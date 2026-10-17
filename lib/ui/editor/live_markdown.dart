/// Typora / Obsidian-style *live* Markdown styling.
///
/// The whole trick is that this is still one plain `TextEditingController`: the
/// editor text is byte-for-byte the Markdown the user typed, and only the
/// *painting* changes. Markup punctuation that has nothing to reveal is drawn at
/// zero size so it visually disappears while still occupying its exact character
/// positions — which is what keeps the caret, selection and IME in sync.
///
/// ## The invariant: the tree must be exactly as long as the text
///
/// `RenderEditable` computes pointer hit-testing and caret positions from the
/// tree [TextEditingController.buildTextSpan] returns; `TextEditingValue`
/// selections are offsets into the *source*. One character more or less in the
/// tree and every offset after it slides — the caret lands left of the click and
/// clicking a line reveals its neighbour.
///
/// A [WidgetSpan] is not free: it occupies exactly one character position in the
/// paragraph (the object-replacement character `U+FFFC`). So a decoration may
/// only ever stand in for **one** source character — the first character of the
/// syntax it replaces — and the rest of that syntax has to be emitted as
/// collapsed text behind it. [_decoration] + [_swallowed] are the only
/// sanctioned way to draw a widget here; nothing else may change the length.
///
/// Two rules decide what is revealed:
///
/// * **Inline markers** (`**`, `` ` ``, `[[…]]`, `#tag`) come back only when the
///   caret actually touches that token — the line you are typing on otherwise
///   looks finished, which is what makes live editing feel calm.
/// * **Block markers** (`#`, `>`, a fence, a rule) come back when the caret
///   enters the block, so the raw syntax is one keystroke away. Bullets and
///   checkboxes are the exception: they are drawn as markers *even on the caret's
///   line*, because otherwise typing `- ` and a space produces no visible change
///   at all and the editor looks broken.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../preview/code_palette.dart';
import '../preview/syntax_highlighter.dart';

// ---------------------------------------------------------------- block kinds

enum _Kind {
  paragraph,
  heading,
  fence,
  code,
  bullet,
  ordered,
  task,
  quote,
  rule,
  setext,
  table,
  tableHeader,
  tableDivider,
}

final RegExp _fenceRe = RegExp(r'^(\s{0,3})(`{3,}|~{3,})(.*)$');
final RegExp _headingRe = RegExp(r'^(\s{0,3})(#{1,6})(\s+)(.*?)(\s+#+\s*)?$');
final RegExp _bulletRe = RegExp(r'^(\s*)([-*+])(\s+)(.*)$');
final RegExp _taskRe = RegExp(
  r'^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[[ xX]\])(\s+)(.*)$',
);

/// Whether a task's lead-in is a number (`1.`) rather than a bullet (`-`).
///
/// The lead group is either a single bullet character or digits plus `.`/`)`,
/// so anything longer than one character is a number.
bool _isOrderedLead(String lead) => lead.length > 1;
final RegExp _orderedRe = RegExp(r'^(\s*)(\d{1,9})([.)])(\s+)(.*)$');
final RegExp _quoteRe = RegExp(r'^(\s{0,3})(>)(\s?)(.*)$');
final RegExp _ruleRe = RegExp(r'^ {0,3}(?:[-*_]\s*){3,}$');

/// A setext underline turns the line above it into a heading. Only `===` counts
/// here: a run of `-` is *always* a horizontal rule, because that is what
/// everyone who types `---` under a paragraph means, and silently promoting the
/// paragraph to a heading is the single most confusing thing this renderer can
/// do. Use `##` for a level-2 heading.
final RegExp _setextRe = RegExp(r'^ {0,3}(=+)\s*$');
final RegExp _tableDividerRe = RegExp(r'^[\s|:\-]+$');
final RegExp _spaceRe = RegExp(r'\s');

/// The font size used for punctuation that is hidden. Zero, not "very small":
/// a proportional font at 0.1px still has a non-zero advance, and those slivers
/// add up into a visible wobble.
const double _kHiddenFontSize = 0;

/// A fenced code block, remembered so it can be highlighted as a whole.
class _Fence {
  _Fence({required this.open, required this.language});

  final int open;
  int close = -1;
  final String language;
  List<List<CodeToken>>? tokens;
}

/// Everything the inline scanner needs besides the text itself.
class _Ctx {
  _Ctx({
    required this.p,
    required this.caretA,
    required this.caretB,
    required this.contentWidth,
    this.textScaler = TextScaler.noScaling,
    this.plain = false,
    this.onTagTap,
    this.onWikilinkTap,
  });

  final AppPalette p;
  final int caretA;
  final int caretB;
  final double contentWidth;

  /// The scale the paragraph will lay the text out at. A table column is sized
  /// from measured text, so the measurement has to be taken under the same
  /// scale the painted text will get — otherwise every column is off by the
  /// user's font-size setting.
  final TextScaler textScaler;

  /// True while laying out text that will be **repainted** by a render object
  /// (a table cell): chips need a [BuildContext] to build, so inside a cell
  /// every inline token falls back to its plain styled text instead.
  final bool plain;
  final void Function(String tag)? onTagTap;
  final void Function(String target)? onWikilinkTap;

  /// True when the caret (or the selection) overlaps `[a, b]`.
  bool touched(int a, int b) => caretA >= 0 && caretB >= a && caretA <= b;
}

