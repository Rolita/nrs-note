import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/inline_syntax.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/table_model.dart';
import '../../core/utils/table_selection.dart';
import '../common/notices.dart';
import 'line_layout/line_editable_text.dart';

// --------------------------------------------------------------- layout rules
//
// The menu places *itself*, cascading submenus included, from these numbers
// instead of from measured intrinsics. Two reasons, both load-bearing:
//
//  * A submenu's origin is "the top of the row that spawned it", and no single
//    child's intrinsic size can answer that. Measuring would mean laying the
//    tree out twice and still risking a panel that disagrees with the row the
//    pointer is on.
//  * A fixed row height means the geometry in a test is the geometry on screen,
//    so "the submenu opens to the right of the row you hovered" can be asserted
//    rather than eyeballed.

/// Width shared by every panel — root and submenu alike.
const double kMenuPanelWidth = 220;

/// Height of one row.
const double kMenuRowHeight = 28;

/// Height of the hairline between groups: the rule plus the air around it.
const double kMenuSeparatorHeight = 8;

/// Air above the first row and below the last.
const double kMenuPanelPadding = 5;

/// Between a panel and the submenu it opened.
const double kMenuPanelGap = 4;

/// Closest any panel may come to a screen edge.
const double kMenuScreenMargin = 6;

// ------------------------------------------------------------------ the model

/// One line of the right-click menu.
sealed class MenuNode {
  const MenuNode();
}

/// A line that does something when clicked.
class MenuAction extends MenuNode {
  const MenuAction({
    required this.label,
    required this.icon,
    this.leading,
    this.shortcut,
    this.onPressed,
    this.checked = false,
    this.danger = false,
  });

  final String label;

  final IconData icon;

  /// A short glyph drawn in the icon slot instead of [icon] — `H1`…`H6` read
  /// better as themselves than as six identical title marks.
  final String? leading;

  /// Right-aligned hint. Only ever set when that shortcut actually works, so
  /// the menu never teaches a key that does nothing.
  final String? shortcut;

  /// Null means "cannot be used right now" and paints the row greyed out.
  final VoidCallback? onPressed;

  /// Ticks the row — block styles use it to say "this line already is that".
  final bool checked;

  /// Paints the row in the palette's danger colour. Only rows that destroy
  /// something use it, and it is the *only* difference between them and their
  /// neighbours: a red row is still the same height, icon slot and rhythm.
  final bool danger;

  bool get enabled => onPressed != null;
}

/// A read-only line — the selection's statistics, shown without pretending to
/// be clickable.
class MenuInfo extends MenuNode {
  const MenuInfo(this.label);

  final String label;
}

/// A line that reveals [children] in a panel of its own, beside this one.
class MenuSubmenu extends MenuNode {
  const MenuSubmenu({
    required this.label,
    required this.icon,
    required this.children,
  });

  final String label;
  final IconData icon;
  final List<MenuNode> children;
}

/// The hairline between groups.
class MenuSeparator extends MenuNode {
  const MenuSeparator();
}

// ------------------------------------------------------------- entry points

/// Shows [entries] at [globalPosition] — the same panel the editor opens on a
/// right-click, for the parts of the app that are not the editing surface (the
/// vault tree, and the editor's own paper below its last line).
///
/// The menu is a route, so Escape closes it and it paints above everything the
/// way a menu should. [keepFocus] is for the editor: pushing a route moves the
/// primary focus, and the caret has to stay visible underneath the menu, so the
/// field takes it back as soon as the menu is up.
Future<void> showAppMenu(
  BuildContext context, {
  required Offset globalPosition,
  required List<MenuNode> entries,
  FocusNode? keepFocus,
}) {
  final RenderObject? root = Overlay.of(context).context.findRenderObject();
  final Offset anchor = root is RenderBox && root.hasSize
      ? root.globalToLocal(globalPosition)
      : globalPosition;
  final Future<void> shown = Navigator.of(context).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: null,
      barrierDismissible: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder:
          (
            BuildContext routeContext,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) {
            return Material(
              type: MaterialType.transparency,
              child: _EditorContextMenu(
                entries: entries,
                anchor: anchor,
                // `pop` rather than `maybePop`: a row may push its own route
                // (a dialog, say) in the same tap. `maybePop` yields to
                // `willPop`'s future and then abandons the pop because the
                // history's top changed, which would leave this route's
                // invisible barrier swallowing every click underneath it.
                onDismiss: () => Navigator.of(routeContext).pop(),
              ),
            );
          },
    ),
  );
  if (keepFocus != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (keepFocus.context != null) keepFocus.requestFocus();
    });
  }
  return shown;
}

