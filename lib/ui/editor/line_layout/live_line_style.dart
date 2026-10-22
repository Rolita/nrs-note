/// 把 live markdown 的块样式接到按行排版引擎上。
///
/// 引擎（阶段 0）只认识 [SourceLine]，live 层只认识自己的块判定；这个文件是
/// 两者之间唯一的胶水：行种类 → 排版样式、行种类 → 固定行高。样式本身不在
/// 这里定义，全部来自 `live_markdown/typography.dart` 的公开入口，避免按行
/// 排版和段落排版各自维护一套字号。
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../../../core/theme/app_palette.dart';
import '../../preview/syntax_highlighter.dart';
import '../live_markdown.dart';
import 'line_layout_engine.dart';
import 'line_marker_style.dart';

/// 按行取 live markdown 的排版样式与行高。
///
/// 实例按「正文样式 + 调色板」构造，可以直接把 [styleFor] / [heightFor]
/// 交给 `layoutLines`，或交给 `LineEditableText` 的 `lineStyleFor` /
/// `lineHeightFor`。两者都实现了值相等，重建等价的实例不会让渲染层丢掉
/// 布局缓存。
class LiveLineStyle {
  LiveLineStyle({
    required this.base,
    required this.palette,
    this.reveal,
    this.hoverTag,
    this.source = '',
    this.markerRevealLine,
  });

  /// 正文样式（`editorProseStyle` 的产物）。
  final TextStyle base;

  /// 当前主题的调色板：标题、代码、引用都要取色。
  final AppPalette palette;

  /// 揭示用的选区（`revealAs ?? selection`），调用时才读。
  ///
  /// 落在它覆盖范围内的行把 Markdown 标记摊开：标题的 `# `、引用的 `>`、
  /// 围栏的 ```` ``` ````、行内的 `**`。拖动期间宿主把它冻结在按下时的选区上，
  /// 所以不能直接读控制器的当前选区——那会让标记在指针底下反复出现、行宽
  /// 反复变化。
  final TextSelection? Function()? reveal;

  /// 指针悬停的标签（文档偏移区间），`null` 表示没有。
  ///
  /// 按行排版没有 widget 可以挂 `MouseRegion`，悬停由编辑器侧命中后写进这个值
  /// ——它是一个**值**而不是回调，才能参与 [==]：悬停切换时渲染层要重新排版，
  /// 颜色是烤进每行 `TextPainter` 的，光重画不够。
  final TextRange? hoverTag;

  /// 整篇源码。
  ///
  /// 代码高亮必须按整个围栏块扫描——块注释、跨行字符串只有看到整块才知道
  /// 边界；按行排版一次只拿得到一行，所以把全文带进来，一次算完再按行首
  /// 偏移索引回去。普通段落不受它影响。
  final String source;

  /// 代码行首偏移 → 该行的 token；首次排版时算一次，实例存活期间复用。
  Map<int, List<CodeToken>>? _codeTokens;

  /// 跨实例的围栏块分词缓存。
  ///
  /// 键是「语言 + 块正文」：块外文字变化时块正文没变，分词结果可以原样
  /// 复用。只保留最近 8 块，长文档里不会把每个历史代码块都留在内存。
  static final LinkedHashMap<(String?, String), List<List<CodeToken>>>
      _blockTokens = LinkedHashMap<(String?, String), List<List<CodeToken>>>();
  static const int _blockCacheLimit = 8;

  /// [line] 里被悬停的标签摘要成这一行内部的偏移；没有则为 `null`。
  ({int a, int b})? _hoverIn(SourceLine line) {
    final TextRange? tag = hoverTag;
    if (tag == null) return null;
    final int at = line.paintStart;
    if (tag.start < at || tag.end > line.end) return null;
    return (a: tag.start - at, b: tag.end - at);
  }

  /// 这一行是否在揭示范围内。
  ///
  /// 判据与段落排版一致：选区**覆盖到**这一行的任意字符就算，所以框选整段
  /// 文档时每一行的标记都是展开的。
  bool _revealed(SourceLine line) {
    final TextSelection? sel = reveal?.call();
    if (sel == null || !sel.isValid || sel.start < 0) return false;
    return sel.end >= line.start && sel.start <= line.end;
  }

