import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/markdown_outline.dart';
import '../../core/utils/table_model.dart';
import '../../core/utils/table_selection.dart';

/// The table tools column.
///
/// Every command is a value→value function from `markdown_actions`, so this
/// panel can never disagree with the editor's right-click menu: it is the same
/// commands, with icons instead of words. The groups are the menu's groups, cut
/// into rows of four so a command is found by *where* it lives as much as by
/// its glyph — select next to select, align next to align.
///
/// With the caret outside every table there is nothing to act on, so the panel
/// lists the file's tables instead. Picking one only moves the caret there —
/// which is also what switches the panel back to that table's tools.
class TablePanel extends StatelessWidget {
  const TablePanel({
    super.key,
    required this.width,
    required this.value,
    required this.onApply,
    required this.onJump,
  });

  /// Dragged by the shell's resize handle; the panel only paints it.
  final double width;

  /// The live body value — the caret decides which table the tools act on.
  final ValueListenable<TextEditingValue> value;

  final ValueChanged<MarkdownEditFn> onApply;

  /// Moves the caret to a document offset. With the caret outside every table
  /// the panel lists the file's tables; picking one jumps there.
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return Container(
      width: width,
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(value: value),
          Expanded(
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: value,
              builder: (BuildContext context, TextEditingValue v, _) =>
                  _Body(value: v, onApply: onApply, onJump: onJump),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.value});