/// Assembles the menu for the current caret / selection.
///
/// Split out from the widget so the *content* can be asserted on its own: which
/// rows exist, which one is ticked, which are greyed out.
List<MenuNode> buildEditorMenu({
  required TextEditingValue value,
  required ValueChanged<MarkdownEditFn> onApply,
  required LineEditableTextState state,
  TableRangeResolver? resolve,
  VoidCallback? onEditCell,
  Future<bool> Function()? onPasteImage,
}) {
  final BlockStyle current = blockStyleOf(markerAt(value));
  final bool hasSelection =
      value.selection.isValid && !value.selection.isCollapsed;
  // 选区里除了一个双链什么都没有时，「新增链接」没有意义——那一行本来就有
  // 链接，该给的出口是「取消链接」。判据与编辑动作共用 [soleWikilink]，
  // 菜单上出现什么、点下去做什么不会各说各话。
  final bool soleWikilinkSelected =
      hasSelection &&
      soleWikilink(
            value.text.substring(value.selection.start, value.selection.end),
          ) !=
          null;

  // The caret's own line decides whether the table rows apply. Offsets are read
  // through the same `lineStartOf` / `lineEndOf` pair as everything else, so a
  // menu that disagrees with the editor about "which line" cannot happen.
  final int caret = value.selection.isValid
      ? value.selection.start
      : value.text.length;
  final String caretLine = value.text.substring(
    lineStartOf(value.text, caret),
    lineEndOf(value.text, caret),
  );
  final bool inTable =
      isTableLine(caretLine) && !isInsideFence(value.text, caret);
  final int columns = tableCellsOf(caretLine).length;
  final TableBlock? table = inTable
      ? TableBlock.parse(value.text, caret)
      : null;
  final int tableRow = table == null ? -1 : table.rowAt(caret);
  final int tableColumn = table == null || tableRow < 0
      ? 0
      : table.columnAt(tableRow, caret);
  final int dataRows = table == null
      ? 0
      : table.bodyRows.length - (table.hasHeader ? 1 : 0);
  final bool canSort = dataRows >= 2;
  bool columnHasNumbers() {
    if (table == null) return false;
    final List<TableRow> body = table.bodyRows;
    for (int r = table.hasHeader ? 1 : 0; r < body.length; r++) {
      final List<TableCell> cells = body[r].cells;
      if (tableColumn < cells.length &&
          numberInCell(cells[tableColumn].text) != null) {
        return true;
      }
    }
    return false;
  }

  final bool numericColumn = columnHasNumbers();

  // The selection decides *how many* rows / columns a command acts on. The
  // resolver is what keeps a column-grip selection a column rather than a
  // geometric cell block.
  final TableRange? range = table == null
      ? null
      : tableRangeOf(value, resolve: resolve);
  final ({TableBlock block, int row, int column, TableCell cell})? active =
      table == null ? null : tableActiveCell(value, resolve: resolve);
  final int rowFrom = range?.firstRow ?? tableRow;
  final int rowTo = range?.lastRow ?? tableRow;
  final int columnFrom = range?.firstColumn ?? tableColumn;
  final int columnTo = range?.lastColumn ?? tableColumn;
  // A column selection covers every row and a row sweep covers every column,
  // but neither makes the *other* axis multi. The labels and the commands have
  // to agree: 「删除 3 行」 must not appear while three columns are selected.
  final int selectedRows = table == null
      ? 0
      : (range == null || range.isColumns ? 1 : range.rowCount);
  final int selectedColumns = table == null
      ? 0
      : (range == null || range.isRows ? 1 : range.columnCount);
  final bool multiRows = selectedRows > 1;
  final bool multiColumns = selectedColumns > 1;
  final List<TableAlign> selectedAligns = table == null
      ? const <TableAlign>[]
      : <TableAlign>[
          for (int c = columnFrom; c <= columnTo; c++)
            c >= 0 && c < table.aligns.length
                ? table.aligns[c]
                : TableAlign.none,
        ];
  final String? tsv = range?.tsv ?? active?.cell.text;
  final bool canFillDown = table != null && (rowTo > rowFrom || rowFrom > 0);
  final bool canFillRight =
      table != null && (columnTo > columnFrom || columnFrom > 0);

  MenuAction style(
    String label,
    IconData icon,
    BlockStyle block, {
    String? shortcut,
  }) {
    return MenuAction(
      label: label,
      icon: icon,
      shortcut: shortcut,
      checked: current == block,
      onPressed: () => onApply(applyBlockStyle(block)),
    );
  }

  MenuAction alignRow(String label, IconData icon, TableAlign align) {
    return MenuAction(
      label: label,
      icon: icon,
      checked:
          selectedAligns.isNotEmpty &&
          selectedAligns.every((TableAlign a) => a == align),
      onPressed: () => onApply(
        (TextEditingValue v) =>
            setTableAlignRange(v, align, resolve: resolve) ?? v,
      ),
    );
  }

  MenuAction tableData(
    String label,
    IconData icon,
    TextEditingValue? Function(TextEditingValue) edit, {
    bool enabled = true,
    String? shortcut,
  }) {
    return MenuAction(
      label: label,
      icon: icon,
      shortcut: shortcut,
      onPressed: enabled
          ? () => onApply((TextEditingValue v) => edit(v) ?? v)
          : null,
    );
  }

  return <MenuNode>[
    if (soleWikilinkSelected)
      MenuAction(
        label: '取消链接',
        icon: LucideIcons.unlink,
        onPressed: () => onApply(removeWikilink()),
      )
    else
      MenuAction(
        label: '新增链接',
        icon: LucideIcons.link,
        onPressed: () => onApply(insertWikilink()),
      ),
    MenuAction(
      label: '新增外部链接',
      icon: LucideIcons.externalLink,
      shortcut: 'Ctrl+K',
      onPressed: () => onApply(insertLink()),
    ),
    const MenuSeparator(),
    MenuSubmenu(
      label: '文本格式',
      icon: LucideIcons.type,
      children: <MenuNode>[
        MenuAction(
          label: '加粗',
          icon: LucideIcons.bold,
          shortcut: 'Ctrl+B',
          onPressed: () => onApply(wrapSelection('**', '**')),
        ),
        MenuAction(
          label: '倾斜',
          icon: LucideIcons.italic,
          shortcut: 'Ctrl+I',
          onPressed: () => onApply(wrapSelection('*', '*')),
        ),
        MenuAction(
          label: '删除线',
          icon: LucideIcons.strikethrough,
          onPressed: () => onApply(wrapSelection('~~', '~~')),
        ),
        MenuAction(
          label: '高亮',
          icon: LucideIcons.highlighter,
          onPressed: () =>
              onApply(wrapSelection('==', '==', placeholder: '高亮')),
        ),
        const MenuSeparator(),
        MenuAction(
          label: '代码',
          icon: LucideIcons.code,
          shortcut: 'Ctrl+E',
          onPressed: () => onApply(wrapSelection('`', '`', placeholder: '代码')),
        ),
        MenuAction(
          label: '数学',
          icon: LucideIcons.sigma,
          onPressed: () =>
              onApply(wrapSelection(r'$', r'$', placeholder: '公式')),
        ),
        // Obsidian's comment syntax, so a note stays portable between the two.
        MenuAction(
          label: '注释',
          icon: LucideIcons.percent,
          onPressed: () =>
              onApply(wrapSelection('%%', '%%', placeholder: '注释')),
        ),
        const MenuSeparator(),
        MenuAction(
          label: '清除格式',
          icon: LucideIcons.removeFormatting,
          onPressed: () => onApply(clearFormatting()),
        ),
      ],
    ),
    MenuSubmenu(
      label: '段落设置',
      icon: LucideIcons.pilcrow,
      children: <MenuNode>[
        style(
          '无序列表',
          LucideIcons.list,
          BlockStyle.bullet,
          shortcut: 'Ctrl+Shift+8',
        ),
        style(
          '有序列表',
          LucideIcons.listOrdered,
          BlockStyle.ordered,
          shortcut: 'Ctrl+Shift+7',
        ),
        style('任务列表', LucideIcons.listTodo, BlockStyle.task),
        const MenuSeparator(),
        for (int level = 1; level <= 6; level++)
          MenuAction(
            label: '$level 级标题',
            icon: LucideIcons.heading,
            leading: 'H$level',
            shortcut: level <= 3 ? 'Ctrl+$level' : null,
            checked: current.headingLevel == level,
            onPressed: () => onApply(
              applyBlockStyle(
                BlockStyle.values[BlockStyle.h1.index + level - 1],
              ),
            ),
          ),
        const MenuSeparator(),
        style(
          '正文',
          LucideIcons.removeFormatting,
          BlockStyle.paragraph,
          shortcut: 'Ctrl+0',
        ),
        style(
          '引用',
          LucideIcons.quote,
          BlockStyle.quote,
          shortcut: 'Ctrl+Shift+Q',
        ),
      ],
    ),
    MenuSubmenu(
      label: '插入',
      icon: LucideIcons.plus,
      children: <MenuNode>[
        MenuAction(
          label: '分割线',
          icon: LucideIcons.minus,
          onPressed: () => onApply(insertDivider()),
        ),
        MenuAction(
          label: '代码块',
          icon: LucideIcons.squareCode,
          shortcut: 'Ctrl+Shift+E',
          onPressed: () => onApply(codeBlock()),
        ),
        MenuAction(
          label: '表格',
          icon: LucideIcons.table,
          onPressed: () => onApply(insertTable()),
        ),
      ],
    ),
    const MenuSeparator(),
    if (inTable) ...<MenuNode>[
      MenuSubmenu(
        label: '表格工具',
        icon: LucideIcons.table,
        children: <MenuNode>[
          MenuSubmenu(
            label: '单元格',
            icon: LucideIcons.grid2x2,
            children: <MenuNode>[
              MenuAction(
                label: '编辑单元格',
                icon: LucideIcons.squarePen,
                shortcut: 'F2',
                onPressed: active == null ? null : onEditCell,
              ),
              MenuAction(
                label: range == null ? '清空单元格' : '清空所选单元格',
                icon: LucideIcons.delete,
                shortcut: range == null ? null : 'Delete',
                onPressed: active == null
                    ? null
                    : () => onApply(
                        (TextEditingValue v) =>
                            tableClearCells(v, resolve: resolve) ?? v,
                      ),
              ),
              const MenuSeparator(),
              tableData(
                '向下填充',
                LucideIcons.arrowDownToLine,
                (TextEditingValue v) =>
                    tableFill(v, down: true, resolve: resolve),
                enabled: canFillDown,
                shortcut: 'Ctrl+D',
              ),
              tableData(
                '向右填充',
                LucideIcons.arrowRightToLine,
                (TextEditingValue v) =>
                    tableFill(v, down: false, resolve: resolve),
                enabled: canFillRight,
                shortcut: 'Ctrl+R',
              ),
              const MenuSeparator(),
              MenuAction(
                label: '复制所选为制表符文本',
                icon: LucideIcons.table,
                shortcut: 'Ctrl+Shift+C',
                onPressed: tsv == null
                    ? null
                    : () => unawaited(
                        Clipboard.setData(ClipboardData(text: tsv)),
                      ),
              ),
              if (range != null) ...<MenuNode>[
                const MenuSeparator(),
                MenuInfo(
                  '${range.rowCount} 行 × ${range.columnCount} 列 · '
                  '${range.stats.filled} 格非空',
                ),
                if (range.stats.hasNumbers)
                  MenuInfo(
                    '合计 ${formatNumber(range.stats.sum!)} · '
                    '平均 ${formatNumber(range.stats.average!)}',
                  ),
              ],
            ],
          ),
          MenuSubmenu(
            label: '行',
            icon: LucideIcons.rows3,
            children: <MenuNode>[
              tableData(
                multiRows ? '上方插入 $selectedRows 行' : '上方插入行',
                LucideIcons.arrowUpToLine,
                (TextEditingValue v) =>
                    tableInsertRows(v, above: true, resolve: resolve),
              ),
              tableData(
                multiRows ? '下方插入 $selectedRows 行' : '下方插入行',
                LucideIcons.arrowDownToLine,
                (TextEditingValue v) =>
                    tableInsertRows(v, above: false, resolve: resolve),
              ),
              tableData(
                multiRows ? '上移 $selectedRows 行' : '上移本行',
                LucideIcons.arrowUp,
                (TextEditingValue v) =>
                    tableMoveRows(v, delta: -1, resolve: resolve),
                enabled: rowFrom > 0,
              ),
              tableData(
                multiRows ? '下移 $selectedRows 行' : '下移本行',
                LucideIcons.arrowDown,
                (TextEditingValue v) =>
                    tableMoveRows(v, delta: 1, resolve: resolve),
                enabled:
                    table != null &&
                    rowTo >= 0 &&
                    rowTo < table.bodyRows.length - 1,
              ),
              tableData(
                multiRows ? '复制 $selectedRows 行到下方' : '复制本行到下方',
                LucideIcons.copy,
                (TextEditingValue v) => tableDuplicateRows(v, resolve: resolve),
                enabled: !isTableDivider(caretLine) || range != null,
              ),
              // The divider is the table's own skeleton: deleting it would turn
              // the grid back into a plain run of pipes, so it cannot be
              // removed. Turning it off is the header switch below, which
              // removes the header row and the divider as one operation.
              tableData(
                multiRows ? '删除 $selectedRows 行' : '删除本行',
                LucideIcons.trash2,
                (TextEditingValue v) => tableDeleteRows(v, resolve: resolve),
                enabled: !isTableDivider(caretLine) || range != null,
              ),
              const MenuSeparator(),
              // A header is the first row *and* the divider under it, so the
              // switch adds or removes both; the rows themselves stay put.
              tableData(
                table != null && table.hasHeader ? '取消表头' : '设为表头',
                LucideIcons.tableProperties,
                (TextEditingValue v) => setTableHeader(
                  v,
                  header: table == null ? false : !table.hasHeader,
                ),
              ),
            ],
          ),
          MenuSubmenu(
            label: '列',
            icon: LucideIcons.columns3,
            children: <MenuNode>[
              tableData(
                multiColumns ? '左侧插入 $selectedColumns 列' : '左侧插入列',
                LucideIcons.arrowLeftToLine,
                (TextEditingValue v) =>
                    tableInsertColumns(v, right: false, resolve: resolve),
              ),
              tableData(
                multiColumns ? '右侧插入 $selectedColumns 列' : '右侧插入列',
                LucideIcons.arrowRightToLine,
                (TextEditingValue v) =>
                    tableInsertColumns(v, right: true, resolve: resolve),
              ),
              tableData(
                multiColumns ? '左移 $selectedColumns 列' : '左移本列',
                LucideIcons.arrowLeft,
                (TextEditingValue v) =>
                    tableMoveColumns(v, delta: -1, resolve: resolve),
                enabled: columnFrom > 0,
              ),
              tableData(
                multiColumns ? '右移 $selectedColumns 列' : '右移本列',
                LucideIcons.arrowRight,
                (TextEditingValue v) =>
                    tableMoveColumns(v, delta: 1, resolve: resolve),
                enabled: columnTo >= 0 && columnTo < columns - 1,
              ),
              tableData(
                multiColumns ? '复制 $selectedColumns 列到右侧' : '复制本列到右侧',
                LucideIcons.copy,
                (TextEditingValue v) =>
                    tableDuplicateColumns(v, resolve: resolve),
              ),
              // Never the last column: a table with no cells is not a table.
              tableData(
                multiColumns ? '删除 $selectedColumns 列' : '删除本列',
                LucideIcons.trash2,
                (TextEditingValue v) => tableDeleteColumns(v, resolve: resolve),
                enabled: selectedColumns < columns,
              ),
            ],
          ),
          MenuSubmenu(
            label: '对齐',
            icon: LucideIcons.alignLeft,
            children: <MenuNode>[
              alignRow('默认对齐', LucideIcons.text, TableAlign.none),
              alignRow('左对齐', LucideIcons.alignLeft, TableAlign.left),
              alignRow('居中', LucideIcons.alignCenter, TableAlign.center),
              alignRow('右对齐', LucideIcons.alignRight, TableAlign.right),
            ],
          ),
          MenuSubmenu(
            label: '数据',
            icon: LucideIcons.sigma,
            children: <MenuNode>[
              tableData(
                '按本列升序',
                LucideIcons.arrowUpDown,
                (TextEditingValue v) => sortTable(v, ascending: true),
                enabled: canSort,
              ),
              tableData(
                '按本列降序',
                LucideIcons.arrowUpDown,
                (TextEditingValue v) => sortTable(v, ascending: false),
                enabled: canSort,
              ),
              const MenuSeparator(),
              tableData('数字列自动右对齐', LucideIcons.ruler, autoAlignTable),
              tableData('转置表格', LucideIcons.arrowLeftRight, transposeTable),
              const MenuSeparator(),
              tableData(
                '追加合计行',
                LucideIcons.sigma,
                (TextEditingValue v) => summarizeTable(v, TableAggregate.sum),
                enabled: numericColumn,
              ),
              tableData(
                '追加平均值行',
                LucideIcons.scale,
                (TextEditingValue v) =>
                    summarizeTable(v, TableAggregate.average),
                enabled: numericColumn,
              ),
              tableData(
                '追加计数行',
                LucideIcons.hash,
                (TextEditingValue v) => summarizeTable(v, TableAggregate.count),
              ),
              tableData(
                '追加最大值行',
                LucideIcons.arrowUp,
                (TextEditingValue v) => summarizeTable(v, TableAggregate.max),
                enabled: numericColumn,
              ),
              tableData(
                '追加最小值行',
                LucideIcons.arrowDown,
                (TextEditingValue v) => summarizeTable(v, TableAggregate.min),
                enabled: numericColumn,
              ),
            ],
          ),
          const MenuSeparator(),
          tableData('删除表格', LucideIcons.trash2, deleteTableAt),
        ],
      ),
      const MenuSeparator(),
    ],
    MenuAction(
      label: '剪切',
      icon: LucideIcons.scissors,
      shortcut: 'Ctrl+X',
      onPressed: hasSelection
          ? () => cutSelectionCells(
              state,
              SelectionChangedCause.toolbar,
              resolve: resolve,
            )
          : null,
    ),
    MenuAction(
      label: '复制',
      icon: LucideIcons.copy,
      shortcut: 'Ctrl+C',
      onPressed: hasSelection
          ? () => copySelectionCells(
              state,
              SelectionChangedCause.toolbar,
              resolve: resolve,
            )
          : null,
    ),
    MenuAction(
      label: '粘贴',
      icon: LucideIcons.clipboardPaste,
      shortcut: 'Ctrl+V',
      onPressed: () => unawaited(
        pasteIntoEditor(
          state,
          plain: false,
          resolve: resolve,
          onPasteImage: onPasteImage,
        ),
      ),
    ),
    MenuAction(
      label: '以纯文本形式粘贴',
      icon: LucideIcons.clipboardType,
      shortcut: 'Ctrl+Shift+V',
      onPressed: () =>
          unawaited(pasteIntoEditor(state, plain: true, resolve: resolve)),
    ),
    const MenuSeparator(),
    MenuAction(
      label: '全选',
      icon: LucideIcons.boxSelect,
      shortcut: 'Ctrl+A',
      onPressed: () => state.selectAll(SelectionChangedCause.toolbar),
    ),
  ];
}

