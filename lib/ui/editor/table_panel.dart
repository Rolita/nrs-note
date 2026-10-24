import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/table_colors.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/markdown_outline.dart';
import '../../core/utils/table_model.dart';
import '../../core/utils/table_selection.dart';
import '../common/app_widgets.dart';
import '../theme/app_color_picker.dart';

/// The table tools column.
///
/// Every command is a value→value function from `markdown_actions`, so this
/// panel can never disagree with the editor's right-click menu for the groups
/// they share: select, rows, columns, alignment, data, summary and the table
/// itself run the same commands, with icons instead of words. The groups are
/// cut into rows of four so a command is found by *where* it lives as much as
/// by its glyph — select next to select, align next to align.
///
/// 「外观」 is the exception: merge, split and the two cell colors live only
/// here. Colors need a palette and a picker, which a context menu cannot show
/// without a second, worse implementation — so they stay one entry point.
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
    final List<TableMerge> merges = tableMergesOf(table);
    final TableRange? range = tableRangeOf(value);
    final TableMerge? merge = _mergeAt(merges, row, column);
    final CellColor? fill = _rangeColor(
      table,
      merges,
      range,
      row,
      column,
      TableCellColorChannel.fill,
    );
    final CellColor? ink = _rangeColor(
      table,
      merges,
      range,
      row,
      column,
      TableCellColorChannel.text,
    );

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

    final List<_Cmd> appearance = <_Cmd>[
      cmd(
        LucideIcons.merge,
        _mergeNeedsSplit(range, merges) ? '先拆分已合并的单元格' : '合并居中',
        mergeTableCells,
        enabled: _canMerge(range, merges),
        active: merge != null,
      ),
      cmd(LucideIcons.split, '拆分单元格', splitTableCell, enabled: merge != null),
      _Cmd(
        icon: LucideIcons.paintBucket,
        tooltip: '填充颜色',
        swatch: fill == null ? null : tableFillColor(p, fill),
        color: _ColorMenu(
          channel: TableCellColorChannel.fill,
          current: fill,
          initial: _pickerSeed(p, fill, TableCellColorChannel.fill),
          onPick: (CellColor? color) => onApply(
            (TextEditingValue v) =>
                setTableCellColor(
                  v,
                  channel: TableCellColorChannel.fill,
                  color: color,
                ) ??
                v,
          ),
        ),
      ),
      _Cmd(
        icon: LucideIcons.baseline,
        tooltip: '文字颜色',
        swatch: ink == null ? null : tableInkColor(p, ink),
        color: _ColorMenu(
          channel: TableCellColorChannel.text,
          current: ink,
          initial: _pickerSeed(p, ink, TableCellColorChannel.text),
          onPick: (CellColor? color) => onApply(
            (TextEditingValue v) =>
                setTableCellColor(
                  v,
                  channel: TableCellColorChannel.text,
                  color: color,
                ) ??
                v,
          ),
        ),
      ),
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
          _Group(label: '外观', commands: appearance),
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
                            ? (hovered
                                  ? p.surface
                                  : p.surface.withValues(alpha: 0.55))
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
                          color: r == 0 && header
                              ? p.textPrimary
                              : p.textSecondary,
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
/// commands that describe the current table (alignment, header, merge).
///
/// The two color commands also carry a 2px line under the glyph and open a
/// palette. The palette is an [OverlayEntry], not a child of the panel: the
/// tools column scrolls, and a 220px card inside a 252px scroller would be
/// clipped at the first scroll.
class _CommandButton extends StatefulWidget {
  const _CommandButton({required this.command});

  final _Cmd command;

  @override
  State<_CommandButton> createState() => _CommandButtonState();
}

class _CommandButtonState extends State<_CommandButton> {
  bool _hovered = false;
  OverlayEntry? _popover;

  @override
  void dispose() {
    _removePopover();
    super.dispose();
  }

  _Cmd get _command => widget.command;

  void _removePopover() {
    _popover?.remove();
    _popover = null;
  }

  void _togglePopover() {
    if (_popover != null) {
      _removePopover();
    } else {
      _openPopover();
    }
  }

  void _openPopover() {
    final _ColorMenu? menu = _command.color;
    if (menu == null) return;
    final RenderObject? box = context.findRenderObject();
    final OverlayState? overlay = Overlay.maybeOf(context);
    if (box is! RenderBox || !box.hasSize || overlay == null) return;
    final RenderObject? frame = overlay.context.findRenderObject();
    if (frame is! RenderBox) return;

    final Rect button = MatrixUtils.transformRect(
      box.getTransformTo(frame),
      Offset.zero & box.size,
    );
    const double width = 220;
    const double margin = 10;
    const double gap = 8;
    // The card is ~125px tall; the estimate only decides whether it opens
    // below the button or above it.
    const double estimated = 130;
    double left = button.center.dx - width / 2;
    left = left.clamp(
      margin,
      math.max(margin, frame.size.width - width - margin),
    );
    double top = button.bottom + gap;
    if (top + estimated > frame.size.height - margin) {
      top = math.max(margin, button.top - estimated - gap);
    }
    final double arrow = (button.center.dx - left).clamp(18.0, width - 18.0);

    _popover = OverlayEntry(
      builder: (BuildContext context) {
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _removePopover,
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: width,
              // The overlay sits above the Navigator's Material. Without one
              // here, every label inherits MaterialApp's fallback text style —
              // the yellow double underline meant for text outside a Material.
              child: Material(
                type: MaterialType.transparency,
                child: _ColorPopover(
                  channel: menu.channel,
                  current: menu.current,
                  arrow: arrow,
                  onPick: (CellColor? color) {
                    _removePopover();
                    menu.onPick(color);
                  },
                  onCustom: () => unawaited(_pickCustom()),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_popover!);
  }

  Future<void> _pickCustom() async {
    final _ColorMenu? menu = _command.color;
    if (menu == null) return;
    _removePopover();
    final Color? picked = await showDialog<Color>(
      context: context,
      barrierColor: context.palette.overlay,
      builder: (BuildContext context) =>
          _TableColorDialog(channel: menu.channel, initial: menu.initial),
    );
    if (!mounted || picked == null) return;
    final int argb = picked.toARGB32();
    menu.onPick(
      CellColor.custom(
        menu.channel == TableCellColorChannel.text
            ? 0xFF000000 | (argb & 0xFFFFFF)
            : argb,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final _Cmd c = widget.command;
    final bool palette = c.color != null;
    final bool enabled = c.onTap != null || palette;
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

    final Widget glyph = palette
        ? SizedBox.expand(
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Icon(c.icon, size: 17, color: foreground),
                Positioned(
                  bottom: 4,
                  child: _SwatchLine(color: c.swatch, tooltip: c.tooltip),
                ),
              ],
            ),
          )
        : Icon(c.icon, size: 17, color: foreground);

    return Tooltip(
      message: c.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: !enabled
              ? null
              : palette
              ? _togglePopover
              : c.onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: AppRadius.smAll,
              border: Border.all(color: border),
            ),
            child: glyph,
          ),
        ),
      ),
    );
  }
}

