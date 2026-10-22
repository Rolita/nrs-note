part of '../live_markdown.dart';

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

