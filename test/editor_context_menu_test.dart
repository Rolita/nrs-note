import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/core/utils/table_selection.dart';
import 'package:nrs/ui/editor/editor_context_menu.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// The editor's right-click menu is the *only* formatting surface in the app —
/// the ribbon above the editor is gone — so these tests are the guard rail for
/// the whole feature: that the right-click actually reaches
/// `contextMenuBuilder`, that the panels land beside each other instead of on
/// top of each other, and that each row writes what it says it writes.
void main() {
  Future<MarkdownSourceController> pump(
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
    // Focused, the way it is while you are actually editing: an *un*focused
    // field places the caret on any right-click, which is exactly the case that
    // must not throw a selection away.
    focus.requestFocus();
    await tester.pumpAndSettle();
    return controller;
  }

  Finder field() => find.byKey(const Key('nrs-editor-field'));

  RenderEditable editable(WidgetTester tester) =>
      tester.allRenderObjects.whereType<RenderEditable>().first;

  /// The painted box of source character [index], in global coordinates — the
  /// same box the pointer has to land inside for the click to mean that
  /// character.
  Rect glyph(WidgetTester tester, int index) {
    final RenderEditable re = editable(tester);
    return re
        .getBoxesForSelection(
          TextSelection(baseOffset: index, extentOffset: index + 1),
        )
        .first
        .toRect()
        .shift(re.localToGlobal(Offset.zero));
  }

  /// Right-clicks and lets the menu settle.
  Future<void> openMenu(WidgetTester tester, Offset spot) async {
    await tester.tapAt(spot, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
      find.text('新增链接'),
      findsOneWidget,
      reason: 'right-click never reached contextMenuBuilder',
    );
  }

  /// Opens a submenu by clicking its row.
  Future<void> openSubmenu(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// The label of the ticked row, read off the row itself: the tick's own `Row`,
  /// then the longest text inside it — the `H1`-style leading glyph is shorter
  /// than every real label.
  String tickedRow(WidgetTester tester) {
    final Finder row = find
        .ancestor(
          of: find.byIcon(LucideIcons.check),
          matching: find.byType(Row),
        )
        .first;
    String best = '';
    for (final Element element
        in find.descendant(of: row, matching: find.byType(Text)).evaluate()) {
      final Widget widget = element.widget;
      if (widget is! Text || widget.data == null) continue;
      // The shortcut hint and the `H1`-style leading glyph are both mono and are
      // the only other texts in a row; the label is the one that is not.
      if (widget.style?.fontFamily == AppFonts.mono) continue;
      if (widget.data!.length > best.length) best = widget.data!;
    }
    return best;
  }

  // ------------------------------------------------------------------ structure

  testWidgets('a right-click opens the menu where the pointer went down', (
    WidgetTester tester,
  ) async {
    await pump(tester, '你好，世界\n');
    final Offset spot = glyph(tester, 2).center;
    await openMenu(tester, spot);

    for (final String label in <String>[
      '新增链接',
      '新增外部链接',
      '文本格式',
      '段落设置',
      '插入',
      '剪切',
      '复制',
      '粘贴',
      '以纯文本形式粘贴',
      '全选',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'missing row: $label');
    }

    // Beside the click, not in a corner and not across the window.
    final Rect first = tester.getRect(find.text('新增链接'));
    expect(first.left, greaterThan(spot.dx));
    expect(first.left, lessThan(spot.dx + 60));
    expect(first.top, greaterThan(spot.dy));
    expect(first.top, lessThan(spot.dy + 40));

    // A submenu starts closed.
    expect(find.text('代码块'), findsNothing);
  });

  testWidgets(
    '插入 offers the divider, the code block and the table, and nothing else',
    (WidgetTester tester) async {
      await pump(tester, '你好\n');
      await openMenu(tester, glyph(tester, 0).center);
      await openSubmenu(tester, '插入');

      expect(find.text('分割线'), findsOneWidget);
      expect(find.text('代码块'), findsOneWidget);
      expect(find.text('表格'), findsOneWidget);
      for (final String unwanted in <String>['脚注', '标注', '数学块', '新建数据库']) {
        expect(
          find.text(unwanted),
          findsNothing,
          reason: 'unwanted row: $unwanted',
        );
      }
    },
  );

  testWidgets('a submenu opens beside its row, not over the panel', (
    WidgetTester tester,
  ) async {
    await pump(tester, '你好\n');
    await openMenu(tester, glyph(tester, 0).center);
    await openSubmenu(tester, '插入');

    final Rect row = tester.getRect(find.text('插入'));
    final Rect child = tester.getRect(find.text('分割线'));
    // Both labels sit the same distance inside their panel, so the horizontal
    // distance between them *is* the distance between the panels.
    expect(
      child.left - row.left,
      closeTo(kMenuPanelWidth + kMenuPanelGap, 1),
      reason: 'the submenu is not exactly one panel to the right',
    );
    // Vertically it starts at the row that opened it: one panel of padding, and
    // nothing else.
    expect(
      (child.top - row.top).abs(),
      closeTo(kMenuPanelPadding, 1),
      reason: 'the submenu should start at the row that opened it',
    );
  });

  testWidgets('a submenu flips to the left of its parent at the window edge', (
    WidgetTester tester,
  ) async {
    await pump(tester, '你好\n');
    // Hard against the right edge, where opening to the right cannot fit.
    final Rect box = tester.getRect(field());
    await openMenu(tester, Offset(box.right - 4, box.top + 12));
    await openSubmenu(tester, '插入');

    final Rect row = tester.getRect(find.text('插入'));
    final Rect child = tester.getRect(find.text('代码块'));
    expect(
      child.left - row.left,
      closeTo(-(kMenuPanelWidth + kMenuPanelGap), 1),
    );
    expect(child.right, lessThanOrEqualTo(row.left + kMenuPanelWidth));
  });

  // ----------------------------------------------------------------- behaviour

  testWidgets('插入 ▸ 代码块 writes a fenced block into the note', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '正文\n');
    await openMenu(tester, glyph(tester, 1).center);
    await openSubmenu(tester, '插入');
    await tester.tap(find.text('代码块'));
    await tester.pumpAndSettle();

    expect(controller.text, contains('```'));
    expect(find.text('代码块'), findsNothing, reason: 'the menu should close');
  });

  testWidgets('插入 ▸ 分割线 writes a rule on a line of its own', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '正文\n');
    await openMenu(tester, glyph(tester, 1).center);
    await openSubmenu(tester, '插入');
    await tester.tap(find.text('分割线'));
    await tester.pumpAndSettle();

    expect(controller.text, contains('---'));
  });

  testWidgets('段落设置 ▸ 标题 rewrites the line the caret is on', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '标题\n');
    await openMenu(tester, glyph(tester, 1).center);
    await openSubmenu(tester, '段落设置');
    await tester.tap(find.text('2 级标题'));
    await tester.pumpAndSettle();

    expect(controller.text, '## 标题\n');
  });

  testWidgets('段落设置 offers three list styles, and no ordered task list', (
    WidgetTester tester,
  ) async {
    await pump(tester, '正文\n');
    await openMenu(tester, glyph(tester, 0).center);
    await openSubmenu(tester, '段落设置');

    for (final String label in <String>['无序列表', '有序列表', '任务列表']) {
      expect(find.text(label), findsOneWidget, reason: 'missing row: $label');
    }
    // Removed on request. `1. [ ] 事` is still parsed and still what you get
    // when 任务列表 is applied to a numbered line — it is just not a menu row.
    expect(find.text('有序任务列表'), findsNothing);
  });

  testWidgets('段落设置 ticks the block the caret is already in', (
    WidgetTester tester,
  ) async {
    await pump(tester, '正文\n');
    await openMenu(tester, glyph(tester, 0).center);
    await openSubmenu(tester, '段落设置');
    expect(tickedRow(tester), '正文');
  });

  testWidgets('the tick follows the block style once it changes', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '标题\n');
    await openMenu(tester, glyph(tester, 1).center);
    await openSubmenu(tester, '段落设置');
    await tester.tap(find.text('3 级标题'));
    await tester.pumpAndSettle();
    expect(controller.text, '### 标题\n');

    await openMenu(tester, glyph(tester, 1).center);
    await openSubmenu(tester, '段落设置');
    expect(tickedRow(tester), '3 级标题');
  });

  testWidgets(
    '文本格式 offers the inline formats, the maths, the comment and 清除格式',
    (WidgetTester tester) async {
      await pump(tester, '你好世界\n');
      await openMenu(tester, glyph(tester, 0).center);
      await openSubmenu(tester, '文本格式');

      for (final String label in <String>[
        '加粗',
        '倾斜',
        '删除线',
        '高亮',
        '代码',
        '数学',
        '注释',
        '清除格式',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'missing row: $label');
      }
    },
  );

  testWidgets('文本格式 ▸ 代码 wraps in backticks and 清除格式 takes them off', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '你好世界\n');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.pump();

    await tester.tapAt(glyph(tester, 0).center, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await openSubmenu(tester, '文本格式');
    await tester.tap(find.text('代码'));
    await tester.pumpAndSettle();
    expect(controller.text, '`你好`世界\n');

    // …and back off again, through 清除格式 on the same selection.
    await tester.tapAt(glyph(tester, 1).center, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();
    await openSubmenu(tester, '文本格式');
    await tester.tap(find.text('清除格式'));
    await tester.pumpAndSettle();
    expect(controller.text, '你好世界\n');
  });

  testWidgets('文本格式 ▸ 加粗 wraps the selection and keeps it selected', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '你好世界\n');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.pump();

    await tester.tapAt(glyph(tester, 0).center, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await openSubmenu(tester, '文本格式');
    await tester.tap(find.text('加粗'));
    await tester.pumpAndSettle();

    expect(controller.text, '**你好**世界\n');
    expect(controller.selection.baseOffset, 2);
    expect(controller.selection.extentOffset, 4);
  });

  testWidgets('新增链接 and 新增外部链接 are different destinations', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '正文\n');

    await openMenu(tester, glyph(tester, 0).center);
    await tester.tap(find.text('新增链接'));
    await tester.pumpAndSettle();
    expect(controller.text, contains('[['));

    controller.text = '正文\n';
    await tester.pumpAndSettle();
    await openMenu(tester, glyph(tester, 0).center);
    await tester.tap(find.text('新增外部链接'));
    await tester.pumpAndSettle();
    expect(controller.text, contains(']('));
    expect(controller.text, isNot(contains('[[')));
  });

  testWidgets('全选 takes the whole note', (WidgetTester tester) async {
    final MarkdownSourceController controller = await pump(
      tester,
      '第一行\n第二行\n',
    );
    await openMenu(tester, glyph(tester, 0).center);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    expect(controller.selection.baseOffset, 0);
    expect(controller.selection.extentOffset, controller.text.length);
  });

  testWidgets('剪切 and 复制 stay greyed out until something is selected', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '你好世界\n');

    Color label(String text) =>
        tester.widget<Text>(find.text(text)).style!.color!;

    await openMenu(tester, glyph(tester, 0).center);
    expect(label('复制'), isNot(label('粘贴')));
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.pump();
    await openMenu(tester, glyph(tester, 0).center);
    expect(label('复制'), label('粘贴'));
  });

  // ------------------------------------------------------- pointer behaviour

  testWidgets('a right-click inside the selection leaves it alone', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '一二三四五六\n');
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 5);
    await tester.pump();

    await tester.tapAt(glyph(tester, 2).center, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(controller.selection.baseOffset, 1);
    expect(controller.selection.extentOffset, 5);
  });

  testWidgets('a right-click outside the selection moves the caret there', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(tester, '一二三四五六\n');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
    await tester.pump();

    await tester.tapAt(glyph(tester, 5).center, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(controller.selection.isCollapsed, isTrue);
    expect(controller.selection.baseOffset, greaterThanOrEqualTo(5));
  });

  // ---------------------------------------------------------------- dismissal

  testWidgets('a click outside dismisses the menu', (
    WidgetTester tester,
  ) async {
    await pump(tester, '你好\n');
    await openMenu(tester, glyph(tester, 0).center);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('新增链接'), findsNothing);
  });

  testWidgets('Escape dismisses the menu, and it comes back on the next click', (
    WidgetTester tester,
  ) async {
    await pump(tester, '你好\n');
    await openMenu(tester, glyph(tester, 0).center);
    await openSubmenu(tester, '插入');
    expect(find.text('代码块'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('新增链接'), findsNothing);

    // A dismissed menu must not leave the field believing one is still up: the
    // next right-click has to bring it back.
    await openMenu(tester, glyph(tester, 0).center);
    expect(find.text('新增链接'), findsOneWidget);
  });

  testWidgets('clicking the row that opened a submenu takes it back down', (
    WidgetTester tester,
  ) async {
    await pump(tester, '你好\n');
    await openMenu(tester, glyph(tester, 0).center);
    await openSubmenu(tester, '插入');
    await openSubmenu(tester, '插入');
    expect(find.text('代码块'), findsNothing);
    expect(find.text('新增链接'), findsOneWidget);
  });

  testWidgets('表格工具 is offered on a table row and nowhere else', (
    WidgetTester tester,
  ) async {
    await pump(tester, '正文\n');
    await openMenu(tester, glyph(tester, 0).center);
    expect(find.text('表格工具'), findsNothing, reason: '表格外的菜单不该有表格行操作');
  });

  testWidgets('表格工具 ▸ 右侧插入列 rewrites every row of the table', (
    WidgetTester tester,
  ) async {
    const String table = '| a | b |\n| --- | --- |\n| c | d |';
    final MarkdownSourceController controller = await pump(tester, table);

    // Right-clicking the second cell is also a caret click: the row under the
    // pointer is the one the table rows act on, so the expectation below is
    // "one column to the right of `b`", not of the first cell.
    await openMenu(tester, glyph(tester, table.indexOf('b')).center);
    await openSubmenu(tester, '表格工具');
    await openSubmenu(tester, '列');
    await openSubmenu(tester, '右侧插入列');

    expect(
      controller.text,
      '| a | b |  |\n| --- | --- | --- |\n| c | d |  |',
      reason: '列要加到每一行上，分隔行也要跟着长',
    );
  });

  testWidgets('表格工具 works on a table without a divider', (
    WidgetTester tester,
  ) async {
    // The shape the welcome note actually had: no `| --- |` line. Its
    // alignments were a fixed-length filler, so the column commands threw and
    // the menu looked like it did nothing at all.
    const String table =
        '| 想要 | 就写 | 快捷键 |  |\n'
        '| **加粗** | `**文字**` | `Ctrl + B` |  |\n'
        '| *斜体* | `*文字*` | `Ctrl + I` |  |';
    final MarkdownSourceController controller = await pump(tester, table);

    await openMenu(tester, glyph(tester, table.indexOf('加粗')).center);
    await openSubmenu(tester, '表格工具');
    await openSubmenu(tester, '列');
    await openSubmenu(tester, '右侧插入列');

    expect(
      TableBlock.parse(controller.text, 0)!
          .bodyRows
          .every((r) => r.cells.length == 5),
      isTrue,
      reason: '没有分隔行的表格也必须能加列',
    );
  });

  testWidgets('对齐 on a table without a divider grows the divider it needs', (
    WidgetTester tester,
  ) async {
    const String table =
        '| 想要 | 就写 | 快捷键 |  |\n'
        '| **加粗** | `**文字**` | `Ctrl + B` |  |\n'
        '| *斜体* | `*文字*` | `Ctrl + I` |  |';
    final MarkdownSourceController controller = await pump(tester, table);

    await openMenu(tester, glyph(tester, table.indexOf('Ctrl + B')).center);
    await openSubmenu(tester, '表格工具');
    await openSubmenu(tester, '对齐');
    await openSubmenu(tester, '右对齐');

    expect(
      controller.text.split('\n')[1],
      '| --- | --- | ---: | --- |',
      reason: '对齐只存在于分隔行；没有分隔行就必须补一行，否则命令看不到效果',
    );
  });

  testWidgets(
    '表格工具 counts selected rows but not a perpendicular column block',
    (WidgetTester tester) async {
      const String table =
          '| h1 | h2 |\n'
          '| --- | --- |\n'
          '| a | b |\n'
          '| c | d |\n'
          '| e | f |';
      final MarkdownSourceController controller = await pump(tester, table);
      final TableRange rows = TableRange.rowsOf(
        TableBlock.parse(table, 0)!,
        1,
        3,
      );
      controller
        ..selection = rows.toTextSelection()
        ..intendedRange = rows;
      await tester.pumpAndSettle();

      await openMenu(tester, glyph(tester, table.indexOf('c')).center);
      await openSubmenu(tester, '表格工具');
      await openSubmenu(tester, '行');
      expect(find.text('上方插入 3 行'), findsOneWidget);
      expect(find.text('删除 3 行'), findsOneWidget);
      expect(find.text('复制 3 行到下方'), findsOneWidget);

      // A row sweep spans every column without being a column selection.
      await openSubmenu(tester, '列');
      expect(find.text('右侧插入列'), findsOneWidget);
      expect(find.text('删除本列'), findsOneWidget);
    },
  );

  testWidgets('表格工具 ▸ 对齐 ticks the current column and writes the divider', (
    WidgetTester tester,
  ) async {
    const String table = '| a | b |\n| --- | --- |\n| 1 | 2 |';
    final MarkdownSourceController controller = await pump(tester, table);

    await openMenu(tester, glyph(tester, table.indexOf('2')).center);
    await openSubmenu(tester, '表格工具');
    await openSubmenu(tester, '对齐');
    expect(tickedRow(tester), '默认对齐');

    await openSubmenu(tester, '右对齐');
    expect(controller.text, '| a | b |\n| --- | ---: |\n| 1 | 2 |');
  });

  testWidgets('表格工具 ▸ 数据 sorts the rows under the header', (
    WidgetTester tester,
  ) async {
    const String table =
        '| 名称 | 数量 |\n'
        '| --- | --- |\n'
        '| 苹果 | 10 |\n'
        '| 香蕉 | 2 |';
    final MarkdownSourceController controller = await pump(tester, table);

    await openMenu(tester, glyph(tester, table.indexOf('10')).center);
    await openSubmenu(tester, '表格工具');
    await openSubmenu(tester, '数据');
    await openSubmenu(tester, '按本列升序');

    expect(
      controller.text,
      '| 名称 | 数量 |\n'
      '| --- | --- |\n'
      '| 香蕉 | 2 |\n'
      '| 苹果 | 10 |',
    );
  });

  testWidgets('表格工具 ▸ 数据 appends a total for the caret column', (
    WidgetTester tester,
  ) async {
    const String table =
        '| 名称 | 数量 |\n'
        '| --- | --- |\n'
        '| 苹果 | 10 |\n'
        '| 香蕉 | 2 |';
    final MarkdownSourceController controller = await pump(tester, table);

    await openMenu(tester, glyph(tester, table.indexOf('10')).center);
    await openSubmenu(tester, '表格工具');
    await openSubmenu(tester, '数据');
    await openSubmenu(tester, '追加合计行');

    expect(
      controller.text,
      '| 名称 | 数量 |\n'
      '| --- | ---: |\n'
      '| 苹果 | 10 |\n'
      '| 香蕉 | 2 |\n'
      '| 合计 | 12 |',
    );
  });
}