/// Writes the clipboard into the field over the selection, caret after it.
///
/// [plain] is the whole difference between the two paste rows. `粘贴` hands the
/// job to the field, which also brings the caret back into view and tidies its
/// own toolbar; `以纯文本形式粘贴` reads the clipboard here and writes the
/// characters in, so it can never pick up anything but text and never depends on
/// the field's idea of whether a paste is allowed. On a plain-Markdown surface
/// the two land the same text today — keeping the second one explicit rather
/// than aliasing it is what keeps that true if the route above ever changes.
/// Copy, but a table selection copies the **table its cells make** rather than
/// the characters between them — see [tableSelectionMarkdown]. Everything else
/// is the field's own copy, so an ordinary text selection is untouched.
void copySelectionCells(
  LineEditableTextState state,
  SelectionChangedCause cause, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue value = state.textEditingValue;
  final String? table = tableSelectionMarkdown(
    value.text,
    value.selection,
    resolve: resolve,
  );
  if (table == null) {
    state.copySelection(cause);
    return;
  }
  unawaited(Clipboard.setData(ClipboardData(text: table)));
}

/// Cut, with the table rule on **both** sides: the cells go to the clipboard
/// and the cells leave the document.
///
/// The field's own `cutSelection` removes the raw range, which begins and ends
/// wherever the pointer did — a drag that started in the middle of 「链接」
/// took only the characters after it, leaving 「链接」 and a stray row of pipes
/// behind (user: 「为什么还有一行，而且链接两个字没有被删掉」). The cells go to
/// the clipboard and the **same rectangle** leaves the document: cleared in
/// place, or removed row-wise when the sweep covered every column.
void cutSelectionCells(
  LineEditableTextState state,
  SelectionChangedCause cause, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue value = state.textEditingValue;
  if (value.selection.isCollapsed) return;
  final TableRange? range = tableRangeOf(value, resolve: resolve);
  unawaited(
    Clipboard.setData(
      ClipboardData(
        text: range?.markdown ?? value.selection.textInside(value.text),
      ),
    ),
  );
  if (range != null) {
    state.userUpdateTextEditingValue(tableRangeClear(range), cause);
    return;
  }
  final String next =
      value.selection.textBefore(value.text) +
      value.selection.textAfter(value.text);
  state.userUpdateTextEditingValue(
    TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: value.selection.start.clamp(0, next.length),
      ),
    ),
    cause,
  );
}

