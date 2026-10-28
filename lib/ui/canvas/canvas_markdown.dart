/// 卡片正文的 markdown 排版与绘制。
///
/// 卡片显示的是**笔记里那一段字排完之后的样子**，不是另一套「卡片排版」：
/// 标题阶梯、高亮色块、分隔线、序号槽位、代码块底片、表格网格全部走正文
/// 编辑器同一条管线（`layoutLines` + `LiveLineStyle` + `LiveTableBlocks`），
/// 连标记的像素常量都只有编辑器那一份。卡片和编辑器各写一套，用户一眼就能
/// 看出「白板里的 .md 和打开的 .md 不一样」——这正是这个文件存在的理由。
///
/// 排版在一个固定的**参考字号**（15.5px，编辑器默认正文）下进行，绘制时整块
/// 缩放到卡片字号（`AppText.ui * node.scale`）。缩进、槽位、圆角、内边距这些
/// 固定像素因此按同一個比例跟着缩，卡片放大一倍就是整张纸放大一倍，而不是
/// 「字大了、圆点还是 5px」。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../editor/code_block_painter.dart';
import '../editor/line_layout/line_layout_engine.dart';
import '../editor/line_layout/line_marker_style.dart';
import '../editor/line_layout/live_line_style.dart';
import '../editor/line_layout/render_line_editable.dart'
    show groupFillBoxesByLine;
import '../editor/live_markdown.dart';
import '../editor/markdown_editor.dart' show editorProseStyle;
import 'canvas_style.dart';

/// 参考正文的字号：编辑器默认的 `proseSize`。
///
/// 卡片正文显示的是 `AppText.ui * node.scale`（默认 13px），比编辑器小；
/// 在 15.5 下排完再整体缩放，字号的**比例**就和编辑器逐项一致（H1 是
/// 1.74 倍、代码是 0.84 倍、标签是胶囊里的 0.84 倍）。
const double _kRefProseSize = 15.5;

/// `==高亮==` 色块上下各内缩视觉行高的 16%。
///
/// 与按行渲染器（`render_line_editable.dart`）同一个数：底片比行盒矮一截，
/// 相邻两行的高亮之间才留得出呼吸位。
const double _kHighlightBandInsetY = 0.16;

/// 无序列表圆点直径（与编辑器一致）。
const double _kBulletDiameter = 5;

/// 复选框边长、左边距与圆角（与编辑器一致）。
const double _kCheckboxSize = 15;
const double _kCheckboxLeft = 2;
const double _kCheckboxRadius = 3;

/// 编辑器正文的基础样式。
///
/// 不用 [canvasCardTextStyle]：那是卡片**源码**（编辑态）的样式；渲染态要
/// 和编辑器逐项对齐，字号、行高、字距都直接取 `editorProseStyle`——那份
/// 样式是编辑器自己画正文用的唯一来源，抄一份到这里迟早会漂。
TextStyle _referenceProseStyle(AppPalette p) =>
    editorProseStyle(p, _kRefProseSize);

/// 代码块右上角语言标签的样式，抄自编辑器的 `CodeBlockPainter` 接线。
TextStyle _codeLabelStyle(AppPalette p) => TextStyle(
  fontFamily: AppFonts.ui,
  fontFamilyFallback: AppFonts.uiFallback,
  fontSize: AppText.caption,
  fontWeight: FontWeight.w500,
  letterSpacing: 0.2,
  color: p.textSecondary,
);

/// 表格的「纸面」：卡片自身合成之后的底色。
///
/// 编辑器里表格纸面就是编辑区本身（[AppPalette.surface]）；卡片是半透明的
/// [CanvasStyle.cardFill] 叠在画布上，所以要把这一层先合成出来，表格才不会
/// 在卡片里浮出一块比卡片更暗的矩形。
Color _tablePaperOf(AppPalette p) {
  final CanvasStyle style = CanvasStyle.of(p);
  return Color.alphaBlend(style.cardFill, style.background);
}

/// 一段卡片正文的排版结果，外加把它画出来的全部几何。
///
/// 宽高是**世界坐标**（卡片自己的坐标系），`layout` 里的一切是参考坐标系
/// （15.5px 正文）；两者的比例就是 [renderScale]。
class CanvasMarkdownDocument {
  CanvasMarkdownDocument._({
    required this.text,
    required this.scale,
    required this.width,
    required this.height,
    required this.renderScale,
    required this.fitMaxWidth,
    required this.layout,
    required this.tables,
    required this.codeRanges,
    required this.palette,
    required this.markers,
  });

