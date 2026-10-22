part of '../live_markdown.dart';

String _fenceLanguage(String info) {
  String raw = info.trim();
  if (raw.startsWith('{')) raw = raw.replaceAll(RegExp(r'[{}]'), '').trim();
  final Match? m = RegExp(r'^[^\s]+').firstMatch(raw);
  return normaliseLanguage(m?.group(0));
}

/// The language as the block's card shows it: `dart` → `Dart`.
///
/// An unnamed fence gets **no** label: a `text` badge on every plain block is
/// noise, not information.
String? _codeLabel(String language) {
  if (language.isEmpty) return null;
  return language[0].toUpperCase() + language.substring(1);
}

/// 把一段代码的 token 转成带颜色的 span 子节点。
///
/// 按行排版与旧的段落排版共用：颜色只由明暗决定，代码块不会因为光标移动而
/// 换色。
List<InlineSpan> codeHighlightSpans(List<CodeToken> tokens, bool isDark) {
  final CodePalette c = CodePalette.forDark(isDark);
  return <InlineSpan>[
    for (final CodeToken t in tokens)
      TextSpan(
        text: t.text,
        style: t.kind == TokenKind.plain ? null : TextStyle(color: c[t.kind]),
      ),
  ];
}

// ---------------------------------------------------------------- inline scan

/// Inline syntax, scanned left to right. Order matters: the longer, more
/// specific constructs must win the tie at the same start offset.
final RegExp _inlineRe = RegExp(
  r'!?\[\[[^\]\n]+\]\]'
  r'|!?\[[^\]\n]{0,200}\]\([^)\n]{0,500}\)'
  r'|`[^`\n]*`'
  r'|\*\*[^*\n]+\*\*|__[^_\n]+__'
  r'|~~[^~\n]+~~'
  r'|==[^=\n]+=='
  r'|\*[^*\n]+\*|(?<![A-Za-z0-9_])_[^_\n]+_(?![A-Za-z0-9_])'
  r'|#[A-Za-z0-9_\u4e00-\u9fff][A-Za-z0-9_\u4e00-\u9fff\-/\.]*',
);

/// A `#tag` only counts when it starts a word — `C#`, `issue#1` and `#1` do not.
bool _isTagStart(String text, int index) {
  if (index <= 0) return true;
  final String prev = text[index - 1];
  if (RegExp(r'^[\s([{>（【「]$').hasMatch(prev)) return true;
  return false;
}

bool _tagLooksValid(String token) {
  final String body = token.substring(1);
  if (body.isEmpty) return false;
  // `#1`, `#2026` are issue references, not tags.
  if (RegExp(r'^[0-9]+$').hasMatch(body)) return false;
  return true;
}

