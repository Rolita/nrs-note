/// 按行排版的几何引擎。
///
/// 一个源码行 = 一个 `TextPainter`。这样做的代价是每行一次布局，收益是
/// **软换行只发生在这一行内部**：第二行的起点由这一行的正文列决定，而不是
/// 整个段落的左边缘。列表的悬挂缩进因此是像素级的，不需要在段落层面
/// 补空格或假装对齐。
///
/// 引擎只产出几何：每行的顶部/高度、正文列、视觉行、光标落点、选区盒子。
/// 它不构建 span、不画字、不认识主题色；调用方用 `styleFor`/`heightFor`
/// 决定每行用什么样式、占多高（折叠的围栏行就是靠后者压成 16px / 0）。
library;

import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/foundation.dart'
    show listEquals, visibleForTesting;
import 'package:flutter/painting.dart';

import 'line_block_view.dart';
import 'line_layout_model.dart';

export 'line_block_view.dart';
export 'line_layout_model.dart';

/// 一行的文字样式。实时 Markdown 会在这里返回标题/代码/正文样式。
typedef LineStyleResolver = TextStyle Function(SourceLine line);

/// 解析器的语义键：两个不同实例只要 [styleKey] 相同，对**没改动的行**就给
/// 出完全一样的排版。
///
/// 宿主每次重建都会换一个新实例（`LiveLineStyle` 带着新源码重建），渲染层
/// 不能因此丢掉整篇布局——文本变化由编辑差分负责。真正改变排版规则的事情
/// （主题、正文样式、悬停标签、标记摊开）才应该改变这个键。
abstract interface class LineStyleKeyed {
  Object? get styleKey;
}

/// 一行的固定高度，`null` 表示按测量结果。
///
/// 折叠的围栏行是唯一的例子：开围栏只留 16px 的卡片标题行，闭围栏压成 0。
typedef LineHeightResolver = double? Function(SourceLine line);

/// 一行的 span 树，`null` 表示用纯文本 + [LineStyleResolver] 的样式。
///
/// 行内样式（加粗、行内代码、链接）走这个入口。返回的 `toPlainText()` 必须与
/// `line.text.substring(line.paintStart, line.end - line.start)` 逐字符相同，
/// 否则偏移映射会错位——引擎会校验，对不上就退回纯文本。
typedef LineSpanResolver = InlineSpan? Function(SourceLine line);

/// 一行的左右内边距，`null` 表示贴住正文列边缘。
///
/// 代码块卡片是唯一的例子：卡片的底色铺满整列，而代码要退进去 16px，否则
/// 字会贴着卡片的边。以前这个内边距由画笔「把卡片画宽 16px」来伪造——那
/// 要求卡片越出正文列；现在按行排版能把正文起点右移，卡片就能老实铺在列内。
typedef LineInsetResolver = EdgeInsets Function(SourceLine line);

/// 一行里要铺圆角底片的行内片段（行内代码、`#标签`）。
///
/// `TextStyle.backgroundColor` 只能是紧贴字形的直角矩形，内边距和圆角都做不
/// 出来；一行一个 `TextPainter` 又承载不了 widget 端帽。所以底片由渲染层按
/// 这个出口自己画：先铺一块圆角矩形，再把这一行的字画在上面。
class LineFillRun {
  LineFillRun({
    required this.from,
    required this.to,
    required this.fill,
    required this.radius,
    required this.probe,
    required this.style,
    this.padX = 0,
    this.padY = 0,
  });

  /// 片段在这一行**排出来的文字**里的起止偏移（`paintStart` 起算，含两侧
  /// 反引号——端帽本身就是内边距）。
  final int from;
  final int to;

  /// 底片颜色。
  final Color fill;

  /// 底片的圆角半径。由样式层给，渲染层不认识「代码胶囊」「标签胶囊」。
  final double radius;

  /// 底片在文字左右额外铺出的宽度。
  ///
  /// 行内代码靠反引号的字宽顶出内边距，标签没有这种隐藏字符可用，只能把底片
  /// 向两侧多画几个像素（样式层给的 `kTagPadX`）。
  final double padX;

  /// 底片在文字上下额外铺出的高度。
  ///
  /// 标签胶囊在设计稿里是 `padding: 1px 6px`，这 1px 上下内边距同样没有字符
  /// 位可占：底片高度按字号量出来之后再上下各补一点，行盒高度不变。
  final double padY;

  /// 量底片高度用的样本（代码正文）。
  final String probe;

  /// 片段字体；只用来量底片的高度与基线位置。
  final TextStyle style;

  /// 底片高度（含上下内边距）与基线相对片段顶部的下沉量。
  ///
  /// 绘制期每帧都要这两个值，量它们却要新建一个 [TextPainter]。首次绘制时
  /// 量一次存在这里，之后只画矩形；样式/字号变了会换一份新的 run 对象。
  double? measuredHeight;
  double? measuredDrop;
}

/// 按行取圆角底片；`null` 表示这一行没有底片。
typedef LineFillResolver = List<LineFillRun> Function(SourceLine line);

/// 正文字形在行盒里整体下沉的量。
///
/// 行高把行距均分在基线上下的行盒里，而汉字与数字的墨迹都落在基线以上，
/// 所以文字的视觉中线总比行盒中心低；复选框/圆点按行盒中心摆放。把文字
/// 上提相同的量，三者才共用同一条视觉中线。行高与字号可变，按实际度量
/// 计算而不是写死像素：汉字墨迹中心约在基线往上 `0.33em`（实测雅黑
/// 15px 时墨迹中心比行盒中心低约 3.1px，1.5px 明显不够）。
double lineTextRise(LaidOutLine line) {
  final double baseline = line.painter.computeDistanceToActualBaseline(
    TextBaseline.alphabetic,
  );
  if (!baseline.isFinite) return 0;
  final double height = line.visuals.isEmpty
      ? line.height
      : line.visuals.first.height;
  final double size = line.painter.text?.style?.fontSize ?? 15;
  final double rise = baseline - height / 2 - size * 0.33;
  return rise.isFinite ? rise.clamp(0.0, size * 0.3) : 0;
}

/// 一行排完版的结果。
class LaidOutLine {
  LaidOutLine({
    required this.source,
    required this.top,
    required this.height,
    required this.slot,
    required this.painter,
    required this.visuals,
    this.insets = EdgeInsets.zero,
    this.block,
    this.fills = const <LineFillRun>[],
    this.fromCache = false,
    this.hidden = false,
    this.fold,
    this.folded = false,
    int? paintedFrom,
  }) : paintedFrom = paintedFrom ?? source.paintStart;

  final SourceLine source;

  /// [painter] 是否由 [LineLayoutCache] 持有。
  ///
  /// 持有时不能在 `dispose()` 里释放：同一个 painter 会被下一轮布局继续
  /// 复用，释放权归缓存池。
  final bool fromCache;

  /// 交给 [painter] 的第一个字符的文档偏移。
  ///
  /// 平时等于 [SourceLine.paintStart]；标记摊进正文时退回标记起点
  /// [SourceLine.markerStart]——缩进仍留在槽位里，摊开的只是标记本身。
  final int paintedFrom;

  /// 行顶在文档坐标里的 y。
  ///
  /// 局部重排（[relayoutLines]）会复用未变行的整个对象，只按新的累计高度
  /// 平移这个值，所以它不是 final。
  double top;

  final double height;

  /// 列表标记槽位；非列表行是 [MarkerSlot.none]。
  final MarkerSlot slot;

  /// 这一行的左右内边距（代码块卡片），坐标从正文列边缘起算。
  final EdgeInsets insets;

  /// 这一行的文字（列表行只含正文）。渲染层把它画在 `(gutter, top)`。
  final TextPainter painter;

  final List<VisualLine> visuals;

  /// 这一行的自绘内容（实时表格行）；`null` 表示照常画 [painter]。
  ///
  /// 有它时 [painter] 是空的：绘制、命中、光标落点全部由 [block] 回答。
  final LineBlockView? block;

  /// 这一行要铺在文字下面的圆角底片（行内代码），坐标相对 [painter]。
  final List<LineFillRun> fills;

  /// 这一行每条视觉行的基线（相对行顶），铺底片时按它分组。
  ///
  /// `TextPainter.computeLineMetrics()` 每帧重算是纯浪费：视觉行的切分在布局
  /// 期就固定了，基线也随之固定。首次铺底片时算一次存在这里。
  List<double>? visualBaselines;

  /// 这一行被某个折叠的祖先藏起来了：保留在 [LineDocumentLayout.laidOut]
  /// 里以维持行号对齐，但高度为 0，不测量、不绘制、不参与命中。
  final bool hidden;

  /// 这一行自己可以折叠时，它的子树范围；其余行为 `null`。
  ///
  /// 被祖先藏起来的行不再拥有折叠箭头，所以这里也是 `null`。
  final ListFold? fold;

  /// [fold] 的子树当前是否折起。
  final bool folded;

  double get bottom => top + height;

  /// 正文列（文档坐标里的 x）。续行从这里开始。
  ///
  /// 列表行的正文列在标记之后，代码行的正文列在卡片内边距之后——两者都是
  /// 「这一行的字从哪里起笔」，所以续行、光标、命中统一读这个值。
  double get gutter => insets.left + slot.width;

