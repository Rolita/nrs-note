import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
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
            hintText: '',
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

  testWidgets('a Backspace at a cell edge keeps the caret inside the cell', (
    WidgetTester tester,
  ) async {
    // 「删掉“你能在这里”之后，再按删除键，光标应该还停在这个格子里」 — a cell is
    // edited in place, so its edges are a wall; without one, one Backspace too
    // many eats the pipe and the row falls back to its raw source.
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text, caret: 6);
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
    expect(
      visibleKinds(tester),
      <TableChromeKind>[TableChromeKind.rowHandle],
      reason: '边缘附近的几个像素也该算数',
    );

    // Hovering a column's grip above the table must not light the row's.
    await point(tester, target(tester, TableChromeKind.columnHandle).rect.center);
    expect(
      visibleKinds(tester),
      <TableChromeKind>[TableChromeKind.columnHandle],
      reason: '只有被指到的那一列该出现',
    );

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

  testWidgets('pressing a grip lights up the row it would move', (
    WidgetTester tester,
  ) async {
    // 「抓手拖拽的时候给一点视觉反馈」 — the feedback starts on *down*: the row
    // the grip belongs to is washed, and the grip itself turns accent, before a
    // single pixel of movement.
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    await pump(tester, text, caret: 0);
    final TableChromeTarget grip = chrome(tester)
        .where((TableChromeTarget t) => t.kind == TableChromeKind.rowHandle)
        .last;

    final TestGesture press = await tester.startGesture(grip.rect.center);
    await tester.pump();
    final TableDragPreview? preview = tableDragPreview.value;
    expect(preview, isNotNull, reason: '按下就该有反馈');
    expect(preview!.column, isFalse);
    expect(preview.index, 1, reason: '按下的那一行就是它的落点');
    // …and the grip stays painted even though the pointer never hovered it.
    expect(
      visibleKinds(tester),
      contains(TableChromeKind.rowHandle),
      reason: '被抓住的抓手必须一直亮着',
    );

    await press.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(tableDragPreview.value!.index, 0, reason: '拖到表头上方就该落在第一行');

    await press.up();
    await tester.pumpAndSettle();
    expect(tableDragPreview.value, isNull, reason: '松手后预览必须清掉');
  });

  testWidgets('dragging a row grip moves that row', (WidgetTester tester) async {
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
    // The caret was not stolen by the grip.
    expect(controller.selection.isCollapsed, isTrue);
  });

  testWidgets('a hover never moves the caret', (WidgetTester tester) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, text, caret: 2);
    final TableChromeTarget grip = target(tester, TableChromeKind.rowHandle);
    await point(tester, grip.rect.center);
    expect(controller.selection.baseOffset, 2);
  });
}
