part of '../live_markdown.dart';

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

  /// Full width of the cell's box, padding included. Zero for a cell covered
  /// by a merge — it owns no pixels of its own.
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

  /// The base line height. Rows with wrapped cells, and rows sharing a
  /// rowspan, are taller; [rows] and the block heights carry those values.
  final double rowHeight;
  final List<TableRowGeometry> rows;
}

/// A row's raw source cells, before widths are handed out.
class _ParsedCell {
  _ParsedCell(this.text, this.offset, this.format);

  final String text;

  /// Absolute offset of [text]'s first character.
  ///
  /// Mutable: a measurement is reused when its table moves because lines were
  /// inserted or removed above it. Rebinding only shifts the offsets; the
  /// painted text and every `TextPainter` stay untouched.
  int offset;

  /// The cell's hidden formatting directive, parsed once with the text.
  final TableCellStyle format;
}

class _RowData {
  _RowData({
    required this.line,
    required this.start,
    required this.end,
    required this.header,
    required this.cells,
  });

  /// Source line index. Mutable for the same reason as [_ParsedCell.offset]:
  /// reusing a table after an edit above it only rebinds lines and offsets.
  int line;
  int start;

  /// One past the row's last source character (the line break excluded). The
  /// selection uses it to decide whether this row is part of the washed block.
  int end;
  final bool header;
  final List<_ParsedCell> cells;

  /// Same cells with measured geometry, filled by [_measureTable].
  final List<_CellData> data = <_CellData>[];

  /// Moves this row to a new source line and offset after an edit above it.
  void rebind({required int line, required int start, required int end}) {
    final int delta = start - this.start;
    this.line = line;
    this.start = start;
    this.end = end;
    if (delta == 0) return;
    for (final _ParsedCell cell in cells) {
      cell.offset += delta;
    }
  }
}

/// One inline code token in a cell, as range data for the cell painter.
///
/// [start] and [end] count characters in the cell's painted text (the source
/// the span tree carries), so they can be fed straight to
/// [TextPainter.getBoxesForSelection]. [style] is the run's own style — the
/// painter measures it to get the band's height and baseline — and [fill]
/// already has the selection tint mixed in.
///
/// 行内代码与 `#标签` 共用这个出口：只有圆角与左右外扩（[radius]/[padX]）
/// 不同。标签没有反引号那样的隐藏端帽可用，所以它的内边距只能由画笔把底片
/// 向两侧多铺几个像素。
class _CellCode {
  const _CellCode({
    required this.start,
    required this.end,
    required this.probe,
    required this.style,
    required this.fill,
    this.radius = _kInlineCodeRadius,
    this.padX = 0,
    this.padY = 0,
    this.isCode = true,
    this.rowBox = false,
  });

  final int start;
  final int end;
  final String probe;
  final TextStyle style;
  final Color fill;

  /// 底片圆角；标签用 [kTagRadius]，代码用 [_kInlineCodeRadius]。
  final double radius;

  /// 底片在文字两侧额外铺出的宽度（标签的内边距）。
  final double padX;

  /// 底片在文字上下额外铺出的高度（标签的 1px 上下内边距）。
  final double padY;

  /// 只有行内代码的底片跟随表格选区换色；标签保留自己的颜色。
  final bool isCode;

  /// 行渲染层里纵向铺满整条视觉行（`==高亮`）；表格行按基线量高，不用它。
  final bool rowBox;
}

/// One source column's box, after the whole table was fitted.
///
/// Kept per **source** column even when a merge covers it: the column grips,
/// the drag preview and a future split all act on source columns, and the
/// anchor's wide box is the sum of these.
class _ColumnBox {
  const _ColumnBox(this.x, this.width);

  final double x;
  final double width;

  double get right => x + width;
}

/// A cell with its measured and allocated geometry.
class _CellData {
  _CellData({
    required this.cell,
    required this.style,
    required this.spans,
    required this.codeRuns,
    required this.width,
    required this.align,
    this.memo,
  });

  final _ParsedCell cell;

  final TextStyle style;

  /// The cell's memoized tree and natural width, or null for the cell being
  /// edited (its source changes with every keystroke, so it is never cached).
  final _CellMemo? memo;

