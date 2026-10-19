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
import 'package:flutter/rendering.dart';

import '../../core/theme/app_palette.dart';
import '../../core/utils/markdown_actions.dart';
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
    required this.selA,
    required this.selB,
    required this.contentWidth,
    this.direction = TextDirection.ltr,
    this.textScaler = TextScaler.noScaling,
    this.plain = false,
    this.onTagTap,
    this.onWikilinkTap,
  });

  final AppPalette p;
  final int caretA;
  final int caretB;

  /// The **live** selection, which the wash follows even while [caretA]/[caretB]
  /// are frozen for a pointer gesture. A rendered chip cannot show the wash
  /// painted behind the field, so it tints itself from this instead.
  final int selA;
  final int selB;

  final double contentWidth;
  final TextDirection direction;

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

  /// True when the caret (or the reveal selection) overlaps `[a, b]`.
  bool touched(int a, int b) => caretA >= 0 && caretB >= a && caretA <= b;

  /// True when a **range** of the live selection intersects `[a, b]`.
  bool selected(int a, int b) => selA >= 0 && selB > selA && selB > a && selA < b;
}

/// Builds the styled span tree for live mode.
///
/// [tables] is filled with the geometry of every table block, so the pointer
/// layer can map a press on a rendered table back to the cell under it. The
/// renderer is the only thing that knows how wide a column came out.
///
/// [liveSelection] is the selection the wash follows when it differs from
/// [selection]: a pointer gesture freezes [selection] to keep markers from
/// reflowing text, but the bands — and a chip's selected tint — still have to
/// follow the pointer.
List<InlineSpan> buildLiveSpans({
  required String text,
  required TextStyle base,
  required AppPalette p,
  required TextSelection selection,
  TextSelection? liveSelection,
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
      final bool divider = isTableDivider(line);
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

  /// True when the selection is just a caret, which is the only case where a
  /// block collapsed to zero size (a table's divider row) may open a line of its
  /// own for editing — a range selection that merely *covers* it must not.
  final bool caretOnly = caretA >= 0 && caretA == caretB;
  final Set<int> revealedFences = <int>{};
  for (final int i in active) {
    if (fences[i] >= 0) revealedFences.add(fences[i]);
  }

  /// Where the **wash** sits, as opposed to where the markers are revealed.
  /// During a drag the reveal is frozen at pointer-down so markers cannot
  /// reflow text under the pointer, but the wash still has to track the live
  /// selection — measuring table bands from the frozen caret painted a strip of
  /// *prose* rows (one full-width band per table row) for the whole gesture.
  final TextSelection bandsSel = liveSelection ?? selection;
  int bandA = -1;
  int bandB = -1;
  if (bandsSel.isValid && bandsSel.start >= 0) {
    bandA = bandsSel.start.clamp(0, text.length);
    bandB = bandsSel.end.clamp(0, text.length);
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
    selA: bandA,
    selB: bandB,
    contentWidth: contentWidth,
    direction: direction,
    textScaler: textScaler,
    onTagTap: onTagTap,
    onWikilinkTap: onWikilinkTap,
  );

  /// The same context, but for text a render object will repaint (table
  /// cells): chips need a build context, so cells fall back to plain text.
  ///
  /// `caretA: -1` keeps every cell rendered by default. The cell the caret
  /// sits in is rebuilt with its source revealed (see [editAt]); that tree is
  /// both painted and laid out invisibly as the skeleton, so the caret still
  /// lands on the glyph under it. Revealing a cell would be fatal if the two
  /// trees disagreed — a `**` that expanded in only one of them would push the
  /// glyphs out of alignment with the caret.
  final _Ctx plainCtx = _Ctx(
    p: p,
    caretA: -1,
    caretB: -1,
    selA: bandA,
    selB: bandB,
    contentWidth: contentWidth,
    direction: direction,
    textScaler: textScaler,
    plain: true,
    onTagTap: onTagTap,
    onWikilinkTap: onWikilinkTap,
  );

  /// Absolute offset of the caret the **live** selection puts in a table, or
  /// `-1` when the selection is a range.
  ///
  /// A rendered table is edited cell by cell: the cell under the caret opens
  /// its Markdown source while every other cell stays rendered. A range is a
  /// selection gesture — revealing source inside it would reflow glyphs under
  /// the pointer and make the drag impossible to aim — so it keeps the whole
  /// table rendered.
  final int editAt = bandsSel.isValid && bandsSel.isCollapsed
      ? bandsSel.start.clamp(0, text.length)
      : -1;

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
      ctx: plainCtx,
      editAt: editAt,
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

  /// Where the selection sits inside each table, computed once per block.
  ///
  /// A cell is painted by a render object, so the wash cannot be the
  /// paragraph's own highlight — that one is a full-width stripe over the
  /// skeleton, which is exactly what made a partly selected table look like a
  /// selected *row*. The band has to be measured from the same glyphs the row
  /// paints, which means a `TextPainter` per cell; hence the cache.
  final Map<int, List<_RowBand?>> bandCache = <int, List<_RowBand?>>{};
  List<_RowBand?> bandsOf(int tableId) => bandCache.putIfAbsent(
    tableId,
    () => _bandsOfTable(tableBlocks[tableId], bandA, bandB),
  );

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
            style: on ? _markerVisible(h, p, accented: true) : _collapsed(base),
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
        out.addAll(_indentRun(m.group(1)!, base, p));
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
        out.addAll(_indentRun(m.group(1)!, base, p));
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
        out.addAll(_indentRun(m.group(1)!, base, p));
        final String marker = '$lead${m.group(3)}${m.group(4)}${m.group(5)}';
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
          out.add(
            _taskBox(p, done, at + m.group(1)!.length + lead.length + gap),
          );
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
        out.add(
          _decoration(MarkdownDividerLine(color: p.outline, height: row)),
        );
        out.add(_swallowed(line, base));

      case _Kind.tableHeader:
      case _Kind.table:
        final _Table? table = tableOf[i] < 0
            ? null
            : (tableOf[i] < tableBlocks.length
                  ? tableBlocks[tableOf[i]]
                  : null);
        final List<_CellData>? cells =
            (table != null && table.lineOfRow.containsKey(i))
            ? table.cellsOf(i)
            : null;
        if (cells == null || cells.isEmpty) {
          // The block is malformed: raw source, pipes and all.
          out.addAll(_tableRowSource(line, base, at, ctx));
          break;
        }
        // ⛔ A table row is **never** folded back to its source just because
        // the caret is in it. Clicking a cell used to turn the row into
        // `| 侧栏 | 全部笔记 |` mid-table, which is the one thing Obsidian never
        // does: the caret edits the cell in place, and the grid stays a grid
        // while you type. The skeleton below puts every character exactly under
        // its painted glyph, so the caret and the hit-testing agree without the
        // source ever being on screen.
        final bool isLastRow = table!.rows.last.line == i;
        // Where this row's share of the selection is. Only the cells the
        // selection actually reaches are washed, and each of them **whole**:
        // touching part of a cell selects that cell, the way a table is meant
        // to be selected. Washing whole rows (which is what this used to do)
        // meant selecting two cells out of three lit up the third one too, and
        // the user's only way to select part of a table was to select all of
        // it — user: 「表格让我可以只选取其中一部分」.
        //
        // The neighbouring bands come along for the ride because they decide
        // which edges are *outward*: a corner is rounded only where the shape
        // turns, so a stack of identical bands is still one rounded rectangle
        // instead of one ring per row.
        final int rowIndex = table.lineOfRow[i]!;
        final List<_RowBand?> bands = bandsOf(tableOf[i]);
        final _RowBand? band = rowIndex < bands.length ? bands[rowIndex] : null;
        final _RowBand? above = rowIndex > 0 && rowIndex - 1 < bands.length
            ? bands[rowIndex - 1]
            : null;
        final _RowBand? below = rowIndex + 1 < bands.length
            ? bands[rowIndex + 1]
            : null;
        out.add(
          _decoration(
            _TableRowView(
              cells: <_PaintCell>[
                for (final _CellData d in cells)
                  _PaintCell(
                    spans: d.spans,
                    cell: TableCellGeometry(
                      start: d.cell.offset,
                      end: d.cell.offset + d.cell.text.length,
                      x: d.x,
                      width: d.boxWidth,
                    ),
                    style: d.style,
                    dx: d.textX,
                    codeRuns: d.codeRuns,
                  ),
              ],
              palette: p,
              rowHeight: table.rowHeight,
              tableWidth: table.width,
              dyShift: table.dyShift,
              header: kinds[i] == _Kind.tableHeader,
              last: isLastRow,
              band: band,
              above: above,
              below: below,
              tableId: table.rows.first.start,
              sourceStart: at,
              rowIndex: rowIndex,
              rowCount: table.rows.length,
              textScaler: ctx.textScaler,
              direction: direction,
            ),
          ),
        );
        // The skeleton: the same characters, invisible, with the advances the
        // painted row has. It carries no paint — its whole job is to give the
        // paragraph real positions, so a click or a drag inside the painted
        // table lands on the character under the pointer without any custom hit
        // testing.
        out.addAll(_tableRowSkeleton(line, base, at, cells));
        break;

      case _Kind.tableDivider:
        // The divider row carries no pixels of its own — the header's bottom
        // border is drawn by the row above it. Collapsing it to a zero-size run
        // is what makes the header sit *flush* on the first body row; left at
        // body size it would leave a whole empty line between them, which is
        // how a rendered table ended up looking like two disconnected strips.
        // Its own source is only on screen while the **caret** is on that line.
        // A range selection must not reveal it: selecting a table is the most
        // common thing you do to a table, and `| --- | --- |` lighting up in the
        // middle of the wash tears one block into two strips.
        final bool caretHere = on && ctx.caretA == ctx.caretB;
        out.add(
          TextSpan(
            text: line,
            style: caretHere
                ? base.copyWith(color: p.textTertiary.withValues(alpha: 0.5))
                : _collapsed(base),
          ),
        );

      case _Kind.paragraph:
        out.addAll(_inline(line, base, at, ctx));
    }

    // The divider row must not hold a line of its own open.
    //
    // Its characters are collapsed to zero size — but a *blank* line still gets
    // the paragraph's default height, so leaving the break at body size put a
    // 28px hole between the header and the first body row and the table read as
    // two disconnected strips.
    //
    // So the break *before* the divider is replaced by a zero-size widget. A
    // `WidgetSpan` stands in for exactly one source character, so the newline is
    // still at its own offset — the tree is unchanged in length and order — it
    // just does not break the line. The divider's characters then ride along at
    // the end of the header's row, where they cost nothing, and the divider's
    // own collapsed break ends that line.
    //
    // The one exception is a caret parked **on the divider line**: there the
    // user is editing `| --- | --- |` and needs to see it, on a line of its own.
    // A range selection is not that — it only *covers* the divider, and giving
    // it a line would put a 28px hole through the middle of a selected table.
    final bool softBreak =
        i + 1 < n &&
        kinds[i + 1] == _Kind.tableDivider &&
        !(active.contains(i + 1) && caretOnly);
    if (i != n - 1) {
      out.add(
        softBreak
            ? _decoration(const SizedBox(width: 0, height: 0))
            : TextSpan(text: '\n', style: base),
      );
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

/// A widget aligned on the text's baseline rather than on the line's middle.
///
/// The middle of a taller paragraph line and the middle of a shorter run's own
/// line box are not the same point when the two fonts have different ascent
/// ratios; a code chip's ends measured against the line middle sat about a
/// pixel below the run's own background. Baseline alignment lines the cap's
/// box up with the run the moment both are measured with the same style.
WidgetSpan _baselineDecoration(Widget child) => WidgetSpan(
  alignment: PlaceholderAlignment.baseline,
  baseline: TextBaseline.alphabetic,
  child: child,
);

/// The characters a decoration did not consume, collapsed to nothing so the
/// caret still has real offsets to move through.
TextSpan _swallowed(String marker, TextStyle base) => TextSpan(
  text: marker.length <= 1 ? '' : marker.substring(1),
  style: _collapsed(base),
);

/// Turns a designed line-height multiplier into one the paragraph can honour.
///
/// A paragraph rounds every line's *advance* to a whole logical pixel, but it
/// computes that line's box from `fontSize * height` unchanged. `15.5 * 1.78`
/// is 27.59, so every box is 0.41px shorter than the step to the next line;
/// the table's row chrome and the selection's boxes are then measured on a
/// different grid from the glyphs and drift inside their rows. Handing back a
/// multiplier whose product is *already* whole makes the box and the advance
/// agree to the last bit (the box height is `fontSize * height` — verified
/// across 1.7 … 1.9).
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

/// How far one nest level pushes the marker to the right.
///
/// Exactly one marker column (`_taskBox`'s 2 + 15 + 9), so a child's content
/// lines up under its parent's content instead of drifting.
const double _kIndentStep = 26;

/// Distance from the row start to the *centre* of a level's marker — where that
/// level's rail is drawn.
const double _kMarkerCentre = 9.5;

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
        color: p.outline,
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

/// The invisible skeleton of a rendered row.
///
/// Every character of the line is still in the tree (the length invariant), but
/// only the cells' text runs have their natural advance; the pipes and the
/// spaces around them are zero-size runs whose `letterSpacing` is set so that
/// each run ends exactly where the *next* cell's text begins.
///
/// That gap arithmetic is the whole trick: the painted cell text starts at
/// `cell.x + _kCellPad` (or wherever [ _CellData.textX ] puts it), so the
/// skeleton has to carry the same offset. Left as plain collapsed whitespace,
/// every column would drift 8px to the left of its painted glyphs — and a click
/// on the third column would put the caret on the second one.
List<InlineSpan> _tableRowSkeleton(
  String line,
  TextStyle base,
  int absStart,
  List<_CellData> cells,
) {
  final List<InlineSpan> spans = <InlineSpan>[];
  // The row widget stands on the leading pipe and is `_kCellPad` wide, so the
  // first cell's text starts exactly where it is painted.
  double x = _kCellPad;

  /// Fills the source characters `[from, to)` of the line with something that
  /// advances exactly up to [target].
  ///
  /// ⛔ The width goes into a **widget**, not into a `letterSpacing`. A collapsed
  /// run carrying 300px of tracking makes the paragraph push that trailing
  /// spacing onto the next line, which silently doubles the height of the row —
  /// measured, not guessed: a gap of 195 made the header row 56px tall in a
  /// 28px document. A zero-height box has no such failure mode and lands on the
  /// same pixel.
  void gap(int from, int to, double target) {
    if (to <= from) return;
    final double width = math.max(0, target - x);
    spans.add(_decoration(SizedBox(width: width, height: 0)));
    if (to - from > 1) {
      spans.add(
        TextSpan(text: line.substring(from + 1, to), style: _collapsed(base)),
      );
    }
    x += width;
  }

  int cursor = 1; // the row's first character carries the row widget
  for (final _CellData d in cells) {
    final int from = d.cell.offset - absStart;
    gap(cursor, from, d.textX);
    spans.add(TextSpan(style: d.style, children: _transparent(d.spans)));
    x += d.advance;
    cursor = from + d.cell.text.length;
  }
  // The last cell can be **wider than its text**: an empty cell still gets the
  // column minimum, and an aligned cell gets slop. If the skeleton stopped at
  // the text plus padding, a click on the blank half of that last cell landed
  // past the end of the paragraph line — on the collapsed divider source, which
  // the soft break parks right behind it. The caret then looked like it was in
  // the header while typing edited `| --- | --- |`. The skeleton spans the
  // whole painted box so every click in the cell resolves inside its own line.
  gap(
    cursor,
    line.length,
    cells.isEmpty ? x + _kCellPad : cells.last.x + cells.last.boxWidth,
  );
  return spans;
}

/// One cell handed to the row renderer: its inline spans, where its box sits
/// in the table, and where its text starts inside that box.
/// Where one row's share of the selection sits, in the table's coordinates.
///
/// `left`/`right` are always **cell edges**, never glyph edges. A table is
/// selected by the cell, not by the character: touching two characters of `就写`
/// washes all of `就写`. That is what makes neighbouring cells merge into one
/// band with no seam at the pipe, and — the reason this used to be wrong — what
/// keeps a two-row selection two clean steps instead of a staircase of
/// half-cells with a frame around each step.
/// user: 「这个选中就是按格子来选中啊，跨表格选中文字干什么？？？」
class _RowBand {
  const _RowBand(this.left, this.right);

  final double left;
  final double right;

  /// Same edge, give or take the sub-pixel the cell boxes rounded to.
  bool near(_RowBand? other) =>
      other != null &&
      (other.left - left).abs() < 0.5 &&
      (other.right - right).abs() < 0.5;

  @override
  bool operator ==(Object other) => other is _RowBand && near(other);

  @override
  int get hashCode => Object.hash(left.round(), right.round());
}

/// The selection's band for every painted row of [table], `null` where the
/// selection does not reach.
///
/// A table is selected **by the cell, as a block**: the wash runs from the
/// anchor's cell to the focus's cell — the rows between them, and the columns
/// between them. Reading the selection as a linear text range instead (which is
/// what this did) washes every cell the range passes over, so a drag down one
/// column came back with the whole middle row lit:
/// user: 「我只选了右边三个表格，为什么会把左边那两个一起选中？？？」
List<_RowBand?> _bandsOfTable(_Table table, int a, int b) {
  final int rows = table.rows.length;
  final List<_RowBand?> none = List<_RowBand?>.filled(rows, null);
  if (b <= a || rows == 0) return none;
  if (a >= table.rows.last.end || b <= table.rows.first.start) return none;

  final (int, int) from = _cellAt(table, a, extent: false);
  // `b` is exclusive: the last selected character is the one before it, and on
  // a row boundary that character is the line break above, not the next row's
  // first cell.
  final (int, int) to = _cellAt(table, b - 1, extent: true);
  final int r0 = math.min(from.$1, to.$1);
  final int r1 = math.max(from.$1, to.$1);
  final int c0 = math.min(from.$2, to.$2);
  final int c1 = math.max(from.$2, to.$2);
  return <_RowBand?>[
    for (int r = 0; r < rows; r++)
      r < r0 || r > r1 ? null : _bandOfRow(table.rows[r], c0, c1),
  ];
}

/// Which painted cell an offset belongs to, as `(row, column)` indices.
///
/// An offset that sits between two rows — a line break, or the `--- | ---`
/// divider — belongs to the row it *reads* into: the one below for an anchor
/// (the caret is at the start of that row's text) and the one above for an
/// extent (the last character selected is the one before the break).
(int, int) _cellAt(_Table table, int offset, {required bool extent}) {
  final List<_RowData> rows = table.rows;
  for (int r = 0; r < rows.length; r++) {
    final _RowData row = rows[r];
    if (offset < row.start) {
      if (!extent || r == 0) return (r, 0);
      return (r - 1, rows[r - 1].data.length - 1);
    }
    if (offset >= row.end || row.data.isEmpty) continue;
    for (int c = 0; c < row.data.length; c++) {
      final _CellData d = row.data[c];
      final int start = d.cell.offset;
      final int end = start + d.cell.text.length;
      if (offset < end) return (r, c);
    }
    // Past the last cell: the row's trailing pipe, which belongs to it.
    return (r, row.data.length - 1);
  }
  if (offset < rows.first.start) return (0, 0);
  return (rows.length - 1, rows.last.data.length - 1);
}

/// Columns `[c0, c1]` of one row, as one span from the first cell's left edge to
/// the last one's right edge. The cells tile the row edge to edge, so this is
/// also where two neighbours merge into one band with no seam at the pipe.
_RowBand? _bandOfRow(_RowData row, int c0, int c1) {
  if (row.data.isEmpty) return null;
  final _CellData first = row.data[c0.clamp(0, row.data.length - 1)];
  final _CellData last = row.data[c1.clamp(0, row.data.length - 1)];
  final double left = first.x;
  final double right = last.x + last.boxWidth;
  if (right - left < 0.5) return null;
  return _RowBand(left, right);
}

/// One of the small controls a live table hangs around itself: a grip to drag a
/// whole row or column, and a `+` to add one in that direction.
enum TableChromeKind { rowHandle, columnHandle, addRow, addColumn }

/// A painted chrome control, in **global** coordinates.
class TableChromeTarget {
  const TableChromeTarget(this.kind, this.rect, this.index);

  final TableChromeKind kind;
  final Rect rect;

  /// The row or column the control belongs to. `-1` for the two `+` buttons,
  /// whose direction ("below", "right") is what they mean.
  final int index;
}

/// The drop the pointer is currently proposing, so every row of that table can
/// show it without the whole span tree being rebuilt for a mouse move.
///
/// A module-level notifier, deliberately: the rows are render objects inside a
/// paragraph, and a drag is a purely visual state — pushing it through the
/// controller would re-render the document on every mouse event.
final ValueNotifier<TableDragPreview?> tableDragPreview =
    ValueNotifier<TableDragPreview?>(null);

class TableDragPreview {
  const TableDragPreview({
    required this.tableId,
    required this.column,
    required this.index,
    this.count = 1,
  });

  /// Source offset of the table block's first line — identity of the table.
  final int tableId;

  /// True while dragging a column, false while dragging a row.
  final bool column;

  /// Where it would land.
  final int index;

  /// How many rows or columns the drag would move. A grip dragged out of a
  /// multi-row/column selection moves the whole block, and the preview has to
  /// show the whole destination — one lit row would promise the wrong thing.
  final int count;
}

/// Where the mouse is, in **global** coordinates — `null` while it is outside
/// the editor.
///
/// The table chrome is deliberately **hover-only**: a grip or a `+` shows up
/// when the pointer comes within [kTableChromeSlop] of the edge it lives on,
/// and disappears again when the pointer leaves. A module-level notifier, like
/// [tableDragPreview], because hovering is purely visual: pushing it through
/// the controller would rebuild the whole span tree on every mouse move, while
/// the rows can simply repaint.
final ValueNotifier<Offset?> tablePointerPosition = ValueNotifier<Offset?>(
  null,
);

/// How far outside a control still counts as "the pointer is on it".
///
/// Wide enough that aiming at a 12px glyph off the table's edge does not need
/// pixel accuracy; narrow enough that the band never reaches the cells' text
/// (the grips start 5px outside the table, so 6px of slop ends on its border).
const double kTableChromeSlop = 6;

/// What the pointer layer needs from one rendered table row.
abstract class TableRowChrome {
  /// Identity of the table block this row belongs to (its first line's offset).
  int get chromeTableId;

  /// Absolute source offset of this row's first character.
  int get chromeSourceStart;

  /// Index of this row among the block's non-divider rows.
  int get chromeRowIndex;
  int get chromeRowCount;

  /// The row's painted box, in global coordinates — the whole table's width.
  Rect chromeBounds();

  /// The cells' global boxes, left to right.
  List<Rect> chromeCells();

  /// Every handle and `+` this row *can* paint, in global coordinates. Hit
  /// testing uses these: the pointer can only reach one of them by hovering it,
  /// which is also what makes it visible.
  List<TableChromeTarget> chromeTargets();

  /// The subset actually painted right now — hover-only, and the drag target
  /// during a drag. What the user can see is exactly what these are.
  List<TableChromeTarget> chromeVisible();
}

/// One inline code token in a cell, as range data for the row renderer.
///
/// [start] and [end] count characters in the cell's painted text (the source
/// the span tree carries), so they can be fed straight to
/// [TextPainter.getBoxesForSelection]. [style] is the code run's own style —
/// the renderer measures it to get the band's height and baseline — and [fill]
/// already has the selection tint mixed in.
class _CellCode {
  const _CellCode({
    required this.start,
    required this.end,
    required this.probe,
    required this.style,
    required this.fill,
  });

  final int start;
  final int end;
  final String probe;
  final TextStyle style;
  final Color fill;
}

class _PaintCell {
  _PaintCell({
    required this.spans,
    required this.cell,
    required this.style,
    required this.dx,
    required this.codeRuns,
  });

  final List<InlineSpan> spans;
  final TableCellGeometry cell;
  final TextStyle style;
  final List<_CellCode> codeRuns;

  /// Left edge of the **text** (not the box), in the table's coordinates.
  /// Comes from [ _CellData.textX ], so a centred or right-aligned column is
  /// painted exactly where the skeleton says its characters are.
  final double dx;
}

/// A rounded fill behind one inline code run, in the cell painter's coordinates.
class _PaintedChip {
  const _PaintedChip(this.rect, this.fill);

  final Rect rect;
  final Color fill;
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
    required this.dyShift,
    required this.header,
    required this.last,
    required this.band,
    required this.above,
    required this.below,
    required this.tableId,
    required this.sourceStart,
    required this.rowIndex,
    required this.rowCount,
    required this.textScaler,
    required this.direction,
  });

  final List<_PaintCell> cells;
  final AppPalette palette;
  final double rowHeight;
  final double tableWidth;

  /// How far down the row has to be nudged to sit on its paragraph line — see
  /// [_Table.dyShift].
  final double dyShift;

  /// The row above the divider (bold, and it draws the rule under itself).
  final bool header;

  /// The last row of the block: it closes the grid at the bottom.
  final bool last;

  /// This row's share of the selection, or `null` when the selection does not
  /// reach it — the whole cells it touches, see [_RowBand].
  final _RowBand? band;

  /// The bands of the rows above and below. They are what tells a row which of
  /// its four edges face *out* of the shape: a corner is rounded only where the
  /// shape actually turns, so a stack of equal bands is still one rounded
  /// rectangle rather than one ring per row, while a selection that starts
  /// halfway through the table gets a properly closed left edge.
  final _RowBand? above;
  final _RowBand? below;

  /// Source offset of the block's first line — the table's identity.
  final int tableId;

  /// Source offset of this row's first character, and its index among the
  /// block's non-divider rows. The drag handles hand these straight to
  /// `moveTableRow` / `moveTableColumn`, so the pointer layer never has to
  /// re-parse the document to find out what it grabbed.
  final int sourceStart;
  final int rowIndex;
  final int rowCount;

  final TextScaler textScaler;
  final TextDirection direction;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTableRow(
    cells,
    palette,
    rowHeight,
    tableWidth,
    dyShift,
    header,
    last,
    band,
    above,
    below,
    tableId,
    sourceStart,
    rowIndex,
    rowCount,
    textScaler,
    direction,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderTableRow renderObject) {
    renderObject
      ..cells = cells
      ..palette = palette
      ..rowHeight = rowHeight
      ..tableWidth = tableWidth
      ..dyShift = dyShift
      ..header = header
      ..last = last
      ..band = band
      ..above = above
      ..below = below
      ..tableId = tableId
      ..sourceStart = sourceStart
      ..rowIndex = rowIndex
      ..rowCount = rowCount
      ..textScaler = textScaler
      ..direction = direction;
  }
}