/// Builds the styled span tree for live mode.
///
/// [tables] is filled with the geometry of every table block, so the pointer
/// layer can map a press on a rendered table back to the cell under it. The
/// renderer is the only thing that knows how wide a column came out.
List<InlineSpan> buildLiveSpans({
  required String text,
  required TextStyle base,
  required AppPalette p,
  required TextSelection selection,
  double contentWidth = 680,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
  List<TableGeometry>? tables,
  void Function(String tag)? onTagTap,
  void Function(String target)? onWikilinkTap,
}) {
  final List<String> lines = text.split('\n');
  final int n = lines.length;
  final List<int> starts = List<int>.filled(n + 1, 0);
  for (int i = 0; i < n; i++) {
    starts[i + 1] = starts[i] + lines[i].length + 1;
  }

  final List<_Kind> kinds = List<_Kind>.filled(n, _Kind.paragraph);
  final List<int> levels = List<int>.filled(n, 0);
  final List<int> fences = List<int>.filled(n, -1);
  final List<_Fence> blocks = <_Fence>[];

  // ---------------------------------------------------------------- pass one
  bool inFence = false;
  int current = -1;
  for (int i = 0; i < n; i++) {
    final String line = lines[i];
    final Match? f = _fenceRe.firstMatch(line);
    if (f != null) {
      if (!inFence) {
        current = blocks.length;
        blocks.add(_Fence(open: i, language: _fenceLanguage(f.group(3) ?? '')));
        inFence = true;
      } else {
        blocks[current].close = i;
        inFence = false;
        current = -1;
      }
      kinds[i] = _Kind.fence;
      fences[i] = current < 0 ? blocks.length - 1 : current;
      continue;
    }
    if (inFence) {
      kinds[i] = _Kind.code;
      fences[i] = current;
      continue;
    }
    if (_setextRe.hasMatch(line) &&
        i > 0 &&
        kinds[i - 1] == _Kind.paragraph &&
        lines[i - 1].trim().isNotEmpty) {
      kinds[i - 1] = _Kind.heading;
      levels[i - 1] = 1;
      kinds[i] = _Kind.setext;
      continue;
    }

    final Match? h = _headingRe.firstMatch(line);
    if (h != null) {
      kinds[i] = _Kind.heading;
      levels[i] = h.group(2)!.length;
      continue;
    }
    if (line.trimLeft().startsWith('|')) {
      final bool divider =
          line.contains('-') && _tableDividerRe.hasMatch(line);
      if (divider && i > 0 && kinds[i - 1] == _Kind.table) {
        kinds[i - 1] = _Kind.tableHeader;
      }
      kinds[i] = divider ? _Kind.tableDivider : _Kind.table;
      continue;
    }
    if (_taskRe.hasMatch(line)) {
      kinds[i] = _Kind.task;
      continue;
    }
    if (_orderedRe.hasMatch(line)) {
      kinds[i] = _Kind.ordered;
      continue;
    }
    if (_ruleRe.hasMatch(line) && line.trim().isNotEmpty) {
      kinds[i] = _Kind.rule;
      continue;
    }
    if (_bulletRe.hasMatch(line)) {
      kinds[i] = _Kind.bullet;
      continue;
    }
    if (_quoteRe.hasMatch(line)) {
      kinds[i] = _Kind.quote;
      continue;
    }
  }

  // Only a closed fence has a known body; highlight it once, up front.
  for (final _Fence b in blocks) {
    final int end = b.close < 0 ? n : b.close;
    final List<String> body = lines.sublist(b.open + 1, end.clamp(0, n));
    if (body.isEmpty) continue;
    final List<List<CodeToken>> tokens = highlightCode(
      body.join('\n'),
      b.language,
    );
    // Defensive: a mismatch would mean the highlighter reshaped the source,
    // and a reshaped source would desynchronise the caret.
    b.tokens = tokens.length == body.length ? tokens : null;
  }

  // ---------------------------------------------------------------- the caret
  final Set<int> active = <int>{};
  int caretA = -1;
  int caretB = -1;
  if (selection.isValid && selection.start >= 0) {
    caretA = selection.start.clamp(0, text.length);
    caretB = selection.end.clamp(0, text.length);
    final int la = _lineOf(text, caretA);
    final int lb = _lineOf(text, caretB);
    for (int i = la; i <= lb && i < n; i++) {
      active.add(i);
    }
  }
  final Set<int> revealedFences = <int>{};
  for (final int i in active) {
    if (fences[i] >= 0) revealedFences.add(fences[i]);
  }

  // --------------------------------------------------------------- the tables
  //
  // A table is the one block that is not painted as text. Cells only line up
  // with the row above them if something decides the column widths for the
  // whole table at once, and a line of text cannot ask its neighbours how wide
  // they are. So every table block is measured here, once, and each row is
  // handed a fixed width and the share each column gets of it.
  final _Ctx ctx = _Ctx(
    p: p,
    caretA: caretA,
    caretB: caretB,
    contentWidth: contentWidth,
    textScaler: textScaler,
    onTagTap: onTagTap,
    onWikilinkTap: onWikilinkTap,
  );

  /// The same context, but for text a render object will repaint (table
  /// cells): chips need a build context, so cells fall back to plain text.
  final _Ctx plainCtx = _Ctx(
    p: p,
    caretA: caretA,
    caretB: caretB,
    contentWidth: contentWidth,
    textScaler: textScaler,
    plain: true,
    onTagTap: onTagTap,
    onWikilinkTap: onWikilinkTap,
  );

  final List<int> tableOf = List<int>.filled(n, -1);
  final List<_Table> tableBlocks = <_Table>[];
  for (int i = 0; i < n; i++) {
    if (tableOf[i] >= 0 || !_isTableKind(kinds[i])) continue;
    int last = i;
    while (last + 1 < n && _isTableKind(kinds[last + 1])) {
      last++;
    }
    int divider = -1;
    for (int k = i; k <= last; k++) {
      if (kinds[k] == _Kind.tableDivider) {
        divider = k;
        break;
      }
    }
    final _Table t = _measureTable(
      lines: lines,
      starts: starts,
      first: i,
      last: last,
      divider: divider,
      base: base,
      ctx: ctx,
      direction: direction,
    );
    for (int k = i; k <= last; k++) {
      tableOf[k] = tableBlocks.length;
    }
    tableBlocks.add(t);
  }
  tables?.clear();
  tables?.addAll(<TableGeometry>[
    for (final _Table t in tableBlocks) t.geometry,
  ]);

  /// A table is only knocked back to its source while the **caret** is in it —
  /// `active` already says which line that is. A *range* leaves it rendered
  /// instead: a selection across cells is how you copy a block of the table,
  /// and expanding the table the moment the pointer moved would make that
  /// gesture impossible to finish. (A range that is typed over collapses to a
  /// caret on the first keystroke, which reveals as usual.)

  // ---------------------------------------------------------------- pass two
  final double row = _lineHeightOf(base);
  final List<InlineSpan> out = <InlineSpan>[];
  for (int i = 0; i < n; i++) {
    final String line = lines[i];
    final bool on = active.contains(i);
    final int at = starts[i];

    switch (kinds[i]) {
      case _Kind.fence:
        final int fenceId = fences[i];
        final _Fence? block = _blockAt(blocks, fenceId);
        final int openLine = block == null ? -1 : block.open;
        final String language = block == null ? '' : block.language;
        final bool revealed = on || revealedFences.contains(fenceId);
        final bool opens = openLine == i;
        if (revealed) {
          out.add(
            TextSpan(
              text: line,
              style: _markerVisible(base, p, accented: true),
            ),
          );
          break;
        }
        // The band stands in for the first backtick; the rest of the fence
        // collapses behind it. A sunken band keeps the block reading as one
        // slab, and gives the language somewhere quiet to live.
        out.add(
          _codeBand(
            p,
            ctx.contentWidth,
            label: opens ? _displayLanguage(language) : null,
            height: row,
          ),
        );
        out.add(_swallowed(line, base));

      case _Kind.code:
        final _Fence? block = _blockAt(blocks, fences[i]);
        final int index = block == null ? -1 : i - block.open - 1;
        final List<List<CodeToken>>? all = block?.tokens;
        final List<CodeToken>? tokens =
            (all != null && index >= 0 && index < all.length)
            ? all[index]
            : null;
        final TextStyle style = _codeLine(base, p);
        out.add(
          TextSpan(
            style: style,
            children: tokens == null
                ? <InlineSpan>[TextSpan(text: line)]
                : _highlight(tokens, p.isDark),
          ),
        );

      case _Kind.setext:
        // The `===` underline has done its job once the heading is styled. It
        // is painted transparent rather than hidden size so the row keeps its
        // height and a caret landing on it stays visible.
        out.add(
          TextSpan(
            text: line,
            style: on ? _markerVisible(base, p) : _invisible(base),
          ),
        );

      case _Kind.heading:
        final Match? m = _headingRe.firstMatch(line);
        final TextStyle h = _headingStyle(base, p, levels[i]);
        if (m == null) {
          // A setext heading: the line itself is the heading.
          out.addAll(_inline(line, h, at, ctx));
          break;
        }
        out.add(TextSpan(text: m.group(1), style: base));
        // On the caret's line the markers scale with the heading, exactly like
        // Typora — a 12px `#` next to a 26px heading looks broken.
        out.add(
          TextSpan(
            text: m.group(2),
            style: on
                ? _markerVisible(h, p, accented: true)
                : _collapsed(base),
          ),
        );
        out.add(
          TextSpan(
            text: m.group(3),
            style: on ? _markerVisible(h, p) : _collapsed(base),
          ),
        );
        out.addAll(
          _inline(
            m.group(4) ?? '',
            h,
            at + m.group(1)!.length + m.group(2)!.length + m.group(3)!.length,
            ctx,
          ),
        );
        final String? tail = m.group(5);
        if (tail != null) {
          out.add(
            TextSpan(
              text: tail,
              style: on ? _markerVisible(h, p) : _collapsed(base),
            ),
          );
        }

      case _Kind.bullet:
        final Match? m = _bulletRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        // ⭐ The bullet is drawn as a bullet *even on the caret's line*: the
        // moment the user taps space after `-` the line has to look like a list,
        // otherwise the keystroke appears to have done nothing.
        final String marker = '${m.group(2)}${m.group(3)}';
        out.add(TextSpan(text: m.group(1), style: base));
        out.add(_bulletDot(p, _level(m.group(1)!)));
        out.add(_swallowed(marker, base));
        out.addAll(
          _inline(
            m.group(4)!,
            base,
            at + m.group(1)!.length + marker.length,
            ctx,
          ),
        );

      case _Kind.ordered:
        final Match? m = _orderedRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        out.add(TextSpan(text: m.group(1), style: base));
        out.add(
          TextSpan(
            text: '${m.group(2)}${m.group(3)}',
            style: _numberStyle(base, p),
          ),
        );
        out.add(TextSpan(text: m.group(4), style: base));
        out.addAll(
          _inline(
            m.group(5)!,
            base,
            at +
                m.group(1)!.length +
                m.group(2)!.length +
                m.group(3)!.length +
                m.group(4)!.length,
            ctx,
          ),
        );

      case _Kind.task:
        final Match? m = _taskRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        final bool done = m.group(4)!.toLowerCase().contains('x');
        final String lead = m.group(2)!;
        final int gap = m.group(3)!.length;
        out.add(TextSpan(text: m.group(1), style: base));
        final String marker =
            '$lead${m.group(3)}${m.group(4)}${m.group(5)}';
        final TextStyle body = done
            // A ticked item steps *one* rung down the text ramp and stays
            // legible; the deletion is carried by the rule, not by fading the
            // words into the page. Dropping it two rungs (to `textTertiary`)
            // made the whole line — rule included — a grey smudge, which is
            // what "删除线不够明显" was about. This is the level the reference
            // (Obsidian's done list) keeps its struck lines at.
            ? _struck(base.copyWith(color: p.textSecondary))
            : base;
        final int contentAt = at + m.group(1)!.length + marker.length;
        // The box stays a box on the caret's line too; the raw `- [ ] ` is one
        // keystroke away in any other editor, and a box that turns into text
        // when you click it is just confusing.
        //
        // A numbered list can carry a box as well (`1. [ ] 事`, which is what
        // the toolbar's "ordered task list" writes). The number is *not* hidden
        // there — it is part of the marker column, so the box lines up with the
        // checkbox of a plain `- [ ]` item rather than replacing the number.
        if (_isOrderedLead(lead)) {
          // The number belongs to the sentence, so a ticked item strikes it
          // too, and it recedes with the rest of the line instead of staying
          // lit up in accent next to greyed-out words. `_numberStyle` is kept
          // underneath for its tabular figures: only the colour and the rule
          // change, so the digit column does not reflow the moment the box is
          // ticked.
          out.add(
            TextSpan(
              text: lead,
              style: done
                  ? _struck(
                      _numberStyle(base, p).copyWith(color: p.textSecondary),
                    )
                  : _numberStyle(base, p),
            ),
          );
          // The gap keeps the space's width but paints nothing: dropping it to a
          // zero-size span would butt the box up against the number.
          out.add(TextSpan(text: m.group(3)!, style: _invisible(base)));
          out.add(_taskBox(p, done, at + m.group(1)!.length + lead.length + gap));
          // Skip the `[` — the box stands in for it.
          out.add(
            TextSpan(
              text: marker.substring(lead.length + gap + 1),
              style: _collapsed(base),
            ),
          );
        } else {
          out.add(_taskBox(p, done, at + m.group(1)!.length));
          out.add(_swallowed(marker, base));
        }
        out.addAll(
          _inline(m.group(6)!, base, contentAt, ctx, forceStyle: body),
        );

      case _Kind.quote:
        final Match? m = _quoteRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        final TextStyle quoted = base.copyWith(color: p.textSecondary);
        out.add(TextSpan(text: m.group(1), style: quoted));
        final String marker = '${m.group(2)}${m.group(3)}';
        if (on) {
          out.add(
            TextSpan(
              text: marker,
              style: _markerVisible(base, p, accented: true),
            ),
          );
        } else {
          out.add(_quoteBar(p, base));
          out.add(_swallowed(marker, base));
        }
        out.addAll(
          _inline(
            m.group(4)!,
            quoted,
            at + m.group(1)!.length + marker.length,
            ctx,
          ),
        );

      case _Kind.rule:
        if (on) {
          out.add(TextSpan(text: line, style: _markerVisible(base, p)));
          break;
        }
        // A real horizontal rule: the first dash becomes the line itself and
        // the remaining ones collapse behind it, so the row keeps its height
        // and the line spans the column whatever the window width.
        out.add(_decoration(MarkdownDividerLine(color: p.outline, height: row)));
        out.add(_swallowed(line, base));

      case _Kind.tableHeader:
      case _Kind.table:
        final _Table? table = tableOf[i] < 0
            ? null
            : (tableOf[i] < tableBlocks.length ? tableBlocks[tableOf[i]] : null);
        final List<_CellData>? cells = (table != null &&
                table.lineOfRow.containsKey(i))
            ? table.cellsOf(i)
            : null;
        if (cells == null || cells.isEmpty) {
          // The block is malformed: raw source, pipes and all.
          out.addAll(_tableRowSource(line, base, at, ctx));
          break;
        }
        // `on` is true for every line a *range* touches; a rendered table must
        // only fold back to source for a collapsed caret on the row itself,
        // otherwise the drag that selects cells would tear the table apart.
        final bool revealed = on && selection.isValid && selection.isCollapsed;
        if (revealed) {
          out.addAll(_tableRowSource(line, base, at, ctx));
          break;
        }
        final bool isLastRow = table!.rows.last.line == i;
        out.add(
          _decoration(
            _TableRowView(
              cells: <_PaintCell>[
                for (final _CellData d in cells)
                  _PaintCell(
                    spans: _inline(
                      d.cell.text,
                      d.style,
                      d.cell.offset,
                      plainCtx,
                    ),
                    cell: TableCellGeometry(
                      start: d.cell.offset,
                      end: d.cell.offset + d.cell.text.length,
                      x: d.x,
                      width: d.boxWidth,
                    ),
                    style: d.style,
                    letterSpacing: d.letterSpacing,
                  ),
              ],
              palette: p,
              rowHeight: table.rowHeight,
              tableWidth: table.width,
              header: kinds[i] == _Kind.tableHeader,
              last: isLastRow,
              caretA: ctx.caretA,
              caretB: ctx.caretB,
              textScaler: ctx.textScaler,
              direction: direction,
            ),
          ),
        );
        // The skeleton: the same characters, invisible, each cell's run
        // occupying (or squeezed into) its column's text area. It carries no
        // paint — its whole job is to give the paragraph real advances, so a
        // click or a drag inside the painted table lands on the character
        // under the pointer without any custom hit testing.
        out.addAll(_tableRowSkeleton(line, base, at, cells));
        break;

      case _Kind.tableDivider:
        out.add(
          TextSpan(
            text: line,
            style: on
                ? base.copyWith(color: p.textTertiary.withValues(alpha: 0.5))
                : _invisible(base),
          ),
        );

      case _Kind.paragraph:
        out.addAll(_inline(line, base, at, ctx));
    }

    if (i != n - 1) {
      out.add(TextSpan(text: '\n', style: base));
    }
  }

  _unhideLastGlyph(out, base);
  return out;
}

