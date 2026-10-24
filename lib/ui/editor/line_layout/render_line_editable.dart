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

import '../../../core/utils/image_markup.dart';
import 'line_layout_engine.dart';
import 'line_layout_pool.dart';
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
    Object? lineLayoutKey,
    LineLayoutPool? layoutPool,
    String? layoutCacheDocument,
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
    ({String needle, bool caseSensitive})? searchHighlight,
    Color? searchHighlightColor,
  }) : // 私有字段不能做命名参数，只能在这里赋值。
       // ignore: prefer_initializing_formals
       _explicitCursorHeight = cursorHeight,
       // ignore: prefer_initializing_formals
       _foldedLines = foldedLines ?? const <int>{},
       // ignore: prefer_initializing_formals
       _lineLayoutKey = lineLayoutKey,
       // ignore: prefer_initializing_formals
       _layoutPool = layoutPool,
       // ignore: prefer_initializing_formals
       _layoutCacheDocument = layoutCacheDocument,
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
       // ignore: prefer_initializing_formals
       _searchHighlight = searchHighlight,
       // ignore: prefer_initializing_formals
       _searchHighlightColor = searchHighlightColor,
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
  ///
  /// 采用挂起布局时会随之换成那份布局的池：它的 `fromCache` 行归旧池所有。
  LineLayoutCache _lineCache = LineLayoutCache();
  String? _layoutText;
  TextStyle? _layoutStyle;
  double? _layoutWidth;

  /// 当前 [_lineLayout] 是按哪个语义键排出来的（见 [lineLayoutKey]）。
  Object? _layoutKey;

  /// 跨文档挂起布局的池（P5a）；为 null 时只在本渲染对象内复用。
  LineLayoutPool? _layoutPool;

  /// 当前文档的身份（笔记 id 加外部版本）；为 null 时不参与跨文档缓存。
  String? _layoutCacheDocument;

  /// 当前 [_lineLayout] 是按哪个跨文档键排出来的。
  ///
  /// 在每次产出布局时连同键一起记下，销毁时原样挂回去——它必须描述**当时**
  /// 的宽度、样式、折叠与揭示行，而不是销毁那一刻的配置。
  LineLayoutPoolKey? _layoutPoolKey;

  /// 跨文档缓存的命中次数，供测试确认切回来没有重新排版。
  @visibleForTesting
  int debugLayoutPoolHits = 0;

  /// 挂起出去（而不是释放）的布局份数。
  @visibleForTesting
  int debugLayoutParks = 0;

  LineLayoutPool? get layoutPool => _layoutPool;
  set layoutPool(LineLayoutPool? value) {
    if (value == _layoutPool) return;
    _layoutPool = value;
  }

  String? get layoutCacheDocument => _layoutCacheDocument;
  set layoutCacheDocument(String? value) {
    if (value == _layoutCacheDocument) return;
    // 键里带文档身份，换文档后旧布局不该再被采用；但也不在这里丢弃：
    // 正常路径是宿主换掉整个输入框，由 [dispose] 原地挂起。
    _layoutCacheDocument = value;
  }

  /// 当前 [_lineLayout] 是按哪一份揭示选区排出来的。
  ///
  /// 选区变化时用它和新值算脏行集合；局部重排成功后同步成新值。
  TextSelection? _layoutReveal;

  /// 下一次布局要走局部重排的脏行；`null` 表示没有待办。
  ///
  /// 只由 `revealSelection` setter 写入，任何全量路径都会清掉它。
  Set<int>? _pendingRevealDirty;

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
    _resolverReplaced();
  }

  /// 按行取固定行高；`null` 表示按测量结果（折叠的围栏行是唯一的使用者）。
  LineHeightResolver? get lineHeightFor => _lineHeightFor;
  LineHeightResolver? _lineHeightFor;
  set lineHeightFor(LineHeightResolver? value) {
    if (value == _lineHeightFor) return;
    _lineHeightFor = value;
    _resolverReplaced();
  }

  /// 按行取 span 树；`null` 时用 [lineStyleFor] 的样式排纯文本。
  LineSpanResolver? get lineSpanFor => _lineSpanFor;
  LineSpanResolver? _lineSpanFor;
  set lineSpanFor(LineSpanResolver? value) {
    if (value == _lineSpanFor) return;
    _lineSpanFor = value;
    _resolverReplaced();
  }

  /// 按行取自绘内容（实时表格行）；`null` 表示所有行都排文字。
  LineBlockResolver? get lineBlockFor => _lineBlockFor;
  LineBlockResolver? _lineBlockFor;
  set lineBlockFor(LineBlockResolver? value) {
    if (value == _lineBlockFor) return;
    _lineBlockFor = value;
    _resolverReplaced();
  }

  /// 按行取圆角底片（行内代码）；`null` 表示不铺底片。
  LineFillResolver? get lineFillFor => _lineFillFor;
  LineFillResolver? _lineFillFor;
  set lineFillFor(LineFillResolver? value) {
    if (value == _lineFillFor) return;
    _lineFillFor = value;
    _resolverReplaced();
  }

  /// 按行取左右内边距（代码块卡片）；`null` 表示贴住正文列边缘。
  LineInsetResolver? get lineInsetFor => _lineInsetFor;
  LineInsetResolver? _lineInsetFor;
  set lineInsetFor(LineInsetResolver? value) {
    if (value == _lineInsetFor) return;
    _lineInsetFor = value;
    _resolverReplaced();
  }

  /// 行解析器的语义键（`LiveLineStyle.styleKey`）。
  ///
  /// 宿主每次重建都会给出新的闭包实例，身份必然变化；键只含影响排版的配置、
  /// 不含源码，键不变时未编辑的行仍可原样复用。键变了才整篇重排。
  Object? get lineLayoutKey => _lineLayoutKey;
  Object? _lineLayoutKey;
  set lineLayoutKey(Object? value) {
    if (value == _lineLayoutKey) return;
    _lineLayoutKey = value;
    markNeedsLayout();
  }

  /// 解析器换了实例：没有语义键时只能按身份判定，有键则等布局时再比。
  void _resolverReplaced() {
    if (_lineLayoutKey == null) {
      _dropLineLayout();
      return;
    }
    markNeedsLayout();
  }

  /// 揭示用的选区。
  ///
  /// 按行样式（`LiveLineStyle`）自己会读当前选区决定哪些标记显形，但排版结果
  /// 缓存着 span 树：选区一变，`# `、`**`、围栏的显隐就变了，行宽可能跟着变，
  /// 所以选区变化仍然是重排的信号。拖动期间宿主会把它冻结在按下时的选区上，
  /// 因此它不一定跟着 [selection] 走。
  ///
  /// 但选区只影响**少数行**：这里不再丢整篇布局，而是算出逐行签名变化的行，
  /// 交给下一次布局做局部重排（见 [_ensureLineLayout]）。签名不变时连布局都
  /// 不动，只重画（分隔线、引用竖线要看新选区决定显隐）。
  TextSelection? get revealSelection => _revealSelection;
  TextSelection? _revealSelection;
  set revealSelection(TextSelection? value) {
    if (value == _revealSelection) return;
    _revealSelection = value;
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) {
      // 还没有可对照的布局：下一次布局本来就会全量，不需要脏行。
      _pendingRevealDirty = null;
      markNeedsLayout();
      return;
    }
    if (_layoutText != (text?.toPlainText() ?? '')) {
      // 文本已经变了、布局还是上一份：脏行下标在新文本上不成立，这个选区
      // 也不能提前写进 `_layoutReveal`。留给编辑增量路径逐行比较签名——
      // 否则「粘贴到别处、原选区行要取消揭示」会被整个漏掉。
      _pendingRevealDirty = null;
      markNeedsLayout();
      return;
    }
    final Set<int> dirty = layout.revealDirtyLines(_layoutReveal, value);
    if (dirty.isEmpty) {
      // 版面一个像素都不变，但洗色与 `_sourceShown` 跟着选区走，需要重画。
      _pendingRevealDirty = null;
      _layoutReveal = value;
      markNeedsPaint();
      return;
    }
    // 图片加载完成也会往这里塞行号；两边同一帧到达时取并集，谁都不能
    // 把对方刚标脏的行丢掉。
    _pendingRevealDirty = <int>{...?_pendingRevealDirty, ...dirty};
    markNeedsLayout();
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
    _layoutReveal = null;
    _layoutKey = null;
    _layoutPoolKey = null;
    _pendingRevealDirty = null;
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

  /// 编辑增量成功的次数，供测试确认普通输入没有退回全量。
  @visibleForTesting
  int debugEditRelayouts = 0;

  /// 全量重建布局的次数（首次布局也计入）。
  @visibleForTesting
  int debugFullLayouts = 0;

  /// `super.text` 的样式；没有任何样式时退化成默认 [TextStyle]。
  TextStyle get _baseStyle => text?.style ?? const TextStyle();

  // ------------------------------------------------------------ 几何出口
  //
  // 坐标一律是**渲染对象局部坐标、已计入滚动**：绘制层拿到矩形后照旧用
  // `localToGlobal` 换算到自己的画布，和 `getBoxesForSelection` 的约定一致。

  /// 选区 `[selection.start, selection.end)` 的高亮矩形。
  ///
  /// 每个视觉行一块；空行也给一条零宽矩形（起点在正文列），调用方要不要把它
  /// 画成细带由自己决定。[visible]（文档坐标）给定时只返回与它相交的行。
  List<Rect> selectionBands(TextSelection selection, {Rect? visible}) {
    final LineDocumentLayout layout = _ensureLineLayout();
    final Offset paintOffset = _linePaintOffset;
    return <Rect>[
      for (final Rect rect in layout.selectionRects(
        selection.start,
        selection.end,
        visible: visible,
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
    final LineDocumentLayout? layout = _lineLayout;
    if (layout != null) {
      final bool styleChanged =
          (value?.style ?? const TextStyle()) != _layoutStyle;
      if (styleChanged) {
        // 正文样式换了：逐行样式、行高、缓存键全部作废，只能全量。
        _dropLineLayout();
      } else if (value?.toPlainText() != _layoutText) {
        // 只是文字变了：**留着布局**。下一次布局用公共前后缀求出这次编辑，
        // 走 `relayoutOnEdit` 的行级增量；一次性全部丢掉正是 P4 要解决的
        // 全量重排。旧布局在增量成功后由调用方接管并释放。
        _pendingRevealDirty = null;
        markNeedsLayout();
      }
    } else if (_layoutText != null) {
      // 没有布局却还留着旧文本记录（被上面的样式分支丢弃过）：清干净，
      // 免得下一次被误判成「可以增量」。
      _layoutText = null;
      _layoutStyle = null;
      _layoutWidth = null;
      _layoutReveal = null;
      _layoutKey = null;
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

  /// 这次布局对应的跨文档键；不参与跨文档缓存时为 null。
  LineLayoutPoolKey? _poolKeyOf(double width, String plain) {
    final String? document = _layoutCacheDocument;
    if (_layoutPool == null || document == null) return null;
    final List<int> folds = _foldedLines.toList()..sort();
    return (
      document: document,
      body: plain,
      width: width,
      textScaler: textScaler,
      style: _baseStyle,
      folds: folds.join(','),
      markerRevealLine: _markerRevealLine,
    );
  }

  /// 采用挂起的布局：命中后只按新的揭示选区重排少数行。
  ///
  /// 表格行块由宿主缓存、切文档时可能已被释放，所以命中后表格行一律重建；
  /// 其余行沿用挂起时的几何，`top` 不变。
  LineDocumentLayout? _adoptPooledLayout(
    double width,
    String plain,
    TextStyle style,
  ) {
    final LineLayoutPool? pool = _layoutPool;
    if (pool == null || _layoutText != null) return null;
    final LineLayoutPoolKey? key = _poolKeyOf(width, plain);
    if (key == null) return null;
    final ParkedLineLayout? parked = pool.take(key);
    if (parked == null) return null;

    final Set<int> dirty = <int>{
      ...parked.layout.revealDirtyLines(parked.reveal, _revealSelection),
    };
    for (int i = 0; i < parked.layout.lines.length; i++) {
      final SourceLine line = parked.layout.lines[i];
      final LineBlockKind kind = line.kind;
      if (kind == LineBlockKind.table ||
          kind == LineBlockKind.tableHeader ||
          kind == LineBlockKind.tableDivider ||
          // 图片块由宿主缓存，切文档时可能已被释放；命中的旧布局里剩下
          // 的只是悬空引用，必须重建。
          (kind == LineBlockKind.paragraph &&
              ImageMarkup.parseLine(line.text) != null)) {
        dirty.add(i);
      }
    }

    // 挂起布局的 painter 池一起接手：`fromCache` 行归它所有。
    _lineCache.dispose();
    _lineCache = parked.cache;
    _layoutText = plain;
    _layoutStyle = style;
    _layoutWidth = width;
    _layoutKey = _lineLayoutKey;
    _layoutPoolKey = key;
    _layoutReveal = _revealSelection;
    _pendingRevealDirty = null;
    _lineLayout = dirty.isEmpty
        ? parked.layout
        : relayoutLines(
            previous: parked.layout,
            dirtyLines: dirty,
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
            metrics: parked.layout.metrics,
          );
    debugLayoutPoolHits++;
    return _lineLayout;
  }

  /// 当前缓存是否仍然对应这份文本、样式、宽度与解析器语义。
  LineDocumentLayout? _cachedLineLayout(double width) {
    final LineDocumentLayout? cached = _lineLayout;
    if (cached != null &&
        _layoutText == (text?.toPlainText() ?? '') &&
        _layoutStyle == _baseStyle &&
        _layoutWidth == width &&
        _layoutKey == _lineLayoutKey) {
      return cached;
    }
    return null;
  }

  /// 取当前文本的行布局。
  ///
  /// 三条路径，成本从低到高：
  /// 1. 输入完全没变 → 原样返回；
  /// 2. 只是文字变了（样式、宽度、解析器语义都没变）→ [relayoutOnEdit]
  ///    只重建被编辑波及的行，其余行换壳复用；
  /// 3. 揭示选区变了 → [relayoutLines] 只重排签名变化的那几行；
  /// 4. 其余任何变化 → 全量 [layoutLines]。
  LineDocumentLayout _ensureLineLayout() {
    final double width = _contentWidthFor(constraints);
    final String plain = text?.toPlainText() ?? '';
    final TextStyle style = _baseStyle;

    // 刚挂上来的输入框（切回一篇刚才挂起的笔记）：直接采用那份布局，只按
    // 新的揭示选区重排少数行，不重排整篇。
    final LineDocumentLayout? pooled = _adoptPooledLayout(width, plain, style);
    if (pooled != null) {
      return pooled;
    }

    final LineDocumentLayout? cached = _cachedLineLayout(width);
    if (cached != null) {
      final Set<int>? dirty = _pendingRevealDirty;
      if (dirty == null || dirty.isEmpty) {
        return cached;
      }
      _pendingRevealDirty = null;
      final LineDocumentLayout next = relayoutLines(
        previous: cached,
        dirtyLines: dirty,
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
      );
      _lineLayout = next;
      _layoutReveal = _revealSelection;
      _layoutPoolKey = _poolKeyOf(width, plain);
      return next;
    }

    // 缓存过期：若只是文字变了（样式/宽度/语义键全都没变），先试编辑增量。
    final LineDocumentLayout? previous = _lineLayout;
    if (previous != null &&
        _layoutText != null &&
        _layoutStyle == style &&
        _layoutWidth == width &&
        _layoutKey == _lineLayoutKey) {
      final ({int start, int removed, int inserted})? edit = _editBetween(
        _layoutText!,
        plain,
      );
      if (edit != null) {
        _pendingRevealDirty = null;
        final LineDocumentLayout? next = relayoutOnEdit(
          previous: previous,
          text: plain,
          editStart: edit.start,
          removedLength: edit.removed,
          insertedLength: edit.inserted,
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
          revealBefore: _layoutReveal,
          revealAfter: _revealSelection,
        );
        if (next != null) {
          _lineLayout = next;
          _layoutText = plain;
          _layoutReveal = _revealSelection;
          _layoutPoolKey = _poolKeyOf(width, plain);
          debugEditRelayouts++;
          return next;
        }
      }
    }

    // 缓存已过期且不能安全增量：先释放旧实例，再按当前文本全量重建。
    _pendingRevealDirty = null;
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
    _layoutReveal = _revealSelection;
    _layoutKey = _lineLayoutKey;
    _layoutPoolKey = _poolKeyOf(width, plain);
    debugFullLayouts++;
    return next;
  }

  /// 销毁前把当前布局挂进跨文档池（P5a）。
  ///
  /// 换笔记时宿主用新的 `ValueKey` 整块重建输入框，走的是 `dispose` 而不是
  /// 「同一份渲染对象换文本」。这里把布局连同它的 painter 池一起交给池，
  /// 切回来时 [LineLayoutPool.take] 原样交还；拿不到池或布局已作废时照旧释放。
  void _parkLayout() {
    final LineDocumentLayout? layout = _lineLayout;
    final LineLayoutPool? pool = _layoutPool;
    final LineLayoutPoolKey? key = _layoutPoolKey;
    if (layout == null || pool == null || key == null) return;
    if (layout.disposed) return;
    // 池化的 painter 归 `_lineCache` 所有，必须跟着布局一起搬；这里先换出
    // 一个新池，稍后 `dispose` 释放的是这个空池。
    final LineLayoutCache cache = _lineCache;
    _lineCache = LineLayoutCache();
    pool.park(key, layout, cache, _layoutReveal);
    _lineLayout = null;
    _layoutPoolKey = null;
    debugLayoutParks++;
  }

  /// 两份文本之间唯一的替换区间：`before` 的 `[start, start + removed)`
  /// 被 `after` 的 `[start, start + inserted)` 取代。
  ///
  /// 公共前缀与公共后缀是最小的单一差分——所有真实编辑（打字、删除、粘贴、
  /// IME 提交）都落在这个形状里。分散改动（比如有序列表整体重编号）会得到
  /// 一个覆盖全部改动的较宽区间：多重建几行只是性能代价，几何不会失真。
  ({int start, int removed, int inserted})? _editBetween(
    String before,
    String after,
  ) {
    if (before == after) return null;
    final int max = math.min(before.length, after.length);
    int prefix = 0;
    while (prefix < max && before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    int suffix = 0;
    final int limit = max - prefix;
    while (suffix < limit &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    return (
      start: prefix,
      removed: before.length - prefix - suffix,
      inserted: after.length - prefix - suffix,
    );
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

  /// 视口在**文档坐标**里的可见纵向区间。
  ///
  /// 正文框自己通常不滚动：编辑器把整篇交给外层滚动视图，`offset.pixels`
  /// 因此恒为 0、`size.height` 是整篇高度。真正被看到的那一段是「最近的
  /// 滚动视口框」与正文框自身内部滚动可见段（单行排版时是横向）的交集。
  /// 绘制层、分层画笔都读这一份：滚动一帧只画看得见的行，而不是整篇。
  ({double top, double bottom}) get visibleDocumentBounds {
    final LineDocumentLayout? layout = _lineLayout;
    final double height = layout?.height ?? double.infinity;
    if (maxLines == 1) return (top: 0, bottom: height);
    final Offset paintOffset = _linePaintOffset;
    double top = offset.pixels;
    double bottom = offset.pixels + size.height;
    final RenderObject? node = _ancestorViewport();
    if (node is RenderBox && node.hasSize) {
      final double originY = MatrixUtils.transformPoint(
        getTransformTo(node),
        Offset.zero,
      ).dy;
      top = math.max(top, -originY - paintOffset.dy);
      bottom = math.min(bottom, node.size.height - originY - paintOffset.dy);
    }
    if (height.isFinite) {
      top = top.clamp(0.0, height);
      bottom = bottom.clamp(top, height);
    }
    // 兜底：跳到文档中段的那一帧，视口链上的变换偶尔会把区间算成空段甚至
    // 负段。按行绘制只画区间内的行，空区间就是整屏空白，而动画结束后不会再
    // 有新帧——空白会一直留到下一次 hover 重建。这里至少给出一个视口高。
    if (bottom - top <= 0) {
      final double extent = node is RenderBox && node.hasSize
          ? node.size.height
          : size.height;
      top = offset.pixels;
      bottom = top + (extent.isFinite && extent > 0 ? extent : size.height);
      if (height.isFinite) {
        top = top.clamp(0.0, height);
        bottom = bottom.clamp(top, height);
      }
    }
    return (top: top, bottom: bottom);
  }

  /// 最近的滚动视口（外层 `SingleChildScrollView` 等）；没有则 `null`。
  RenderObject? _ancestorViewport() {
    RenderObject? node = parent;
    while (node != null && node is! RenderAbstractViewport) {
      node = node.parent;
    }
    return node;
  }

  /// 视口在**文档坐标**里的上沿（不含滚动量）。
  double get visibleDocumentTop => visibleDocumentBounds.top;

  /// 视口在文档坐标里的下沿。
  double get visibleDocumentBottom => visibleDocumentBounds.bottom;

  /// 视口矩形（文档坐标）。分层画笔（代码块卡片、选区洗色）用它裁剪。
  Rect get visibleDocumentRect => Rect.fromLTRB(
    0,
    visibleDocumentTop,
    math.max(0, size.width),
    math.max(visibleDocumentTop, visibleDocumentBottom),
  );

  /// 视口上下各多画一点，快速滚动时行边缘不会闪空。
  double get _viewportPadding {
    final double line = preferredLineHeight;
    return line.isFinite && line > 0 ? line * 2 : 32;
  }

  /// 最近一次 [paint] 真正画出的正文行数，供测试确认视口裁剪生效。
  @visibleForTesting
  int debugPaintedLines = 0;

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
      // 表格 chrome（行/列抓手）挂在内容区外的左上侧：裁剪向左上各放宽
      // [kTableChromeBleed]，让它们画进滚动视图的 padding 里。右侧、下侧
      // 不放大——正文只在正坐标里画，只有 chrome 会伸出去。
      canvas.clipRect(
        Rect.fromLTRB(
          offset.dx - kTableChromeBleed,
          offset.dy - kTableChromeBleed,
          offset.dx + size.width,
          offset.dy + size.height,
        ),
      );
    }
    canvas.translate(offset.dx + paintOffset.dx, offset.dy + paintOffset.dy);

    // 逐行绘制只看与视口相交的那一段：文档再长，一帧也只画看得见的行。
    final ({double top, double bottom}) span = visibleDocumentBounds;
    final double pad = _viewportPadding;
    final ({int from, int to}) range = layout.lineRangeBetween(
      span.top - pad,
      span.bottom + pad,
    );
    final Rect? visible = maxLines == 1
        ? null
        : Rect.fromLTRB(0, span.top, layout.width, span.bottom);

    debugPaintedLines = 0;
    debugSearchHighlightRects = 0;
    _paintSelection(canvas, layout, visible);
    _paintBlocks(canvas, layout, range);
    _paintMarkers(canvas, layout, range);
    _paintFills(canvas, layout, range);
    // 色带铺在正文底下：行内代码底片之上、字形之下。
    _paintSearchHighlights(canvas, layout, range, visible);
    _paintText(canvas, layout, range);
    _paintComposing(canvas, layout, visible);
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
  void _paintBlocks(
    Canvas canvas,
    LineDocumentLayout layout,
    ({int from, int to}) range,
  ) {
    for (int i = range.from; i < range.to; i++) {
      final LaidOutLine line = layout.laidOut[i];
      final LineBlockView? block = line.block;
      if (block == null || line.height <= 0) continue;
      final Offset local = _lineOrigin(line);
      // 行可能被整对象复用，而块里的源码偏移是建块时记的：每帧按当前行
      // 回写一次，指针落点与揭示判定不会落在位移前的旧偏移上。
      if (block is ImageBlockChrome) {
        (block as ImageBlockChrome).chromeSourceRange(
          line.source.start,
          line.source.end,
        );
      }
      block.paint(canvas, local, _globalOriginOf(local));
    }
  }

  /// 当前排出来的表格行，几何已换算成**全局坐标**。
  ///
  /// 宿主（`markdown_editor`）拿它做抓手 / `+` 按钮的命中与单元格定位。自绘行
  /// 只在行内坐标里排版，所以每次查询前先把行原点写进去。
  ///
  /// 行集合只在布局换新时重建；滚动只改原点，逐行平移即可——指针移动不该
  /// 每帧把全篇行扫一遍。
  List<TableRowChrome> tableRows() {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) return const <TableRowChrome>[];
    List<TableRowChrome>? rows = _tableRows;
    List<LaidOutLine>? lines = _tableRowLines;
    if (rows == null || lines == null || !identical(_tableRowsLayout, layout)) {
      rows = <TableRowChrome>[];
      lines = <LaidOutLine>[];
      for (final LaidOutLine line in layout.laidOut) {
        final LineBlockView? block = line.block;
        if (block is! TableRowChrome) continue;
        rows.add(block as TableRowChrome);
        lines.add(line);
      }
      _tableRows = rows;
      _tableRowLines = lines;
      _tableRowsLayout = layout;
    }
    final Offset origin = localToGlobal(_linePaintOffset);
    for (int i = 0; i < rows.length; i++) {
      rows[i].chromeOrigin = _lineOrigin(lines[i]) + origin;
    }
    return rows;
  }

  List<TableRowChrome>? _tableRows;
  List<LaidOutLine>? _tableRowLines;
  LineDocumentLayout? _tableRowsLayout;

  /// 只把某一行标脏，下一次布局走 [relayoutLines] 的增量分支。
  ///
  /// 图片解码完成、或拖拽预览改了宽度时用：整篇重排会在加载一张图时卡一下，
  /// 而行高变化只需要这一行重新量。
  void invalidateImageLine(int sourceStart) {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null || _layoutText != (text?.toPlainText() ?? '')) {
      // 还没有可对照的布局，或文本已经先走一步：下次布局本来就会全量。
      _pendingRevealDirty = null;
      markNeedsLayout();
      return;
    }
    int index = -1;
    for (int i = 0; i < layout.lines.length; i++) {
      if (layout.lines[i].start == sourceStart) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      // 块记下的行首已经因为上方编辑平移了：脏行下标不可信，整篇重来。
      _dropLineLayout();
      return;
    }
    (_pendingRevealDirty ??= <int>{}).add(index);
    markNeedsLayout();
  }

  /// 视口内的图片块，几何已换算成**全局坐标**。
  ///
  /// 与 [tableRows] 一样按布局实例缓存列表；滚动只平移原点。每行查询前把
  /// 当前源码范围写回去，命中测试和光标映射才不会用着位移前的旧偏移。
  List<ImageBlockChrome> imageBlocks() {
    final LineDocumentLayout? layout = _lineLayout;
    if (layout == null) return const <ImageBlockChrome>[];
    List<ImageBlockChrome>? blocks = _imageBlockChrome;
    List<LaidOutLine>? lines = _imageBlockChromeLines;
    if (blocks == null ||
        lines == null ||
        !identical(_imageBlockChromeLayout, layout)) {
      blocks = <ImageBlockChrome>[];
      lines = <LaidOutLine>[];
      for (final LaidOutLine line in layout.laidOut) {
        final LineBlockView? block = line.block;
        if (block is! ImageBlockChrome) continue;
        blocks.add(block as ImageBlockChrome);
        lines.add(line);
      }
      _imageBlockChrome = blocks;
      _imageBlockChromeLines = lines;
      _imageBlockChromeLayout = layout;
    }
    final Offset origin = localToGlobal(_linePaintOffset);
    final ({double top, double bottom}) visible = visibleDocumentBounds;
    final List<ImageBlockChrome> result = <ImageBlockChrome>[];
    for (int i = 0; i < blocks.length; i++) {
      final LaidOutLine line = lines[i];
      if (line.top + line.height < visible.top ||
          line.top > visible.bottom) {
        continue;
      }
      final Offset local = _lineOrigin(line);
      blocks[i]
        ..chromeSourceRange(line.source.start, line.source.end)
        ..chromeOrigin = local + origin;
      result.add(blocks[i]);
    }
    return result;
  }

  List<ImageBlockChrome>? _imageBlockChrome;
  List<LaidOutLine>? _imageBlockChromeLines;
  LineDocumentLayout? _imageBlockChromeLayout;

  /// 搜索框里的词在正文中的所有出现位置都用这条色带标出来。
  ///
  /// 只改绘制、不改排版：色带挂在 `selectionRects` 同一套几何上，滚动时只算
  /// 视口里的行，和正文输入的字宽、换行毫无关系。
  ({String needle, bool caseSensitive})? get searchHighlight =>
      _searchHighlight;
  ({String needle, bool caseSensitive})? _searchHighlight;
  set searchHighlight(({String needle, bool caseSensitive})? value) {
    if (value == _searchHighlight) return;
    _searchHighlight = value;
    markNeedsPaint();
  }

  /// 搜索色带的颜色；`null` 时不画。
  Color? get searchHighlightColor => _searchHighlightColor;
  Color? _searchHighlightColor;
  set searchHighlightColor(Color? value) {
    if (value == _searchHighlightColor) return;
    _searchHighlightColor = value;
    markNeedsPaint();
  }

  /// 最近一次 [paint] 画出的搜索色带块数，供测试确认色带真的落到了正文上。
  @visibleForTesting
  int debugSearchHighlightRects = 0;

  void _paintSearchHighlights(
    Canvas canvas,
    LineDocumentLayout layout,
    ({int from, int to}) range,
    Rect? visible,
  ) {
    final ({String needle, bool caseSensitive})? hit = _searchHighlight;
    final Color? color = _searchHighlightColor;
    if (hit == null || color == null || hit.needle.isEmpty) return;
    if (range.to <= range.from) return;

    // 只扫视口附近这几行：长笔记每帧的匹配成本与屏幕上的字数成正比，而不是
    // 与整篇正文成正比。
    final int windowStart = layout.laidOut[range.from].source.start;
    final int windowEnd = layout.laidOut[range.to - 1].source.end;
    if (windowEnd <= windowStart) return;
    final String window = layout.text.substring(windowStart, windowEnd);
    final RegExp pattern = RegExp(
      RegExp.escape(hit.needle),
      caseSensitive: hit.caseSensitive,
    );
    if (!pattern.hasMatch(window)) return;

    // 表格行是自己的一块纸面：色带若盖在它画完的格子上会把字糊掉，跳过。
    final List<({int start, int end})> blocks = <({int start, int end})>[];
    for (int i = range.from; i < range.to; i++) {
      final LaidOutLine line = layout.laidOut[i];
      if (line.block != null) {
        blocks.add((start: line.source.start, end: line.source.end));
      }
    }

    final Paint paint = Paint()..color = color;
    for (final RegExpMatch match in pattern.allMatches(window)) {
      final int start = windowStart + match.start;
      final int end = windowStart + match.end;
      if (blocks.any(
        (({int start, int end}) r) => start <= r.end && end > r.start,
      )) {
        continue;
      }
      for (final Rect rect in layout.selectionRects(
        start,
        end,
        visible: visible,
      )) {
        canvas.drawRect(rect, paint);
      }
      debugSearchHighlightRects++;
    }
  }

  void _paintSelection(
    Canvas canvas,
    LineDocumentLayout layout,
    Rect? visible,
  ) {
    final TextSelection? value = selection;
    final Color? color = selectionColor;
    if (value == null || !value.isValid || value.isCollapsed || color == null) {
      return;
    }
    final Paint paint = Paint()..color = color;
    for (final Rect rect in layout.selectionRects(
      value.start,
      value.end,
      visible: visible,
    )) {
      canvas.drawRect(rect, paint);
    }
  }

  void _paintText(
    Canvas canvas,
    LineDocumentLayout layout,
    ({int from, int to}) range,
  ) {
    for (int i = range.from; i < range.to; i++) {
      final LaidOutLine line = layout.laidOut[i];
      if (line.height <= 0) continue;
      // 自绘行（表格）的 `TextPainter` 是空的，画在它上面的东西由 block 负责。
      if (line.block != null) continue;
      line.painter.paint(
        canvas,
        Offset(line.gutter, line.top - lineTextRise(line)),
      );
      debugPaintedLines++;
    }
  }

  /// 行内代码的圆角底片，铺在文字**下面**。
  ///
  /// `TextStyle.backgroundColor` 只能是紧贴字形的直角矩形，而旧实现靠两个
  /// widget 端帽撑出内边距和圆角；一行一个 `TextPainter` 没有 widget，所以
  /// 这里按 [LaidOutLine.fills] 自己铺一块圆角矩形，再把字画在上面。
  ///
  /// `==高亮==` 的色块（[LineFillRun.rowBox]）也走这里：上下各内缩
  /// [_kHighlightBandInsetY]，与参考项目 EPUB Reader V7 一致。
  static const double _kHighlightBandInsetY = 0.16;

  void _paintFills(
    Canvas canvas,
    LineDocumentLayout layout,
    ({int from, int to}) range,
  ) {
    final Paint paint = Paint();
    for (int i = range.from; i < range.to; i++) {
      final LaidOutLine line = layout.laidOut[i];
      if (line.fills.isEmpty || line.height <= 0) continue;
      final TextPainter tp = line.painter;
      final Offset origin = Offset(line.gutter, line.top - lineTextRise(line));
      for (final LineFillRun run in line.fills) {
        final List<TextBox> boxes = tp.getBoxesForSelection(
          TextSelection(baseOffset: run.from, extentOffset: run.to),
        );
        if (boxes.isEmpty) continue;
        // 底片高度与基线第一次绘制时量一次，之后直接读缓存：
        // 每帧为每个行内代码片段新建 `TextPainter` 是滚动路径上的固定开销。
        // `rowBox`（`==高亮`）不用量：它直接铺满视觉行盒，和选区同高。
        double? height = run.measuredHeight;
        double? drop = run.measuredDrop;
        if (!run.rowBox && (height == null || drop == null)) {
          final TextPainter metrics = TextPainter(
            text: TextSpan(
              text: run.probe.isEmpty ? ' ' : run.probe,
              style: run.style,
            ),
            textDirection: textDirection,
            textScaler: textScaler,
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

        // 一条代码可以折行：每个视觉行各铺一块。分组的依据必须是视觉行，
        // 而不是盒子的 `top`——被压成零号字的反引号和代码正文字号不同，
        // 即使在同一行，两者的盒子上下沿也差好几个像素。
        final List<double> baselines =
            line.visualBaselines ??= <double>[
              for (final LineMetrics metrics in tp.computeLineMetrics())
                metrics.baseline,
            ];
        final List<({int line, double left, double right})> groups =
            groupFillBoxesByLine(boxes, baselines);
        for (final ({int line, double left, double right}) group in groups) {
          final double top;
          final double bottom;
          if (run.rowBox) {
            // `==高亮==` 的色块：视觉行盒来自引擎算好的 `visuals`（不受
            // `lineTextRise` 上提影响），再上下各内缩 [_kHighlightBandInsetY]。
            // 参考项目 EPUB Reader V7 的内缩比例是 0.16：色带 ≈ 1.2em，
            // 罩得住字形、又给相邻行留出呼吸位。
            final VisualLine visual = line.visuals[group.line];
            final double insetY = visual.height * _kHighlightBandInsetY;
            top = line.top + visual.top + insetY;
            bottom = line.top + visual.top + visual.height - insetY;
          } else {
            final double baseline = baselines[group.line];
            top = origin.dy + baseline - drop! - run.padY;
            bottom = top + height!;
          }
          // 标签的内边距没有字符位可占，只能把底片向两侧多铺几个像素；
          // 夹取要在**画布坐标**里做（先加 origin）：行首让出的内边距正是靠
          // 这一步生效的，若先在画笔局部坐标夹再平移，让出的位置会被平移
          // 原样吃掉，字又贴回底片边缘。
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

  void _paintMarkers(
    Canvas canvas,
    LineDocumentLayout layout,
    ({int from, int to}) range,
  ) {
    final LineMarkerStyle? style = _markerStyle;
    if (style == null) return;
    final Paint railPaint = Paint()..color = style.rail;
    for (int index = range.from; index < range.to; index++) {
      final LaidOutLine line = layout.laidOut[index];
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
        // 与旧实现同一个构造：2px 宽、离正文列左边 2px。高度不能只取第一条
        // 视觉行——一段话软换行后，第二、第三行也是同一句引用的组成部分，
        // 竖线要一直铺到最后一条视觉行的底边。连续引用行首尾相接，读起来
        // 是一根连续的线。
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
      // 缩进槽里没有字形：点在它上面等于点在正文左侧的空白，必须让给正文
      // 定位。否则隐藏态会把落点夹回 `markerStart` 并摊开标记，光标停在
      // `3. ` 前面，接着输入就把文字插进标记里（`qie'huan3. [ ]`）。
      if (local.dx < line.slot.indent) continue;
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
    // 布局没换、滚动没动时，箭头几何逐像素相同。指针移动会高频问这一份，
    // 全篇重建是白费工；返回同一个列表实例也让上层可以按引用判断稳定性。
    final List<ListFoldHandle>? cached = _foldHandles;
    if (cached != null &&
        identical(_foldHandlesLayout, layout) &&
        _foldHandlesOrigin == origin) {
      return cached;
    }
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
    _foldHandles = handles;
    _foldHandlesLayout = layout;
    _foldHandlesOrigin = origin;
    return handles;
  }

  List<ListFoldHandle>? _foldHandles;
  LineDocumentLayout? _foldHandlesLayout;
  Offset? _foldHandlesOrigin;

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
    final List<Rect>? cached = _checkboxRects;
    if (cached != null &&
        identical(_checkboxRectsLayout, layout) &&
        _checkboxRectsOrigin == origin) {
      return cached;
    }
    final List<Rect> rects = <Rect>[
      for (final LaidOutLine line in layout.laidOut)
        if (line.source.kind == LineBlockKind.task &&
            line.height > 0 &&
            !line.slot.revealedMarkers)
          checkboxRectOf(line, layout.metrics).shift(origin),
    ];
    _checkboxRects = rects;
    _checkboxRectsLayout = layout;
    _checkboxRectsOrigin = origin;
    return rects;
  }

  List<Rect>? _checkboxRects;
  LineDocumentLayout? _checkboxRectsLayout;
  Offset? _checkboxRectsOrigin;

  /// IME 组合区间用一条下划线标出。
  void _paintComposing(
    Canvas canvas,
    LineDocumentLayout layout,
    Rect? visible,
  ) {
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
      visible: visible,
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
    // 换笔记时这个渲染对象整块销毁：布局先挂进跨文档池，切回时才不用整篇
    // 重排。布局已经作废（样式/折叠变化丢掉过）时这里什么也不做。
    _parkLayout();
    _lineLayout?.dispose();
    _lineLayout = null;
    _lineCache.dispose();
    _layoutText = null;
    _layoutStyle = null;
    _layoutWidth = null;
    _layoutReveal = null;
    _layoutPoolKey = null;
    _pendingRevealDirty = null;
    super.dispose();
  }
}

/// 把一段底片的框按视觉行合并。
///
/// 不能按 `top` 分组：零号字的反引号端帽和代码正文在同一视觉行，盒子上沿
/// 却差着几个像素，按 `top` 会拆成三块、把内边距画成独立的竖条。这里改用
/// 离盒子中心最近的基线认行；同一行的左右端点取并集，折行的代码才会在
/// 每行各留一块。
@visibleForTesting
List<({int line, double left, double right})> groupFillBoxesByLine(
  List<TextBox> boxes,
  List<double> baselines,
) {
  if (boxes.isEmpty || baselines.isEmpty) {
    return const <({int line, double left, double right})>[];
  }
  final List<double?> left = List<double?>.filled(baselines.length, null);
  final List<double?> right = List<double?>.filled(baselines.length, null);
  for (final TextBox box in boxes) {
    final double center = (box.top + box.bottom) / 2;
    int line = 0;
    double nearest = (baselines[0] - center).abs();
    for (int i = 1; i < baselines.length; i++) {
      final double distance = (baselines[i] - center).abs();
      if (distance < nearest) {
        nearest = distance;
        line = i;
      }
    }
    left[line] = left[line] == null
        ? box.left
        : math.min(left[line]!, box.left);
    right[line] = right[line] == null
        ? box.right
        : math.max(right[line]!, box.right);
  }
  return <({int line, double left, double right})>[
    for (int i = 0; i < baselines.length; i++)
      if (left[i] != null) (line: i, left: left[i]!, right: right[i]!),
  ];
}
