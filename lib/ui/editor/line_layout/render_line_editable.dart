/// 按行渲染的可编辑文本。
///
/// `RenderEditable` 整篇只有一个 `TextPainter`，段落里的软换行永远回到段落
/// 左边缘——列表的续行因此会钻到序号下面。这里不替换 `RenderEditable` 的
/// 输入法/选区/手势，只把「排版 + 几何 + 绘制」换成
/// [LineDocumentLayout]：一个源码行一个 `TextPainter`，列表行的正文从
/// `slot.width` 起排，续行自然从正文列开始。
///
/// 其余成员（事件处理、语义、滚动、光标闪烁）全部继承自 `RenderEditable`。
/// 为了让继承来的方法（`startVerticalCaretMovement`、`getWordBoundary`、
/// `selectPositionAt` 等）不因 `_textPainter` 未布局而崩溃，`performLayout`
/// 会先跑一遍 `super.performLayout()`，再用行布局覆盖 `size` 与滚动范围。
/// 两套几何的差异只影响**绘制与命中**：绘制层（选区洗色、代码块卡片、复选框
/// 命中）读的是本文件给出的 `lineLayout` / `selectionBands` / `blockRectFor` /
/// `positionAt`，不再经过单段盒模型。
library;

import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'line_layout_engine.dart';
import 'line_marker_style.dart';

/// 一条可折叠列表项在屏幕上的落点，坐标已换算成全局坐标。
///
/// 箭头是画出来的（`ListFoldPainter`），没有 widget 可以 `getRect`，所以
/// 命中与悬停都问渲染对象要这两个矩形：与用户看到的位置逐像素一致。
class ListFoldHandle {
  const ListFoldHandle({
    required this.lineStart,
    required this.lineEnd,
    required this.hiddenEnd,
    required this.folded,
    required this.button,
    required this.row,
    this.ellipsis,
  });

  /// 列表项行首的源码偏移，也是折叠状态的键。
  final int lineStart;

  /// 列表项这一行源码的末尾（换行符之前）。
  final int lineEnd;

  /// 子树最后一行的末尾；收起时落在 `(lineEnd, hiddenEnd]` 的光标都算
  /// 藏进了折叠区。
  final int hiddenEnd;

  final bool folded;

  /// 箭头按钮（16 × 20），在标记槽位左侧、页边距里。
  final Rect button;

  /// 这一行（含折行）的整条横带，用来判断箭头该不该因悬停显形。
  final Rect row;

  /// 收起时接在正文末尾的省略号左上角（全局坐标）；展开时为 `null`。
  ///
  /// 省略号不在源码里，也不进排版：它是折叠状态的提示，由
  /// `ListFoldPainter` 画在字后面，不参与选区与命中。
  final Offset? ellipsis;
}

class RenderLineEditable extends RenderEditable {
  // 纯粹转发参数给 super，保持与 SDK 构造函数逐项一致，便于升级时对比。
  // ignore: use_super_parameters
  RenderLineEditable({
    InlineSpan? text,
    required TextDirection textDirection,
    TextAlign textAlign = TextAlign.start,
    Color? cursorColor,
    Color? backgroundCursorColor,
    ValueNotifier<bool>? showCursor,
    bool? hasFocus,
    required LayerLink startHandleLayerLink,
    required LayerLink endHandleLayerLink,
    int? maxLines = 1,
    int? minLines,
    bool expands = false,
    StrutStyle? strutStyle,
    Color? selectionColor,
    TextScaler textScaler = TextScaler.noScaling,
    TextSelection? selection,
    required ViewportOffset offset,
    bool ignorePointer = false,
    bool readOnly = false,
    bool forceLine = true,
    TextHeightBehavior? textHeightBehavior,
    TextWidthBasis textWidthBasis = TextWidthBasis.parent,
    String obscuringCharacter = '•',
    bool obscureText = false,
    Locale? locale,
    double cursorWidth = 1.0,
    double? cursorHeight,
    Radius? cursorRadius,
    bool paintCursorAboveText = false,
    Offset cursorOffset = Offset.zero,
    double devicePixelRatio = 1.0,
    BoxHeightStyle selectionHeightStyle = BoxHeightStyle.max,
    BoxWidthStyle selectionWidthStyle = BoxWidthStyle.max,
    bool? enableInteractiveSelection,
    EdgeInsets floatingCursorAddedMargin = const EdgeInsets.fromLTRB(
      4,
      4,
      4,
      5,
    ),
    TextRange? promptRectRange,
    Color? promptRectColor,
    Clip clipBehavior = Clip.hardEdge,
    required TextSelectionDelegate textSelectionDelegate,
    RenderEditablePainter? painter,
    RenderEditablePainter? foregroundPainter,
    List<RenderBox>? children,
    LineStyleResolver? lineStyleFor,
    LineHeightResolver? lineHeightFor,
    LineSpanResolver? lineSpanFor,
    LineFillResolver? lineFillFor,
    LineInsetResolver? lineInsetFor,
    TextSelection? revealSelection,
    int? markerRevealLine,
    Set<int>? foldedLines,
    LineMarkerStyle? markerStyle,
    LineBlockResolver? lineBlockFor,
  }) : // 私有字段不能做命名参数，只能在这里赋值。
       // ignore: prefer_initializing_formals
       _explicitCursorHeight = cursorHeight,
       // ignore: prefer_initializing_formals
       _foldedLines = foldedLines ?? const <int>{},
       // ignore: prefer_initializing_formals
       _lineStyleFor = lineStyleFor,
       // ignore: prefer_initializing_formals
       _lineHeightFor = lineHeightFor,
       // ignore: prefer_initializing_formals
       _lineSpanFor = lineSpanFor,
       // ignore: prefer_initializing_formals
       _lineFillFor = lineFillFor,
       // ignore: prefer_initializing_formals
       _lineInsetFor = lineInsetFor,
       // ignore: prefer_initializing_formals
       _revealSelection = revealSelection,
       // ignore: prefer_initializing_formals
       _markerRevealLine = markerRevealLine,
       // ignore: prefer_initializing_formals
       _markerStyle = markerStyle,
       // ignore: prefer_initializing_formals
       _lineBlockFor = lineBlockFor,
       super(
         text: text,
         textDirection: textDirection,
         textAlign: textAlign,
         cursorColor: cursorColor,
         backgroundCursorColor: backgroundCursorColor,
         showCursor: showCursor,
         hasFocus: hasFocus,
         startHandleLayerLink: startHandleLayerLink,
         endHandleLayerLink: endHandleLayerLink,
         maxLines: maxLines,
         minLines: minLines,
         expands: expands,
         strutStyle: strutStyle,
         selectionColor: selectionColor,
         textScaler: textScaler,
         selection: selection,
         offset: offset,
         ignorePointer: ignorePointer,
         readOnly: readOnly,
         forceLine: forceLine,
         textHeightBehavior: textHeightBehavior,
         textWidthBasis: textWidthBasis,
         obscuringCharacter: obscuringCharacter,
         obscureText: obscureText,
         locale: locale,
         cursorWidth: cursorWidth,
         cursorHeight: cursorHeight,
         cursorRadius: cursorRadius,
         paintCursorAboveText: paintCursorAboveText,
         cursorOffset: cursorOffset,
         devicePixelRatio: devicePixelRatio,
         selectionHeightStyle: selectionHeightStyle,
         selectionWidthStyle: selectionWidthStyle,
         enableInteractiveSelection: enableInteractiveSelection,
         floatingCursorAddedMargin: floatingCursorAddedMargin,
         promptRectRange: promptRectRange,
         promptRectColor: promptRectColor,
         clipBehavior: clipBehavior,
         textSelectionDelegate: textSelectionDelegate,
         painter: painter,
         foregroundPainter: foregroundPainter,
         children: children,
       );