class _RenderTableRow extends RenderBox implements TableRowChrome {
  _RenderTableRow(
    this._cells,
    this._palette,
    this._rowHeight,
    this._tableWidth,
    this._dyShift,
    this._header,
    this._last,
    this._band,
    this._above,
    this._below,
    this._tableId,
    this._sourceStart,
    this._rowIndex,
    this._rowCount,
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

  double _dyShift;
  set dyShift(double value) {
    if (value == _dyShift) return;
    _dyShift = value;
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

  _RowBand? _band;
  set band(_RowBand? value) {
    if (value == _band) return;
    _band = value;
    markNeedsPaint();
  }

  _RowBand? _above;
  set above(_RowBand? value) {
    if (value == _above) return;
    _above = value;
    markNeedsPaint();
  }

  _RowBand? _below;
  set below(_RowBand? value) {
    if (value == _below) return;
    _below = value;
    markNeedsPaint();
  }

  int _tableId;
  set tableId(int value) {
    if (value == _tableId) return;
    _tableId = value;
    markNeedsPaint();
  }

  int _sourceStart;
  set sourceStart(int value) {
    if (value == _sourceStart) return;
    _sourceStart = value;
  }

  int _rowIndex;
  set rowIndex(int value) {
    if (value == _rowIndex) return;
    _rowIndex = value;
    markNeedsPaint();
  }

  int _rowCount;
  set rowCount(int value) {
    if (value == _rowCount) return;
    _rowCount = value;
  }

  // ------------------------------------------------------------ the chrome
  //
  // The grips and `+` buttons are painted, not widgets: a `WidgetSpan` child
  // that accepted a hit would swallow the click the caret needs, and the row's
  // own box is deliberately zero-wide. The pointer layer reads the rects back
  // through [chromeTargets] and drives `markdown_actions` itself.

  bool get _paintsColumnGrip => _rowIndex == 0;
  bool get _paintsAddRow => _rowIndex == _rowCount - 1;
  bool get _paintsAddColumn => _rowIndex == 0;

  /// Everything the chrome is drawn with, in this row's own coordinates — the
  /// origin is the table's left edge, the row's own box being one padding
  /// column wide (see [paint]).
  ///
  /// The grips live *outside* the table: left of a row, above a column, with
  /// the two `+` buttons right of and below it. That is where they belong
  /// (Obsidian puts them there too), and it keeps them off the cells the user
  /// is reading. All four are sized for their **glyph**, not for a button:
  /// a bare six-dot grip needs 16x16, a bare plus 12x12.
  Rect rowGripRect() => Rect.fromLTWH(
    -_kChromeGap - _kGrip,
    (_contentHeight - _kGrip) / 2,
    _kGrip,
    _kGrip,
  );

  Rect columnGripRect(int column) {
    final Rect cell = _cellRect(column);
    return Rect.fromLTWH(
      cell.center.dx - _kGrip / 2,
      -_kChromeGap - _kGrip,
      _kGrip,
      _kGrip,
    );
  }

  Rect addRowRect() => Rect.fromLTWH(
    _tableWidth / 2 - _kAdd / 2,
    _contentHeight + _kChromeGap,
    _kAdd,
    _kAdd,
  );

  Rect addColumnRect() => Rect.fromLTWH(
    _tableWidth + _kChromeGap,
    (_contentHeight - _kAdd) / 2,
    _kAdd,
    _kAdd,
  );

  /// Every control this row can paint, in paint order.
  ///
  /// One list, so the drawn controls and the hit-testable ones cannot drift
  /// apart — which is also what lets [chromeVisible] answer for the tests
  /// without anyone reading pixels.
  Iterable<(TableChromeKind, Rect, int)> _controls() sync* {
    yield (TableChromeKind.rowHandle, rowGripRect(), _rowIndex);
    if (_paintsColumnGrip) {
      for (int c = 0; c < _cells.length; c++) {
        yield (TableChromeKind.columnHandle, columnGripRect(c), c);
      }
    }
    if (_paintsAddColumn) {
      yield (TableChromeKind.addColumn, addColumnRect(), -1);
    }
    if (_paintsAddRow) {
      yield (TableChromeKind.addRow, addRowRect(), -1);
    }
  }

  /// Is the pointer within [kTableChromeSlop] of [local]? This — not the caret
  /// — is what makes a control exist on screen.
  bool _hovering(Rect local, [Offset? origin]) {
    final Offset? p = tablePointerPosition.value;
    if (p == null) return false;
    return local
        .shift(origin ?? _paintedOrigin)
        .inflate(kTableChromeSlop)
        .contains(p);
  }

  /// …and is it *on* the glyph rather than merely near the edge? A control
  /// under the pointer is drawn through the accent; its neighbours stay quiet.
  bool _pointing(Rect local) {
    final Offset? p = tablePointerPosition.value;
    if (p == null || !_hovering(local)) return false;
    return local.shift(_paintedOrigin).inflate(2).contains(p);
  }

  /// True while [kind] is the drop target of a drag — the grip the row or
  /// column would land on stays lit even though the pointer has left it.
  bool _dragging(TableChromeKind kind, int index) {
    final TableDragPreview? preview = tableDragPreview.value;
    if (preview == null || preview.tableId != _tableId) return false;
    if (kind == TableChromeKind.rowHandle) {
      return !preview.column &&
          index >= preview.index &&
          index < preview.index + preview.count;
    }
    if (kind == TableChromeKind.columnHandle) {
      return preview.column &&
          index >= preview.index &&
          index < preview.index + preview.count;
    }
    return false;
  }

  bool _visible(TableChromeKind kind, Rect local, int index) =>
      _dragging(kind, index) || _hovering(local);

  /// The box of column [column] in this row, or a zero-width sliver at the
  /// table's right edge when the row has fewer cells than the table.
  Rect _cellRect(int column) {
    if (column < 0 || column >= _cells.length) {
      return Rect.fromLTWH(_tableWidth, 0, 0, _contentHeight);
    }
    final TableCellGeometry c = _cells[column].cell;
    return Rect.fromLTWH(c.x, 0, c.width, _contentHeight);
  }

  // ------------------------------------------------------- the pointer layer

  @override
  int get chromeTableId => _tableId;

  @override
  int get chromeSourceStart => _sourceStart;

  @override
  int get chromeRowIndex => _rowIndex;

  @override
  int get chromeRowCount => _rowCount;

  /// The row's paint origin: `paint` nudges the whole row down by [_dyShift] to
  /// sit on its paragraph line, so the painted box is that much lower than the
  /// box the framework hit-tests. Every rect the pointer layer gets has to be
  /// measured from *here*, or the grips sit a couple of pixels off their paint.
  Offset get _paintedOrigin => localToGlobal(Offset(0, _dyShift));

  @override
  Rect chromeBounds() => _paintedOrigin & Size(_tableWidth, _contentHeight);

  @override
  List<Rect> chromeCells() => <Rect>[
    for (final _PaintCell cell in _cells)
      _paintedOrigin + Offset(cell.cell.x, 0) &
          Size(cell.cell.width, _contentHeight),
  ];

  @override
  List<TableChromeTarget> chromeTargets() {
    final Offset origin = _paintedOrigin;
    return <TableChromeTarget>[
      for (final (TableChromeKind k, Rect r, int i) in _controls())
        TableChromeTarget(k, r.shift(origin), i),
    ];
  }

  @override
  List<TableChromeTarget> chromeVisible() {
    final Offset origin = _paintedOrigin;
    return <TableChromeTarget>[
      for (final (TableChromeKind k, Rect r, int i) in _controls())
        if (_visible(k, r, i)) TableChromeTarget(k, r.shift(origin), i),
    ];
  }

  // ----------------------------------------------------------- the preview

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    tableDragPreview.addListener(markNeedsPaint);
    tablePointerPosition.addListener(_pointerMoved);
  }

  @override
  void detach() {
    tableDragPreview.removeListener(markNeedsPaint);
    tablePointerPosition.removeListener(_pointerMoved);
    super.detach();
  }

  /// Hovering is a paint-only change, so the rows listen to the pointer
  /// themselves instead of the span tree being rebuilt for it.
  ///
  /// Guarded by [_pointerNear]: a mouse moving across a long note would
  /// otherwise repaint every table in it — the whole point of not rebuilding
  /// the tree is lost if the painting is just as eager.
  bool _wereNear = false;

  bool _pointerNear() {
    final Offset? p = tablePointerPosition.value;
    if (p == null) return false;
    final Rect box = _paintedOrigin & Size(_tableWidth, _contentHeight);
    return box
        .inflate(_kChromeGap + _kGrip + kTableChromeSlop + 8)
        .contains(p);
  }

  void _pointerMoved() {
    final bool near = _pointerNear();
    if (!near && !_wereNear) return;
    _wereNear = near;
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
  final List<List<_PaintedChip>> _chips = <List<_PaintedChip>>[];
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
    _chips.clear();
    _contentHeight = _rowHeight;
    for (final _PaintCell cell in _cells) {
      final TextPainter tp = TextPainter(
        text: TextSpan(style: cell.style, children: cell.spans),
        textDirection: _direction,
        textScaler: _textScaler,
        // One line, always. A cell that wrapped would paint a second line
        // outside its own row box and cut straight through the row below it —
        // the column widths and the skeleton already guarantee it fits.
        maxLines: 1,
        ellipsis: '…',
      );
      tp.layout(maxWidth: math.max(1, cell.cell.width - 2 * _kCellPad));
      _painters.add(tp);
      _chips.add(_chipsFor(tp, cell));
      _contentHeight = math.max(_contentHeight, tp.height);
    }
    // `_kCellPad` wide, not zero: the row stands on the line's first character
    // and that character has to leave room for the first cell's left padding,
    // or the skeleton under the row would sit 8px left of the painted text.
    // (The table is painted from `-_kCellPad`, so the grid still starts at the
    // text column's left edge.)
    size = constraints.constrain(Size(_kCellPad, _contentHeight));
  }

  /// Measures one rounded chip per inline code run in [cell].
  ///
  /// The horizontal span comes from the cell's own painter — the two collapsed
  /// backticks reserve the padding as `letterSpacing`, so their boxes are the
  /// chip's true ends, squeeze correction and all. Vertically the chip must
  /// match the code run's *line box*, not its ink: a separate painter measures
  /// the mono style, and the band hangs from the cell's baseline exactly like
  /// the prose chip's end caps do.
  List<_PaintedChip> _chipsFor(TextPainter tp, _PaintCell cell) {
    if (cell.codeRuns.isEmpty) return const <_PaintedChip>[];
    final double baseline = tp.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final List<_PaintedChip> chips = <_PaintedChip>[];
    for (final _CellCode code in cell.codeRuns) {
      final List<TextBox> boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: code.start, extentOffset: code.end),
      );
      if (boxes.isEmpty) continue;
      double left = boxes.first.left;
      double right = boxes.first.right;
      for (final TextBox box in boxes) {
        left = math.min(left, box.left);
        right = math.max(right, box.right);
      }
      final TextPainter metrics = TextPainter(
        text: TextSpan(
          text: code.probe.isEmpty ? ' ' : code.probe,
          style: code.style,
        ),
        textDirection: _direction,
        textScaler: _textScaler,
      )..layout();
      final double drop = metrics.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      chips.add(
        _PaintedChip(
          Rect.fromLTRB(
            left,
            baseline - drop,
            right,
            baseline - drop + metrics.height,
          ),
          code.fill,
        ),
      );
      metrics.dispose();
    }
    return chips;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(_kCellPad, _rowHeight));

  /// ⛔ Never take part in hit testing. The invisible skeleton underneath owns
  /// the pointer; if this box absorbed a tap the caret would stop moving.
  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    final double height = _contentHeight;
    // ⛔ `offset` is the row's own position **inside the paragraph**, and the
    // canvas is *not* translated for us: `RenderParagraph.paintInlineChildren`
    // calls `context.paintChild(child, childOffset + offset)`, so a child that
    // draws at its local (0, 0) lands at the paragraph's origin — which for this
    // editor is the top of the document. Dropping `offset` here is what put the
    // whole frame above the note, user: 「表格的方框在最顶部显示了」. The other
    // two render objects in this file (the indent rail, the divider) both add
    // it; only this one used to believe the canvas came pre-translated.
    //
    // [localToGlobal] is then only good for *sub-pixel* snapping: the paragraph
    // sits at a fractional origin once the editor scrolls, and a 1px rule at a
    // fractional `dy` lands between two device pixels and dissolves into the
    // selection wash instead of closing around it — user: 「四周怎么没有闭合？」.
    final Offset origin = localToGlobal(Offset.zero);
    // The table starts **on the text column's left edge**: the row's own box is
    // one padding column wide and stands on the line's first character (`|`),
    // so that padding is already spent by the paragraph before this point.
    // Both edges are then nudged by less than half a pixel so they land on
    // whole device pixels (`_dyShift` is the row's share of the line height:
    // the placeholder is `PlaceholderAlignment.middle`, so the frame has to be
    // pushed down to the top of the glyphs the cells paint).
    final double left = offset.dx + origin.dx.roundToDouble() - origin.dx;
    final double top =
        offset.dy + (origin.dy + _dyShift).roundToDouble() - origin.dy;
    final double right = left + _tableWidth;
    final double bottom = top + height;

    /// A column boundary in this row's coordinates, snapped to the pixel grid.
    /// Each one is rounded on its own, so the rounding cannot accumulate across
    /// the table and every rule comes out exactly one pixel wide.
    double edgeAt(double tableX) => (left + tableX).roundToDouble();

    final _RowBand? band = _band;
    // The band is a run of whole cells, so it stops on column boundaries — the
    // very ones the grid uses, which is what keeps the border *on* the grid
    // instead of half a pixel beside it.
    final double bl = band == null ? left : edgeAt(math.max(0, band.left));
    final double br = band == null
        ? right
        : edgeAt(math.min(_tableWidth, band.right));
    final double radius = math.min(_kSelectRadius, math.max(0, (br - bl) / 2));
    // Which corners the shape actually *turns* at: only where the row above (or
    // below) does not carry the same edge on. A stack of equal bands is
    // therefore one rounded rectangle, while a band that begins halfway down
    // the table still closes itself off; a step between two rows closes the
    // outward corner and leaves the inward one square, which is what makes the
    // steps read as one shape instead of a pile of boxes.
    final bool roundTL =
        band != null && (_above == null || _above!.left > band.left + 0.5);
    final bool roundTR =
        band != null && (_above == null || _above!.right < band.right - 0.5);
    final bool roundBL =
        band != null && (_below == null || _below!.left > band.left + 0.5);
    final bool roundBR =
        band != null && (_below == null || _below!.right < band.right - 0.5);

    // The selection wash: **one opaque band per row, snapped to whole cells**,
    // rounded only where the shape turns. Stacked, those bands are one
    // continuous shape — that is the whole point.
    //
    // **Dark**, not the 27%-accent selection colour the prose uses: a table is a
    // dense grid of glyphs, and a light band behind all of them washed the text
    // out — user: 「表格的颜色改深一点点，不然看不清晰」. Obsidian's selected
    // table is a near-black purple — measured #272231 against a #1C1C1C page —
    // and a 1px edge, not the fill, is what marks the selection.
    //
    // Opaque, not `selection` itself: the paragraph paints its own
    // text-highlight over the skeleton runs underneath, and blending the two
    // double-purples every glyph box.
    final Color wash = Color.alphaBlend(
      _palette.selectionEdge.withValues(alpha: _header ? 0.18 : 0.11),
      _palette.surface,
    );
    if (band != null) {
      // …which is also why the row's *unselected* share has to be repainted in
      // paper first. That paragraph highlight is a full-column stripe: with the
      // wash covering only a few cells, the stripe would still show next to
      // them and the row would look selected end to end — the exact complaint
      // this band exists to answer.
      final Paint paper = Paint()..color = _palette.surface;
      if (bl > left) {
        canvas.drawRect(Rect.fromLTRB(left, top, bl, bottom), paper);
      }
      if (br < right) {
        canvas.drawRect(Rect.fromLTRB(br, top, right, bottom), paper);
      }
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(bl, top, br, bottom),
          topLeft: roundTL ? Radius.circular(radius) : Radius.zero,
          topRight: roundTR ? Radius.circular(radius) : Radius.zero,
          bottomLeft: roundBL ? Radius.circular(radius) : Radius.zero,
          bottomRight: roundBR ? Radius.circular(radius) : Radius.zero,
        ),
        Paint()..color = wash,
      );
    }

    // What the pointer is proposing to do, if it is dragging a grip: the row or
    // column it would land on, painted as a light accent wash so the drop is
    // not a guess.
    //
    // Under the chips, the grid and the band outline on purpose. Pressing a
    // grip also selects its row/column, and the drop target starts out on that
    // very row — painted last, this wash would cover the selection's edge and
    // the press would look like a plain highlight instead of a selection.
    final TableDragPreview? preview = tableDragPreview.value;
    if (preview != null && preview.tableId == _tableId) {
      final Paint hot = Paint()
        ..color = Color.alphaBlend(
          _palette.accent.withValues(alpha: 0.18),
          _palette.surface,
        );
      if (preview.column) {
        // The destination is a contiguous run: paint the run as one wash with
        // an accent rule down each end, so a block drag reads as a block.
        final int last = math.min(
          _cells.length - 1,
          preview.index + preview.count - 1,
        );
        for (int c = preview.index; c <= last; c++) {
          final Rect cell = _cellRect(c);
          if (cell.width > 0) {
            canvas.drawRect(
              Rect.fromLTWH(left + cell.left, top, cell.width, height),
              hot,
            );
            if (c == preview.index) {
              canvas.drawRect(
                Rect.fromLTWH(left + cell.left, top, 2, height),
                Paint()..color = _palette.accent,
              );
            }
          }
        }
      } else if (_rowIndex >= preview.index &&
          _rowIndex < preview.index + preview.count) {
        canvas.drawRect(Rect.fromLTWH(left, top, _tableWidth, height), hot);
        if (_rowIndex == preview.index) {
          canvas.drawRect(
            Rect.fromLTWH(left, top, _tableWidth, 2),
            Paint()..color = _palette.accent,
          );
        }
      }
    }

    // Inline code's padded, rounded band. A cell is a `TextPainter`, so it
    // cannot carry the prose chip's widget caps; the row paints the band
    // itself, behind the glyphs. It goes down **before** the grid so the rules
    // stay on top — a 26px band on a 28px row otherwise shaves the header's
    // bottom border (「代码挡住了表格的边框」).
    final double chipRadius = _textScaler.scale(_kInlineCodeRadius);
    final Paint chipPaint = Paint();
    for (int i = 0; i < _cells.length && i < _painters.length; i++) {
      if (i >= _chips.length || _chips[i].isEmpty) continue;
      final TextPainter tp = _painters[i];
      final Offset origin = Offset(
        left + _cells[i].dx,
        offset.dy + (height - tp.height) / 2,
      );
      for (final _PaintedChip chip in _chips[i]) {
        chipPaint.color = chip.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            chip.rect.shift(origin),
            Radius.circular(chipRadius),
          ),
          chipPaint,
        );
      }
    }

    // The grid: a rule along the top of every row (plus the bottom of the header
    // and of the last row), and a rule at every column boundary.
    //
    // Inside the wash the rules stay — a table should still read as a table —
    // but in a colour lifted towards the accent, so they sit *in* the band
    // instead of cutting it into rectangles. They are drawn twice rather than
    // split into segments: once in the paper colour across the whole row, then
    // again in the lifted colour with a clip to the band. A rule that runs out
    // of the band therefore changes colour exactly at its edge, and the ones
    // the outline covers (the band's own two sides) are stroked over anyway.
    final Paint line = Paint()..color = _palette.outlineSoft;
    final Paint strong = Paint()
      ..color = band == null ? _palette.outline : _palette.outlineSoft;
    final Set<double> edges = <double>{0, _tableWidth};
    for (final _PaintCell cell in _cells) {
      edges
        ..add(cell.cell.x)
        ..add(cell.cell.x + cell.cell.width);
    }
    void grid(Paint paint) {
      canvas.drawRect(Rect.fromLTWH(left, top, _tableWidth, 1), paint);
      for (final double x in edges) {
        canvas.drawRect(Rect.fromLTWH(edgeAt(x), top, 1, height), paint);
      }
    }

    grid(line);
    if (_header || _last) {
      // The header's and the block's closing line are the two strong rules in
      // the grid; `grid` draws one paint only, so it goes down separately.
      canvas.drawRect(Rect.fromLTWH(left, bottom - 1, _tableWidth, 1), strong);
    }
    if (band != null) {
      final RRect shape = RRect.fromRectAndCorners(
        Rect.fromLTRB(bl, top, br, bottom),
        topLeft: roundTL ? Radius.circular(radius) : Radius.zero,
        topRight: roundTR ? Radius.circular(radius) : Radius.zero,
        bottomLeft: roundBL ? Radius.circular(radius) : Radius.zero,
        bottomRight: roundBR ? Radius.circular(radius) : Radius.zero,
      );
      // Lifted off the grid colour rather than off the wash: the rules inside
      // the block stay *rules* (measured #3C3746 on Obsidian's #272231 fill),
      // not accent-bright bars that cut the block into cells.
      final Paint lifted = Paint()
        ..color = Color.alphaBlend(
          _palette.selectionEdge.withValues(alpha: 0.2),
          _palette.outline,
        );
      canvas.save();
      canvas.clipRRect(shape);
      grid(lifted);
      if (_header || _last) {
        canvas.drawRect(
          Rect.fromLTWH(left, bottom - 1, _tableWidth, 1),
          lifted,
        );
      }
      canvas.restore();
      _paintBandOutline(canvas, left, bl, br, top, bottom);
    }

    // The text, last, so the glyphs sit on top of fill and grid alike.
    for (int i = 0; i < _cells.length && i < _painters.length; i++) {
      final _PaintCell cell = _cells[i];
      final TextPainter tp = _painters[i];
      tp.paint(
        canvas,
        Offset(left + cell.dx, offset.dy + (height - tp.height) / 2),
      );
    }

    // …and the chrome over everything, so a washed row cannot paint out its
    // own grips.
    _paintChrome(canvas, left, top);
  }

  /// The grips and the two `+` buttons — **hover-only**, and bare glyphs.
  ///
  /// The style is Obsidian's own edge controls, which is what the user pointed
  /// at: six thin dots and a thin `+` floating in the margin with **nothing**
  /// behind them. So no plate, no ring, no chip — the icon *is* the button.
  ///
  /// Three states, and only three:
  ///  * out of reach  — not painted at all (a table is a page, not a toolbar);
  ///  * at the edge   — the tertiary ink, so the control whispers "here";
  ///  * on the glyph, or the drop target of a drag — the accent, which is the
  ///    whole "you are holding it" feedback.
  void _paintChrome(Canvas canvas, double left, double top) {
    // ⛔ Two different origins, and mixing them up silently draws nothing:
    // the glyphs are drawn at `(left, top)` — paragraph coordinates plus the
    // sub-pixel nudge — while the *hit testing* has to run against
    // [localToGlobal], because a pointer event arrives in global coordinates.
    // Both describe the same point; only their frames of reference differ.
    final Offset painted = Offset(left, top);
    for (final (TableChromeKind kind, Rect local, int index) in _controls()) {
      final bool grabbed = _dragging(kind, index);
      if (!grabbed && !_hovering(local)) continue;
      final bool on = grabbed || _pointing(local);
      final Color color = on ? _palette.accent : _palette.textTertiary;
      final double weight = on ? 1.6 : 1.2;
      final Rect r = local.shift(painted);
      switch (kind) {
        case TableChromeKind.rowHandle:
        case TableChromeKind.columnHandle:
          _paintGrip(canvas, r, color: color);
        case TableChromeKind.addRow:
        case TableChromeKind.addColumn:
          _paintPlus(canvas, r, color: color, weight: weight);
      }
    }
  }

  /// The six dots that say "drag me": two columns of three, the grip everyone
  /// already knows from reorderable lists. A grab *hand* belongs to the cursor
  /// alone — here the dots stay upright for both axes, so a row and a column
  /// read as the same kind of control.
  ///
  /// Repainted from the Material icon font rather than stroked by hand: the
  /// chrome is painted by a render object, and an [Icon] would need a widget —
  /// which would swallow the taps the skeleton owns.
  void _paintGrip(Canvas canvas, Rect r, {required Color color}) {
    final IconData icon = Icons.drag_indicator;
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: _kGrip,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      // The editor's own text scale belongs to the note, not to the chrome;
      // a grip has to stay the same size at any zoom.
      textScaler: TextScaler.noScaling,
    )..layout();
    tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  void _paintPlus(
    Canvas canvas,
    Rect r, {
    required Color color,
    required double weight,
  }) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = weight
      ..strokeCap = StrokeCap.round;
    final double arm = r.width / 2 - weight / 2;
    canvas.drawLine(
      Offset(r.center.dx - arm, r.center.dy),
      Offset(r.center.dx + arm, r.center.dy),
      stroke,
    );
    canvas.drawLine(
      Offset(r.center.dx, r.center.dy - arm),
      Offset(r.center.dx, r.center.dy + arm),
      stroke,
    );
  }

  /// Strokes the block's outline, one row at a time.
  ///
  /// A row owns only the segments that face out of the shape: its two vertical
  /// sides, and the parts of its top and bottom edge that the neighbouring band
  /// does not continue. Nothing is drawn twice and nothing is rounded twice, so
  /// a stack of rows paints exactly one outline — even when the stack steps in
  /// and out as the selection covers a different run of cells.
  ///
  /// ⛔ Every coordinate below is a **stroke centre on a half pixel**, and the
  /// sides and the ends all come off the same two edges ([l]/[r] for a row's
  /// sides, [t]/[b] for its ends). A side and an end therefore share their
  /// corner pixel exactly. Mixing snapped and unsnapped edges — which is what
  /// this did, `bl` for the sides against `bl + 0.5` for the ends — put the
  /// corners half a pixel apart, and the outline came out with four gaps the
  /// width of the stroke: user: 「四周怎么没有闭合？？」.
  void _paintBandOutline(
    Canvas canvas,
    double left,
    double bl,
    double br,
    double top,
    double bottom,
  ) {
    final _RowBand band = _band!;
    // `bl`/`br`/`top`/`bottom` are whole numbers, so a 1px stroke centred on
    // `n + 0.5` covers exactly the pixel row `n .. n+1`: the border lands on
    // the grid rule it replaces instead of straddling it into a grey smear.
    final double l = bl + 0.5;
    final double r = br - 0.5;
    final double t = top + 0.5;
    final double b = bottom - 0.5;
    if (r - l <= 0 || b - t <= 0) return;

    final bool roundTL = _above == null || _above!.left > band.left + 0.5;
    final bool roundTR = _above == null || _above!.right < band.right - 0.5;
    final bool roundBL = _below == null || _below!.left > band.left + 0.5;
    final bool roundBR = _below == null || _below!.right < band.right - 0.5;

    final double rr = math.max(
      0,
      math.min(_kSelectRadius, math.min((r - l) / 2, (b - t) / 2)),
    );
    final double tl = roundTL ? rr : 0;
    final double tr = roundTR ? rr : 0;
    final double blr = roundBL ? rr : 0;
    final double brr = roundBR ? rr : 0;

    /// A step edge, snapped the same way the grid snaps it, then moved to the
    /// stroke's centre. The band's own two sides use [l]/[r] rather than this,
    /// because there the stroke sits *inside* the wash and not on its edge.
    double xAt(double tableX) => (left + tableX).roundToDouble() + 0.5;

    final Path path = Path()
      // The two sides, already shortened by whatever corner radii their ends
      // have — so an end and a side meet at the very same point.
      ..moveTo(l, t + tl)
      ..lineTo(l, b - blr)
      ..moveTo(r, t + tr)
      ..lineTo(r, b - brr);
    for (final (double a, double c) in _exposed(band, _above)) {
      _horizontal(
        path,
        a <= band.left + 0.5 ? l : xAt(a),
        c >= band.right - 0.5 ? r : xAt(c),
        t,
        top: true,
        roundLeft: a <= band.left + 0.5 && roundTL,
        roundRight: c >= band.right - 0.5 && roundTR,
        radius: rr,
      );
    }
    for (final (double a, double c) in _exposed(band, _below)) {
      _horizontal(
        path,
        a <= band.left + 0.5 ? l : xAt(a),
        c >= band.right - 0.5 ? r : xAt(c),
        b,
        top: false,
        roundLeft: a <= band.left + 0.5 && roundBL,
        roundRight: c >= band.right - 0.5 && roundBR,
        radius: rr,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _palette.selectionEdge,
    );
  }

  /// The parts of [band]'s width that [other] does not also cover — i.e. the
  /// bits of this row's top (or bottom) edge that are on the shape's boundary.
  static List<(double, double)> _exposed(_RowBand band, _RowBand? other) {
    if (other == null) return <(double, double)>[(band.left, band.right)];
    final List<(double, double)> out = <(double, double)>[];
    if (other.left > band.left + 0.5) {
      out.add((band.left, math.min(band.right, other.left)));
    }
    if (other.right < band.right - 0.5) {
      out.add((math.max(band.left, other.right), band.right));
    }
    return out;
  }

  /// One horizontal edge of the outline, with a rounded turn at either end
  /// where the shape actually turns.
  ///
  /// A quadratic with the corner point as its control: at a two-pixel radius it
  /// is indistinguishable from a circular arc, and — unlike [Path.arcToPoint]
  /// with its `clockwise` flag — it cannot be built backwards. A backwards arc
  /// ends up on the far side of the edge, which is the other way to leave the
  /// corners open.
  static void _horizontal(
    Path path,
    double x0,
    double x1,
    double y, {
    required bool top,
    required bool roundLeft,
    required bool roundRight,
    required double radius,
  }) {
    if (x1 - x0 < 0.5) return;
    final double lr = roundLeft ? math.min(radius, (x1 - x0) / 2) : 0;
    final double rr = roundRight ? math.min(radius, (x1 - x0) / 2) : 0;
    // The corner turns **into** the row: down from a top edge, up from a
    // bottom one.
    final double into = top ? 1 : -1;
    if (lr > 0) {
      path
        ..moveTo(x0, y + into * lr)
        ..quadraticBezierTo(x0, y, x0 + lr, y);
    } else {
      path.moveTo(x0, y);
    }
    path.lineTo(x1 - rr, y);
    if (rr > 0) {
      path.quadraticBezierTo(x1, y, x1, y + into * rr);
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
    required this.end,
    required this.header,
    required this.cells,
  });

  final int line;
  final int start;

  /// One past the row's last source character (the line break excluded). The
  /// selection uses it to decide whether this row is part of the washed block.
  final int end;
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
    required this.spans,
    required this.codeRuns,
    required this.natural,
    required this.width,
    required this.align,
  });

  final _ParsedCell cell;
  final TextStyle style;

  /// Inline code tokens, in [cell] text coordinates.
  final List<_CellCode> codeRuns;

  /// The cell's painted tree — the same runs the row renderer draws and the
  /// skeleton lays out invisibly. Any tracking correction is already in it, so
  /// the two can never disagree about where a character sits.
  final List<InlineSpan> spans;

  /// Width the text wants, one line, no wrapping.
  final double natural;

  /// Width the column's *text area* got after the whole table was fitted.
  final double width;

  /// Column alignment, from the divider row.
  final TextAlign align;

  /// Letter spacing that squeezes [spans] into [width]. Zero unless the
  /// column had to shrink.
  double letterSpacing = 0;

  /// The cell box's left edge and full width (padding included), in the
  /// table's own coordinates. Filled by [_measureTable].
  double x = 0;
  double boxWidth = 0;

  /// How wide the painted text actually comes out: [natural], or exactly the
  /// text area when the column had to squeeze it.
  double get advance => math.min(natural, width);

  /// Where the painted text starts inside the box, honouring [align]. The
  /// skeleton is placed from this number, which is what keeps a click in a
  /// centred or right-aligned cell on the character under the pointer.
  double get textX => switch (align) {
    TextAlign.center => x + (boxWidth - advance) / 2,
    TextAlign.end => x + boxWidth - _kCellPad - advance,
    _ => x + _kCellPad,
  };
}