List<InlineSpan> _inline(
  String text,
  TextStyle body,
  int absStart,
  _Ctx ctx, {
  TextStyle? forceStyle,
  List<_CellCode>? codeRuns,
}) {
  if (text.isEmpty) return const <InlineSpan>[];
  final AppPalette p = ctx.p;
  final TextStyle style = forceStyle ?? body;
  final List<InlineSpan> spans = <InlineSpan>[];
  int cursor = 0;

  for (final RegExpMatch m in _inlineRe.allMatches(text)) {
    final String token = m.group(0)!;
    if (token.startsWith('#')) {
      if (!_isTagStart(text, m.start) || !_tagLooksValid(token)) continue;
    }
    if (m.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, m.start), style: style));
    }
    final bool open = ctx.touched(absStart + m.start, absStart + m.end);
    final TextStyle mark = open ? _markerVisible(body, p) : _collapsed(body);

    if (token.startsWith('#')) {
      final String tag = token.substring(1);
      if (open) {
        // 编辑态：胶囊撤掉，露出源码（强调色的 `#标签`）。
        spans.add(TextSpan(text: token, style: _tagText(style, p)));
      } else if (ctx.plain) {
        // 按行排版没有 widget 胶囊：字换成胶囊内部的字号/字重；底片（accentSoft
        // 圆角块）由渲染层按同一区间铺——区间和 span 树同出一次扫描。
        final bool lit = ctx.hovered(m.start, m.end);
        final TextStyle chip = _tagChipText(style, p, hovered: lit);
        spans.add(TextSpan(text: token, style: chip));
        codeRuns?.add(
          _CellCode(
            start: m.start,
            end: m.end,
            probe: token,
            style: chip,
            fill: lit ? p.accent : p.accentSoft,
            radius: kTagRadius,
            padX: kTagPadX,
          ),
        );
      } else if (ctx.onTagTap == null) {
        spans.add(TextSpan(text: token, style: _tagText(style, p)));
      } else {
        spans.add(_tagChip(p, tag, style, ctx.onTagTap!));
        spans.add(_swallowed(token, body));
      }
    } else if (token.startsWith('`')) {
      final String inner = token.substring(1, token.length - 1);
      final int from = absStart + m.start;
      final int to = absStart + m.end;
      final Color fill = ctx.selected(from, to)
          ? _selectedChip(p)
          : p.surfaceSunken;
      if (open) {
        // Editing: the fill drops away and the source shows — backticks and
        // all. Leaving the chip on made a span that was being edited still
        // look rendered, user: 「选中后没有恢复成编辑态」.
        final TextStyle source = _inlineCodeSource(body, p);
        final TextStyle tick = _markerVisible(source, p);
        spans.add(TextSpan(text: '`', style: tick));
        spans.add(TextSpan(text: inner, style: source));
        spans.add(TextSpan(text: '`', style: tick));
      } else if (ctx.plain) {
        // A cell is a `TextPainter`: it has no room for the widget caps the
        // prose chip uses, and a `TextStyle` background can never be padded or
        // rounded. So the ends still reserve the padding — a collapsed
        // character's advance is exactly its `letterSpacing` — and the row
        // renderer paints one rounded band behind the range.
        final TextStyle source = _inlineCodeSource(body, p);
        final TextStyle edge = mark.copyWith(
          letterSpacing: ctx.textScaler.scale(_kInlineCodePad),
        );
        spans.add(TextSpan(text: '`', style: edge));
        spans.add(TextSpan(text: inner, style: source));
        spans.add(TextSpan(text: '`', style: edge));
        codeRuns?.add(
          _CellCode(
            start: m.start,
            end: m.end,
            probe: inner,
            style: source,
            fill: fill,
          ),
        );
      } else {
        // The backticks are the chip's two ends: each collapses into a cap as
        // wide as the padding the text needs, and rounds its outward corners.
        // The run in between keeps its own background, so the three pieces
        // read as one rounded chip — a `TextSpan` background alone is always a
        // hard-edged rectangle flush with the glyphs.
        final TextStyle source = _inlineCodeSource(body, p);
        final double pad = ctx.textScaler.scale(_kInlineCodePad);
        final double radius = ctx.textScaler.scale(_kInlineCodeRadius);
        final bool ltr = ctx.direction == TextDirection.ltr;
        spans.add(
          _baselineDecoration(
            _InlineCodeEnd(
              width: pad,
              radius: radius,
              color: fill,
              roundStart: ltr,
              probe: inner,
              style: source,
              textDirection: ctx.direction,
              textScaler: ctx.textScaler,
            ),
          ),
        );
        spans.add(TextSpan(text: inner, style: _inlineCode(body, p, fill)));
        spans.add(
          _baselineDecoration(
            _InlineCodeEnd(
              width: pad,
              radius: radius,
              color: fill,
              roundStart: !ltr,
              probe: inner,
              style: source,
              textDirection: ctx.direction,
              textScaler: ctx.textScaler,
            ),
          ),
        );
      }
    } else if (token.startsWith('**') || token.startsWith('__')) {
      spans.add(TextSpan(text: token.substring(0, 2), style: mark));
      spans.add(
        TextSpan(
          text: token.substring(2, token.length - 2),
          style: style.copyWith(fontWeight: FontWeight.w700),
        ),
      );
      spans.add(TextSpan(text: token.substring(token.length - 2), style: mark));
    } else if (token.startsWith('~~')) {
      spans.add(TextSpan(text: '~~', style: mark));
      spans.add(
        TextSpan(
          text: token.substring(2, token.length - 2),
          // Same rule as a ticked task: one thickness, painted in the colour of
          // the run it crosses. A `~~` word keeps its own colour, so this is
          // the only cue that it is struck at all.
          style: _struck(style),
        ),
      );
      spans.add(TextSpan(text: '~~', style: mark));
    } else if (token.startsWith('==')) {
      spans.add(TextSpan(text: '==', style: mark));
      spans.add(
        TextSpan(
          text: token.substring(2, token.length - 2),
          style: style.copyWith(backgroundColor: p.warningSoft),
        ),
      );
      spans.add(TextSpan(text: '==', style: mark));
    } else if (token.startsWith('[[') || token.startsWith('![[')) {
      final bool embed = token.startsWith('!');
      final String inner = token.substring(embed ? 3 : 2, token.length - 2);
      if (open ||
          ctx.plain ||
          ctx.onWikilinkTap == null ||
          inner.trim().isEmpty) {
        spans.add(TextSpan(text: token, style: _wikiText(style, p)));
      } else {
        spans.add(
          embed
              ? _embedChip(p, inner, ctx.onWikilinkTap!)
              : _wikiChip(p, inner, style, ctx.onWikilinkTap!),
        );
        spans.add(_swallowed(token, body));
      }
    } else if (token.startsWith('![') || token.startsWith('[')) {
      final bool image = token.startsWith('![');
      final int openLen = image ? 2 : 1;
      final int close = token.indexOf(']');
      final String label = token.substring(openLen, close);
      final String url = token.substring(close + 2, token.length - 1);
      if (open) {
        spans.add(TextSpan(text: token.substring(0, openLen), style: mark));
        spans.add(
          TextSpan(
            text: label,
            style: image ? _wikiText(style, p) : _linkText(style, p),
          ),
        );
        spans.add(TextSpan(text: token.substring(close), style: mark));
      } else if (image && url.trim().isNotEmpty && !ctx.plain) {
        spans.add(_imageSpan(p, url.trim(), label, ctx.contentWidth));
        spans.add(_swallowed(token, body));
      } else if (image) {
        if (ctx.plain) {
          // A cell cannot host the image widget; show the alt text and keep
          // the rest of the token, so the length invariant still holds.
          spans.add(TextSpan(text: token.substring(0, openLen), style: mark));
          spans.add(TextSpan(text: label, style: _wikiText(style, p)));
          spans.add(TextSpan(text: token.substring(close), style: mark));
        } else {
          spans.add(TextSpan(text: token, style: mark));
        }
      } else if (ctx.plain) {
        spans.add(TextSpan(text: token.substring(0, openLen), style: mark));
        spans.add(TextSpan(text: label, style: _linkText(style, p)));
        spans.add(TextSpan(text: token.substring(close), style: mark));
      } else {
        spans.add(_linkChip(p, label.isEmpty ? url : label, style));
        spans.add(_swallowed(token, body));
      }
    } else {
      spans.add(TextSpan(text: token.substring(0, 1), style: mark));
      spans.add(
        TextSpan(
          text: token.substring(1, token.length - 1),
          style: style.copyWith(fontStyle: FontStyle.italic),
        ),
      );
      spans.add(TextSpan(text: token.substring(token.length - 1), style: mark));
    }
    cursor = m.end;
  }

  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: style));
  }
  return spans;
}

