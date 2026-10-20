part of '../live_markdown.dart';

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
    // The break belongs to the line it closes, and a fenced block's rows are
    // shorter than prose. Leaving the newline at the body style made every code
    // row step by the body's line height (28px) instead of the code's (20px) —
    // the compact block the reference shows was impossible.
    TextStyle? breakStyle;

    switch (kinds[i]) {
      case _Kind.fence:
        final int fenceId = fences[i];
        final _Fence? block = _blockAt(blocks, fenceId);
        final bool revealed = on || revealedFences.contains(fenceId);
        if (revealed) {
          out.add(
            TextSpan(
              text: line,
              style: _markerVisible(base, p, accented: true),
            ),
          );
          break;
        }
        // The fence line is folded away. The slab behind the whole block is
        // painted by `CodeBlockPainter` — a `TextStyle` background can only hug
        // a run, which is what turned every line into a stripe of its own
        // width. The opening fence only reserves the card's header row; the
        // closing one collapses to nothing and leaves the bottom air to the
        // slab. The language label is painted with the slab, in the top-right
        // corner, so it does not push the code down a whole line.
        final bool opens = block != null && block.open == i;
        out.add(
          _codeFenceSpacer(
            ctx.contentWidth,
            opens ? _kCodeHeaderHeight : 0,
          ),
        );
        out.add(_swallowed(line, base));
        breakStyle = _collapsed(base);

      case _Kind.code:
        final _Fence? block = _blockAt(blocks, fences[i]);
        final int index = block == null ? -1 : i - block.open - 1;
        final List<List<CodeToken>>? all = block?.tokens;
        final List<CodeToken>? tokens =
            (all != null && index >= 0 && index < all.length)
            ? all[index]
            : null;
        final TextStyle style = _codeLine(base, p);
        breakStyle = style;
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
        out.add(_bulletDot(p));
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
          out.add(_quoteBar(p, base, marker, ctx.textScaler));
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
          _decoration(MarkdownDividerLine(color: p.rule, height: row)),
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
            : TextSpan(text: '\n', style: breakStyle ?? base),
      );
    }
  }

  _unhideLastGlyph(out, base);
  return out;
}