class _Table {
  _Table({
    required this.rows,
    required this.width,
    required this.rowHeight,
    required this.dyShift,
    required this.lineOfRow,
    required this.geometry,
  });

  final List<_RowData> rows;
  final double width;
  final double rowHeight;

  /// How far the painted rows sit **above** their paragraph line, and therefore
  /// how far down they have to be nudged to land on it.
  ///
  /// A row is a `PlaceholderAlignment.middle` box, which Flutter centres on the
  /// text's own mid-line — so a 28px box on a 28px line still hangs a couple of
  /// pixels over the top. Harmless while the row was all there was to see; not
  /// harmless now that the selection paints a band around it, because the
  /// paragraph's own highlight would peek out below the band's bottom edge.
  final double dyShift;

  /// Source line → index into [rows] (the divider line maps to nothing).
  final Map<int, int> lineOfRow;
  final TableGeometry geometry;

  List<_CellData> cellsOf(int line) => rows[lineOfRow[line]!].data;
}

const double _kCellPad = 8;

/// The chrome a live table hangs around itself: a grip per row and per column,
/// and a `+` on the right and bottom edges.
///
/// The grip is a square: it holds six dots, which read the same whether the row
/// moves up and down or the column moves left and right.
const double _kGrip = 16;

/// The gap between the table's border and the chrome that hangs off it.
const double _kChromeGap = 5;
const double _kAdd = 12;