  final ValueListenable<TextEditingValue> value;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SizedBox(
      height: AppLayout.panelHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.sm, 0),
        child: Row(
          children: <Widget>[
            Icon(LucideIcons.table, size: 13, color: p.textTertiary),
            const SizedBox(width: 6),
            Text(
              '表格',
              style: TextStyle(
                fontSize: AppText.caption,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: p.textTertiary,
              ),
            ),
            const Spacer(),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: value,
              builder: (BuildContext context, TextEditingValue v, _) {
                final ({int row, int column})? cell = _activeCell(v);
                if (cell == null) return const SizedBox.shrink();
                return Text(
                  '${_columnName(cell.column)}${cell.row + 1}',
                  style: TextStyle(
                    fontSize: AppText.mono,
                    fontFamily: AppFonts.mono,
                    fontFamilyFallback: AppFonts.monoFallback,
                    color: p.textTertiary,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.value,
    required this.onApply,
    required this.onJump,
  });

  final TextEditingValue value;
  final ValueChanged<MarkdownEditFn> onApply;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final int caret = value.selection.isValid
        ? value.selection.start.clamp(0, value.text.length)
        : 0;
    final TableBlock? table = TableBlock.parse(value.text, caret);

    if (table == null) {
      return _TableIndex(tables: TableBlock.allIn(value.text), onJump: onJump);
    }

    final List<TableRow> body = table.bodyRows;
    final ({int row, int column}) cell = _cellOf(table, caret);
    final int row = cell.row;
    final int column = cell.column;
    final int columns = table.columns;
    final int dataRows = body.length - (table.hasHeader ? 1 : 0);
    final bool canSort = dataRows >= 2;
    final bool numeric = _columnHasNumbers(table, column);
    final List<TableAlign> aligns = table.aligns;
    final TableAlign align = column < aligns.length
        ? aligns[column]
        : TableAlign.none;

    _Cmd cmd(
      IconData icon,
      String tooltip,
      TextEditingValue? Function(TextEditingValue) action, {
      bool enabled = true,
      bool active = false,
      bool danger = false,
    }) {
      return _Cmd(
        icon: icon,
        tooltip: tooltip,
        active: active,
        danger: danger,
        onTap: enabled
            ? () => onApply((TextEditingValue v) => action(v) ?? v)
            : null,
      );
    }

    final List<_Cmd> select = <_Cmd>[
      cmd(LucideIcons.rows3, '选中整行', selectTableRow),
      cmd(LucideIcons.columns3, '选中整列', selectTableColumn),
      cmd(LucideIcons.table, '选中整张表', selectTableAll),
    ];

    final List<_Cmd> rows = <_Cmd>[
      cmd(
        LucideIcons.arrowUpToLine,
        '在上方插入行',
        (TextEditingValue v) => tableInsertRows(v, above: true),
      ),
      cmd(
        LucideIcons.arrowDownToLine,
        '在下方插入行',
        (TextEditingValue v) => tableInsertRows(v, above: false),
      ),
      cmd(
        LucideIcons.arrowUp,
        '上移本行',
        (TextEditingValue v) => tableMoveRows(v, delta: -1),
        enabled: row > 0,
      ),
      cmd(
        LucideIcons.arrowDown,
        '下移本行',
        (TextEditingValue v) => tableMoveRows(v, delta: 1),
        enabled: row < body.length - 1,
      ),
      cmd(
        LucideIcons.copy,
        '复制本行',
        (TextEditingValue v) => tableDuplicateRows(v),
      ),
      cmd(
        LucideIcons.trash2,
        '删除本行',
        (TextEditingValue v) => tableDeleteRows(v),
      ),
    ];

    final List<_Cmd> columnsList = <_Cmd>[
      cmd(
        LucideIcons.arrowLeftToLine,
        '在左侧插入列',
        (TextEditingValue v) => tableInsertColumns(v, right: false),
      ),
      cmd(
        LucideIcons.arrowRightToLine,
        '在右侧插入列',
        (TextEditingValue v) => tableInsertColumns(v, right: true),
      ),
      cmd(
        LucideIcons.arrowLeft,
        '左移本列',
        (TextEditingValue v) => tableMoveColumns(v, delta: -1),
        enabled: column > 0,
      ),
      cmd(
        LucideIcons.arrowRight,
        '右移本列',
        (TextEditingValue v) => tableMoveColumns(v, delta: 1),
        enabled: column < columns - 1,
      ),
      cmd(
        LucideIcons.copy,
        '复制本列',
        (TextEditingValue v) => tableDuplicateColumns(v),
      ),
      cmd(
        LucideIcons.trash2,
        '删除本列',
        (TextEditingValue v) => tableDeleteColumns(v),
        enabled: columns > 1,
      ),
    ];

    final List<_Cmd> alignment = <_Cmd>[
      cmd(
        LucideIcons.alignLeft,
        '左对齐',
        (TextEditingValue v) => setTableAlign(v, TableAlign.left),
        active: align == TableAlign.left,
      ),
      cmd(
        LucideIcons.alignCenter,
        '居中对齐',
        (TextEditingValue v) => setTableAlign(v, TableAlign.center),
        active: align == TableAlign.center,
      ),
      cmd(
        LucideIcons.alignRight,
        '右对齐',
        (TextEditingValue v) => setTableAlign(v, TableAlign.right),
        active: align == TableAlign.right,
      ),
      cmd(LucideIcons.ruler, '自动对齐（数字贴右）', autoAlignTable),
    ];

    final List<_Cmd> data = <_Cmd>[
      cmd(
        LucideIcons.arrowUpNarrowWide,
        '按本列升序',
        (TextEditingValue v) => sortTable(v, ascending: true),
        enabled: canSort,
      ),
      cmd(
        LucideIcons.arrowDownWideNarrow,
        '按本列降序',
        (TextEditingValue v) => sortTable(v, ascending: false),
        enabled: canSort,
      ),
      cmd(LucideIcons.filter, '按本列去重', dedupeTableColumn, enabled: canSort),
      cmd(
        LucideIcons.arrowDownToLine,
        '向下填充',
        (TextEditingValue v) => tableFill(v, down: true),
        enabled: row > 0,
      ),
      cmd(
        LucideIcons.arrowRightToLine,
        '向右填充',
        (TextEditingValue v) => tableFill(v, down: false),
        enabled: column > 0,
      ),
    ];

    final List<_Cmd> summary = <_Cmd>[
      cmd(
        LucideIcons.sigma,
        '在表尾追加合计行',
        (TextEditingValue v) => summarizeTable(v, TableAggregate.sum),
        enabled: numeric,
      ),
      cmd(
        LucideIcons.scale,
        '在表尾追加平均行',
        (TextEditingValue v) => summarizeTable(v, TableAggregate.average),
        enabled: numeric,
      ),
      cmd(
        LucideIcons.hash,
        '在表尾追加计数行',
        (TextEditingValue v) => summarizeTable(v, TableAggregate.count),
      ),
      cmd(
        LucideIcons.arrowDown,
        '在表尾追加最小值行',
        (TextEditingValue v) => summarizeTable(v, TableAggregate.min),
        enabled: numeric,
      ),
      cmd(
        LucideIcons.arrowUp,
        '在表尾追加最大值行',
        (TextEditingValue v) => summarizeTable(v, TableAggregate.max),
        enabled: numeric,
      ),
    ];

    final List<_Cmd> tableTools = <_Cmd>[
      cmd(
        LucideIcons.tableProperties,
        table.hasHeader ? '取消表头' : '设为表头',
        (TextEditingValue v) => setTableHeader(v, header: !table.hasHeader),
        active: table.hasHeader,
      ),
      cmd(LucideIcons.arrowLeftRight, '转置表格', transposeTable),
      cmd(LucideIcons.eraser, '清空所选单元格', tableClearCells),
      cmd(LucideIcons.trash2, '删除整张表格', deleteTableAt, danger: true),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: AppSpace.sm),
            child: Text(
              _summaryLine(table, column),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.caption,
                height: 1.4,
                color: p.textTertiary,
              ),
            ),
          ),
          _Group(label: '选择', commands: select),
          _Group(label: '行', commands: rows),
          _Group(label: '列', commands: columnsList),
          _Group(label: '对齐', commands: alignment),
          _Group(label: '数据', commands: data),
          _Group(label: '汇总', commands: summary),
          _Group(label: '表格', commands: tableTools),
        ],
      ),
    );
  }
}

