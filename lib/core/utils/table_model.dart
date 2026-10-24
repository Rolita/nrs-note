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

/// The six named colors a cell may point at.
///
/// A token is not a literal color: the renderer resolves it against the current
/// theme, so a note filled with `amber` stays readable when the app switches to
/// dark mode. A custom `#RRGGBB` does the opposite and stays literal.
enum CellColorToken { gray, amber, green, blue, purple, red }

/// A cell color: a theme token, or a literal ARGB value.
class CellColor {
  const CellColor.token(CellColorToken this.token) : custom = null;

  const CellColor.custom(int this.custom) : token = null;

  final CellColorToken? token;
  final int? custom;

  /// Reads the value written after `bg=` / `fg=`. Unknown names and malformed
  /// hex are ignored — a hand-edited directive loses the color, not the cell.
  static CellColor? parse(String source) {
    final String s = source.trim();
    for (final CellColorToken token in CellColorToken.values) {
      if (token.name == s) return CellColor.token(token);
    }
    if (!s.startsWith('#') || (s.length != 7 && s.length != 9)) return null;
    final int? value = int.tryParse(s.substring(1), radix: 16);
    if (value == null) return null;
    return CellColor.custom(s.length == 7 ? 0xFF000000 | value : value);
  }

  /// The canonical spelling inside a directive.
  String get source {
    final CellColorToken? t = token;
    if (t != null) return t.name;
    final int argb = custom!;
    final String rgb = (argb & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    if ((argb >> 24) & 0xFF == 0xFF) return '#$rgb';
    return '#${argb.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  @override
  bool operator ==(Object other) =>
      other is CellColor && other.token == token && other.custom == custom;

  @override
  int get hashCode => Object.hash(token, custom);
}

/// What a cell carries besides its text: spans and the two colors.
///
/// The grid keeps this next to every cell instead of in a side table, because
/// a structural edit moves cells and their formatting has to move with them.
class TableCellStyle {
  const TableCellStyle({
    this.columnSpan = 1,
    this.rowSpan = 1,
    this.fill,
    this.text,
  });

  final int columnSpan;
  final int rowSpan;
  final CellColor? fill;
  final CellColor? text;

  bool get spans => columnSpan > 1 || rowSpan > 1;

  bool get isEmpty => !spans && fill == null && text == null;

  TableCellStyle copyWith({
    int? columnSpan,
    int? rowSpan,
    CellColor? fill,
    CellColor? text,
  }) => TableCellStyle(
    columnSpan: columnSpan ?? this.columnSpan,
    rowSpan: rowSpan ?? this.rowSpan,
    fill: fill ?? this.fill,
    text: text ?? this.text,
  );

  /// The directive this style writes at the start of a cell, or `''`.
  ///
  /// Fixed key order — `c r bg fg` — so two spellings of the same style cannot
  /// make a source diff look like an edit.
  String get directive => directiveFor();

  /// [directive], with the table's column widths appended as `w`.
  ///
  /// Widths are a **table** property, not a cell's: passing them here keeps the
  /// one place that spells a directive exhaustive, while [TableCellStyle] still
  /// stores none of them — a span or a color that moves between cells must not
  /// carry a whole table's widths along.
  String directiveFor({List<int>? widths}) {
    final List<String> parts = <String>[
      if (columnSpan > 1) 'c=$columnSpan',
      if (rowSpan > 1) 'r=$rowSpan',
      if (fill != null) 'bg=${fill!.source}',
      if (text != null) 'fg=${text!.source}',
      if (widths != null && widths.isNotEmpty) 'w=${widths.join(',')}',
    ];
    return parts.isEmpty ? '' : '<!--nrs ${parts.join(' ')}-->';
  }

  @override
  bool operator ==(Object other) =>
      other is TableCellStyle &&
      other.columnSpan == columnSpan &&
      other.rowSpan == rowSpan &&
      other.fill == fill &&
      other.text == text;

  @override
  int get hashCode => Object.hash(columnSpan, rowSpan, fill, text);
}

/// Which of a cell's two colors a command writes.
enum TableCellColorChannel { fill, text }

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

const String _kDirectiveOpen = '<!--nrs';
const String _kDirectiveClose = '-->';

final RegExp _directiveKeyRe = RegExp(r'([A-Za-z]+)\s*=\s*([^\s]+)');

/// The `[start, end)` of the formatting directive that opens [raw], if it has
/// one.
///
/// The comment only counts at the beginning of the cell, after optional
/// padding. A malformed comment (no closing `-->`) stays ordinary text: it is
/// better to show the user their broken source than to hide a cell behind a
/// directive that cannot be parsed. The `nrs` namespace is reserved.
(int, int)? tableDirectiveRange(String raw) {
  int i = 0;
  while (i < raw.length && (raw[i] == ' ' || raw[i] == '\t')) {
    i++;
  }
  if (!raw.startsWith(_kDirectiveOpen, i)) return null;
  final int after = i + _kDirectiveOpen.length;
  if (after < raw.length &&
      raw[after] != ' ' &&
      raw[after] != '\t' &&
      !raw.startsWith(_kDirectiveClose, after)) {
    return null;
  }
  final int close = raw.indexOf(_kDirectiveClose, after);
  if (close < 0) return null;
  return (i, close + _kDirectiveClose.length);
}

class _CellDirective {
  const _CellDirective(this.start, this.end, this.style);

  final int start;
  final int end;
  final TableCellStyle style;
}

_CellDirective? _cellDirective(String raw) {
  final (int, int)? range = tableDirectiveRange(raw);
  if (range == null) return null;
  final String body = raw.substring(
    range.$1 + _kDirectiveOpen.length,
    range.$2 - _kDirectiveClose.length,
  );
  int columnSpan = 1;
  int rowSpan = 1;
  CellColor? fill;
  CellColor? text;
  for (final Match m in _directiveKeyRe.allMatches(body)) {
    final String value = m[2]!;
    switch (m[1]) {
      case 'c':
        columnSpan = _spanValue(value);
      case 'r':
        rowSpan = _spanValue(value);
      case 'bg':
        fill = CellColor.parse(value);
      case 'fg':
        text = CellColor.parse(value);
    }
  }
  return _CellDirective(
    range.$1,
    range.$2,
    TableCellStyle(
      columnSpan: columnSpan,
      rowSpan: rowSpan,
      fill: fill,
      text: text,
    ),
  );
}

int _spanValue(String value) {
  final int? n = int.tryParse(value);
  return n != null && n >= 2 ? n : 1;
}

/// The `key=value` pairs inside [raw]'s `nrs` directive, in source order.
///
/// Used by writers that rebuild a directive but must not swallow keys they do
/// not understand — a hand-added `foo=1` survives a column resize.
List<(String, String)> tableDirectivePairs(String raw) {
  final (int, int)? range = tableDirectiveRange(raw);
  if (range == null) return const <(String, String)>[];
  final String body = raw.substring(
    range.$1 + _kDirectiveOpen.length,
    range.$2 - _kDirectiveClose.length,
  );
  return <(String, String)>[
    for (final Match m in _directiveKeyRe.allMatches(body)) (m[1]!, m[2]!),
  ];
}

/// The manual column widths stored in [line]'s first cell, or `null`.
///
/// The widths live in the first visual row's first `nrs` directive as
/// `w=180,240`. They are **design pixels at 15.5pt**; the renderer converts
/// them to its own pixels. A list that is malformed, not positive, or not
/// exactly [columns] long is ignored whole — half a width list is not a hint,
/// it is a table whose geometry would depend on which column happened to parse.
List<int>? tableColumnWidthsOfLine(String line, int columns) {
  if (columns < 1) return null;
  final List<(int, int)> cells = cellsOfLine(line);
  if (cells.isEmpty) return null;
  final (int a, int b) = cells.first;
  final String raw = line.substring(a, b);
  final (int, int)? range = tableDirectiveRange(raw);
  if (range == null) return null;
  final String body = raw.substring(
    range.$1 + _kDirectiveOpen.length,
    range.$2 - _kDirectiveClose.length,
  );
  String? value;
  for (final Match m in _directiveKeyRe.allMatches(body)) {
    // The first `w` wins, the same rule every other duplicated key follows.
    if (m[1] == 'w') {
      value = m[2];
      break;
    }
  }
  if (value == null) return null;
  final List<String> parts = value.split(',');
  if (parts.length != columns) return null;
  final List<int> widths = <int>[];
  for (final String part in parts) {
    final int? n = int.tryParse(part);
    if (n == null || n <= 0) return null;
    widths.add(n);
  }
  return widths;
}

/// One cell of a parsed row: the **raw** range (padding included) and the text.
class TableCell {
  const TableCell({required this.start, required this.end, required this.raw});

  final int start;
  final int end;
  final String raw;

  TableCellStyle get style =>
      _cellDirective(raw)?.style ?? const TableCellStyle();

  bool get hasDirective => tableDirectiveRange(raw) != null;

  /// Where the directive's `<!--` and its trailing `-->` sit, in source
  /// offsets, padding included.
  int? get directiveStart {
    final (int, int)? range = tableDirectiveRange(raw);
    return range == null ? null : start + range.$1;
  }

  int? get directiveEnd {
    final (int, int)? range = tableDirectiveRange(raw);
    return range == null ? null : start + range.$2;
  }

  /// The cell's **visible** markdown: the directive, padding and escapes gone.
  String get text {
    final (int, int)? range = tableDirectiveRange(raw);
    final String visible = range == null
        ? raw
        : raw.replaceRange(range.$1, range.$2, '');
    return unescapeCell(visible.trim());
  }

  /// Where the cell's own text begins — past the padding and the hidden
  /// directive. An empty cell starts and ends at the same place.
  int get contentStart {
    int i = 0;
    while (i < raw.length && (raw[i] == ' ' || raw[i] == '\t')) {
      i++;
    }
    final (int, int)? range = tableDirectiveRange(raw);
    if (range != null) {
      i = range.$2;
      while (i < raw.length && (raw[i] == ' ' || raw[i] == '\t')) {
        i++;
      }
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

  /// The table's manual column widths, or `null` for automatic widths.
  ///
  /// Read from the first visual row's first cell — the header when there is
  /// one, otherwise the first body row. Kept off [TableCellStyle] on purpose:
  /// a span or a color travels with its cell, but widths belong to all of them.
  List<int>? get columnWidths {
    final List<TableRow> body = bodyRows;
    if (body.isEmpty || body.first.cells.isEmpty) return null;
    final TableRow first = body.first;
    return tableColumnWidthsOfLine(
      text.substring(first.start, first.end),
      columns,
    );
  }

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

/// One cell of the editable grid: its visible text and its formatting.
///
/// The text is plain and unescaped, the way [TableCell.text] reads it. Formatting
/// lives beside it so an edit that only moves cells carries both along.
class GridCell {
  GridCell(this.text, [this.style = const TableCellStyle()]);

  String text;
  TableCellStyle style;

  GridCell copy() => GridCell(text, style);

  bool get isEmpty => text.trim().isEmpty;
}

/// One valid merged block: the anchor plus the rectangle it covers.
class TableMerge {
  const TableMerge({
    required this.row,
    required this.column,
    required this.rowSpan,
    required this.columnSpan,
  });

  final int row;
  final int column;
  final int rowSpan;
  final int columnSpan;

  int get lastRow => row + rowSpan - 1;
  int get lastColumn => column + columnSpan - 1;

  bool covers(int r, int c) =>
      r >= row && r <= lastRow && c >= column && c <= lastColumn;

  bool intersects(int fromRow, int toRow, int fromColumn, int toColumn) =>
      row <= toRow &&
      lastRow >= fromRow &&
      column <= toColumn &&
      lastColumn >= fromColumn;
}

/// The formatting directive that opens a raw cell, or an empty style.
///
/// The renderer parses a line into raw cells once and then asks this for each
/// one; [TableCell.style] would re-scan the directive for every read.
TableCellStyle tableCellStyleOf(String raw) =>
    _cellDirective(raw)?.style ?? const TableCellStyle();

/// Every valid merge in [block], anchors only, row-major.
///
/// The read-only counterpart of [TableGrid.merges]: the sidebar and the
/// selection model ask about spans without copying the table into a grid first.
List<TableMerge> tableMergesOf(TableBlock block) {
  final List<TableRow> body = block.bodyRows;
  return tableMergesFromStyles(
    rowCount: body.length,
    columns: block.columns,
    styleAt: (int row, int column) => column < body[row].cells.length
        ? body[row].cells[column].style
        : const TableCellStyle(),
  );
}

/// [TableGrid.merges] without building a grid — for callers that already hold
/// per-cell styles (the renderer parses a table line by line).
List<TableMerge> tableMergesFromStyles({
  required int rowCount,
  required int columns,
  required TableCellStyle Function(int row, int column) styleAt,
}) => _validMerges(rowCount: rowCount, columns: columns, styleAt: styleAt);

/// The merges a grid actually has, ignoring spans of one, out-of-bounds spans
/// and overlaps. Both [TableBlock] and [TableGrid] share this validation so a
/// hand-edited file reads the same to the renderer and to the commands.
List<TableMerge> _validMerges({
  required int rowCount,
  required int columns,
  required TableCellStyle Function(int row, int column) styleAt,
}) {
  final List<TableMerge> out = <TableMerge>[];
  for (int r = 0; r < rowCount; r++) {
    for (int c = 0; c < columns; c++) {
      final TableCellStyle style = styleAt(r, c);
      if (!style.spans) continue;
      if (c + style.columnSpan > columns || r + style.rowSpan > rowCount) {
        continue;
      }
      final TableMerge merge = TableMerge(
        row: r,
        column: c,
        rowSpan: style.rowSpan,
        columnSpan: style.columnSpan,
      );
      if (out.any(
        (TableMerge m) => m.intersects(
          merge.row,
          merge.lastRow,
          merge.column,
          merge.lastColumn,
        ),
      )) {
        continue;
      }
      out.add(merge);
    }
  }
  return out;
}

/// The editable form of a block: cells and alignments, no offsets.
///
/// Structural edits change this and nothing else; [render] turns it back into
/// Markdown. That is what makes "every row the same width" a property of the
/// model instead of something each command has to remember.
class TableGrid {
  TableGrid({
    required this.rows,
    required this.aligns,
    required this.header,
    this.widths,
  });

  factory TableGrid.fromBlock(TableBlock block) {
    final int cols = block.columns;
    final List<int>? widths = block.columnWidths;
    return TableGrid(
      rows: <List<GridCell>>[
        for (final TableRow r in block.bodyRows)
          <GridCell>[
            for (int c = 0; c < cols; c++)
              c < r.cells.length
                  ? GridCell(r.cells[c].text, r.cells[c].style)
                  : GridCell(''),
          ],
      ],
      // A copy, and growable: on a table without a divider `block.aligns` is a
      // fixed-length filler, and the column commands insert/remove entries.
      aligns: List<TableAlign>.of(block.aligns),
      header: block.hasHeader,
      widths: widths == null ? null : List<int>.of(widths),
    );
  }

  /// A rectangular grid of unformatted text — what TSV and a new table are.
  factory TableGrid.fromStrings(
    List<List<String>> rows, {
    required List<TableAlign> aligns,
    required bool header,
  }) {
    final int cols = rows.fold<int>(
      0,
      (int m, List<String> r) => math.max(m, r.length),
    );
    return TableGrid(
      rows: <List<GridCell>>[
        for (final List<String> row in rows)
          <GridCell>[
            for (int c = 0; c < cols; c++)
              GridCell(c < row.length ? row[c] : ''),
          ],
      ],
      aligns: List<TableAlign>.of(aligns),
      header: header,
    );
  }

  /// Content rows, header first. A row is always [columns] wide.
  final List<List<GridCell>> rows;

  /// One alignment per column.
  final List<TableAlign> aligns;

  /// Whether [rows] starts with a header row (and therefore needs a divider).
  ///
  /// Mutable because alignment is written **into the divider**: a table that
  /// arrived without one has to grow one before an alignment can survive
  /// [render] — otherwise the row looks applied but the Markdown never changes.
  bool header;

  /// Manual column widths in design pixels, or `null` for automatic widths.
  ///
  /// Mutable because column insert/delete/move rearrange it with the columns;
  /// [render] writes it into the new first row's first cell. A list whose length
  /// no longer matches [columns] is ignored on the way out, never written half.
  List<int>? widths;

  int get columns => rows.isEmpty ? aligns.length : rows.first.length;

  /// One empty row of the right width.
  List<GridCell> emptyRow() =>
      List<GridCell>.generate(columns, (_) => GridCell(''));

  String textAt(int row, int column) =>
      row >= 0 && row < rows.length && column >= 0 && column < rows[row].length
      ? rows[row][column].text
      : '';

  /// Every merge the grid actually has, row-major, anchors only.
  ///
  /// Validation is deliberately defensive: out-of-bounds spans, spans of one,
  /// and overlapping directives are ignored rather than clamped. A hand-edited
  /// file must never be able to draw the table into itself; the directive is
  /// still hidden, the cell simply renders unmerged.
  List<TableMerge> get merges => _validMerges(
    rowCount: rows.length,
    columns: columns,
    styleAt: (int row, int column) => column < rows[row].length
        ? rows[row][column].style
        : const TableCellStyle(),
  );

  /// The merge covering `(row, column)`, anchor or not.
  TableMerge? mergeCovering(int row, int column) {
    for (final TableMerge m in merges) {
      if (m.covers(row, column)) return m;
    }
    return null;
  }

  TableMerge? mergeAnchoredAt(int row, int column) {
    for (final TableMerge m in merges) {
      if (m.row == row && m.column == column) return m;
    }
    return null;
  }

  /// Splits every merge, keeping the colors. For edits that move cells around:
  /// a span is a claim about rows and columns, and after a transpose or a sort
  /// that claim points at different data than the one the user made.
  void dropMerges() {
    for (final List<GridCell> row in rows) {
      for (final GridCell cell in row) {
        if (!cell.style.spans) continue;
        cell.style = TableCellStyle(
          fill: cell.style.fill,
          text: cell.style.text,
        );
      }
    }
  }

  /// The canonical Markdown for this grid.
  String render() {
    if (rows.isEmpty) return '';
    final int cols = columns;
    final List<int>? columnWidths =
        widths != null &&
            widths!.length == cols &&
            widths!.every((int w) => w > 0)
        ? widths
        : null;
    final List<String> lines = <String>[];
    for (int i = 0; i < rows.length; i++) {
      final List<String> cells = <String>[
        for (int c = 0; c < cols; c++)
          if (c < rows[i].length)
            '${rows[i][c].style.directiveFor(widths: i == 0 && c == 0 ? columnWidths : null)}${escapeCell(rows[i][c].text)}'
          else
            '',
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

/// Inserts [count] empty rows at [index].
///
/// An insertion strictly inside a span grows that span: the merged block still
/// covers the same visible area plus the new row. At either boundary the span
/// keeps its size and the whole block merely moves.
void _insertGridRows(TableGrid grid, int index, int count) {
  final List<(int, int, int, int)> expansions = <(int, int, int, int)>[];
  for (final TableMerge m in grid.merges) {
    if (index > m.row && index <= m.lastRow) {
      expansions.add((m.row, m.column, m.rowSpan + count, m.columnSpan));
    }
  }
  for (int i = 0; i < count; i++) {
    grid.rows.insert(index, grid.emptyRow());
  }
  for (final (int r, int c, int rowSpan, int columnSpan) in expansions) {
    final TableCellStyle style = grid.rows[r][c].style;
    grid.rows[r][c].style = TableCellStyle(
      columnSpan: columnSpan,
      rowSpan: rowSpan,
      fill: style.fill,
      text: style.text,
    );
  }
}

/// Inserts [count] empty columns at [index], alignments included.
void _insertGridColumns(TableGrid grid, int index, int count) {
  final List<(int, int, int, int)> expansions = <(int, int, int, int)>[];
  for (final TableMerge m in grid.merges) {
    if (index > m.column && index <= m.lastColumn) {
      expansions.add((m.row, m.column, m.rowSpan, m.columnSpan + count));
    }
  }
  final List<int>? widths = grid.widths;
  if (widths != null && widths.length == grid.columns) {
    final int at = index.clamp(0, widths.length);
    // The new column copies the width it will sit next to, so an insertion
    // does not reflow a table the user has already sized by hand.
    final int source = at > 0
        ? widths[at - 1]
        : (at < widths.length ? widths[at] : 120);
    for (int i = 0; i < count; i++) {
      widths.insert(at, source);
    }
  }
  for (int i = 0; i < count; i++) {
    for (final List<GridCell> row in grid.rows) {
      row.insert(index.clamp(0, row.length), GridCell(''));
    }
    grid.aligns.insert(index.clamp(0, grid.aligns.length), TableAlign.none);
  }
  for (final (int r, int c, int rowSpan, int columnSpan) in expansions) {
    final TableCellStyle style = grid.rows[r][c].style;
    grid.rows[r][c].style = TableCellStyle(
      columnSpan: columnSpan,
      rowSpan: rowSpan,
      fill: style.fill,
      text: style.text,
    );
  }
}

/// Removes rows [from]…[to].
///
/// Deleting the anchor removes the merge — the cells it covered are gone or
/// have become ordinary cells. Deleting covered rows shrinks the span; deleting
/// rows above or below it does nothing to it.
void _deleteGridRows(TableGrid grid, int from, int to) {
  final List<(int, int, int, int)> shrinks = <(int, int, int, int)>[];
  for (final TableMerge m in grid.merges) {
    if (m.row >= from && m.row <= to) continue;
    if (from > m.row && from <= m.lastRow) {
      final int overlap = math.min(to, m.lastRow) - from + 1;
      shrinks.add((
        m.row,
        m.column,
        math.max(1, m.rowSpan - overlap),
        m.columnSpan,
      ));
    }
  }
  grid.rows.removeRange(from, to + 1);
  for (final (int r, int c, int rowSpan, int columnSpan) in shrinks) {
    final TableCellStyle style = grid.rows[r][c].style;
    grid.rows[r][c].style = TableCellStyle(
      columnSpan: columnSpan,
      rowSpan: rowSpan,
      fill: style.fill,
      text: style.text,
    );
  }
}

/// Removes columns [from]…[to]. The column-wise mirror of [_deleteGridRows].
void _deleteGridColumns(TableGrid grid, int from, int to) {
  final List<(int, int, int, int)> shrinks = <(int, int, int, int)>[];
  for (final TableMerge m in grid.merges) {
    if (m.column >= from && m.column <= to) continue;
    if (from > m.column && from <= m.lastColumn) {
      final int overlap = math.min(to, m.lastColumn) - from + 1;
      shrinks.add((
        m.row,
        m.column,
        m.rowSpan,
        math.max(1, m.columnSpan - overlap),
      ));
    }
  }
  final List<int>? widths = grid.widths;
  if (widths != null && widths.length == grid.columns) {
    widths.removeRange(from, math.min(to + 1, widths.length));
  }
  for (final List<GridCell> row in grid.rows) {
    row.removeRange(from, math.min(to + 1, row.length));
  }
  grid.aligns.removeRange(from, math.min(to + 1, grid.aligns.length));
  for (final (int r, int c, int rowSpan, int columnSpan) in shrinks) {
    final TableCellStyle style = grid.rows[r][c].style;
    grid.rows[r][c].style = TableCellStyle(
      columnSpan: columnSpan,
      rowSpan: rowSpan,
      fill: style.fill,
      text: style.text,
    );
  }
}

/// Grows a rectangle until every merge it touches is contained whole.
///
/// A merged block is one cell to the person looking at the table, so touching
/// any part of it acts on all of it: clearing half a block would leave text
/// alive that the user can no longer see. The loop matters because growing to
/// contain one merge can reach into the next.
({int fromRow, int toRow, int fromColumn, int toColumn}) expandOverMerges(
  Iterable<TableMerge> merges, {
  required int fromRow,
  required int toRow,
  required int fromColumn,
  required int toColumn,
}) {
  int r0 = fromRow;
  int r1 = toRow;
  int c0 = fromColumn;
  int c1 = toColumn;
  bool changed = true;
  while (changed) {
    changed = false;
    for (final TableMerge m in merges) {
      if (!m.intersects(r0, r1, c0, c1)) continue;
      if (m.row < r0) {
        r0 = m.row;
        changed = true;
      }
      if (m.lastRow > r1) {
        r1 = m.lastRow;
        changed = true;
      }
      if (m.column < c0) {
        c0 = m.column;
        changed = true;
      }
      if (m.lastColumn > c1) {
        c1 = m.lastColumn;
        changed = true;
      }
    }
  }
  return (fromRow: r0, toRow: r1, fromColumn: c0, toColumn: c1);
}

/// [expandOverMerges] for a grid a command is already holding.
({int fromRow, int toRow, int fromColumn, int toColumn}) _expandToMerges(
  TableGrid grid,
  int fromRow,
  int toRow,
  int fromColumn,
  int toColumn,
) => expandOverMerges(
  grid.merges,
  fromRow: fromRow,
  toRow: toRow,
  fromColumn: fromColumn,
  toColumn: toColumn,
);

/// Splits one merge, keeping the anchor's colors and text.
void _clearMergeSpan(TableGrid grid, TableMerge merge) {
  final TableCellStyle style = grid.rows[merge.row][merge.column].style;
  grid.rows[merge.row][merge.column].style = TableCellStyle(
    fill: style.fill,
    text: style.text,
  );
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
    // A formatted empty cell has no visible text to select; the selection
    // starts after its hidden directive, or the first keystroke would eat it.
    final TextSelection whole = cell.hasDirective
        ? TextSelection(
            baseOffset: cell.contentStart,
            extentOffset: cell.contentEnd,
          )
        : TextSelection(baseOffset: cell.start, extentOffset: cell.end);
    return TableEditResult(
      next,
      // An empty cell is selected whole: the first keystroke replaces the
      // placeholder instead of landing beside it, exactly like Tab and Enter.
      selectCell || cell.isEmpty
          ? whole
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
    _insertGridRows(grid, at, 1);
    return _commit(block, grid, row: at, column: column);
  }

  /// Removes one row. The last row takes the whole table with it — a table with
  /// no rows is not a table, it is a divider with nothing above it.
  static TableEditResult deleteRow(TableBlock block, int row) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.length <= 1) return deleteTable(block);
    final int at = row.clamp(0, grid.rows.length - 1);
    _deleteGridRows(grid, at, at);
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
    _deleteGridRows(grid, a, b);
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
    _insertGridRows(grid, index, math.max(1, count));
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
    _insertGridColumns(grid, index, math.max(1, count));
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
    if (grid.rows.isEmpty) {
      return TableEditResult(
        block.text,
        TextSelection.collapsed(offset: block.start),
      );
    }
    final int r0 = fromRow.clamp(0, grid.rows.length - 1);
    final int r1 = toRow.clamp(r0, grid.rows.length - 1);
    final int c0 = fromColumn.clamp(0, grid.columns - 1);
    final int c1 = toColumn.clamp(c0, grid.columns - 1);
    final ({int fromRow, int toRow, int fromColumn, int toColumn}) whole =
        _expandToMerges(grid, r0, r1, c0, c1);
    for (int r = whole.fromRow; r <= whole.toRow; r++) {
      for (int c = whole.fromColumn; c <= whole.toColumn; c++) {
        if (c >= 0 && c < grid.rows[r].length) grid.rows[r][c].text = '';
      }
    }
    return _commit(block, grid, row: r0, column: c0);
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
    for (final List<GridCell> r in grid.rows) {
      while (r.length < columnsNeeded) {
        r.add(GridCell(''));
      }
    }
    while (grid.rows.length < rowsNeeded) {
      grid.rows.add(grid.emptyRow());
    }
    // A paste that grows the table creates columns nobody has sized. Writing a
    // shorter width list would give the new columns a width of their own by
    // accident, so the table goes back to automatic widths instead.
    if (grid.widths != null && grid.widths!.length != columnsNeeded) {
      grid.widths = null;
    }

    final bool single = values.length <= 1 && valueWidth <= 1;
    final int atR = atRow.clamp(0, grid.rows.length - 1);
    final int atC = atColumn.clamp(0, columnsNeeded - 1);
    if (single) {
      // Typing in a merged anchor is a one-cell write: the merge survives.
      // Typing in a *covered* cell has nowhere to show the text until the
      // block is split, so that merge goes.
      final TableMerge? covered = grid.mergeCovering(atR, atC);
      if (covered != null && !(covered.row == atR && covered.column == atC)) {
        _clearMergeSpan(grid, covered);
      }
    } else {
      // A rectangle of new cells cannot live inside a merge: every merge the
      // write touches is split first, colors kept.
      final int wantedLastRow =
          atRow + (values.isEmpty ? 1 : values.length) - 1;
      final int wantedLastColumn =
          atColumn + (valueWidth < 1 ? 1 : valueWidth) - 1;
      final int lastWriteRow = wantedLastRow < 0
          ? 0
          : (wantedLastRow > grid.rows.length - 1
                ? grid.rows.length - 1
                : wantedLastRow);
      final int lastWriteColumn = wantedLastColumn < 0
          ? 0
          : (wantedLastColumn > columnsNeeded - 1
                ? columnsNeeded - 1
                : wantedLastColumn);
      final int uFromRow = math.min(fromRow, atRow);
      final int uToRow = math.max(toRow, lastWriteRow);
      final int uFromColumn = math.min(fromColumn, atColumn);
      final int uToColumn = math.max(toColumn, lastWriteColumn);
      for (final TableMerge m in grid.merges) {
        if (m.intersects(uFromRow, uToRow, uFromColumn, uToColumn)) {
          _clearMergeSpan(grid, m);
        }
      }
    }

    // Clear the whole selection first, then write: a value landing inside the
    // rectangle overwrites a cell that was about to be cleared, and the order
    // is what keeps that from being ambiguous. Only text is cleared — a cell's
    // formatting belongs to the cell, the way Excel's Clear Contents works.
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
        grid.rows[r][c].text = '';
      }
    }

    int lastRow = atR;
    int lastColumn = atC;
    for (int r = 0; r < values.length; r++) {
      final int at = (atRow + r).clamp(0, grid.rows.length - 1);
      for (int c = 0; c < values[r].length; c++) {
        final int column = (atColumn + c).clamp(0, grid.rows[at].length - 1);
        grid.rows[at][column].text = values[r][c];
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
    _insertGridColumns(grid, at, 1);
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
    _deleteGridColumns(grid, a, b);
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
    _deleteGridColumns(grid, at, at);
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
    grid.dropMerges();
    final List<GridCell> row = grid.rows.removeAt(from);
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
    grid.dropMerges();
    for (final List<GridCell> r in grid.rows) {
      if (from < r.length && to < r.length) r.insert(to, r.removeAt(from));
    }
    if (from < grid.aligns.length && to < grid.aligns.length) {
      grid.aligns.insert(to, grid.aligns.removeAt(from));
    }
    final List<int>? widths = grid.widths;
    if (widths != null &&
        widths.length == grid.columns &&
        from < widths.length &&
        to < widths.length) {
      widths.insert(to, widths.removeAt(from));
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
    grid.dropMerges();
    final List<List<GridCell>> chunk = <List<GridCell>>[
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
    grid.dropMerges();
    final int at = delta < 0 ? a - 1 : a + 1;
    for (final List<GridCell> r in grid.rows) {
      final List<GridCell> chunk = <GridCell>[
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
    final List<int>? widths = grid.widths;
    if (widths != null && widths.length == columns) {
      final List<int> widthChunk = <int>[
        for (int c = a; c <= b && c < widths.length; c++) widths[c],
      ];
      widths.removeRange(a, math.min(b + 1, widths.length));
      widths.insertAll(at.clamp(0, widths.length), widthChunk);
    }
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
      grid.rows.add(<GridCell>[
        for (int c = 0; c < cols; c++) GridCell(c < r.length ? r[c] : ''),
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

    final List<List<GridCell>> body = <List<GridCell>>[
      for (int i = first; i < grid.rows.length; i++) grid.rows[i],
    ];
    final List<int> order = <int>[for (int i = 0; i < body.length; i++) i];
    order.sort((int i, int j) {
      final String a = at < body[i].length ? body[i][at].text : '';
      final String b = at < body[j].length ? body[j][at].text : '';
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
    if (!Iterable<int>.generate(order.length).any((int i) => order[i] != i)) {
      return null;
    }
    grid.dropMerges();
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
    final List<List<GridCell>> kept = <List<GridCell>>[];
    for (int i = first; i < grid.rows.length; i++) {
      final List<GridCell> cells = grid.rows[i];
      final String key = (at < cells.length ? cells[at].text : '')
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
    grid.dropMerges();
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
    grid.dropMerges();
    grid.rows.insert(at, <GridCell>[
      for (final GridCell c in grid.rows[from]) c.copy(),
    ]);
    return _commit(block, grid, row: at, column: column);
  }

  /// Inserts a copy of [column] directly to its right, alignment included.
  static TableEditResult? duplicateColumn(
    TableBlock block, {
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final int columns = grid.columns;
    if (columns == 0) return null;
    final int at = column.clamp(0, columns - 1);
    final int to = at + 1;
    grid.dropMerges();
    for (final List<GridCell> r in grid.rows) {
      r.insert(
        to.clamp(0, r.length),
        at < r.length ? r[at].copy() : GridCell(''),
      );
    }
    grid.aligns.insert(
      to.clamp(0, grid.aligns.length),
      at < grid.aligns.length ? grid.aligns[at] : TableAlign.none,
    );
    final List<int>? widths = grid.widths;
    if (widths != null && widths.length == columns && at < widths.length) {
      widths.insert(to.clamp(0, widths.length), widths[at]);
    }
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
    grid.dropMerges();
    final List<List<GridCell>> copies = <List<GridCell>>[
      for (int i = a; i <= b; i++)
        <GridCell>[for (final GridCell c in grid.rows[i]) c.copy()],
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
    grid.dropMerges();
    for (final List<GridCell> r in grid.rows) {
      final List<GridCell> copies = <GridCell>[
        for (int c = a; c <= b && c < r.length; c++) r[c].copy(),
      ];
      r.insertAll(at.clamp(0, r.length), copies);
    }
    final List<TableAlign> aligns = <TableAlign>[
      for (int c = a; c <= b && c < grid.aligns.length; c++) grid.aligns[c],
    ];
    grid.aligns.insertAll(at.clamp(0, grid.aligns.length), aligns);
    final List<int>? widths = grid.widths;
    if (widths != null && widths.length == columns) {
      final List<int> widthCopies = <int>[
        for (int c = a; c <= b && c < widths.length; c++) widths[c],
      ];
      widths.insertAll(at.clamp(0, widths.length), widthCopies);
    }
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
    grid.dropMerges();
    final List<List<GridCell>> rows = <List<GridCell>>[
      for (int c = 0; c < cols; c++)
        <GridCell>[
          for (final List<GridCell> r in grid.rows)
            c < r.length ? r[c].copy() : GridCell(''),
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
            ? grid.rows[r][c].text.trim()
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
        at < grid.rows[r].length ? grid.rows[r][at].text : '',
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

    final List<GridCell> summary = List<GridCell>.generate(
      grid.columns,
      (_) => GridCell(''),
    );
    summary[at].text = value;
    if (grid.columns > 1) {
      summary[at == 0 ? 1 : 0].text = aggregate.label;
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

  /// Merges a rectangle into its top-left cell.
  ///
  /// The merge **moves** content instead of deleting it: every non-empty
  /// visible cell in the rectangle is appended to the anchor in reading order,
  /// joined by newlines (rendered as `<br>`). The covered cells are emptied
  /// and stripped of formatting; the anchor keeps its own colors and gains the
  /// spans.
  ///
  /// `null` when the rectangle is smaller than two cells, out of bounds, or
  /// touches any existing merge. A merge never overlaps another merge: the
  /// user has to split first, which keeps "what is this block made of" a
  /// question with one answer.
  static TableEditResult? mergeCells(
    TableBlock block, {
    required int fromRow,
    required int toRow,
    required int fromColumn,
    required int toColumn,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty || grid.columns == 0) return null;
    final int r0 = math.min(fromRow, toRow);
    final int r1 = math.max(fromRow, toRow);
    final int c0 = math.min(fromColumn, toColumn);
    final int c1 = math.max(fromColumn, toColumn);
    if (r0 < 0 || c0 < 0) return null;
    if (r1 >= grid.rows.length || c1 >= grid.columns) return null;
    if ((r1 - r0 + 1) * (c1 - c0 + 1) < 2) return null;
    for (final TableMerge m in grid.merges) {
      if (m.intersects(r0, r1, c0, c1)) return null;
    }

    final List<String> parts = <String>[];
    for (int r = r0; r <= r1; r++) {
      for (int c = c0; c <= c1; c++) {
        final String text = grid.rows[r][c].text;
        if (text.trim().isNotEmpty) parts.add(text);
      }
    }
    for (int r = r0; r <= r1; r++) {
      for (int c = c0; c <= c1; c++) {
        if (r == r0 && c == c0) continue;
        grid.rows[r][c].text = '';
        grid.rows[r][c].style = const TableCellStyle();
      }
    }
    final GridCell anchor = grid.rows[r0][c0];
    anchor.text = parts.join('\n');
    anchor.style = anchor.style.copyWith(
      columnSpan: c1 - c0 + 1,
      rowSpan: r1 - r0 + 1,
    );
    return _commit(block, grid, row: r0, column: c0);
  }

  /// Removes the spans of the merge covering `(row, column)`, keeping its text
  /// and colors in the anchor. `null` when the cell is not merged.
  static TableEditResult? splitCell(
    TableBlock block, {
    required int row,
    required int column,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    final TableMerge? m = grid.mergeCovering(row, column);
    if (m == null) return null;
    final TableCellStyle style = grid.rows[m.row][m.column].style;
    grid.rows[m.row][m.column].style = TableCellStyle(
      fill: style.fill,
      text: style.text,
    );
    return _commit(block, grid, row: m.row, column: m.column);
  }

  /// Sets or clears one color channel over a rectangle.
  ///
  /// The rectangle grows until every merged block it touches is contained
  /// whole; the color lands on the anchor of each merged block and on every
  /// ordinary cell. Covered cells are never painted — the anchor owns the
  /// block's background, so splitting leaves the color where the user saw it.
  static TableEditResult setCellColor(
    TableBlock block, {
    required int fromRow,
    required int toRow,
    required int fromColumn,
    required int toColumn,
    required TableCellColorChannel channel,
    required CellColor? color,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty || grid.columns == 0) {
      return TableEditResult(
        block.text,
        TextSelection.collapsed(offset: block.start),
      );
    }
    final int r0 = fromRow.clamp(0, grid.rows.length - 1);
    final int r1 = toRow.clamp(r0, grid.rows.length - 1);
    final int c0 = fromColumn.clamp(0, grid.columns - 1);
    final int c1 = toColumn.clamp(c0, grid.columns - 1);
    final ({int fromRow, int toRow, int fromColumn, int toColumn}) whole =
        _expandToMerges(grid, r0, r1, c0, c1);
    for (int r = whole.fromRow; r <= whole.toRow; r++) {
      for (int c = whole.fromColumn; c <= whole.toColumn; c++) {
        final TableMerge? m = grid.mergeCovering(r, c);
        if (m != null && !(m.row == r && m.column == c)) continue;
        final TableCellStyle style = grid.rows[r][c].style;
        grid.rows[r][c].style = TableCellStyle(
          columnSpan: style.columnSpan,
          rowSpan: style.rowSpan,
          fill: channel == TableCellColorChannel.fill ? color : style.fill,
          text: channel == TableCellColorChannel.text ? color : style.text,
        );
      }
    }
    final TableMerge? active = grid.mergeCovering(r0, c0);
    return _commit(
      block,
      grid,
      row: active?.row ?? r0,
      column: active?.column ?? c0,
    );
  }

  /// The color of one channel on the cell — the anchor's color when the cell is
  /// covered. Used by the sidebar's swatch and by the tests.
  static CellColor? cellColor(
    TableBlock block, {
    required int row,
    required int column,
    required TableCellColorChannel channel,
  }) {
    final TableGrid grid = TableGrid.fromBlock(block);
    if (grid.rows.isEmpty || grid.columns == 0) return null;
    final int r = row.clamp(0, grid.rows.length - 1);
    final int c = column.clamp(0, grid.columns - 1);
    final TableMerge? m = grid.mergeCovering(r, c);
    final TableCellStyle style = grid.rows[m?.row ?? r][m?.column ?? c].style;
    return channel == TableCellColorChannel.fill ? style.fill : style.text;
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
