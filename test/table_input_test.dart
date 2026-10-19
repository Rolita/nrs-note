import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// Basic typing in a rendered table — the path every edit takes before any
/// spreadsheet feature matters.
///
/// A rendered table is one `TextField` whose visible glyphs are painted by the
/// row widget over an invisible skeleton. Every one of these tests starts from
/// a **pointer click** (not a programmatic offset), because the skeleton's job
/// is to turn a pixel into a source offset; a test that sets `selection` by
/// hand would skip exactly the part that can be wrong.
void main() {
  Future<MarkdownSourceController> pump(
    WidgetTester tester,
    String text,
  ) async {
    tablePointerPosition.value = null;
    addTearDown(() => tablePointerPosition.value = null);
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

  List<TableRowChrome> rows(WidgetTester tester) =>
      tester.allRenderObjects.whereType<TableRowChrome>().toList()..sort(
        (TableRowChrome a, TableRowChrome b) =>
            a.chromeRowIndex.compareTo(b.chromeRowIndex),
      );

  FocusNode fieldFocus(WidgetTester tester) =>
      tester
          .widget<TextField>(find.byKey(const Key('nrs-editor-field')))
          .focusNode!;

  /// The engine's replacement of the current selection with [insert] — what a
  /// keystroke or an IME commit looks like to the formatters.
  void type(
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

  /// The table's cells as the model sees them **after** the edit, which is the
  /// only thing that decides whether typing went into the cell or into the
  /// pipes.
  List<List<String>> grid(MarkdownSourceController controller) {
    final TableBlock? block = TableBlock.parse(controller.text, 0);
    expect(block, isNotNull, reason: '输入把表格改坏了：\n${controller.text}');
    return <List<String>>[
      for (final TableRow r in block!.bodyRows)
        <String>[for (final TableCell c in r.cells) c.text],
    ];
  }

  Future<void> click(
    WidgetTester tester,
    MarkdownSourceController controller,
    int row,
    int column, {
    double dx = 0.5,
    double dy = 0.5,
  }) async {
    final Rect cell = rows(tester)[row].chromeCells()[column];
    await tester.tapAt(
      Offset(cell.left + cell.width * dx, cell.top + cell.height * dy),
    );
    await tester.pumpAndSettle();
    final ({TableBlock block, int row, int column, TableCell cell})? active =
        tableActiveCell(controller.value);
    expect(active, isNotNull, reason: '点击后光标不在任何单元格里');
    expect(
      (active!.row, active.column),
      (row, column),
      reason:
          '点击第 $row 行第 $column 列，光标却落在第 ${active.row} 行第 ${active.column} 列',
    );
  }

  testWidgets('typing lands in the clicked cell of every column', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 0, 0);
    type(tester, controller, '1');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['a1', 'b']);

    await click(tester, controller, 0, 1);
    type(tester, controller, '2');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['a1', 'b2']);

    await click(tester, controller, 1, 0);
    type(tester, controller, '3');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['c3', 'd']);

    // The last cell is the one whose trailing blank sits against the closing
    // pipe. Typing there must not create a third cell.
    await click(tester, controller, 1, 1);
    type(tester, controller, '4');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['c3', 'd4']);
    expect(
      TableBlock.parse(controller.text, 0)!.bodyRows.last.cells,
      hasLength(2),
      reason: '最后一格打字后多出了一格：\n${controller.text}',
    );
  });

  testWidgets('typing into an empty cell fills that cell', (
    WidgetTester tester,
  ) async {
    const String text = '|  |  |\n| --- | --- |\n|  |  |';
    final MarkdownSourceController controller = await pump(tester, text);

    for (final (int row, int col) in <(int, int)>[
      (0, 0),
      (0, 1),
      (1, 0),
      (1, 1),
    ]) {
      await click(tester, controller, row, col);
      type(tester, controller, String.fromCharCode(97 + row * 2 + col));
      await tester.pumpAndSettle();
    }
    expect(grid(controller), <List<String>>[
      <String>['a', 'b'],
      <String>['c', 'd'],
    ]);
  });

  testWidgets('typing in the left and right padding stays in the cell', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);

    // Just inside the left edge of `b` — this pixel is cell 2's padding, and
    // the skeleton's gap widget between the cells covers it.
    await click(tester, controller, 0, 1, dx: 0.03);
    type(tester, controller, 'L');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['a', 'Lb']);

    // Just inside the right edge of `a` — the previous cell's padding.
    await click(tester, controller, 0, 0, dx: 0.97);
    type(tester, controller, 'R');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['aR', 'Lb']);
  });

  testWidgets('End then typing stays inside the last cell', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    type(tester, controller, 'X');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['c', 'dX']);
    expect(
      TableBlock.parse(controller.text, 0)!.bodyRows.last.cells,
      hasLength(2),
      reason: 'End 之后打字把内容写到了行尾管道外：\n${controller.text}',
    );
  });

  testWidgets('Enter adds a row and typing fills the same column', (
    WidgetTester tester,
  ) async {
    const String text = '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 10 |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 1);
    type(tester, controller, '\n');
    await tester.pumpAndSettle();
    expect(grid(controller), <List<String>>[
      <String>['名称', '数量'],
      <String>['苹果', '10'],
      <String>['', ''],
    ]);
    final ({TableBlock block, int row, int column, TableCell cell})? active =
        tableActiveCell(controller.value);
    expect((active!.row, active.column), (2, 1), reason: 'Enter 之后光标应落在新行同一列');
    type(tester, controller, '20');
    await tester.pumpAndSettle();
    expect(grid(controller)[2], <String>['', '20']);
  });

  testWidgets('a slow keystroke sequence types the whole word', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 0);
    for (final String char in <String>['你', '好', '世', '界']) {
      type(tester, controller, char);
      await tester.pumpAndSettle();
    }
    expect(grid(controller)[1], <String>['c你好世界', 'd']);
  });

  /// Removes `[from, to)` the way the engine does for a word delete: one
  /// update, the caret collapsed at the start of what went away.
  void delete(
    WidgetTester tester,
    MarkdownSourceController controller,
    int from,
    int to,
  ) {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: controller.text.replaceRange(from, to, ''),
        selection: TextSelection.collapsed(offset: from),
      ),
    );
  }

  /// Parks the caret at a source offset directly — the positions native line
  /// movement (Ctrl+End, PageDown) can reach that the table key handler does
  /// not see.
  void park(MarkdownSourceController controller, int offset) {
    controller.selection = TextSelection.collapsed(offset: offset);
  }

  testWidgets('arrow keys step across cells and skip the divider', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 0, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    type(tester, controller, '1');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['ab', '1cd']);

    // The end of the header's last cell steps into the first body row, not
    // onto the divider.
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    type(tester, controller, '2');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['2ef', 'gh']);
    expect(controller.text.split('\n')[1], '| --- | --- |');

    // ...and back across the divider to the end of the header's last cell.
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    type(tester, controller, '3');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['ab', '1cd3']);
  });

  testWidgets('Up from the first body row lands in the header', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    type(tester, controller, 'H');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['Hab', 'cd']);
    expect(grid(controller)[1], <String>['ef', 'gh']);
    expect(controller.text.split('\n')[1], '| --- | --- |');
  });

  testWidgets('Down from the header lands in the first body row', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 0, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    type(tester, controller, 'X');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['ab', 'cd']);
    expect(grid(controller)[1], <String>['ef', 'Xgh']);
  });

  testWidgets('arrows at the table edges stay in the cell', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 0, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    type(tester, controller, 'A');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['Aab', 'cd']);

    await click(tester, controller, 1, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    type(tester, controller, 'Z');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['ef', 'ghZ']);
    expect(
      TableBlock.parse(controller.text, 0)!.bodyRows.last.cells,
      hasLength(2),
      reason: '边界处的方向键把光标带出了单元格：\n${controller.text}',
    );
  });

  testWidgets('Tab right after a click selects the next cell', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    // Deliberately no settle after the click: the click guard is still armed,
    // and it must not swallow the whole-cell selection Tab just made.
    final Rect cell = rows(tester)[1].chromeCells()[0];
    await tester.tapAt(cell.center);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    type(tester, controller, 'X');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['ef', 'X']);
  });

  testWidgets('Tab keeps focus and the landing cell takes an IME composition', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(fieldFocus(tester).hasFocus, isTrue, reason: 'Tab 把焦点带走了');
    final TextEditingValue landed = controller.value;
    expect(
      landed.selection.isCollapsed,
      isFalse,
      reason: 'Tab 的落点要选中整格，第一次输入才能整格替换',
    );

    // What the Windows engine sends when a Chinese IME starts composing: the
    // text and the selection are untouched, and only a collapsed composing
    // range appears. The cell is a *selection*, and this is the first write
    // after Tab — the one that used to be read as a rectangle edit.
    final int at = landed.selection.start;
    tester.testTextInput.updateEditingValue(
      landed.copyWith(composing: TextRange.collapsed(at)),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: landed.text.replaceRange(
          landed.selection.start,
          landed.selection.end,
          'ni',
        ),
        selection: TextSelection.collapsed(offset: at + 2),
        composing: TextRange(start: at, end: at + 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.value.composing, TextRange(start: at, end: at + 2));

    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: controller.value.text.replaceRange(at, at + 2, '你'),
        selection: TextSelection.collapsed(offset: at + 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['ef', '你']);
  });

  testWidgets('Shift+Tab keeps focus and the previous cell typeable', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(fieldFocus(tester).hasFocus, isTrue, reason: 'Shift+Tab 把焦点带走了');
    type(tester, controller, 'X');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['X', 'gh']);
  });

  testWidgets('Tab off the last cell appends a row that takes input', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(fieldFocus(tester).hasFocus, isTrue, reason: 'Tab 把焦点带走了');
    expect(grid(controller), hasLength(3), reason: '末格 Tab 没有新建一行');
    type(tester, controller, 'X');
    await tester.pumpAndSettle();
    expect(grid(controller).last, <String>['X', '']);
  });

  testWidgets('Backspace and Delete stop at the cell boundaries', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    for (int i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
    }
    type(tester, controller, 'X');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['Xef', 'gh']);

    await click(tester, controller, 1, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    for (int i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
    }
    type(tester, controller, 'Y');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['Xef', 'ghY']);
    expect(controller.text.split('\n')[1], '| --- | --- |');
  });

  testWidgets('typing with the caret parked on a pipe stays in a cell', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    // The caret after the closing pipe — where End used to leave it.
    park(controller, controller.text.length);
    type(tester, controller, 'X');
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['ef', 'ghX']);
    expect(
      TableBlock.parse(controller.text, 0)!.bodyRows.last.cells,
      hasLength(2),
      reason: '在行尾管道后打字多出了一格：\n${controller.text}',
    );

    // The caret before the leading pipe.
    park(controller, 0);
    type(tester, controller, 'Y');
    await tester.pumpAndSettle();
    expect(grid(controller)[0], <String>['Yab', 'cd']);
    expect(controller.text.startsWith('|'), isTrue);
  });

  testWidgets('a multi-character delete is clamped to the cell', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 1);
    final TableBlock block = TableBlock.parse(controller.text, 0)!;
    final TableCell cell = block.bodyRows.last.cells.last;

    // Deleting only the pipe is structure, not text: blocked outright.
    park(controller, block.bodyRows.last.end);
    delete(tester, controller, cell.end, cell.end + 1);
    await tester.pumpAndSettle();
    expect(controller.text, text);

    // A word delete that sweeps the text *and* the closing pipe keeps the
    // table: only the cell's content goes.
    delete(tester, controller, cell.contentStart, cell.end + 1);
    await tester.pumpAndSettle();
    expect(grid(controller), <List<String>>[
      <String>['ab', 'cd'],
      <String>['ef', ''],
    ]);
    expect(controller.text.split('\n')[1], '| --- | --- |');
  });

  testWidgets('the divider cannot be deleted, replaced or typed into', (
    WidgetTester tester,
  ) async {
    const String text = '| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);
    final TableBlock block = TableBlock.parse(text, 0)!;
    final divider = block.rows.firstWhere((r) => r.divider);

    // Select the dashes and delete them — the engine's replacement, the shape
    // Backspace, Delete and a cut all take.
    controller.selection = TextSelection(
      baseOffset: divider.start,
      extentOffset: divider.end,
    );
    await tester.pumpAndSettle();
    type(tester, controller, '');
    await tester.pumpAndSettle();
    expect(controller.text, text, reason: '删掉分隔行等于把表格拆散');

    // Typing over the divider is the same splice.
    controller.selection = TextSelection(
      baseOffset: divider.start,
      extentOffset: divider.end,
    );
    await tester.pumpAndSettle();
    type(tester, controller, 'x');
    await tester.pumpAndSettle();
    expect(controller.text, text);

    // A caret parked on the divider (the renderer reveals the line there).
    park(controller, divider.start + 4);
    type(tester, controller, 'x');
    await tester.pumpAndSettle();
    expect(controller.text, text);

    // Backspace at the divider's start would eat the newline under the header.
    park(controller, divider.start);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(controller.text, text);

    // Delete at its end would eat the newline above the first body row.
    park(controller, divider.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(controller.text, text);
  });

  testWidgets('a paragraph break right above a table is not deleted into it', (
    WidgetTester tester,
  ) async {
    const String text = '说明\n| ab | cd |\n| --- | --- |\n| ef | gh |';
    final MarkdownSourceController controller = await pump(tester, text);
    final TableBlock block = TableBlock.parse(text, text.indexOf('|'))!;

    // The caret ends the paragraph; Delete would glue the prose onto the first
    // row, which stops being a row the moment the `|` is no longer leading.
    park(controller, block.start - 1);
    delete(tester, controller, block.start - 1, block.start);
    await tester.pumpAndSettle();
    expect(controller.text, text, reason: '表格前的换行也是表格的边界');
  });

  testWidgets('an IME composition inside a cell commits into that cell', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);

    await click(tester, controller, 1, 1);
    final TextEditingValue start = controller.value;
    final int at = start.selection.start;
    // Composition: `ni` is provisional, and no pipe must be carved out of it.
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: start.text.replaceRange(at, at, 'ni'),
        selection: TextSelection.collapsed(offset: at + 2),
        composing: TextRange(start: at, end: at + 2),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.value.composing, TextRange(start: at, end: at + 2));

    // Commit: `你`.
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: controller.value.text.replaceRange(at, at + 2, '你'),
        selection: TextSelection.collapsed(offset: at + 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(grid(controller)[1], <String>['c', 'd你']);
  });
}
