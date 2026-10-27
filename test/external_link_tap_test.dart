import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// `[标签](地址)` 是正文的一部分：**单击只是落光标**（折叠态的行还会因此
/// 摊开，光标去行末），跳转要按 Ctrl/⌘ + 单击。
void main() {
  Widget build(MarkdownSourceController controller, List<String> opened) {
    return MaterialApp(
      theme: AppTheme.build(AppPalette.midnight),
      home: Scaffold(
        body: MarkdownEditor(
          controller: controller,
          focusNode: FocusNode(),
          scrollController: ScrollController(),
          fontSize: 15.5,
          padding: EdgeInsets.zero,
          onLinkTap: opened.add,
        ),
      ),
    );
  }

  Offset pointIn(RenderLineEditable field, int offset) {
    final Rect local = field.getLocalRectForCaret(TextPosition(offset: offset));
    return field.localToGlobal(local.topLeft) + Offset(2, local.height / 2);
  }

  testWidgets('折叠行里单击链接：不跳转，光标去行末', (WidgetTester tester) async {
    const String text = '看 [官网](https://example.com/a) 还有字\n第二行';
    final List<String> opened = <String>[];
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    await tester.pumpWidget(build(controller, opened));
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final int lineEnd = text.indexOf('\n');

    // 光标放在第二行：第一行是折叠态，链接是一颗胶囊。
    controller.selection = TextSelection.collapsed(offset: text.length);
    await tester.pumpAndSettle();

    await tester.tapAt(pointIn(field, text.indexOf('官网') + 1));
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: '单击是编辑，不是跳转');
    expect(
      controller.selection,
      TextSelection.collapsed(offset: lineEnd),
      reason: '这一行因此摊开，光标去行末，不留在链接文字右边',
    );

    // 点在标签右缘的留白上：同样不跳转，光标一样去行末。
    controller.selection = TextSelection.collapsed(offset: text.length);
    await tester.pumpAndSettle();
    await tester.tapAt(
      pointIn(field, text.indexOf('官网') + 2) + const Offset(2, 0),
    );
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(controller.selection, TextSelection.collapsed(offset: lineEnd));

    // 普通正文照旧只落光标。
    await tester.tapAt(pointIn(field, text.indexOf('还有字') + 1));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('Ctrl + 单击链接才把地址交给宿主，光标不动', (WidgetTester tester) async {
    const String text =
        '看 [官网](https://example.com/a) 和 `[代码](https://code.dev)` 结尾\n第二行';
    final List<String> opened = <String>[];
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    await tester.pumpWidget(build(controller, opened));
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;

    controller.selection = TextSelection.collapsed(offset: text.length);
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    try {
      await tester.tapAt(pointIn(field, text.indexOf('官网') + 1));
      await tester.pumpAndSettle();
      expect(opened, <String>['https://example.com/a']);
      expect(
        controller.selection,
        TextSelection.collapsed(offset: text.length),
        reason: '跳转不是一次落点，光标留在原处',
      );

      // 行内代码里的同一段写法仍然只是代码。
      await tester.tapAt(pointIn(field, text.indexOf('[代码]') + 2));
      await tester.pumpAndSettle();
      expect(
        opened,
        <String>['https://example.com/a'],
        reason: '行内代码里的链接不是外链',
      );
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
  });

  testWidgets('编辑态里点链接只是落光标，不打开浏览器', (WidgetTester tester) async {
    const String text = '看 [官网](https://example.com/a) 还有字\n第二行';
    final List<String> opened = <String>[];
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    await tester.pumpWidget(build(controller, opened));
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final int labelAt = text.indexOf('官网');

    // 光标就在这一行：`[官网](https://example.com/a)` 已经摊成源码。
    controller.selection = TextSelection.collapsed(offset: labelAt);
    await tester.pumpAndSettle();

    await tester.tapAt(pointIn(field, labelAt + 1));
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: '编辑态里点链接不该弹浏览器');
    expect(
      controller.selection,
      TextSelection.collapsed(offset: labelAt + 1),
      reason: '就是正常落光标',
    );

    // 点地址那一截也一样：光标落在点上，不跳走。
    final int urlAt = text.indexOf('https');
    await tester.tapAt(pointIn(field, urlAt + 3));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    expect(controller.selection, TextSelection.collapsed(offset: urlAt + 3));
  });
}
