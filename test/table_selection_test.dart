import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/core/utils/table_selection.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// A table selection is a **rectangle of cells**, not a run of characters.
///
/// These tests pin the rectangle down in three places that used to disagree:
/// the reading (which cells a drag covers), the edit (what Delete / typing /
/// paste does to them) and the painted escapes (`\|`, `<br>`).
void main() {
  const String table = '| a | b |\n| --- | --- |\n| c | d |';
  int at(String text, String needle) => text.indexOf(needle);

  group('TableRange', () {
    test('a rectangle is read from the cells the wash covers', () {
      final TextSelection sel = TextSelection(
        baseOffset: at(table, 'a'),
        extentOffset: at(table, 'd') + 1,
      );
      final TableRange range = TableRange.fromSelection(table, sel)!;
      expect((range.firstRow, range.lastRow), (0, 1));
      expect((range.firstColumn, range.lastColumn), (0, 1));
      expect(range.kind, TableRangeKind.rows);
      expect(range.values, <List<String>>[
        <String>['a', 'b'],
        <String>['c', 'd'],
      ]);
    });

    test('a one-column sweep is a cell block, not a row deletion', () {
      final TextSelection sel = TextSelection(
        baseOffset: at(table, 'b'),
        extentOffset: at(table, 'd') + 1,
      );
      final TableRange range = TableRange.fromSelection(table, sel)!;
      expect((range.firstColumn, range.lastColumn), (1, 1));
      expect(range.kind, TableRangeKind.cells);
      expect(range.markdown, '| b |\n| --- |\n| d |');
      expect(range.tsv, 'b\nd');
    });

    test('the selection end is exclusive, so it never grabs the next row', () {
      // A drag that stops exactly at the line break of the first row selects
      // that row, not the first cell of the row below.
      final int stop = table.indexOf('\n') + 1;
      final TableRange range = TableRange.fromSelection(
        table,
        TextSelection(baseOffset: 1, extentOffset: stop),
      )!;
      expect(range.lastRow, 0);
      expect(range.values, <List<String>>[
        <String>['a', 'b'],
      ]);
    });

    test('the trailing newline still belongs to the last row', () {
      final String withNewline = '$table\n';
      final TableRange range = TableRange.fromSelection(
        withNewline,
        TextSelection(baseOffset: 1, extentOffset: withNewline.length),
      )!;
      expect(range.lastRow, 1);
    });

    test('a single cell is ordinary text, not a table range', () {
      expect(
        TableRange.fromSelection(
          table,
          TextSelection(
            baseOffset: at(table, 'a'),
            extentOffset: at(table, 'a') + 1,
          ),
        ),
        isNull,
      );
    });

    test('a selection anchored on the divider is not a cell rectangle', () {
      final TableBlock block = TableBlock.parse(table, 0)!;
      final row = block.rows.firstWhere((r) => r.divider);
      // The divider holds no cells. Reading it as the rows around it made a
      // delete of the dashes take the whole table with it.
      expect(
        TableRange.fromSelection(
          table,
          TextSelection(baseOffset: row.start, extentOffset: row.end),
        ),
        isNull,
      );
      expect(
        TableRange.fromSelection(
          table,
          TextSelection(baseOffset: row.end, extentOffset: row.end + 1),
        ),
        isNull,
      );
    });

    group('merged blocks', () {
      const String merged =
          '| <!--nrs c=2 r=2 bg=amber-->合并 |  | x | w |\n'
          '| --- | --- | --- | --- |\n'
          '|  |  | y | z |\n'
          '| a | b | c | d |';
      final TableBlock block = TableBlock.parse(merged, 0)!;
      final body = block.bodyRows;

      test('a rectangle that clips a merge grows to the whole block', () {
        // Header cells 0…2 touch the 2×2 block anchored at (0, 0); the
        // rectangle has to take in the block's second row as well.
        final TableRange range = TableRange.fromSelection(
          merged,
          TextSelection(
            baseOffset: merged.indexOf('合并'),
            extentOffset: merged.indexOf('x') + 1,
          ),
        )!;

        expect(range.kind, TableRangeKind.cells);
        expect((range.firstRow, range.lastRow), (0, 1));
        expect((range.firstColumn, range.lastColumn), (0, 2));
        expect(range.values.first.sublist(0, 3), <String>['合并', '', 'x']);
        expect(range.values[1].sublist(0, 3), <String>['', '', 'y']);
      });

      test('selecting only covered cells still reads as the anchor block', () {
        final covered = body[1];
        final TableRange range = TableRange.fromSelection(
          merged,
          TextSelection(
            baseOffset: covered.cells[0].start,
            extentOffset: covered.cells[1].end,
          ),
        )!;

        expect((range.firstRow, range.lastRow), (0, 1));
        expect((range.firstColumn, range.lastColumn), (0, 1));
        expect(range.values, <List<String>>[
          <String>['合并', ''],
          <String>['', ''],
        ]);
      });

      test('a row selection is not grown through a rowspan', () {
        // Deleting one row of a merge must not delete the row above it that
        // the user never selected; only cell rectangles snap.
        final TableRange range = TableRange.rowsOf(block, 1, 1);

        expect((range.firstRow, range.lastRow), (1, 1));
        expect(range.kind, TableRangeKind.rows);

        final TableRange swept = TableRange.fromSelection(
          merged,
          TextSelection(
            baseOffset: body[1].cells.first.start,
            extentOffset: body[1].cells.last.end,
          ),
        )!;
        expect(swept.kind, TableRangeKind.rows);
        expect((swept.firstRow, swept.lastRow), (1, 1));
      });
    });

    test('statistics count filled cells and numbers separately', () {
      const String numbers =
          '| 名称 | 数量 |\n| --- | --- |\n| A | 10 |\n| B | 2.5 |\n| C |  |';
      final TableRange range = TableRange.fromSelection(
        numbers,
        TextSelection(baseOffset: 0, extentOffset: numbers.length),
      )!;
      final TableStats stats = range.stats;
      expect(stats.cells, 8);
      expect(stats.filled, 7);
      expect(stats.numbers, 2);
      expect(stats.sum, 12.5);
      expect(stats.average, 6.25);
      expect(stats.min, 2.5);
      expect(stats.max, 10);
    });
  });

  group('rectangle edits', () {
    test('clearing a partial rectangle keeps the rows', () {
      final TextSelection sel = TextSelection(
        baseOffset: at(table, 'b'),
        extentOffset: at(table, 'd') + 1,
      );
      final TableRange range = TableRange.fromSelection(table, sel)!;
      final TextEditingValue cleared = tableRangeClear(range);
      expect(cleared.text, '| a |  |\n| --- | --- |\n| c |  |');
      // The cleared block stays lit: the next keystroke goes back into it.
      expect(cleared.selection.isCollapsed, isFalse);
      final TableRange again = TableRange.fromSelection(
        cleared.text,
        cleared.selection,
      )!;
      expect((again.firstRow, again.lastRow), (0, 1));
      expect((again.firstColumn, again.lastColumn), (1, 1));
    });

    test(
      'typing over the selection writes the active cell and clears the rest',
      () {
        final TextSelection sel = TextSelection(
          baseOffset: at(table, 'a'),
          extentOffset: at(table, 'd') + 1,
        );
        final TableRange range = TableRange.fromSelection(table, sel)!;
        final TextEditingValue typed = tableRangeReplace(range, 'x');
        expect(typed.text, '| x |  |\n| --- | --- |\n|  |  |');
        expect(typed.selection.isCollapsed, isTrue);
      },
    );

    test('a pasted grid fills from the active cell', () {
      final TextSelection sel = TextSelection(
        baseOffset: at(table, 'a'),
        extentOffset: at(table, 'd') + 1,
      );
      final TextEditingValue v = pasteValue(
        TextEditingValue(text: table, selection: sel),
        '1\t2\n3\t4',
      );
      expect(v.text, '| 1 | 2 |\n| --- | --- |\n| 3 | 4 |');
    });

    test('plain text pasted over a rectangle becomes one cell', () {
      final TextSelection sel = TextSelection(
        baseOffset: at(table, 'a'),
        extentOffset: at(table, 'd') + 1,
      );
      final TextEditingValue v = pasteValue(
        TextEditingValue(text: table, selection: sel),
        '第一行\n第二行',
      );
      expect(v.text, '| 第一行<br>第二行 |  |\n| --- | --- |\n|  |  |');
    });
  });

  group('spreadsheet commands', () {
    const String grid = '| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |';
    TableBlock blockOf(String text) => TableBlock.parse(text, 0)!;

    /// Commands read the gesture's own rectangle, not the one geometry would
    /// infer back from the selection.
    TableRangeResolver hold(TableRange range) =>
        (String text, TextSelection _) =>
            text == range.block.text ? range : null;

    test('清空 empties cells even for a row sweep', () {
      final TableBlock block = blockOf(grid);
      final TableRange rows = TableRange.rowsOf(block, 1, 2);
      final TextEditingValue cleared = tableClearCells(
        TextEditingValue(text: grid, selection: rows.toTextSelection()),
        resolve: hold(rows),
      )!;
      expect(
        cleared.text,
        '| h1 | h2 |\n| --- | --- |\n|  |  |\n|  |  |',
        reason: '菜单里的“清空”不该把行删掉',
      );
      // The keyboard's structural delete is a different command on purpose.
      expect(tableRangeClear(rows).text, '| h1 | h2 |\n| --- | --- |');
    });

    test(
      'a perpendicular column selection inserts one row, not one per row',
      () {
        final TableBlock block = blockOf(grid);
        final TableRange columns = TableRange.columnsOf(block, 0, 0);
        final TextEditingValue inserted = tableInsertRows(
          TextEditingValue(text: grid, selection: columns.toTextSelection()),
          above: true,
          resolve: hold(columns),
        )!;
        // The inserted row becomes the first row, so the divider follows it;
        // the point is that exactly **one** row was inserted.
        expect(
          inserted.text,
          '|  |  |\n| --- | --- |\n| h1 | h2 |\n| a | b |\n| c | d |',
        );
      },
    );

    test(
      'a perpendicular row selection inserts one column, not one per column',
      () {
        final TableBlock block = blockOf(grid);
        final TableRange rows = TableRange.rowsOf(block, 1, 2);
        final TextEditingValue inserted = tableInsertColumns(
          TextEditingValue(text: grid, selection: rows.toTextSelection()),
          right: true,
          resolve: hold(rows),
        )!;
        expect(
          inserted.text,
          '| h1 |  | h2 |\n| --- | --- | --- |\n| a |  | b |\n| c |  | d |',
        );
      },
    );

    test('fill down copies the first selected row over the rest', () {
      final TableBlock block = blockOf(grid);
      final TableRange column = TableRange.rect(
        block,
        fromRow: 1,
        toRow: 2,
        fromColumn: 0,
        toColumn: 0,
      );
      final TextEditingValue filled = tableFill(
        TextEditingValue(text: grid, selection: column.toTextSelection()),
        down: true,
        resolve: hold(column),
      )!;
      expect(filled.text, '| h1 | h2 |\n| --- | --- |\n| a | b |\n| a | d |');
    });

    test('fill right copies the first selected column across', () {
      final TableBlock block = blockOf(grid);
      final TableRange all = TableRange.rect(
        block,
        fromRow: 0,
        toRow: 2,
        fromColumn: 0,
        toColumn: 1,
      );
      final TextEditingValue filled = tableFill(
        TextEditingValue(text: grid, selection: all.toTextSelection()),
        down: false,
        resolve: hold(all),
      )!;
      expect(filled.text, '| h1 | h1 |\n| --- | --- |\n| a | a |\n| c | c |');
    });

    test('a collapsed caret fills from the cell above or to the left', () {
      final TextEditingValue down = tableFill(
        TextEditingValue(
          text: grid,
          selection: TextSelection.collapsed(offset: grid.indexOf('c')),
        ),
        down: true,
      )!;
      expect(down.text, '| h1 | h2 |\n| --- | --- |\n| a | b |\n| a | d |');

      final TextEditingValue right = tableFill(
        TextEditingValue(
          text: grid,
          selection: TextSelection.collapsed(offset: grid.indexOf('d')),
        ),
        down: false,
      )!;
      expect(right.text, '| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | c |');
    });

    test('整行 selects the row the caret is in, line break included', () {
      final TextEditingValue picked = selectTableRow(
        TextEditingValue(
          text: grid,
          selection: TextSelection.collapsed(offset: at(grid, 'b')),
        ),
      )!;
      expect(picked.text.substring(picked.selection.start, picked.selection.end),
          '| a | b |\n');
      final TableRange range = TableRange.fromSelection(
        picked.text,
        picked.selection,
      )!;
      expect((range.firstRow, range.lastRow), (1, 1));
      expect(range.kind, TableRangeKind.rows);
    });

    test('整列 selects the column the caret is in', () {
      final TextEditingValue picked = selectTableColumn(
        TextEditingValue(
          text: grid,
          selection: TextSelection.collapsed(offset: at(grid, 'd')),
        ),
      )!;
      // Markdown has no single range for a column, so the selection runs from
      // the first cell of that column to the last one; the renderer paints the
      // rectangle by cell, and structural commands read the intent from it.
      final String selected = picked.text.substring(
        picked.selection.start,
        picked.selection.end,
      );
      expect(selected.startsWith('h2'), isTrue);
      expect(selected.endsWith('d'), isTrue);
      final TableRange range = TableRange.fromSelection(
        picked.text,
        picked.selection,
      )!;
      expect((range.firstColumn, range.lastColumn), (1, 1));
      expect((range.firstRow, range.lastRow), (0, 2));
    });

    test('整张表 selects every row of the table at the caret', () {
      final TextEditingValue picked = selectTableAll(
        TextEditingValue(
          text: '前文\n$grid\n后文',
          selection: TextSelection.collapsed(
            offset: at('前文\n$grid', 'd'),
          ),
        ),
      )!;
      expect(picked.text.substring(picked.selection.start, picked.selection.end),
          '$grid\n');
      expect(
        TableRange.fromSelection(picked.text, picked.selection)!
            .kind,
        TableRangeKind.rows,
      );
    });

    test('selection commands leave a caret outside any table alone', () {
      expect(
        selectTableRow(
          const TextEditingValue(
            text: '没有表格',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ),
        isNull,
      );
      expect(
        selectTableColumn(
          const TextEditingValue(
            text: '没有表格',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ),
        isNull,
      );
      expect(
        selectTableAll(
          const TextEditingValue(
            text: '没有表格',
            selection: TextSelection.collapsed(offset: 1),
          ),
        ),
        isNull,
      );
    });

    test('按列去重 drops the repeated row under the caret', () {
      final TextEditingValue deduped = dedupeTableColumn(
        TextEditingValue(
          text: grid,
          selection: TextSelection.collapsed(offset: at(grid, 'd')),
        ),
      )!;
      // Column 1 is `b` then `d` — nothing repeats here, so the text is kept.
      expect(deduped.text, grid);

      const String repeated =
          '| h |\n| --- |\n| x |\n| y |\n| x |';
      final TextEditingValue out = dedupeTableColumn(
        TextEditingValue(
          text: repeated,
          selection: TextSelection.collapsed(offset: at(repeated, 'y')),
        ),
      )!;
      expect(out.text, '| h |\n| --- |\n| x |\n| y |');
      // The caret stays in the cell it was in, so the next keystroke still
      // types into the row the user was looking at.
      expect(out.selection.isCollapsed, isTrue);
      expect(out.selection.start, out.text.indexOf('y'));
    });
  });

  group('painted cell text', () {
    test(r'\| is painted as a pipe without moving the source offsets', () {
      final String display = tableCellDisplay(r' a\|b ');
      expect(display.length, r' a\|b '.length);
      expect(display.contains('|'), isTrue);
      expect(display.contains(r'\'), isFalse);
    });

    test('<br> is painted as a break mark, still four source slots', () {
      final String display = tableCellDisplay('a<br>b');
      expect(display.length, 'a<br>b'.length);
      expect(display.startsWith('a↵'), isTrue);
      expect(display.endsWith('b'), isTrue);
      expect(display.contains('<br>'), isFalse);
    });
  });

  group('the editor protects the grid', () {
    Future<MarkdownSourceController> pump(
      WidgetTester tester,
      String text, {
      int caret = 0,
    }) async {
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
      controller.selection = TextSelection.collapsed(offset: caret);
      await tester.pumpAndSettle();
      return controller;
    }

    /// The engine's replacement of the current selection with [insert] — what
    /// a keystroke, a Delete or an IME commit looks like in a formatter.
    void replaceSelection(
      WidgetTester tester,
      MarkdownSourceController controller,
      String insert,
    ) {
      final TextEditingValue v = controller.value;
      final String before = v.selection.textBefore(v.text);
      final String after = v.selection.textAfter(v.text);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: before + insert + after,
          selection: TextSelection.collapsed(
            offset: before.length + insert.length,
          ),
        ),
      );
    }

    testWidgets('typing over a rectangle cannot splice the pipes', (
      WidgetTester tester,
    ) async {
      final MarkdownSourceController controller = await pump(tester, table);
      controller.selection = TextSelection(
        baseOffset: at(table, 'a'),
        extentOffset: at(table, 'd') + 1,
      );
      await tester.pumpAndSettle();
      replaceSelection(tester, controller, 'x');
      await tester.pumpAndSettle();
      expect(controller.text, '| x |  |\n| --- | --- |\n|  |  |');
      expect(controller.selection.isCollapsed, isTrue);
    });

    testWidgets('Delete on a partial rectangle clears cells, not rows', (
      WidgetTester tester,
    ) async {
      final MarkdownSourceController controller = await pump(tester, table);
      controller.selection = TextSelection(
        baseOffset: at(table, 'b'),
        extentOffset: at(table, 'd') + 1,
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(controller.text, '| a |  |\n| --- | --- |\n| c |  |');
      expect(controller.selection.isCollapsed, isFalse);
    });

    testWidgets('a typed pipe stays inside its cell', (
      WidgetTester tester,
    ) async {
      final String text = '| a | b |\n| --- | --- |\n| c | d |';
      final MarkdownSourceController controller = await pump(
        tester,
        text,
        caret: at(text, 'c') + 1,
      );
      replaceSelection(tester, controller, '|');
      await tester.pumpAndSettle();
      expect(controller.text, '| a | b |\n| --- | --- |\n| c\\| | d |');
      expect(TableBlock.parse(controller.text, 0)!.columns, 2);
    });

    testWidgets('an ordinary text selection is still ordinary', (
      WidgetTester tester,
    ) async {
      final MarkdownSourceController controller = await pump(tester, table);
      controller.selection = TextSelection(
        baseOffset: at(table, 'a'),
        extentOffset: at(table, 'a') + 1,
      );
      await tester.pumpAndSettle();
      replaceSelection(tester, controller, 'x');
      await tester.pumpAndSettle();
      expect(controller.text, '| x | b |\n| --- | --- |\n| c | d |');
    });

    testWidgets('Ctrl+Z takes back a rectangle edit', (
      WidgetTester tester,
    ) async {
      final MarkdownSourceController controller = await pump(tester, table);
      // `UndoHistory` batches changes in a 500 ms window; both the initial
      // value and the edit have to land before Ctrl+Z has anything to go back
      // to. A real user pauses longer than this between focusing and typing.
      await tester.pump(const Duration(milliseconds: 600));
      controller.selection = TextSelection(
        baseOffset: at(table, 'b'),
        extentOffset: at(table, 'd') + 1,
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.text, '| a |  |\n| --- | --- |\n| c |  |');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(controller.text, table, reason: '撤销没有回到删除前的表格');
    });
  });
}