  /// 用户点开了哪一行的列表标记（行首偏移），`null` 表示都照常画在槽位里。
  ///
  /// 这是一个值而不是从 [reveal] 推出来的：光标停在行首是常态（刚绑定笔记、
  /// Ctrl+Home），按选区判断会让第一行是列表的笔记一打开就露出源码。
  final int? markerRevealLine;

  /// 这一行的列表标记是否要摊进正文。
  ///
  /// 判断依据与引擎的 `markersInline` 必须一致：只有 [markerRevealLine] 这一行
  /// 展开。点标记本身才展开，点正文立刻收起——这样 `- ` / `1. ` / `[ ] ` 能被
  /// 鼠标点到、被键盘改，而正文永远保持渲染态。
  bool markersInline(SourceLine line) =>
      line.isList && markerRevealLine == line.start;

  /// 光标是否**就停在**这一行上（折叠选区）。
  ///
  /// 表格分隔行只在这个条件下显形：框选一张表是最常见的操作，而
  /// `| --- | --- |` 在洗色中间露出一行，会把一张表撕成两段。
  bool _caretOn(SourceLine line) {
    final TextSelection? sel = reveal?.call();
    if (sel == null || !sel.isValid || !sel.isCollapsed) return false;
    return sel.start >= line.start && sel.start <= line.end;
  }

  /// 这一行的排版样式。
  TextStyle styleFor(SourceLine line) {
    switch (line.kind) {
      case LineBlockKind.heading:
        // setext 标题在扫描时已被改判成 heading，级别由扫描器填 1。
        return line.headingLevel > 0
            ? liveHeadingStyle(base, palette, line.headingLevel)
            : base;
      case LineBlockKind.code:
        return liveCodeLineStyle(base, palette);
      case LineBlockKind.fence:
        // 折叠的围栏不落墨：它只占住卡片头那一行，源码本来就不该在画面上。
        // 光标落上去时才展开成一行源码。
        if (!_revealed(line)) return liveCollapsedStyle(base);
        return liveMarkerStyle(
          liveCodeLineStyle(base, palette),
          palette,
          accented: true,
        );
      case LineBlockKind.setext:
        // `===` 已经完成了它的职责，保留行高但不画字；光标落上去时显形。
        return _revealed(line)
            ? liveMarkerStyle(base, palette)
            : liveInvisibleStyle(base);
      case LineBlockKind.quote:
        return base.copyWith(color: palette.textSecondary);
      case LineBlockKind.rule:
        // 分隔线本身由渲染层画成一条横线；`---` 只在光标落上去时显形，
        // 否则画面上会同时出现一条线和三个减号。
        return _revealed(line)
            ? liveMarkerStyle(base, palette)
            : liveInvisibleStyle(base);
      case LineBlockKind.task:
        // 勾掉的任务整体降一档并划掉，和复选框一起把「做完了」说清楚。
        return line.checked ? liveTaskDoneStyle(base, palette) : base;
      case LineBlockKind.tableDivider:
        // 分隔行不占像素：表头的底边由表格自己画。光标落上去时才显形，
        // 否则它会在「表头」和「第一行」之间空出一整行正文高。
        return _caretOn(line) ? base : liveCollapsedStyle(base);
      case LineBlockKind.paragraph:
      case LineBlockKind.bullet:
      case LineBlockKind.ordered:
      case LineBlockKind.table:
      case LineBlockKind.tableHeader:
        return base;
    }
  }