  /// Inline code tokens, in [cell] text coordinates.
  final List<_CellCode> codeRuns;

  /// The cell's painted tree — the same runs the row renderer draws and the
  /// skeleton lays out invisibly, so the two can never disagree about where a
  /// character sits.
  final List<InlineSpan> spans;

  /// Width the cell's *text area* got after the whole table was fitted. For a
  /// column-span anchor this is the sum of the columns it covers, minus its
  /// own outer padding; a covered cell gets zero.
  final double width;

  /// Text alignment. A merge's anchor is centred — that is what 「合并居中」
  /// means — and every other cell follows the divider row.
  final TextAlign align;

  /// The cell box's left edge and full width (padding included), in the
  /// table's own coordinates. Filled by [_measureTable].
  double x = 0;
  double boxWidth = 0;

  /// Where the painted text starts inside the box: always the padding edge.
  ///
  /// The painter itself is laid out at exactly [width] with [align], so it
  /// aligns every line of a wrapped cell; shifting the whole block by an
  /// `advance` (which only describes the unwrapped text) would leave wrapped
  /// cells flush left no matter what the divider asked for.
  double get textX => x + _kCellPad;

  /// Resolved background, or null for an unfilled cell.
  Color? fill;

  /// The painter that draws this cell, or null when the cell is covered.
  TextPainter? painter;

  /// Inline-code bands measured from [painter].
  List<_PaintedChip> chips = const <_PaintedChip>[];

  /// The cached painter entry this cell shares, when it has one. Reused
  /// tables mark it as used before the store sweeps.
  _PaintedCell? painted;

  /// True when a merge anchored elsewhere covers this cell.
  bool covered = false;

  /// The merge this cell takes part in, anchor or covered.
  TableMerge? block;

  /// The merged block's rect in table coordinates. For an ordinary cell this
  /// is just the row's own box.
  double mergeTop = 0;
  double mergeHeight = 0;

  /// Top of the painter in table coordinates: merged text is centred in the
  /// whole block, not in the anchor's row.
  double textTop = 0;

  double get mergeBottom => mergeTop + mergeHeight;
}

class _Table {
  _Table({
    required this.rows,
    required this.width,
    required this.rowHeight,
    required this.dyShift,
    required this.lineOfRow,
    required this.geometry,
    required this.columns,
    required this.columnRoom,
    required this.widthScale,
    required this.rowHeights,
    required this.rowTops,
    required this.merges,
    required List<TextPainter> ownedPainters,
  }) : _owned = ownedPainters;

  final List<_RowData> rows;
  final double width;

  /// Text width the whole table has to live in: the text column minus every
  /// cell's padding. The resize drag spends this room before it starts taking
  /// width away from a neighbouring column.
  final double columnRoom;

  /// Rendering pixels per design pixel stored in `w=…` — the current font size
  /// and accessibility scale relative to the 15.5pt the values were authored
  /// at. A drag converts the pixels it ends on back through this.
  final double widthScale;

  /// The base line height — the height a row would have with no wrapped cell.
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

  /// One box per **source** column, left to right.
  final List<_ColumnBox> columns;

  /// Every row's height: the base line, a wrapped cell's painter, or its share
  /// of a rowspan.
  final List<double> rowHeights;

  /// Each row's top in table coordinates.
  final List<double> rowTops;

  /// The validated merges, anchors only, row-major.
  final List<TableMerge> merges;

  /// Painters this table built and therefore has to dispose (the edited cell,
  /// which is never memoized). Shared painters belong to [_CellMemoStore].
  final List<TextPainter> _owned;

  /// The source column at table-x [x], or null outside the table.
  int? columnAt(double x) {
    for (int c = 0; c < columns.length; c++) {
      final _ColumnBox box = columns[c];
      if (x >= box.x && x < box.right) return c;
    }
    return null;
  }

  /// The merge covering `(row, column)`, anchor included.
  TableMerge? mergeAt(int row, int column) {
    for (final TableMerge m in merges) {
      if (m.covers(row, column)) return m;
    }
    return null;
  }

  /// Whether [row] and [column] are a merge's own top-left cell.
  bool isAnchor(int row, int column, TableMerge m) =>
      m.row == row && m.column == column;