  /// 源 markdown。
  final String text;

  /// 卡片字号倍率（`TextNode.scale`，文件卡片恒为 1）。
  final double scale;

  /// 排出来的正文宽（世界坐标）。
  final double width;

  /// 排出来的正文高（世界坐标，含末尾代码块的底部留白）。
  final double height;

  /// 参考字号 → 卡片字号的比例。
  final double renderScale;

  /// 求宽度时用的折行上限（世界坐标）；[atWidth] 造出来的文档是 `-1`。
  final double fitMaxWidth;

  final LineDocumentLayout layout;
  final LiveTableBlocks tables;
  final List<CodeBlockRange> codeRanges;
  final AppPalette palette;

  /// 列表圆点、序号、复选框、引用竖线、分隔线的颜色与字重。
  final LineMarkerStyle markers;

  /// 语言标签的排版结果按文本缓存，随文档一起释放。
  final Map<String, TextPainter> _labels = <String, TextPainter>{};

  bool _disposed = false;

  /// 这份文档是不是就是「这段文字、这个倍率、这个宽度、这个主题」的排版。
  bool matches({
    required String text,
    required double scale,
    required double width,
    required AppPalette palette,
  }) =>
      this.text == text &&
      this.scale == scale &&
      identical(this.palette, palette) &&
      (this.width - width).abs() <= 0.5;

  /// 这份文档是不是 [measure] 用同一组输入量出来的。
  bool matchesFit({
    required String text,
    required double scale,
    required double maxWidth,
    required AppPalette palette,
  }) =>
      fitMaxWidth >= 0 &&
      this.text == text &&
      this.scale == scale &&
      identical(this.palette, palette) &&
      (fitMaxWidth - maxWidth).abs() <= 0.01;

  /// 量一段正文：先按最大宽度排一遍，取出最宽的一行，再按那个宽度重排。
  ///
  /// 两遍是必须的：第一遍里的行都按上限折行，量到的宽度是「折行后的宽度」，
  /// 用它当卡片宽会让每张卡都顶满 [canvasTextMaxWidth]；第二遍把卡片收到
  /// 内容宽度，整篇的全宽装饰（分隔线、代码底片、选区色带）才能正好铺在
  /// 卡片里。内容本来就顶满上限时第一遍就是终稿，不再重排。
  static CanvasMarkdownDocument measure({
    required String text,
    required double scale,
    required double maxWidth,
    required AppPalette palette,
  }) {
    final double renderScale = _renderScaleOf(scale);
    final double refMax = math.max(1, maxWidth / renderScale);
    final CanvasMarkdownDocument probe = _build(
      text: text,
      scale: scale,
      refWidth: refMax,
      palette: palette,
      fitMaxWidth: maxWidth,
    );
    final double fitRef = probe._fitWidth();
    if (fitRef >= probe.layout.width - 0.001) return probe;
    probe.dispose();
    return _build(
      text: text,
      scale: scale,
      refWidth: math.max(1, fitRef),
      palette: palette,
      fitMaxWidth: maxWidth,
    );
  }

  /// 在已知正文宽度的场合（绘制、手动拉宽过的卡片）直接按那个宽度排。
  static CanvasMarkdownDocument atWidth({
    required String text,
    required double scale,
    required double width,
    required AppPalette palette,
  }) => _build(
    text: text,
    scale: scale,
    refWidth: math.max(1, width / _renderScaleOf(scale)),
    palette: palette,
    fitMaxWidth: -1,
  );

  static double _renderScaleOf(double scale) =>
      math.max(0.01, AppText.ui * scale / _kRefProseSize);