  /// [localY]（相对行顶）落在第几条视觉行。
  int visualIndexAtY(double localY) {
    for (int i = visuals.length - 1; i >= 0; i--) {
      if (localY >= visuals[i].top) return i;
    }
    return 0;
  }

  @override
  String toString() =>
      'LaidOutLine(${source.index}, top=$top, h=$height, gutter=$gutter)';
}

/// 整篇文档的行布局结果。
///
/// 文档坐标：原点在正文左上角，y 沿行累积，x 从正文左边缘起算。
class LineDocumentLayout {
  LineDocumentLayout._({
    required this.text,
    required this.lines,
    required this.laidOut,
    required this.width,
    required this.height,
    required this.metrics,
    required Map<int, int> hiddenUnder,
    // 私有字段不能做命名参数，只能在这里赋值。
    // ignore: prefer_initializing_formals
  }) : _hiddenUnder = hiddenUnder;

  final String text;
  final List<SourceLine> lines;
  final List<LaidOutLine> laidOut;
  final double width;
  final double height;
  final LineLayoutMetrics metrics;

  /// 被藏起来的行号 → 折叠它的可见祖先行号。
  final Map<int, int> _hiddenUnder;

  /// [blockRect] 的结果按 `(start, end)` 备忘：代码块卡片每帧都会问同一批块。
  final Map<(int, int), Rect?> _blockRects = <(int, int), Rect?>{};

  /// 实际执行过全行扫描的 [blockRect] 次数，供测试确认缓存生效。
  @visibleForTesting
  int debugBlockRectComputes = 0;

  bool _disposed = false;

  /// 与文档坐标 `[top, bottom]` 纵向相交的源码行下标区间 `[from, to)`。
  ///
  /// [laidOut] 按 `top` 递增（含零高的隐藏行），所以起点用二分找，止点从起点
  /// 顺序推进即可。绘制层只遍历这个区间，滚动成本因此与总行数脱钩。
  ({int from, int to}) lineRangeBetween(double top, double bottom) {
    if (laidOut.isEmpty || bottom < top) return (from: 0, to: 0);
    int from = _lineIndexAtOrBefore(top);
    int to = from;
    while (to < laidOut.length && laidOut[to].top <= bottom) {
      to++;
    }
    return (from: from, to: to);
  }

