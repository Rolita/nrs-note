part of '../live_markdown.dart';

/// The leading whitespace of a list row, rendered as [level] fixed-width steps.
///
/// Tab writes two spaces, and two spaces of a proportional font are worth about
/// nine pixels — so nesting used to be invisible: the child marker sat 9px right
/// of the parent's, the text did not move, and there was nothing to say which
/// parent a nested row belonged to. Here each level is worth [_kIndentStep]
/// whatever the font's space happens to measure, and the step carries a rail at
/// the parent's marker centre.
///
/// The typed spaces are all still in the span tree — the length invariant needs
/// every source character to survive — but the first one becomes the full-width
/// widget and the rest collapse to nothing. That keeps `substring` offsets, the
/// caret's offsets and `getPositionForPoint` exactly as they were.
List<InlineSpan> _indentRun(String indent, TextStyle base, AppPalette p) {
  if (indent.isEmpty) return const <InlineSpan>[];
  final int level = _level(indent);
  if (level == 0) {
    // One stray space is not a nest level. Leave it at its natural width so the
    // caret stays where the user typed it.
    return <InlineSpan>[TextSpan(text: indent, style: base)];
  }
  return <InlineSpan>[
    _decoration(
      MarkdownIndentGuides(
        levels: level,
        color: p.rule,
        rowHeight: _lineHeightOf(base),
      ),
    ),
    if (indent.length > 1)
      TextSpan(text: indent.substring(1), style: _collapsed(base)),
  ];
}

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

List<InlineSpan> _highlight(List<CodeToken> tokens, bool isDark) {
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
      if (open || ctx.plain || ctx.onTagTap == null) {
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

bool _isTableKind(_Kind kind) =>
    kind == _Kind.table ||
    kind == _Kind.tableHeader ||
    kind == _Kind.tableDivider;

// ------------------------------------------------------------- inline widgets

/// The dot in front of a bullet item.
///
/// One solid disc at every depth. It used to cycle ● / ○ / ▪ by nesting level,
/// which is the browser default rather than a decision: three shapes meant three
/// things to learn, and the hollow ring at level 2 read as a disabled control.
/// Depth is already said by the indent, and one glyph says it once.
WidgetSpan _bulletDot(AppPalette p) {
  final Color color = p.textTertiary.withValues(alpha: 0.9);
  return _decoration(
    Padding(
      padding: const EdgeInsets.only(left: 2, right: 9),
      child: Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    ),
  );
}

/// The vertical rule on the left of a quote.
///
/// It is exactly one row tall so consecutive quote lines butt up against each
/// other and read as a single continuous bar rather than a dashed one, and it is
/// exactly as wide as the `> ` it hides — see [_markerAdvance].
WidgetSpan _quoteBar(
  AppPalette p,
  TextStyle base,
  String marker,
  TextScaler scaler,
) {
  final double row = _lineHeightOf(base);
  return _decoration(
    SizedBox(
      width: _markerAdvance(marker, base, scaler),
      height: row,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: 2,
          height: row,
          margin: const EdgeInsets.only(left: 2),
          color: p.accent,
        ),
      ),
    ),
  );
}

/// Advance width of a marker, measured the way the paragraph will lay it out.
///
/// A decoration that stands in for `> ` has to occupy exactly as much room as
/// the characters it hides. The bar used to be a fixed 14px while `> ` is as
/// wide as the font makes it, so putting the caret on a quote line nudged the
/// whole paragraph sideways under the pointer — and re-wrapped the line whenever
/// it happened to end near the column's edge. That is the jitter you feel when
/// you click into a quote.
double _markerAdvance(String marker, TextStyle style, TextScaler scaler) {
  final String key =
      '${style.fontFamily}|${style.fontSize}|${style.letterSpacing}|'
      '${scaler.scale(1)}|$marker';
  final double? cached = _kMarkerAdvances[key];
  if (cached != null) return cached;
  final TextPainter tp = TextPainter(
    text: TextSpan(text: marker, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final double width = tp.width;
  tp.dispose();
  // A note has a handful of distinct markers; the bound is only here so a
  // pathological document cannot grow the map without end.
  if (_kMarkerAdvances.length > 128) _kMarkerAdvances.clear();
  _kMarkerAdvances[key] = width;
  return width;
}

final Map<String, double> _kMarkerAdvances = <String, double>{};

/// The sunken slab that keeps a fenced block reading as a single card is
/// painted behind the field (see `CodeBlockPainter`); this is only the fence
/// line's own row — an empty spacer that reserves the card's header, or nothing
/// at all for the closing fence.
WidgetSpan _codeFenceSpacer(double width, double height) => _decoration(
  SizedBox(
    // A few pixels short of the column: the widget plus whatever it swapped out
    // may never be wider than the line, or the paragraph wraps.
    width: math.max(24, width - 8),
    height: height,
  ),
);
