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
