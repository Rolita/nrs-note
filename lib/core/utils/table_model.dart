/// The table model: **parse a Markdown table into a grid, change the grid,
/// render the grid back**.
///
/// Every table edit in the app goes through this file. The previous
/// implementation edited tables by splicing string ranges: compute a delta for
/// every row, remap the caret by hand, and hope the divider row keeps up. Every
/// bug in the feature came from that — a caret that drifted one character, a row
/// that lost its trailing pipe, a divider that disagreed with its own header, a
/// delete that left the first cell behind. A grid has no offsets to drift.
///
/// The rules of the model:
///
/// * a **block** is a run of consecutive lines that each start with `|`, and it
///   is the unit of editing — a structural edit re-renders the whole block, so
///   the rows can never end up different widths;
/// * the **divider** (`| --- | :-: |`) is not a row. It is the thing that makes
///   the first row a header, and it is regenerated from the column alignments;
/// * a cell's text is **unescaped** in the grid (`\|` → `|`, `<br>` → newline)
///   and escaped again on the way out, so a pipe inside a cell is just text;
/// * the rendered form is the canonical one — `| a | b |` — because the editor
///   is what-would-be-seen-is-what-you-get and nobody reads the pipes.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart' show TextSelection;

/// How a column lines its text up. Read from the divider, written back to it.
enum TableAlign { none, left, center, right }

/// What a summary row does with a column's numbers.
enum TableAggregate { count, sum, average, min, max }

extension TableAggregateLabel on TableAggregate {
  /// The word the summary row carries in its label cell.
  String get label => switch (this) {
    TableAggregate.count => '计数',
    TableAggregate.sum => '合计',
    TableAggregate.average => '平均',
    TableAggregate.min => '最小',
    TableAggregate.max => '最大',
  };
}

/// The number a cell holds, or `null` when it is not numeric.
///
/// Thousands separators and a leading currency sign are ignored, so
/// `¥1,299` sorts and sums with `1299`. A trailing `%` is dropped rather than
/// divided by a hundred: the number a person sees in the cell is the number
/// they expect to see in the total.
double? numberInCell(String text) {
  String s = text.trim();
  if (s.isEmpty) return null;
  s = s.replaceAll(RegExp(r'[\s,，]'), '');
  s = s.replaceFirst(RegExp(r'^[¥$€£]'), '');
  if (s.endsWith('%')) s = s.substring(0, s.length - 1);
  return double.tryParse(s);
}