/// Corner radius of the selection wash around a table block. Small on purpose:
/// a table is a rectangle, and the rounding should read as a softened corner,
/// not as a pill.
const double _kSelectRadius = 2;

/// The narrowest a column may be squeezed to before the table starts sharing
/// space strictly by content. Without it an empty table — the one the
/// 「插入 ▸ 表格」 snippet writes — has a natural width of zero and collapses to
/// a 32px speck.
const double _kMinCell = 64;

/// Splits `| a | b |` into its cells, keeping each cell's absolute offset.
///
/// The ranges come from [tableCellsOf] — the same parser Tab uses to walk the
/// table, so the two can never disagree about where a cell begins. The text is
/// the **painted** form, not the raw source: the escapes are rendered rather
/// than shown (`\|` is a pipe, `<br>` is a break mark).
List<_ParsedCell> _parseCells(String line, int absStart) => <_ParsedCell>[
  for (final (int a, int b) in tableCellsOf(line))
    _ParsedCell(tableCellDisplay(line.substring(a, b)), absStart + a),
];

/// A character that takes no room, used to keep an escape's source slots alive
/// without painting the punctuation.
const String _kZeroWidth = '\u200b';

/// The raw source of one cell as it is **painted**.
///
/// `\|` is a literal pipe — the backslash becomes zero-width, the pipe is drawn
/// as text — and `<br>` is a visible break mark (「↵」) whose three trailing
/// letters become zero-width. The model unescapes both on the way in, so this
/// is the only place the source spelling and the painted spelling differ.
///
/// ⛔ The result is always the **same UTF-16 length** as [raw]. The row
/// skeleton, the cell geometry and the selection bands all map painted
/// characters back to source offsets by counting them; a shorter string would
/// slide every character after the first escape — the caret would land one
/// slot off, then two.
@visibleForTesting
String tableCellDisplay(String raw) {
  if (!raw.contains(r'\|') && !raw.contains('<br>')) return raw;
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < raw.length; i++) {
    if (raw.startsWith(r'\|', i)) {
      out.write(_kZeroWidth);
      continue;
    }
    if (raw.startsWith('<br>', i)) {
      out.write('↵$_kZeroWidth$_kZeroWidth$_kZeroWidth');
      i += 3;
      continue;
    }
    out.write(raw[i]);
  }
  return out.toString();
}