// ------------------------------------------------------- the length invariant

/// One character position is all a [WidgetSpan] gets, so every decoration in
/// this file is a widget standing in for the *first* character of the syntax it
/// replaces, followed by [_swallowed].
WidgetSpan _decoration(Widget child) =>
    WidgetSpan(alignment: PlaceholderAlignment.middle, child: child);

/// The characters a decoration did not consume, collapsed to nothing so the
/// caret still has real offsets to move through.
TextSpan _swallowed(String marker, TextStyle base) => TextSpan(
  text: marker.length <= 1 ? '' : marker.substring(1),
  style: _collapsed(base),
);

/// Turns a designed line-height multiplier into one the paragraph can honour.
///
/// A paragraph rounds every line's *advance* to a whole logical pixel, but it
/// computes that line's highlight box from `fontSize * height` unchanged.
/// `15.5 * 1.78` is 27.59, so the box is 0.41px shorter than the step to the
/// next line, and a multi-line selection is painted as a stack of bands with a
/// hairline of paper between them: measured on the real widget, the seam pixel
/// comes out 41% lighter than the highlight, which is exactly the "1px gap
/// between the lines" this exists to remove. Handing back a multiplier whose
/// product is *already* whole makes the box and the advance agree to the last
/// bit (the box height is `fontSize * height` — verified across 1.7 … 1.9).
///
/// The multiplier moves by at most half a pixel of line spacing, which is not
/// visible as spacing but does put the line grid on whole pixels.
double snapLineHeight(double fontSize, double designed) {
  final double line = fontSize * designed;
  if (line <= 0) return designed;
  return line.roundToDouble() / fontSize;
}