/// Paste, with the blank line a table needs to stay a table of its own.
///
/// ⛔ Neither route hands the characters to the field any more. `pasteText`
/// writes them in verbatim, so a copied block dropped on the line under a table
/// became four more rows of that table with an empty right-hand column — user:
/// 「如果是在表格的下一行粘贴的话，会把两个表格连在一起」. Both variants read
/// the clipboard here and go through [pasteValue], which is the only place that
/// rule can be applied and the only way Ctrl+V and this menu can agree.
Future<void> pasteIntoEditor(
  LineEditableTextState state, {
  // Kept so the two menu entries stay distinct at the call site: only the
  // format-aware 粘贴 row is handed [onPasteImage]; 纯文本 must never draw one.
  required bool plain,
  TableRangeResolver? resolve,
  Future<bool> Function()? onPasteImage,
}) async {
  final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
  final String? text = data?.text;
  if (text == null || text.isEmpty) {
    // No text to paste: the format-aware row falls back to the image path.
    // If that draws nothing either, the paste is a no-op, as it always was.
    if (onPasteImage != null && state.mounted) await onPasteImage();
    return;
  }
  if (!state.mounted) return;
  final String? refusal = pasteGridRefusal(text);
  if (refusal != null) {
    showSplitNotice(state.context, refusal, kind: NoticeKind.error);
    return;
  }

  state.userUpdateTextEditingValue(
    pasteValue(state.textEditingValue, text, resolve: resolve),
    SelectionChangedCause.toolbar,
  );
}