/// [v] as a cell-sized number: no floating noise, no trailing `.0`.
String formatNumber(double v) {
  if (!v.isFinite) return '';
  if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
  return v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// Text order for a column: numeric when both sides are numbers, otherwise
/// case-insensitive text, with the raw text as the final tiebreak.
int _compareCellText(String a, String b) {
  final double? x = numberInCell(a);
  final double? y = numberInCell(b);
  if (x != null && y != null) {
    final int byNumber = x.compareTo(y);
    if (byNumber != 0) return byNumber;
  }
  final int byText = a.trim().toLowerCase().compareTo(b.trim().toLowerCase());
  return byText != 0 ? byText : a.compareTo(b);
}

/// The divider cell for [align].
String alignSpec(TableAlign align) => switch (align) {
  TableAlign.none => '---',
  TableAlign.left => ':---',
  TableAlign.center => ':---:',
  TableAlign.right => '---:',
};

/// The alignment a divider cell asks for.
TableAlign alignOf(String spec) {
  final String s = spec.trim();
  final bool left = s.startsWith(':');
  final bool right = s.endsWith(':');
  if (left && right) return TableAlign.center;
  if (left) return TableAlign.left;
  if (right) return TableAlign.right;
  return TableAlign.none;
}

/// A `\|` inside a cell is text, not a separator. Every scanner in the app —
/// this one and the renderer's — has to agree, or a cell would be cut in two.
int _nextPipe(String line, int from) {
  int i = line.indexOf('|', from);
  while (i > 0 && line[i - 1] == r'\') {
    i = line.indexOf('|', i + 1);
  }
  return i;
}

/// The cells of a table line, as line-relative `[start, end)` ranges. The text
/// between the pipes, padding included.
List<(int, int)> cellsOfLine(String line) {
  final List<(int, int)> cells = <(int, int)>[];
  final int first = _nextPipe(line, 0);
  if (first < 0) return cells;
  int pipe = first;
  while (true) {
    final int next = _nextPipe(line, pipe + 1);
    final int from = pipe + 1;
    if (next < 0) {
      if (from < line.length) cells.add((from, line.length));
      break;
    }
    cells.add((from, next));
    pipe = next;
  }
  return cells;
}

/// `| --- | :-: |` — the row that turns the row above it into a header.
bool isDividerLine(String line) =>
    line.contains('-') && _dividerRe.hasMatch(line);

final RegExp _dividerRe = RegExp(r'^[\s|:\-]+$');

/// Whether [line] belongs to a table at all.
bool isRowLine(String line) => line.trimLeft().startsWith('|');

/// `|` and newlines cannot appear in a cell: one would end the cell, the other
/// the row. GFM's escape is a backslash for the pipe and `<br>` for the break.
String escapeCell(String text) =>
    text.replaceAll(r'\|', '|').replaceAll('|', r'\|').replaceAll('\n', '<br>');

/// The inverse of [escapeCell], applied when a block is parsed.
String unescapeCell(String text) =>
    text.replaceAll(r'\|', '|').replaceAll('<br>', '\n');

/// One cell of a parsed row: the **raw** range (padding included) and the text.
class TableCell {
  const TableCell({required this.start, required this.end, required this.raw});

  final int start;
  final int end;
  final String raw;

  /// The cell's markdown, padding and escapes removed.
  String get text => unescapeCell(raw.trim());

  /// Where the cell's own text begins — past the padding the source uses to
  /// line the columns up. An empty cell starts and ends at the same place.
  int get contentStart {
    int i = 0;
    while (i < raw.length && (raw[i] == ' ' || raw[i] == '\t')) {
      i++;
    }
    return start + i;
  }

  int get contentEnd {
    int i = raw.length;
    while (i > 0 && (raw[i - 1] == ' ' || raw[i - 1] == '\t')) {
      i--;
    }
    return math.max(start + i, contentStart);
  }

  bool get isEmpty => text.isEmpty;
}

/// One line of a block. The divider is a row too — it just holds no cells the
/// user can edit.
class TableRow {
  const TableRow({
    required this.start,
    required this.end,
    required this.cells,
    required this.divider,
  });

  final int start;
  final int end;
  final List<TableCell> cells;
  final bool divider;
}

/// A parsed table block, tied to the document it came from.
class TableBlock {
  const TableBlock({
    required this.text,
    required this.start,
    required this.end,
    required this.rows,
  });

  /// The whole document.
  final String text;

  /// First character of the block's first line.
  final int start;

  /// Last character of the block's last line, newline excluded.
  final int end;

  /// Every line, divider included.
  final List<TableRow> rows;

  /// The divider's index in [rows], or `-1` when the block has no header.
  int get dividerIndex => rows.indexWhere((TableRow r) => r.divider);

  /// Whether the first row is a header.
  bool get hasHeader => dividerIndex >= 0;

  /// The rows a user sees: everything but the divider.
  List<TableRow> get bodyRows => <TableRow>[
    for (final TableRow r in rows)
      if (!r.divider) r,
  ];

  /// The widest row wins: a short row is padded by the model, never by hand.
  int get columns =>
      rows.fold<int>(0, (int m, TableRow r) => math.max(m, r.cells.length));

  /// Column alignments, read off the divider row.
  List<TableAlign> get aligns {
    final int d = dividerIndex;
    if (d < 0) return List<TableAlign>.filled(columns, TableAlign.none);
    final List<TableCell> cells = rows[d].cells;
    return <TableAlign>[
      for (int c = 0; c < columns; c++)
        c < cells.length ? alignOf(cells[c].text) : TableAlign.none,
    ];
  }

  /// The row index (in [bodyRows]) that [offset] sits on, or `-1`.
  int rowAt(int offset) {
    final List<TableRow> body = bodyRows;
    for (int i = 0; i < body.length; i++) {
      if (offset <= body[i].end) return i;
    }
    return body.isEmpty ? -1 : body.length - 1;
  }

  /// The column [offset] sits in, on [row].
  int columnAt(int row, int offset) {
    final List<TableRow> body = bodyRows;
    if (row < 0 || row >= body.length) return 0;
    final List<TableCell> cells = body[row].cells;
    for (int c = 0; c < cells.length; c++) {
      if (offset <= cells[c].end) return c;
    }
    return math.max(0, cells.length - 1);
  }

  /// Parses the block that contains [offset]. `null` outside a table, and
  /// inside a fenced code block, where pipes are just code.
  static TableBlock? parse(String text, int offset) {
    if (offset < 0 || offset > text.length) return null;
    if (_insideFence(text, offset)) return null;
    final int here = _lineStartOf(text, offset);
    if (!isRowLine(_line(text, here))) return null;

    int start = here;
    while (start > 0) {
      final int prev = _lineStartOf(text, start - 1);
      if (!isRowLine(_line(text, prev))) break;
      start = prev;
    }
    int end = _lineEndOf(text, here);
    while (end < text.length) {
      final int next = end + 1;
      if (!isRowLine(_line(text, next))) break;
      end = _lineEndOf(text, next);
    }

    final List<TableRow> rows = <TableRow>[];
    int cursor = start;
    while (cursor <= end) {
      final int stop = _lineEndOf(text, cursor);
      final String line = text.substring(cursor, stop);
      rows.add(
        TableRow(
          start: cursor,
          end: stop,
          divider: isDividerLine(line),
          cells: <TableCell>[
            for (final (int a, int b) in cellsOfLine(line))
              TableCell(
                start: cursor + a,
                end: cursor + b,
                raw: line.substring(a, b),
              ),
          ],
        ),
      );
      if (stop >= end) break;
      cursor = stop + 1;
    }
    if (rows.isEmpty) return null;
    return TableBlock(text: text, start: start, end: end, rows: rows);
  }

  /// Every table in [text], in document order.
  ///
  /// The fenced-code state is tracked here instead of calling [parse] per line:
  /// a note with a dozen tables would otherwise re-scan the whole document for
  /// each one, and this runs while the table tools are listing a file's tables.
  static List<TableBlock> allIn(String text) {
    final List<TableBlock> out = <TableBlock>[];
    if (text.isEmpty) return out;
    int lineStart = 0;
    bool fenced = false;
    while (lineStart <= text.length) {
      final int lineEnd = _lineEndOf(text, lineStart);
      final String line = text.substring(lineStart, lineEnd);
      if (RegExp(r'^\s{0,3}```').hasMatch(line)) {
        fenced = !fenced;
      } else if (!fenced && isRowLine(line)) {
        final TableBlock? block = parse(text, lineStart);
        // `block.start == lineStart` keeps a table from being listed once per
        // line: only the row that opens it produces the block.
        if (block != null && block.start == lineStart) {
          out.add(block);
          lineStart = block.end + 1;
          continue;
        }
      }
      if (lineEnd >= text.length) break;
      lineStart = lineEnd + 1;
    }
    return out;
  }
}

String _line(String text, int start) =>
    text.substring(start, _lineEndOf(text, start));

/// First character of the line that contains [offset]. A caret parked on a
/// newline belongs to the line that newline ends.
int _lineStartOf(String text, int offset) {
  if (offset <= 0) return 0;
  final int at = offset > text.length ? text.length : offset;
  final int i = text.lastIndexOf('\n', at - 1);
  return i < 0 ? 0 : i + 1;
}

/// The newline that ends the line containing [offset], or the text's end.
int _lineEndOf(String text, int offset) {
  final int i = text.indexOf('\n', offset.clamp(0, text.length));
  return i < 0 ? text.length : i;
}

/// Whether [offset] sits inside a fenced code block.
bool _insideFence(String text, int offset) {
  int fences = 0;
  int index = 0;
  for (final String line in text.split('\n')) {
    if (RegExp(r'^\s{0,3}```').hasMatch(line)) fences++;
    final int lineEnd = index + line.length;
    if (offset >= index && offset <= lineEnd) break;
    index = lineEnd + 1;
  }
  return fences.isOdd;
}

/// The editable form of a block: plain strings, no offsets.
///
/// Structural edits change this and nothing else; [render] turns it back into
/// Markdown. That is what makes "every row the same width" a property of the
/// model instead of something each command has to remember.
class TableGrid {
  TableGrid({required this.rows, required this.aligns, required this.header});

  factory TableGrid.fromBlock(TableBlock block) {
    final int cols = block.columns;
    return TableGrid(
      rows: <List<String>>[
        for (final TableRow r in block.bodyRows)
          <String>[
            for (int c = 0; c < cols; c++)
              c < r.cells.length ? r.cells[c].text : '',
          ],
      ],
      // A copy, and growable: on a table without a divider `block.aligns` is a
      // fixed-length filler, and the column commands insert/remove entries.
      aligns: List<TableAlign>.of(block.aligns),
      header: block.hasHeader,
    );
  }

  /// Content rows, header first. A row is always [columns] wide.
  final List<List<String>> rows;

  /// One alignment per column.
  final List<TableAlign> aligns;

  /// Whether [rows] starts with a header row (and therefore needs a divider).
  ///
  /// Mutable because alignment is written **into the divider**: a table that
  /// arrived without one has to grow one before an alignment can survive
  /// [render] — otherwise the row looks applied but the Markdown never changes.
  bool header;

  int get columns => rows.isEmpty ? aligns.length : rows.first.length;

  /// One empty row of the right width.
  List<String> emptyRow() => List<String>.filled(columns, '');

  /// The canonical Markdown for this grid.
  String render() {
    if (rows.isEmpty) return '';
    final int cols = columns;
    final List<String> lines = <String>[];
    for (int i = 0; i < rows.length; i++) {
      final List<String> cells = <String>[
        for (int c = 0; c < cols; c++)
          escapeCell(c < rows[i].length ? rows[i][c] : ''),
      ];
      lines.add('| ${cells.join(' | ')} |');
      if (i == 0 && header) {
        final List<String> specs = <String>[
          for (int c = 0; c < cols; c++)
            alignSpec(c < aligns.length ? aligns[c] : TableAlign.none),
        ];
        lines.add('| ${specs.join(' | ')} |');
      }
    }
    return lines.join('\n');
  }
}

/// What a table command hands back: the new document and where the caret goes.
class TableEditResult {
  const TableEditResult(this.text, this.selection);

  final String text;
  final TextSelection selection;
}

/// The commands. Every one of them is "parse → change the grid → render", so
/// none of them can leave the block in a half-edited state.
class TableCommands {
  /// Renders [grid] into [block]'s place and puts the caret in `(row, column)`.
  static TableEditResult _commit(
    TableBlock block,
    TableGrid grid, {
    int? row,
    int? column,
    bool selectCell = false,
    bool caretAtEnd = false,
  }) {
    final String table = grid.render();
    final String next = block.text.replaceRange(block.start, block.end, table);
    if (row == null) {
      return TableEditResult(
        next,
        TextSelection.collapsed(offset: block.start.clamp(0, next.length)),
      );
    }
    // Re-parse instead of computing offsets: the grid is the truth, and one
    // extra parse is cheaper than a bug.
    final TableBlock fresh =
        TableBlock.parse(next, (block.start + 1).clamp(0, next.length)) ??
        block;
    final List<TableRow> body = fresh.bodyRows;
    if (body.isEmpty) {
      return TableEditResult(
        next,
        TextSelection.collapsed(offset: block.start),
      );
    }
    final TableRow r = body[row.clamp(0, body.length - 1)];
    if (r.cells.isEmpty) {
      return TableEditResult(next, TextSelection.collapsed(offset: r.start));
    }
    final TableCell cell = r.cells[(column ?? 0).clamp(0, r.cells.length - 1)];
    return TableEditResult(
      next,
      // An empty cell is selected whole: the first keystroke replaces the
      // placeholder instead of landing beside it, exactly like Tab and Enter.
      selectCell || cell.isEmpty
          ? TextSelection(baseOffset: cell.start, extentOffset: cell.end)
          // `caretAtEnd` is for writes: after typing over a selection the caret
          // belongs after the text that was just written, not before it.
          : TextSelection.collapsed(
              offset: caretAtEnd ? cell.contentEnd : cell.contentStart,
            ),
    );
  }

  /// One more row. [above] puts it on top of [row] — which, for the header,
  /// means the new row *becomes* the header, exactly like dragging one up.
  static TableEditResult insertRow(
    TableBlock block, {
    required int row,
    required bool above,
    int column = 0,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int at = (above ? row : row + 1).clamp(0, grid.rows.length);
    grid.rows.insert(at, grid.emptyRow());
    return _commit(block, grid, row: at, column: column);
  }

  /// Removes one row. The last row takes the whole table with it — a table with
  /// no rows is not a table, it is a divider with nothing above it.
  static TableEditResult deleteRow(TableBlock block, int row) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.length <= 1) return deleteTable(block);
    final int at = row.clamp(0, grid.rows.length - 1);
    grid.rows.removeAt(at);
    return _commit(
      block,
      grid,
      row: at.clamp(0, grid.rows.length - 1),
      column: 0,
    );
  }

  /// Removes rows [from]…[to] inclusive — what a whole-row selection deletes.
  static TableEditResult deleteRows(TableBlock block, int from, int to) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int a = from.clamp(0, grid.rows.length - 1);
    final int b = to.clamp(a, grid.rows.length - 1);
    if (a == 0 && b == grid.rows.length - 1) return deleteTable(block);
    grid.rows.removeRange(a, b + 1);
    return _commit(
      block,
      grid,
      row: a.clamp(0, grid.rows.length - 1),
      column: 0,
    );
  }

  /// Inserts [count] empty rows at [at] — the block-wide half of what a
  /// multi-row selection inserts.
  static TableEditResult insertRowsAt(
    TableBlock block, {
    required int at,
    required int count,
    int column = 0,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int index = at.clamp(0, grid.rows.length);
    for (int i = 0; i < math.max(1, count); i++) {
      grid.rows.insert(index, grid.emptyRow());
    }
    return _commit(block, grid, row: index, column: column);
  }

  /// Inserts [count] empty columns at [at], alignment row included.
  static TableEditResult insertColumnsAt(
    TableBlock block, {
    required int at,
    required int count,
    required int row,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int index = at.clamp(0, grid.columns);
    for (int i = 0; i < math.max(1, count); i++) {
      for (final List<String> r in grid.rows) {
        r.insert(index.clamp(0, r.length), '');
      }
      grid.aligns.insert(index.clamp(0, grid.aligns.length), TableAlign.none);
    }
    return _commit(block, grid, row: row, column: index);
  }

  /// Clears the cells of a rectangle, keeping the rows. Used when the selection
  /// covers only some of the columns: deleting those rows outright would take
  /// the cells the user did not select with them.
  static TableEditResult clearRect(
    TableBlock block, {
    required int fromRow,
    required int toRow,
    required int fromColumn,
    required int toColumn,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int r0 = fromRow.clamp(0, grid.rows.length - 1);
    final int r1 = toRow.clamp(r0, grid.rows.length - 1);
    for (int r = r0; r <= r1; r++) {
      for (int c = fromColumn; c <= toColumn; c++) {
        if (c >= 0 && c < grid.rows[r].length) grid.rows[r][c] = '';
      }
    }
    return _commit(block, grid, row: r0, column: fromColumn);
  }

  /// Writes [values] at the active cell and clears the rest of the selection.
  ///
  /// This is what a keystroke or a paste over a rectangle means: the active
  /// cell (the corner the selection was started from) receives the text, the
  /// other selected cells go empty, and the table **keeps its shape**. The grid
  /// grows only when the values do not fit — a paste of ten rows into a
  /// two-row table appends eight, it does not drop eight.
  ///
  /// The caret comes back after the last cell written, past the text, rather
  /// than at the active cell's start: typing `abc` over a range should leave
  /// the caret after `abc`.
  static TableEditResult writeRect(
    TableBlock block, {
    required int fromRow,
    required int toRow,
    required int fromColumn,
    required int toColumn,
    required int atRow,
    required int atColumn,
    required List<List<String>> values,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int valueWidth = values.fold<int>(
      0,
      (int m, List<String> r) => math.max(m, r.length),
    );
    final int rowsNeeded = math.max(
      grid.rows.length,
      math.max(toRow + 1, atRow + values.length),
    );
    final int columnsNeeded = math.max(
      grid.columns,
      math.max(toColumn + 1, atColumn + valueWidth),
    );
    while (grid.aligns.length < columnsNeeded) {
      grid.aligns.add(TableAlign.none);
    }
    for (final List<String> r in grid.rows) {
      while (r.length < columnsNeeded) {
        r.add('');
      }
    }
    while (grid.rows.length < rowsNeeded) {
      grid.rows.add(grid.emptyRow());
    }

    // Clear the whole selection first, then write: a value landing inside the
    // rectangle overwrites a cell that was about to be cleared, and the order
    // is what keeps that from being ambiguous.
    for (
      int r = fromRow.clamp(0, grid.rows.length - 1);
      r <= toRow.clamp(0, grid.rows.length - 1);
      r++
    ) {
      for (
        int c = fromColumn.clamp(0, columnsNeeded - 1);
        c <= toColumn.clamp(0, columnsNeeded - 1);
        c++
      ) {
        grid.rows[r][c] = '';
      }
    }

    int lastRow = atRow.clamp(0, grid.rows.length - 1);
    int lastColumn = atColumn.clamp(0, columnsNeeded - 1);
    for (int r = 0; r < values.length; r++) {
      final int at = (atRow + r).clamp(0, grid.rows.length - 1);
      for (int c = 0; c < values[r].length; c++) {
        final int column = (atColumn + c).clamp(0, grid.rows[at].length - 1);
        grid.rows[at][column] = values[r][c];
        lastRow = at;
        lastColumn = column;
      }
    }
    return _commit(
      block,
      grid,
      row: lastRow,
      column: lastColumn,
      caretAtEnd: true,
    );
  }

  /// One more column. [right] puts it after [column], otherwise before it.
  static TableEditResult insertColumn(
    TableBlock block, {
    required int row,
    required int column,
    required bool right,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int at = (right ? column + 1 : column).clamp(0, grid.columns);
    for (final List<String> r in grid.rows) {
      r.insert(at.clamp(0, r.length), '');
    }
    grid.aligns.insert(at.clamp(0, grid.aligns.length), TableAlign.none);
    // The caret stays in the column it was in, which may have moved right.
    return _commit(
      block,
      grid,
      row: row,
      column: at > column ? column : column + 1,
    );
  }

  /// Removes a block of columns — what an explicit column selection deletes.
  ///
  /// Unlike [deleteColumn] this can take every column, and then it takes the
  /// table: a divider with no cells above it is not a table.
  static TableEditResult deleteColumns(
    TableBlock block, {
    required int from,
    required int to,
    required int row,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int columns = grid.columns;
    if (columns == 0) return deleteTable(block);
    final int a = from.clamp(0, columns - 1);
    final int b = to.clamp(a, columns - 1);
    if (b - a + 1 >= columns) return deleteTable(block);
    for (final List<String> r in grid.rows) {
      r.removeRange(a, math.min(b + 1, r.length));
    }
    grid.aligns.removeRange(a, math.min(b + 1, grid.aligns.length));
    return _commit(block, grid, row: row, column: a.clamp(0, grid.columns - 1));
  }

  /// Removes one column. The last one cannot go: a table needs a cell.
  static TableEditResult? deleteColumn(
    TableBlock block, {
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.columns <= 1) return null;
    final int at = column.clamp(0, grid.columns - 1);
    for (final List<String> r in grid.rows) {
      if (at < r.length) r.removeAt(at);
    }
    if (at < grid.aligns.length) grid.aligns.removeAt(at);
    return _commit(
      block,
      grid,
      row: row,
      column: at.clamp(0, grid.columns - 1),
    );
  }

  /// Moves a row within the block. The header role follows the first row.
  static TableEditResult? moveRow(
    TableBlock block, {
    required int from,
    required int to,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.length < 2) return null;
    if (from < 0 ||
        from >= grid.rows.length ||
        to < 0 ||
        to >= grid.rows.length) {
      return null;
    }
    if (from == to) return null;
    final List<String> row = grid.rows.removeAt(from);
    grid.rows.insert(to, row);
    return _commit(block, grid, row: to, column: column);
  }

  /// Moves a column within the block, alignments included.
  static TableEditResult? moveColumn(
    TableBlock block, {
    required int from,
    required int to,
    required int row,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.columns < 2) return null;
    if (from < 0 || from >= grid.columns || to < 0 || to >= grid.columns) {
      return null;
    }
    if (from == to) return null;
    for (final List<String> r in grid.rows) {
      if (from < r.length && to < r.length) r.insert(to, r.removeAt(from));
    }
    if (from < grid.aligns.length && to < grid.aligns.length) {
      grid.aligns.insert(to, grid.aligns.removeAt(from));
    }
    return _commit(block, grid, row: row, column: to);
  }

  /// Moves rows [from]…[to] one slot up or down, as a block.
  ///
  /// [delta] is only ever ±1 — a drag of one row is the same command, and
  /// keeping the selection together is what makes 「上移 3 行」 mean it.
  /// Returns `null` at the edge, where there is nothing to swap with.
  static TableEditResult? moveRows(
    TableBlock block, {
    required int from,
    required int to,
    required int delta,
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.length < 2 || delta == 0) return null;
    final int a = from.clamp(0, grid.rows.length - 1);
    final int b = to.clamp(a, grid.rows.length - 1);
    if (delta < 0 && a == 0) return null;
    if (delta > 0 && b == grid.rows.length - 1) return null;
    final List<List<String>> chunk = <List<String>>[
      for (int i = a; i <= b; i++) grid.rows[i],
    ];
    grid.rows.removeRange(a, b + 1);
    final int at = delta < 0 ? a - 1 : a + 1;
    grid.rows.insertAll(at, chunk);
    return _commit(
      block,
      grid,
      row: (row + delta).clamp(0, grid.rows.length - 1),
      column: column,
    );
  }

  /// Moves columns [from]…[to] one slot left or right, alignments included.
  static TableEditResult? moveColumns(
    TableBlock block, {
    required int from,
    required int to,
    required int delta,
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int columns = grid.columns;
    if (columns < 2 || delta == 0) return null;
    final int a = from.clamp(0, columns - 1);
    final int b = to.clamp(a, columns - 1);
    if (delta < 0 && a == 0) return null;
    if (delta > 0 && b == columns - 1) return null;
    final int at = delta < 0 ? a - 1 : a + 1;
    for (final List<String> r in grid.rows) {
      final List<String> chunk = <String>[
        for (int c = a; c <= b && c < r.length; c++) r[c],
      ];
      r.removeRange(a, math.min(b + 1, r.length));
      r.insertAll(at.clamp(0, r.length), chunk);
    }
    final List<TableAlign> chunk = <TableAlign>[
      for (int c = a; c <= b && c < grid.aligns.length; c++) grid.aligns[c],
    ];
    grid.aligns.removeRange(a, math.min(b + 1, grid.aligns.length));
    grid.aligns.insertAll(at.clamp(0, grid.aligns.length), chunk);
    return _commit(
      block,
      grid,
      row: row,
      column: (column + delta).clamp(0, columns - 1),
    );
  }

  /// Sets the alignment of one column — the edit the divider row used to make
  /// impossible to reach.
  static TableEditResult setAlign(
    TableBlock block, {
    required int row,
    required int column,
    required TableAlign align,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.aligns.isEmpty) {
      return TableEditResult(
        block.text,
        TextSelection.collapsed(offset: block.start),
      );
    }
    // Alignment has nowhere to live without a divider. An explicit left /
    // centre / right therefore repairs the table by growing one; 「默认对齐」
    // adds nothing, so a dividerless table is left exactly as it was.
    if (align != TableAlign.none) grid.header = true;
    final int at = column.clamp(0, grid.aligns.length - 1);
    grid.aligns[at] = align;
    return _commit(block, grid, row: row, column: at);
  }

  /// Sets the alignment of columns [from]…[to] — one command for a selection
  /// that covers several columns.
  static TableEditResult setAlignRange(
    TableBlock block, {
    required int from,
    required int to,
    required int row,
    required int column,
    required TableAlign align,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.aligns.isEmpty) {
      return TableEditResult(
        block.text,
        TextSelection.collapsed(offset: block.start),
      );
    }
    if (align != TableAlign.none) grid.header = true;
    final int a = from.clamp(0, grid.aligns.length - 1);
    final int b = to.clamp(a, grid.aligns.length - 1);
    for (int c = a; c <= b; c++) {
      grid.aligns[c] = align;
    }
    return _commit(block, grid, row: row, column: column.clamp(a, b));
  }

  /// Adds or removes the header row.
  ///
  /// The header is the first row **plus the divider after it** — Markdown has no
  /// way to have one without the other. Removing it therefore also drops the
  /// alignment, which lives inside the divider; that is the same rule
  /// [setAlign] already follows, where a dividerless table has no alignment.
  /// The rows themselves are untouched: the first one merely stops being the
  /// header, so toggling back restores exactly the table that was there.
  static TableEditResult setHeader(
    TableBlock block, {
    required bool header,
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty) {
      return TableEditResult(
        block.text,
        TextSelection.collapsed(offset: block.start),
      );
    }
    // Already in the requested state: keep the source verbatim instead of
    // re-rendering, which would rewrite the user's spacing around the pipes.
    if (grid.header == header) {
      final List<TableRow> body = block.bodyRows;
      if (body.isEmpty) {
        return TableEditResult(
          block.text,
          TextSelection.collapsed(offset: block.start),
        );
      }
      final TableRow r = body[row.clamp(0, body.length - 1)];
      return TableEditResult(
        block.text,
        TextSelection.collapsed(
          offset: r.cells.isEmpty
              ? r.start
              : r.cells[column.clamp(0, r.cells.length - 1)].contentStart,
        ),
      );
    }
    grid.header = header;
    return _commit(block, grid, row: row, column: column);
  }

  /// Removes the whole block, and the newline that closed it, so deleting a
  /// table does not leave a blank line where it used to.
  static TableEditResult deleteTable(TableBlock block) {
    final int end = block.end < block.text.length ? block.end + 1 : block.end;
    final String next = block.text.replaceRange(block.start, end, '');
    return TableEditResult(
      next,
      TextSelection.collapsed(offset: block.start.clamp(0, next.length)),
    );
  }

  /// Appends [rows] under [block], dropping [rows]'s own header — the table
  /// already has one, and a second would land as data carrying the old column
  /// names.
  static TableEditResult appendRows(TableBlock block, List<List<String>> rows) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int cols = grid.columns;
    for (final List<String> r in rows) {
      grid.rows.add(<String>[
        for (int c = 0; c < cols; c++) c < r.length ? r[c] : '',
      ]);
    }
    return _commit(block, grid, row: grid.rows.length - 1, column: 0);
  }

  /// Sorts the data rows by [column], leaving a header row in place.
  ///
  /// Empty cells sink to the bottom in both directions — a blank is "no value",
  /// so it should never take the top slot just because the sort was descending.
  /// The sort is stable: equal cells keep their relative order.
  static TableEditResult? sortRows(
    TableBlock block, {
    required int column,
    required bool ascending,
    required int row,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty) return null;
    final int at = column.clamp(0, grid.columns - 1);
    final int first = grid.header ? 1 : 0;
    if (grid.rows.length - first < 2) return null;

    final List<List<String>> body = <List<String>>[
      for (int i = first; i < grid.rows.length; i++) grid.rows[i],
    ];
    final List<int> order = <int>[for (int i = 0; i < body.length; i++) i];
    order.sort((int i, int j) {
      final String a = at < body[i].length ? body[i][at] : '';
      final String b = at < body[j].length ? body[j][at] : '';
      final bool aEmpty = a.trim().isEmpty;
      final bool bEmpty = b.trim().isEmpty;
      if (aEmpty || bEmpty) {
        if (aEmpty && bEmpty) return i.compareTo(j);
        return aEmpty ? 1 : -1;
      }
      int by = _compareCellText(a, b);
      if (!ascending) by = -by;
      return by != 0 ? by : i.compareTo(j);
    });
    for (int k = 0; k < order.length; k++) {
      grid.rows[first + k] = body[order[k]];
    }
    return _commit(block, grid, row: row, column: at);
  }

  /// Drops body rows whose cell in [column] repeats an earlier one.
  ///
  /// The first occurrence wins and the order is kept: this is 「去掉重复项」,
  /// not a sort. Empty cells are never treated as duplicates — a table of
  /// half-filled rows would otherwise collapse to one blank line.
  static TableEditResult? dedupeColumn(
    TableBlock block, {
    required int column,
    required int row,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty) return null;
    final int at = column.clamp(0, grid.columns - 1);
    final int first = grid.header ? 1 : 0;
    if (grid.rows.length - first < 2) return null;

    final Set<String> seen = <String>{};
    final List<List<String>> kept = <List<String>>[];
    for (int i = first; i < grid.rows.length; i++) {
      final List<String> cells = grid.rows[i];
      final String key = (at < cells.length ? cells[at] : '')
          .trim()
          .toLowerCase();
      if (key.isNotEmpty && !seen.add(key)) continue;
      kept.add(cells);
    }
    if (kept.length == grid.rows.length - first) {
      final List<TableRow> body = block.bodyRows;
      final TableRow r = body[row.clamp(0, body.length - 1)];
      return TableEditResult(
        block.text,
        TextSelection.collapsed(
          offset: r.cells.isEmpty
              ? r.start
              : r.cells[at.clamp(0, r.cells.length - 1)].contentStart,
        ),
      );
    }
    grid.rows.removeRange(first, grid.rows.length);
    grid.rows.addAll(kept);
    return _commit(
      block,
      grid,
      row: row.clamp(first, grid.rows.length - 1),
      column: at,
    );
  }

  /// Inserts a copy of [row] directly under it.
  static TableEditResult duplicateRow(
    TableBlock block, {
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty) {
      return TableEditResult(
        block.text,
        TextSelection.collapsed(offset: block.start),
      );
    }
    final int from = row.clamp(0, grid.rows.length - 1);
    final int at = from + 1;
    grid.rows.insert(at, List<String>.of(grid.rows[from]));
    return _commit(block, grid, row: at, column: column);
  }

  /// Inserts a copy of [column] directly to its right, alignment included.
  static TableEditResult? duplicateColumn(
    TableBlock block, {
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.columns == 0) return null;
    final int at = column.clamp(0, grid.columns - 1);
    final int to = at + 1;
    for (final List<String> r in grid.rows) {
      r.insert(to.clamp(0, r.length), at < r.length ? r[at] : '');
    }
    grid.aligns.insert(
      to.clamp(0, grid.aligns.length),
      at < grid.aligns.length ? grid.aligns[at] : TableAlign.none,
    );
    return _commit(block, grid, row: row, column: to);
  }

  /// Copies rows [from]…[to] directly below [to], in order.
  static TableEditResult? duplicateRows(
    TableBlock block, {
    required int from,
    required int to,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty) return null;
    final int a = from.clamp(0, grid.rows.length - 1);
    final int b = to.clamp(a, grid.rows.length - 1);
    final List<List<String>> copies = <List<String>>[
      for (int i = a; i <= b; i++) List<String>.of(grid.rows[i]),
    ];
    grid.rows.insertAll(b + 1, copies);
    return _commit(block, grid, row: b + 1, column: column);
  }

  /// Copies columns [from]…[to] directly to the right of [to], in order,
  /// alignments included.
  static TableEditResult? duplicateColumns(
    TableBlock block, {
    required int from,
    required int to,
    required int row,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int columns = grid.columns;
    if (columns == 0) return null;
    final int a = from.clamp(0, columns - 1);
    final int b = to.clamp(a, columns - 1);
    final int at = b + 1;
    for (final List<String> r in grid.rows) {
      final List<String> copies = <String>[
        for (int c = a; c <= b && c < r.length; c++) r[c],
      ];
      r.insertAll(at.clamp(0, r.length), copies);
    }
    final List<TableAlign> aligns = <TableAlign>[
      for (int c = a; c <= b && c < grid.aligns.length; c++) grid.aligns[c],
    ];
    grid.aligns.insertAll(at.clamp(0, grid.aligns.length), aligns);
    return _commit(block, grid, row: row, column: at);
  }

  /// Turns rows into columns and columns into rows.
  ///
  /// The header role travels with the first row: after a transpose the old
  /// first *column* becomes the new header. Alignments are dropped, because
  /// "right-aligned column" has no meaning once that column is a row.
  static TableEditResult transpose(
    TableBlock block, {
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty) {
      return TableEditResult(
        block.text,
        TextSelection.collapsed(offset: block.start),
      );
    }
    final int cols = grid.columns;
    final List<List<String>> rows = <List<String>>[
      for (int c = 0; c < cols; c++)
        <String>[
          for (final List<String> r in grid.rows) c < r.length ? r[c] : '',
        ],
    ];
    final TableGrid out = TableGrid(
      rows: rows,
      aligns: List<TableAlign>.filled(rows.first.length, TableAlign.none),
      header: grid.header,
    );
    return _commit(
      block,
      out,
      row: column.clamp(0, rows.length - 1),
      column: row.clamp(0, rows.first.length - 1),
    );
  }

  /// Sets each column's alignment from its data: a column where every filled
  /// cell is a number lines its numbers up on the right, everything else stays
  /// left. It is a deliberate command, not a background guess.
  static TableEditResult autoAlign(
    TableBlock block, {
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int first = grid.header ? 1 : 0;
    bool aligned = false;
    for (int c = 0; c < grid.columns; c++) {
      int filled = 0;
      int numbers = 0;
      for (int r = first; r < grid.rows.length; r++) {
        final String text = c < grid.rows[r].length
            ? grid.rows[r][c].trim()
            : '';
        if (text.isEmpty) continue;
        filled++;
        if (numberInCell(text) != null) numbers++;
      }
      final bool numeric = filled > 0 && numbers == filled;
      grid.aligns[c] = numeric ? TableAlign.right : TableAlign.none;
      aligned = aligned || numeric;
    }
    // Same rule as the explicit align command: no divider, no alignment.
    if (aligned) grid.header = true;
    return _commit(block, grid, row: row, column: column);
  }

  /// Appends a footer row with [aggregate] of [column].
  ///
  /// The result lands in the chosen column; the word「合计」/「平均」… lands in
  /// the first other column, so the sum reads as a row of the table instead of
  /// a bare number in a cell. A numeric column is right-aligned as a side
  /// effect: a total that does not line up with the numbers it totals is worse
  /// than no total.
  static TableEditResult? appendAggregate(
    TableBlock block, {
    required int column,
    required TableAggregate aggregate,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.columns == 0) return null;
    final int at = column.clamp(0, grid.columns - 1);
    final int first = grid.header ? 1 : 0;
    final List<String> cells = <String>[
      for (int r = first; r < grid.rows.length; r++)
        at < grid.rows[r].length ? grid.rows[r][at] : '',
    ];
    final List<double> numbers = <double>[
      for (final String c in cells)
        if (numberInCell(c) case final double n) n,
    ];

    final String value = switch (aggregate) {
      TableAggregate.count =>
        '${cells.where((String c) => c.trim().isNotEmpty).length}',
      TableAggregate.sum =>
        numbers.isEmpty
            ? ''
            : formatNumber(
                numbers.fold<double>(0, (double a, double b) => a + b),
              ),
      TableAggregate.average =>
        numbers.isEmpty
            ? ''
            : formatNumber(
                numbers.fold<double>(0, (double a, double b) => a + b) /
                    numbers.length,
              ),
      TableAggregate.min =>
        numbers.isEmpty ? '' : formatNumber(numbers.reduce(math.min)),
      TableAggregate.max =>
        numbers.isEmpty ? '' : formatNumber(numbers.reduce(math.max)),
    };
    if (value.isEmpty && aggregate != TableAggregate.count) return null;

    final List<String> summary = List<String>.filled(grid.columns, '');
    summary[at] = value;
    if (grid.columns > 1) {
      summary[at == 0 ? 1 : 0] = aggregate.label;
    }
    grid.rows.add(summary);
    // The right alignment lives in the divider; grow one so the side effect
    // survives `render`, exactly as the explicit align command does.
    grid.header = true;
    grid.aligns[at] = TableAlign.right;
    return _commit(
      block,
      grid,
      row: grid.rows.length - 1,
      column: at,
      selectCell: true,
    );
  }
}

/// Tab-separated text — what Excel, Numbers and every web table put on the
/// clipboard — read as a grid. `null` when [text] is not one.
List<List<String>>? gridFromTsv(String text) {
  final List<String> lines = text.replaceAll('\r\n', '\n').split('\n');
  final List<String> meaningful = <String>[
    for (final String l in lines)
      if (l.trim().isNotEmpty) l,
  ];
  if (meaningful.length < 2) return null;
  final List<List<String>> rows = <List<String>>[
    for (final String l in meaningful) l.split('\t'),
  ];
  final int cols = rows.first.length;
  if (cols < 2) return null;
  // A ragged paste is still a table: the model pads it.
  return <List<String>>[
    for (final List<String> r in rows)
      <String>[for (int c = 0; c < cols; c++) c < r.length ? r[c].trim() : ''],
  ];
}

/// Whether [text] is a Markdown table block.
bool isMarkdownTable(String text) {
  final List<String> lines = text.split('\n');
  if (lines.isEmpty) return false;
  if (!isRowLine(lines.first)) return false;
  // Either a divider on the second line, or two rows of the same width.
  if (lines.length > 1 && isDividerLine(lines[1])) return true;
  return lines.where(isRowLine).length >= 2;
}

/// A Markdown table's cells as a grid, or `null` when it is not a table.
TableGrid? gridFromMarkdown(String text) {
  final TableBlock? block = TableBlock.parse(text, 0);
  if (block == null || block.start != 0) return null;
  return TableGrid.fromBlock(block);
}