  LineDocumentLayout? _lineLayout;

  /// 跨轮布局复用的 painter 池；样式、宽度或文字变化时由键自然失效。
  final LineLayoutCache _lineCache = LineLayoutCache();
  String? _layoutText;
  TextStyle? _layoutStyle;
  double? _layoutWidth;

  /// 宿主显式给的光标高度；`null` 表示逐行跟随（见 [_caretHeightOf]）。
  double? _explicitCursorHeight;

  @override
  set cursorHeight(double? value) {
    _explicitCursorHeight = value;
    super.cursorHeight = value;
  }

  /// 按行取排版样式；`null` 时整篇使用 [text] 的样式。
  LineStyleResolver? get lineStyleFor => _lineStyleFor;
  LineStyleResolver? _lineStyleFor;
  set lineStyleFor(LineStyleResolver? value) {
    if (value == _lineStyleFor) return;
    _lineStyleFor = value;
    _dropLineLayout();
  }

  /// 按行取固定行高；`null` 表示按测量结果（折叠的围栏行是唯一的使用者）。
  LineHeightResolver? get lineHeightFor => _lineHeightFor;
  LineHeightResolver? _lineHeightFor;
  set lineHeightFor(LineHeightResolver? value) {
    if (value == _lineHeightFor) return;
    _lineHeightFor = value;
    _dropLineLayout();
  }

  /// 按行取 span 树；`null` 时用 [lineStyleFor] 的样式排纯文本。
  LineSpanResolver? get lineSpanFor => _lineSpanFor;
  LineSpanResolver? _lineSpanFor;
  set lineSpanFor(LineSpanResolver? value) {
    if (value == _lineSpanFor) return;
    _lineSpanFor = value;
    _dropLineLayout();
  }

  /// 按行取自绘内容（实时表格行）；`null` 表示所有行都排文字。
  LineBlockResolver? get lineBlockFor => _lineBlockFor;
  LineBlockResolver? _lineBlockFor;
  set lineBlockFor(LineBlockResolver? value) {
    if (value == _lineBlockFor) return;
    _lineBlockFor = value;
    _dropLineLayout();
  }

  /// 按行取圆角底片（行内代码）；`null` 表示不铺底片。
  LineFillResolver? get lineFillFor => _lineFillFor;
  LineFillResolver? _lineFillFor;
  set lineFillFor(LineFillResolver? value) {
    if (value == _lineFillFor) return;
    _lineFillFor = value;
    _dropLineLayout();
  }

  /// 按行取左右内边距（代码块卡片）；`null` 表示贴住正文列边缘。
  LineInsetResolver? get lineInsetFor => _lineInsetFor;
  LineInsetResolver? _lineInsetFor;
  set lineInsetFor(LineInsetResolver? value) {
    if (value == _lineInsetFor) return;
    _lineInsetFor = value;
    _dropLineLayout();
  }

  /// 揭示用的选区。
  ///
  /// 按行样式（`LiveLineStyle`）自己会读当前选区决定哪些标记显形，但排版结果
  /// 缓存着 span 树：选区一变，`# `、`**`、围栏的显隐就变了，行宽可能跟着变，
  /// 所以这里不自用、只当重排的信号。拖动期间宿主会把它冻结在按下时的选区上，
  /// 因此它不一定跟着 [selection] 走。
  TextSelection? get revealSelection => _revealSelection;
  TextSelection? _revealSelection;
  set revealSelection(TextSelection? value) {
    if (value == _revealSelection) return;
    _revealSelection = value;
    _dropLineLayout();
  }

  /// 用户点开了哪一行的列表标记（行首偏移）。
  ///
  /// 只有这一行把 `- ` / `1. ` / `[ ] ` 摊进正文；`null` 表示都照常画在槽位里。
  /// 槽位占不占宽直接改变行宽，所以变了要整篇重排。
  int? get markerRevealLine => _markerRevealLine;
  int? _markerRevealLine;
  set markerRevealLine(int? value) {
    if (value == _markerRevealLine) return;
    _markerRevealLine = value;
    _dropLineLayout();
  }

  /// 哪些列表项的行首偏移当前收起。
  ///
  /// 折叠会改变行高与整篇高度，必须重排；集合按值比较，重建时原样传回
  /// 同一个集合不会白白丢掉缓存。
  Set<int> get foldedLines => _foldedLines;
  Set<int> _foldedLines;
  set foldedLines(Set<int> value) {
    if (setEquals(value, _foldedLines)) return;
    _foldedLines = Set<int>.unmodifiable(value);
    _dropLineLayout();
  }