  /// 这一行交给 `TextPainter` 的 span 树。
  ///
  /// 只解析**行内**语法（加粗、斜体、行内代码、链接、`#标签`）；块级标记
  /// （标题的 `#`、引用的 `>`）按揭示范围决定显形还是折叠，列表标记则根本
  /// 不进正文（[SourceLine.paintStart] 已经跳过了它们）。
  ///
  /// 返回值的 `toPlainText()` 必须与 `text.substring(paintStart, end)` 逐字符
  /// 相同，否则按行排版的偏移映射会整体错位；对不上时退回纯文本。
  InlineSpan spanFor(SourceLine line) {
    final TextStyle style = styleFor(line);
    // 标记摊进正文时，`- ` / `1. ` / `[ ] ` 必须是这一行排出来的字符，
    // 偏移映射才认得出它们；否则它们仍画在槽位里、由渲染层负责。
    final bool inline = markersInline(line);
    final int at = inline ? line.start : line.paintStart;
    final String body = line.text.substring(at - line.start);
    if (body.isEmpty) return TextSpan(text: '', style: style);

    final bool on = _revealed(line);
    final ({int a, int b})? hover = _hoverIn(line);
    if (line.kind == LineBlockKind.code) {
      // 代码行没有行内语法，但有自己的整块高亮；颜色按 token 铺在字上。
      final List<CodeToken>? tokens = _tokensFor(line);
      final InlineSpan highlighted = TextSpan(
        style: style,
        children: tokens == null
            ? <InlineSpan>[TextSpan(text: body)]
            : codeHighlightSpans(tokens, palette.isDark),
      );
      return highlighted.toPlainText() == body
          ? highlighted
          : TextSpan(text: body, style: style);
    }
    if (inline) {
      // 标记按「标记样式」上屏，后半段照常解析行内语法；两段合起来的纯文本
      // 仍然是整行源码，引擎的偏移映射对得上。
      final int prefixLength = line.paintStart - line.start;
      final String prefix = body.substring(0, prefixLength);
      final String rest = body.substring(prefixLength);
      final InlineSpan marked = TextSpan(
        style: style,
        children: <InlineSpan>[
          TextSpan(text: prefix, style: liveMarkerStyle(style, palette)),
          if (rest.isNotEmpty)
            _inlineOrPlain(rest, style, at + prefixLength, hover: hover),
        ],
      );
      return marked.toPlainText() == body
          ? marked
          : TextSpan(text: body, style: style);
    }
    final InlineSpan span;
    switch (line.kind) {
      case LineBlockKind.code:
      case LineBlockKind.fence:
      case LineBlockKind.setext:
      case LineBlockKind.table:
      case LineBlockKind.tableHeader:
      case LineBlockKind.tableDivider:
      case LineBlockKind.rule:
        // 围栏/分隔行没有行内语法，逐字排版即可。
        span = TextSpan(text: body, style: style);
      case LineBlockKind.heading:
        span = _withPrefix(
          body,
          style,
          _kHeadingPrefix,
          at,
          accent: true,
          on: on,
          hover: hover,
        );
      case LineBlockKind.quote:
        span = _withPrefix(
          body,
          style,
          _kQuotePrefix,
          at,
          accent: false,
          on: on,
          hover: hover,
          // 引用的 `>` 未揭示时透明但仍占着 `> ` 的宽度：左侧那条强调色竖线
          // 就画在这个空位里，正文依旧从竖线右侧起排。压成零宽会让竖线没有
          // 落脚处，只能压在第一个字上。
          keepMarkerWidth: true,
        );
      default:
        span = _inlineOrPlain(body, style, at, hover: hover);
    }
    return span.toPlainText() == body
        ? span
        : TextSpan(text: body, style: style);
  }

  /// 这一行要铺在文字下面的圆角底片（行内代码、`#标签`）。
  ///
  /// 一行 `TextPainter` 没有 widget 端帽，`TextStyle.backgroundColor` 又只能
  /// 是紧贴字形的直角矩形，所以胶囊由渲染层按这份区间自己画。区间和 span 树
  /// 出自同一个扫描器：光标落在代码/标签里时那边会退回源码，这边就不会给出
  /// 底片。
  List<LineFillRun> fillsFor(SourceLine line) {
    switch (line.kind) {
      case LineBlockKind.code:
      case LineBlockKind.fence:
      case LineBlockKind.setext:
      case LineBlockKind.table:
      case LineBlockKind.tableHeader:
      case LineBlockKind.tableDivider:
      case LineBlockKind.rule:
        return const <LineFillRun>[];
      default:
        break;
    }
    // 标记摊进正文时底片也要按整行算，否则胶囊会整体左移一个标记宽度。
    final bool inline = markersInline(line);
    final int at = inline ? line.start : line.paintStart;
    final String body = line.text.substring(at - line.start);
    final TextSelection? sel = reveal?.call();
    final bool valid =
        sel != null &&
        sel.isValid &&
        sel.start >= 0 &&
        sel.end >= at &&
        sel.start <= at + body.length;
    final ({int a, int b})? hover = _hoverIn(line);
    // `_hoverIn` 的偏移相对正文起点；标记摊开时要把前缀长度加回去。
    final int shift = inline ? line.paintStart - line.start : 0;
    return inlineFills(
      body,
      base: styleFor(line),
      p: palette,
      caretA: valid ? math.max(0, sel.start - at) : -1,
      caretB: valid ? math.min(body.length, sel.end - at) : -1,
      hoverA: hover == null ? -1 : hover.a + shift,
      hoverB: hover == null ? -1 : hover.b + shift,
    );
  }