// ---------------------------------------------------------------- the widget

class _PanelLayout {
  const _PanelLayout({required this.rect, required this.nodes});

  final Rect rect;
  final List<MenuNode> nodes;
}

class _EditorContextMenu extends StatefulWidget {
  const _EditorContextMenu({
    required this.entries,
    required this.anchor,
    required this.onDismiss,
  });

  final List<MenuNode> entries;

  /// Where the pointer went down, in the overlay's own coordinates.
  final Offset anchor;

  final VoidCallback onDismiss;

  @override
  State<_EditorContextMenu> createState() => _EditorContextMenuState();
}

class _EditorContextMenuState extends State<_EditorContextMenu> {
  /// The chain of open submenus: `_open[i]` is the index, inside panel `i`, of
  /// the row whose submenu is showing. Empty means only the root panel is up.
  List<int> _open = const <int>[];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  /// Escape closes the menu.
  ///
  /// `WidgetsApp` already binds Escape to a `DismissIntent`, but that action is
  /// only found when the primary focus sits inside the menu's route — and this
  /// menu deliberately keeps the focus on the field, so the caret, the
  /// selection colour and the clipboard rows stay alive underneath it. The
  /// field's own `DismissIntent` action (hide the selection toolbar) is what the
  /// focus tree finds instead, so the menu has to close itself.
  ///
  /// A raw handler is enough: returning `true` only orders the handlers, it does
  /// not stop the event from reaching the focus tree, so the field still sees
  /// the key and keeps its own behaviour.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    widget.onDismiss();
    return true;
  }

  /// The first [level] entries of the open chain — always a fresh growable list,
  /// because every caller goes on to push an entry onto it. (Handing back
  /// `_open` itself when it is already short enough is what made the very first
  /// click on a submenu throw: `_open` starts as a `const []`.)
  List<int> _prefix(int level) {
    final int n = math.min(level, _open.length);
    return <int>[for (int i = 0; i < n; i++) _open[i]];
  }

  void _hover(int level, int index, MenuNode node) {
    final List<int> next = _prefix(level);
    if (node is MenuSubmenu) next.add(index);
    if (_samePath(next, _open)) return;
    setState(() => _open = next);
  }

  void _tap(int level, int index, MenuNode node) {
    if (node is MenuSubmenu) {
      final List<int> next = _prefix(level);
      // A second click on the row that opened a panel takes it back down, so
      // the menu can be driven by clicking alone. `next` is already the prefix
      // (this row and anything deeper dropped), which is exactly the "close"
      // state — the question is only whether it *was* open.
      final bool open = _open.length > level && _open[level] == index;
      if (!open) next.add(index);
      setState(() => _open = next);
      return;
    }
    if (node is MenuAction) {
      // Tear the menu down first: the edit re-lays out the field underneath, and
      // a panel still on screen would be measured against the old text.
      widget.onDismiss();
      node.onPressed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final List<_PanelLayout> panels = _layout(screen);

    return Stack(
      children: <Widget>[
        // Opaque on purpose. A menu is modal for as long as it is up: a click
        // that misses every panel closes it and stops there, which is also what
        // keeps the field's own right-click handler from toggling the menu
        // straight back open under the closing click.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => widget.onDismiss(),
            onSecondaryTapDown: (_) => widget.onDismiss(),
            child: const SizedBox.expand(),
          ),
        ),
        for (int level = 0; level < panels.length; level++)
          Positioned.fromRect(
            rect: panels[level].rect,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: AppMotion.instant,
              curve: AppMotion.enter,
              builder: (BuildContext context, double t, Widget? child) =>
                  Opacity(opacity: t, child: child),
              child: _MenuPanel(
                nodes: panels[level].nodes,
                level: level,
                openIndex: level < _open.length ? _open[level] : -1,
                onHover: _hover,
                onTap: _tap,
              ),
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------- geometry

  List<_PanelLayout> _layout(Size screen) {
    final List<List<MenuNode>> levels = <List<MenuNode>>[widget.entries];
    List<MenuNode> current = widget.entries;
    for (final int index in _open) {
      if (index < 0 || index >= current.length) break;
      final MenuNode node = current[index];
      if (node is! MenuSubmenu) break;
      levels.add(node.children);
      current = node.children;
    }

    final List<_PanelLayout> out = <_PanelLayout>[];
    double x = widget.anchor.dx;
    double y = widget.anchor.dy;
    for (int level = 0; level < levels.length; level++) {
      final List<MenuNode> nodes = levels[level];
      final double width = kMenuPanelWidth;
      final double height = _panelHeight(nodes);

      if (level == 0) {
        x = _clampTo(x, width, screen.width);
        y = _clampTo(y, height, screen.height);
      } else {
        final _PanelLayout parent = out[level - 1];
        final int row = _open[level - 1].clamp(
          0,
          math.max(0, parent.nodes.length - 1),
        );
        final double rowTop =
            parent.rect.top +
            kMenuPanelPadding +
            _heightBefore(parent.nodes, row);
        final double right = parent.rect.right + kMenuPanelGap;
        final double left = parent.rect.left - kMenuPanelGap - width;
        // Right of the row, unless that runs off the window — then left of the
        // parent, which is what a cascading menu has always done.
        final bool fits = right + width <= screen.width - kMenuScreenMargin;
        x = _clampTo(fits ? right : left, width, screen.width);
        y = _clampTo(rowTop, height, screen.height);
      }
      out.add(
        _PanelLayout(rect: Rect.fromLTWH(x, y, width, height), nodes: nodes),
      );
    }
    return out;
  }

  static bool _samePath(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Keeps a [size]-long edge inside `[kMenuScreenMargin, extent - margin]`.
///
/// The `math.max` matters when a panel is taller than the window: the lower
/// bound would otherwise overtake the upper one and `clamp` would throw.
double _clampTo(double v, double size, double extent) {
  final double max = math.max(
    kMenuScreenMargin,
    extent - kMenuScreenMargin - size,
  );
  return v.clamp(kMenuScreenMargin, math.max(kMenuScreenMargin, max));
}

double _nodeHeight(MenuNode node) =>
    node is MenuSeparator ? kMenuSeparatorHeight : kMenuRowHeight;

double _heightBefore(List<MenuNode> nodes, int index) {
  double height = 0;
  for (int i = 0; i < index && i < nodes.length; i++) {
    height += _nodeHeight(nodes[i]);
  }
  return height;
}

double _panelHeight(List<MenuNode> nodes) =>
    kMenuPanelPadding * 2 + _heightBefore(nodes, nodes.length);

/// The hover / "this submenu is open" fill for a row.
///
/// Derived from the palette rather than written out in hex: a few per cent of
/// the text colour lifts the panel without a second literal that would drift.
Color _menuRowFill(AppPalette p) => Color.alphaBlend(
  p.textPrimary.withValues(alpha: 0.07),
  p.surfaceRaised,
);

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({
    required this.nodes,
    required this.level,
    required this.openIndex,
    required this.onHover,
    required this.onTap,
  });

  final List<MenuNode> nodes;
  final int level;
  final int openIndex;
  final void Function(int level, int index, MenuNode node) onHover;
  final void Function(int level, int index, MenuNode node) onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: p.outline),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: p.shadow,
            blurRadius: 18,
            spreadRadius: -3,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: kMenuPanelPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < nodes.length; i++) _row(context, i, nodes[i]),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int index, MenuNode node) => switch (node) {
    MenuSeparator() => SizedBox(
      height: kMenuSeparatorHeight,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(height: 1, color: context.palette.outlineSoft),
        ),
      ),
    ),
    MenuInfo() => _MenuInfoRow(label: node.label),
    MenuSubmenu() => _MenuRow(
      label: node.label,
      icon: node.icon,
      submenu: true,
      expanded: openIndex == index,
      onHover: () => onHover(level, index, node),
      onTap: () => onTap(level, index, node),
    ),
    MenuAction() => _MenuRow(
      label: node.label,
      icon: node.icon,
      leading: node.leading,
      shortcut: node.shortcut,
      checked: node.checked,
      enabled: node.enabled,
      danger: node.danger,
      onHover: () => onHover(level, index, node),
      onTap: () => onTap(level, index, node),
    ),
  };
}