  /// 丢掉缓存的布局（连同每行的 `TextPainter`）并请求重排。
  void _dropLineLayout() {
    _lineLayout?.dispose();
    _lineLayout = null;
    _layoutText = null;
    _layoutStyle = null;
    _layoutWidth = null;
    markNeedsLayout();
  }

  /// 列表标记的绘制样式；`null` 表示不画标记（标记源码按正文排版）。
  LineMarkerStyle? get markerStyle => _markerStyle;
  LineMarkerStyle? _markerStyle;
  set markerStyle(LineMarkerStyle? value) {
    if (value == _markerStyle) return;
    _markerStyle = value;
    // 标记不进排版，只是叠在槽位里，所以重画就够了。
    markNeedsPaint();
  }

  /// 当前按行排版的几何结果；尚未排版时为 `null`。
  ///
  /// 这是绘制层唯一该读的几何来源：选区洗色、代码块卡片都问它要矩形，而不是
  /// 绕回 `RenderEditable` 的单段盒模型——那套几何只认识整篇一个
  /// `TextPainter`，列表续行会算回行首。
  LineDocumentLayout? get lineLayout => _lineLayout;

  /// `super.text` 的样式；没有任何样式时退化成默认 [TextStyle]。
  TextStyle get _baseStyle => text?.style ?? const TextStyle();

  // ------------------------------------------------------------ 几何出口
  //
  // 坐标一律是**渲染对象局部坐标、已计入滚动**：绘制层拿到矩形后照旧用
  // `localToGlobal` 换算到自己的画布，和 `getBoxesForSelection` 的约定一致。

  /// 选区 `[selection.start, selection.end)` 的高亮矩形。
  ///
  /// 每个视觉行一块；空行也给一条零宽矩形（起点在正文列），调用方要不要把它
  /// 画成细带由自己决定。
  List<Rect> selectionBands(TextSelection selection) {
    final LineDocumentLayout layout = _ensureLineLayout();
    final Offset paintOffset = _linePaintOffset;
    return <Rect>[
      for (final Rect rect in layout.selectionRects(
        selection.start,
        selection.end,
      ))
        rect.shift(paintOffset),
    ];
  }

  /// 源码区间 `[start, end)` 覆盖的整行矩形。
  ///
  /// 代码块卡片要的是「这些行合起来占多高」，不是每行的字形盒子。
  Rect? blockRectFor(int start, int end) {
    final Rect? rect = _ensureLineLayout().blockRect(start, end);
    return rect?.shift(_linePaintOffset);
  }

  /// 源码行 [line] 的顶部（文档坐标，不含滚动偏移）。
  ///
  /// 和选区盒子不同，这个出口给的是**整篇文档**里的位置：大纲跳转要的是内容
  /// 坐标去驱动滚动，掺进视口偏移会把当前滚动量再算一遍。
  double lineTopFor(int line) => _ensureLineLayout().lineTop(line);

  /// 全局坐标 [globalPosition] 对应的位置。
  ///
  /// 行引擎自己的命中：列表行的续行落在正文列上，点圆点会吸附到正文起点，
  /// 不会被单段排版算回行首。
  TextPosition positionAt(Offset globalPosition) {
    final LineDocumentLayout layout = _ensureLineLayout();
    final Offset local = globalToLocal(globalPosition) - _linePaintOffset;
    return TextPosition(offset: layout.offsetAtPoint(local));
  }

  @override
  set text(InlineSpan? value) {
    if (value?.toPlainText() != text?.toPlainText() ||
        value?.style != text?.style) {
      _lineLayout?.dispose();
      _lineLayout = null;
    }
    super.text = value;
  }

  @override
  set textScaler(TextScaler value) {
    if (value != textScaler) {
      _lineLayout?.dispose();
      _lineLayout = null;
    }
    super.textScaler = value;
  }

  @override
  set textAlign(TextAlign value) {
    if (value != textAlign) {
      _lineLayout?.dispose();
      _lineLayout = null;
    }
    super.textAlign = value;
  }

  @override
  set textDirection(TextDirection value) {
    if (value != textDirection) {
      _lineLayout?.dispose();
      _lineLayout = null;
    }
    super.textDirection = value;
  }

  @override
  set strutStyle(StrutStyle? value) {
    if (value != strutStyle) {
      _lineLayout?.dispose();
      _lineLayout = null;
    }
    super.strutStyle = value;
  }

  @override
  set textHeightBehavior(TextHeightBehavior? value) {
    if (value != textHeightBehavior) {
      _lineLayout?.dispose();
      _lineLayout = null;
    }
    super.textHeightBehavior = value;
  }

  @override
  set textWidthBasis(TextWidthBasis value) {
    if (value != textWidthBasis) {
      _lineLayout?.dispose();
      _lineLayout = null;
    }
    super.textWidthBasis = value;
  }

  /// 行布局的可用宽度。
  double _contentWidthFor(BoxConstraints constraints) {
    if (constraints.hasBoundedWidth && constraints.maxWidth.isFinite) {
      return math.max(1.0, constraints.maxWidth);
    }
    if (hasSize && size.width.isFinite && size.width > 0) return size.width;
    final double min = constraints.minWidth;
    return min.isFinite && min > 0 ? min : 1.0;
  }

  /// 当前缓存是否仍然对应这份文本、样式与宽度。
  LineDocumentLayout? _cachedLineLayout(double width) {
    final LineDocumentLayout? cached = _lineLayout;
    if (cached != null &&
        _layoutText == (text?.toPlainText() ?? '') &&
        _layoutStyle == _baseStyle &&
        _layoutWidth == width) {
      return cached;
    }
    return null;
  }

  /// 取当前文本的行布局，文本/样式/宽度变化时重建。
  LineDocumentLayout _ensureLineLayout() {
    final double width = _contentWidthFor(constraints);
    final String plain = text?.toPlainText() ?? '';
    final TextStyle style = _baseStyle;
    final LineDocumentLayout? cached = _cachedLineLayout(width);
    if (cached != null) return cached;

    // 缓存已过期：先释放旧实例，再按当前文本重建。
    _lineLayout?.dispose();
    final LineDocumentLayout next = layoutLines(
      text: plain,
      baseStyle: style,
      contentWidth: width,
      textScaler: textScaler,
      textDirection: textDirection,
      styleFor: _lineStyleFor,
      heightFor: _lineHeightFor,
      spanFor: _lineSpanFor,
      fillFor: _lineFillFor,
      insetFor: _lineInsetFor,
      blockFor: _lineBlockFor,
      markerRevealLine: _markerRevealLine,
      foldedLines: _foldedLines,
      cache: _lineCache,
    );
    _lineLayout = next;
    _layoutText = plain;
    _layoutStyle = style;
    _layoutWidth = width;
    return next;
  }