/// Natural width of a cell: its *painted* span tree, measured on one line.
///
/// The tree, not the raw source — measuring `**加粗**` would hand the column two
/// asterisks' worth of width that nobody can see, and every click in the cell
/// would land on a hidden character instead of the one under the pointer.
double _measureSpans(
  List<InlineSpan> spans,
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
) {
  if (spans.isEmpty) return 0;
  final TextPainter tp = TextPainter(
    text: TextSpan(style: style, children: spans),
    textDirection: direction,
    textScaler: scaler,
  );
  tp.layout(maxWidth: double.infinity);
  final double w = tp.width;
  tp.dispose();
  return w;
}

/// Copies a span tree with every run re-styled.
///
/// Only [TextSpan] leaves carry text, and in a cell there is nothing else: the
/// plain context (`_Ctx.plain`) turns every chip — tag, wikilink, link, image —
/// into styled text, precisely so a cell can be measured and repainted by a
/// render object.
List<InlineSpan> _restyle(
  List<InlineSpan> spans,
  TextStyle Function(TextStyle) f,
) => <InlineSpan>[
  for (final InlineSpan s in spans)
    if (s is TextSpan)
      TextSpan(
        text: s.text,
        style: s.style == null ? null : f(s.style!),
        children: s.children == null ? null : _restyle(s.children!, f),
      )
    else
      s,
];