  /// 文档坐标 [y] 落在（或刚越过）的源码行下标；不过滤零高的隐藏行。
  int _lineIndexAtOrBefore(double y) {
    int lo = 0;
    int hi = laidOut.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (laidOut[mid].top <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 把落在折叠子树里的偏移收回到可见位置。
  ///
  /// 折叠区的文字还留在源码里，程序性选区（方向键、Ctrl+End、撤销）仍可能
  /// 停在那些偏移上。它们没有字形可以落脚，统一吸附到折叠项正文的末尾——
  /// 也就是子树前面那个仍然可见的位置。
  int visibleOffset(int offset) {
    final int o = offset.clamp(0, text.length);
    final int index = _lineIndexAtOffset(o);
    if (!laidOut[index].hidden) return o;
    final int? parent = _hiddenUnder[index];
    return parent == null
        ? laidOut[index].source.start
        : laidOut[parent].source.end;
  }

  /// 光标在 [offset] 处的几何。
  ///
  /// 标记没摊开时（列表行 `[start, paintStart)`）光标统一吸附到正文列起点：
  /// 槽位里的圆点/复选框不是字形，用字宽去插值只会让光标在标记里乱跳。
  /// 标记摊进正文后它就是字形，偏移按普通字符映射；只有缩进区仍吸附到
  /// 标记起点。
  CaretGeometry caretGeometryAt(int offset) {
    final int o = visibleOffset(offset);
    final int lineIndex = _lineIndexAtOffset(o);
    final LaidOutLine line = laidOut[lineIndex];
    final SourceLine source = line.source;

    final LineBlockView? block = line.block;
    if (block != null) {
      final Rect rect = block.caretRectAt(o);
      return CaretGeometry(
        offset: o,
        origin: Offset(rect.left, line.top + rect.top),
        height: rect.height > 0 ? rect.height : line.visuals.first.height,
        lineIndex: lineIndex,
        visualIndex: 0,
      );
    }

    if (o < line.paintedFrom) {
      return CaretGeometry(
        offset: o,
        origin: Offset(line.gutter, line.top),
        height: line.visuals.first.height,
        lineIndex: lineIndex,
        visualIndex: 0,
      );
    }

    final int local = (o - line.paintedFrom).clamp(
      0,
      source.end - line.paintedFrom,
    );
    final TextPosition position = TextPosition(offset: local);
    final Offset caret = line.painter.getOffsetForCaret(position, Rect.zero);
    final int visual = line.visualIndexAtY(caret.dy);
    return CaretGeometry(
      offset: o,
      origin: Offset(line.gutter + caret.dx, line.top + caret.dy),
      // 光标高度跟这一整条视觉行，不用字形量出来的高度：行尾是空格时
      // `getFullHeightForCaret` 量的是空格自己的字形盒（比行高矮一截），
      // 光标会突然变短。整条视觉行的高度对正文、标题、加粗行都一致。
      height: line.visuals[visual].height,
      lineIndex: lineIndex,
      visualIndex: visual,
    );
  }

  /// 文档坐标 [point] 对应的源码偏移。
  ///
  /// 标记没摊开时，落在标记区/缩进区会返回正文起点——点列表的圆点会像点行首
  /// 一样，光标进到正文第一字前面，而不是钻到标记字符之间。标记摊进正文后
  /// 缩进仍占着槽位，只有落在槽位左边才钳到标记起点。
  int offsetAtPoint(Offset point) {
    if (point.dy < 0) return 0;
    if (point.dy >= height) return visibleOffset(text.length);
    final int lineIndex = _lineIndexAtY(point.dy);
    final LaidOutLine line = laidOut[lineIndex];
    final LineBlockView? block = line.block;
    if (block != null) {
      return block
          .offsetAt(Offset(point.dx, point.dy - line.top))
          .clamp(0, text.length);
    }
    final double localX = point.dx - line.gutter;
    if (localX < 0) {
      // 标记摊进正文后槽位只剩缩进；缩进不是字形，落在它上面应归到正文起点。
      // 沿用 paintedFrom（摊开时为 markerStart）会把光标停在 `3. ` 之前，
      // 接着输入就把文字插进标记里（`qie'huan3. [ ]`）。
      return line.slot.revealedMarkers
          ? line.source.paintStart
          : line.paintedFrom;
    }
    final double maxWidth = math.max(
      1.0,
      width - line.gutter - line.insets.right,
    );
    final int local = line.painter
        .getPositionForOffset(
          Offset(
            math.min(localX, maxWidth),
            point.dy - line.top + lineTextRise(line),
          ),
        )
        .offset;
    return (line.paintedFrom + local).clamp(line.paintedFrom, line.source.end);
  }

  /// 源码行 [index] 的顶部（文档坐标）；越界时夹到首/末行。
  ///
  /// 大纲跳转要的是「这一行在第几个像素」，而每行的高度由它自己的字号决定
  /// （标题、代码、正文各不相同），用正文行高乘行数会一路累积误差。
  double lineTop(int index) {
    if (laidOut.isEmpty) return 0;
    final int i = index.clamp(0, laidOut.length - 1);
    return laidOut[i].top;
  }

  /// 选区 `[baseOffset, extentOffset)` 的高亮盒子。
  ///
  /// 每个视觉行一块：横向贴着字形（`BoxWidthStyle.tight`，Typora / Obsidian
  /// 的观感），纵向铺满整条视觉行——上下两行的盒子因此首尾相接，行与行之间
  /// 的缝隙由画笔（`EditorSelectionPainter`）统一扣出来，而不是靠行距留白。
  /// 从行首选起的选区还会盖住左侧标记槽位。
  ///
  /// [visible] 给定时只遍历与它纵向相交的行：绘制一帧不必产出屏幕外的矩形。
  List<Rect> selectionRects(
    int baseOffset,
    int extentOffset, {
    Rect? visible,
  }) {
    int a = baseOffset.clamp(0, text.length);
    int b = extentOffset.clamp(0, text.length);
    if (a > b) {
      final int swap = a;
      a = b;
      b = swap;
    }
    if (a == b) return const <Rect>[];

    final ({int from, int to}) range = visible == null
        ? (from: 0, to: laidOut.length)
        : lineRangeBetween(visible.top, visible.bottom);
    final List<Rect> out = <Rect>[];
    for (int index = range.from; index < range.to; index++) {
      final LaidOutLine line = laidOut[index];
      final SourceLine source = line.source;
      // 自绘行（表格）按格子成块选中：这一行没有字形盒子可量，矩形由它
      // 自己回答，引擎只负责换算到文档坐标。
      final LineBlockView? block = line.block;
      if (block != null) {
        if (line.height <= 0) continue;
        final int from = math.max(a, source.start);
        final int to = math.min(b, source.end);
        if (to <= from) continue;
        for (final Rect rect in block.highlightRects(from, to)) {
          out.add(rect.shift(Offset(line.gutter, line.top)));
        }
        continue;
      }
      // 换行符属于它结束的那一行，所以右端要算到 end + 1。
      final int from = math.max(a, source.start);
      final int to = math.min(b, source.end + 1);
      if (to <= from) continue;
      if (line.height <= 0) continue;

      final int paintedFrom = math.max(from, line.paintedFrom);
      final int paintedTo = math.min(to, source.end);
      List<TextBox> boxes = const <TextBox>[];
      if (paintedTo > paintedFrom) {
        boxes = line.painter.getBoxesForSelection(
          TextSelection(
            baseOffset: paintedFrom - line.paintedFrom,
            extentOffset: paintedTo - line.paintedFrom,
          ),
          boxHeightStyle: BoxHeightStyle.tight,
          boxWidthStyle: BoxWidthStyle.tight,
        );
      }

      if (boxes.isEmpty) {
        // 空行，或者选区只碰到了换行符：给一条零宽的高亮，落在这一行的起笔处。
        // 列表行从行首选起时连标记槽位一起洗；有内边距的行（代码块）只洗到
        // 正文起点，否则卡片的内边距会被涂成一条色带。
        final VisualLine visual = line.visuals.last;
        final bool fromLineStart = from <= source.start;
        final double left = fromLineStart && source.isList ? 0 : line.gutter;
        out.add(
          Rect.fromLTRB(
            left,
            line.top + visual.top,
            left,
            line.top + visual.top + visual.height,
          ),
        );
        continue;
      }

      for (int i = 0; i < boxes.length; i++) {
        final TextBox box = boxes[i];
        final VisualLine visual = _visualAt(line, box.top);
        double left = line.gutter + box.left;
        // 从行首选起：第一块把手伸进标记槽位（只有列表行有槽位）。
        if (i == 0 && from <= source.start && source.isList) left = 0;
        out.add(
          Rect.fromLTRB(
            left,
            line.top + visual.top,
            math.max(left, line.gutter + box.right),
            line.top + visual.top + visual.height,
          ),
        );
      }
    }
    return out;
  }

  /// 源码区间 `[start, end)` 覆盖的整行矩形（文档坐标）。
  ///
  /// 只有一个矩形，因为调用方（代码块卡片）要的是「这一段占了几行、从哪到
  /// 哪」，而不是每一行的字形盒子。零高的行（折叠的闭围栏）不参与，否则卡片
  /// 底部会多出一整行空白。
  Rect? blockRect(int start, int end) {
    int a = start.clamp(0, text.length);
    int b = end.clamp(0, text.length);
    if (a > b) {
      final int swap = a;
      a = b;
      b = swap;
    }
    if (a == b) return null;
    final (int, int) key = (a, b);
    if (_blockRects.containsKey(key)) return _blockRects[key];

    debugBlockRectComputes++;
    double top = double.infinity;
    double bottom = -double.infinity;
    for (final LaidOutLine line in laidOut) {
      if (line.source.end < a || line.source.start >= b) continue;
      if (line.height <= 0) continue;
      for (final VisualLine visual in line.visuals) {
        if (visual.height <= 0) continue;
        top = math.min(top, line.top + visual.top);
        bottom = math.max(bottom, line.top + visual.top + visual.height);
      }
    }
    final Rect? result = top.isFinite && bottom > top
        ? Rect.fromLTRB(0, top, width, bottom)
        : null;
    return _blockRects[key] = result;
  }

  /// [localTop]（相对行顶）落在哪条视觉行。
  VisualLine _visualAt(LaidOutLine line, double localTop) {
    VisualLine found = line.visuals.first;
    for (final VisualLine visual in line.visuals) {
      if (visual.top > localTop + 0.01) break;
      found = visual;
    }
    return found;
  }

  int _lineIndexAtOffset(int offset) {
    int lo = 0;
    int hi = laidOut.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (laidOut[mid].source.start <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  int _lineIndexAtY(double y) {
    int lo = _lineIndexAtOrBefore(y);
    // 零高的行（折叠子树的成员、收起的闭围栏）不占像素：落点归到它上方
    // 最近一条真正画出来的行，否则点击会被吸进看不见的源码。
    while (lo > 0 && laidOut[lo].height <= 0) {
      lo--;
    }
    return lo;
  }

  /// 是否已经释放或交出所有权（此后任何几何方法都不可再用）。
  bool get disposed => _disposed;

  /// 释放所有行的 [TextPainter]。布局对象作废后不能再调用任何几何方法。
  ///
  /// 自绘行（表格）的资源不在这里释放：那些视图由宿主缓存、跨多轮排版
  /// 复用，只有宿主知道什么时候该丢。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final LaidOutLine line in laidOut) {
      if (!line.fromCache) line.painter.dispose();
    }
  }

  /// 交出所有权：之后 [dispose] 变成空操作。
  ///
  /// 局部重排会把未变行的 [LaidOutLine]（连同 `TextPainter`）整体搬进新布局；
  /// 旧布局随即作废，如果它再释放一遍这些 painter，新布局就会拿着已释放的
  /// 对象继续测量。
  void handOverOwnership() {
    _disposed = true;
  }

  /// 揭示选区从 [before] 变到 [after] 时，需要重排的行号集合。
  ///
  /// 逐行签名 = 「选区与本行 `[start, end]` 的钳制交集」+「折叠光标落点」。
  /// `LiveLineStyle` 对一行的选区依赖（`_revealed`、`_caretOn`、`_tagRevealed`、
  /// `_inlineOrPlain`、`fillsFor`、`insetFor`）全部能由它导出：交集落在行内
  /// 的哪一段，决定标记摊开与否、行内 token 是否露出源码、标签是否让出内边距。
  ///
  /// 计算只在「新旧选区并集覆盖的行区间」内逐行比较，标点（折叠光标）移动
  /// 只碰两行；框选整篇（Ctrl+A）会得到全文，那是一次允许的全量重排。
  ///
  /// 表格行额外连带整段表格 run：表格整表重测时会换掉整块行视图，只重排
  /// 其中几行会让其余行继续指向已释放的行块。
  Set<int> revealDirtyLines(TextSelection? before, TextSelection? after) {
    if (laidOut.isEmpty) return const <int>{};
    final bool beforeValid =
        before != null && before.isValid && before.start >= 0;
    final bool afterValid = after != null && after.isValid && after.start >= 0;
    if (!beforeValid && !afterValid) return const <int>{};

    int first = laidOut.length - 1;
    int last = 0;
    if (beforeValid) {
      first = math.min(first, _lineIndexAtOffset(before.start));
      last = math.max(last, _lineIndexAtOffset(before.end));
    }
    if (afterValid) {
      first = math.min(first, _lineIndexAtOffset(after.start));
      last = math.max(last, _lineIndexAtOffset(after.end));
    }

    final Set<int> dirty = <int>{};
    for (int i = first; i <= last; i++) {
      final SourceLine source = laidOut[i].source;
      if (_revealSignature(source, before) !=
          _revealSignature(source, after)) {
        dirty.add(i);
      }
    }
    if (dirty.isEmpty) return dirty;

    // 表格 run 连带：table / tableHeader / tableDivider 的连续行属于同一张表，
    // 只要有一行被判脏，整段一起重建。
    final Set<int> expanded = <int>{};
    for (final int i in dirty) {
      int from = i;
      int to = i;
      if (_isTableLine(laidOut[i].source.kind)) {
        while (from > 0 && _isTableLine(laidOut[from - 1].source.kind)) {
          from--;
        }
        while (to + 1 < laidOut.length &&
            _isTableLine(laidOut[to + 1].source.kind)) {
          to++;
        }
      }
      for (int k = from; k <= to; k++) {
        expanded.add(k);
      }
    }
    return expanded;
  }
}

/// 一轮布局的 `TextPainter` 池。
///
/// 长文档每次击键都会整篇重排，但除改动行之外，绝大多数行的文字、样式、
/// 可用宽度都没变。导航、标记槽位与表格仍逐行重算（它们便宜且依赖上下文），
/// 这里只复用真正昂贵的 `TextPainter.layout()` 结果。
///
/// 键不含行号，而按行号存放：在中间插入换行会让后续行号整体移动，那些行
/// 本轮先 miss，下一轮重新稳定下来即可命中。带行内样式的行、表格块行不进
/// 缓存，避免 span 树或块资源被错误共享。
class LineLayoutCache {
  final Map<int, _MeasuredLine> _lines = <int, _MeasuredLine>{};
  int _generation = 0;

  void _begin() {
    _generation++;
  }

  _MeasuredLine? _take(int index, _LineKey key) {
    final _MeasuredLine? line = _lines[index];
    if (line == null || line.key != key) return null;
    line.generation = _generation;
    return line;
  }

  void _put(
    int index,
    _LineKey key,
    TextPainter painter,
    double height,
    int base,
    List<VisualLine> visuals,
  ) {
    final _MeasuredLine? old = _lines[index];
    if (old != null && !identical(old.painter, painter)) {
      old.painter.dispose();
    }
    _lines[index] = _MeasuredLine(
      key: key,
      painter: painter,
      height: height,
      base: base,
      visuals: visuals,
      generation: _generation,
    );
  }

  void _end() {
    _lines.removeWhere((int _, _MeasuredLine line) {
      if (line.generation == _generation) return false;
      line.painter.dispose();
      return true;
    });
  }

  /// 释放池里所有 painter。只能在整个渲染对象销毁时调用一次。
  void dispose() {
    for (final _MeasuredLine line in _lines.values) {
      line.painter.dispose();
    }
    _lines.clear();
  }
}

typedef _LineKey = (
  String painted,
  TextStyle style,
  double maxWidth,
  TextScaler textScaler,
  TextDirection textDirection,
  double? override,
);

class _MeasuredLine {
  _MeasuredLine({
    required this.key,
    required this.painter,
    required this.height,
    required this.base,
    required this.visuals,
    required this.generation,
  });

  final _LineKey key;
  final TextPainter painter;
  final double height;

  /// 缓存 [visuals] 时它们的文档偏移以哪个位置为 0。
  final int base;
  final List<VisualLine> visuals;
  int generation;
}

/// 一轮按行布局的成本计数，供测试与性能夹具观测。
///
/// [paintersMeasured] 是本轮真正执行了 `TextPainter.layout()` 的可见行数；
/// [cacheHits] 是从 [LineLayoutCache] 原样取回 painter 的行数；[blockResolves]
/// 是向 [LineBlockResolver]（表格等自绘行）索要内容的次数。三者不互斥：
/// 一块行既不测量也不命中缓存（高度被 [LineHeightResolver] 压成 0 的行仍会
/// 测量，隐藏行两种都不算）。
class LineLayoutStats {
  int paintersMeasured = 0;
  int cacheHits = 0;
  int blockResolves = 0;

  /// 本轮真正重建（解析 span / 重新测量）的行数；隐藏占位行不算。
  int rebuiltLines = 0;

  /// 局部重排里整对象复用的行数。
  int reusedLines = 0;

  void reset() {
    paintersMeasured = 0;
    cacheHits = 0;
    blockResolves = 0;
    rebuiltLines = 0;
    reusedLines = 0;
  }
}

/// 对 [text] 做一次按行布局。
///
/// [contentWidth] 是正文列（不是整行）的可用宽度；列表行的实际排版宽度
/// 会再减去标记槽位，代码行再减去 [LineInsetResolver] 给的卡片内边距。
LineDocumentLayout layoutLines({
  required String text,
  required TextStyle baseStyle,
  required double contentWidth,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  LineStyleResolver? styleFor,
  LineHeightResolver? heightFor,
  LineSpanResolver? spanFor,
  LineFillResolver? fillFor,
  LineInsetResolver? insetFor,
  LineBlockResolver? blockFor,
  int? markerRevealLine,
  Set<int> foldedLines = const <int>{},
  LineLayoutMetrics metrics = const LineLayoutMetrics(),
  LineLayoutCache? cache,
  LineLayoutStats? stats,
}) {
  cache?._begin();
  final List<SourceLine> sources = scanSourceLines(text);
  final List<LaidOutLine> out = <LaidOutLine>[];

  // 哪些列表项的子树现在收起。父行自己也藏在上一个折叠里时跳过：它的
  // 箭头看不见，展开状态等祖先展开后自然恢复。这样每个被藏的行都只认
  // 最近一层**可见**的折叠，光标吸附一步就能回到看得见的地方。
  final _FoldPlan folds = _planFolds(sources, foldedLines);
  final Map<int, ListFold> foldByParent = folds.byParent;
  final Set<int> hiddenLines = folds.hidden;
  final Map<int, int> hiddenUnder = folds.hiddenUnder;
  final Set<int> foldedParents = folds.foldedParents;
  final LineBlockContext blockContext = LineBlockContext(
    contentWidth: contentWidth,
    textScaler: textScaler,
    textDirection: textDirection,
  );
  double top = 0;

  // 每一级最近一个列表项的标记中心，供下一层导轨对齐。空行不清栈，这样
  // 松散列表（条目之间隔一行）的竖线仍是连贯的一根。
  final List<double?> railCentres = List<double?>.filled(6, null);

  for (int i = 0; i < sources.length; i++) {
    final SourceLine source = sources[i];
    if (hiddenLines.contains(i)) {
      // 零高的占位行：不取样式、不测量、不进缓存，只为让行号与源码一一
      // 对应。绘制与命中都会跳过它，几何出口会把它折回可见的父项。
      out.add(_hiddenLine(source, top, baseStyle, textScaler, textDirection));
      continue;
    }

    final TextStyle style = styleFor?.call(source) ?? baseStyle;
    final MarkerSlot bare = _slotOf(
      source,
      style,
      text,
      textScaler,
      textDirection,
      metrics,
      const <double>[],
    );
    final List<double> rails = _railsFor(
      source,
      sources,
      i,
      railCentres,
      bare,
      metrics,
    );
    // 只有用户明确点开的那一行才把标记摊进正文；光标恰好停在行首（刚绑定
    // 笔记、Ctrl+Home）不算——那会让第一行是列表的笔记一打开就露出源码。
    final bool markersInline =
        source.isList &&
        markerRevealLine != null &&
        markerRevealLine == source.start;
    final MarkerSlot slot = MarkerSlot(
      level: bare.level,
      indent: bare.indent,
      marker: bare.marker,
      digitWidth: bare.digitWidth,
      ownRailAbove:
          source.isList && bare.level > 0 && railCentres[bare.level] != null,
      railXs: rails,
      revealedMarkers: markersInline,
    );
    _updateRailCentres(source, slot, railCentres, metrics);
    final _LineMeasured measured = _measureOneLine(
      source: source,
      text: text,
      style: style,
      slot: slot,
      contentWidth: contentWidth,
      textScaler: textScaler,
      textDirection: textDirection,
      blockContext: blockContext,
      blockFor: blockFor,
      spanFor: spanFor,
      fillFor: fillFor,
      insetFor: insetFor,
      heightFor: heightFor,
      markersInline: markersInline,
      index: i,
      cache: cache,
      stats: stats,
    );

    out.add(
      LaidOutLine(
        source: source,
        top: top,
        height: measured.height,
        slot: slot,
        insets: measured.insets,
        painter: measured.painter,
        visuals: measured.visuals,
        block: measured.block,
        fills: measured.fills,
        fromCache: measured.fromCache,
        fold: foldByParent[i],
        folded: foldedParents.contains(i),
        paintedFrom: measured.paintedFrom,
      ),
    );
    stats?.rebuiltLines++;
    top += measured.height;
  }

  cache?._end();

  return LineDocumentLayout._(
    text: text,
    lines: sources,
    laidOut: out,
    width: contentWidth,
    height: top,
    metrics: metrics,
    hiddenUnder: hiddenUnder,
  );
}

/// 一行的测量产物。全量与局部重排共用 [_measureOneLine] 的返回值。
typedef _LineMeasured = ({
  TextPainter painter,
  double height,
  List<VisualLine> visuals,
  List<LineFillRun> fills,
  int paintedFrom,
  EdgeInsets insets,
  LineBlockView? block,
  bool fromCache,
});

/// 测量并排版一行。
///
/// 全量 [layoutLines] 与局部 [relayoutLines] 都走这里：解析 span、铺底片、
/// 取固定行高、缓存命中、建 `TextPainter`、切视觉行——只有一份，避免两条
/// 路径各自漂移。
///
/// [cache] 为 `null` 时一律新建 painter、不进池（局部重排的要求：脏行多半
/// 因揭示变化而不可缓存，入池会把「键相同但 span 树已变」的旧 painter 留给
/// 下一次全量布局）。
_LineMeasured _measureOneLine({
  required SourceLine source,
  required String text,
  required TextStyle style,
  required MarkerSlot slot,
  required double contentWidth,
  required TextScaler textScaler,
  required TextDirection textDirection,
  required LineBlockContext blockContext,
  required LineBlockResolver? blockFor,
  required LineSpanResolver? spanFor,
  required LineFillResolver? fillFor,
  required LineInsetResolver? insetFor,
  required LineHeightResolver? heightFor,
  required bool markersInline,
  required int index,
  required LineLayoutCache? cache,
  required LineLayoutStats? stats,
}) {
  final LineBlockView? block = blockFor?.call(source, blockContext);
  stats?.blockResolves++;
  final EdgeInsets insets = block == null
      ? (insetFor?.call(source) ?? EdgeInsets.zero)
      : EdgeInsets.zero;
  final double maxWidth = math.max(
    1.0,
    contentWidth - insets.horizontal - slot.width,
  );
  final int paintedFrom = markersInline ? source.markerStart : source.paintStart;
  final String painted = text.substring(paintedFrom, source.end);
  final InlineSpan? custom = block == null ? spanFor?.call(source) : null;
  final InlineSpan? usable = custom != null && custom.toPlainText() == painted
      ? custom
      : null;
  // 底片的偏移是相对这一行排出来的文字算的，span 树退回纯文本时那些偏移
  // 也就不成立了（端帽的内边距会跟着消失），所以只在 span 可用时铺底片。
  final List<LineFillRun> fills = block == null && usable != null
      ? (fillFor?.call(source) ?? const <LineFillRun>[])
      : const <LineFillRun>[];
  final double? override = block != null ? null : heightFor?.call(source);
  // 只有 span 树不改变任何字体度量时才缓存：颜色、底片、装饰线不影响
  // 排版，可以忽略；字重、字体、字号、字距会影响宽度，必须逐层比对。
  final bool cacheable =
      block == null && (usable == null || _spanUsesBaseMetrics(usable, style));
  final bool pooled = cacheable && cache != null;
  final _LineKey key = (
    painted,
    style,
    maxWidth,
    textScaler,
    textDirection,
    override,
  );
  final _MeasuredLine? measured = pooled ? cache._take(index, key) : null;

  final TextPainter painter;
  final double height;
  final List<VisualLine> visuals;
  if (measured != null) {
    painter = measured.painter;
    height = measured.height;
    visuals = _shiftVisuals(measured.visuals, measured.base, paintedFrom);
    stats?.cacheHits++;
  } else {
    painter = TextPainter(
      text: block != null
          ? TextSpan(text: '', style: style)
          : (usable ?? TextSpan(text: painted, style: style)),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth);
    stats?.paintersMeasured++;

    final double rowHeight = _rowHeight(style);
    height = block?.height ?? override ?? math.max(painter.height, rowHeight);
    visuals = block != null
        ? <VisualLine>[
            VisualLine(
              index: 0,
              top: 0,
              height: block.height,
              start: source.start,
              end: source.end,
              width: block.width,
            ),
          ]
        : _visualsOf(
            source,
            painter,
            height,
            override != null,
            maxWidth,
            paintedFrom,
          );
    if (pooled) {
      cache._put(index, key, painter, height, paintedFrom, visuals);
    }
  }

  return (
    painter: painter,
    height: height,
    visuals: visuals,
    fills: fills,
    paintedFrom: paintedFrom,
    insets: insets,
    block: block,
    fromCache: pooled,
  );
}

/// 局部重排：只重建 [dirtyLines] 里的行，其余行整对象复用。
///
/// 前提是「文本、宽度、字号缩放、方向、基础样式、`markerRevealLine`、折叠
/// 状态」都没变——那些变化会改变行结构、槽位或隐藏行映射，只能走全量。
/// 调用方（渲染对象）负责判断；这里对文本/宽度/度量再做一次兜底，前提不成立
/// 时直接退回 [layoutLines]，绝不把错误状态静默接受。
///
/// 复用行的 `LaidOutLine` 对象会被搬进新布局，只平移 [LaidOutLine.top]；
/// 旧布局随即 `handOverOwnership()`，不能再释放这些 painter。脏行的旧
/// painter 按所有权处理：池化的留给下一次全量布局自然淘汰，非池化的当场释放。
LineDocumentLayout relayoutLines({
  required LineDocumentLayout previous,
  required Set<int> dirtyLines,
  required String text,
  required TextStyle baseStyle,
  required double contentWidth,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  LineStyleResolver? styleFor,
  LineHeightResolver? heightFor,
  LineSpanResolver? spanFor,
  LineFillResolver? fillFor,
  LineInsetResolver? insetFor,
  LineBlockResolver? blockFor,
  int? markerRevealLine,
  Set<int> foldedLines = const <int>{},
  LineLayoutMetrics metrics = const LineLayoutMetrics(),
  LineLayoutStats? stats,
}) {
  if (previous.text != text ||
      previous.width != contentWidth ||
      previous.metrics != metrics) {
    return layoutLines(
      text: text,
      baseStyle: baseStyle,
      contentWidth: contentWidth,
      textScaler: textScaler,
      textDirection: textDirection,
      styleFor: styleFor,
      heightFor: heightFor,
      spanFor: spanFor,
      fillFor: fillFor,
      insetFor: insetFor,
      blockFor: blockFor,
      markerRevealLine: markerRevealLine,
      foldedLines: foldedLines,
      metrics: metrics,
      stats: stats,
    );
  }

  final List<SourceLine> sources = previous.lines;
  final List<LaidOutLine> laidOut = List<LaidOutLine>.of(previous.laidOut);
  final LineBlockContext blockContext = LineBlockContext(
    contentWidth: contentWidth,
    textScaler: textScaler,
    textDirection: textDirection,
  );
  double top = 0;
  for (int i = 0; i < laidOut.length; i++) {
    final LaidOutLine old = laidOut[i];
    // 隐藏占位行与未变行：整对象复用（painter、槽位、导轨、底片、视觉行
    // 全部保留），只把行顶平移到新的累计高度。
    if (old.hidden || !dirtyLines.contains(i)) {
      old.top = top;
      top += old.height;
      stats?.reusedLines++;
      continue;
    }

    final SourceLine source = old.source;
    final TextStyle style = styleFor?.call(source) ?? baseStyle;
    // 槽位沿用上一轮：纯选区变化不改列表几何（样式与选区无关），导轨也不变。
    final MarkerSlot slot = old.slot;
    final bool markersInline =
        source.isList &&
        markerRevealLine != null &&
        markerRevealLine == source.start;
    if (!old.fromCache) old.painter.dispose();
    final _LineMeasured measured = _measureOneLine(
      source: source,
      text: text,
      style: style,
      slot: slot,
      contentWidth: contentWidth,
      textScaler: textScaler,
      textDirection: textDirection,
      blockContext: blockContext,
      blockFor: blockFor,
      spanFor: spanFor,
      fillFor: fillFor,
      insetFor: insetFor,
      heightFor: heightFor,
      markersInline: markersInline,
      index: i,
      cache: null,
      stats: stats,
    );
    laidOut[i] = LaidOutLine(
      source: source,
      top: top,
      height: measured.height,
      slot: slot,
      insets: measured.insets,
      painter: measured.painter,
      visuals: measured.visuals,
      block: measured.block,
      fills: measured.fills,
      fold: old.fold,
      folded: old.folded,
      paintedFrom: measured.paintedFrom,
    );
    stats?.rebuiltLines++;
    top += measured.height;
  }

  previous.handOverOwnership();
  return LineDocumentLayout._(
    text: text,
    lines: sources,
    laidOut: laidOut,
    width: contentWidth,
    height: top,
    metrics: metrics,
    hiddenUnder: previous._hiddenUnder,
  );
}

/// 编辑后的局部重排：只重建被编辑波及的行，其余行换壳复用。
///
/// [editStart] / [removedLength] / [insertedLength] 描述新旧文本之间**唯一**的
/// 替换区间（公共前缀与公共后缀求出，新文本坐标）。返回 `null` 表示这次编辑
/// 超出了安全增量范围（行结构变化、行内容对不上、前提不成立），调用方必须
/// 退回 [layoutLines]——宁可慢一次，也不接受几何有偏差的布局。
///
/// 复用的判据是「源码行本身没变」：行文本、种类、层级、序号、标记偏移全部
/// 相同，只有绝对偏移按字符差平移；再加上揭示签名不变（变了的那一行单独
/// 重排）。行高、视觉行、底片、表格行块都跟着旧对象走，因此不会重新解析
/// span、也不会重新测量。
///
/// 结构传播按方案 §8 处理：被编辑波及的表格扩到整张表、围栏扩到整块、
/// 列表结构变化扩到整个列表组；其余情况一旦发现有行对不上就整体退回全量。
LineDocumentLayout? relayoutOnEdit({
  required LineDocumentLayout previous,
  required String text,
  required int editStart,
  required int removedLength,
  required int insertedLength,
  required TextStyle baseStyle,
  required double contentWidth,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection textDirection = TextDirection.ltr,
  LineStyleResolver? styleFor,
  LineHeightResolver? heightFor,
  LineSpanResolver? spanFor,
  LineFillResolver? fillFor,
  LineInsetResolver? insetFor,
  LineBlockResolver? blockFor,
  int? markerRevealLine,
  Set<int> foldedLines = const <int>{},
  LineLayoutMetrics metrics = const LineLayoutMetrics(),
  TextSelection? revealBefore,
  TextSelection? revealAfter,
  LineLayoutStats? stats,
}) {
  if (previous.width != contentWidth || previous.metrics != metrics) return null;
  if (editStart < 0 || removedLength < 0 || insertedLength < 0) return null;

  final int oldLength = previous.text.length;
  final int oldTail = editStart + removedLength;
  final int newTail = editStart + insertedLength;
  if (oldTail > oldLength || newTail > text.length) return null;
  if (oldLength - oldTail != text.length - newTail) return null;
  // 尾部必须逐字符相同：不一致说明传入的区间不是这两份文本的真实差分，
  // 后面的「偏移平移」前提就不成立了。
  if (newTail < text.length &&
      previous.text.substring(oldTail) != text.substring(newTail)) {
    return null;
  }

  final List<SourceLine> sources = scanSourceLines(text);
  if (sources.isEmpty) return null;
  final int charDelta = insertedLength - removedLength;
  final int lineDelta = sources.length - previous.lines.length;

  int from = _sourceIndexAtOffset(sources, editStart) - 1;
  if (from < 0) from = 0;
  int to = _sourceIndexAtOffset(sources, newTail);
  if (to > sources.length - 1) to = sources.length - 1;
  if (from > to) from = to;

  // 表格整段连带：表一旦重测就换了整块行视图，只重建其中几行会让其余行
  // continue 指向已作废的行块。
  bool tableTouched = false;
  bool fenceTouched = false;
  bool listTouched = false;
  for (int i = from; i <= to; i++) {
    final LineBlockKind kind = sources[i].kind;
    if (_isTableLine(kind)) tableTouched = true;
    if (kind == LineBlockKind.fence || kind == LineBlockKind.code) {
      fenceTouched = true;
    }
    if (sources[i].isList) listTouched = true;
  }
  // 表格与围栏必须**整块重建**，不能「换壳复用」：表格的列宽来自整表重测，
  // 每个单元格的 `LineBlockView` 都跟着换；围栏的跨行 token（块注释、多行
  // 字符串）让后面没改字的代码行也可能换色。两者都记成强制重建区间。
  int? forceFrom;
  int? forceTo;
  if (tableTouched) {
    while (from > 0 && _isTableLine(sources[from - 1].kind)) {
      from--;
    }
    while (to + 1 < sources.length && _isTableLine(sources[to + 1].kind)) {
      to++;
    }
    forceFrom = from;
    forceTo = to;
  }
  if (fenceTouched) {
    from = _fenceBlockStart(sources, from);
    to = _fenceBlockEnd(sources, to);
    forceFrom = forceFrom == null ? from : math.min(forceFrom, from);
    forceTo = forceTo == null ? to : math.max(forceTo, to);
  }

  // 列表结构变化（增删行、层级/序号/标记变化）会改变导轨与槽位，dirty 要
  // 扩到整个列表组；纯正文改字不影响别人的导轨，不必扩张。
  if (listTouched && (lineDelta != 0 || _structureChanged(previous, sources, from, to))) {
    from = _railGroupStart(sources, from);
    to = _railGroupEnd(sources, to);
  }

  final _FoldPlan folds = _planFolds(sources, foldedLines);
  final LineBlockContext blockContext = LineBlockContext(
    contentWidth: contentWidth,
    textScaler: textScaler,
    textDirection: textDirection,
  );
  final List<double?> railCentres = List<double?>.filled(6, null);
  final List<LaidOutLine> out = <LaidOutLine>[];
  double top = 0;

  // 已经认领过的旧行。区间内的匹配按绝对偏移查旧行，必须防两行同时认领
  // 同一个旧行——重建分支会释放旧 painter，第二次复用就会拿到已释放的对象。
  final Set<int> claimed = <int>{};

  for (int i = 0; i < sources.length; i++) {
    final SourceLine source = sources[i];
    // 候选旧行与它应有的偏移平移量。
    int? oldIndex;
    int oldDelta = 0;
    if (i < from) {
      oldIndex = i;
    } else if (i > to) {
      oldIndex = i - lineDelta;
      oldDelta = charDelta;
    } else {
      // 区间内没有行号映射：按绝对偏移找旧行。编辑点之前偏移不变，之后
      // 整体平移 `charDelta`——两种都试，内容对得上就是同一行。
      final int at = _sourceIndexAtOffset(previous.lines, source.start);
      if (at < previous.lines.length &&
          previous.lines[at].start == source.start &&
          previous.lines[at].text == source.text) {
        oldIndex = at;
      } else {
        final int shifted = source.start - charDelta;
        final int at2 = _sourceIndexAtOffset(previous.lines, shifted);
        if (at2 < previous.lines.length &&
            previous.lines[at2].start == shifted &&
            previous.lines[at2].text == source.text) {
          oldIndex = at2;
          oldDelta = charDelta;
        }
      }
    }
    if (oldIndex != null &&
        (oldIndex < 0 ||
            oldIndex >= previous.laidOut.length ||
            claimed.contains(oldIndex))) {
      oldIndex = null;
    }
    if (oldIndex != null) claimed.add(oldIndex);
    final LaidOutLine? old = oldIndex == null
        ? null
        : previous.laidOut[oldIndex];

    if (folds.hidden.contains(i)) {
      // 零高占位行：旧行也是隐藏行时可以连同空 painter 一起搬过来，否则新建。
      final bool reusePainter = old != null && old.hidden;
      final LaidOutLine hidden = _hiddenLine(
        source,
        top,
        baseStyle,
        textScaler,
        textDirection,
        reusePainter ? old.painter : null,
      );
      if (reusePainter) {
        stats?.reusedLines++;
      } else {
        if (old != null && !old.fromCache) old.painter.dispose();
        stats?.rebuiltLines++;
      }
      out.add(hidden);
      continue;
    }

    // 候选复用行：源码行本身必须没变，只有绝对偏移平移。
    final bool revealSame =
        old != null &&
        _revealSignature(old.source, revealBefore) ==
            _revealSignature(source, revealAfter);
    final bool markersInline =
        source.isList &&
        markerRevealLine != null &&
        markerRevealLine == source.start;
    // 落在强制重建区间（整张表 / 整个围栏块）的行即便源码一字未改也不能
    // 换壳复用：它们的测量结果依赖整块上下文。
    final bool forced =
        (forceFrom != null && i >= forceFrom && i <= forceTo!);
    if (old != null &&
        !forced &&
        !old.hidden &&
        revealSame &&
        old.slot.revealedMarkers == markersInline &&
        _sameSourceLine(old.source, source, oldDelta)) {
      final MarkerSlot bare = MarkerSlot(
        level: old.slot.level,
        indent: old.slot.indent,
        marker: old.slot.marker,
        digitWidth: old.slot.digitWidth,
      );
      final List<double> rails = _railsFor(
        source,
        sources,
        i,
        railCentres,
        bare,
        metrics,
      );
      final MarkerSlot slot = MarkerSlot(
        level: bare.level,
        indent: bare.indent,
        marker: bare.marker,
        digitWidth: bare.digitWidth,
        ownRailAbove:
            source.isList && bare.level > 0 && railCentres[bare.level] != null,
        railXs: rails,
        revealedMarkers: markersInline,
      );
      _updateRailCentres(source, slot, railCentres, metrics);
      final int shift = oldDelta;
      final LaidOutLine reused = LaidOutLine(
        source: source,
        top: top,
        height: old.height,
        slot: slot,
        insets: old.insets,
        painter: old.painter,
        visuals: shift == 0 ? old.visuals : _shiftVisuals(old.visuals, 0, shift),
        block: old.block,
        fills: old.fills,
        fromCache: old.fromCache,
        paintedFrom: old.paintedFrom + shift,
        fold: folds.byParent[i],
        folded: folds.foldedParents.contains(i),
      );
      reused.visualBaselines = old.visualBaselines;
      out.add(reused);
      stats?.reusedLines++;
      top += reused.height;
      continue;
    }

    // 需要重建的行：重新取样式、槽位与测量结果。
    final TextStyle style = styleFor?.call(source) ?? baseStyle;
    final MarkerSlot bare = _slotOf(
      source,
      style,
      text,
      textScaler,
      textDirection,
      metrics,
      const <double>[],
    );
    final List<double> rails = _railsFor(
      source,
      sources,
      i,
      railCentres,
      bare,
      metrics,
    );
    final MarkerSlot slot = MarkerSlot(
      level: bare.level,
      indent: bare.indent,
      marker: bare.marker,
      digitWidth: bare.digitWidth,
      ownRailAbove:
          source.isList && bare.level > 0 && railCentres[bare.level] != null,
      railXs: rails,
      revealedMarkers: markersInline,
    );
    _updateRailCentres(source, slot, railCentres, metrics);
    if (old != null && !old.fromCache) old.painter.dispose();
    final _LineMeasured measured = _measureOneLine(
      source: source,
      text: text,
      style: style,
      slot: slot,
      contentWidth: contentWidth,
      textScaler: textScaler,
      textDirection: textDirection,
      blockContext: blockContext,
      blockFor: blockFor,
      spanFor: spanFor,
      fillFor: fillFor,
      insetFor: insetFor,
      heightFor: heightFor,
      markersInline: markersInline,
      index: i,
      cache: null,
      stats: stats,
    );
    out.add(
      LaidOutLine(
        source: source,
        top: top,
        height: measured.height,
        slot: slot,
        insets: measured.insets,
        painter: measured.painter,
        visuals: measured.visuals,
        block: measured.block,
        fills: measured.fills,
        fold: folds.byParent[i],
        folded: folds.foldedParents.contains(i),
        paintedFrom: measured.paintedFrom,
      ),
    );
    stats?.rebuiltLines++;
    top += measured.height;
  }

  previous.handOverOwnership();
  return LineDocumentLayout._(
    text: text,
    lines: sources,
    laidOut: out,
    width: contentWidth,
    height: top,
    metrics: metrics,
    hiddenUnder: folds.hiddenUnder,
  );
}

/// 两行的源码内容与结构是否一致；[delta] 是行首偏移应有的平移量。
bool _sameSourceLine(SourceLine before, SourceLine after, int delta) =>
    after.text == before.text && _sameStructure(before, after, delta);

/// 两行的**结构**是否一致（不看正文）：种类、层级、序号、标记偏移。
///
/// 只改正文不该让整组列表重排——导轨与槽位只由结构决定；只有结构变了才需要
/// 把脏区扩到整个列表组。
bool _sameStructure(SourceLine before, SourceLine after, int delta) {
  return after.start == before.start + delta &&
      after.kind == before.kind &&
      after.headingLevel == before.headingLevel &&
      after.indent == before.indent &&
      after.nestLevel == before.nestLevel &&
      after.number == before.number &&
      after.checked == before.checked &&
      after.fenceOpens == before.fenceOpens &&
      after.markerStart - after.start == before.markerStart - before.start &&
      after.markerEnd - after.start == before.markerEnd - before.start &&
      after.leadEnd - after.start == before.leadEnd - before.start &&
      after.paintStart - after.start == before.paintStart - before.start;
}

/// 新文本里偏移 [offset] 落在（或刚越过）的源码行下标。
int _sourceIndexAtOffset(List<SourceLine> lines, int offset) {
  int lo = 0;
  int hi = lines.length - 1;
  while (lo < hi) {
    final int mid = (lo + hi + 1) >> 1;
    if (lines[mid].start <= offset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// dirty 区间 `[from, to]` 里是否有行结构变了（不再是同一行、列表几何变了）。
bool _structureChanged(
  LineDocumentLayout previous,
  List<SourceLine> sources,
  int from,
  int to,
) {
  if (sources.length != previous.lines.length) return true;
  for (int i = from; i <= to && i < sources.length; i++) {
    if (!_sameStructure(previous.lines[i], sources[i], 0)) return true;
  }
  return false;
}

/// 围栏块的开围栏行；找不到时退回 [i]（结构异常，交给逐行校验兜底）。
int _fenceBlockStart(List<SourceLine> lines, int i) {
  int j = i;
  while (j >= 0) {
    final SourceLine line = lines[j];
    if (line.kind == LineBlockKind.fence && line.fenceOpens) return j;
    if (j == 0) break;
    if (line.kind != LineBlockKind.fence && line.kind != LineBlockKind.code) {
      break;
    }
    j--;
  }
  return i;
}

/// 围栏块的闭合围栏行（未闭合时到文档末尾）。
int _fenceBlockEnd(List<SourceLine> lines, int i) {
  int j = i;
  while (j + 1 < lines.length) {
    final SourceLine next = lines[j + 1];
    if (next.kind != LineBlockKind.fence && next.kind != LineBlockKind.code) {
      break;
    }
    j++;
    if (next.kind == LineBlockKind.fence) break;
  }
  return j;
}

/// 列表组的起点：往上跳过列表行、空行与缩进续行。
int _railGroupStart(List<SourceLine> lines, int i) {
  int j = i;
  while (j > 0) {
    final SourceLine prev = lines[j - 1];
    if (prev.isList ||
        prev.text.trim().isEmpty ||
        prev.text.startsWith(RegExp(r'\s'))) {
      j--;
      continue;
    }
    break;
  }
  return j;
}

/// 列表组的终点：往下跳过列表行、空行与缩进续行。
int _railGroupEnd(List<SourceLine> lines, int i) {
  int j = i;
  while (j + 1 < lines.length) {
    final SourceLine next = lines[j + 1];
    if (next.isList ||
        next.text.trim().isEmpty ||
        next.text.startsWith(RegExp(r'\s'))) {
      j++;
      continue;
    }
    break;
  }
  return j;
}

/// 折叠规划：哪些行被藏起来、藏在哪一项下面、哪些项自己收起。
typedef _FoldPlan = ({
  Map<int, ListFold> byParent,
  Set<int> foldedParents,
  Set<int> hidden,
  Map<int, int> hiddenUnder,
});

_FoldPlan _planFolds(List<SourceLine> sources, Set<int> foldedLines) {
  final Map<int, ListFold> byParent = <int, ListFold>{
    for (final ListFold fold in scanListFolds(sources)) fold.parentIndex: fold,
  };
  final Set<int> hidden = <int>{};
  final Map<int, int> hiddenUnder = <int, int>{};
  final Set<int> foldedParents = <int>{};
  for (int i = 0; i < sources.length; i++) {
    final ListFold? fold = byParent[i];
    if (fold == null || hidden.contains(i)) continue;
    if (!foldedLines.contains(sources[i].start)) continue;
    foldedParents.add(i);
    for (int k = i + 1; k <= fold.lastIndex; k++) {
      hidden.add(k);
      hiddenUnder[k] = i;
    }
  }
  return (
    byParent: byParent,
    foldedParents: foldedParents,
    hidden: hidden,
    hiddenUnder: hiddenUnder,
  );
}

/// 零高占位行；[painter] 给定时直接借用（旧布局同为隐藏行）。
LaidOutLine _hiddenLine(
  SourceLine source,
  double top,
  TextStyle baseStyle,
  TextScaler textScaler,
  TextDirection textDirection, [
  TextPainter? painter,
]) {
  return LaidOutLine(
    source: source,
    top: top,
    height: 0,
    slot: MarkerSlot.none,
    painter:
        painter ??
        (TextPainter(
          text: TextSpan(text: '', style: baseStyle),
          textDirection: textDirection,
          textScaler: textScaler,
        )..layout()),
    visuals: <VisualLine>[
      VisualLine(
        index: 0,
        top: 0,
        height: 0,
        start: source.paintStart,
        end: source.end,
        width: 0,
      ),
    ],
    hidden: true,
  );
}

/// 一行在揭示选区下的签名；`(-1, -1, -1)` 表示这一行完全不受选区影响。
///
/// [a]/[b] 是选区与本行 `[start, end]` 的钳制交集，[caret] 是折叠光标落在
/// 本行时的偏移（非折叠选区为 -1）。`LiveLineStyle` 的选区依赖都由此导出：
/// 交集覆盖到行 → 块级标记摊开；交集落在某个行内 token 上 → token 露出源码；
/// 标签前缀被覆盖 → 左内边距收回。
typedef _RevealSignature = (int a, int b, int caret);

_RevealSignature _revealSignature(SourceLine line, TextSelection? selection) {
  if (selection == null || !selection.isValid || selection.start < 0) {
    return (-1, -1, -1);
  }
  if (selection.end < line.start || selection.start > line.end) {
    return (-1, -1, -1);
  }
  return (
    math.max(selection.start, line.start),
    math.min(selection.end, line.end),
    selection.isCollapsed ? selection.start : -1,
  );
}

/// 表格 run 的行种类：一张表的所有行。
bool _isTableLine(LineBlockKind kind) =>
    kind == LineBlockKind.table ||
    kind == LineBlockKind.tableHeader ||
    kind == LineBlockKind.tableDivider;

/// 一段样式的整行高度。
///
/// 空行没有任何字形，`TextPainter` 可能报 0 高；一行不能因此塌掉，
/// 否则空行上的光标和点击都会失效。
double _rowHeight(TextStyle style) {
  final double size = style.fontSize ?? 15;
  final double height = style.height ?? 1.2;
  return (size * height).roundToDouble();
}

/// 把一行的 [TextPainter] 切成视觉行。
List<VisualLine> _visualsOf(
  SourceLine source,
  TextPainter painter,
  double height,
  bool fixedHeight,
  double maxWidth,
  int paintedFrom,
) {
  final int paintedLength = source.end - paintedFrom;
  if (fixedHeight || paintedLength == 0) {
    return <VisualLine>[
      VisualLine(
        index: 0,
        top: 0,
        height: height,
        start: paintedFrom,
        end: source.end,
        width: 0,
      ),
    ];
  }

  final List<LineMetrics> metrics = painter.computeLineMetrics();
  if (metrics.isEmpty) {
    return <VisualLine>[
      VisualLine(
        index: 0,
        top: 0,
        height: height,
        start: paintedFrom,
        end: source.end,
        width: painter.width,
      ),
    ];
  }

  final List<VisualLine> out = <VisualLine>[];
  double top = 0;
  int cursor = 0;
  for (int i = 0; i < metrics.length; i++) {
    final line = metrics[i];
    final boundary = painter.getLineBoundary(TextPosition(offset: cursor));
    int from = boundary.start;
    int to = boundary.end;
    if (from < cursor) from = cursor;
    if (to <= from) {
      // 行尾空白被折行裁掉时 getLineBoundary 可能不前进。用右侧探测点兜底，
      // 至少保证视觉行区间单调递增，否则 offset↔point 会来回跳。
      final int probe = painter
          .getPositionForOffset(
            Offset(math.max(0, maxWidth - 0.01), top + line.height / 2),
          )
          .offset;
      to = probe.clamp(cursor + 1, paintedLength);
      from = cursor;
    }
    if (to > paintedLength) to = paintedLength;
    out.add(
      VisualLine(
        index: i,
        top: top,
        height: line.height,
        start: paintedFrom + from,
        end: paintedFrom + to,
        width: line.width,
      ),
    );
    top += line.height;
    cursor = to;
    if (cursor >= paintedLength) break;
  }

  // 最后一条视觉行必须覆盖到行尾，否则行尾的光标会落到不存在的区间。
  if (out.isNotEmpty && out.last.end < source.end) {
    final VisualLine last = out.last;
    out[out.length - 1] = VisualLine(
      index: last.index,
      top: last.top,
      height: last.height,
      start: last.start,
      end: source.end,
      width: last.width,
    );
  }
  return out;
}

/// span 树是否只改变颜色/底片等视觉属性，而不改变字体度量。
///
/// 普通段落也会被 `buildLiveInlineSpan` 包成 `TextSpan + children`，不能只看
/// `children == null`。这里逐层比对字号、字重、字体、字距、行高等真正参与
/// 排版的属性；代码 token 的颜色、标签底片都可以安全忽略。
bool _spanUsesBaseMetrics(InlineSpan span, TextStyle base) {
  if (span is! TextSpan) return false;
  final TextStyle? style = span.style;
  if (style != null && !_sameTextMetrics(style, base)) return false;
  final List<InlineSpan>? children = span.children;
  if (children == null) return true;
  for (final InlineSpan child in children) {
    if (!_spanUsesBaseMetrics(child, base)) return false;
  }
  return true;
}

/// 比较两段样式中会影响排版结果的字段，忽略前景/背景/装饰。
bool _sameTextMetrics(TextStyle style, TextStyle base) {
  if (style.foreground != null) return false;
  // 完全透明的字不落墨，却仍在排版里占位：它的显隐只改颜色，按度量比较会
  // 把整行当成可缓存行，光标移进来时复用旧 painter，`>` 这类标记就永远
  // 显不出来。引用前缀（keepMarkerWidth）和只保留行高的分隔行都属于这类。
  if (style.color != null && style.color!.a == 0) return false;
  return (style.fontSize ?? base.fontSize) == base.fontSize &&
      (style.fontWeight ?? base.fontWeight) == base.fontWeight &&
      (style.fontStyle ?? base.fontStyle) == base.fontStyle &&
      (style.fontFamily ?? base.fontFamily) == base.fontFamily &&
      listEquals(
        style.fontFamilyFallback ?? base.fontFamilyFallback,
        base.fontFamilyFallback,
      ) &&
      (style.letterSpacing ?? base.letterSpacing) == base.letterSpacing &&
      (style.wordSpacing ?? base.wordSpacing) == base.wordSpacing &&
      (style.textBaseline ?? base.textBaseline) == base.textBaseline &&
      (style.height ?? base.height) == base.height &&
      (style.leadingDistribution ?? base.leadingDistribution) ==
          base.leadingDistribution &&
      (style.locale ?? base.locale) == base.locale &&
      listEquals(style.fontFeatures ?? base.fontFeatures, base.fontFeatures) &&
      listEquals(
        style.fontVariations ?? base.fontVariations,
        base.fontVariations,
      );
}

/// 复用缓存视觉行时，把文档偏移从旧基准平移到新基准。
///
/// 在编辑点之后，整行的 `source.start` / `paintedFrom` 会一起偏移，视觉行
/// 的 `top/height/width` 不受影响，只需平移 `start/end`。
List<VisualLine> _shiftVisuals(List<VisualLine> visuals, int from, int to) {
  if (from == to) return visuals;
  final int delta = to - from;
  return <VisualLine>[
    for (final VisualLine v in visuals)
      VisualLine(
        index: v.index,
        top: v.top,
        height: v.height,
        start: v.start + delta,
        end: v.end + delta,
        width: v.width,
      ),
  ];
}

/// 一行的导轨 x。
///
/// 导轨对齐**标记的中心**（圆点、复选框、有序序号各自的中心），竖线从数字
/// 中间穿过去，而不是贴着左边把它切开。空行不打断列表栈，同级项被空行
/// 隔开时也把这一列接上。
List<double> _railsFor(
  SourceLine source,
  List<SourceLine> sources,
  int index,
  List<double?> centres,
  MarkerSlot slot,
  LineLayoutMetrics metrics,
) {
  double fallback(int level) =>
      level * metrics.indentStep + metrics.markerCentre;

  if (source.isList) {
    final int level = source.nestLevel;
    return <double>[
      for (int k = 0; k < level; k++) centres[k] ?? fallback(k),
      // 同级自己这一列：有同级项时接住条目之间的空档；有子项时从本项
      // 一直连到子项（长条目折行时第二行也要有线）。顶层的同级之间不画，
      // 免得整份文档在根层拖出一条长线。
      if ((level > 0 && _hasSiblingAtLevel(sources, index, level, centres)) ||
          _hasChildAtLevel(sources, index, level))
        _markerCentre(source, slot, metrics),
    ];
  }

  if (source.text.trim().isEmpty) {
    final int? next = _nextListLevel(sources, index);
    if (next == null) return const <double>[];
    // 空行把上下两项隔开时，竖线要一直延续到**同级**那一列：同级项自己
    // 的列就是它下面子项的导轨，断了会正好缺在 1. 和 2. 之间。
    int count = 0;
    for (int k = 0; k < centres.length; k++) {
      if (centres[k] != null) count = k + 1;
    }
    return <double>[for (int k = 0; k < count; k++) centres[k] ?? fallback(k)];
  }

  // 带缩进的非列表行是列表项自己的续行，不结束列表；只有顶格的行才把
  // 列表收起来，后面的空行不再继承导轨。
  if (source.text.startsWith(RegExp(r'\s'))) return const <double>[];
  centres.fillRange(0, centres.length, null);
  return const <double>[];
}

/// 记录本行标记的中心，供下一层导轨对齐；更深的兄弟层级就此结束。
///
/// 有序任务对齐**序号**的中心，不是复选框：复选框在序号右边 10px 开外，
/// 线画到那里会明显偏右、离开数字所在的列。
void _updateRailCentres(
  SourceLine source,
  MarkerSlot slot,
  List<double?> centres,
  LineLayoutMetrics metrics,
) {
  if (!source.isList) return;
  final int level = source.nestLevel;
  centres[level] = _markerCentre(source, slot, metrics);
  for (int k = level + 1; k < centres.length; k++) {
    centres[k] = null;
  }
}

/// 标记的中心 x。
///
/// 有序标记对齐的是**数字本身**的中心，不是整个前缀（`1. ` 含空白和点）
/// 的中心，也不是复选框中心——后者在序号右边 10px 开外。
double _markerCentre(
  SourceLine source,
  MarkerSlot slot,
  LineLayoutMetrics metrics,
) {
  final double digit = slot.digitWidth > 0 ? slot.digitWidth / 2 : 0;
  return switch (source.kind) {
    LineBlockKind.bullet => slot.indent + 2 + 2.5,
    LineBlockKind.ordered =>
      slot.indent + (digit > 0 ? digit : slot.marker / 2),
    LineBlockKind.task =>
      source.number == null
          ? slot.indent + metrics.markerCentre
          : slot.indent +
                (digit > 0 ? digit : (slot.marker - metrics.taskWidth) / 2),
    _ => slot.indent + metrics.markerCentre,
  };
}

/// 同一层是否还有别的列表项：前面已经记过同级中心，或后面还能遇到同级项。
///
/// 往下扫时跳过空行和带缩进的续行；遇到更深的层继续找（子项后面可能
/// 还有同级的 `2.`），遇到更浅的层或顶格的非列表行就说明这一组结束了。
bool _hasSiblingAtLevel(
  List<SourceLine> sources,
  int index,
  int level,
  List<double?> centres,
) {
  if (centres[level] != null) return true;
  for (int i = index + 1; i < sources.length; i++) {
    final SourceLine line = sources[i];
    if (line.text.trim().isEmpty) continue;
    if (line.isList) {
      if (line.nestLevel < level) return false;
      if (line.nestLevel == level) return true;
      continue;
    }
    if (line.text.startsWith(RegExp(r'\s'))) continue;
    return false;
  }
  return false;
}

/// 本项下面是否挂着子项：往下扫到的第一个列表行比它更深。
bool _hasChildAtLevel(List<SourceLine> sources, int index, int level) {
  for (int i = index + 1; i < sources.length; i++) {
    final SourceLine line = sources[i];
    if (line.text.trim().isEmpty) continue;
    if (line.isList) return line.nestLevel > level;
    if (line.text.startsWith(RegExp(r'\s'))) continue;
    return false;
  }
  return false;
}

/// 跳过空行，看下一条非空行是不是列表；不是就返回 `null`。
int? _nextListLevel(List<SourceLine> sources, int from) {
  for (int i = from + 1; i < sources.length; i++) {
    final SourceLine line = sources[i];
    if (!line.isList && line.text.trim().isEmpty) continue;
    return line.isList ? line.nestLevel : null;
  }
  return null;
}

/// 一行的标记槽位；非列表行没有槽位，但空行可以带导轨。
MarkerSlot _slotOf(
  SourceLine source,
  TextStyle style,
  String text,
  TextScaler textScaler,
  TextDirection textDirection,
  LineLayoutMetrics metrics,
  List<double> railXs,
) {
  if (!source.isList) return MarkerSlot(railXs: railXs);

  final int level = source.nestLevel;
  final double indent = level * metrics.indentStep;
  double marker;
  double digitWidth = 0;
  switch (source.kind) {
    case LineBlockKind.bullet:
      marker = metrics.bulletWidth;
    case LineBlockKind.ordered:
      marker = _measure(
        text.substring(source.markerStart, source.markerEnd),
        style,
        textScaler,
        textDirection,
      );
      digitWidth = _measure(
        source.number?.toString() ?? '',
        style,
        textScaler,
        textDirection,
      );
    case LineBlockKind.task:
      if (source.number == null) {
        marker = metrics.taskWidth;
      } else {
        // 有序任务：数字 + 空白 + 复选框。`leadEnd` 是 `[` 的位置。
        marker =
            _measure(
              text.substring(source.markerStart, source.leadEnd),
              style,
              textScaler,
              textDirection,
            ) +
            metrics.taskWidth;
        digitWidth = _measure(
          source.number?.toString() ?? '',
          style,
          textScaler,
          textDirection,
        );
      }
    default:
      marker = 0;
  }

  return MarkerSlot(
    level: level,
    indent: indent,
    marker: marker,
    digitWidth: digitWidth,
    railXs: railXs,
  );
}

/// 量一段标记源码的宽度。标记不属于正文，量完立即释放。
double _measure(
  String text,
  TextStyle style,
  TextScaler textScaler,
  TextDirection textDirection,
) {
  if (text.isEmpty) return 0;
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: textDirection,
    textScaler: textScaler,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width;
}