  @override
  double get preferredLineHeight {
    final LineDocumentLayout? layout = _lineLayout;
    // 注意取的是**视觉行**高度：源码行可能折成多条，[LaidOutLine.height]
    // 是整条源码行的高度，拿它当光标高度会让光标跨行。折叠的围栏行高为 0，
    // 拿它当光标高度光标会消失，所以跳过零高的行。
    if (layout != null) {
      for (final LaidOutLine line in layout.laidOut) {
        for (final VisualLine visual in line.visuals) {
          if (visual.height > 0) return visual.height;
        }
      }
    }
    // 尚未布局时按引擎的同一公式估算（行高 = 字号 × height，四舍五入）。
    final TextStyle style = _baseStyle;
    return ((style.fontSize ?? 15) * (style.height ?? 1.2)).roundToDouble();
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    // 缓存命中时直接回答，不再为了一次「量一下」把整篇重新排一遍。
    // 未命中也不完整布局：dry 只用于父级询问首选尺寸，真正的尺寸与滚动
    // 范围仍由 [performLayout] 决定。估算按源码行数 × 基础行高，对纯文本
    // 文档与真实布局逐像素一致；带标题/折行的文档即使差几像素，下一帧的
    // `performLayout` 也会把尺寸纠正回来。
    final double width = _contentWidthFor(constraints);
    final LineDocumentLayout? cached = _cachedLineLayout(width);
    final double naturalHeight =
        cached?.height ??
        _estimatedHeight(text?.toPlainText() ?? '', _baseStyle);
    final double boxWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : width;
    return Size(boxWidth, constraints.constrainHeight(naturalHeight));
  }

  /// 没有缓存时的轻量高度估算：换行符个数即源码行数。
  double _estimatedHeight(String plain, TextStyle style) {
    int lines = 1;
    for (int i = 0; i < plain.length; i++) {
      if (plain.codeUnitAt(i) == 0x0A) lines++;
    }
    final double size = style.fontSize ?? 15;
    final double height = style.height ?? 1.2;
    return lines * (size * height).roundToDouble();
  }

  @override
  void performLayout() {
    // 先让继承来的 `_textPainter` 完成布局：`startVerticalCaretMovement`、
    // `getWordBoundary`、`selectPositionAt` 等继承方法直接读它。
    super.performLayout();

    final LineDocumentLayout layout = _ensureLineLayout();
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : layout.width;
    size = Size(width, constraints.constrainHeight(layout.height));

    offset.applyViewportDimension(maxLines == 1 ? size.width : size.height);
    offset.applyContentDimensions(
      0.0,
      math.max(0.0, layout.height - size.height),
    );
  }

  /// 视口滚动偏移；多行时只沿垂直方向滚动，与 SDK 的 `_viewportAxis` 一致。
  Offset get _linePaintOffset =>
      maxLines == 1 ? Offset(-offset.pixels, 0.0) : Offset(0.0, -offset.pixels);

  @override
  void paint(PaintingContext context, Offset offset) {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null || !hasSize) {
      super.paint(context, offset);
      return;
    }

    final Offset paintOffset = _linePaintOffset;
    final Canvas canvas = context.canvas;
    canvas.save();
    if (clipBehavior != Clip.none) {
      canvas.clipRect(offset & size);
    }
    canvas.translate(offset.dx + paintOffset.dx, offset.dy + paintOffset.dy);

    _paintSelection(canvas, layout);
    _paintBlocks(canvas, layout);
    _paintMarkers(canvas, layout);
    _paintFills(canvas, layout);
    _paintText(canvas, layout);
    _paintComposing(canvas, layout);
    _paintCaret(canvas, layout);