/// Height of one editor row. Full-row decorations (a rule, a code band) need it
/// so they neither shrink nor stretch the line they live on — which means the
/// *rounded* advance, the number the paragraph actually steps by.
double _lineHeightOf(TextStyle base) =>
    ((base.fontSize ?? 15) * (base.height ?? 1.78)).roundToDouble();

bool _isHiddenStyle(TextStyle? style) =>
    style != null && style.fontSize == _kHiddenFontSize;

/// The last character of the document must never be hidden.
///
/// `RenderEditable` anchors the end-of-text caret on the **last glyph's** box
/// (`TextPainter._computeEndOfTextCaretAnchorOffset`), and asserts that box is
/// non-empty. A hidden space has a zero-width box — so typing `- `, `# `, `> `
/// or `- [ ] ` as the very last thing in a note made the caret collapse to
/// nothing (and threw the assert in debug). Handing that one character the body
/// style costs nothing visible — it is a space — and it is last, so its width
/// cannot move anything else.
void _unhideLastGlyph(List<InlineSpan> spans, TextStyle base) {
  if (spans.isEmpty) return;
  final InlineSpan last = spans.last;
  if (last is! TextSpan || last.children != null) return;
  final String? text = last.text;
  if (text == null || text.isEmpty) return;
  if (!_isHiddenStyle(last.style)) return;
  if (!_spaceRe.hasMatch(text[text.length - 1])) return;
  spans[spans.length - 1] = TextSpan(
    text: text.substring(0, text.length - 1),
    style: last.style,
  );
  spans.add(TextSpan(text: text[text.length - 1], style: base));
}

_Fence? _blockAt(List<_Fence> blocks, int index) =>
    index >= 0 && index < blocks.length ? blocks[index] : null;

int _lineOf(String text, int offset) {
  int count = 0;
  for (int i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) count++;
  }
  return count;
}

/// Nesting depth from a run of leading whitespace (two spaces ≈ one level).
int _level(String indent) {
  int width = 0;
  for (final int unit in indent.codeUnits) {
    width += unit == 0x09 ? 2 : 1;
  }
  return (width ~/ 2).clamp(0, 5);
}

String _fenceLanguage(String info) {
  String raw = info.trim();
  if (raw.startsWith('{')) raw = raw.replaceAll(RegExp(r'[{}]'), '').trim();
  final Match? m = RegExp(r'^[^\s]+').firstMatch(raw);
  return normaliseLanguage(m?.group(0));
}

String _displayLanguage(String? lang) =>
    (lang == null || lang.isEmpty) ? 'text' : lang;

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
      spans.add(TextSpan(text: '`', style: mark));
      spans.add(
        TextSpan(
          text: token.substring(1, token.length - 1),
          style: _inlineCode(body, p),
        ),
      );
      spans.add(TextSpan(text: '`', style: mark));
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
      if (open || ctx.plain || ctx.onWikilinkTap == null || inner.trim().isEmpty) {
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
        spans.add(
          TextSpan(text: label, style: _linkText(style, p)),
        );
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
      spans.add(
        TextSpan(text: token.substring(token.length - 1), style: mark),
      );
    }
    cursor = m.end;
  }

  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: style));
  }
  return spans;
}

bool _isTableKind(_Kind kind) =>
    kind == _Kind.table ||
    kind == _Kind.tableHeader ||
    kind == _Kind.tableDivider;

/// A revealed table row: raw source, pipes dimmed, cells still inline-styled.
List<InlineSpan> _tableRowSource(
  String line,
  TextStyle base,
  int absStart,
  _Ctx ctx,
) {
  final List<InlineSpan> spans = <InlineSpan>[];
  int start = 0;
  for (int i = 0; i < line.length; i++) {
    if (line[i] != '|') continue;
    if (i > start) {
      spans.addAll(
        _inline(line.substring(start, i), base, absStart + start, ctx),
      );
    }
    spans.add(TextSpan(text: '|', style: _collapsed(base)));
    start = i + 1;
  }
  if (start < line.length) {
    spans.addAll(_inline(line.substring(start), base, absStart + start, ctx));
  }
  return spans;
}

/// The invisible skeleton of a rendered row: every character of the line is
/// present (the length invariant), but the only ones with advance width are
/// the cells' text runs, which are given their column's text area — squeezed
/// with a negative letter spacing when the table had to shrink. The pipes and
/// the leading indent collapse to nothing.
List<InlineSpan> _tableRowSkeleton(
  String line,
  TextStyle base,
  int absStart,
  List<_CellData> cells,
) {
  final List<InlineSpan> spans = <InlineSpan>[];
  int cursor = 1; // the row's first character carries the row widget
  for (final _CellData d in cells) {
    final int from = d.cell.offset - absStart;
    if (from > cursor) {
      spans.add(
        TextSpan(text: line.substring(cursor, from), style: _collapsed(base)),
      );
    }
    spans.add(
      TextSpan(
        text: d.cell.text,
        style: d.style.copyWith(
          color: Colors.transparent,
          letterSpacing: d.letterSpacing,
        ),
      ),
    );
    cursor = from + d.cell.text.length;
  }
  if (cursor < line.length) {
    spans.add(TextSpan(text: line.substring(cursor), style: _collapsed(base)));
  }
  return spans;
}

