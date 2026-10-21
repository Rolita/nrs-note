import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/core/utils/table_selection.dart';
import 'package:nrs/ui/editor/editor_context_menu.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// The P0 correctness matrix for tables: undo, paste, IME, escapes, structural
/// boundaries, text outside the block, paste limits and menu state.
///
/// Everything here drives the same widgets a user does. Structural commands
/// are applied exactly the way `_applyEdit` applies a context-menu row — one
/// `TextEditingValue` write — so an undo step proves the command was not split
/// into several edits.
void main() {
  const String table =
      '| 名称 | 数量 | 备注 |\n'
      '| --- | --- | --- |\n'
      '| 甲 | 1 | 一 |\n'
      '| 乙 | 2 | 二 |';

  final int jia = table.indexOf('甲');
  final int one = table.indexOf('1');
  final int two = table.indexOf('2');
  final int noteTwo = table.indexOf('二');

  // Body rows 1–2 × columns 0–1: a plain cell rectangle.
  final TextSelection bodyCells = TextSelection(
    baseOffset: jia,
    extentOffset: two + 1,
  );
  // The first body row, columns 0–1: a one-row block, not a whole row.
  final TextSelection firstBodyRow = TextSelection(
    baseOffset: jia,
    extentOffset: one + 1,
  );

  const String clipboardTwoByTwo = 'x\ty\nz\tw';

  final List<_UndoCase> undoCases = <_UndoCase>[
    _UndoCase(
      'insert a row above',
      (TextEditingValue v) => editTable(v, TableEdit.rowAbove),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'insert a row below',
      (TextEditingValue v) => editTable(v, TableEdit.rowBelow),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'delete a row',
      (TextEditingValue v) => editTable(v, TableEdit.deleteRow),
      selection: TextSelection.collapsed(offset: two),
    ),
    _UndoCase(
      'move a row up',
      (TextEditingValue v) => tableMoveRows(v, delta: -1),
      selection: TextSelection.collapsed(offset: two),
    ),
    _UndoCase(
      'move a row down',
      (TextEditingValue v) => tableMoveRows(v, delta: 1),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'duplicate a row',
      tableDuplicateRows,
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'insert a column on the left',
      (TextEditingValue v) => editTable(v, TableEdit.columnLeft),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'insert a column on the right',
      (TextEditingValue v) => editTable(v, TableEdit.columnRight),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'delete a column',
      (TextEditingValue v) => editTable(v, TableEdit.deleteColumn),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'move a column left',
      (TextEditingValue v) => tableMoveColumns(v, delta: -1),
      selection: TextSelection.collapsed(offset: noteTwo),
    ),
    _UndoCase(
      'move a column right',
      (TextEditingValue v) => tableMoveColumns(v, delta: 1),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'duplicate a column',
      tableDuplicateColumns,
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'set the column alignment',
      (TextEditingValue v) => setTableAlign(v, TableAlign.center),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'sort the rows ascending',
      (TextEditingValue v) => sortTable(v, ascending: true),
      // Column 1 (1, 2) is already ascending; sort the 甲/乙 column instead.
      selection: TextSelection.collapsed(offset: jia),
    ),
    _UndoCase(
      'sort the rows descending',
      (TextEditingValue v) => sortTable(v, ascending: false),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'transpose the table',
      transposeTable,
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'append a sum row',
      (TextEditingValue v) => summarizeTable(v, TableAggregate.sum),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'append an average row',
      (TextEditingValue v) => summarizeTable(v, TableAggregate.average),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'append a count row',
      (TextEditingValue v) => summarizeTable(v, TableAggregate.count),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'append a max row',
      (TextEditingValue v) => summarizeTable(v, TableAggregate.max),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'append a min row',
      (TextEditingValue v) => summarizeTable(v, TableAggregate.min),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'fill down over a block',
      (TextEditingValue v) => tableFill(v, down: true),
      selection: bodyCells,
    ),
    _UndoCase(
      'fill right over a block',
      (TextEditingValue v) => tableFill(v, down: false),
      selection: firstBodyRow,
    ),
    _UndoCase('clear a block of cells', tableClearCells, selection: bodyCells),
    _UndoCase(
      'commit the F2 cell editor',
      (TextEditingValue v) => setTableCellText(
        v,
        tableStart: 0,
        row: 1,
        column: 1,
        text: '42',
      ),
      selection: TextSelection.collapsed(offset: one),
    ),
    _UndoCase(
      'paste a grid over a rectangle',
      (TextEditingValue v) => pasteValue(v, clipboardTwoByTwo),
      selection: bodyCells,
    ),
    _UndoCase(
      'cut a rectangle',
      (TextEditingValue v) {
        final TableRange? range = TableRange.fromSelection(
          v.text,
          v.selection,
        );
        return range == null ? null : tableRangeClear(range);
      },
      selection: bodyCells,
    ),
  ];

  group('undo matrix', () {
    for (final _UndoCase c in undoCases) {
      testWidgets('${c.name} is one undo step', (WidgetTester tester) async {
        final MarkdownSourceController controller = await pumpEditor(
          tester,
          table,
        );
        await expectOneUndo(
          tester,
          controller,
          c.edit,
          selection: c.selection,
        );
      });
    }

    testWidgets('typing over a rectangle is one undo step', (
      WidgetTester tester,
    ) async {
      final MarkdownSourceController controller = await pumpEditor(
        tester,
        table,
      );
      await tester.pump(const Duration(milliseconds: 600));
      controller.selection = bodyCells;
      await tester.pump(const Duration(milliseconds: 600));

      final String before = controller.text;
      tester.testTextInput.updateEditingValue(
        replacementFor(controller, 'x'),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.text, isNot(before));

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(controller.text, before, reason: '撤销没有一次回到键入前');
    });
  });

  group('rectangle paste end to end', () {
    const String host =
        '| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |';

    late MarkdownSourceController controller;
    String? clipboard;

    Future<void> mount(WidgetTester tester, String text) async {
      controller = MarkdownSourceController(text: text);
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      clipboard = null;

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard =
                  (call.arguments as Map<Object?, Object?>)['text'] as String?;
            case 'Clipboard.getData':
              return <String, Object?>{'text': clipboard};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppPalette.light),
          home: Scaffold(
            body: MarkdownEditor(
              controller: controller,
              focusNode: focus,
              scrollController: ScrollController(),
              fontSize: 15.5,
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
    }

    Future<void> select(tester, TextSelection selection) async {
      controller.selection = selection;
      await tester.pump(const Duration(milliseconds: 600));
    }

    Future<void> paste(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pumpAndSettle();
    }

    testWidgets('a TSV paste replaces the rectangle at the same size', (
      WidgetTester tester,
    ) async {
      await mount(tester, host);
      await select(
        tester,
        TextSelection(
          baseOffset: host.indexOf('a'),
          extentOffset: host.indexOf('d') + 1,
        ),
      );
      clipboard = clipboardTwoByTwo;

      final String before = controller.text;
      await paste(tester);

      expect(
        controller.text,
        '| h1 | h2 |\n| --- | --- |\n| x | y |\n| z | w |',
      );

      await tester.pump(const Duration(milliseconds: 600));
      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(controller.text, before, reason: '一次粘贴应该只占一步撤销');
    });

    testWidgets('a larger grid grows the table down and right', (
      WidgetTester tester,
    ) async {
      await mount(tester, host);
      await select(
        tester,
        TextSelection(
          baseOffset: host.indexOf('a'),
          extentOffset: host.indexOf('d') + 1,
        ),
      );
      clipboard = 'a\tb\tc\nd\te\tf\ng\th\ti';

      await paste(tester);

      expect(
        controller.text,
        '| h1 | h2 |  |\n'
        '| --- | --- | --- |\n'
        '| a | b | c |\n'
        '| d | e | f |\n'
        '| g | h | i |',
      );
      expect(TableBlock.parse(controller.text, 0)!.columns, 3);
    });

    testWidgets('a pasted Markdown table keeps its own header row', (
      WidgetTester tester,
    ) async {
      await mount(tester, host);
      await select(
        tester,
        TextSelection(
          baseOffset: host.indexOf('a'),
          extentOffset: host.indexOf('d') + 1,
        ),
      );
      clipboard = '| 1 | 2 |\n| --- | --- |\n| 3 | 4 |';

      await paste(tester);

      expect(
        controller.text,
        '| h1 | h2 |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |',
      );
    });

    testWidgets('plain text in a rectangle escapes breaks and pipes', (
      WidgetTester tester,
    ) async {
      await mount(tester, host);
      await select(
        tester,
        TextSelection(
          baseOffset: host.indexOf('a'),
          extentOffset: host.indexOf('d') + 1,
        ),
      );
      clipboard = '第一行\n第二行|管道';

      await paste(tester);

      expect(
        controller.text,
        '| h1 | h2 |\n'
        '| --- | --- |\n'
        '| 第一行<br>第二行\\|管道 |  |\n'
        '|  |  |',
      );
      final TableBlock block = TableBlock.parse(controller.text, 0)!;
      expect(block.bodyRows[1].cells[0].text, '第一行\n第二行|管道');
      expect(block.columns, 2);
    });

    testWidgets('a paste over a whole-row selection covers its cells', (
      WidgetTester tester,
    ) async {
      await mount(tester, host);
      final TableBlock block = TableBlock.parse(host, 0)!;
      final TableRange row = TableRange.rowsOf(block, 1, 1);
      await select(tester, row.toTextSelection());
      clipboard = clipboardTwoByTwo;

      await paste(tester);

      expect(
        controller.text,
        '| h1 | h2 |\n| --- | --- |\n| x | y |\n| z | w |',
      );
    });

    testWidgets('a paste over a whole-column selection grows from its anchor', (
      WidgetTester tester,
    ) async {
      final TableBlock block = TableBlock.parse(host, 0)!;
      // The last column, so a 2-column paste has to grow the table as well.
      final TableRange column = TableRange.columnsOf(block, 1, 1);
      final TextEditingValue pasted = pasteValue(
        TextEditingValue(text: host, selection: column.toTextSelection()),
        'x\ty\nz\tw',
        resolve: (String text, TextSelection selection) => column,
      );

      expect(
        pasted.text,
        '| h1 | x | y |\n'
        '| --- | --- | --- |\n'
        '| a | z | w |\n'
        '| c |  |  |',
      );
    });
  });

  group('IME over a rectangle', () {
    const String imeTable =
        '| a | b |\n| --- | --- |\n| c | d |\n| e | f |';

    testWidgets('composition never breaks the grid, and commits once', (
      WidgetTester tester,
    ) async {
      final MarkdownSourceController controller = await pumpEditor(
        tester,
        imeTable,
      );
      await tester.pump(const Duration(milliseconds: 600));
      final TextSelection body = TextSelection(
        baseOffset: imeTable.indexOf('c'),
        extentOffset: imeTable.indexOf('f') + 1,
      );
      controller.selection = body;
      await tester.pump(const Duration(milliseconds: 600));
      final String before = controller.text;

      void expectTableShape() {
        final TableBlock? block = TableBlock.parse(controller.text, 0);
        expect(block, isNotNull, reason: '组合期间表格被写坏了');
        expect(block!.columns, 2);
        expect(block.bodyRows.length, 3);
        for (final TableRow row in block.rows) {
          expect(
            tableCellsOf(controller.text.substring(row.start, row.end)).length,
            2,
          );
        }
      }

      tester.testTextInput.updateEditingValue(
        composingFor(controller, 'n'),
      );
      await tester.pump();
      expectTableShape();

      tester.testTextInput.updateEditingValue(
        composingFor(controller, 'ni'),
      );
      await tester.pump();
      expectTableShape();

      tester.testTextInput.updateEditingValue(
        replacementFor(controller, '你'),
      );
      await tester.pump();
      expectTableShape();

      // The rectangle is consumed once: the active cell holds the committed
      // text, every other selected cell is empty, the header is untouched.
      final TableGrid grid = TableGrid.fromBlock(
        TableBlock.parse(controller.text, 0)!,
      );
      expect(grid.rows[0], <String>['a', 'b']);
      expect(grid.rows[1], <String>['你', '']);
      // The 2×2 rectangle was consumed: the row below is cleared too.
      expect(grid.rows[2], <String>['', '']);

      await tester.pump(const Duration(milliseconds: 600));
      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(controller.text, before, reason: '一次 IME 提交应该只占一步撤销');
    });
  });

  group('escapes round-trip', () {
    const String source =
        '| 表达式 | 说明 | 代码 |\n'
        '| --- | --- | --- |\n'
        '| a \\| b | 换行<br>第二行 | `x \\| y` |\n'
        '| 反斜杠 \\\\ | 尾随 |  |';

    test('copy → paste rebuilds the same grid, byte for byte on the way back', () {
      final TableBlock block = TableBlock.parse(source, 0)!;
      final TableRange all = TableRange(
        block: block,
        anchorRow: 0,
        anchorColumn: 0,
        focusRow: block.bodyRows.length - 1,
        focusColumn: block.columns - 1,
      );
      final List<List<String>> original = TableGrid.fromBlock(block).rows;

      final String copied = all.markdown;
      expect(copied, contains(r'\|'));
      expect(copied, contains('<br>'));
      expect(copied, contains(r'`x \| y`'));

      final TextEditingValue pasted = pasteValue(
        const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        ),
        copied,
      );
      final TableBlock again = TableBlock.parse(pasted.text, 0)!;
      expect(TableGrid.fromBlock(again).rows, original);

      final TableRange allAgain = TableRange(
        block: again,
        anchorRow: 0,
        anchorColumn: 0,
        focusRow: again.bodyRows.length - 1,
        focusColumn: again.columns - 1,
      );
      expect(allAgain.markdown, copied, reason: '再次复制不应重复转义');
    });

    test('the painted cell keeps the source length and never re-escapes', () {
      const String raw = r'a \| b<br>c';
      final String display = tableCellDisplay(raw);
      expect(display.length, raw.length);
      expect(display.replaceAll('\u200b', ''), 'a | b↵c');
      expect(display.contains(r'\|'), isFalse);
      expect(display.contains('<br>'), isFalse);
      expect(unescapeCell(raw), 'a | b\nc');
    });
  });

  group('structural boundaries', () {
    test('deleting the last body row leaves a legal header-only table', () {
      const String text = '| a | b |\n| --- | --- |\n| c | d |';
      final TableBlock block = TableBlock.parse(text, 0)!;
      final TableEditResult result = TableCommands.deleteRow(block, 1);

      expect(result.text, '| a | b |\n| --- | --- |');
      final TableBlock fresh = TableBlock.parse(result.text, 0)!;
      expect(fresh.columns, 2);
      expect(fresh.bodyRows.length, 1);
      expect(fresh.bodyRows.single.cells.map((TableCell c) => c.text), <String>[
        'a',
        'b',
      ]);
    });

    test('a whole-row sweep of the only remaining row deletes the table', () {
      const String text = '| a | b |\n| --- | --- |';
      final TableBlock block = TableBlock.parse(text, 0)!;
      final TableRange onlyRow = TableRange.rowsOf(block, 0, 0);

      expect(tableRangeClear(onlyRow).text, '');
    });

    test('deleting the header promotes the next row and keeps the divider', () {
      const String text =
          '| a | b |\n| --- | --- |\n| c | d |\n| e | f |';
      final TableBlock block = TableBlock.parse(text, 0)!;
      final TableEditResult result = TableCommands.deleteRow(block, 0);

      expect(result.text, '| c | d |\n| --- | --- |\n| e | f |');
      final TableBlock fresh = TableBlock.parse(result.text, 0)!;
      expect(fresh.hasHeader, isTrue);
      expect(TableGrid.fromBlock(fresh).rows, <List<String>>[
        <String>['c', 'd'],
        <String>['e', 'f'],
      ]);
    });

    test('the last column cannot be deleted', () {
      const String text = '| a |\n| --- |\n| b |';
      final TableBlock block = TableBlock.parse(text, 0)!;
      final TextEditingValue value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.indexOf('b')),
      );

      expect(block.columns, 1);
      expect(
        TableCommands.deleteColumn(block, row: 1, column: 0),
        isNull,
      );
      expect(tableDeleteColumns(value), isNull);

      // The keyboard's structural delete goes through the range, not the menu.
      final TableRange column = TableRange.columnsOf(block, 0, 0);
      expect(tableRangeClear(column).text, text);
    });

    test('deleting a table takes no neighbouring text or blank line', () {
      const String doc = '前言\n| a | b |\n| --- | --- |\n后记';
      final TextEditingValue value = TextEditingValue(
        text: doc,
        selection: TextSelection.collapsed(offset: doc.indexOf('a')),
      );
      final TextEditingValue next = deleteTableAt(value)!;

      expect(next.text, '前言\n后记');
      expect(next.text.contains('|'), isFalse);
    });
  });

  group('text outside the table', () {
    // Two body rows with an unsorted second column: every structural command
    // below has somewhere to move, and sorting really reorders.
    const String first = '| a | b |\n| --- | --- |\n| c | f |\n| e | d |';
    const String second = '| x | y |\n| --- | --- |\n| 1 | 2 |';
    const String doc = '前言\n$first\n后记\n\n$second';
    const String prefix = '前言\n';

    final int a = doc.indexOf('a');
    final int b = doc.indexOf('b');
    final int c = doc.indexOf('c');
    final int d = doc.indexOf('d');

    final List<_UndoCase> commands = <_UndoCase>[
      _UndoCase(
        'insert row above',
        (TextEditingValue v) => editTable(v, TableEdit.rowAbove),
        selection: TextSelection.collapsed(offset: a),
      ),
      _UndoCase(
        'insert row below',
        (TextEditingValue v) => editTable(v, TableEdit.rowBelow),
        selection: TextSelection.collapsed(offset: a),
      ),
      _UndoCase(
        'delete row',
        (TextEditingValue v) => editTable(v, TableEdit.deleteRow),
        selection: TextSelection.collapsed(offset: c),
      ),
      _UndoCase(
        'move row down',
        (TextEditingValue v) => tableMoveRows(v, delta: 1),
        selection: TextSelection.collapsed(offset: c),
      ),
      _UndoCase(
        'duplicate row',
        tableDuplicateRows,
        selection: TextSelection.collapsed(offset: c),
      ),
      _UndoCase(
        'insert column left',
        (TextEditingValue v) => editTable(v, TableEdit.columnLeft),
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'insert column right',
        (TextEditingValue v) => editTable(v, TableEdit.columnRight),
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'delete column',
        (TextEditingValue v) => editTable(v, TableEdit.deleteColumn),
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'move column right',
        (TextEditingValue v) => tableMoveColumns(v, delta: 1),
        // Column 0: the header's last column has nowhere to go.
        selection: TextSelection.collapsed(offset: c),
      ),
      _UndoCase(
        'duplicate column',
        tableDuplicateColumns,
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'set alignment',
        (TextEditingValue v) => setTableAlign(v, TableAlign.center),
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'sort',
        (TextEditingValue v) => sortTable(v, ascending: true),
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'transpose',
        transposeTable,
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'append a summary row',
        (TextEditingValue v) => summarizeTable(v, TableAggregate.count),
        selection: TextSelection.collapsed(offset: b),
      ),
      _UndoCase(
        'clear a rectangle',
        (TextEditingValue v) {
          final TableRange? range = TableRange.fromSelection(
            v.text,
            v.selection,
          );
          return range == null ? null : tableRangeClear(range);
        },
        selection: TextSelection(baseOffset: c, extentOffset: d + 1),
      ),
      _UndoCase(
        'paste a grid',
        (TextEditingValue v) => pasteValue(v, clipboardTwoByTwo),
        selection: TextSelection(baseOffset: c, extentOffset: d + 1),
      ),
      _UndoCase(
        'commit an F2 edit',
        (TextEditingValue v) => setTableCellText(
          v,
          tableStart: first.length + prefix.length,
          row: 1,
          column: 0,
          text: '42',
        ),
        selection: TextSelection.collapsed(offset: c),
      ),
      _UndoCase(
        'delete the table',
        deleteTableAt,
        selection: TextSelection.collapsed(offset: a),
      ),
    ];

    for (final _UndoCase command in commands) {
      test('${command.name} leaves the text around it byte-identical', () {
        final TextEditingValue before = TextEditingValue(
          text: doc,
          selection: command.selection!,
        );
        final TextEditingValue next = command.edit(before)!;

        expect(next.text.startsWith(prefix), isTrue);
        expect(next.text.endsWith(second), isTrue);
        expect(
          next.text.indexOf('后记'),
          next.text.lastIndexOf('后记'),
          reason: '表前或表后的哨兵被改写或复制了',
        );
        expect(
          next.text.indexOf(second),
          next.text.length - second.length,
          reason: '第二张表被改动或吞并了',
        );
      });
    }
  });

  group('large paste guard', () {
    String tsv(int rows, int columns) => <String>[
      for (int r = 0; r < rows; r++)
        <String>[for (int c = 0; c < columns; c++) '$r-$c'].join('\t'),
    ].join('\n');

    const TextEditingValue empty = TextEditingValue(
      text: '',
      selection: TextSelection.collapsed(offset: 0),
    );

    test('a 501-row grid is refused without touching the document', () {
      final String pasted = tsv(501, 2);
      expect(pasteGridRefusal(pasted), isNotNull);
      expect(pasteValue(empty, pasted), empty);
    });

    test('500 rows and 20000 cells are still accepted', () {
      expect(pasteGridRefusal(tsv(500, 2)), isNull);
      expect(pasteValue(empty, tsv(500, 2)).text, isNotEmpty);
      expect(pasteGridRefusal(tsv(100, 200)), isNull);
      expect(pasteValue(empty, tsv(100, 200)).text, isNotEmpty);
    });

    test('one cell over the limit is refused', () {
      expect(pasteGridRefusal(tsv(101, 200)), isNotNull);
      expect(pasteValue(empty, tsv(101, 200)), empty);
    });

    test('a large Markdown table is refused before it is parsed', () {
      final String pasted =
          '| a | b |\n| --- | --- |\n'
          '${<String>[for (int r = 0; r < 501; r++) '| $r | $r |'].join('\n')}';
      expect(pasteGridRefusal(pasted), isNotNull);
      expect(pasteValue(empty, pasted), empty);
    });

    test('long prose is not a grid and is never refused', () {
      final String prose = <String>[
        for (int i = 0; i < 800; i++) '第 $i 行，没有制表符。',
      ].join('\n');
      expect(pasteGridRefusal(prose), isNull);
    });

    testWidgets('Ctrl+V surfaces the refusal instead of freezing', (
      WidgetTester tester,
    ) async {
      final MarkdownSourceController controller = MarkdownSourceController(
        text: '| a | b |\n| --- | --- |\n| c | d |',
      );
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      String? clipboard = tsv(501, 2);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': clipboard};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppPalette.light),
          home: Scaffold(
            body: MarkdownEditor(
              controller: controller,
              focusNode: focus,
              scrollController: ScrollController(),
              fontSize: 15.5,
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pumpAndSettle();

      final String before = controller.text;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(controller.text, before);
      expect(find.textContaining('粘贴内容过大'), findsOneWidget);
    });
  });

  group('menu state follows the selection', () {
    const String menuTable =
        '| h1 | h2 | h3 |\n'
        '| :--- | ---: | --- |\n'
        '| a | 1 | x |\n'
        '| b | 2 | y |\n'
        '| c | 3 | z |';

    late LineEditableTextState state;

    Future<void> mount(WidgetTester tester) async {
      await pumpEditor(tester, menuTable);
      state = tester.state<LineEditableTextState>(find.byType(LineEditableText));
    }

    Map<String, MenuAction> actionsFor(
      TextEditingValue value, {
      TableRange? intended,
    }) {
      final List<MenuNode> nodes = buildEditorMenu(
        value: value,
        onApply: (MarkdownEditFn fn) {},
        state: state,
        resolve: intended == null
            ? null
            : (String text, TextSelection selection) => intended,
        onEditCell: () {},
      );
      final Map<String, MenuAction> out = <String, MenuAction>{};
      void walk(List<MenuNode> list) {
        for (final MenuNode node in list) {
          if (node is MenuAction) out[node.label] = node;
          if (node is MenuSubmenu) walk(node.children);
        }
      }

      walk(nodes);
      return out;
    }

    List<MenuNode> menuNodesFor(TextEditingValue value) => buildEditorMenu(
      value: value,
      onApply: (MarkdownEditFn fn) {},
      state: state,
      onEditCell: () {},
    );

    TableBlock block() => TableBlock.parse(menuTable, 0)!;

    testWidgets('a caret and a single cell offer the single-cell rows', (
      WidgetTester tester,
    ) async {
      await mount(tester);
      // The body's 1, not the 1 inside the header's h1.
      final int one = menuTable.indexOf('| 1 |') + 2;
      final TextSelection caret = TextSelection.collapsed(offset: one);

      for (final TextSelection selection in <TextSelection>[
        caret,
        TextSelection(baseOffset: one, extentOffset: one + 1),
      ]) {
        final Map<String, MenuAction> actions = actionsFor(
          TextEditingValue(text: menuTable, selection: selection),
        );

        expect(actions.containsKey('上方插入行'), isTrue);
        expect(actions.containsKey('删除本行'), isTrue);
        expect(actions.containsKey('删除本列'), isTrue);
        expect(actions.containsKey('清空单元格'), isTrue);
        expect(actions.containsKey('清空所选单元格'), isFalse);
        expect(actions['清空单元格']!.shortcut, isNull);
        expect(actions['删除本列']!.enabled, isTrue);
        expect(actions['编辑单元格']!.enabled, isTrue);
        expect(actions['编辑单元格']!.shortcut, 'F2');
        expect(actions['向下填充']!.enabled, isTrue);
        expect(actions['向右填充']!.enabled, isTrue);
        expect(actions['向下填充']!.shortcut, 'Ctrl+D');
        expect(actions['向右填充']!.shortcut, 'Ctrl+R');
        expect(actions.containsKey('复制所选为制表符文本'), isTrue);
      }
    });

    testWidgets('a cell rectangle sizes every row and column command', (
      WidgetTester tester,
    ) async {
      await mount(tester);
      final Map<String, MenuAction> actions = actionsFor(
        TextEditingValue(
          text: menuTable,
          selection: TextSelection(
            baseOffset: menuTable.indexOf('a'),
            extentOffset: menuTable.indexOf('2') + 1,
          ),
        ),
      );

      expect(actions.containsKey('上方插入 2 行'), isTrue);
      expect(actions.containsKey('删除 2 行'), isTrue);
      expect(actions.containsKey('左侧插入 2 列'), isTrue);
      expect(actions.containsKey('右侧插入 2 列'), isTrue);
      expect(actions.containsKey('左移 2 列'), isTrue);
      expect(actions.containsKey('右移 2 列'), isTrue);
      expect(actions.containsKey('复制 2 列到右侧'), isTrue);
      expect(actions.containsKey('删除 2 列'), isTrue);
      expect(actions['删除 2 列']!.enabled, isTrue);
      expect(actions['清空所选单元格']!.enabled, isTrue);
      expect(actions['清空所选单元格']!.shortcut, 'Delete');
      expect(actions['复制所选为制表符文本']!.enabled, isTrue);
      expect(actions['复制所选为制表符文本']!.shortcut, 'Ctrl+Shift+C');

      // The block spans a left-aligned and a right-aligned column: neither
      // alignment tick may claim the whole selection.
      expect(actions['左对齐']!.checked, isFalse);
      expect(actions['右对齐']!.checked, isFalse);
      final List<MenuInfo> info = <MenuInfo>[];
      void collectInfo(List<MenuNode> list) {
        for (final MenuNode node in list) {
          if (node is MenuInfo) info.add(node);
          if (node is MenuSubmenu) collectInfo(node.children);
        }
      }

      collectInfo(
        menuNodesFor(
          TextEditingValue(
            text: menuTable,
            selection: TextSelection(
              baseOffset: menuTable.indexOf('a'),
              extentOffset: menuTable.indexOf('2') + 1,
            ),
          ),
        ),
      );
      expect(info.any((MenuInfo n) => n.label.startsWith('2 行 × 2 列')), isTrue);
    });

    testWidgets('a whole-row selection moves as one row, not one per cell', (
      WidgetTester tester,
    ) async {
      await mount(tester);
      final TableRange row = TableRange.rowsOf(block(), 3, 3);
      final Map<String, MenuAction> actions = actionsFor(
        TextEditingValue(text: menuTable, selection: row.toTextSelection()),
        intended: row,
      );

      expect(actions.containsKey('上方插入行'), isTrue);
      expect(actions.containsKey('删除本行'), isTrue);
      expect(actions.containsKey('左侧插入列'), isTrue);
      expect(actions.containsKey('删除本列'), isTrue);
      expect(actions['上移本行']!.enabled, isTrue);
      expect(actions['下移本行']!.enabled, isFalse, reason: '已是最后一行');
      expect(actions['向下填充']!.enabled, isTrue);
      expect(actions['向右填充']!.enabled, isTrue);
    });

    testWidgets('a whole-column selection sizes columns only', (
      WidgetTester tester,
    ) async {
      await mount(tester);
      final TableRange column = TableRange.columnsOf(block(), 1, 1);
      final Map<String, MenuAction> actions = actionsFor(
        TextEditingValue(
          text: menuTable,
          selection: column.toTextSelection(),
        ),
        intended: column,
      );

      expect(actions.containsKey('左侧插入列'), isTrue);
      expect(actions.containsKey('删除本列'), isTrue);
      expect(actions['右移本列']!.enabled, isTrue);
      expect(actions['左移本列']!.enabled, isTrue);
      expect(actions['删除本列']!.enabled, isTrue);
      expect(actions['右对齐']!.checked, isTrue);
      expect(actions['左对齐']!.checked, isFalse);
      expect(actions['向下填充']!.enabled, isTrue);
      expect(actions['向右填充']!.enabled, isTrue);
    });

    testWidgets('a one-column table greys out deleting its last column', (
      WidgetTester tester,
    ) async {
      await mount(tester);
      const String oneColumn = '| a |\n| --- |\n| b |';
      final TableBlock parsed = TableBlock.parse(oneColumn, 0)!;
      final TableRange column = TableRange.columnsOf(parsed, 0, 0);
      final Map<String, MenuAction> actions = actionsFor(
        TextEditingValue(
          text: oneColumn,
          selection: column.toTextSelection(),
        ),
        intended: column,
      );

      expect(actions['删除本列']!.enabled, isFalse);
    });

    testWidgets('a divider caret cannot delete the table row it belongs to', (
      WidgetTester tester,
    ) async {
      await mount(tester);
      final TableBlock parsed = block();
      final TableRow divider = parsed.rows.firstWhere(
        (TableRow row) => row.divider,
      );
      final Map<String, MenuAction> actions = actionsFor(
        TextEditingValue(
          text: menuTable,
          selection: TextSelection.collapsed(offset: divider.start),
        ),
      );

      expect(actions['删除本行']!.enabled, isFalse);
    });
  });
}

// ---------------------------------------------------------------- the harness

class _UndoCase {
  const _UndoCase(this.name, this.edit, {this.selection});

  final String name;
  final TextEditingValue? Function(TextEditingValue) edit;
  final TextSelection? selection;
}

Future<MarkdownSourceController> pumpEditor(
  WidgetTester tester,
  String text,
) async {
  final MarkdownSourceController controller = MarkdownSourceController(
    text: text,
  );
  final FocusNode focus = FocusNode();
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.light),
      home: Scaffold(
        body: MarkdownEditor(
          controller: controller,
          focusNode: focus,
          scrollController: ScrollController(),
          fontSize: 15.5,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  focus.requestFocus();
  await tester.pumpAndSettle();
  return controller;
}

Future<void> pressCtrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// [edit] as one controller write, then Ctrl+Z → the document before it and
/// Ctrl+Y → the document after it.
Future<void> expectOneUndo(
  WidgetTester tester,
  MarkdownSourceController controller,
  TextEditingValue? Function(TextEditingValue) edit, {
  TextSelection? selection,
}) async {
  if (selection != null) {
    controller.selection = selection;
    await tester.pump();
  }
  // `UndoHistory` throttles pushes by 500 ms; let the starting value land.
  await tester.pump(const Duration(milliseconds: 600));
  final TextEditingValue before = controller.value;

  final TextEditingValue? next = edit(before);
  expect(next, isNotNull, reason: 'the command returned null');
  expect(next!.text, isNot(before.text), reason: 'the command was a no-op');
  controller.value = next;
  await tester.pump(const Duration(milliseconds: 600));
  final TextEditingValue after = controller.value;

  await pressCtrl(tester, LogicalKeyboardKey.keyZ);
  expect(controller.text, before.text, reason: 'Ctrl+Z did not restore the table');
  expect(controller.selection.isValid, isTrue);
  expect(
    controller.selection.start,
    inInclusiveRange(0, controller.text.length),
  );

  await pressCtrl(tester, LogicalKeyboardKey.keyY);
  expect(controller.text, after.text, reason: 'Ctrl+Y did not reapply the edit');
  expect(controller.selection.isValid, isTrue);
  expect(
    controller.selection.start,
    inInclusiveRange(0, controller.text.length),
  );
}

/// The engine's replacement of the current composition (or selection) with
/// [insert].
TextEditingValue replacementFor(
  MarkdownSourceController controller,
  String insert,
) {
  final TextEditingValue v = controller.value;
  final bool composing = v.composing.isValid && !v.composing.isCollapsed;
  final int from = composing ? v.composing.start : v.selection.start;
  final int to = composing ? v.composing.end : v.selection.end;
  final String before = v.text.substring(0, from);
  final String after = v.text.substring(to);
  return TextEditingValue(
    text: before + insert + after,
    selection: TextSelection.collapsed(offset: before.length + insert.length),
  );
}

/// A composition update carrying [preedit] over the current composition (or
/// selection, when no composition is open). Each update replaces the previous
/// preedit in place, exactly like an IME extending its composition.
TextEditingValue composingFor(
  MarkdownSourceController controller,
  String preedit,
) {
  final TextEditingValue v = controller.value;
  final bool composing = v.composing.isValid && !v.composing.isCollapsed;
  final int from = composing ? v.composing.start : v.selection.start;
  final int to = composing ? v.composing.end : v.selection.end;
  final String before = v.text.substring(0, from);
  final String after = v.text.substring(to);
  return TextEditingValue(
    text: before + preedit + after,
    selection: TextSelection.collapsed(
      offset: before.length + preedit.length,
    ),
    composing: TextRange(
      start: before.length,
      end: before.length + preedit.length,
    ),
  );
}