/// Every table in the file, for the times the caret is in prose.
class _TableIndex extends StatelessWidget {
  const _TableIndex({required this.tables, required this.onJump});

  final List<TableBlock> tables;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    if (tables.isEmpty) return _emptyState(p);

    final List<_TableEntry> entries = _entriesOf(tables);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, AppSpace.lg),
      itemCount: entries.length + 1,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              '全文 ${entries.length} 张表 · 点击跳转',
              style: TextStyle(
                fontSize: AppText.caption,
                height: 1.4,
                color: p.textTertiary,
              ),
            ),
          );
        }
        final _TableEntry entry = entries[i - 1];
        return _TableCard(entry: entry, onTap: () => onJump(entry.table.start));
      },
    );
  }
}

/// One table and the heading it sits under, plus the line it starts on.
class _TableEntry {
  const _TableEntry({
    required this.table,
    required this.section,
    required this.line,
  });

  final TableBlock table;

  /// Nearest heading above the table, or `null` when it follows plain prose.
  final Heading? section;

  /// 1-based line number, shown as `L142`.
  final int line;
}

/// Pairs each table with the heading above it.
///
/// Both lists are already in document order, so one walk over the lines is
/// enough: headings are recorded as they pass, tables are stamped with the last
/// one seen. Offsets are compared instead of lines because the tables carry
/// offsets while the headings carry line indices.
List<_TableEntry> _entriesOf(List<TableBlock> tables) {
  final List<_TableEntry> entries = <_TableEntry>[];
  final String text = tables.first.text;
  final List<Heading> headings = extractHeadings(text);

  Heading? section;
  int h = 0;
  int t = 0;
  int line = 1;
  int start = 0;
  while (true) {
    while (h < headings.length && headings[h].line == line - 1) {
      section = headings[h];
      h++;
    }
    while (t < tables.length && tables[t].start == start) {
      entries.add(_TableEntry(table: tables[t], section: section, line: line));
      t++;
    }
    final int next = text.indexOf('\n', start);
    if (next < 0) break;
    start = next + 1;
    line++;
  }
  return entries;
}