/// One cell handed to the row renderer: its inline spans, where its box sits
/// in the table, and the style its text was measured with.
class _PaintCell {
  _PaintCell({
    required this.spans,
    required this.cell,
    required this.style,
    required this.letterSpacing,
  });

  final List<InlineSpan> spans;
  final TableCellGeometry cell;
  final TextStyle style;
  final double letterSpacing;
}

/// One rendered table row.
///
/// ## Why a render object, and why it measures itself zero wide
///
/// The row's source characters are laid out *invisibly* right behind it (see
/// [_tableRowSkeleton]), so the paragraph's own `getPositionForPoint` already
/// maps a click to the right character — the row itself must therefore take no
/// space and, crucially, **refuse every hit**: a `WidgetSpan` child that says
/// "hit me" would swallow the tap before the paragraph ever saw it, and the
/// caret would stop moving. Sizing to `0 × rowHeight` achieves both at once,
/// the same trick [MarkdownDividerLine] uses to paint a full-width rule.
class _TableRowView extends LeafRenderObjectWidget {
  const _TableRowView({
    required this.cells,
    required this.palette,
    required this.rowHeight,
    required this.tableWidth,
    required this.header,
    required this.last,
    required this.caretA,
    required this.caretB,
    required this.textScaler,
    required this.direction,
  });

  final List<_PaintCell> cells;
  final AppPalette palette;
  final double rowHeight;
  final double tableWidth;

  /// The row above the divider (bold, and it draws the rule under itself).
  final bool header;

  /// The last row of the block: it closes the grid at the bottom.
  final bool last;
  final int caretA;
  final int caretB;
  final TextScaler textScaler;
  final TextDirection direction;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTableRow(
    cells,
    palette,
    rowHeight,
    tableWidth,
    header,
    last,
    caretA,
    caretB,
    textScaler,
    direction,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTableRow renderObject,
  ) {
    renderObject
      ..cells = cells
      ..palette = palette
      ..rowHeight = rowHeight
      ..tableWidth = tableWidth
      ..header = header
      ..last = last
      ..caretA = caretA
      ..caretB = caretB
      ..textScaler = textScaler
      ..direction = direction;
  }
}

class _RenderTableRow extends RenderBox {
  _RenderTableRow(
    this._cells,
    this._palette,
    this._rowHeight,
    this._tableWidth,
    this._header,
    this._last,
    this._caretA,
    this._caretB,
    this._textScaler,
    this._direction,
  );

  List<_PaintCell> _cells;
  set cells(List<_PaintCell> value) {
    if (identical(value, _cells)) return;
    _cells = value;
    markNeedsLayout();
  }

  AppPalette _palette;
  set palette(AppPalette value) {
    if (value == _palette) return;
    _palette = value;
    markNeedsPaint();
  }

  double _rowHeight;
  set rowHeight(double value) {
    if (value == _rowHeight) return;
    _rowHeight = value;
    markNeedsLayout();
  }

  double _tableWidth;
  set tableWidth(double value) {
    if (value == _tableWidth) return;
    _tableWidth = value;
    markNeedsPaint();
  }

  bool _header;
  set header(bool value) {
    if (value == _header) return;
    _header = value;
    markNeedsPaint();
  }

  bool _last;
  set last(bool value) {
    if (value == _last) return;
    _last = value;
    markNeedsPaint();
  }

  int _caretA;
  set caretA(int value) {
    if (value == _caretA) return;
    _caretA = value;
    markNeedsPaint();
  }

  int _caretB;
  set caretB(int value) {
    if (value == _caretB) return;
    _caretB = value;
    markNeedsPaint();
  }

  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    markNeedsLayout();
  }

  TextDirection _direction;
  set direction(TextDirection value) {
    if (value == _direction) return;
    _direction = value;
    markNeedsLayout();
  }

  final List<TextPainter> _painters = <TextPainter>[];
  double _contentHeight = 0;

  void _disposePainters() {
    for (final TextPainter tp in _painters) {
      tp.dispose();
    }
    _painters.clear();
  }

  @override
  void performLayout() {
    _disposePainters();
    _contentHeight = _rowHeight;
    for (final _PaintCell cell in _cells) {
      final TextPainter tp = TextPainter(
        text: TextSpan(style: cell.style, children: cell.spans),
        textDirection: _direction,
        textScaler: _textScaler,
      );
      tp.layout(maxWidth: math.max(1, cell.cell.width - 2 * _kCellPad));
      _painters.add(tp);
      _contentHeight = math.max(_contentHeight, tp.height);
    }
    size = constraints.constrain(Size(0, _contentHeight));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(0, _rowHeight));

  /// ⛔ Never take part in hit testing. The invisible skeleton underneath owns
  /// the pointer; if this box absorbed a tap the caret would stop moving.
  @override
  bool hitTestSelf(Offset position) => false;

  /// The cells the current selection touches, as full-cell boxes. A *collapsed*
  /// caret never selects anything — and indeed a collapsed caret knocks the
  /// whole row back to source before this is ever painted.
  Iterable<TableCellGeometry> get _selectedCells sync* {
    if (_caretA < 0 || _caretB <= _caretA) return;
    for (final _PaintCell cell in _cells) {
      if (_caretA < cell.cell.end && _caretB > cell.cell.start) {
        yield cell.cell;
      }
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    final double height = _contentHeight;

    // The selection: one opaque box per touched cell, then an accent rule
    // around the whole covered region. Opaque, not the translucent selection
    // colour, because the paragraph paints its own text-highlight for the
    // skeleton runs underneath — blending the two would double the purple
    // wherever they overlap and leave the cell looking uneven.
    final List<TableCellGeometry> selected = _selectedCells.toList();
    if (selected.isNotEmpty) {
      final Paint fill = Paint()
        ..color = Color.alphaBlend(_palette.selection, _palette.surface);
      Rect region = Rect.zero;
      for (final TableCellGeometry c in selected) {
        final Rect box = Rect.fromLTWH(
          offset.dx + c.x,
          offset.dy,
          c.width,
          height,
        );
        canvas.drawRect(box, fill);
        region = region == Rect.zero ? box : region.expandToInclude(box);
      }
      canvas.drawRect(
        region.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = _palette.accent,
      );
    }

    // The grid: a rule along the top of every row (plus the bottom of the
    // header and of the last row), and a rule at every column boundary.
    final Paint line = Paint()..color = _palette.outlineSoft;
    final Paint strong = Paint()..color = _palette.outline;
    canvas.drawRect(Rect.fromLTWH(offset.dx, offset.dy, _tableWidth, 1), line);
    if (_header || _last) {
      canvas.drawRect(
        Rect.fromLTWH(offset.dx, offset.dy + height - 1, _tableWidth, 1),
        strong,
      );
    }
    final Set<double> edges = <double>{0};
    for (final _PaintCell cell in _cells) {
      edges
        ..add(cell.cell.x)
        ..add(cell.cell.x + cell.cell.width);
    }
    for (final double x in edges) {
      canvas.drawRect(Rect.fromLTWH(offset.dx + x, offset.dy, 1, height), line);
    }

    // The text, last, so the glyphs sit on top of fill and grid alike.
    for (int i = 0; i < _cells.length && i < _painters.length; i++) {
      final _PaintCell cell = _cells[i];
      final TextPainter tp = _painters[i];
      tp.paint(
        canvas,
        offset + Offset(cell.cell.x + _kCellPad, (height - tp.height) / 2),
      );
    }
  }
}

// ------------------------------------------------------------------ the table