/// The tree with [extra] tracking added on top of each run's own — the width
/// correction a squeezed column needs.
///
/// Added, not assigned: a run inside a cell may already carry tracking, and
/// replacing it would make the painted text disagree with the measured width.
List<InlineSpan> _spaced(List<InlineSpan> spans, double extra) => extra == 0
    ? spans
    : _restyle(
        spans,
        (TextStyle s) =>
            s.copyWith(letterSpacing: (s.letterSpacing ?? 0) + extra),
      );

/// The same, but the cell's **first character** keeps its natural advance.
///
/// Skia applies half of a text run's tracking *before* its first glyph. On the
/// first run of a paragraph line that half pulls the whole line back, so a
/// squeezed first cell moved its row — the row widget, the skeleton under it,
/// every column rule — up to several pixels left of the rest of the table
/// (`ls = -5.18` shifted the header by 2.6px, measured). A run that starts on
/// the second character is not the line's first: its tracking only bites the
/// glyphs behind it, and the row origin never moves.
///
/// The caller divides the correction over the characters that actually receive
/// it, so the cell still comes out exactly as wide as its column.
List<InlineSpan> _squeeze(
  List<InlineSpan> spans,
  double extra,
  TextStyle base,
) {
  if (extra == 0 || spans.isEmpty) return spans;
  final InlineSpan first = spans.first;
  if (first is! TextSpan || first.text == null || first.text!.isEmpty) {
    return _spaced(spans, extra);
  }
  final String text = first.text!;
  final int cut = text.characters.first.length;
  final TextStyle firstStyle = first.style ?? base;
  final TextStyle restStyle = firstStyle.copyWith(
    letterSpacing: (firstStyle.letterSpacing ?? 0) + extra,
  );
  final List<InlineSpan> rest = <InlineSpan>[
    if (text.length > cut) TextSpan(text: text.substring(cut), style: restStyle),
    if (first.children != null)
      TextSpan(
        style: restStyle,
        children: _restyle(
          first.children!,
          (TextStyle s) =>
              s.copyWith(letterSpacing: (s.letterSpacing ?? 0) + extra),
        ),
      ),
  ];
  return <InlineSpan>[
    TextSpan(text: text.substring(0, cut), style: first.style),
    ...rest,
    ..._spaced(spans.skip(1).toList(), extra),
  ];
}