  /// The merge the anchor of row [row] starts at [column], if any.
  TableMerge? anchorAt(int row, int column) {
    for (final TableMerge m in merges) {
      if (m.row == row && m.column == column) return m;
    }
    return null;
  }

  /// The anchor cell for `(row, column)` — the covered cell itself when there
  /// is no merge.
  _CellData anchorCell(int row, int column) {
    final TableMerge? m = mergeAt(row, column);
    if (m == null) return rows[row].data[column];
    return rows[m.row].data[m.column];
  }

  /// Whether the column boundary before [boundary] is interior to a merge on
  /// [row] and must not be drawn.
  bool mergeAcross(int row, int boundary) {
    for (final TableMerge m in merges) {
      if (row < m.row || row > m.lastRow) continue;
      if (m.column < boundary && boundary <= m.lastColumn) return true;
    }
    return false;
  }

  /// Horizontal extent of [m] in table coordinates.
  (double, double) mergeSpan(TableMerge m) {
    final _ColumnBox first = columns[m.column];
    final _ColumnBox last = columns[m.lastColumn];
    return (first.x, last.right);
  }

  /// Marks every memo entry this table still uses, so a reused table survives
  /// the store's sweep even though it was not re-measured.
  void touch(int generation) {
    for (final _RowData row in rows) {
      for (final _CellData cell in row.data) {
        cell.memo?.usedIn = generation;
        cell.painted?.usedIn = generation;
      }
    }
  }

  void dispose() {
    for (final TextPainter painter in _owned) {
      painter.dispose();
    }
    _owned.clear();
  }
}

const double _kCellPad = 8;

/// The chrome a live table hangs around itself: a grip per row and per column,
/// and a `+` on the right and bottom edges.
///
/// The grip is a rounded button holding six dots: the row grip is two columns
/// by three rows (it moves up and down), the column grip three columns by two
/// rows (it moves left and right). The dot grid's orientation is the drag
/// direction.
const double _kGrip = 20;

/// The dot grid inside the button. Painted at this size, centered in [_kGrip]:
/// the button carries the affordance, the dots only name the direction.
const double _kGripDots = 16;

/// The gap between the table's border and the chrome that hangs off it.
const double _kChromeGap = 5;

const double _kAdd = 12;

/// Corner radius of the selection wash around a table block. Small on purpose:
/// a table is a rectangle, and the rounding should read as a softened corner,
/// not as a pill.
const double _kSelectRadius = 2;

/// The narrowest a column is allowed to get once the table is too wide to fit
/// on one line, in logical pixels at [_kReadableColAt] font size.
///
/// A wide table wraps rather than shrinks: 88px is about six Chinese
/// characters at the default 15.5px, enough for a short label to stay on one
/// line and wide enough for a wrapped paragraph to still read in columns.
/// Scaled with the editor's font size and the accessibility text scale.
const double _kReadableCol = 88;

/// Font size [_kReadableCol] was designed at; the readable floor keeps the same
/// number of glyphs as the editor's font size changes.
const double _kReadableColAt = 15.5;

/// Splits `| a | b |` into its cells, keeping each cell's absolute offset.
///
/// The ranges come from [tableCellsOf] — the same parser Tab uses to walk the
/// table, so the two can never disagree about where a cell begins. The text is
/// the **painted** form, not the raw source: the escapes are rendered rather
/// than shown (`\|` is a pipe, `<br>` is a break mark).
List<_ParsedCell> _parseCells(String line, int absStart) => <_ParsedCell>[
  for (final (int a, int b) in tableCellsOf(line))
    _ParsedCell(
      tableCellDisplay(line.substring(a, b)),
      absStart + a,
      tableCellStyleOf(line.substring(a, b)),
    ),
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
  final (int, int)? directive = tableDirectiveRange(raw);
  if (directive == null && !raw.contains(r'\|') && !raw.contains('<br>')) {
    return raw;
  }
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < raw.length; i++) {
    if (directive != null && i == directive.$1) {
      for (int k = directive.$1; k < directive.$2; k++) {
        out.write(_kZeroWidth);
      }
      i = directive.$2 - 1;
      continue;
    }
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