/// Geometry of one rendered cell, in the table's own coordinates (`x` is the
/// distance from the table's left edge) plus the source characters it holds.
class TableCellGeometry {
  const TableCellGeometry({
    required this.start,
    required this.end,
    required this.x,
    required this.width,
  });

  /// First source character of the cell's text.
  final int start;

  /// One past the last source character of the cell's text.
  final int end;

  /// Left edge of the cell's box (padding included).
  final double x;

  /// Full width of the cell's box, padding included.
  final double width;
}

/// Geometry of one rendered row: which source line it paints and where its
/// cells ended up.
class TableRowGeometry {
  const TableRowGeometry({
    required this.line,
    required this.start,
    required this.header,
    required this.cells,
  });

  final int line;

  /// Absolute offset of the row's first source character.
  final int start;

  /// True for the row above the `| --- |` divider: it paints bold.
  final bool header;
  final List<TableCellGeometry> cells;
}

/// Everything the pointer layer and the tests need about one rendered table.
class TableGeometry {
  const TableGeometry({
    required this.first,
    required this.last,
    required this.width,
    required this.rowHeight,
    required this.rows,
  });

  /// First / last source line of the table block (the divider included).
  final int first;
  final int last;
  final double width;
  final double rowHeight;
  final List<TableRowGeometry> rows;
}

/// A row's raw source cells, before widths are handed out.
class _ParsedCell {
  _ParsedCell(this.text, this.offset);

  final String text;

  /// Absolute offset of [text]'s first character.
  final int offset;
}

class _RowData {
  _RowData({
    required this.line,
    required this.start,
    required this.header,
    required this.cells,
  });

  final int line;
  final int start;
  final bool header;
  final List<_ParsedCell> cells;

  /// Same cells with measured geometry, filled by [_measureTable].
  final List<_CellData> data = <_CellData>[];
}

/// A cell with its measured and allocated geometry.
class _CellData {
  _CellData({
    required this.cell,
    required this.style,
    required this.natural,
    required this.width,
  });

  final _ParsedCell cell;
  final TextStyle style;

  /// Width the text wants, one line, no wrapping.
  final double natural;

  /// Width the column's *text area* got after the whole table was fitted.
  final double width;

  /// Letter spacing that squeezes the skeleton run into [width]. Zero unless
  /// the column had to shrink.
  double letterSpacing = 0;

  /// The cell box's left edge and full width (padding included), in the
  /// table's own coordinates. Filled by [_measureTable].
  double x = 0;
  double boxWidth = 0;
}

class _Table {
  _Table({
    required this.rows,
    required this.width,
    required this.rowHeight,
    required this.lineOfRow,
    required this.geometry,
  });

  final List<_RowData> rows;
  final double width;
  final double rowHeight;

  /// Source line → index into [rows] (the divider line maps to nothing).
  final Map<int, int> lineOfRow;
  final TableGeometry geometry;

  List<_CellData> cellsOf(int line) => rows[lineOfRow[line]!].data;
}

const double _kCellPad = 8;

/// Splits `| a | b |` into its cells, keeping each cell's absolute offset.
List<_ParsedCell> _parseCells(String line, int absStart) {
  final List<_ParsedCell> cells = <_ParsedCell>[];
  int pipe = line.indexOf('|');
  if (pipe < 0) return cells;
  while (true) {
    final int next = line.indexOf('|', pipe + 1);
    final int from = pipe + 1;
    if (next < 0) {
      if (from < line.length) {
        cells.add(_ParsedCell(line.substring(from), absStart + from));
      }
      break;
    }
    cells.add(_ParsedCell(line.substring(from, next), absStart + from));
    pipe = next;
  }
  return cells;
}

double _measureCell(
  String text,
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
) {
  if (text.trim().isEmpty) return 0;
  final TextPainter tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
  );
  tp.layout(maxWidth: double.infinity);
  final double w = tp.width;
  tp.dispose();
  return w;
}

/// Measures a whole table block: parses the rows, gives every column the
/// widest cell's width plus padding, then squeezes the whole thing into the
/// content width if even that is not enough (the squeeze is shared by the
/// columns proportionally, and each cell's skeleton run gets a negative
/// letter spacing to match).
_Table _measureTable({
  required List<String> lines,
  required List<int> starts,
  required int first,
  required int last,
  required int divider,
  required TextStyle base,
  required _Ctx ctx,
  required TextDirection direction,
}) {
  final List<_RowData> rows = <_RowData>[];
  final Map<int, int> lineOfRow = <int, int>{};
  for (int i = first; i <= last; i++) {
    if (i == divider) continue;
    final int at = starts[i];
    final List<_ParsedCell> cells = _parseCells(lines[i], at);
    if (cells.isEmpty) continue;
    lineOfRow[i] = rows.length;
    rows.add(
      _RowData(
        line: i,
        start: at,
        header: divider >= 0 && i == divider - 1,
        cells: cells,
      ),
    );
  }

  final int cols = rows.fold<int>(
    0,
    (int m, _RowData r) => math.max(m, r.cells.length),
  );
  final double rowHeight = _lineHeightOf(base);
  final TextStyle bodyStyle = base.copyWith(fontWeight: FontWeight.w400);
  final TextStyle headStyle = base.copyWith(fontWeight: FontWeight.w700);

  // Natural width per column: the widest cell, measured one-line.
  final List<double> natural = List<double>.filled(cols, 0);
  for (final _RowData r in rows) {
    final TextStyle style = r.header ? headStyle : bodyStyle;
    for (int c = 0; c < r.cells.length; c++) {
      natural[c] = math.max(
        natural[c],
        _measureCell(r.cells[c].text, style, ctx.textScaler, direction),
      );
    }
  }

  final double available = math.max(60, ctx.contentWidth - 1);
  final double padding = cols * 2 * _kCellPad;
  final double wanted = natural.fold<double>(0, (double a, double w) => a + w);
  // Text area per column; the rest of the space is the padding ring.
  double fit = wanted;
  if (wanted + padding > available) {
    fit = math.max(1, available - padding);
  }
  final List<double> widths = <double>[
    for (int c = 0; c < cols; c++)
      wanted <= 0 ? fit / math.max(1, cols) : natural[c] * (fit / wanted),
  ];

  final List<_CellData> squeezed = <_CellData>[];
  for (final _RowData r in rows) {
    final TextStyle style = r.header ? headStyle : bodyStyle;
    for (int c = 0; c < r.cells.length; c++) {
      final _ParsedCell parsed = r.cells[c];
      final _CellData data = _CellData(
        cell: parsed,
        style: style,
        natural: _measureCell(parsed.text, style, ctx.textScaler, direction),
        width: widths[c],
      );
      final int len = parsed.text.length;
      if (len > 0 && data.natural > data.width) {
        // The column was squeezed: match the skeleton run to it so a click
        // still lands on the character under the pointer.
        data.letterSpacing = (data.width - data.natural) / len;
      }
      squeezed.add(data);
    }
  }
  int k = 0;
  for (final _RowData r in rows) {
    r.data.addAll(squeezed.sublist(k, k + r.cells.length));
    k += r.cells.length;
  }
  assert(k == squeezed.length);

  final List<List<TableCellGeometry>> perRow = <List<TableCellGeometry>>[
    for (final _RowData _ in rows) <TableCellGeometry>[],
  ];
  double cx = 0;
  for (int c = 0; c < cols; c++) {
    final double boxWidth = widths[c] + 2 * _kCellPad;
    for (int ri = 0; ri < rows.length; ri++) {
      final _RowData r = rows[ri];
      if (c >= r.cells.length) continue;
      final _CellData d = r.data[c];
      d
        ..x = cx
        ..boxWidth = boxWidth;
      perRow[ri].add(
        TableCellGeometry(
          start: r.cells[c].offset,
          end: r.cells[c].offset + r.cells[c].text.length,
          x: cx,
          width: boxWidth,
        ),
      );
    }
    cx += boxWidth;
  }
  final List<TableRowGeometry> geometryRows = <TableRowGeometry>[
    for (int ri = 0; ri < rows.length; ri++)
      TableRowGeometry(
        line: rows[ri].line,
        start: rows[ri].start,
        header: rows[ri].header,
        cells: perRow[ri],
      ),
  ];

  return _Table(
    rows: rows,
    width: cx,
    rowHeight: rowHeight,
    lineOfRow: lineOfRow,
    geometry: TableGeometry(
      first: first,
      last: last,
      width: cx,
      rowHeight: rowHeight,
      rows: geometryRows,
    ),
  );
}