/// One card: the heading it belongs to, a real mini grid, and where it is.
///
/// The grid is the whole point of this list — a joined string of header cells
/// reads as one run of text, while a drawn grid shows at a glance how many
/// columns the table has and what they are called.
class _TableCard extends StatefulWidget {
  const _TableCard({required this.entry, required this.onTap});

  final _TableEntry entry;
  final VoidCallback onTap;

  @override
  State<_TableCard> createState() => _TableCardState();
}

class _TableCardState extends State<_TableCard> {
  /// The header plus two data rows: enough to recognise a table, and the same
  /// three rows in the interaction draft.
  static const int _previewRows = 3;

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final TableBlock table = widget.entry.table;
    final List<TableRow> rows = table.bodyRows;
    final List<TableRow> preview = rows.take(_previewRows).toList();
    final Heading? section = widget.entry.section;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.fromLTRB(6, 7, 6, 8),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceRaised : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (section != null) ...<Widget>[
                    Text(
                      '#' * section.level,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontFamily: AppFonts.mono,
                        fontFamilyFallback: AppFonts.monoFallback,
                        color: p.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        section.plainText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppText.caption,
                          color: p.textSecondary,
                        ),
                      ),
                    ),
                  ] else
                    Expanded(
                      child: Text(
                        '（无小节标题）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppText.caption,
                          color: p.textTertiary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              _MiniGrid(
                rows: preview,
                columns: table.columns,
                // A table without a divider has no header row to highlight.
                header: table.hasHeader,
                hovered: _hovered,
              ),
              const SizedBox(height: 4),
              Text(
                '${rows.length} × ${table.columns} · L${widget.entry.line}',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: AppFonts.mono,
                  fontFamilyFallback: AppFonts.monoFallback,
                  color: p.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tiny spreadsheet: the preview rows drawn as cells, not as a joined string.
///
/// Only inner lines are drawn — every cell but the last in a row has a right
/// edge, every row but the last has a bottom edge — so neighbouring borders do
/// not stack into a 2px grid, the same rule the panels' seams follow.
class _MiniGrid extends StatelessWidget {
  const _MiniGrid({
    required this.rows,
    required this.columns,
    required this.header,
    required this.hovered,
  });

  final List<TableRow> rows;
  final int columns;
  final bool header;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.outlineSoft),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int r = 0; r < rows.length; r++)
            Row(
              children: <Widget>[
                for (int c = 0; c < columns; c++)
                  Expanded(
                    child: Container(
                      height: 18,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        // The header row reads as a header, not as data.
                        color: r == 0 && header
                            ? (hovered ? p.surface : p.surface.withValues(alpha: 0.55))
                            : null,
                        border: Border(
                          right: c == columns - 1
                              ? BorderSide.none
                              : BorderSide(color: p.outlineSoft),
                          bottom: r == rows.length - 1
                              ? BorderSide.none
                              : BorderSide(color: p.outlineSoft),
                        ),
                      ),
                      child: Text(
                        _cellText(rows[r], c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.5,
                          height: 1.2,
                          fontFamily: AppFonts.mono,
                          fontFamilyFallback: AppFonts.monoFallback,
                          color: r == 0 && header ? p.textPrimary : p.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  String _cellText(TableRow row, int column) {
    if (column >= row.cells.length) return '';
    return row.cells[column].text.trim();
  }
}

Widget _emptyState(AppPalette p) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.surfaceSunken,
              borderRadius: AppRadius.lgAll,
            ),
            child: Icon(LucideIcons.table, size: 20, color: p.textTertiary),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            '没有表格',
            style: TextStyle(
              fontSize: AppText.ui,
              fontWeight: FontWeight.w600,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '这篇笔记还没有表格。\n用「|」分隔单元格就会生成一张。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppText.caption,
              height: 1.7,
              color: p.textTertiary,
            ),
          ),
        ],
      ),
    ),
  );
}

/// One titled row group: the name on the left, a hairline to the right edge.
class _Group extends StatelessWidget {
  const _Group({required this.label, required this.commands});