    canvas.restore();
  }

  /// 这一行在画布坐标里的左上角（文档坐标；画布已经平移过滚动量）。
  static Offset _lineOrigin(LaidOutLine line) => Offset(line.gutter, line.top);

  /// 同一位置在全局坐标里的值。
  ///
  /// 自绘行只在行内坐标里排版，而悬停判定与像素对齐都发生在全局坐标系里；
  /// 滚动量在绘制期才加上，`localToGlobal` 并不知道它，所以这里补上。
  Offset _globalOriginOf(Offset local) =>
      localToGlobal(local + _linePaintOffset);

  /// 自绘行（实时表格）：行高、文字、网格、控件全部由它自己画。
  ///
  /// 排在选区洗色之后、正文之前——表格的洗色是它自己按格子画的，而它画出来
  /// 的纸面底片必须盖住编辑器底层那条通用洗色。
  void _paintBlocks(Canvas canvas, LineDocumentLayout layout) {
    for (final LaidOutLine line in layout.laidOut) {
      final LineBlockView? block = line.block;
      if (block == null || line.height <= 0) continue;
      final Offset local = _lineOrigin(line);
      block.paint(canvas, local, _globalOriginOf(local));
    }
  }

  /// 当前排出来的表格行，几何已换算成**全局坐标**。
  ///
  /// 宿主（`markdown_editor`）拿它做抓手 / `+` 按钮的命中与单元格定位。自绘行
  /// 只在行内坐标里排版，所以每次查询前先把行原点写进去。
  List<TableRowChrome> tableRows() {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) return const <TableRowChrome>[];
    final List<TableRowChrome> rows = <TableRowChrome>[];
    for (final LaidOutLine line in layout.laidOut) {
      final LineBlockView? block = line.block;
      if (block is! TableRowChrome) continue;
      final TableRowChrome chrome = block as TableRowChrome;
      chrome.chromeOrigin = _globalOriginOf(_lineOrigin(line));
      rows.add(chrome);
    }
    return rows;
  }

  void _paintSelection(Canvas canvas, LineDocumentLayout layout) {
    final TextSelection? value = selection;
    final Color? color = selectionColor;
    if (value == null || !value.isValid || value.isCollapsed || color == null) {
      return;
    }
    final Paint paint = Paint()..color = color;
    for (final Rect rect in layout.selectionRects(value.start, value.end)) {
      canvas.drawRect(rect, paint);
    }
  }

  void _paintText(Canvas canvas, LineDocumentLayout layout) {
    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0) continue;
      // 自绘行（表格）的 `TextPainter` 是空的，画在它上面的东西由 block 负责。
      if (line.block != null) continue;
      line.painter.paint(
        canvas,
        Offset(line.gutter, line.top - lineTextRise(line)),
      );
    }
  }

  /// 行内代码的圆角底片，铺在文字**下面**。
  ///
  /// `TextStyle.backgroundColor` 只能是紧贴字形的直角矩形，而旧实现靠两个
  /// widget 端帽撑出内边距和圆角；一行一个 `TextPainter` 没有 widget，所以
  /// 这里按 [LaidOutLine.fills] 自己铺一块圆角矩形，再把字画在上面。
  void _paintFills(Canvas canvas, LineDocumentLayout layout) {
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
        final TextPainter metrics = TextPainter(
          text: TextSpan(
            text: run.probe.isEmpty ? ' ' : run.probe,
            style: run.style,
          ),
          textDirection: textDirection,
          textScaler: textScaler,
        )..layout();
        final double height = metrics.height + run.padY * 2;
        metrics.dispose();
        paint.color = run.fill;

        // 一条代码可以折行：每个视觉行各铺一块，圆角只出现在两端的组上由
        // 半径本身表达——组内不切开，组间也不连成一条梯形。
        double left = boxes.first.left;
        double right = boxes.first.right;
        double top = boxes.first.top;
        double bottom = boxes.first.bottom;
        void flush() {
          final double center = (top + bottom) / 2;
          // 标签的内边距没有字符位可占，只能把底片向两侧多铺几个像素；
          // 夹取要在**画布坐标**里做（先加 origin）：行首让出的内边距正是靠
          // 这一步生效的，若先在画笔局部坐标夹再平移，让出的位置会被平移
          // 原样吃掉，字又贴回底片边缘。
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTRB(
                math.max(0, origin.dx + left - run.padX),
                origin.dy + center - height / 2,
                math.min(layout.width, origin.dx + right + run.padX),
                origin.dy + center + height / 2,
              ),
              Radius.circular(run.radius),
            ),
            paint,
          );
        }

        for (final TextBox box in boxes.skip(1)) {
          if ((box.top - top).abs() > 0.5) {
            flush();
            left = box.left;
            right = box.right;
            top = box.top;
            bottom = box.bottom;
            continue;
          }
          left = math.min(left, box.left);
          right = math.max(right, box.right);
          bottom = math.max(bottom, box.bottom);
        }
        flush();
      }
    }
  }

  // -------------------------------------------------------- 列表标记与导轨
  //
  // 标记源码不在正文里（`LineLayoutModel` 把 `paintStart` 推到标记之后），
  // 所以圆点、序号、复选框都得由渲染层画在左侧槽位里。槽位宽度由引擎算好，
  // 这里只负责画——尺寸常量与 `live_markdown` 的既有实现逐项一致。

  /// 无序列表圆点直径。
  static const double _kBulletDiameter = 5;

  /// 复选框边长。
  static const double _kCheckboxSize = 15;

  /// 复选框左边距（槽位内），与旧实现的 `Padding(left: 2)` 对齐。
  static const double _kCheckboxLeft = 2;

  /// 复选框圆角，取值同 `AppRadius.xs`。
  static const double _kCheckboxRadius = 3;

  void _paintMarkers(Canvas canvas, LineDocumentLayout layout) {
    final LineMarkerStyle? style = _markerStyle;
    if (style == null) return;
    final Paint railPaint = Paint()..color = style.rail;
    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0) continue;
      _paintRails(canvas, line, railPaint);
      // 标记源码这时已经摊进正文、由字排出来，槽位里再画一遍就成了两份。
      if (line.slot.revealedMarkers) continue;

      final SourceLine source = line.source;
      if (source.kind == LineBlockKind.rule) {
        // 光标落进这一行（或选区扫过它）时，样式层已经把 `---` 源码上屏了，
        // 再横着画一条就是「编辑态仍然显示分割线」，还会从减号中间穿过去。
        if (_sourceShown(line)) continue;
        // 未揭示时源码是透明的；线本身得有人画，否则一行分隔线会在画面上
        // 彻底消失。
        // 1px 的线落在像素栅格上：半像素的位置会被抗锯齿摊成两行灰。
        final double y = (line.top + line.height / 2).floorToDouble();
        canvas.drawRect(
          Rect.fromLTWH(0, y, math.max(0, layout.width), 1),
          railPaint,
        );
        continue;
      }
      if (source.kind == LineBlockKind.quote) {
        // 引用的 `>` 未揭示时是透明的，左侧那条强调色竖线得有人画；光标落进
        // 这一行时 `>` 自己显形，竖线让位，不然同一个标记会出现两遍。
        if (_sourceShown(line) || line.visuals.isEmpty) continue;
        // 与旧实现同一个构造：2px 宽、离正文列左边 2px、正好一行高。连续
        // 引用行首尾相接，读起来是一根连续的线。
        final VisualLine first = line.visuals.first;
        canvas.drawRect(
          Rect.fromLTWH(2, line.top + first.top, 2, first.height),
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
            Offset(line.slot.indent + 2 + _kBulletDiameter / 2, middle),
            _kBulletDiameter / 2,
            Paint()..color = style.bullet,
          );
        case LineBlockKind.ordered:
          _paintNumber(
            canvas,
            layout,
            line,
            style,
            end: source.markerEnd,
            checked: false,
          );
        case LineBlockKind.task:
          if (source.number != null) {
            _paintNumber(
              canvas,
              layout,
              line,
              style,
              end: source.leadEnd,
              checked: source.checked,
            );
          }
          _paintCheckbox(
            canvas,
            checkboxRectOf(line, layout.metrics),
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

  /// 这一行是否正在显示标记源码（分隔线的 `---`、引用的 `>`）。
  ///
  /// 判据与 `LiveLineStyle` 的揭示范围一致：选区与这一行有任何交叠就算。
  bool _sourceShown(LaidOutLine line) {
    final TextSelection? sel = _revealSelection;
    if (sel == null || !sel.isValid || sel.start < 0) return false;
    return sel.end >= line.source.start && sel.start <= line.source.end;
  }

  /// 每一级祖先的导轨，占满整条源码行的高度——连续两行首尾相接，
  /// 读起来是一根连续的线，而不是虚线。
  ///
  /// 落在本行**标记槽位里**的那根（同级自己这一列）要在字形上下断开：
  /// 否则 1px 的线会从数字/复选框中间穿过去，看起来像把标记切开了。
  void _paintRails(Canvas canvas, LaidOutLine line, Paint paint) {
    final double markerLeft = line.slot.indent;
    final double markerRight = line.slot.indent + line.slot.marker;
    double? glyphTop;
    double? glyphBottom;
    if (line.source.isList) {
      final double baseline =
          line.top +
          line.painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      // 只让开字形本身的高度（数字约 0.68em 高），不要把整条行盒都挖空，
      // 否则两根相邻条目之间只剩一两像素的点。
      final double size = line.painter.text?.style?.fontSize ?? 15;
      glyphTop = baseline - size * 0.68;
      glyphBottom = baseline + size * 0.08;
    }
    for (final double x in line.slot.railXs) {
      // 半像素回退，让 1px 的线落在像素栅格上，而不是被抗锯齿摊成两像素。
      final bool own = x > markerLeft && x < markerRight;
      // 标记已经摊成文字时，自己这一列会从序号/圆点中间穿过去，干脆不画。
      if (own && line.slot.revealedMarkers) continue;
      if (own && glyphTop != null && glyphBottom != null) {
        // 组里的第一项从标记往下起线；前面已经有条目时才把上方那一段接上。
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

  /// 有序列表的序号（`1.`），基线对齐正文首行。
  void _paintNumber(
    Canvas canvas,
    LineDocumentLayout layout,
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
      textDirection: textDirection,
      textScaler: textScaler,
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
        line.slot.indent,
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

  /// 一行里复选框的画布矩形（文档坐标）。
  ///
  /// 有序任务（`6. [ ] 事`）的槽位是「序号 + 空白 + 复选框」，
  /// 所以复选框要从序号量完的宽度之后起算；普通任务直接落在缩进上。
  static Rect checkboxRectOf(LaidOutLine line, LineLayoutMetrics metrics) {
    final VisualLine first = line.visuals.first;
    final double middle = line.top + first.top + first.height / 2;
    final double lead = math.max(0, line.slot.marker - metrics.taskWidth);
    return Rect.fromLTWH(
      line.slot.indent + lead + _kCheckboxLeft,
      middle - _kCheckboxSize / 2,
      _kCheckboxSize,
      _kCheckboxSize,
    );
  }

  /// [globalPosition] 落在哪个复选框上，返回该行的源码偏移；否则 `null`。
  ///
  /// 命中用的是**实际绘制的矩形**（外加 [slop] 的触控余量），和用户看到的
  /// 方框是同一个，不靠字符偏移去猜。
  int? taskCheckboxAt(Offset globalPosition, {double slop = 0}) {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) return null;
    final Offset local = globalToLocal(globalPosition) - _linePaintOffset;
    for (final LaidOutLine line in layout.laidOut) {
      if (line.source.kind != LineBlockKind.task || line.height <= 0) continue;
      // 复选框已经摊成 `[ ]` 文字时，那里没有画出来的方框可点：命中应该落到
      // 光标上，而不是翻转一个看不见的复选框。
      if (line.slot.revealedMarkers) continue;
      if (checkboxRectOf(line, layout.metrics).inflate(slop).contains(local)) {
        return line.source.markerStart;
      }
    }
    return null;
  }

  /// [globalPosition] 是否落在未摊开的列表标记**左侧**的空白里。
  ///
  /// 标记画在槽位 [MarkerSlot.indent] 处，左边的缩进没有字形，悬停在那里
  /// 不该出现输入光标；标记摊开后缩进仍由槽位占着，同样不算字形。
  bool isLeftOfListMarker(Offset globalPosition) {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) return false;
    final Offset local = globalToLocal(globalPosition) - _linePaintOffset;
    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0 || !line.source.isList) continue;
      if (local.dy < line.top || local.dy >= line.top + line.height) continue;
      return local.dx < line.slot.indent;
    }
    return false;
  }

  /// [globalPosition] 落在列表行的标记区时，返回该行的标记范围。
  ///
  /// 槽位里画的圆点/序号/复选框不是字形，`positionAt` 会把落点吸附到正文列；
  /// 但用户点的是标记本身，要的是把它展开成可编辑的 `- ` / `1. `。这个出口
  /// 就是那一下区分：命中标记区返回源码范围，否则返回 `null`，让调用方照常
  /// 按正文定位。[revealed] 为真时标记已经是字形，落点可以留在标记内部。
  ///
  /// [caret] 是未摊开时按落点换算出的标记内偏移：点在 `1` 和 `.` 之间就落在
  /// 那两个字之间，而不是一律回到标记起点；标记已摊开时调用方本来就按正文
  /// 定位，这里给 [markerStart] 占位。
  ({int start, int markerStart, int paintStart, bool revealed, int caret})?
  listMarkerAt(Offset globalPosition) {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) return null;
    final Offset local = globalToLocal(globalPosition) - _linePaintOffset;
    for (final LaidOutLine line in layout.laidOut) {
      if (line.height <= 0 || !line.source.isList) continue;
      if (local.dy < line.top || local.dy >= line.top + line.height) continue;
      // 槽位是一条从行首通到行尾的竖带，可画出来的只有中间那一截字形
      // （圆点、序号、方框）。点在字形上下的空白里不该把这一行摊成源码——
      // 只有点标记本身才算。
      final VisualLine first = line.visuals.first;
      final double size = line.painter.text?.style?.fontSize ?? 15;
      final double middle = line.top + first.top + first.height / 2;
      final double half = size * 0.42 + 2;
      if ((local.dy - middle).abs() > half) continue;
      if (local.dx < 0) continue;
      final bool revealed = line.slot.revealedMarkers;
      double markerWidth = line.slot.indent + line.slot.marker;
      if (revealed) {
        // 摊开以后标记是真实字形：宽度按排出来的算，但缩进仍由槽位占着，
        // 命中区要从正文列起算，不然嵌套列表的标记会被当成正文。
        final List<TextBox> boxes = line.painter.getBoxesForSelection(
          TextSelection(
            baseOffset: 0,
            extentOffset: line.source.paintStart - line.paintedFrom,
          ),
        );
        markerWidth =
            line.gutter +
            boxes.fold<double>(
              0,
              (double w, TextBox b) => math.max(w, b.right),
            );
      }
      if (local.dx >= (revealed ? markerWidth : line.gutter)) continue;
      return (
        start: line.source.start,
        markerStart: line.source.markerStart,
        paintStart: line.source.paintStart,
        revealed: revealed,
        caret: revealed
            ? line.source.markerStart
            : _markerCaretAt(line, local.dx),
      );
    }
    return null;
  }

  /// 落点在标记槽位里的 x 换算成标记源码里的字符偏移。
  ///
  /// 槽位宽度就是按标记源码、用正文样式量出来的（见引擎的 `_slotOf`），
  /// 摊开后的前缀也走同一套度量，所以拿同一份样式排一遍就能得到各个字符
  /// 间隙。落在标记左侧的缩进里时夹回标记起点。
  int _markerCaretAt(LaidOutLine line, double dx) {
    final SourceLine source = line.source;
    final int from = source.markerStart;
    final int to = source.paintStart;
    if (to <= from) return from;
    final TextStyle? style = line.painter.text?.style;
    if (style == null) return from;
    final String marker = source.text.substring(
      from - source.start,
      to - source.start,
    );
    final TextPainter painter = TextPainter(
      text: TextSpan(text: marker, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    final int within = painter
        .getPositionForOffset(
          Offset(math.max(0, dx - line.slot.indent), painter.height / 2),
        )
        .offset;
    painter.dispose();
    return (from + within).clamp(from, to);
  }

  /// 每一条可折叠列表项的箭头落点，按源码顺序，**全局坐标**。
  ///
  /// 箭头画在标记槽位左侧：16px 宽的按钮正好在标记起点收住，顶级项因此
  /// 落到页边距里，嵌套项落在缩进槽里。纵向上对齐第一条视觉行。
  List<ListFoldHandle> foldHandles() {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null || !hasSize) return const <ListFoldHandle>[];
    final Offset origin = localToGlobal(_linePaintOffset);
    final List<ListFoldHandle> handles = <ListFoldHandle>[];
    for (final LaidOutLine line in layout.laidOut) {
      final ListFold? fold = line.fold;
      if (fold == null || line.height <= 0) continue;
      final VisualLine first = line.visuals.first;
      final double center = line.top + first.top + first.height / 2;
      final Rect button = Rect.fromLTWH(
        line.slot.indent - 16,
        center - 10,
        16,
        20,
      ).shift(origin);
      Offset? ellipsis;
      if (line.folded) {
        final VisualLine last = line.visuals.last;
        final Offset end = line.painter.getOffsetForCaret(
          TextPosition(offset: line.source.end - line.paintedFrom),
          Rect.zero,
        );
        ellipsis =
            Offset(
              // 字与省略号之间留一个字距，读起来像句尾接着写的。
              line.gutter + end.dx + 5,
              // 字形整体被上提了 `lineTextRise`，省略号跟着上提才有同一条基线。
              line.top + last.top - lineTextRise(line),
            ) +
            origin;
      }
      handles.add(
        ListFoldHandle(
          lineStart: line.source.start,
          lineEnd: line.source.end,
          hiddenEnd: layout.lines[fold.lastIndex].end,
          folded: line.folded,
          button: button,
          row: Rect.fromLTRB(
            button.left,
            line.top + origin.dy,
            layout.width + origin.dx,
            line.bottom + origin.dy,
          ),
          ellipsis: ellipsis,
        ),
      );
    }
    return handles;
  }

  /// [globalPosition] 落在哪个折叠箭头上；没有则为 `null`。
  ListFoldHandle? foldHandleAt(Offset globalPosition) {
    for (final ListFoldHandle handle in foldHandles()) {
      if (handle.button.contains(globalPosition)) return handle;
    }
    return null;
  }

  /// [globalPosition] 落在哪一条可折叠列表项的横带上。
  ListFoldHandle? foldRowAt(Offset globalPosition) {
    for (final ListFoldHandle handle in foldHandles()) {
      if (handle.row.contains(globalPosition)) return handle;
    }
    return null;
  }

  /// 渲染层实际画出的每个任务复选框的矩形，按源码顺序，**全局坐标**。
  ///
  /// 给测试和命中调试用：复选框是画出来的，没有 widget 可以 `getRect`。
  List<Rect> taskCheckboxRects() {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) return const <Rect>[];
    final Offset origin = localToGlobal(_linePaintOffset);
    return <Rect>[
      for (final LaidOutLine line in layout.laidOut)
        if (line.source.kind == LineBlockKind.task &&
            line.height > 0 &&
            !line.slot.revealedMarkers)
          checkboxRectOf(line, layout.metrics).shift(origin),
    ];
  }

  /// IME 组合区间用一条下划线标出。
  void _paintComposing(Canvas canvas, LineDocumentLayout layout) {
    final TextRange composing =
        textSelectionDelegate.textEditingValue.composing;
    if (!composing.isValid || composing.isCollapsed) return;
    final Color color = cursorColor ?? const Color(0xFF000000);
    final Paint paint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final Rect rect in layout.selectionRects(
      composing.start,
      composing.end,
    )) {
      final double y = rect.bottom - 0.75;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), paint);
    }
  }

  /// 这一行的光标高度。
  ///
  /// 宿主显式给了 `cursorHeight` 就用它；否则跟随**这一行**的高度。整篇共用
  /// `preferredLineHeight` 是单段排版的假设：一旦按行取样式，标题行旁边的
  /// 正文光标会撑到标题那么高，标题行的光标又会缩成正文高。
  double _caretHeightOf(CaretGeometry caret) {
    final double? explicit = _explicitCursorHeight;
    if (explicit != null) return explicit;
    return caret.height > 0 ? caret.height : preferredLineHeight;
  }

  void _paintCaret(Canvas canvas, LineDocumentLayout layout) {
    final TextSelection? value = selection;
    if (!hasFocus || !showCursor.value || value == null || !value.isValid) {
      return;
    }
    final CaretGeometry caret = layout.caretGeometryAt(value.extentOffset);
    final double height = _caretHeightOf(caret);
    final double top = caret.origin.dy + (caret.height - height) / 2;
    final Rect rect = Rect.fromLTWH(
      caret.origin.dx + cursorOffset.dx,
      top + cursorOffset.dy,
      cursorWidth,
      height,
    );
    final Paint paint = Paint()..color = cursorColor ?? const Color(0xFF000000);
    final Radius? radius = cursorRadius;
    if (radius == null) {
      canvas.drawRect(rect, paint);
    } else {
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);
    }
  }

  @override
  List<TextBox> getBoxesForSelection(TextSelection selection) {
    return <TextBox>[
      for (final Rect rect in selectionBands(selection))
        TextBox.fromLTRBD(
          rect.left,
          rect.top,
          rect.right,
          rect.bottom,
          textDirection,
        ),
    ];
  }

  @override
  List<TextSelectionPoint> getEndpointsForSelection(TextSelection selection) {
    final LineDocumentLayout layout = _ensureLineLayout();
    final Offset paintOffset = _linePaintOffset;
    if (selection.isCollapsed) {
      final CaretGeometry caret = layout.caretGeometryAt(
        selection.extentOffset,
      );
      return <TextSelectionPoint>[
        TextSelectionPoint(
          Offset(caret.origin.dx, caret.bottom) + paintOffset,
          null,
        ),
      ];
    }

    final List<Rect> rects = layout.selectionRects(
      selection.start,
      selection.end,
    );
    if (rects.isEmpty) {
      final CaretGeometry caret = layout.caretGeometryAt(
        selection.extentOffset,
      );
      return <TextSelectionPoint>[
        TextSelectionPoint(
          Offset(caret.origin.dx, caret.bottom) + paintOffset,
          null,
        ),
      ];
    }
    return <TextSelectionPoint>[
      TextSelectionPoint(rects.first.bottomLeft + paintOffset, textDirection),
      TextSelectionPoint(rects.last.bottomRight + paintOffset, textDirection),
    ];
  }

  @override
  Rect? getRectForComposingRange(TextRange range) {
    if (!range.isValid || range.isCollapsed) return null;
    final LineDocumentLayout layout = _ensureLineLayout();
    final List<Rect> rects = layout.selectionRects(range.start, range.end);
    if (rects.isEmpty) return null;
    Rect union = rects.first;
    for (int i = 1; i < rects.length; i++) {
      union = union.expandToInclude(rects[i]);
    }
    return union.shift(_linePaintOffset);
  }

  @override
  TextPosition getPositionForPoint(Offset globalPosition) =>
      positionAt(globalPosition);

  @override
  Rect getLocalRectForCaret(TextPosition caretPosition) {
    final LineDocumentLayout layout = _ensureLineLayout();
    final CaretGeometry caret = layout.caretGeometryAt(caretPosition.offset);
    final double height = _caretHeightOf(caret);
    final double top = caret.origin.dy + (caret.height - height) / 2;
    return Rect.fromLTWH(
      caret.origin.dx + cursorOffset.dx,
      top + cursorOffset.dy,
      cursorWidth,
      height,
    ).shift(_linePaintOffset);
  }

  @override
  void selectPositionAt({
    required Offset from,
    Offset? to,
    required SelectionChangedCause cause,
  }) {
    // 基类用整篇单段的 `_textPainter` 做命中，会把列表续行算回行首；
    // 这里换成行布局的命中结果，再走与基类相同的 `userUpdateTextEditingValue`。
    final TextPosition fromPosition = getPositionForPoint(from);
    final TextPosition? toPosition = to == null
        ? null
        : getPositionForPoint(to);
    final TextEditingValue value = textSelectionDelegate.textEditingValue;
    final int length = value.text.length;
    final TextSelection next = TextSelection(
      baseOffset: math.min(fromPosition.offset, length),
      extentOffset: math.min(toPosition?.offset ?? fromPosition.offset, length),
      affinity: fromPosition.affinity,
    );
    textSelectionDelegate.userUpdateTextEditingValue(
      value.copyWith(selection: next),
      cause,
    );
  }

  @override
  TextSelection getLineAtOffset(TextPosition position) {
    final LineDocumentLayout layout = _ensureLineLayout();
    final CaretGeometry caret = layout.caretGeometryAt(position.offset);
    final SourceLine line = layout.lines[caret.lineIndex];
    return TextSelection(baseOffset: line.start, extentOffset: line.end);
  }

  /// 正在监听的闪烁开关（[showCursor] 通知器）。
  ValueNotifier<bool>? _blink;

  /// 父类的闪烁监听只重画它自带的那个画光标的子绘制对象；本类的光标画在
  /// [paint] 里，那个子对象根本不参与绘制，所以父类那条链路不会让画面变
  /// 一下——光标会停在最后一次点击/输入时的状态，要等下一次交互才更新，
  /// 看起来就是「点一下显示、再点一下隐藏」。这里自己监听，闪一次重画一次。
  @override
  set showCursor(ValueNotifier<bool> value) {
    super.showCursor = value;
    if (attached) _watchBlink(value);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _watchBlink(showCursor);
  }

  @override
  void detach() {
    _blink?.removeListener(_onBlink);
    _blink = null;
    super.detach();
  }

  void _watchBlink(ValueNotifier<bool> value) {
    if (identical(_blink, value)) return;
    _blink?.removeListener(_onBlink);
    _blink = value..addListener(_onBlink);
  }

  void _onBlink() => markNeedsPaint();

  @override
  void dispose() {
    _blink?.removeListener(_onBlink);
    _blink = null;
    _lineLayout?.dispose();
    _lineLayout = null;
    _lineCache.dispose();
    _layoutText = null;
    _layoutStyle = null;
    _layoutWidth = null;
    super.dispose();
  }
}