  static CanvasMarkdownDocument _build({
    required String text,
    required double scale,
    required double refWidth,
    required AppPalette palette,
    required double fitMaxWidth,
  }) {
    final TextStyle base = _referenceProseStyle(palette);
    final LiveLineStyle live = LiveLineStyle(
      base: base,
      palette: palette,
      source: text,
    );
    final LiveTableBlocks tables = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      // 卡片没有选区，也没有揭示态：整篇都按「完成」的样子排。
      selection: () => null,
      paper: _tablePaperOf(palette),
    );
    final LineDocumentLayout layout = layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: refWidth,
      styleFor: live.styleFor,
      heightFor: live.heightFor,
      spanFor: live.spanFor,
      fillFor: live.fillsFor,
      insetFor: live.insetFor,
      blockFor: tables.blockFor,
    );
    final List<CodeBlockRange> ranges = codeBlockRanges(text);
    final double renderScale = _renderScaleOf(scale);

    // 关闭围栏压成 0 高，末块代码就没有自己的底边；底片的下留白得算进
    // 文档高度，否则卡片会把最后 12px 的圆角底裁掉。
    double heightRef = layout.height;
    for (final CodeBlockRange range in ranges) {
      final Rect? rows = layout.blockRect(range.start, range.end);
      if (rows != null) {
        heightRef = math.max(heightRef, rows.bottom + kCodeSlabBottomPad);
      }
    }

    return CanvasMarkdownDocument._(
      text: text,
      scale: scale,
      width: layout.width * renderScale,
      height: heightRef * renderScale,
      renderScale: renderScale,
      fitMaxWidth: fitMaxWidth,
      layout: layout,
      tables: tables,
      codeRanges: ranges,
      palette: palette,
      markers: live.markers,
    );
  }

  /// 内容自然宽度（参考坐标），压到当前排版宽度以内。
  ///
  /// 只有真正占像素的字算宽：折叠的围栏行没有墨迹，分隔线、代码底片是
  /// 整行铺满的装饰，它们跟着卡片走、不该把卡片撑到上限。表格按它自己
  /// 量出来的宽度参与，代码按最长的一行参与。
  double _fitWidth() {
    final double maxRef = layout.width;
    final double slack = canvasTextFitSlack / renderScale;
    double widest = 0;
    bool anyInk = false;
    bool fullWidth = false;

    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0) continue;
      switch (line.source.kind) {
        case LineBlockKind.rule:
        case LineBlockKind.fence:
          fullWidth = true;
        case LineBlockKind.setext:
        case LineBlockKind.tableDivider:
          break;
        case LineBlockKind.table:
        case LineBlockKind.tableHeader:
          final LineBlockView? block = line.block;
          if (block != null) {
            widest = math.max(widest, line.gutter + block.width);
            anyInk = true;
          }
        case LineBlockKind.heading:
        case LineBlockKind.paragraph:
        case LineBlockKind.bullet:
        case LineBlockKind.ordered:
        case LineBlockKind.task:
        case LineBlockKind.quote:
        case LineBlockKind.code:
          final double ink = _inkWidth(line);
          widest = math.max(widest, ink);
          anyInk = anyInk || ink > 0;
      }
    }

    // 一行字都没有、只有一条分隔线（或空代码块）时没有自然宽度可依：
    // 那种卡片就该占满上限，否则线会缩成一个点。
    if (!anyInk) return fullWidth ? maxRef : math.min(maxRef, slack);
    return math.min(maxRef, widest + slack);
  }

  /// 一行字实际占的宽度：正文列 + 字形宽 + 右侧内边距 + 末尾底片的外扩。
  double _inkWidth(LaidOutLine line) {
    double width = line.gutter + line.painter.width + line.insets.right;
    final int length = line.painter.text?.toPlainText().length ?? 0;
    for (final LineFillRun run in line.fills) {
      // 底片在字后面还有 padX 的外扩；行末的胶囊没有下一个字可借位，
      // 不让出这几像素，卡片会把胶囊右缘裁掉。
      if (run.to >= length) width += run.padX;
    }
    return width;
  }

  /// 画在卡片正文区左上角（世界坐标）。
  void paint(Canvas canvas, Offset origin) {
    if (text.isEmpty || _disposed) return;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(renderScale);

    _paintCodeSlabs(canvas);

    // 表格自己画网格、文字、纸面；它需要一个全局原点来把 1px 网格对到
    // 设备像素上，和编辑器里的调用方式一致。
    final Matrix4 matrix = Matrix4.fromFloat64List(canvas.getTransform());
    for (final LaidOutLine line in layout.laidOut) {
      final LineBlockView? block = line.block;
      if (block == null || line.height <= 0) continue;
      final Offset local = Offset(line.gutter, line.top);
      block.paint(canvas, local, MatrixUtils.transformPoint(matrix, local));
    }

    _paintMarkers(canvas);
    _paintFills(canvas);

    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0 || line.block != null) continue;
      line.painter.paint(
        canvas,
        Offset(line.gutter, line.top - lineTextRise(line)),
      );
    }

    canvas.restore();
  }

  /// 每个围栏代码块一块圆角底片 + 右上角语言标签。
  void _paintCodeSlabs(Canvas canvas) {
    if (codeRanges.isEmpty) return;
    final Paint paint = Paint()..color = codeSlabFill(palette);
    for (final CodeBlockRange range in codeRanges) {
      final Rect? rows = layout.blockRect(range.start, range.end);
      if (rows == null) continue;
      final Rect slab = Rect.fromLTRB(
        0,
        rows.top - kCodeSlabTopPad,
        layout.width,
        rows.bottom + kCodeSlabBottomPad,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(slab, const Radius.circular(kCodeSlabRadius)),
        paint,
      );

      final String? label = range.label;
      if (label == null) continue;
      final TextPainter tp = _labels.putIfAbsent(
        label,
        () => TextPainter(
          text: TextSpan(text: label, style: _codeLabelStyle(palette)),
          textDirection: TextDirection.ltr,
        )..layout(),
      );
      tp.paint(
        canvas,
        Offset(
          slab.right - kCodeSlabLabelRight - tp.width,
          slab.top + kCodeSlabLabelTop,
        ),
      );
    }
  }

  // -------------------------------------------------------- 列表标记与导轨
  //
  // 这里是按行渲染器 `_paintMarkers` 的同一份几何：圆点 5px、复选框 15px、
  // 序号按正文首行基线对齐、引用的竖线离正文列 2px。卡片里没有「揭示」
  // 这回事，所以不用判 `_sourceShown`——所有标记都按完成态画。

  void _paintMarkers(Canvas canvas) {
    final LineMarkerStyle style = markers;
    final Paint rail = Paint()..color = style.rail;
    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0) continue;
      _paintRails(canvas, line, rail);
      if (line.slot.revealedMarkers) continue;

      final SourceLine source = line.source;
      if (source.kind == LineBlockKind.rule) {
        // 1px 的线落在像素栅格上：半像素的位置会被抗锯齿摊成两行灰。
        final double y = (line.top + line.height / 2).floorToDouble();
        canvas.drawRect(
          Rect.fromLTWH(0, y, math.max(0, layout.width), 1),
          rail,
        );
        continue;
      }
      if (source.kind == LineBlockKind.quote) {
        if (line.visuals.isEmpty) continue;
        final VisualLine first = line.visuals.first;
        final VisualLine last = line.visuals.last;
        canvas.drawRect(
          Rect.fromLTWH(2, line.top + first.top, 2, last.bottom - first.top),
          Paint()..color = style.accent,
        );
        continue;
      }
      if (!source.isList) continue;

      final VisualLine first = line.visuals.first;
      final double middle = line.top + first.top + first.height / 2;
      switch (source.kind) {
        case LineBlockKind.bullet:
          canvas.drawCircle(
            Offset(line.markerOrigin + 2 + _kBulletDiameter / 2, middle),
            _kBulletDiameter / 2,
            Paint()..color = style.bullet,
          );
        case LineBlockKind.ordered:
          _paintNumber(
            canvas,
            line,
            style,
            end: source.markerEnd,
            checked: false,
          );
        case LineBlockKind.task:
          if (source.number != null) {
            _paintNumber(
              canvas,
              line,
              style,
              end: source.leadEnd,
              checked: source.checked,
            );
          }
          _paintCheckbox(
            canvas,
            _checkboxRectOf(line, layout.metrics),
            source.checked,
            style,
          );
        case LineBlockKind.paragraph:
        case LineBlockKind.heading:
        case LineBlockKind.fence:
        case LineBlockKind.code:
        case LineBlockKind.quote:
        case LineBlockKind.rule:
        case LineBlockKind.setext:
        case LineBlockKind.table:
        case LineBlockKind.tableHeader:
        case LineBlockKind.tableDivider:
          break;
      }
    }
  }

  /// 每一级祖先的导轨；自己那一列在字形上下断开（同编辑器）。
  void _paintRails(Canvas canvas, LaidOutLine line, Paint paint) {
    final double markerLeft = line.markerOrigin;
    final double markerRight = line.markerOrigin + line.slot.marker;
    double? glyphTop;
    double? glyphBottom;
    if (line.source.isList) {
      final double baseline =
          line.top +
          line.painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      final double size = line.painter.text?.style?.fontSize ?? 15;
      glyphTop = baseline - size * 0.68;
      glyphBottom = baseline + size * 0.08;
    }
    final double shift = line.insets.left;
    for (final double rail in line.slot.railXs) {
      final double x = rail + shift;
      final bool own = x > markerLeft && x < markerRight;
      if (own && line.slot.revealedMarkers) continue;
      if (own && glyphTop != null && glyphBottom != null) {
        if (line.slot.ownRailAbove) {
          canvas.drawRect(
            Rect.fromLTWH(x - 0.5, line.top, 1, glyphTop - line.top),
            paint,
          );
        }
        canvas.drawRect(
          Rect.fromLTWH(
            x - 0.5,
            glyphBottom,
            1,
            line.top + line.height - glyphBottom,
          ),
          paint,
        );
        continue;
      }
      canvas.drawRect(Rect.fromLTWH(x - 0.5, line.top, 1, line.height), paint);
    }
  }

  /// 有序列表的序号，基线对齐正文首行。
  void _paintNumber(
    Canvas canvas,
    LaidOutLine line,
    LineMarkerStyle style, {
    required int end,
    required bool checked,
  }) {
    final int from = line.source.markerStart;
    if (end <= from) return;
    final TextStyle text = checked
        ? style.number.copyWith(
            color: style.muted,
            decoration: TextDecoration.lineThrough,
            decorationThickness: 2,
            decorationColor: style.muted,
          )
        : style.number;
    final TextPainter painter = TextPainter(
      text: TextSpan(text: layout.text.substring(from, end), style: text),
      textDirection: TextDirection.ltr,
    )..layout();

    final double bodyBaseline = line.painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final double numberBaseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    painter.paint(
      canvas,
      Offset(
        line.markerOrigin,
        line.top - lineTextRise(line) + bodyBaseline - numberBaseline,
      ),
    );
    painter.dispose();
  }

  /// 任务项的复选框：未勾选是描边空框，勾选是强调色实心块加一个勾。
  void _paintCheckbox(
    Canvas canvas,
    Rect rect,
    bool done,
    LineMarkerStyle style,
  ) {
    final RRect box = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(_kCheckboxRadius),
    );
    if (!done) {
      canvas.drawRRect(
        box.deflate(0.75),
        Paint()
          ..color = style.boxBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      return;
    }

    canvas.drawRRect(box, Paint()..color = style.accent);
    final Path check = Path()
      ..moveTo(rect.left + 4, rect.top + 7.6)
      ..lineTo(rect.left + 6.4, rect.top + 10.1)
      ..lineTo(rect.left + 11, rect.top + 4.7);
    canvas.drawPath(
      check,
      Paint()
        ..color = style.onAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  static Rect _checkboxRectOf(LaidOutLine line, LineLayoutMetrics metrics) {
    final VisualLine first = line.visuals.first;
    final double middle = line.top + first.top + first.height / 2;
    final double lead = math.max(0, line.slot.marker - metrics.taskWidth);
    return Rect.fromLTWH(
      line.markerOrigin + lead + _kCheckboxLeft,
      middle - _kCheckboxSize / 2,
      _kCheckboxSize,
      _kCheckboxSize,
    );
  }

  /// 行内代码、`#标签`、`==高亮==` 的圆角底片，铺在文字下面。
  void _paintFills(Canvas canvas) {
    final Paint paint = Paint();
    for (final LaidOutLine line in layout.laidOut) {
      if (line.fills.isEmpty || line.height <= 0) continue;
      final TextPainter tp = line.painter;
      final Offset origin = Offset(line.gutter, line.top - lineTextRise(line));
      for (final LineFillRun run in line.fills) {
        final List<TextBox> boxes = tp.getBoxesForSelection(
          TextSelection(baseOffset: run.from, extentOffset: run.to),
        );
        if (boxes.isEmpty) continue;
        double? height = run.measuredHeight;
        double? drop = run.measuredDrop;
        if (!run.rowBox && (height == null || drop == null)) {
          final TextPainter metrics = TextPainter(
            text: TextSpan(
              text: run.probe.isEmpty ? ' ' : run.probe,
              style: run.style,
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          height = metrics.height + run.padY * 2;
          drop = metrics.computeDistanceToActualBaseline(
            TextBaseline.alphabetic,
          );
          metrics.dispose();
          run.measuredHeight = height;
          run.measuredDrop = drop;
        }
        paint.color = run.fill;

        // 一条代码可以折行：每个视觉行各铺一块，分组依据是视觉行而不是
        // 盒子的 top（零号字的反引号与正文字号不同，盒子上下沿对不齐）。
        final List<double> baselines = line.visualBaselines ??= <double>[
          for (final LineMetrics metrics in tp.computeLineMetrics())
            metrics.baseline,
        ];
        final List<({int line, double left, double right})> groups =
            groupFillBoxesByLine(boxes, baselines);
        for (final ({int line, double left, double right}) group in groups) {
          final double top;
          final double bottom;
          if (run.rowBox) {
            final VisualLine visual = line.visuals[group.line];
            final double insetY = visual.height * _kHighlightBandInsetY;
            top = line.top + visual.top + insetY;
            bottom = line.top + visual.top + visual.height - insetY;
          } else {
            final double baseline = baselines[group.line];
            top = origin.dy + baseline - drop! - run.padY;
            bottom = top + height!;
          }
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTRB(
                math.max(0, origin.dx + group.left - run.padX),
                top,
                math.min(layout.width, origin.dx + group.right + run.padX),
                bottom,
              ),
              Radius.circular(run.radius),
            ),
            paint,
          );
        }
      }
    }
  }

  /// 画面上看得见的文字：折叠的标记、围栏、分隔线不落墨，也不该出现在这里。
  ///
  /// 调试与测试用（`CanvasBoard.debugFileBody`）：「卡片上现在写的是什么」。
  /// 表格的文字由自绘行负责，这一段拿不到，只能跳过。
  String get visibleText {
    final StringBuffer out = StringBuffer();
    bool first = true;
    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0 || line.block != null) continue;
      // 围栏行是代码底片的头，不是一段文字：它既有行高又没有字，留在
      // 这里会凭空多出一个空行。
      if (line.source.kind == LineBlockKind.fence) continue;
      if (!first) out.write('\n');
      first = false;
      out.write(_visibleTextOf(line.painter.text!));
    }
    return out.toString();
  }

  /// 只收「有墨」的 span：零号字与全透明是标记被折叠后的样子。
  String _visibleTextOf(InlineSpan span, [TextStyle? inherited]) {
    final TextStyle? style = span.style ?? inherited;
    if (style != null &&
        (style.color == const Color(0x00000000) ||
            (style.fontSize ?? 1) <= 0)) {
      return '';
    }
    if (span is! TextSpan) return span.toPlainText();
    final StringBuffer out = StringBuffer();
    final String? own = span.text;
    if (own != null) out.write(own);
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      out.write(_visibleTextOf(child, style));
    }
    return out.toString();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final TextPainter label in _labels.values) {
      label.dispose();
    }
    _labels.clear();
    tables.dispose();
    layout.dispose();
  }
}