  /// 行内语法；[at] 是 [body] 第一个字符的文档偏移。
  ///
  /// [buildLiveInlineSpan] 只认识这一行内部的偏移，所以把揭示选区减掉 [at]；
  /// 选区整段落在这一行之前/之后时直接当作「没碰到」，否则减出来的负数会
  /// 被 `touched` 读成「从 0 开始」。
  InlineSpan _inlineOrPlain(
    String body,
    TextStyle style,
    int at, {
    ({int a, int b})? hover,
  }) {
    final TextSelection? sel = reveal?.call();
    final bool valid =
        sel != null &&
        sel.isValid &&
        sel.start >= 0 &&
        sel.end >= at &&
        sel.start <= at + body.length;
    return buildLiveInlineSpan(
      body,
      base: style,
      p: palette,
      // 选区从这一行之前开始（框选整段）时，夹到正文起点，这一行的行内标记
      // 也应该展开。
      caretA: valid ? math.max(0, sel.start - at) : -1,
      caretB: valid ? math.min(body.length, sel.end - at) : -1,
      hoverA: hover?.a ?? -1,
      hoverB: hover?.b ?? -1,
    );
  }

  /// 块级前缀（`#`、`>`）：揭示时显形，否则压成零宽；剩下的正文照常解析。
  ///
  /// [keepMarkerWidth] 让未揭示的前缀只透明、不缩字：引用的竖线要占住
  /// `> ` 原来的宽度，同时揭示前后正文的起点保持不变，不会左右跳一下。
  InlineSpan _withPrefix(
    String body,
    TextStyle style,
    RegExp prefixPattern,
    int at, {
    required bool accent,
    required bool on,
    bool keepMarkerWidth = false,
    ({int a, int b})? hover,
  }) {
    final Match? m = prefixPattern.firstMatch(body);
    if (m == null) return _inlineOrPlain(body, style, at, hover: hover);
    final String prefix = m.group(1)!;
    final String rest = body.substring(prefix.length);
    return TextSpan(
      style: style,
      children: <InlineSpan>[
        TextSpan(
          text: prefix,
          style: on
              ? liveMarkerStyle(style, palette, accented: accent)
              : keepMarkerWidth
              ? liveInvisibleStyle(style)
              : liveCollapsedStyle(style),
        ),
        if (rest.isNotEmpty)
          _inlineOrPlain(
            rest,
            style,
            at + prefix.length,
            hover: hover == null
                ? null
                : (a: hover.a - prefix.length, b: hover.b - prefix.length),
          ),
      ],
    );
  }

  /// 列表标记（圆点 / 序号 / 复选框 / 导轨）的绘制样式。
  LineMarkerStyle get markers => LineMarkerStyle(
    bullet: palette.textTertiary.withValues(alpha: 0.9),
    rail: palette.rule,
    accent: palette.accent,
    onAccent: palette.onAccent,
    // 与旧实现同一个推导：描边比 `rule` 亮一档，且随主题自适应。
    boxBorder: Color.alphaBlend(
      palette.textTertiary.withValues(alpha: 0.55),
      palette.rule,
    ),
    muted: palette.textSecondary,
    number: liveNumberStyle(base, palette),
  );