/// The same tree, invisible. This is what the paragraph lays out underneath a
/// painted row, so its advances place the caret exactly where the glyphs are.
/// The same tree, painted with nothing visible.
///
/// ⛔ A transparent **colour** is not enough. The skeleton shares the paragraph's
/// line with the row that actually paints it, and any *box* the style draws —
/// the inline-code band, the `==高亮==` background, an underline — is still
/// painted at the paragraph's own metrics. Those boxes are a full line tall
/// (28px), while the row's cells are painted at the font's height (~20px), so
/// one `` `code` `` in a cell bled down over the table's bottom border and over
/// the caret: 「md 的代码挡住了输入光标，也挡住了表格的边框」.
///
/// Nothing here affects layout — only what is drawn — so dropping the background
/// and the decoration leaves the advances, the glyph boxes and the caret mapping
/// exactly as they were.
List<InlineSpan> _transparent(List<InlineSpan> spans) => _restyle(
  spans,
  (TextStyle s) => s.copyWith(
    color: Colors.transparent,
    backgroundColor: Colors.transparent,
    decoration: TextDecoration.none,
    decorationColor: Colors.transparent,
  ),
);

/// Column alignment, read off the divider row (`:---`, `:-:`, `---:`).
///
/// Obsidian honours these, and a column of numbers that refuses to line up on
/// the right is the single most common reason to write them, so the renderer
/// has to as well — including in the skeleton, or a click in a right-aligned
/// cell would land somewhere else entirely.
TextAlign _alignOf(String divider, int column) {
  final List<_ParsedCell> cells = _parseCells(divider, 0);
  if (column >= cells.length) return TextAlign.start;
  final String cell = cells[column].text.trim();
  final bool left = cell.startsWith(':');
  final bool right = cell.endsWith(':');
  if (left && right) return TextAlign.center;
  if (right) return TextAlign.end;
  return TextAlign.start;
}

/// How far a `PlaceholderAlignment.middle` box of [box] height sits above the
/// line it shares with [style]'s text. Positive means "push it back down".
///
/// Flutter centres such a box on the text's mid-line, `(ascent - descent) / 2`
/// above the baseline, while the line's top is a full ascent up. So the box's
/// top lands at `(ascent + descent - box) / 2` relative to the line's top —
/// negative, i.e. above it, whenever the box is shorter than the text's own
/// line box.
double _middleOverhang(
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
  double box,
) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: ' ', style: style),
    textDirection: direction,
    textScaler: scaler,
  )..layout();
  final LineMetrics m = tp.computeLineMetrics().first;
  tp.dispose();
  return (box - (m.ascent + m.descent)) / 2;
}

/// Measures a whole table block.
///
/// Two rules decide the geometry:
///
/// * a table is **as wide as its content** and starts on the text column's left
///   edge, the way Obsidian's does — columns get their widest cell plus padding,
///   and the table stops there. It only shrinks (proportionally, every column at
///   once) when the content is wider than the column itself;
/// * every cell is measured from its **painted** tree, so the columns, the
///   painted glyphs and the invisible skeleton all agree on where each character
///   is.
_Table _measureTable({
  required List<String> lines,
  required List<int> starts,
  required int first,
  required int last,
  required int divider,
  required TextStyle base,
  required _Ctx ctx,
  required int editAt,
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
        end: at + lines[i].length,
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

  // Pass one: build each cell's tree and measure it. The tree is kept — it is
  // exactly what the row renderer paints and what the skeleton redraws
  // invisibly, so the three of them cannot drift apart.
  //
  // The cell under the caret gets **two** trees: the rendered one decides the
  // column widths (so entering a cell never reflows the table under the
  // pointer), and the source-revealed one is what is painted and laid out
  // underneath it. Any squeeze the revealed text needs is baked into both.
  final List<List<List<InlineSpan>>> trees = <List<List<InlineSpan>>>[];
  final List<List<List<_CellCode>>> codes = <List<List<_CellCode>>>[];
  final List<List<double>> measured = <List<double>>[];
  final List<List<double>> painted = <List<double>>[];
  final List<double> natural = List<double>.filled(cols, 0);
  for (final _RowData r in rows) {
    final TextStyle style = r.header ? headStyle : bodyStyle;
    final List<List<InlineSpan>> rowTrees = <List<InlineSpan>>[];
    final List<List<_CellCode>> rowCodes = <List<_CellCode>>[];
    final List<double> rowWidths = <double>[];
    final List<double> rowPainted = <double>[];
    for (int c = 0; c < r.cells.length; c++) {
      final int from = r.cells[c].offset;
      final int to = from + r.cells[c].text.length;
      final bool editing = editAt >= from && editAt <= to;
      final List<_CellCode> codeRuns = <_CellCode>[];
      final List<InlineSpan> rendered = _inline(
        r.cells[c].text,
        style,
        from,
        ctx,
        // A revealed cell paints no chip, so it has no chip runs to report.
        codeRuns: editing ? null : codeRuns,
      );
      final double w = _measureSpans(rendered, style, ctx.textScaler, direction);
      final List<InlineSpan> paintSpans = editing
          ? _inline(r.cells[c].text, style, from, _cellEditCtx(ctx, from, to))
          : rendered;
      rowTrees.add(paintSpans);
      rowCodes.add(editing ? const <_CellCode>[] : codeRuns);
      rowWidths.add(w);
      rowPainted.add(
        editing
            ? _measureSpans(paintSpans, style, ctx.textScaler, direction)
            : w,
      );
      natural[c] = math.max(natural[c], w);
    }
    trees.add(rowTrees);
    codes.add(rowCodes);
    measured.add(rowWidths);
    painted.add(rowPainted);
  }

  // Pass two: hand out the columns.
  //
  // The table is **as wide as its content**, the way Obsidian's is: each column
  // gets its widest cell plus the cell padding, and the whole thing stops there
  // instead of stretching to the text column's right edge. A short table that
  // fills six hundred pixels of paper reads as a diagram, not as a table.
  //
  // `_kMinCell` is the floor — it is what keeps `|  |  |` (the empty table
  // `insertTable` writes) a usable grid instead of a 32px speck, and what stops
  // a one-letter column from being a sliver.
  //
  // When the natural widths exceed the column, the **minimum is served first**
  // and only the demand above it is squeezed proportionally: a table with one
  // long paragraph column and four short ones used to shrink all five by the
  // same percentage, which turned labels into unreadable slivers while the
  // paragraph was still wide. Proportional-from-the-floor keeps every short
  // column whole and takes the space out of the column that can spare it.
  // Only when even the floors do not fit does everything shrink linearly.
  //
  // The 1px from `contentWidth` is not cosmetic: a line break fires on a strict
  // `> contentWidth`, so a table landing exactly on the last pixel makes
  // rounding decide whether the row wraps — and a wrapped row is twice as tall
  // as its cells.
  final double available = math.max(60, ctx.contentWidth - 1);
  final List<double> wanted = <double>[
    for (int c = 0; c < cols; c++) math.max(natural[c], _kMinCell),
  ];
  final double fit = math.max(1, available - cols * 2 * _kCellPad);
  final double span = wanted.fold<double>(0, (double a, double w) => a + w);
  final double floor = cols * _kMinCell;
  final List<double> widths;
  if (span <= fit) {
    widths = wanted;
  } else if (floor <= fit) {
    final double extra = span - floor;
    final double room = fit - floor;
    widths = <double>[
      for (final double w in wanted)
        _kMinCell + (extra <= 0 ? 0 : (w - _kMinCell) * room / extra),
    ];
  } else {
    widths = <double>[for (final double w in wanted) w * fit / span];
  }

  // Pass three: bake each cell's tracking correction into its tree and record
  // where the box ended up.
  for (int ri = 0; ri < rows.length; ri++) {
    final _RowData r = rows[ri];
    final TextStyle style = r.header ? headStyle : bodyStyle;
    for (int c = 0; c < r.cells.length; c++) {
      final _ParsedCell parsed = r.cells[c];
      final List<InlineSpan> spans = trees[ri][c];
      // A revealed cell is wider than its rendered form; squeeze it back into
      // the column it was measured for, exactly like a long cell. The column
      // itself keeps the width it had before the cell opened.
      //
      // The squeeze skips the cell's first character (see [_squeeze]) so it
      // cannot move the row's line origin, and is spread over the characters
      // that do carry it, so the cell still measures exactly `widths[c]`.
      final double nat = painted[ri][c];
      final int len = parsed.text.length;
      final int head = parsed.text.isEmpty
          ? 0
          : parsed.text.characters.first.length;
      final int tracked = len - head;
      // Negative only: a squeezed column has to shrink its text, while a
      // stretched one simply keeps the extra room *after* the text.
      final double ls = len > 0 && nat > widths[c]
          ? (widths[c] - nat) / (tracked > 0 ? tracked : len)
          : 0;
      r.data.add(
        _CellData(
          cell: parsed,
          style: style,
          spans: tracked > 0 ? _squeeze(spans, ls, style) : _spaced(spans, ls),
          codeRuns: codes[ri][c],
          natural: nat,
          width: widths[c],
          align: divider >= 0 ? _alignOf(lines[divider], c) : TextAlign.start,
        )..letterSpacing = ls,
      );
    }
  }

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
    dyShift: _middleOverhang(base, ctx.textScaler, direction, rowHeight),
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
    1 => (1.62, 1.3, -0.5),
    2 => (1.36, 1.34, -0.4),
    3 => (1.18, 1.4, -0.25),
    4 => (1.07, 1.45, -0.1),
    5 => (0.99, 1.5, 0),
    _ => (0.93, 1.5, 0.1),
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

/// Horizontal padding inside an inline code chip, carried by the two backticks.
const double _kInlineCodePad = 4;

/// Corner radius of a code chip's rounded ends. Small on purpose — at this
/// height anything rounder turns a one-character span into a pill.
const double _kInlineCodeRadius = 3;

TextStyle _inlineCode(TextStyle base, AppPalette p, [Color? fill]) =>
    _inlineCodeSource(base, p).copyWith(
      backgroundColor: fill ?? p.surfaceSunken,
    );

/// The code run while it is being edited: same face and size as the chip, but
/// no fill — the backticks and the plain background are what say "source".
TextStyle _inlineCodeSource(TextStyle base, AppPalette p) {
  final double s = (base.fontSize ?? 15) * 0.92;
  return base.copyWith(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: s,
    // A line that is *only* inline code still owes the paragraph a whole-pixel
    // advance, or it shows the same seam as body text.
    height: snapLineHeight(s, base.height ?? 1.78),
    color: p.textPrimary,
  );
}

/// `surfaceSunken` with the selection wash mixed in, for a chip the live
/// selection covers while the reveal is frozen.
Color _selectedChip(AppPalette p) =>
    Color.alphaBlend(p.selection, p.surfaceSunken);

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
    base.copyWith(color: p.accent);

TextStyle _wikiText(TextStyle base, AppPalette p) => base.copyWith(
  color: p.accent,
  decoration: TextDecoration.underline,
  decorationStyle: TextDecorationStyle.dotted,
  decorationColor: p.accent.withValues(alpha: 0.45),
);

TextStyle _linkText(TextStyle base, AppPalette p) => base.copyWith(
  color: p.accent,
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
TextStyle _invisible(TextStyle base) =>
    base.copyWith(color: Colors.transparent);

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
    Padding(padding: const EdgeInsets.only(left: 2, right: 9), child: dot),
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
      width: 2,
      height: _lineHeightOf(base),
      color: p.accent.withValues(alpha: 0.55),
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
            border: Border.all(color: done ? p.accent : p.outline, width: 1.5),
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
              color: p.accent,
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
          color: p.accent,
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
            Text(label, style: TextStyle(fontSize: 12, color: p.textSecondary)),
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
      color: p.accent,
      decoration: TextDecoration.underline,
      decorationColor: p.accent.withValues(alpha: 0.35),
    ),
  ),
);

