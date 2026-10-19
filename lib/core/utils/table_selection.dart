/// What a table selection **is**: a rectangle of cells, not the characters
/// between two pipes.
///
/// The renderer has always painted a table selection by the cell — the wash
/// snaps out to whole cells even when the pointer stopped in the middle of one.
/// Copy, cut, delete, paste, TSV and the statistics all have to read the same
/// rectangle, or the thing that disappears is not the thing that was lit:
///
/// * reading a selection as a linear text range deleted from the middle of
///   「链接」 to the last row and left the first two characters behind;
/// * ending the range at the *next* row's first character (a caret is exclusive
///   at its end) copied one row more than the wash showed;
/// * cutting a partial rectangle removed the pipes between the cells, and what
///   came back was a run of loose text instead of a table.
///
/// This file is that one reading. The model edits themselves still live in
/// `table_model.dart`; this one decides **which cells** they act on.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart' show TextSelection;

import 'table_model.dart';

/// The shape a selection takes when it is applied.
enum TableRangeKind {
  /// A block of cells: delete clears their contents, the table keeps its shape.
  cells,

  /// One or more whole rows — picking a row by its grip, or sweeping every
  /// column. Delete removes the rows themselves.
  rows,

  /// One or more whole columns. Delete removes the columns themselves.
  columns,
}

/// One rectangle of cells in one table, with the cell the user started from.
///
/// [anchorRow]/[anchorColumn] is the **active cell** — where typing and pasting
/// land, the way a spreadsheet keeps the cell the range was started from. The
/// four bounds are always derived, so a range dragged upwards is the same
/// rectangle as one dragged downwards.
class TableRange {
  TableRange({
    required this.block,
    required this.anchorRow,
    required this.anchorColumn,
    required this.focusRow,
    required this.focusColumn,
    this.kind = TableRangeKind.cells,
    this.forward = true,
  });

  /// The table the range belongs to.
  final TableBlock block;

  /// The active cell: typing replaces this one and clears the rest.
  final int anchorRow;
  final int anchorColumn;

  /// The far corner.
  final int focusRow;
  final int focusColumn;

  final TableRangeKind kind;

  /// Whether the gesture ran forward in the source. Kept so the snapped
  /// selection can be rebuilt with the same base and extent, which is what
  /// keeps Shift+click and keyboard selection extensions pointing the same way.
  final bool forward;

  int get firstRow => math.min(anchorRow, focusRow);
  int get lastRow => math.max(anchorRow, focusRow);
  int get firstColumn => math.min(anchorColumn, focusColumn);
  int get lastColumn => math.max(anchorColumn, focusColumn);

  int get rowCount => lastRow - firstRow + 1;
  int get columnCount => lastColumn - firstColumn + 1;
  int get cellCount => rowCount * columnCount;

  bool get isRows => kind == TableRangeKind.rows;
  bool get isColumns => kind == TableRangeKind.columns;

  /// A range that is only different from an ordinary text selection when it
  /// covers more than one cell.
  bool get isSingleCell => rowCount == 1 && columnCount == 1;

  List<TableRow> get _body => block.bodyRows;

  /// Whether [row] is a body-row index the table actually has.
  bool hasRow(int row) => row >= 0 && row < _body.length;

  bool hasColumn(int column) => column >= 0 && column < block.columns;

  /// The cell at absolute body-row [row], column [column], or `null` where the
  /// table's rows are ragged (a short row has no cell there; [textAt] reads it
  /// as empty, which is what the grid edit will write into).
  TableCell? cellAt(int row, int column) {
    if (!hasRow(row) || column < 0) return null;
    final List<TableCell> cells = _body[row].cells;
    return column < cells.length ? cells[column] : null;
  }

  String textAt(int row, int column) => cellAt(row, column)?.text ?? '';

  /// The selected cells, row-major. Short rows contribute empty strings, so
  /// every row of the result has exactly [columnCount] cells.
  List<List<String>> get values => <List<String>>[
    for (int r = firstRow; r <= lastRow; r++)
      <String>[for (int c = firstColumn; c <= lastColumn; c++) textAt(r, c)],
  ];

  /// The selected cells as a Markdown table.
  ///
  /// The first selected row becomes the header and a divider is emitted: a
  /// table is only a table when its second line is one. The selected columns'
  /// alignments travel with it.
  String get markdown {
    final List<TableAlign> aligns = block.aligns;
    return TableGrid(
      rows: values,
      aligns: <TableAlign>[
        for (int c = firstColumn; c <= lastColumn; c++)
          c < aligns.length ? aligns[c] : TableAlign.none,
      ],
      header: true,
    ).render();
  }