/// The 2px current-color line under a palette command's glyph.
///
/// It is always present, transparent when the cell has no color, so the two
/// buttons do not shift when a fill is added or cleared. The hairline border
/// keeps a near-white token visible on the raised sidebar.
class _SwatchLine extends StatelessWidget {
  const _SwatchLine({required this.color, required this.tooltip});

  final Color? color;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final Color? swatch = color;
    return Container(
      key: ValueKey<String>('table-swatch-$tooltip'),
      width: 18,
      height: 2,
      decoration: swatch == null
          ? null
          : BoxDecoration(
              color: swatch,
              borderRadius: BorderRadius.circular(1),
              border: Border.all(
                color: Colors.black.withValues(alpha: 0.14),
                width: 0.5,
              ),
            ),
    );
  }
}

/// What a palette command needs to open its popover. Built on every panel
/// rebuild so the swatch and the checkmark always describe the live cell.
class _ColorMenu {
  const _ColorMenu({
    required this.channel,
    required this.current,
    required this.initial,
    required this.onPick,
  });

  final TableCellColorChannel channel;
  final CellColor? current;

  /// The seed for the custom picker when [current] is a theme token.
  final Color initial;

  final ValueChanged<CellColor?> onPick;
}

class _Cmd {
  const _Cmd({
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.active = false,
    this.danger = false,
    this.swatch,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final bool danger;

  /// The underline color; `null` paints the line transparent.
  final Color? swatch;

  /// Present on the two palette commands.
  final _ColorMenu? color;
}

/// The palette: six theme colors, clear, and the custom picker's door.
class _ColorPopover extends StatelessWidget {
  const _ColorPopover({
    required this.channel,
    required this.current,
    required this.arrow,
    required this.onPick,
    required this.onCustom,
  });

  final TableCellColorChannel channel;
  final CellColor? current;

  /// The arrow's center, measured from the card's left edge.
  final double arrow;

  final ValueChanged<CellColor?> onPick;
  final VoidCallback onCustom;

  static const Map<CellColorToken, String> _full = <CellColorToken, String>{
    CellColorToken.gray: '灰色',
    CellColorToken.amber: '琥珀色',
    CellColorToken.green: '绿色',
    CellColorToken.blue: '蓝色',
    CellColorToken.purple: '紫色',
    CellColorToken.red: '红色',
  };

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool fill = channel == TableCellColorChannel.fill;
    final CellColor? custom = current?.custom == null
        ? null
        : CellColor.custom(current!.custom!);

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Container(
          key: const ValueKey<String>('table-color-popover'),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: p.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.outline),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: p.shadow,
                blurRadius: 40,
                offset: const Offset(0, 18),
              ),
              BoxShadow(
                color: p.shadow,
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height: 22,
                child: Row(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Text(
                        fill ? '填充颜色' : '文字颜色',
                        style: TextStyle(
                          fontSize: AppText.caption,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    const Spacer(),
                    _PopoverClear(
                      label: fill ? '无填充' : '无颜色',
                      onTap: () => onPick(null),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  for (int i = 0; i < CellColorToken.values.length; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    Expanded(
                      child: _SwatchItem(
                        color: _colorOf(p, CellColorToken.values[i]),
                        name: _full[CellColorToken.values[i]]!,
                        selected:
                            current ==
                            CellColor.token(CellColorToken.values[i]),
                        onTap: () =>
                            onPick(CellColor.token(CellColorToken.values[i])),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 9),
              Container(height: 1, color: p.outlineSoft),
              const SizedBox(height: 7),
              _CustomColorRow(
                hint: custom == null
                    ? (fill ? '含透明度' : null)
                    : hexText(Color(custom.custom!)),
                onTap: onCustom,
              ),
            ],
          ),
        ),
        Positioned(
          left: arrow - 4.5,
          top: -4.5,
          child: _PopoverArrow(palette: p),
        ),
      ],
    );
  }

  Color _colorOf(AppPalette p, CellColorToken token) {
    final CellColor color = CellColor.token(token);
    return channel == TableCellColorChannel.fill
        ? tableFillColor(p, color)
        : tableInkColor(p, color);
  }
}

class _PopoverClear extends StatelessWidget {
  const _PopoverClear({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: hovered ? p.surfaceSunken : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  LucideIcons.ban,
                  size: 12,
                  color: hovered ? p.textPrimary : p.textSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: hovered ? p.textPrimary : p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One preset: a 26px well that carries a check when it is the cell's current
/// color. The ring is drawn with spread shadows so the well stays inside its
/// sixth of the 220px card.
class _SwatchItem extends StatelessWidget {
  const _SwatchItem({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color check = AppPalette.readableOn(color);
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        return Tooltip(
          message: name,
          waitDuration: const Duration(milliseconds: 500),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Center(
              child: AnimatedContainer(
                duration: AppMotion.fast,
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.08),
                  ),
                  boxShadow: selected
                      ? <BoxShadow>[
                          BoxShadow(color: p.surface, spreadRadius: 1.5),
                          BoxShadow(color: p.accent, spreadRadius: 3),
                        ]
                      : hovered
                      ? <BoxShadow>[
                          BoxShadow(color: p.surface, spreadRadius: 1.5),
                          BoxShadow(color: p.outline, spreadRadius: 3),
                        ]
                      : null,
                ),
                child: selected
                    ? Icon(LucideIcons.check, size: 12, color: check)
                    : null,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CustomColorRow extends StatelessWidget {
  const _CustomColorRow({required this.hint, required this.onTap});

  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        final String? hint = this.hint;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: hovered ? p.surfaceSunken : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  LucideIcons.palette,
                  size: 14,
                  color: hovered ? p.textPrimary : p.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  '自定义…',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: hovered ? p.textPrimary : p.textSecondary,
                  ),
                ),
                if (hint != null) ...<Widget>[
                  const Spacer(),
                  Text(
                    hint,
                    style: TextStyle(
                      fontSize: 10,
                      fontFamily: AppFonts.mono,
                      fontFamilyFallback: AppFonts.monoFallback,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The little rotated square that points back at the button.
class _PopoverArrow extends StatelessWidget {
  const _PopoverArrow({required this.palette});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: math.pi / 4,
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: palette.surfaceRaised,
          border: Border(
            top: BorderSide(color: palette.outline),
            left: BorderSide(color: palette.outline),
          ),
        ),
      ),
    );
  }
}

/// The custom-color card: the existing picker, confirmed in one edit.
///
/// [AppColorPicker] reports every drag frame; the dialog only holds the live
/// value and returns it on 「应用」, so the document sees one directive edit
/// instead of one per frame.
class _TableColorDialog extends StatefulWidget {
  const _TableColorDialog({required this.channel, required this.initial});

  final TableCellColorChannel channel;
  final Color initial;

  @override
  State<_TableColorDialog> createState() => _TableColorDialogState();
}

class _TableColorDialogState extends State<_TableColorDialog> {
  static const double _width = 296;

  late Color _color = widget.initial;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool fill = widget.channel == TableCellColorChannel.fill;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: SizedBox(
              width: _width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surfaceRaised,
                  borderRadius: AppRadius.lgAll,
                  border: Border.all(color: p.outline),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: p.shadow,
                      blurRadius: 34,
                      offset: const Offset(0, 12),
                    ),
                    BoxShadow(
                      color: p.shadow,
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: AppRadius.lgAll,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 13, 16, 2),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              fill
                                  ? LucideIcons.paintBucket
                                  : LucideIcons.baseline,
                              size: 14,
                              color: p.textSecondary,
                            ),
                            const SizedBox(width: 7),
                            Text(
                              fill ? '填充颜色' : '文字颜色',
                              style: TextStyle(
                                fontSize: AppText.ui,
                                fontWeight: FontWeight.w600,
                                color: p.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                        child: Text(
                          fill ? '支持透明度；自定义色写回 #AARRGGBB。' : '自定义色写回 #RRGGBB。',
                          style: TextStyle(
                            fontSize: AppText.caption,
                            height: 1.5,
                            color: p.textTertiary,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                        child: AppColorPicker(
                          color: _color,
                          showAlpha: fill,
                          width: 248,
                          onChanged: (Color color) =>
                              setState(() => _color = color),
                          onChangeEnd: (Color color) {
                            if (mounted) setState(() => _color = color);
                          },
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: p.outlineSoft)),
                        ),
                        child: Row(
                          children: <Widget>[
                            Text(
                              'Esc 取消',
                              style: TextStyle(
                                fontSize: AppText.caption,
                                color: p.textTertiary,
                              ),
                            ),
                            const Spacer(),
                            OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                            const SizedBox(width: AppSpace.sm),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(context).pop(_color),
                              child: const Text('应用'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

TableMerge? _mergeAt(List<TableMerge> merges, int row, int column) {
  for (final TableMerge merge in merges) {
    if (merge.covers(row, column)) return merge;
  }
  return null;
}

/// Whether the selection cuts through an existing merge instead of containing
/// it whole; the tooltip then says why the button is dark.
bool _mergeNeedsSplit(TableRange? range, List<TableMerge> merges) {
  if (range == null) return false;
  for (final TableMerge merge in merges) {
    if (!merge.intersects(
      range.firstRow,
      range.lastRow,
      range.firstColumn,
      range.lastColumn,
    )) {
      continue;
    }
    final bool contained =
        range.firstRow <= merge.row &&
        merge.lastRow <= range.lastRow &&
        range.firstColumn <= merge.column &&
        merge.lastColumn <= range.lastColumn;
    if (!contained) return true;
  }
  return false;
}

/// Whether 「合并居中」 can run: a rectangle of at least two cells that does
/// not touch a merge already on the table.
bool _canMerge(TableRange? range, List<TableMerge> merges) {
  if (range == null || range.cellCount < 2) return false;
  for (final TableMerge merge in merges) {
    if (merge.intersects(
      range.firstRow,
      range.lastRow,
      range.firstColumn,
      range.lastColumn,
    )) {
      return false;
    }
  }
  return true;
}

/// The color both commands should show: the cell's own color, or the one
/// color the selection shares. Mixed colors report `null`, which leaves the
/// swatch line blank and no preset checked.
CellColor? _rangeColor(
  TableBlock table,
  List<TableMerge> merges,
  TableRange? range,
  int row,
  int column,
  TableCellColorChannel channel,
) {
  if (range == null) return _colorAt(table, merges, row, column, channel);
  CellColor? seen;
  bool first = true;
  for (int r = range.firstRow; r <= range.lastRow; r++) {
    for (int c = range.firstColumn; c <= range.lastColumn; c++) {
      final TableMerge? merge = _mergeAt(merges, r, c);
      if (merge != null && !(merge.row == r && merge.column == c)) continue;
      final CellColor? color = _colorAt(table, merges, r, c, channel);
      if (first) {
        seen = color;
        first = false;
      } else if (color != seen) {
        return null;
      }
    }
  }
  return seen;
}

/// The color of one channel on the cell — the anchor's when the cell is
/// covered, because that is the cell the user sees.
CellColor? _colorAt(
  TableBlock table,
  List<TableMerge> merges,
  int row,
  int column,
  TableCellColorChannel channel,
) {
  final TableMerge? merge = _mergeAt(merges, row, column);
  final int r = merge?.row ?? row;
  final int c = merge?.column ?? column;
  final List<TableRow> body = table.bodyRows;
  if (r < 0 || r >= body.length) return null;
  final List<TableCell> cells = body[r].cells;
  if (c < 0 || c >= cells.length) return null;
  final TableCellStyle style = cells[c].style;
  return channel == TableCellColorChannel.fill ? style.fill : style.text;
}

/// Where the custom picker starts: the cell's current color, or a sensible
/// paper/ink default. Text colors are opaque — a transparent glyph color
/// would make the cell's text vanish.
Color _pickerSeed(
  AppPalette p,
  CellColor? color,
  TableCellColorChannel channel,
) {
  if (color == null) {
    return channel == TableCellColorChannel.fill
        ? p.surfaceSunken
        : p.textPrimary;
  }
  final Color resolved = channel == TableCellColorChannel.fill
      ? tableFillColor(p, color)
      : tableInkColor(p, color);
  return channel == TableCellColorChannel.text
      ? Color(0xFF000000 | (resolved.toARGB32() & 0xFFFFFF))
      : resolved;
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
