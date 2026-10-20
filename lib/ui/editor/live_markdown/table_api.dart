part of '../live_markdown.dart';

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
