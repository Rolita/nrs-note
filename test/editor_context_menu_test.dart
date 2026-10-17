import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/editor_context_menu.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// The editor's right-click menu is the *only* formatting surface in the app —
/// the ribbon above the editor is gone — so these tests are the guard rail for
/// the whole feature: that the right-click actually reaches
/// `contextMenuBuilder`, that the panels land beside each other instead of on
/// top of each other, and that each row writes what it says it writes.
void main() {
  Future<MarkdownSourceController> pump(WidgetTester tester, String text) async {
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
          of: find.byIcon(Icons.check_rounded),
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

  testWidgets('插入 offers the divider and the code block, and nothing else', (
    WidgetTester tester,
  ) async {
    await pump(tester, '你好\n');
    await openMenu(tester, glyph(tester, 0).center);
    await openSubmenu(tester, '插入');

    expect(find.text('分割线'), findsOneWidget);
    expect(find.text('代码块'), findsOneWidget);
    for (final String unwanted in <String>[
      '脚注',
      '表格',
      '标注',
      '数学块',
      '新建数据库',
    ]) {
      expect(find.text(unwanted), findsNothing, reason: 'unwanted row: $unwanted');
    }
  });

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
    expect(child.left - row.left, closeTo(-(kMenuPanelWidth + kMenuPanelGap), 1));
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

    Color label(String text) => tester.widget<Text>(find.text(text)).style!.color!;

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

  testWidgets('a click outside dismisses the menu', (WidgetTester tester) async {
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
}