WidgetSpan _imageSpan(AppPalette p, String url, String alt, double maxWidth) =>
    _decoration(
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

/// One rounded end of an inline code chip, standing in for a backtick.
///
/// A [TextStyle.backgroundColor] can only paint a rectangle flush with the
/// glyphs, so the padding and the rounded corners are carried by the two
/// characters the syntax already has: each backtick collapses into a fixed-width
/// box that paints its half of the chip. The run between them keeps a plain
/// background; together the three pieces read as one continuous chip, and no
/// source character is lost — the caret still steps through the backticks.
///
/// The box is measured from [probe] under the same [style] as the run, and it
/// is placed by **baseline**, not by the line's middle. That is what keeps the
/// cap and the run's own background on the same two horizontal edges when the
/// paragraph font and the mono font have different ascent ratios.
class _InlineCodeEnd extends LeafRenderObjectWidget {
  const _InlineCodeEnd({
    required this.width,
    required this.radius,
    required this.color,
    required this.roundStart,
    required this.probe,
    required this.style,
    required this.textDirection,
    required this.textScaler,
  });

  final double width;
  final double radius;
  final Color color;

  /// Whether the rounded corners are on the visual start side — left in LTR,
  /// right in RTL. The other side stays square and bleeds into the code run.
  final bool roundStart;

  /// The code itself: measuring the real content keeps a fallback glyph (CJK
  /// in a code span, say) from changing the run's metrics behind the cap's back.
  final String probe;
  final TextStyle style;
  final TextDirection textDirection;
  final TextScaler textScaler;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderInlineCodeEnd(
    width,
    radius,
    color,
    roundStart,
    probe,
    style,
    textDirection,
    textScaler,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderInlineCodeEnd renderObject,
  ) {
    renderObject
      ..width = width
      ..radius = radius
      ..color = color
      ..roundStart = roundStart
      ..setMetrics(probe, style, textDirection, textScaler);
  }
}

class _RenderInlineCodeEnd extends RenderBox {
  _RenderInlineCodeEnd(
    this._width,
    this._radius,
    this._color,
    this._roundStart,
    String probe,
    TextStyle style,
    TextDirection textDirection,
    TextScaler textScaler,
  ) : _metrics = _measure(probe, style, textDirection, textScaler);

  /// The line the cap must be as tall as, and the baseline it hangs from.
  static TextPainter _measure(
    String probe,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
  ) => TextPainter(
    text: TextSpan(text: probe.isEmpty ? ' ' : probe, style: style),
    textDirection: direction,
    textScaler: scaler,
  )..layout();

  TextPainter _metrics;

  double _width;
  double get width => _width;
  set width(double value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  double _radius;
  double get radius => _radius;
  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  Color _color;
  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  bool _roundStart;
  bool get roundStart => _roundStart;
  set roundStart(bool value) {
    if (value == _roundStart) return;
    _roundStart = value;
    markNeedsPaint();
  }

  void setMetrics(
    String probe,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final TextPainter next = _measure(probe, style, direction, scaler);
    if (next.height == _metrics.height &&
        next.computeDistanceToActualBaseline(TextBaseline.alphabetic) ==
            _metrics.computeDistanceToActualBaseline(TextBaseline.alphabetic)) {
      next.dispose();
      return;
    }
    _metrics.dispose();
    _metrics = next;
    markNeedsLayout();
  }

  Size _size() => Size(_width, _metrics.height);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _metrics.computeDistanceToActualBaseline(baseline);

  @override
  void performLayout() {
    size = constraints.constrain(_size());
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_size());

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_width <= 0 || size.height <= 0 || _color.a == 0) return;
    // Bleed one pixel towards the run: cap and run paint two abutting
    // rectangles, and antialiasing each edge separately leaves a hairline
    // seam between them at fractional device-pixel ratios. Both sides are the
    // same colour, so the overlap is invisible.
    final Rect band = Rect.fromLTWH(
      offset.dx + (_roundStart ? 0 : -1),
      offset.dy,
      _width + 1,
      size.height,
    );
    final Radius corner = Radius.circular(_radius);
    final RRect shape = _roundStart
        ? RRect.fromRectAndCorners(
            band,
            topLeft: corner,
            bottomLeft: corner,
          )
        : RRect.fromRectAndCorners(
            band,
            topRight: corner,
            bottomRight: corner,
          );
    context.canvas.drawRRect(shape, Paint()..color = _color);
  }

  @override
  void dispose() {
    _metrics.dispose();
    super.dispose();
  }

  /// ⛔ Never take part in hit testing — a click on the chip's padding has to
  /// place the caret, exactly like a click on the backtick it replaced.
  @override
  bool hitTestSelf(Offset position) => false;
}

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
/// The vertical rails down the left of a nested list row.
///
/// One rail per ancestor level, each at that level's marker centre, and exactly
/// one row tall — so consecutive rows butt up against each other and the rails
/// read as one continuous line down a branch rather than a dashed one. The box
/// is as wide as the whole indent ([levels] × [_kIndentStep]) because it *is*
/// the indent: the first leading space of the source stands in for it.
class MarkdownIndentGuides extends LeafRenderObjectWidget {
  const MarkdownIndentGuides({
    super.key,
    required this.levels,
    required this.color,
    required this.rowHeight,
  });

  final int levels;
  final Color color;
  final double rowHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderIndentGuides(levels, color, rowHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderIndentGuides renderObject,
  ) {
    renderObject
      ..levels = levels
      ..color = color
      ..rowHeight = rowHeight;
  }
}

/// [MarkdownIndentGuides]'s render object: `levels × step` wide, rails in
/// `paint`.
class RenderIndentGuides extends RenderBox {
  RenderIndentGuides(this._levels, this._color, this._rowHeight);

  int _levels;
  int get levels => _levels;
  set levels(int value) {
    if (value == _levels) return;
    _levels = value;
    markNeedsLayout();
  }

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

  Size _size() => Size(_levels * _kIndentStep, _rowHeight);

  @override
  void performLayout() {
    size = constraints.constrain(_size());
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_size());

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_levels <= 0 || _rowHeight <= 0) return;
    final Paint paint = Paint()..color = _color;
    for (int i = 0; i < _levels; i++) {
      // Half-pixel back so a 1px rail lands on the pixel grid instead of being
      // antialiased across two of them.
      final double x = offset.dx + i * _kIndentStep + _kMarkerCentre - 0.5;
      context.canvas.drawRect(
        Rect.fromLTWH(x, offset.dy, 1, size.height),
        paint,
      );
    }
  }

  /// ⛔ Never take part in hit testing — a click on the rail has to place the
  /// caret, exactly like a click on the indent's whitespace did.
  @override
  bool hitTestSelf(Offset position) => false;
}

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