  final String label;
  final List<_Cmd> commands;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 24,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: p.textSecondary,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(child: Container(height: 1, color: p.outlineSoft)),
                ],
              ),
            ),
          ),
          for (int i = 0; i < commands.length; i += 4)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 4 : 3),
              child: Row(
                children: <Widget>[
                  for (int j = 0; j < 4; j++) ...<Widget>[
                    if (j > 0) const SizedBox(width: 3),
                    Expanded(
                      child: i + j < commands.length
                          ? _CommandButton(command: commands[i + j])
                          : const SizedBox(height: 32),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One 4-across button: a 17px glyph, a tooltip, and a lit state for the
/// commands that describe the current table (alignment, header).
class _CommandButton extends StatefulWidget {
  const _CommandButton({required this.command});

  final _Cmd command;

  @override
  State<_CommandButton> createState() => _CommandButtonState();
}

class _CommandButtonState extends State<_CommandButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final _Cmd c = widget.command;
    final bool enabled = c.onTap != null;
    final Color foreground;
    if (!enabled) {
      foreground = p.textTertiary.withValues(alpha: 0.45);
    } else if (c.danger) {
      foreground = p.danger;
    } else if (c.active) {
      foreground = p.accent;
    } else {
      foreground = p.textSecondary;
    }

    final Color background = !enabled
        ? Colors.transparent
        : c.active
        ? p.accentSoft
        : (_hovered ? p.surfaceRaised : Colors.transparent);
    final Color border = !enabled || (!_hovered && !c.active)
        ? Colors.transparent
        : (c.active ? p.accent.withValues(alpha: 0.28) : p.outlineSoft);

    return Tooltip(
      message: c.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: c.onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: AppRadius.smAll,
              border: Border.all(color: border),
            ),
            child: Icon(c.icon, size: 17, color: foreground),
          ),
        ),
      ),
    );
  }
}

class _Cmd {
  const _Cmd({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final bool danger;
}

({int row, int column}) _cellOf(TableBlock block, int offset) {
  final List<TableRow> body = block.bodyRows;
  final (int r, int c) = tableCellAt(block, offset, extent: false);
  if (body.isEmpty) return (row: 0, column: 0);
  return (row: r.clamp(0, body.length - 1), column: c);
}

({int row, int column})? _activeCell(TextEditingValue v) {
  if (!v.selection.isValid) return null;
  final int caret = v.selection.start.clamp(0, v.text.length);
  final TableBlock? block = TableBlock.parse(v.text, caret);
  if (block == null) return null;
  return _cellOf(block, caret);
}

bool _columnHasNumbers(TableBlock table, int column) {
  final List<TableRow> body = table.bodyRows;
  for (int r = table.hasHeader ? 1 : 0; r < body.length; r++) {
    final List<TableCell> cells = body[r].cells;
    if (column < cells.length && numberInCell(cells[column].text) != null) {
      return true;
    }
  }
  return false;
}

/// `第 2 张表 · 4 × 4 · 「变化」列` — enough to know which table the tools act on.
String _summaryLine(TableBlock table, int column) {
  final List<TableRow> body = table.bodyRows;
  final int number = _tableNumber(table.text, table.start);
  final StringBuffer out = StringBuffer(
    '第 $number 张表 · ${body.length} × ${table.columns}',
  );
  if (table.hasHeader && body.isNotEmpty && column < body.first.cells.length) {
    final String title = body.first.cells[column].text.trim();
    if (title.isNotEmpty) out.write(' · 「$title」列');
  }
  return out.toString();
}

/// The 1-based position of the table that starts at [start].
int _tableNumber(String text, int start) {
  int count = 0;
  bool inTable = false;
  int offset = 0;
  for (final String line in text.split('\n')) {
    final bool row = isRowLine(line);
    if (row && !inTable) {
      if (offset >= start) break;
      count++;
    }
    inTable = row;
    offset += line.length + 1;
  }
  return count == 0 ? 1 : count;
}

String _columnName(int index) {
  int i = index + 1;
  String name = '';
  while (i > 0) {
    final int rem = (i - 1) % 26;
    name = String.fromCharCode(65 + rem) + name;
    i = (i - 1) ~/ 26;
  }
  return name;
}
