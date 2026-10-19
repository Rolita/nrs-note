import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/table_selection.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// The grips and plus buttons a live table hangs around itself.
///
/// They are *painted* by the row's render object and hit-tested by the editor's
/// raw `Listener`, so the only honest way to test them is from the outside:
/// ask the render objects where they drew, then tap / drag there.
///
/// They are also **hover-only** — nothing is drawn until the pointer is at the
/// edge — which is why every test here either moves the pointer position or
/// accepts that it is clicking blind (a real mouse always hovers first).
void main() {
  Future<MarkdownSourceController> pump(
    WidgetTester tester,
    String text, {
    int caret = 0,
  }) async {
    // The pointer position is module-level state shared by every render object
    // in the process; a test that inherited it would see chrome it never asked
    // for.
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
    controller.selection = TextSelection.collapsed(offset: caret);
    await tester.pumpAndSettle();
    return controller;
  }

  List<TableRowChrome> rows(WidgetTester tester) =>
      tester.allRenderObjects.whereType<TableRowChrome>().toList()..sort(
        (TableRowChrome a, TableRowChrome b) =>
            a.chromeRowIndex.compareTo(b.chromeRowIndex),
      );

  List<TableChromeTarget> chrome(WidgetTester tester) => <TableChromeTarget>[
    for (final TableRowChrome r in rows(tester)) ...r.chromeTargets(),
  ];

  /// What is on screen right now.
  List<TableChromeTarget> visible(WidgetTester tester) => <TableChromeTarget>[
    for (final TableRowChrome r in rows(tester)) ...r.chromeVisible(),
  ];

  List<TableChromeKind> visibleKinds(WidgetTester tester) => <TableChromeKind>[
    for (final TableChromeTarget t in visible(tester)) t.kind,
  ];

  TableChromeTarget target(WidgetTester tester, TableChromeKind kind) =>
      chrome(tester).firstWhere((TableChromeTarget t) => t.kind == kind);

  /// Puts the mouse at [position] and lets the frame paint.
  Future<void> point(WidgetTester tester, Offset position) async {
    tablePointerPosition.value = position;
    await tester.pump();
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

  /// The floating F2 field, which is the only text field carrying this node.
  Finder cellField() => find.byWidgetPredicate(
    (Widget w) =>
        w is TextField && w.focusNode?.debugLabel == 'nrs-cell-editor',
  );

  testWidgets('a Backspace at a cell edge keeps the caret inside the cell', (
    WidgetTester tester,
  ) async {
    // 「删掉“你能在这里”之后，再按删除键，光标应该还停在这个格子里」 — a cell is
    // edited in place, so its edges are a wall; without one, one Backspace too
    // many eats the pipe and the row falls back to its raw source.
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      caret: 6,
    );
    for (int i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
    }
    expect(controller.text, text, reason: '退格越过了格子边界，吃掉了隔壁的单元格');
    expect(controller.selection.baseOffset, 6, reason: '光标应该原地不动');

    // Inside the cell the key still deletes one character.
    controller.selection = const TextSelection.collapsed(offset: 7);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(controller.text, '| a |  |\n| --- | --- |\n| c | d |');
  });

  testWidgets('a grip shows up only while the pointer is at the edge', (
    WidgetTester tester,
  ) async {
    // 「抓手等鼠标悬浮在边缘的时候才显示」 — a table inside a page is a page,
    // not a toolbar, so with the mouse elsewhere nothing at all is drawn…
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    await pump(tester, text, caret: 0);
    expect(visible(tester), isEmpty, reason: '鼠标不在边缘，不该有任何抓手');

    // …and the row grip is to the *left* of the table, the column grip *above*
    // it — the same edges Obsidian uses.
    final Rect table = rows(tester).first.chromeBounds();
    final TableChromeTarget grip = target(tester, TableChromeKind.rowHandle);
    expect(grip.rect.right, lessThanOrEqualTo(table.left + 1));
    final TableChromeTarget top = target(tester, TableChromeKind.columnHandle);
    expect(top.rect.bottom, lessThanOrEqualTo(table.top + 1));

    await point(tester, grip.rect.center);
    expect(visibleKinds(tester), <TableChromeKind>[TableChromeKind.rowHandle]);
    // The band is forgiving: a few pixels outside the glyph still counts, or
    // aiming at a 10px arrow would be a game of skill.
    await point(tester, grip.rect.center - const Offset(4, 0));
    expect(visibleKinds(tester), <TableChromeKind>[
      TableChromeKind.rowHandle,
    ], reason: '边缘附近的几个像素也该算数');

    // Hovering a column's grip above the table must not light the row's.
    await point(
      tester,
      target(tester, TableChromeKind.columnHandle).rect.center,
    );
    expect(visibleKinds(tester), <TableChromeKind>[
      TableChromeKind.columnHandle,
    ], reason: '只有被指到的那一列该出现');

    // Leaving the table takes everything with it.
    await point(tester, table.center + const Offset(0, 200));
    expect(visible(tester), isEmpty);
  });

  testWidgets('the plus buttons are hover-only too', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    await pump(tester, text, caret: 0);
    expect(visible(tester), isEmpty);

    final TableChromeTarget below = target(tester, TableChromeKind.addRow);
    final TableChromeTarget right = target(tester, TableChromeKind.addColumn);
    await point(tester, below.rect.center);
    expect(visibleKinds(tester), <TableChromeKind>[TableChromeKind.addRow]);
    await point(tester, right.rect.center);
    expect(visibleKinds(tester), <TableChromeKind>[TableChromeKind.addColumn]);
  });

  testWidgets('a grip shows the default arrow, even inside the field', (
    WidgetTester tester,
  ) async {
    // The column grip hangs above the table but *inside* the field, where the
    // field's own text cursor would otherwise win and draw an I-beam over the
    // dots.
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    await pump(tester, text, caret: 0);
    TextField field() =>
        tester.widget<TextField>(find.byKey(const Key('nrs-editor-field')));
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    final Rect table = rows(tester).first.chromeBounds();

    final Offset row = target(tester, TableChromeKind.rowHandle).rect.center;
    await tester.sendEventToBinding(mouse.hover(row));
    await tester.pump();
    expect(field().mouseCursor, SystemMouseCursors.basic);

    final Offset column = target(
      tester,
      TableChromeKind.columnHandle,
    ).rect.center;
    await tester.sendEventToBinding(mouse.hover(column));
    await tester.pump();
    expect(field().mouseCursor, SystemMouseCursors.basic);

    // Anywhere off the chrome the text cursor comes back.
    await tester.sendEventToBinding(mouse.hover(table.center));
    await tester.pump();
    expect(field().mouseCursor, SystemMouseCursors.text);
  });

  testWidgets('the plus under a table adds a row', (WidgetTester tester) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);
    final TableChromeTarget plus = target(tester, TableChromeKind.addRow);
    await point(tester, plus.rect.center);
    await tester.tapAt(plus.rect.center);
    await tester.pumpAndSettle();
    expect(controller.text, '$text\n|  |  |');
  });

  testWidgets('the plus on the right adds a column', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);
    final TableChromeTarget plus = target(tester, TableChromeKind.addColumn);
    await point(tester, plus.rect.center);
    await tester.tapAt(plus.rect.center);
    await tester.pumpAndSettle();
    expect(controller.text, '| a | b |  |\n| --- | --- | --- |\n| c | d |  |');
  });

  testWidgets('dragging a grip lights up the row it would move', (
    WidgetTester tester,
  ) async {
    // The press itself selects the row; the drop preview belongs to the drag.
    // Painting it while the button is merely down washed over the selection's
    // border, which is why the border seemed to arrive only on release.
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    await pump(tester, text, caret: 0);
    final TableChromeTarget grip = chrome(
      tester,
    ).where((TableChromeTarget t) => t.kind == TableChromeKind.rowHandle).last;
    await point(tester, grip.rect.center);

    final TestGesture press = await tester.startGesture(grip.rect.center);
    await tester.pump();
    expect(tableDragPreview.value, isNull, reason: '按下先只显示选区，不画落点预览');

    await press.moveBy(const Offset(0, -30));
    await tester.pump();
    final TableDragPreview? preview = tableDragPreview.value;
    expect(preview, isNotNull, reason: '开始拖动后才有落点预览');
    expect(preview!.column, isFalse);
    expect(preview.index, 0, reason: '拖到表头上方就该落在第一行');
    // …and the grip stays painted even though the pointer left it.
    expect(
      visibleKinds(tester),
      contains(TableChromeKind.rowHandle),
      reason: '被抓住的抓手必须一直亮着',
    );

    await press.up();
    await tester.pumpAndSettle();
    expect(tableDragPreview.value, isNull, reason: '松手后预览必须清掉');
  });

  testWidgets('dragging a row grip moves that row', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> grips = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.rowHandle)
        .toList();
    expect(grips, hasLength(2));
    await point(tester, grips[1].rect.center);

    // Grab the body row's grip and drag it up over the header.
    final TestGesture drag = await tester.startGesture(grips[1].rect.center);
    await drag.moveBy(const Offset(0, -6));
    await tester.pump();
    await drag.moveBy(const Offset(0, -24));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      controller.text,
      '| c | d |\n| --- | --- |\n| a | b |',
      reason: '被抓住的那一行没有换到目标位置',
    );
    final TableRange kept = controller.intendedRange!;
    expect(kept.kind, TableRangeKind.rows, reason: '松手后应保持拖拽的行被选中');
    expect((kept.firstRow, kept.lastRow), (0, 0), reason: '选区应停在被移动后的位置');
  });

  testWidgets('a column drag keeps the column selected', (
    WidgetTester tester,
  ) async {
    // A column grip is painted above the table, over the preceding text line.
    // The field's own drag recognizer used to see that press as the start of a
    // text selection and replace the column band with a caret / a slice of the
    // paragraph above, so the drag made the selection — the thing that says
    // what is being moved — disappear. The row grip sits outside the text and
    // never showed it.
    const String text =
        '上面的文字\n| a | b | c |\n| --- | --- | --- |\n| d | e | f |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> grips = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.columnHandle)
        .toList();
    final List<Rect> cells = rows(tester).first.chromeCells();
    await point(tester, grips[0].rect.center);
    final TestGesture drag = await tester.startGesture(
      grips[0].rect.center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final TextSelection pressed = controller.selection;
    expect(controller.intendedRange?.kind, TableRangeKind.columns);

    await drag.moveBy(const Offset(0, -4));
    await tester.pump();
    await drag.moveTo(Offset(cells[1].center.dx, grips[0].rect.center.dy));
    await tester.pump();

    expect(controller.selection, pressed, reason: '文本框自己的拖选把手伸进了列选区');
    expect(controller.intendedRange?.kind, TableRangeKind.columns);
    await drag.up();
    await tester.pumpAndSettle();
  });

  testWidgets('dragging a column grip moves that column', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b | c |\n| --- | --- | --- |\n| d | e | f |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> grips = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.columnHandle)
        .toList();
    expect(grips, hasLength(3));
    final List<Rect> cells = rows(tester).first.chromeCells();
    await point(tester, grips[2].rect.center);

    // Grab the last column and drag it over the first one.
    final TestGesture drag = await tester.startGesture(
      grips[2].rect.center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(-6, 0));
    await tester.pump();
    await drag.moveTo(Offset(cells[0].center.dx, grips[2].rect.center.dy));
    await tester.pump();
    expect(tableDragPreview.value?.index, 0, reason: '落点应在第一列');
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      controller.text,
      '| c | a | b |\n| --- | --- | --- |\n| f | d | e |',
      reason: '被抓住的那一列没有换到目标位置',
    );
    final TableRange kept = controller.intendedRange!;
    expect(kept.kind, TableRangeKind.columns, reason: '松手后应保持拖拽的列被选中');
    expect((kept.firstColumn, kept.lastColumn), (0, 0), reason: '选区应停在被移动后的位置');
  });

  testWidgets('a hover never moves the caret', (WidgetTester tester) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      caret: 2,
    );
    final TableChromeTarget grip = target(tester, TableChromeKind.rowHandle);
    await point(tester, grip.rect.center);
    expect(controller.selection.baseOffset, 2);
  });

  testWidgets('deleting a selection that starts mid-cell takes the whole rows', (
    WidgetTester tester,
  ) async {
    // 「选中这部分删除，为什么还有一行，而且链接两个字没有被删掉」 — the wash
    // covers whole cells, but the pointer can go down inside one, so the raw
    // selection began after 「c」 and the delete left it behind with a stray row
    // of pipes. The delete has to follow the cells that were painted.
    const String text = '| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      caret: 0,
    );
    final int rowStart = text.indexOf('| c');
    controller.selection = TextSelection(
      // Between 「c」 and the pipe, so the drag starts *in* the first column —
      // starting exactly on the pipe belongs to the second cell, the way the
      // renderer maps a click on the border.
      baseOffset: rowStart + 3,
      extentOffset: text.length,
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(controller.text, '| a | b |\n| --- | --- |\n');
  });

  testWidgets('Ctrl+X cuts the same cells the wash painted', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      caret: 0,
    );
    final int rowStart = text.indexOf('| c');
    controller.selection = TextSelection(
      baseOffset: rowStart + 3,
      extentOffset: text.length,
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(controller.text, '| a | b |\n| --- | --- |\n');
  });

  testWidgets('clicking a row grip selects that whole row', (
    WidgetTester tester,
  ) async {
    const String text = '| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> grips = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.rowHandle)
        .toList();
    expect(grips, hasLength(3));

    await point(tester, grips[1].rect.center);
    await tester.tapAt(grips[1].rect.center);
    await tester.pumpAndSettle();

    final TableRange? range = controller.intendedRange;
    expect(range, isNotNull, reason: '抓手的点击必须是一次选区手势');
    expect(range!.kind, TableRangeKind.rows);
    expect((range.firstRow, range.lastRow), (1, 1));
    expect(controller.selection.start, text.indexOf('| a'));
    // The line break is part of the row, so Delete takes the whole thing.
    expect(controller.selection.end, text.indexOf('| c'));
  });

  testWidgets('Shift+clicking a second grip extends the row block', (
    WidgetTester tester,
  ) async {
    const String text = '| h |\n| --- |\n| a |\n| b |\n| c |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> grips = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.rowHandle)
        .toList();

    await point(tester, grips[1].rect.center);
    await tester.tapAt(grips[1].rect.center);
    await tester.pumpAndSettle();
    expect(controller.intendedRange!.lastRow, 1);

    await point(tester, grips[2].rect.center);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(grips[2].rect.center);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    final TableRange range = controller.intendedRange!;
    expect(range.kind, TableRangeKind.rows);
    expect((range.firstRow, range.lastRow), (1, 2));
    expect(controller.selection.start, text.indexOf('| a'));
    expect(controller.selection.end, text.indexOf('| c'));
  });

  testWidgets('clicking a column grip selects the whole column', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |\n| e | f |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> grips = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.columnHandle)
        .toList();
    expect(grips, hasLength(2));

    await point(tester, grips[1].rect.center);
    await tester.tapAt(grips[1].rect.center);
    await tester.pumpAndSettle();

    final TableRange range = controller.intendedRange!;
    expect(range.kind, TableRangeKind.columns);
    expect((range.firstColumn, range.lastColumn), (1, 1));
    expect(controller.selection.start, text.indexOf('b'));
    expect(controller.selection.end, text.lastIndexOf('f') + 1);
  });

  testWidgets('a grip selects its row or column the moment it is pressed', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> targets = chrome(tester);

    for (final (TableChromeKind kind, TableRangeKind expected)
        in <(TableChromeKind, TableRangeKind)>[
          (TableChromeKind.rowHandle, TableRangeKind.rows),
          (TableChromeKind.columnHandle, TableRangeKind.columns),
        ]) {
      final TestGesture press = await tester.startGesture(
        targets.firstWhere((TableChromeTarget t) => t.kind == kind).rect.center,
        kind: PointerDeviceKind.mouse,
      );
      // No pumpAndSettle here: the gesture is still down, and the selection
      // must already be on — the drag says what is being moved from frame one.
      await tester.pump();
      expect(controller.intendedRange?.kind, expected);
      await press.up();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('dragging a selected block by its grip moves every row', (
    WidgetTester tester,
  ) async {
    const String text = '| h |\n| --- |\n| a |\n| b |\n| c |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<TableChromeTarget> grips = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.rowHandle)
        .toList();

    await point(tester, grips[1].rect.center);
    await tester.tapAt(grips[1].rect.center);
    await tester.pumpAndSettle();
    await point(tester, grips[2].rect.center);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tapAt(grips[2].rect.center);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(controller.intendedRange!.lastRow, 2);

    // Grab the second row of the block and drop it on the row below.
    final TestGesture drag = await tester.startGesture(grips[2].rect.center);
    await tester.pump();
    await drag.moveTo(Offset(grips[2].rect.center.dx, grips[3].rect.center.dy));
    await tester.pump();
    expect(tableDragPreview.value!.index, 2, reason: '整块会落在第三行');
    expect(tableDragPreview.value!.count, 2);
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      controller.text,
      '| h |\n| --- |\n| c |\n| a |\n| b |',
      reason: '拖动选中块时只移动了抓手那一行',
    );
    final TableRange kept = controller.intendedRange!;
    expect(kept.kind, TableRangeKind.rows);
    expect((kept.firstRow, kept.lastRow), (2, 3), reason: '移动后选区跟着走');
  });

  testWidgets('a selected block reports its statistics below itself', (
    WidgetTester tester,
  ) async {
    const String text =
        '| 名称 | 数量 |\n'
        '| --- | --- |\n'
        '| 苹果 | 10 |\n'
        '| 香蕉 | 20 |\n'
        '| 橙子 | 30 |';
    final MarkdownSourceController controller = await pump(tester, text);
    controller.selection = TextSelection(
      baseOffset: text.indexOf('苹果'),
      extentOffset: text.indexOf('30') + 2,
    );
    await tester.pumpAndSettle();

    final Finder chip = find.textContaining('合计');
    expect(chip, findsOneWidget);
    final String label = tester.widget<Text>(chip).data!;
    expect(label, contains('3×2'));
    expect(label, contains('6 格非空'));
    expect(label, contains('合计 60'));
    expect(label, contains('平均 20'));

    final Rect chipRect = tester.getRect(chip);
    final TableRowChrome last = rows(tester).last;
    expect(
      chipRect.top,
      greaterThanOrEqualTo(last.chromeBounds().bottom),
      reason: '统计条要贴在被选中块的下沿',
    );

    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();
    expect(find.textContaining('合计'), findsNothing);
  });

  testWidgets('Ctrl+D and Ctrl+R fill from the neighbouring cell', (
    WidgetTester tester,
  ) async {
    const String text = '| h1 | h2 |\n| --- | --- |\n| a | b |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);

    controller.selection = TextSelection.collapsed(offset: text.indexOf('c'));
    await tester.pumpAndSettle();
    await pressCtrl(tester, LogicalKeyboardKey.keyD);
    expect(
      controller.text,
      '| h1 | h2 |\n| --- | --- |\n| a | b |\n| a | d |',
      reason: 'Ctrl+D 应该把上面一格带下来',
    );

    controller.selection = TextSelection.collapsed(
      offset: controller.text.indexOf('d'),
    );
    await tester.pumpAndSettle();
    await pressCtrl(tester, LogicalKeyboardKey.keyR);
    expect(
      controller.text,
      '| h1 | h2 |\n| --- | --- |\n| a | b |\n| a | a |',
      reason: 'Ctrl+R 应该把左边一格带过来',
    );
  });

  testWidgets('F2 opens a floating editor and Enter commits it', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);
    controller.selection = TextSelection.collapsed(offset: text.indexOf('d'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(cellField(), findsOneWidget);
    expect(find.text('单元格'), findsOneWidget);
    expect(find.text('B2'), findsOneWidget, reason: '面板要标出正在编辑哪一格');

    // A real line break inside the cell becomes the GFM `<br>` on commit.
    await tester.enterText(cellField(), '第一行\n第二行');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(controller.text, '| a | b |\n| --- | --- |\n| c | 第一行<br>第二行 |');
    expect(cellField(), findsNothing);
  });

  testWidgets('Esc throws the floating cell editor away', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text);
    controller.selection = TextSelection.collapsed(offset: text.indexOf('d'));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    await tester.enterText(cellField(), '不想保存');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(controller.text, text);
    expect(cellField(), findsNothing);
  });

  testWidgets('Ctrl+Shift+C copies the block as tab-separated text', (
    WidgetTester tester,
  ) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
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

    const String text = '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 10 |\n| 香蕉 | 20 |';
    final MarkdownSourceController controller = await pump(tester, text);
    controller.selection = TextSelection(
      baseOffset: text.indexOf('苹果'),
      extentOffset: text.indexOf('20') + 2,
    );
    await tester.pumpAndSettle();

    await pressCtrl(tester, LogicalKeyboardKey.keyC, shift: true);
    expect(clipboard, '苹果\t10\n香蕉\t20');
  });

  testWidgets('clicking the blank part of an empty cell stays in that cell', (
    WidgetTester tester,
  ) async {
    // The painted cell is wider than its source (`|  |`), so a click on its
    // blank right half used to fall through to the collapsed divider line: the
    // caret looked like it was in the header while typing edited the dashes.
    const String text = '| 324234 |  |\n| --- | --- |\n|  |  |';
    final MarkdownSourceController controller = await pump(tester, text);
    final List<Rect> cells = rows(tester).first.chromeCells();
    expect(cells, hasLength(2));

    await tester.tapAt(Offset(cells[1].right - 12, cells[1].center.dy));
    await tester.pumpAndSettle();

    expect(
      controller.selection.start,
      lessThan(text.indexOf('| ---')),
      reason: '光标落到了分隔行上',
    );
    final active = tableActiveCell(controller.value);
    expect(active, isNotNull);
    expect((active!.row, active.column), (0, 1));

    // The same cell on the body row: its blank half must resolve there too.
    // The pause keeps the second tap from counting as a double click.
    await tester.pump(const Duration(milliseconds: 400));
    final List<Rect> bodyCells = rows(tester).last.chromeCells();
    await tester.tapAt(Offset(bodyCells[1].right - 12, bodyCells[1].center.dy));
    await tester.pumpAndSettle();
    final bodyActive = tableActiveCell(controller.value);
    expect(bodyActive, isNotNull);
    expect((bodyActive!.row, bodyActive.column), (1, 1));
  });

  testWidgets('a squeezed table keeps its narrow column usable', (
    WidgetTester tester,
  ) async {
    // A short column next to a very long one: proportional shrinking used to
    // make the short one a sliver. The minimum now wins before the overflow is
    // divided up.
    final String long = '很长的说明' * 60;
    final String text = '| 名称 | 说明 |\n| --- | --- |\n| a | $long |';
    await pump(tester, text);
    final List<Rect> cells = rows(tester).first.chromeCells();
    expect(cells, hasLength(2));
    // 64px of content plus 8px of padding on each side.
    expect(cells.first.width, closeTo(80, 1));
  });
}