  /// The selected cells as tab-separated text — what a spreadsheet understands.
  /// Tabs and line breaks inside a cell become spaces, because they are the
  /// separators here.
  String get tsv => values
      .map(
        (List<String> row) => row
            .map(
              (String cell) => cell.replaceAll('\t', ' ').replaceAll('\n', ' '),
            )
            .join('\t'),
      )
      .join('\n');

  /// Numbers and counts over the selected cells.
  TableStats get stats {
    int filled = 0;
    int numbers = 0;
    double sum = 0;
    double low = double.infinity;
    double high = double.negativeInfinity;
    for (final List<String> row in values) {
      for (final String text in row) {
        if (text.trim().isEmpty) continue;
        filled++;
        final double? n = numberInCell(text);
        if (n == null) continue;
        numbers++;
        sum += n;
        low = math.min(low, n);
        high = math.max(high, n);
      }
    }
    return TableStats(
      cells: cellCount,
      filled: filled,
      numbers: numbers,
      sum: numbers == 0 ? null : sum,
      min: numbers == 0 ? null : low,
      max: numbers == 0 ? null : high,
    );
  }

  /// The source selection that paints this rectangle.
  ///
  /// Cell rectangles select from the first cell's text to the last cell's text;
  /// a whole-row range takes the newline after the last row as well, because
  /// that is what makes the rows disappear instead of turning into `|  |  |`.
  /// The wash reads the same endpoints, so what is selected is what was seen.
  TextSelection toTextSelection() {
    final List<TableRow> body = _body;
    if (body.isEmpty) return TextSelection.collapsed(offset: block.start);
    final TableRow first = body[firstRow.clamp(0, body.length - 1)];
    final TableRow last = body[lastRow.clamp(0, body.length - 1)];
    final int start;
    final int end;
    switch (kind) {
      case TableRangeKind.rows:
        start = first.start;
        end = last.end < block.text.length ? last.end + 1 : last.end;
      case TableRangeKind.cells:
      case TableRangeKind.columns:
        final TableCell? a = cellAt(firstRow, firstColumn);
        final TableCell? b = cellAt(lastRow, lastColumn);
        start = a == null
            ? first.start
            : (a.isEmpty ? a.start : a.contentStart);
        end = b == null ? last.end : (b.isEmpty ? b.end : b.contentEnd);
    }
    return forward
        ? TextSelection(baseOffset: start, extentOffset: end)
        : TextSelection(baseOffset: end, extentOffset: start);
  }

  /// Reads the rectangle a source selection paints, or `null` when it is an
  /// ordinary text selection.
  ///
  /// The end is **exclusive**: the last character the user selected is at
  /// `selection.end - 1`. Using `selection.end` itself treated a drag that
  /// stopped exactly at the next row's line start as also selecting that row's
  /// first cell — one row of wash/copy disagreement, and a cut that took a row
  /// the user never saw lit.
  ///
  /// A selection that starts in prose is prose; one that runs past the block's
  /// own final newline is prose too. A selection inside a single cell stays an
  /// ordinary text selection, because selecting two words of a sentence must
  /// copy those two words, not the cell.
  static TableRange? fromSelection(String text, TextSelection selection) {
    if (!selection.isValid || selection.isCollapsed) return null;
    final TableBlock? block = TableBlock.parse(text, selection.start);
    if (block == null) return null;
    if (selection.end > block.end + 1) return null;
    if (block.bodyRows.isEmpty) return null;
    // The divider holds no cells, so an endpoint parked on it names no
    // rectangle. Mapping it through [tableCellAt] reads as the rows on either
    // side of the dashes — a divider-only selection used to delete the whole
    // table.
    if (_onDivider(block, selection.start) ||
        _onDivider(block, selection.end - 1)) {
      return null;
    }

    final (int r0, int c0) = tableCellAt(block, selection.start, extent: false);
    final (int r1, int c1) = tableCellAt(
      block,
      selection.end - 1,
      extent: true,
    );
    if (r0 == r1 && c0 == c1) return null;

    final bool forward = selection.baseOffset <= selection.extentOffset;
    final int firstColumn = math.min(c0, c1);
    final int lastColumn = math.max(c0, c1);
    // Sweeping every column is a row selection, not a block of cells: Delete
    // removes the rows, and the wash already reads as one full row.
    final TableRangeKind kind =
        firstColumn == 0 && lastColumn == block.columns - 1
        ? TableRangeKind.rows
        : TableRangeKind.cells;
    return TableRange(
      block: block,
      anchorRow: forward ? r0 : r1,
      anchorColumn: forward ? c0 : c1,
      focusRow: forward ? r1 : r0,
      focusColumn: forward ? c1 : c0,
      kind: kind,
      forward: forward,
    );
  }