/// 每张卡片一份 [CanvasMarkdownDocument]，跨帧复用。
///
/// 排版一次就要扫全文、建几十上百个 `TextPainter`；卡片每帧都会重画，所以
/// 键是「节点 id + 用途」（`node-…` / `file-body-…`），文字、倍率、宽度、
/// 主题任一变化才重排。
class CanvasMarkdownCache {
  final Map<String, CanvasMarkdownDocument> _entries =
      <String, CanvasMarkdownDocument>{};

  /// 绘制入口：宽度就是卡片当前正文宽。
  CanvasMarkdownDocument get(
    String key, {
    required String text,
    required double scale,
    required double width,
    required AppPalette palette,
  }) {
    final CanvasMarkdownDocument? old = _entries[key];
    if (old != null &&
        old.matches(text: text, scale: scale, width: width, palette: palette)) {
      return old;
    }
    old?.dispose();
    final CanvasMarkdownDocument doc = CanvasMarkdownDocument.atWidth(
      text: text,
      scale: scale,
      width: width,
      palette: palette,
    );
    _entries[key] = doc;
    return doc;
  }

  /// 贴合入口：返回内容自然宽高（世界坐标），并把终稿留在缓存里给绘制用。
  ({double width, double height}) fit(
    String key, {
    required String text,
    required double scale,
    required double maxWidth,
    required AppPalette palette,
  }) {
    final CanvasMarkdownDocument? old = _entries[key];
    if (old != null &&
        old.matchesFit(
          text: text,
          scale: scale,
          maxWidth: maxWidth,
          palette: palette,
        )) {
      return (width: old.width, height: old.height);
    }
    old?.dispose();
    final CanvasMarkdownDocument doc = CanvasMarkdownDocument.measure(
      text: text,
      scale: scale,
      maxWidth: maxWidth,
      palette: palette,
    );
    _entries[key] = doc;
    return (width: doc.width, height: doc.height);
  }

  /// 某个键现在排出来的可见文字；文字对不上（还没重排）时返回 `null`。
  String? visibleText(String key, String text) {
    final CanvasMarkdownDocument? doc = _entries[key];
    if (doc == null || doc.text != text) return null;
    return doc.visibleText;
  }

  void dispose() {
    for (final CanvasMarkdownDocument doc in _entries.values) {
      doc.dispose();
    }
    _entries.clear();
  }
}