// ------------------------------------------------------------------ styles

TextStyle _headingStyle(TextStyle base, AppPalette p, int level) {
  final double s = base.fontSize ?? 15;
  final (double scale, double height, double tracking) = switch (level) {
    1 => (1.66, 1.32, -0.6),
    2 => (1.38, 1.34, -0.45),
    3 => (1.19, 1.4, -0.3),
    4 => (1.07, 1.45, -0.15),
    5 => (0.98, 1.5, 0),
    _ => (0.92, 1.5, 0.1),
  };
  return base.copyWith(
    fontSize: s * scale,
    height: snapLineHeight(s * scale, height),
    letterSpacing: tracking,
    fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
    color: level == 6 ? p.textTertiary : p.textPrimary,
  );
}

TextStyle _codeLine(TextStyle base, AppPalette p) {
  final double s = (base.fontSize ?? 15) * 0.94;
  return base.copyWith(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: s,
    // Same row height as body text, so every row of a fenced block lines up
    // and the sunken background reads as one slab instead of a staircase.
    height: snapLineHeight(s, base.height ?? 1.78),
    color: p.textSecondary,
    backgroundColor: p.surfaceSunken,
    letterSpacing: 0,
  );
}

TextStyle _inlineCode(TextStyle base, AppPalette p) {
  final double s = (base.fontSize ?? 15) * 0.92;
  return base.copyWith(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: s,
    // A line that is *only* inline code still owes the paragraph a whole-pixel
    // advance, or it shows the same seam as body text.
    height: snapLineHeight(s, base.height ?? 1.78),
    color: p.isDark ? p.accent : p.accentHover,
    backgroundColor: p.surfaceSunken,
  );
}

TextStyle _numberStyle(TextStyle base, AppPalette p) => base.copyWith(
  color: p.accent,
  fontWeight: FontWeight.w600,
  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
);

/// A run that has been crossed out — a ticked task, an inline `~~deletion~~`.
///
/// Two things have to be true for the rule to read as a deletion rather than as
/// a scratch on the line:
///
/// * **Thickness.** `decorationThickness: 2` is a multiplier of the font's own
///   underline weight, which is a fraction of a pixel at this body size. At 1
///   the rule is a hairline that disappears between the glyph stems; at 2 it is
///   the ~2px stroke the eye reads as a struck-through word.
/// * **Colour.** The rule is painted in the colour of the text it crosses
///   (CSS `currentColor`), so a struck word looks *crossed out* instead of
///   having a separately-coloured line laid over it. A rule dimmer than its own
///   text — which is what pinning it to `textTertiary` did — reads as a smudge
///   and was the whole of "删除线不够明显".
TextStyle _struck(TextStyle base) => base.copyWith(
  decoration: TextDecoration.lineThrough,
  decorationThickness: 2,
  decorationColor: base.color,
);

TextStyle _tagText(TextStyle base, AppPalette p) =>
    base.copyWith(color: p.isDark ? p.accent : p.accentHover);

TextStyle _wikiText(TextStyle base, AppPalette p) => base.copyWith(
  color: p.isDark ? p.accent : p.accentHover,
  decoration: TextDecoration.underline,
  decorationStyle: TextDecorationStyle.dotted,
  decorationColor: p.accent.withValues(alpha: 0.45),
);

TextStyle _linkText(TextStyle base, AppPalette p) => base.copyWith(
  color: p.isDark ? p.accent : p.accentHover,
  decoration: TextDecoration.underline,
  decorationColor: p.accent.withValues(alpha: 0.35),
);

/// Punctuation the caret is sitting in — visible but receded.
TextStyle _markerVisible(
  TextStyle base,
  AppPalette p, {
  bool accented = false,
}) => base.copyWith(
  color: accented
      ? p.accent.withValues(alpha: 0.75)
      : p.textTertiary.withValues(alpha: 0.8),
);

/// Punctuation with nothing to reveal: zero size, zero advance.
///
/// `letterSpacing` and `wordSpacing` must be zeroed explicitly — they are *per
/// character* additions that have nothing to do with the font size, so leaving
/// the base tracking on a hidden run leaves a visible gap behind every hidden
/// `*`.
TextStyle _collapsed(TextStyle base) => base.copyWith(
  fontSize: _kHiddenFontSize,
  height: 1,
  letterSpacing: 0,
  wordSpacing: 0,
  color: Colors.transparent,
);

/// A row that is *only* syntax (a setext underline, a table divider) is painted
/// transparent instead of zero-size, so the row keeps its normal height and a
/// caret landing on it stays visible and clickable.
TextStyle _invisible(TextStyle base) => base.copyWith(color: Colors.transparent);

// ------------------------------------------------------------- inline widgets

WidgetSpan _bulletDot(AppPalette p, int level) {
  final Color color = p.textTertiary.withValues(alpha: 0.9);
  final int shape = level % 3;
  final Widget dot = switch (shape) {
    0 => Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
    1 => Container(
      width: 5.5,
      height: 5.5,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.3),
      ),
    ),
    _ => Container(
      width: 4.5,
      height: 4.5,
      decoration: BoxDecoration(
        color: color,
        borderRadius: const BorderRadius.all(Radius.circular(1)),
      ),
    ),
  };
  return _decoration(
    Padding(
      padding: const EdgeInsets.only(left: 2, right: 9),
      child: dot,
    ),
  );
}

/// The vertical rule on the left of a quote.
///
/// It is exactly one row tall so consecutive quote lines butt up against each
/// other and read as a single continuous bar rather than a dashed one.
WidgetSpan _quoteBar(AppPalette p, TextStyle base) => _decoration(
  Padding(
    padding: const EdgeInsets.only(left: 2, right: 10),
    child: Container(
      width: 3,
      height: _lineHeightOf(base),
      color: p.accent.withValues(alpha: 0.6),
    ),
  ),
);

/// The sunken band that keeps a fenced block reading as a single slab.
WidgetSpan _codeBand(
  AppPalette p,
  double width, {
  String? label,
  double height = 18,
}) => _decoration(
  Container(
    // A few pixels short of the column: the widget plus whatever it swapped out
    // may never be wider than the line, or the paragraph wraps.
    width: math.max(24, width - 8),
    height: height,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.only(left: 11),
    color: p.surfaceSunken,
    child: label == null
        ? null
        : Row(
            children: <Widget>[
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: 0.55),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: AppFonts.mono,
                  fontFamilyFallback: AppFonts.monoFallback,
                  fontSize: 10.5,
                  letterSpacing: 0.3,
                  fontWeight: FontWeight.w600,
                  color: p.textTertiary,
                ),
              ),
            ],
          ),
  ),
);