  /// A cell rectangle with explicit bounds — the shape a command hands back
  /// after it cleared the cells and wants the rectangle to stay lit.
  static TableRange rect(
    TableBlock block, {
    required int fromRow,
    required int toRow,
    required int fromColumn,
    required int toColumn,
    int? activeRow,
    int? activeColumn,
  }) {
    final List<TableRow> body = block.bodyRows;
    final int maxRow = math.max(0, body.length - 1);
    final int maxColumn = math.max(0, block.columns - 1);
    final int r0 = fromRow.clamp(0, maxRow);
    final int r1 = toRow.clamp(r0, maxRow);
    final int c0 = fromColumn.clamp(0, maxColumn);
    final int c1 = toColumn.clamp(c0, maxColumn);
    return TableRange(
      block: block,
      anchorRow: (activeRow ?? r0).clamp(r0, r1),
      anchorColumn: (activeColumn ?? c0).clamp(c0, c1),
      focusRow: r1,
      focusColumn: c1,
    );
  }

  /// Whole rows [from]…[to], the shape a row grip produces.
  static TableRange rowsOf(TableBlock block, int from, int to) {
    final List<TableRow> body = block.bodyRows;
    final int maxRow = math.max(0, body.length - 1);
    final int r0 = from.clamp(0, maxRow);
    final int r1 = to.clamp(r0, maxRow);
    return TableRange(
      block: block,
      anchorRow: r0,
      anchorColumn: 0,
      focusRow: r1,
      focusColumn: math.max(0, block.columns - 1),
      kind: TableRangeKind.rows,
    );
  }

  /// Whole columns [from]…[to], the shape a column grip produces.
  static TableRange columnsOf(TableBlock block, int from, int to) {
    final List<TableRow> body = block.bodyRows;
    final int maxColumn = math.max(0, block.columns - 1);
    return TableRange(
      block: block,
      anchorRow: 0,
      anchorColumn: from.clamp(0, maxColumn),
      focusRow: math.max(0, body.length - 1),
      focusColumn: to.clamp(0, maxColumn),
      kind: TableRangeKind.columns,
    );
  }
}

/// What the selected numbers add up to.
///
/// Computed over the cells the wash covers, in the order a person reads them:
/// every non-empty cell counts as filled, every cell that [numberInCell] can
/// read counts as a number. A selection with no numbers still reports its
/// filled cells, because "3 项" is useful on its own.
class TableStats {
  const TableStats({
    required this.cells,
    required this.filled,
    required this.numbers,
    required this.sum,
    required this.min,
    required this.max,
  });

  final int cells;
  final int filled;
  final int numbers;
  final double? sum;
  final double? min;
  final double? max;

  bool get hasNumbers => numbers > 0;

  double? get average => numbers == 0 ? null : sum! / numbers;
}

/// The cell an offset belongs to, as `(body row, column)`.
///
/// [extent] decides where an offset that sits **between** rows — the newline
/// that ends a row, or the hidden divider — belongs: a selection's start reads
/// into the row below (the caret is at the start of that row's text), while its
/// end belongs to the row above (the last character selected is the one before
/// the break). This is the same rule the renderer uses to paint the wash, which
/// is the point: copy and delete have to agree with the pixels.
bool _onDivider(TableBlock block, int offset) => block.rows.any(
  (TableRow r) => r.divider && offset >= r.start && offset <= r.end,
);

(int, int) tableCellAt(TableBlock block, int offset, {required bool extent}) {
  final List<TableRow> rows = block.bodyRows;
  if (rows.isEmpty) return (0, 0);
  for (int r = 0; r < rows.length; r++) {
    final TableRow row = rows[r];
    if (offset < row.start) {
      if (!extent || r == 0) return (r, 0);
      return (r - 1, math.max(0, rows[r - 1].cells.length - 1));
    }
    if (offset >= row.end || row.cells.isEmpty) continue;
    for (int c = 0; c < row.cells.length; c++) {
      if (offset < row.cells[c].end) return (r, c);
    }
    return (r, row.cells.length - 1);
  }
  final int last = rows.length - 1;
  return (last, math.max(0, rows[last].cells.length - 1));
}
