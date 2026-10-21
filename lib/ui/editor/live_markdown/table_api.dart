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