/// The marker shell around a task checkbox.
///
/// [sourceOffset] is the offset of the character this box stands in for.
///
/// ⛔ **Deliberately not tappable.** A `GestureDetector` here would be hit
/// through the `TextPainter`'s *placeholder* box rather than the box the user
/// can see, which drifts apart as soon as the row wraps or the marker column has
/// more than one element — the reported symptom is "the box on the first line
/// works and the others do not". The editor instead runs a `Listener` over the
/// whole field and hit-tests this widget's real paint rect; see
/// `MarkdownEditor`.
class MarkdownTodoCheckbox extends StatelessWidget {
  const MarkdownTodoCheckbox({
    super.key,
    required this.sourceOffset,
    required this.child,
  });

  final int sourceOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

WidgetSpan _taskBox(AppPalette p, bool done, int sourceOffset) => _decoration(
  MarkdownTodoCheckbox(
    sourceOffset: sourceOffset,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.only(left: 2, right: 9),
        child: Container(
          width: 15,
          height: 15,
          decoration: BoxDecoration(
            color: done ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(
              color: done ? p.accent : p.outline,
              width: 1.5,
            ),
          ),
          child: done
              ? Icon(Icons.check_rounded, size: 11, color: p.onAccent)
              : null,
        ),
      ),
    ),
  ),
);

WidgetSpan _tagChip(
  AppPalette p,
  String tag,
  TextStyle body,
  void Function(String tag) onTap,
) {
  final double size = (body.fontSize ?? 15).clamp(11.0, 15.0);
  return _decoration(
    MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onTap(tag),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: p.accentSoft,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(color: p.accent.withValues(alpha: 0.25)),
          ),
          child: Text(
            '#$tag',
            style: TextStyle(
              fontSize: size * 0.88,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: p.isDark ? p.accent : p.accentHover,
            ),
          ),
        ),
      ),
    ),
  );
}

WidgetSpan _wikiChip(
  AppPalette p,
  String label,
  TextStyle body,
  void Function(String target) onTap,
) => _decoration(
  MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: () => onTap(label),
      child: Text(
        label,
        style: TextStyle(
          fontSize: body.fontSize,
          height: body.height,
          fontWeight: body.fontWeight,
          color: p.isDark ? p.accent : p.accentHover,
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
          decorationColor: p.accent.withValues(alpha: 0.45),
        ),
      ),
    ),
  ),
);

WidgetSpan _embedChip(
  AppPalette p,
  String label,
  void Function(String target) onTap,
) => _decoration(
  MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: () => onTap(label),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
        decoration: BoxDecoration(
          color: p.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: p.outlineSoft),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.attachment_rounded, size: 11, color: p.textTertiary),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: p.textSecondary),
            ),
          ],
        ),
      ),
    ),
  ),
);

WidgetSpan _linkChip(AppPalette p, String label, TextStyle body) => _decoration(
  Text(
    label,
    style: TextStyle(
      fontSize: body.fontSize,
      height: body.height,
      color: p.isDark ? p.accent : p.accentHover,
      decoration: TextDecoration.underline,
      decorationColor: p.accent.withValues(alpha: 0.35),
    ),
  ),
);

WidgetSpan _imageSpan(
  AppPalette p,
  String url,
  String alt,
  double maxWidth,
) => _decoration(
  Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: ClipRRect(
      borderRadius: AppRadius.mdAll,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.max(120, maxWidth - 24),
          maxHeight: 420,
        ),
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
              _brokenImage(p, alt),
        ),
      ),
    ),
  ),
);

Widget _brokenImage(AppPalette p, String alt) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  decoration: BoxDecoration(
    color: p.surfaceSunken,
    borderRadius: AppRadius.smAll,
    border: Border.all(color: p.outlineSoft),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(Icons.image_not_supported_outlined, size: 13, color: p.textTertiary),
      const SizedBox(width: 6),
      Text(
        alt.trim().isEmpty ? '图片无法加载' : alt.trim(),
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: p.textTertiary,
        ),
      ),
    ],
  ),
);

// -------------------------------------------------------------- the rule line

/// A horizontal rule (`---`, `***`, `___`), drawn as a full-width line.
///
/// ## Why this is a render object and not a `Container(width: …)`
///
/// A `WidgetSpan` child gets `BoxConstraints(maxWidth: 编辑框宽度)`, so its width
/// could just be a fixed number — except that number has to come from somewhere,
/// and one pixel over the edge makes the paragraph wrap: the row would grow a
/// phantom extra line. This box sidesteps the question entirely by **measuring
/// itself as zero wide** and painting the line out to whatever width its
/// constraints allow. A zero-width inline box can never wrap, and the line is
/// exactly as long as the column at any window size, no matter how many dashes
/// were typed.
///
/// It is `height` tall (a normal text row) with the line centred inside, so the
/// rule keeps the vertical rhythm instead of squashing the rows around it.
class MarkdownDividerLine extends LeafRenderObjectWidget {
  const MarkdownDividerLine({
    super.key,
    required this.color,
    required this.height,
    this.thickness = 1,
    this.inset = 4,
  });

  final Color color;
  final double height;
  final double thickness;
  final double inset;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderMarkdownDividerLine(color, height, thickness, inset);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMarkdownDividerLine renderObject,
  ) {
    renderObject
      ..color = color
      ..rowHeight = height
      ..thickness = thickness
      ..inset = inset;
  }
}

/// [MarkdownDividerLine]'s render object: size `0 × rowHeight`, line in `paint`.
class RenderMarkdownDividerLine extends RenderBox {
  RenderMarkdownDividerLine(
    this._color,
    this._rowHeight,
    this._thickness,
    this._inset,
  );

  Color _color;
  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double _rowHeight;
  double get rowHeight => _rowHeight;
  set rowHeight(double value) {
    if (value == _rowHeight) return;
    _rowHeight = value;
    markNeedsLayout();
  }

  double _thickness;
  double get thickness => _thickness;
  set thickness(double value) {
    if (value == _thickness) return;
    _thickness = value;
    markNeedsLayout();
  }

  double _inset;
  double get inset => _inset;
  set inset(double value) {
    if (value == _inset) return;
    _inset = value;
    markNeedsPaint();
  }

  /// How long the line turned out to be = the available width at the last
  /// layout pass. Only ever written from [performLayout] — [computeDryLayout] is
  /// a probe and may run after the real layout.
  double _lineWidth = 0;

  /// The width the last layout pass allowed (test-only).
  @visibleForTesting
  double get debugLineWidth => _lineWidth;

  @override
  void performLayout() {
    _lineWidth = constraints.maxWidth;
    size = constraints.constrain(Size(0, _rowHeight));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(0, _rowHeight));

  @override
  void paint(PaintingContext context, Offset offset) {
    final double w = _lineWidth - _inset;
    // Unbounded (or degenerate) constraints: draw nothing rather than throw.
    if (!w.isFinite || w <= 0 || _thickness <= 0) return;
    context.canvas.drawRect(
      Rect.fromLTWH(
        offset.dx + _inset / 2,
        offset.dy + (size.height - _thickness) / 2,
        w,
        _thickness,
      ),
      Paint()..color = _color,
    );
  }

  /// ⛔ Never take part in hit testing — clicking the rule must place the caret.
  @override
  bool hitTestSelf(Offset position) => false;
}