/// The cell's context in **edit mode**: every inline token in `[from, to]` is
/// revealed, as if the caret were on all of them at once.
///
/// [touched] opens only the token the caret overlaps; a cell in edit mode shows
/// the source of the whole cell, so the cell's own range is handed to it.
/// `plain` stays true: the cell is still painted by a `TextPainter` and cannot
/// host the chips' widgets, so source is the only honest "editing" look.
_Ctx _cellEditCtx(_Ctx ctx, int from, int to) => _Ctx(
  p: ctx.p,
  caretA: from,
  caretB: to,
  selA: ctx.selA,
  selB: ctx.selB,
  contentWidth: ctx.contentWidth,
  direction: ctx.direction,
  textScaler: ctx.textScaler,
  plain: true,
  onTagTap: ctx.onTagTap,
  onWikilinkTap: ctx.onWikilinkTap,
);

// ------------------------------------------------- 按行渲染器（line_layout）入口

/// 一行正文的行内样式树，供按行排版的 `TextPainter` 使用。
///
/// 和段落渲染共用同一套扫描器，唯一区别是 `plain: true`：chip 一律降级成等长
/// 的 [TextSpan]，因为一个只负责自己这一行的 `TextPainter` 承载不了 widget。
/// 标记字符仍然发出，只是被 `_collapsed` 压成零宽，所以
/// `toPlainText()` 与 [text] 逐字符相同 —— 按行排版的偏移映射靠这个前提。
///
/// [caretA] / [caretB] 是**这一行内部**的揭示范围（已经减掉行首偏移），传
/// `-1` 表示没有光标在这一行，所有标记都折叠、这一行看起来是完成的。
InlineSpan buildLiveInlineSpan(
  String text, {
  required TextStyle base,
  required AppPalette p,
  int caretA = -1,
  int caretB = -1,
  int hoverA = -1,
  int hoverB = -1,
  double contentWidth = 680,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
}) {
  if (text.isEmpty) return TextSpan(text: '', style: base);
  return TextSpan(
    style: base,
    children: _inline(
      text,
      base,
      0,
      _Ctx(
        p: p,
        caretA: caretA,
        caretB: caretB,
        selA: -1,
        selB: -1,
        contentWidth: contentWidth,
        direction: direction,
        textScaler: textScaler,
        plain: true,
        hoverA: hoverA,
        hoverB: hoverB,
      ),
    ),
  );
}

/// 一行里行内代码与 `#标签` 的圆角底片区间（行内偏移，含两侧反引号）。
///
/// 和 [buildLiveInlineSpan] 用的是同一个扫描器、同一份 `plain` 上下文，所以
/// 「哪些反引号算代码」「哪些 `#` 算标签」「光标落在里面时退回源码」这些规则
/// 只有一处实现：底片不会和 span 树各说各话。
List<LineFillRun> inlineFills(
  String text, {
  required TextStyle base,
  required AppPalette p,
  int caretA = -1,
  int caretB = -1,
  int hoverA = -1,
  int hoverB = -1,
}) {
  if (!text.contains('`') && !text.contains('#')) {
    return const <LineFillRun>[];
  }
  final List<_CellCode> runs = <_CellCode>[];
  _inline(
    text,
    base,
    0,
    _Ctx(
      p: p,
      caretA: caretA,
      caretB: caretB,
      selA: -1,
      selB: -1,
      contentWidth: 680,
      direction: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      plain: true,
      hoverA: hoverA,
      hoverB: hoverB,
    ),
    codeRuns: runs,
  );
  return <LineFillRun>[
    for (final _CellCode run in runs)
      LineFillRun(
        from: run.start,
        to: run.end,
        fill: run.fill,
        radius: run.radius,
        padX: run.padX,
        probe: run.probe,
        style: run.style,
      ),
  ];
}
