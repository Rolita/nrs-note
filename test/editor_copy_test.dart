import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// What leaves a table for the clipboard, and what comes back in.
///
/// A table is selected **by the cell** — the wash snaps out to whole cells — so
/// copying hands back a table made of those cells, and pasting it must not be
/// swallowed by the table it lands under.
void main() {
  const String note =
      '| 区域   | 你能在这里做的事                           |\n'
      '| ---- | ---------------------------------- |\n'
      '| 笔记列表 | 搜索、置顶、收藏;拖中间的竖线可调整宽度               |\n'
      '| 侧栏   | 按 **全部笔记 / 置顶 / 收藏 / 含待办 / 标签** 筛选 |\n'
      '| 编辑器  | 边写边成形;窗口够宽时右侧还会展开大纲                |\n';

  /// The one column a drag down the right-hand side of [note] covers.
  const String copied =
      '| 搜索、置顶、收藏;拖中间的竖线可调整宽度 |\n'
      '| --- |\n'
      '| 按 **全部笔记 / 置顶 / 收藏 / 含待办 / 标签** 筛选 |\n'
      '| 边写边成形;窗口够宽时右侧还会展开大纲 |';

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
        theme: AppTheme.build(AppPalette.dark),
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
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, TextSelection selection) async {
    controller.selection = selection;
    await tester.pumpAndSettle();
  }

  testWidgets('a drag down one column copies that column as a table', (
    WidgetTester tester,
  ) async {
    await mount(tester, note);
    await select(
      tester,
      TextSelection(
        baseOffset: note.indexOf('收藏;'),
        extentOffset: note.indexOf('展开') + 2,
      ),
    );
    await press(tester, LogicalKeyboardKey.keyC);

    // ⛔ Not the raw range: no pipes from the original rows, no `| ---- |`
    // divider, no `| 侧栏 |` prefixes — a table of the cells the drag covered.
    expect(clipboard, copied);
  });

  testWidgets('a drag inside one cell still copies characters', (
    WidgetTester tester,
  ) async {
    await mount(tester, note);
    await select(
      tester,
      TextSelection(
        baseOffset: note.indexOf('收藏;'),
        extentOffset: note.indexOf('收藏;') + 2,
      ),
    );
    await press(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, '收藏');
  });

  testWidgets('pasting a copied column under a table keeps it a table', (
    WidgetTester tester,
  ) async {
    // The user's second half: pasted on the line below, the block used to be
    // absorbed as four more rows with an empty right-hand column — 「会把两个
    // 表格连在一起」. A blank line is what keeps them apart.
    await mount(tester, note);
    clipboard = copied;
    controller.selection = TextSelection.collapsed(offset: note.length);
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyV);

    expect(controller.text, '$note\n$copied');
  });

  testWidgets('pasting into the empty row under a table starts a new table', (
    WidgetTester tester,
  ) async {
    // The user's case: the caret sits in the row `Enter` leaves at the bottom of
    // a table. Pasting there used to pour the block into that row's first cell
    // and grow the table above by every pasted row.
    const String sheet =
        '| 功能 | 快捷键 | 写法 |\n'
        '| --- | --- | --- |\n'
        '| 加粗 | Ctrl + B | **文字** |';
    await mount(tester, '$sheet\n|  |  |  |');
    clipboard = copied;
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length - 2,
    );
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyV);

    expect(controller.text, '$sheet\n\n$copied');
  });

  testWidgets('pasting a copy of the table under it makes one table', (
    WidgetTester tester,
  ) async {
    // Copying the whole table and pasting it under itself is how rows get
    // duplicated — and the result is a single table, not two: the copy's header
    // is dropped, because the table already has one and a second would show up
    // as a data row carrying the old column names.
    const String head =
        '| 功能 | 快捷键 | 写法 |\n'
        '| --- | --- | --- |\n'
        '| 加粗 | Ctrl + B | **文字** |\n'
        '| 斜体 | Ctrl + I | *文字* |';
    const String body =
        '| 加粗 | Ctrl + B | **文字** |\n'
        '| 斜体 | Ctrl + I | *文字* |';
    await mount(tester, '$head\n|  |  |  |');
    clipboard = head;
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length - 2,
    );
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyV);

    expect(controller.text, '$head\n$body');
    expect(
      RegExp(r'^\| --- \| --- \| --- \|$', multiLine: true)
          .allMatches(controller.text),
      hasLength(1),
      reason: '一张表只能有一条分隔行',
    );
  });
}