/// A read-only row: no hover fill, no pointer cursor, low-contrast text. It
/// shares the label column with the actions above and below it so the panel
/// still reads as one list.
class _MenuInfoRow extends StatelessWidget {
  const _MenuInfoRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: kMenuRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 20,
            child: Center(
              child: Icon(LucideIcons.sigma, size: 13, color: p.textTertiary),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.label,
    required this.icon,
    this.leading,
    this.shortcut,
    this.submenu = false,
    this.expanded = false,
    this.checked = false,
    this.enabled = true,
    this.danger = false,
    this.onHover,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final String? leading;
  final String? shortcut;
  final bool submenu;
  final bool expanded;
  final bool checked;
  final bool enabled;
  final bool danger;
  final VoidCallback? onHover;
  final VoidCallback? onTap;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // An open submenu keeps its parent row lit: the highlight is the thread
    // between the row you clicked and the panel that appeared beside it, and it
    // has to survive the pointer crossing the gap between the two.
    final bool lit = (_hovered || widget.expanded) && widget.enabled;
    final Color foreground = widget.enabled
        ? (widget.danger ? p.danger : p.textPrimary)
        : p.textTertiary.withValues(alpha: 0.55);
    final Color iconColor = widget.enabled
        ? (widget.danger ? p.danger : p.textSecondary)
        : foreground;

    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover?.call();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: Container(
          height: kMenuRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          decoration: BoxDecoration(
            color: lit ? _menuRowFill(p) : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 20,
                child: Center(
                  child: widget.leading != null
                      ? Text(
                          widget.leading!,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            fontFamily: AppFonts.mono,
                            fontFamilyFallback: AppFonts.monoFallback,
                            color: iconColor,
                          ),
                        )
                      : Icon(widget.icon, size: 14.5, color: iconColor),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppText.ui, color: foreground),
                ),
              ),
              if (widget.shortcut != null) ...<Widget>[
                const SizedBox(width: AppSpace.md),
                Text(
                  widget.shortcut!,
                  style: TextStyle(
                    fontSize: AppText.mono,
                    fontFamily: AppFonts.mono,
                    fontFamilyFallback: AppFonts.monoFallback,
                    color: p.textTertiary.withValues(alpha: 0.9),
                  ),
                ),
              ],
              if (widget.submenu) ...<Widget>[
                const SizedBox(width: AppSpace.xs + 2),
                Icon(LucideIcons.chevronRight, size: 14, color: p.textTertiary),
              ],
              if (widget.checked) ...<Widget>[
                const SizedBox(width: AppSpace.xs + 2),
                Icon(LucideIcons.check, size: 13, color: p.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
