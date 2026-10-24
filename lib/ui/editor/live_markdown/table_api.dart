part of '../live_markdown.dart';

// `TableChromeKind` / `TableChromeTarget` / `TableRowChrome` 三件套定义在
// `line_layout/line_block_view.dart`：按行排版的自绘行由渲染对象持有，而
// 渲染对象只在 `line_layout/` 里，两边得看到同一份契约。这里只留下纯粹的
// 指针状态。

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
/// The table chrome is deliberately **hover-only**: the row grips appear when
/// the pointer reaches the table's left edge, the column grips when it reaches
/// the top edge, and the `+` buttons when it is on them. The edge is the whole
/// side, not one handle — but only the grip whose row or column is under the
/// pointer shows: sliding along the edge, the single grip follows the pointer,
/// row by row, column by column. A module-level notifier, like
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

/// The narrowest a column may be squeezed to, in logical pixels.
///
/// Layout floor and resize floor are the same number on purpose: a drag may not
/// promise a column width the auto layout would refuse to honour. Without it an
/// empty table — the one 「插入 ▸ 表格」 writes — has a natural width of zero and
/// collapses to a speck, and a one-letter column becomes a sliver.
const double kTableMinColumnWidth = 64;

/// How far from an internal divider a press still counts as "on the line",
/// per side. Deliberately narrower than [kTableChromeSlop]: the band stays
/// inside the cell's 8px padding and never reaches its text.
const double kTableResizeHitSlop = 3;

/// Horizontal travel before a press on a divider turns into a resize drag.
const double kTableResizeStartSlop = 2;

/// The column divider being dragged, so every row of that table can paint its
/// slice of the ghost line without a document edit.
///
/// [localX] is table-local, like the row blocks' own geometry: each row adds
/// its origin and clips itself to its height.
final ValueNotifier<TableResizePreview?> tableResizePreview =
    ValueNotifier<TableResizePreview?>(null);

class TableResizePreview {
  const TableResizePreview({required this.tableId, required this.localX});

  /// Source offset of the table block's first line — identity of the table.
  final int tableId;

  /// Where the divider would end up, in table-local rendering pixels.
  final double localX;
}

/// The text widths of the two columns around a dragged divider, after the
/// pointer travelled [dx] rendering pixels to the right.
///
/// [room] is the whole table's text budget and [others] the width every *other*
/// column already takes; what is left is the spare this pair may grow into.
/// The table grows into that spare first; once it is that wide, the right
/// column yields down to [min]. Dragging left only shrinks the left column —
/// the table gets narrower and the right column does not move. A table already
/// compressed below [min] can only grow the left column, never squeeze it
/// further.
(double, double) resizeColumnPair({
  required double left,
  required double right,
  required double dx,
  required double room,
  double others = 0,
  double min = kTableMinColumnWidth,
}) {
  final double spare = math.max(0, room - others - left - right);
  final double yield = math.max(0, right - min);
  final double lower = math.min(left, min);
  final double upper = left + spare + yield;
  final double nextLeft = (left + dx).clamp(lower, upper);
  final double nextRight = right - math.max(0, nextLeft + right - room + others);
  return (nextLeft, nextRight);
}

/// The last column's text width after its **right outer edge** was dragged
/// [dx] rendering pixels to the right.
///
/// 最右外沿没有右邻列可以让位，所以它只能长到整张表刚好铺满正文为止——
/// [ceiling] 就是这一列在其它列都不动的前提下还能长到的宽度。往左拖则一直
/// 收到 [min]。表格本来就被压缩得比正文窄时，这条边界只能把它拉宽到正文。
double resizeEdgeColumn({
  required double left,
  required double ceiling,
  required double dx,
  double min = kTableMinColumnWidth,
}) => (left + dx).clamp(math.min(left, min), math.max(left, ceiling));