  /// 这一行的左右内边距。
  ///
  /// 代码块卡片是唯一的例子：卡片底色铺满正文列，代码要左右各退
  /// [kCodeBlockInset] 才不会贴着卡片的边。围栏行（卡片头）也一起退，光标
  /// 落上去展开源码时那一行才会跟正文对齐。
  EdgeInsets insetFor(SourceLine line) {
    switch (line.kind) {
      case LineBlockKind.code:
      case LineBlockKind.fence:
        return const EdgeInsets.symmetric(horizontal: kCodeBlockInset);
      default:
        return EdgeInsets.zero;
    }
  }

  /// 固定行高；`null` 表示按测量结果。
  ///
  /// 折叠的围栏是唯一的例子：开围栏只留卡片头（16px），闭围栏压成 0，
  /// 否则代码块上下会各多出一整行正文高的空白。光标落上去时它展开成一行
  /// 源码，行高交回测量。
  double? heightFor(SourceLine line) {
    if (line.kind == LineBlockKind.tableDivider) {
      return _caretOn(line) ? null : 0;
    }
    if (line.kind != LineBlockKind.fence) return null;
    if (_revealed(line)) return null;
    return line.fenceOpens ? liveCodeHeaderHeight : 0;
  }

  /// 代码行首偏移 → 该行 token；没有对应块时返回 `null`（退回纯文本）。
  List<CodeToken>? _tokensFor(SourceLine line) =>
      (_codeTokens ??= _highlightBlocks())[line.start];

  /// 取一个围栏块的分词结果，命中时把它移到 LRU 队尾。
  static List<List<CodeToken>> _highlightBlock(String body, String? label) {
    final (String?, String) key = (label, body);
    final List<List<CodeToken>>? cached = _blockTokens.remove(key);
    if (cached != null) {
      _blockTokens[key] = cached;
      return cached;
    }
    final List<List<CodeToken>> tokens = highlightCode(body, label);
    _blockTokens[key] = tokens;
    if (_blockTokens.length > _blockCacheLimit) {
      _blockTokens.remove(_blockTokens.keys.first);
    }
    return tokens;
  }

  /// 把每个围栏块的正文整块交给高亮器，再把逐行 token 按行首偏移拆回来。
  Map<int, List<CodeToken>> _highlightBlocks() {
    final Map<int, List<CodeToken>> out = <int, List<CodeToken>>{};
    if (source.isEmpty) return out;
    for (final CodeBlockRange block in codeBlockRanges(source)) {
      // 正文从围栏行之后开始，到闭合围栏所在行的前一个换行为止。收缩成
      // `clamp` 而不是「找不到就跳过」，是为了未闭合的围栏也能一路着色到底。
      final int openEnd = source.indexOf('\n', block.start);
      final int bodyStart = openEnd < 0 ? source.length : openEnd + 1;
      int bodyEnd = source.length;
      if (block.closed) {
        final int closeLine = source.lastIndexOf('\n', block.end - 1);
        bodyEnd = closeLine < bodyStart ? bodyStart : closeLine;
      }
      if (bodyStart >= bodyEnd) continue;
      final String body = source.substring(bodyStart, bodyEnd);
      final List<String> rows = body.split('\n');
      final List<List<CodeToken>> tokens = _highlightBlock(body, block.label);
      if (tokens.length != rows.length) continue;
      int offset = bodyStart;
      for (int i = 0; i < rows.length; i++) {
        out[offset] = tokens[i];
        offset += rows[i].length + 1;
      }
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is LiveLineStyle &&
      other.base == base &&
      other.palette == palette &&
      other.reveal == reveal &&
      other.hoverTag == hoverTag &&
      // 源码变了高亮就变了；不参与相等会让渲染层留着旧实例、复用旧 token。
      other.source == source &&
      // 标记摊开与否改变 span 树，也参与相等，免得沿用旧实例。
      other.markerRevealLine == markerRevealLine;

  @override
  int get hashCode =>
      Object.hash(base, palette, reveal, hoverTag, source, markerRevealLine);
}

/// 标题行开头的 `#` 连同它后面的空白。
final RegExp _kHeadingPrefix = RegExp(r'^(\s*#{1,6}\s+)');

/// 引用行开头的 `>`（可嵌套、可带缩进）。
final RegExp _kQuotePrefix = RegExp(r'^(\s*(?:>\s?)+)');
