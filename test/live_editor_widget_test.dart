import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/ui/editor/selection_wash.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// These tests exist because the whole live editor leans on two assumptions that
/// are easy to get wrong and invisible when they are:
///
/// 1. widgets embedded in a [WidgetSpan] *inside a TextField* are reachable, and
/// 2. the tree the framework measures carets with is exactly as long as the text
///    — the moment it is not, the caret lands left of the click and clicking a
///    line reveals its neighbour.
///
/// (2) used to be broken: every decoration (bullet, checkbox, rule, code band,
/// tag pill) added its widget *next to* the marker text instead of *in place of*
/// one of its characters, so the painted tree grew one character per decoration.
void main() {
  Future<MarkdownSourceController> pump(
    WidgetTester tester,
    String text, {
    void Function(String tag)? onTagTap,
    FocusNode? focusNode,
  }) async {
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    controller.onTagTap = onTagTap;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          body: MarkdownEditor(
            controller: controller,
            focusNode: focusNode ?? FocusNode(),
            scrollController: ScrollController(),
            fontSize: 15.5,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  /// The render object the framework actually positions carets with.
  RenderEditable editable(WidgetTester tester) =>
      tester.allRenderObjects.whereType<RenderEditable>().first;

  /// Renders [text] into its own [RepaintBoundary] and hands back the pixels, so
  /// a test can assert on what was **painted** rather than on the widget tree.
  ///
  /// The paper lives *inside* the boundary: the boundary captures only its own
  /// subtree, and every pixel outside it would read as transparent.
  Future<_Pixels> shoot(
    WidgetTester tester,
    String text,
    TextSelection selection, {
    AppPalette palette = AppPalette.light,
    TextSelection? frozen,
  }) async {
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(palette),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: palette.surface,
              child: MarkdownEditor(
                controller: controller,
                focusNode: focus,
                scrollController: ScrollController(),
                fontSize: 15.5,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    await tester.pumpAndSettle();
    // A drag freezes the reveal at pointer-down while the selection keeps
    // moving; `frozen` reproduces that frame without a gesture.
    controller.revealAs = frozen;
    controller.selection = selection;
    controller.repaint();
    await tester.pumpAndSettle();

    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // ⛔ `toImage` rasterises on another thread: inside a widget test it has to
    // run through `runAsync`, or it never completes and the test hangs.
    late ByteData bytes;
    late int width;
    late int height;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      width = image.width;
      height = image.height;
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    return _Pixels(width, height, bytes, palette);
  }

  int widgetCount(InlineSpan span) {
    if (span is WidgetSpan) return 1;
    int n = 0;
    if (span is TextSpan) {
      for (final InlineSpan c in span.children ?? const <InlineSpan>[]) {
        n += widgetCount(c);
      }
    }
    return n;
  }

  testWidgets('the laid-out tree is exactly as long as the text', (
    WidgetTester tester,
  ) async {
    const String text =
        '# 标题\n\n- 列表\n- [ ] 待办\n\n---\n\n> 引用\n\n```\ncode\n```\n';
    final MarkdownSourceController controller = await pump(tester, text);

    final InlineSpan? tree = editable(tester).text;
    expect(tree, isNotNull);
    expect(
      tree!.toPlainText().length,
      controller.text.length,
      reason: 'a decoration added or removed a character',
    );
    // And the decorations really are widgets in the tree.
    expect(widgetCount(tree), greaterThan(0));
  });

  testWidgets('tapping a checkbox flips the task and keeps the caret', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(
      tester,
      '- [ ] 待办\n- [ ] 另一件\n',
    );
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    // Tap where the *second* box is actually painted, not somewhere derived
    // from the text offset — that is exactly the difference the reference
    // implementation got wrong first.
    final Finder boxes = find.byType(MarkdownTodoCheckbox);
    expect(boxes, findsNWidgets(2));
    await tester.tapAt(tester.getCenter(boxes.last));
    await tester.pump();

    expect(controller.text, '- [ ] 待办\n- [x] 另一件\n');
    expect(
      controller.selection.baseOffset,
      0,
      reason: 'flipping a box should not move the insertion point',
    );
  });

  /// A gesture that ends on a marker ends as a **click**, whatever the field
  /// wrote on the way.
  ///
  /// `TextField` counts clicks, and two of them select a *word*; the marker
  /// column is one character wide (the box swallows the rest of `- [ ] ` to
  /// nothing), so the range's only box with pixels is the marker cell — and the
  /// wash paints it as a square growing out of the checkbox:
  /// 「点击这个图标的时候，后面出现一个正方形背景」.
  testWidgets('a click on a checkbox never leaves a range behind', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(
      tester,
      '- [ ] 待办\n- [ ] 另一件\n',
    );
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    final Finder boxes = find.byType(MarkdownTodoCheckbox);
    expect(boxes, findsNWidgets(2));
    final Rect rect = tester.getRect(boxes.first);

    // A click on the prose a moment earlier arms the field's click counter, so
    // the press below is read as the second half of a double click.
    await tester.tapAt(rect.center + const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 120));

    // The press lands in the marker column but in the padding outside the
    // shell's paint rect; the release lands on the box itself. Before this was
    // fixed the press found no caret to hand back, so the field's own range
    // survived the flip.
    final TestGesture gesture = await tester.startGesture(
      Offset(rect.right + 7, rect.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveTo(rect.center);
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(controller.text, '- [x] 待办\n- [ ] 另一件\n');
    expect(
      controller.selection.isCollapsed,
      isTrue,
      reason: 'a range covering the marker cell washes it into a square',
    );
  });

  testWidgets('tapping a tag pill reports the tag', (
    WidgetTester tester,
  ) async {
    final List<String> tapped = <String>[];
    await pump(tester, '想法 #写作 收尾\n', onTagTap: tapped.add);

    final Finder pill = find.byType(GestureDetector);
    expect(pill, findsOneWidget);
    await tester.tap(pill);
    await tester.pump();

    expect(tapped, <String>['写作']);
  });

  testWidgets('a rule measures itself as zero wide and spans the column', (
    WidgetTester tester,
  ) async {
    await pump(tester, '---\n下一段\n');

    final RenderMarkdownDividerLine line = tester.allRenderObjects
        .whereType<RenderMarkdownDividerLine>()
        .first;
    // Zero width is the point: an inline box as wide as the column would push
    // the characters behind it onto a phantom second line.
    expect(line.size.width, 0);
    expect(line.debugLineWidth, greaterThan(200));
    expect(line.size.height, greaterThan(10));
  });

  testWidgets('an open IME composition keeps the live rendering', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(
      tester,
      '- 列表项\n普通段落\n',
    );

    // What a Chinese IME does while you type pinyin: an uncommitted range at the
    // very end of the text.
    const String typed = '- 列表项\n普通段落ni';
    controller.value = TextEditingValue(
      text: typed,
      selection: TextSelection.collapsed(offset: typed.length),
      composing: TextRange(start: typed.length - 2, end: typed.length),
    );
    await tester.pump();

    final InlineSpan? tree = editable(tester).text;
    expect(tree!.toPlainText().length, typed.length);
    expect(
      widgetCount(tree),
      greaterThan(0),
      reason: 'the composition knocked the editor back to raw Markdown',
    );
  });

  testWidgets('the editor still accepts typing', (WidgetTester tester) async {
    final MarkdownSourceController controller = await pump(tester, '');
    await tester.tap(find.byKey(const Key('nrs-editor-field')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('nrs-editor-field')), '# 标题');
    expect(controller.text, '# 标题');
  });

  testWidgets('Tab indents a list item without selecting its line', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '- item',
      focusNode: focus,
    );
    focus.requestFocus();
    await tester.pumpAndSettle();
    controller.selection = const TextSelection.collapsed(offset: 6);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(controller.text, '  - item');
    expect(
      controller.selection,
      const TextSelection.collapsed(offset: 8),
      reason: 'Tab 缩进后选中了整行，下一次输入会替换整行',
    );

    // The keystroke after Tab edits at the caret instead of replacing a line.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  - item!',
        selection: TextSelection.collapsed(offset: 9),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, '  - item!');
  });

  /// Pointing at a character and getting a different one back is the bug that
  /// actually hurts: the caret blinks somewhere else and the next keystroke —
  /// or Backspace — edits text the user was not looking at.
  ///
  /// This walks *every* character of a real note, asks where that character was
  /// painted (`getBoxesForSelection`) and clicks the middle of it. A click in
  /// the right half of a glyph may snap to the position after it, so both
  /// `i` and `i + 1` are acceptable — anything else means the painted layout and
  /// the offset space have come apart.
  testWidgets('a click lands on the character under the pointer', (
    WidgetTester tester,
  ) async {
    // The shape the vault actually contains: front matter, a blank separator
    // line, then the note. (The blank first line is exactly what used to make
    // the pane throw, so it stays in the fixture.)
    final String body = '\n${Note.welcome().body}';
    final MarkdownSourceController controller = await pump(tester, body);
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    final RenderEditable re = editable(tester);

    final List<String> drifted = <String>[];
    for (int i = 0; i < body.length; i++) {
      if (body[i] == '\n') continue;
      final List<TextBox> boxes = re.getBoxesForSelection(
        TextSelection(baseOffset: i, extentOffset: i + 1),
      );
      if (boxes.isEmpty) continue;
      final Rect box = boxes.first.toRect();
      // Zero-width means a hidden marker character: it is deliberately drawn at
      // no width, so there is nothing to aim at.
      if (box.width <= 0) continue;
      final TextPosition got = re.getPositionForPoint(
        re.localToGlobal(box.center),
      );
      if (got.offset != i && got.offset != i + 1) {
        drifted.add('$i「${body[i]}」→ ${got.offset}（差 ${got.offset - i}）');
      }
    }

    expect(
      drifted,
      isEmpty,
      reason: '点击位置与光标偏移不一致：\n${drifted.take(25).join('\n')}',
    );
  });

  /// Dragging across a word has to select *that* word.
  ///
  /// The trap: pressing the button puts the caret on the line, which reveals its
  /// inline markers, which makes the line wider — all while the pointer is still
  /// moving. Measuring the drag against the reflowed layout selects text the user
  /// was never pointing at. A hidden URL makes that drift enormous (the whole
  /// `](https://…)` appears at once), so the assertion is exact rather than
  /// "within a character or two".
  testWidgets('a drag selects exactly the characters it passed over', (
    WidgetTester tester,
  ) async {
    // Desktop is where dragging selects text; on the mobile path a plain drag
    // does nothing until a long press, which would make this test vacuous.
    // (The override has to be cleared inside the test — the binding checks that
    // no debug variable outlives the test *before* tear-downs run.)
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      // The caret starts on the blank first line, so the link's line is *not*
      // revealed when the pointer goes down — that is what makes the reveal land
      // in the middle of the gesture.
      const String body =
          '\n文字 [标题](https://example.test/very/long/path) 尾巴结束\n';
      final MarkdownSourceController controller = await pump(tester, body);
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      final RenderEditable re = editable(tester);

      final int tail = body.indexOf('巴');
      expect(tail, greaterThan(0));

      Rect glyph(int index) => re
          .getBoxesForSelection(
            TextSelection(baseOffset: index, extentOffset: index + 1),
          )
          .first
          .toRect()
          .shift(re.localToGlobal(Offset.zero));

      final Offset from = glyph(0).centerLeft + const Offset(0.5, 0);
      final int mid = body.indexOf('尾');
      // Aimed at what was *painted* before the gesture started: with the reveal
      // frozen that layout is still the one on screen, so these coordinates stay
      // meaningful for the whole drag.
      final Offset via = glyph(mid).center;
      final Offset to = glyph(tail).center;

      final TestGesture drag = await tester.startGesture(from);
      await tester.pump();
      // The first move reaches the link, which would reveal its URL and push the
      // rest of the line ~250px to the right before the next move is measured.
      await drag.moveTo(via);
      await tester.pump();
      await drag.moveTo(to);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect(controller.selection.start, 0);
      expect(
        controller.selection.end,
        inInclusiveRange(tail, tail + 1),
        reason: 'the drag drifted off the characters it was drawn over',
      );
      // And releasing hands the reveal back to the live caret.
      expect(controller.revealAs, isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  /// Continuation has to survive the trip through the real field, not just hold
  /// in the pure rule table (`nrs_test.dart` covers that end): the formatter only
  /// runs when the platform actually delivers a newline to `EditableText`, which
  /// is the path a key press takes. A formatter that is present but bypassed
  /// would still pass every unit test.
  testWidgets('the editor continues a list when the platform sends a newline', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '普通段落\n- 甲\n1. 乙\n',
      focusNode: focus,
    );
    // Focus without a tap: the field is only as tall as its text, and a tap on
    // its centre now lands on the empty paper below the note (which parks the
    // caret at the end). This test is about the formatter, not about clicking.
    focus.requestFocus();
    await tester.pump();

    // Caret at the end of the `- 甲` line — `普通段落\n- 甲` is 8 characters.
    const int caret = 8;
    controller.selection = const TextSelection.collapsed(offset: caret);
    await tester.pump();
    expect(controller.text.substring(0, caret), '普通段落\n- 甲');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '普通段落\n- 甲\n\n1. 乙\n',
        selection: TextSelection.collapsed(offset: caret + 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.text, '普通段落\n- 甲\n- \n1. 乙\n');
    expect(controller.selection.baseOffset, caret + 3, reason: '光标应落在新记号之后');
  });

  /// The empty paper below the last line is part of the editing surface: a
  /// press there has to focus the field and leave the caret at the end. It used
  /// to be dead space, so the caret only appeared when the click landed on a
  /// line that already had words on it.
  testWidgets('a click below the last line focuses the editor at the end', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '第一行\n第二行\n',
      focusNode: focus,
    );
    final Rect field = tester.getRect(
      find.byKey(const Key('nrs-editor-field')),
    );
    await tester.tapAt(Offset(field.center.dx, field.bottom + 120));
    await tester.pumpAndSettle();

    expect(focus.hasFocus, isTrue, reason: '点空白处没有拿到焦点，键盘无处可去');
    expect(
      controller.selection.baseOffset,
      controller.text.length,
      reason: '点空白处应把光标放到文末',
    );
  });

  /// The field is focused and the caret is somewhere in the text. A press on the
  /// paper below must keep the caret in the editor — on desktop the field's own
  /// `onTapOutside` unfocuses it first, so this is the case that used to need a
  /// second click.
  testWidgets('clicking the empty paper keeps the caret in the editor', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      final MarkdownSourceController controller = await pump(
        tester,
        '第一行\n第二行\n',
        focusNode: focus,
      );
      focus.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      final Rect field = tester.getRect(
        find.byKey(const Key('nrs-editor-field')),
      );
      await tester.tapAt(Offset(field.center.dx, field.bottom + 120));
      await tester.pumpAndSettle();

      expect(focus.hasFocus, isTrue, reason: '点空白处不该把光标弄丢');
      expect(
        controller.selection.baseOffset,
        controller.text.length,
        reason: '点空白处应把光标放到文末',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  /// A right-click below the last line is outside the field's box, so the field
  /// never sees it — the menu has to be opened by the editor itself, and it has
  /// to be the same menu.
  testWidgets('a right-click on the empty paper opens the editor menu', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    await pump(tester, '第一行\n', focusNode: focus);

    final Rect field = tester.getRect(
      find.byKey(const Key('nrs-editor-field')),
    );
    await tester.tapAt(
      Offset(field.center.dx, field.bottom + 100),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('全选'), findsOneWidget, reason: '空白处右键没有菜单');
    expect(focus.hasFocus, isTrue, reason: '菜单打开时光标不该消失');

    // A click that misses the panel closes it.
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text('全选'), findsNothing);
  });

  /// A click is a click, however fast it is repeated.
  ///
  /// Flutter counts clicks for us and is generous about it: two taps within
  /// `kDoubleTapTimeout` that land inside 100 logical pixels select a **word**,
  /// a third selects the whole **line**. A Chinese "word" is a character or two,
  /// so a quick second click on a spot you were only aiming at highlights it —
  /// 点慢一点是光标，快一点变选中，再快一点整行被选走。
  ///
  /// No pointer handler can catch it. The double-tap recogniser only wins the
  /// gesture arena once the pointer is **up**, so the range is written *after*
  /// down, after the microtask and after up — every place that used to try to
  /// undo it ran while the selection was still a caret. The guard therefore
  /// lives in the controller's `selection` setter, the one place that sees the
  /// range at all.
  testWidgets('a fast click on the same spot stays a caret', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final MarkdownSourceController controller = await pump(
        tester,
        '文字 编辑器 尾巴结束\n',
      );
      final RenderEditable re = editable(tester);

      Rect glyph(int index) => re
          .getBoxesForSelection(
            TextSelection(baseOffset: index, extentOffset: index + 1),
          )
          .first
          .toRect()
          .shift(re.localToGlobal(Offset.zero));

      final Offset spot = glyph(4).center;

      // 100 ms apart — comfortably inside the platform's double-tap window, so
      // this walks the whole caret → word → line cycle it would otherwise take.
      for (int i = 1; i <= 5; i++) {
        await tester.tapAt(spot);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          controller.selection.isCollapsed,
          isTrue,
          reason: '第 $i 次快速点击被读成了选中：${controller.selection}',
        );
      }

      // A drag is still a selection — the guard steps aside the moment the
      // pointer travels far enough to mean one.
      final TestGesture drag = await tester.startGesture(spot);
      await tester.pump();
      await drag.moveTo(glyph(8).center);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(
        controller.selection.isCollapsed,
        isFalse,
        reason: 'the click guard swallowed a real drag',
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  /// Every line of a selection leaves a strip of paper before the next one.
  ///
  /// The field's own boxes still tile (they are the line grid the table chrome
  /// is measured from), but the wash is painted behind the field by
  /// `EditorSelectionPainter`, which takes [kSelectionLineGap] out of every
  /// line. This is the "一点点间隙" the reference screenshot shows: 22px of
  /// wash on a 24px line in Obsidian, 26px of wash on NRS's 28px line.
  testWidgets('every line of a selection leaves a seam before the next', (
    WidgetTester tester,
  ) async {
    const String text = '第一行文字\n第二行文字\n第三行文字';
    for (final AppPalette palette in <AppPalette>[
      AppPalette.light,
      AppPalette.dark,
    ]) {
      final _Pixels px = await shoot(
        tester,
        text,
        const TextSelection(baseOffset: 0, extentOffset: text.length),
        palette: palette,
      );
      final RenderEditable re = editable(tester);
      final List<TextBox> boxes = re
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: text.length),
          )
          .where((TextBox b) => b.right > b.left && b.bottom > b.top)
          .toList();
      boxes.sort((TextBox a, TextBox b) => a.top.compareTo(b.top));
      expect(boxes.length, greaterThanOrEqualTo(3), reason: '没有测到三行');
      final TextBox first = boxes.first;
      final TextBox second = boxes.firstWhere(
        (TextBox b) => b.top > first.top + 1,
      );
      // The seam is paint, not layout: the boxes still meet exactly, so a
      // change of height style that leaves a real hole would fail here too.
      expect(
        (second.top - first.bottom).abs(),
        lessThanOrEqualTo(0.05),
        reason: '选区盒不再首尾相接；缝隙应该由画笔控制，而不是行距',
      );

      // The boxes are in the field's coordinates; the screenshot starts at the
      // editor, and the field sits inside its padding, so convert before
      // sampling a pixel.
      Rect onPaper(TextBox b) => Rect.fromPoints(
        re.localToGlobal(b.toRect().topLeft),
        re.localToGlobal(b.toRect().bottomRight),
      );
      final Rect firstPaper = onPaper(first);
      final Rect secondPaper = onPaper(second);
      final int x =
          (firstPaper.left > secondPaper.left
                  ? firstPaper.left
                  : secondPaper.left)
              .ceil() +
          2;
      expect(
        x < firstPaper.right && x < secondPaper.right,
        isTrue,
        reason: '采样列不在两行选区内',
      );
      final double seam = firstPaper.bottom;
      final Color wash = Color.alphaBlend(
        px.palette.selection,
        px.palette.surface,
      );
      final int above = (seam - 3).round();
      final int below = (seam + 3).round();
      expect(
        px.isColor(wash, x, above, tolerance: 4) &&
            px.isColor(wash, x, below, tolerance: 4),
        isTrue,
        reason: '缝隙两侧没有选区色：上 ${px.at(x, above)}，下 ${px.at(x, below)}',
      );
      final int from = (seam - 1).ceil();
      final int to = (seam + 1).floor();
      final int paper = <int>[
        for (int y = from; y <= to; y++)
          if (px.isSurface(x, y)) y,
      ].length;
      expect(
        paper,
        inInclusiveRange(1, 3),
        reason:
            '两行之间只有 $paper 行纸色（$from..$to）——'
            '选区又连成了一整块，或者缝开得太大',
      );
    }
  });

  /// Flutter's desktop default (`BoxWidthStyle.max`) paints every fully selected
  /// line as a band running to the right edge of the column — a highlighted
  /// *block*, not highlighted *text*. Obsidian, and every desktop editor worth
  /// copying, hugs the glyphs instead.
  testWidgets('the highlight hugs the text, not the column', (
    WidgetTester tester,
  ) async {
    const String text = '短句\n\n另一句\n';
    final MarkdownSourceController controller = await pump(tester, text);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: text.length,
    );
    await tester.pumpAndSettle();

    final RenderEditable re = editable(tester);
    expect(re.selectionWidthStyle, ui.BoxWidthStyle.tight);
    // `includeLineSpacingMiddle` is shifted a few pixels down inside the line:
    // fine on prose, but a table's wash is painted on the line box, so the two
    // would peek out from under each other at the block's edges.
    expect(re.selectionHeightStyle, ui.BoxHeightStyle.includeLineSpacingTop);
    final List<TextBox> boxes = re.getBoxesForSelection(controller.selection);
    final double widest = boxes
        .map((TextBox b) => b.right)
        .reduce((double a, double b) => a > b ? a : b);
    expect(
      widest,
      lessThan(re.size.width / 2),
      reason:
          '选中「短句」却高亮到 '
          '${widest.toStringAsFixed(0)}px（整列宽 ${re.size.width.toStringAsFixed(0)}px）'
          '—— 又把整行铺满了',
    );
  });

  /// An empty line contains no glyphs, so a tight selection gives it a box of
  /// zero width and the field paints nothing there: a selection running across
  /// a paragraph break looked cut in two. Typora leaves a narrow bar at the
  /// start of every selected empty line; these tests hold that shape.
  group('an empty line inside a selection', () {
    test('is included only when the selection reaches into it', () {
      const String text = '短句\n\n另一句\n';
      expect(
        selectedBlankLineStarts(
          text,
          const TextSelection(baseOffset: 0, extentOffset: text.length),
        ),
        <int>[3],
      );
      // Ending on the newline *before* the empty line — the caret is at the
      // line's start but the line itself is not taken.
      expect(
        selectedBlankLineStarts(
          text,
          const TextSelection(baseOffset: 0, extentOffset: 3),
        ),
        isEmpty,
      );
      // Starting on the next paragraph leaves the line above it alone.
      expect(
        selectedBlankLineStarts(
          text,
          const TextSelection(baseOffset: 4, extentOffset: text.length),
        ),
        isEmpty,
      );
    });

    test('a run of empty lines is included line by line', () {
      const String text = 'a\n\n\nb';
      expect(
        selectedBlankLineStarts(
          text,
          const TextSelection(baseOffset: 0, extentOffset: text.length),
        ),
        <int>[2, 3],
      );
    });

    test('a caret and a whitespace-only line are not empty lines', () {
      expect(
        selectedBlankLineStarts(
          'a\n\nb',
          const TextSelection.collapsed(offset: 2),
        ),
        isEmpty,
      );
      // Spaces already have glyph boxes of their own to be selected.
      const String spaced = 'a\n  \nb';
      expect(
        selectedBlankLineStarts(
          spaced,
          const TextSelection(baseOffset: 0, extentOffset: spaced.length),
        ),
        isEmpty,
      );
    });

    testWidgets('shows a slim bar at the line start, not a full stripe', (
      WidgetTester tester,
    ) async {
      const String text = '短句\n\n另一句\n';
      for (final AppPalette palette in <AppPalette>[
        AppPalette.light,
        AppPalette.dark,
      ]) {
        final _Pixels px = await shoot(
          tester,
          text,
          const TextSelection(baseOffset: 0, extentOffset: text.length),
          palette: palette,
        );
        final RenderEditable re = editable(tester);
        final Rect local = re
            .getBoxesForSelection(
              const TextSelection(baseOffset: 3, extentOffset: 4),
            )
            .first
            .toRect();
        final Rect band = Rect.fromPoints(
          re.localToGlobal(local.topLeft),
          re.localToGlobal(local.bottomRight),
        );
        final Color wash = Color.alphaBlend(
          px.palette.selection,
          px.palette.surface,
        );

        final int y = band.center.dy.round();
        final int x = band.left.ceil() + 1;
        expect(
          px.isColor(wash, x, y, tolerance: 4),
          isTrue,
          reason:
              '空白行在 ($x, $y) 处没有选区色（实际 ${px.at(x, y)}，应为 $wash）——'
              '空白行仍然什么都没画',
        );
        expect(
          px.isSurface(
            band.left.ceil() + kBlankLineSelectionWidth.round() + 8,
            y,
          ),
          isTrue,
          reason: '空白行被整行涂满了；应该只有线首的一条细带',
        );
      }
    });
  });

  /// The rendered table paints over an invisible skeleton of the very same
  /// characters, so a click anywhere in a cell has to land on that cell's own
  /// source text — no custom hit testing involved.
  testWidgets('a click in a rendered table cell lands in that cell', (
    WidgetTester tester,
  ) async {
    // The caret starts on the plain line above, so the table is rendered.
    const String body = '上文\n\n| 区域 | 事情 |\n| --- | --- |\n| 侧栏 | 筛选笔记 |\n';
    final MarkdownSourceController controller = await pump(tester, body);
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    final RenderEditable re = editable(tester);

    final int cellStart = body.indexOf('侧栏');
    final Rect box = re
        .getBoxesForSelection(
          TextSelection(baseOffset: cellStart, extentOffset: cellStart + 2),
        )
        .first
        .toRect();
    expect(box.width, greaterThan(0), reason: 'the cell skeleton has width');

    await tester.tapAt(re.localToGlobal(box.center));
    await tester.pump();

    final int at = controller.selection.baseOffset;
    expect(
      at,
      inInclusiveRange(cellStart, cellStart + 2),
      reason: '点击「侧栏」格中心，光标应落在这个格子里，实际落在 $at',
    );
  });

  /// Clicking a cell is what puts **that cell** into edit mode: its Markdown
  /// source appears (backticks and all) while the rest of the table keeps its
  /// rendered look. A range is a selection gesture and must not open anything.
  testWidgets('clicking a cell reveals its source and only its source', (
    WidgetTester tester,
  ) async {
    const String body =
        '上文\n\n| 前 `code` 后 | 另一个 `x` |\n| --- | --- |\n| a | b |\n';
    final MarkdownSourceController controller = await pump(tester, body);
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();
    final RenderEditable re = editable(tester);

    Iterable<TextSpan> leaves(InlineSpan span) sync* {
      if (span is! TextSpan) return;
      if (span.text != null) yield span;
      for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
        yield* leaves(child);
      }
    }

    // A rendered cell's backticks are collapsed to `fontSize: 0`; an open
    // cell's are real glyphs. Counting both is enough to tell which cells the
    // painter is showing as source.
    int ticks({required bool visible}) => leaves(re.text!)
        .where(
          (TextSpan s) =>
              s.text == '`' && ((s.style?.fontSize ?? 0) > 0) == visible,
        )
        .length;

    expect(ticks(visible: true), 0);
    expect(ticks(visible: false), 4, reason: '两颗格子里的代码都应先渲染成 chip');

    final List<TableRowChrome> rows =
        tester.allRenderObjects.whereType<TableRowChrome>().toList()..sort(
          (TableRowChrome a, TableRowChrome b) =>
              a.chromeRowIndex.compareTo(b.chromeRowIndex),
        );
    final List<List<Rect>> before = <List<Rect>>[
      for (final TableRowChrome row in rows) row.chromeCells(),
    ];

    final int firstCell = body.indexOf('前');
    final int secondCell = body.indexOf('另一个');
    final Rect box = re
        .getBoxesForSelection(
          TextSelection(baseOffset: firstCell, extentOffset: firstCell + 1),
        )
        .first
        .toRect();
    await tester.tapAt(re.localToGlobal(box.center));
    await tester.pumpAndSettle();

    expect(controller.selection.isCollapsed, isTrue);
    expect(
      controller.selection.start,
      inInclusiveRange(firstCell, body.indexOf('后') + 1),
      reason: '点击后光标应落在这一格',
    );
    expect(ticks(visible: true), 2, reason: '点击的格子应展开源码：反引号要看得见');
    expect(ticks(visible: false), 2, reason: '另一颗格子的代码仍应保持渲染态（chip）');

    final List<List<Rect>> after = <List<Rect>>[
      for (final TableRowChrome row in rows) row.chromeCells(),
    ];
    expect(after, before, reason: '展开一格不能把整张表重新排版');

    // A range across cells is a selection, not an edit: everything renders.
    // Disarm the click guard first — a real drag disarms it as soon as the
    // pointer travels, and a programmatic range inside the 400ms window would
    // otherwise be folded back to the click's caret on purpose.
    controller.disarmClickGuard();
    controller.selection = TextSelection(
      baseOffset: firstCell,
      extentOffset: secondCell + 3,
    );
    await tester.pumpAndSettle();
    expect(ticks(visible: true), 0, reason: '范围选区不应把格子切回源码');
    expect(ticks(visible: false), 4);
    expect(
      controller.selection.isCollapsed,
      isFalse,
      reason: 'click guard 不应吞掉拖出来的范围',
    );
  });

  testWidgets('the caret maps onto a cell’s revealed source', (
    WidgetTester tester,
  ) async {
    const String body =
        '上文\n\n| aa **bb** cc | zz |\n| --- | --- |\n| x | y |\n';
    final MarkdownSourceController controller = await pump(tester, body);
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();
    final RenderEditable re = editable(tester);

    final int cellStart = body.indexOf('aa');
    final Rect cellBox = re
        .getBoxesForSelection(
          TextSelection(baseOffset: cellStart, extentOffset: cellStart + 2),
        )
        .first
        .toRect();
    await tester.tapAt(re.localToGlobal(cellBox.center));
    await tester.pumpAndSettle();

    // The click above revealed `**bb**`; the boxes below are the *revealed*
    // ones, which is exactly what the pointer must map against.
    final int cc = body.indexOf('cc', cellStart);
    expect(cc, greaterThan(cellStart));
    final Rect target = re
        .getBoxesForSelection(
          TextSelection(baseOffset: cc, extentOffset: cc + 1),
        )
        .first
        .toRect();
    await tester.tapAt(re.localToGlobal(target.center));
    await tester.pumpAndSettle();

    expect(
      controller.selection.start,
      inInclusiveRange(cc, cc + 1),
      reason: '展开源码后，点击「cc」应把光标放在这个字符上',
    );
  });

  /// A *range* across cells keeps the table rendered — that is the whole point
  /// of the cell-shaped selection: the row must not tear back into source
  /// while the user is dragging across it.
  testWidgets('a drag across table cells keeps the table rendered', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      const String body = '上文\n\n| 区域 | 事情 |\n| --- | --- |\n| 侧栏 | 筛选笔记 |\n';
      final MarkdownSourceController controller = await pump(tester, body);
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      final RenderEditable re = editable(tester);

      final Rect first = re
          .getBoxesForSelection(
            TextSelection(
              baseOffset: body.indexOf('侧栏'),
              extentOffset: body.indexOf('侧栏') + 2,
            ),
          )
          .first
          .toRect();
      final Rect second = re
          .getBoxesForSelection(
            TextSelection(
              baseOffset: body.indexOf('筛选'),
              extentOffset: body.indexOf('筛选') + 2,
            ),
          )
          .first
          .toRect();

      final Offset a = re.localToGlobal(first.center);
      final Offset b = re.localToGlobal(second.center);
      final TestGesture gesture = await tester.startGesture(a);
      await gesture.moveBy((b - a) / 2);
      await tester.pump();
      await gesture.moveBy((b - a) / 2);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(controller.selection.isCollapsed, isFalse);
      int rowViews = 0;
      final InlineSpan? tree = re.text;
      void walk(InlineSpan s) {
        if (s is WidgetSpan &&
            s.child.runtimeType.toString() == '_TableRowView') {
          rowViews++;
        }
        if (s is TextSpan) {
          for (final InlineSpan c in s.children ?? const <InlineSpan>[]) {
            walk(c);
          }
        }
      }

      if (tree != null) walk(tree);
      expect(rowViews, 2, reason: '拖选进行中，两行都必须保持成品渲染');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a nested row steps one marker column and carries a rail', (
    WidgetTester tester,
  ) async {
    // Two typed spaces are worth ~9px, so nesting used to be invisible. One
    // level must be worth exactly one marker column (2 + 15 + 9), which is what
    // makes a child's marker line up under its parent's text.
    await pump(tester, '- [ ] 甲\n  - [ ] 乙\n    - [ ] 丙\n');

    final List<Rect> boxes = <Rect>[
      for (final Element e in find.byType(MarkdownTodoCheckbox).evaluate())
        tester.getRect(find.byWidget(e.widget)),
    ];
    expect(boxes.length, 3);
    expect(boxes[1].left - boxes[0].left, 26);
    expect(boxes[2].left - boxes[1].left, 26);

    // The guide box *is* the indent, so it has to be as wide as the whole step
    // count and no wider — anything else moves the marker.
    final List<MarkdownIndentGuides> guides = tester
        .widgetList<MarkdownIndentGuides>(find.byType(MarkdownIndentGuides))
        .toList();
    expect(guides.map((MarkdownIndentGuides g) => g.levels), <int>[1, 2]);
    expect(tester.getSize(find.byType(MarkdownIndentGuides).first).width, 26);
    expect(tester.getSize(find.byType(MarkdownIndentGuides).last).width, 52);
  });

  testWidgets('the rail is painted, and only from the first child down', (
    WidgetTester tester,
  ) async {
    // The complaint was that there is no line at all, so this one checks the
    // pixels: a 1px column of `outline` running unbroken from the first nested
    // row to the last, and nothing above it on the parent's row.
    const String text = '- [ ] 甲\n  - [ ] 乙\n  - [ ] 丙\n';
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final GlobalKey key = GlobalKey();
    final AppPalette p = AppPalette.light;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(p),
        home: Scaffold(
          // ⛔ The boundary only captures *its own* subtree, so the paper has to
          // live inside it or every pixel outside the text reads as transparent.
          body: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: p.surface,
              child: MarkdownEditor(
                controller: controller,
                focusNode: focus,
                scrollController: ScrollController(),
                fontSize: 15.5,
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();

    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // ⛔ `toImage` rasterises on another thread, so inside a widget test it has
    // to run through `runAsync` — called directly it never completes and the
    // test hangs until the harness kills it.
    late ByteData bytes;
    late int width;
    late int height;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      width = image.width;
      height = image.height;
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    final int surface = p.surface.toARGB32();

    bool isPaper(int x, int y) {
      final int i = (y * width + x) * 4;
      return (bytes.getUint8(i) - (surface >> 16 & 0xFF)).abs() <= 6 &&
          (bytes.getUint8(i + 1) - (surface >> 8 & 0xFF)).abs() <= 6 &&
          (bytes.getUint8(i + 2) - (surface & 0xFF)).abs() <= 6;
    }

    // The longest unbroken run of ink in each column. Glyphs are broken up by
    // the gap between lines (Ahem fills the em box, not the line box), while the
    // rail spans two rows end to end.
    int bestRun = 0;
    int bestX = -1;
    int bestTop = -1;
    for (int x = 0; x < width; x++) {
      int run = 0;
      for (int y = 0; y < height; y++) {
        if (!isPaper(x, y)) {
          run++;
          if (run > bestRun) {
            bestRun = run;
            bestX = x;
            bestTop = y - run + 1;
          }
        } else {
          run = 0;
        }
      }
    }

    final RenderEditable re = editable(tester);
    final double left = re.localToGlobal(Offset.zero).dx;
    // 9.5 from the row start, minus the half-pixel nudge onto the pixel grid.
    expect(bestX.toDouble(), closeTo(left + 9, 1.5), reason: '竖线必须落在父级标记的中心');
    expect(bestRun, greaterThan(40), reason: '竖线要跨过整段子级、不能断成一段一段');
    // …and it starts on the *second* line, not on the parent's.
    expect(bestTop, greaterThan(20), reason: '父级自己那一行不该有竖线');
  });

  testWidgets('the table starts on the text column and stops at its content', (
    WidgetTester tester,
  ) async {
    // Two complaints, one probe. The grid used to hang eight pixels to the left
    // of every line of prose around it (`left = offset.dx - _kCellPad`), and it
    // used to stretch all the way to the column's right edge however little it
    // had to say. A table is as wide as its content and starts *on* the text
    // column, the way Obsidian's does.
    const String text =
        '# 标题\n'
        '| a | b |\n'
        '| --- | --- |\n'
        '| c | d |\n'
        '| e | f |\n';
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final GlobalKey key = GlobalKey();
    final AppPalette p = AppPalette.light;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(p),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: p.surface,
              child: MarkdownEditor(
                controller: controller,
                focusNode: focus,
                scrollController: ScrollController(),
                fontSize: 15.5,
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();

    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late ByteData bytes;
    late int width;
    late int height;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      width = image.width;
      height = image.height;
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    final int surface = p.surface.toARGB32();

    bool isPaper(int x, int y) {
      final int i = (y * width + x) * 4;
      return (bytes.getUint8(i) - (surface >> 16 & 0xFF)).abs() <= 6 &&
          (bytes.getUint8(i + 1) - (surface >> 8 & 0xFF)).abs() <= 6 &&
          (bytes.getUint8(i + 2) - (surface & 0xFF)).abs() <= 6;
    }

    /// Every column whose longest unbroken run of ink is at least 60px: the
    /// table's vertical rules (three rows tall, ~84px) and nothing else — the
    /// heading's glyphs are one line high.
    final List<int> rules = <int>[];
    for (int x = 0; x < width; x++) {
      int run = 0;
      int best = 0;
      for (int y = 0; y < height; y++) {
        if (!isPaper(x, y)) {
          run++;
          if (run > best) best = run;
        } else {
          run = 0;
        }
      }
      if (best >= 60) rules.add(x);
    }

    final RenderEditable re = editable(tester);
    final double columnLeft = re.localToGlobal(Offset.zero).dx;
    final double columnWidth = re.size.width;

    expect(rules, isNotEmpty, reason: '一条竖线都没画出来');
    expect(
      rules.first.toDouble(),
      closeTo(columnLeft, 1.5),
      reason: '表格左边缘要和正文左边缘对齐',
    );
    // Fit-content: the widest rule is the table's right edge, and it stops well
    // short of the column.
    expect(
      rules.last - rules.first,
      lessThan(columnWidth / 2),
      reason: '两列表格不该铺满整行',
    );
  });

  /// The selection used to be painted **cell by cell**: an opaque box per touched
  /// cell plus an accent ring around each row's share. A selected table therefore
  /// looked like a mosaic of purple tiles with the grid shouting through every
  /// seam, and a Ctrl+A turned the whole thing into a ladder of borders.
  ///
  /// What Obsidian does — and what these two tests pin down — is one continuous
  /// band per row, the table's full width, with **one** rounded outline around
  /// the whole selected span.
  testWidgets('a selected table is one washed block, not one ring per row', (
    WidgetTester tester,
  ) async {
    const String text = '| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n';
    final _Pixels px = await shoot(
      tester,
      text,
      const TextSelection(baseOffset: 0, extentOffset: 43),
    );

    // Horizontal runs of the accent colour, one per row that drew a border.
    final List<List<int>> bands = px.bandsOf(px.palette.selectionEdge, 40);

    expect(
      bands.length,
      2,
      reason:
          '整个表格选中后只该有上下两条外框，实际数到 ${bands.length} 条 '
          '(${bands.map((List<int> b) => b.first).join(",")})：又是每行一圈',
    );
    // …and the two of them span the whole table: header + two body rows.
    final int span = bands.last.first - bands.first.first;
    expect(
      span,
      closeTo(3 * px.rowHeight, 2),
      reason: '外框高度 ${span}px 应该正好是三行（每行 ${px.rowHeight}px）',
    );

    // No paper showing *inside* the band: the wash is one continuous shape, not
    // per-cell boxes with grid-coloured gaps between them.
    final int left =
        px.firstOf(px.palette.selectionEdge, bands.first.last + 4) + 3;
    final int right =
        px.lastOf(px.palette.selectionEdge, bands.last.last - 4) - 3;
    for (int y = bands.first.last + 4; y < bands.last.first - 3; y++) {
      for (int x = left; x < right; x++) {
        expect(
          px.isSurface(x, y),
          isFalse,
          reason: 'band 内部 ($x,$y) 还是纸色：色带被网格线切开了',
        );
      }
    }
  });

  testWidgets('a drag keeps the table washed as one block with reveal frozen', (
    WidgetTester tester,
  ) async {
    // Pointer-down freezes marker reveal for the whole gesture, and the table's
    // bands used to be measured from that frozen caret. The field's selection
    // painter followed the *live* range instead, so mid-drag the table showed
    // one prose stripe per row — with the seam between rows and no block
    // outline — and only snapped back on release. user: 「选中表格的效果不对，
    // 不应该是一行行选，而是直接选中整个表格。」
    const String text = '| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n';
    final _Pixels px = await shoot(
      tester,
      text,
      const TextSelection(baseOffset: 0, extentOffset: 43),
      // What was painted when the drag started: a bare caret at the anchor.
      frozen: const TextSelection.collapsed(offset: 0),
    );

    final List<List<int>> bands = px.bandsOf(px.palette.selectionEdge, 40);
    expect(
      bands.length,
      2,
      reason: '冻结揭示时表格被画成了一行行的正文色带（只数到 ${bands.length} 条外框）',
    );
    expect(
      bands.last.first - bands.first.first,
      closeTo(3 * px.rowHeight, 2),
      reason: '冻结期间外框也该跨满三行表格',
    );

    // No paper seam between the rows: the opaque table wash has to sit on top of
    // the prose stripes, not let them through line by line.
    final int left =
        px.firstOf(px.palette.selectionEdge, bands.first.first) + 6;
    final int right =
        px.lastOf(px.palette.selectionEdge, bands.first.first) - 6;
    for (int y = bands.first.first + 3; y < bands.last.first - 3; y++) {
      for (int x = left; x < right; x++) {
        expect(
          px.isSurface(x, y),
          isFalse,
          reason: '冻结期间表格内部 ($x,$y) 露出了纸色：又是按行选中',
        );
      }
    }
  });

  testWidgets('the wash ends on the last selected row', (
    WidgetTester tester,
  ) async {
    // Selecting the header plus the first body row has to close the outline
    // after that row — not after the table, and not after every row.
    const String text = '| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n';
    const String twoRows = '| a | b |\n| --- | --- |\n| c | d |';
    final _Pixels px = await shoot(
      tester,
      text,
      // Through the end of `| c | d |` — the newline after it is outside.
      const TextSelection(baseOffset: 0, extentOffset: 33),
    );
    final List<List<int>> bands = px.bandsOf(px.palette.selectionEdge, 40);

    expect(bands.length, 2, reason: '上下各一条，不能每行都封一次口');
    expect(
      bands.last.first - bands.first.first,
      closeTo(2 * px.rowHeight, 2),
      reason:
          '选中的是两行（${twoRows.split("\n").length} 行源码，含分隔行），'
          '外框却跨了 ${bands.last.first - bands.first.first}px',
    );
  });
  testWidgets('a selection inside one table washes only the cells it covers', (
    WidgetTester tester,
  ) async {
    // Part of a table must be selectable, and **by the cell**: the selection
    // snaps out to whole cells, so touching `b` washes all of `b`'s cell.
    // Washing whole *rows* (which is what this used to do) meant the only way
    // to select part of a table was to select all of it — user:
    // 「表格让我可以只选取其中一部分」. Cutting the wash at the glyph instead
    // (what this did last) is the opposite mistake: it reads as text selected
    // across a table, which is not a thing — user:
    // 「这个选中就是按格子来选中啊，跨表格选中文字干什么？？？」
    const String text = '| a | b |\n| --- | --- |\n| c | d |\n';
    final _Pixels all = await shoot(
      tester,
      text,
      const TextSelection(baseOffset: 0, extentOffset: 33),
    );
    final _Pixels part = await shoot(
      tester,
      text,
      // From `b` through `d`: the right-hand column, both rows. A **block**,
      // not a staircase — see the expectation below.
      const TextSelection(baseOffset: 6, extentOffset: 31),
    );

    final List<List<int>> full = all.bandsOf(all.palette.selectionEdge, 40);
    // 20, not 40: the whole point is that the band is narrower than the table.
    final List<List<int>> cut = part.bandsOf(part.palette.selectionEdge, 20);
    // Two horizontal edges — the top of `b`'s row and the bottom of `d`'s — and
    // nothing in between. ⛔ Not three: a step at the row boundary would mean
    // the wash followed the *text range* (`b`, then `c` and `d` on the way
    // down), and that is the very thing this selection model exists to kill —
    // dragging down one column would light up the left-hand cells of every row
    // in between. user: 「我只选了右边三个表格，为什么会把左边那两个一起选中？？？」
    //
    // So the band is the intersection of the rows and the columns the two ends
    // span: one rectangle, whichever way the drag went.
    expect(cut.length, 2, reason: '按格子成块：只有上边和下边，中间不该有台阶');

    // The band's top edge says exactly how wide it is — the outline is the one
    // thing painted in the accent with no wash or glyph in the way. Both frames
    // are the same document, so the table sits at the same y in both.
    final int cutTop = full.first.first;
    final int fullTop = full.first.first;
    int run(_Pixels px, int y) {
      int n = 0;
      for (int x = 0; x < px.width; x++) {
        if (px.isColor(px.palette.selectionEdge, x, y, tolerance: 24)) n++;
      }
      return n;
    }

    expect(
      run(part, cutTop),
      lessThan(run(all, fullTop) - 20),
      reason: '选区的上边框和整个表格一样长：色带还是铺满了行',
    );
    final int left = part.firstOf(part.palette.selectionEdge, cutTop);
    final int fullLeft = all.firstOf(all.palette.selectionEdge, fullTop);
    expect(
      left,
      greaterThan(fullLeft + 60),
      reason: '选区没有开始的那一列不该被染上颜色，色带却从 $left 就开始了',
    );
    // Everything left of it is still paper (bar the cell's own glyph), one line
    // down, inside the band. Measured against the full-width selection, where
    // that same stretch is wash from end to end.
    final int y = cutTop + 12;
    int painted(_Pixels px) {
      int n = 0;
      for (int x = fullLeft + 8; x < left - 6; x++) {
        if (!px.isSurface(x, y)) n++;
      }
      return n;
    }

    expect(
      painted(part),
      lessThan(painted(all) ~/ 3),
      reason: '选区左边那一列被涂了 ${painted(part)}px，整表选中时才 ${painted(all)}px',
    );
  });

  testWidgets('an inline code band in a cell cannot cover the table border', (
    WidgetTester tester,
  ) async {
    // The skeleton that gives the paragraph its caret positions shares the line
    // with the row. A `code` span in a cell used to paint its band at the
    // *paragraph's* metrics — a full 28px line — so the band hung below the row
    // and swallowed the block's bottom border (and the caret's feet).
    const String text = '| a | `code` |\n| --- | --- |\n| b | c |';
    final _Pixels px = await shoot(
      tester,
      text,
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    final List<List<int>> bands = px.bandsOf(px.palette.selectionEdge, 120);
    expect(bands.length, 2, reason: '只有外框上下的两条，代码本身不算');

    final int left =
        px.firstOf(px.palette.selectionEdge, bands.first.last + 6) + 6;
    final int right =
        px.lastOf(px.palette.selectionEdge, bands.first.last + 6) - 6;
    for (int x = left; x < right; x++) {
      expect(
        px.isColor(
          px.palette.selectionEdge,
          x,
          bands.last.first,
          tolerance: 40,
        ),
        isTrue,
        reason: '底边框在 x=$x 处被格子里的代码色带盖掉了',
      );
    }
  });

  testWidgets('an inline code chip pads and rounds its own ends', (
    WidgetTester tester,
  ) async {
    // Obsidian and Typora draw inline code as a padded, rounded chip. A
    // TextStyle background is always a rectangle flush with the glyphs, so the
    // two backticks stand in as padded end caps. This checks the painted
    // result: one continuous band, wider than the code on both sides, with the
    // corners cut.
    const String text = '前 `code` 后';
    final _Pixels px = await shoot(
      tester,
      text,
      const TextSelection.collapsed(offset: 0),
    );
    final RenderEditable re = editable(tester);
    final Offset origin = re.localToGlobal(Offset.zero);
    final Rect code = re
        .getBoxesForSelection(
          const TextSelection(baseOffset: 3, extentOffset: 7),
        )
        .first
        .toRect()
        .shift(origin);

    bool fill(int x, int y) =>
        px.isColor(px.palette.surfaceSunken, x, y, tolerance: 8);

    // The widest filled row of the band around the code is the one to measure:
// it runs end to end, while the rounded rows at the band's top and bottom
// are inset by the corner radius — and a row of the glyphs themselves is
// punched through by the ink. The window reaches past the box the field
// reports: that box is the *line's*, and the chip hangs inside it.
    int bandY = -1;
    int widest = 0;
    for (int y = code.top.round() - 12; y < code.bottom.round(); y++) {
      int n = 0;
      for (int x = 0; x < px.width; x++) {
        if (fill(x, y)) n++;
      }
      if (n > widest) {
        widest = n;
        bandY = y;
      }
    }
    expect(bandY, greaterThanOrEqualTo(0), reason: '代码没有任何底色');
    expect(widest, greaterThan(20), reason: '找到的色带只有几个像素，不是一整条');

    int leftAt(int y) {
      for (int x = 0; x < px.width; x++) {
        if (fill(x, y)) return x;
      }
      return -1;
    }

    int rightAt(int y) {
      for (int x = px.width - 1; x >= 0; x--) {
        if (fill(x, y)) return x;
      }
      return -1;
    }

    final int left = leftAt(bandY);
    final int right = rightAt(bandY);
    expect(left, greaterThanOrEqualTo(0));
    expect(
      left,
      lessThanOrEqualTo(code.left.round() - 3),
      reason: '代码左边没有内边距，色带仍然贴着字',
    );
    expect(
      right,
      greaterThanOrEqualTo(code.right.round() + 2),
      reason: '代码右边没有内边距，色带仍然贴着字',
    );

    // The corner: the band's top edge is found by walking up from the widest
    // row, because where the edge lands inside a row depends on the pixel grid
    // (and moved when the field lost its hint). What matters is the shape: at
    // the top row the leftmost filled column is paper, while a few pixels in
    // the fill is already there. A rectangle would keep both filled.
    int bandTop = bandY;
    while (bandTop > 0 && fill(left, bandTop - 1)) {
      bandTop--;
    }
    expect(bandTop, greaterThan(0), reason: '代码色带找不到上沿');
    expect(fill(left, bandTop - 1), isFalse, reason: '圆角没有切出来：色带左上角还是实心的');
    expect(fill(left + 4, bandTop - 1), isTrue, reason: '圆角削掉了端部整整一行，色带的上沿不平');
  });

  testWidgets('inline code in a table cell is a padded, rounded chip', (
    WidgetTester tester,
  ) async {
    // A cell is a TextPainter — it cannot host the prose chip's widget end
    // caps. The row renderer has to paint the band itself, and the two
    // collapsed backticks carry the padding as their advance. user:
    // 「表格里的代码样式也要一起改一下」.
    const String text = 'intro\n\n| 前 `code` 后 |\n| --- |\n| x |\n';
    final _Pixels px = await shoot(
      tester,
      text,
      const TextSelection.collapsed(offset: 0),
    );
    final RenderEditable re = editable(tester);
    final Offset origin = re.localToGlobal(Offset.zero);
    final int at = text.indexOf('`code`');
    expect(at, greaterThan(0));

    /// The union of the paragraph's boxes for a source range. A range comes
    /// back in pieces (one per run) — `.first` saw nothing but the leading
    /// backtick's padding, which made the scan window cut the band in half.
    Rect box(int from, int to) {
      final List<TextBox> boxes = re.getBoxesForSelection(
        TextSelection(baseOffset: from, extentOffset: to),
      );
      expect(boxes, isNotEmpty);
      double left = boxes.first.left;
      double top = boxes.first.top;
      double right = boxes.first.right;
      double bottom = boxes.first.bottom;
      for (final TextBox b in boxes) {
        if (b.left < left) left = b.left;
        if (b.top < top) top = b.top;
        if (b.right > right) right = b.right;
        if (b.bottom > bottom) bottom = b.bottom;
      }
      return Rect.fromLTRB(left, top, right, bottom).shift(origin);
    }

    final Rect token = box(at, at + 6);
    final Rect inner = box(at + 1, at + 5);

    // tolerance 4, not 24 or 8: the grid's `outlineSoft` sits within 8 of
    // `surfaceSunken`, so a looser match reads the table's rules as chip fill.
    bool fill(int x, int y) =>
        px.isColor(px.palette.surfaceSunken, x, y, tolerance: 4);

    final int left = (token.left - 4).round().clamp(0, px.width - 1);
    final int right = (token.right + 4).round().clamp(0, px.width - 1);
    int countAt(int y) {
      int n = 0;
      for (int x = left; x <= right; x++) {
        if (fill(x, y)) n++;
      }
      return n;
    }

    int leftAt(int y) {
      for (int x = left; x <= right; x++) {
        if (fill(x, y)) return x;
      }
      return -1;
    }

    int rightAt(int y) {
      for (int x = right; x >= left; x--) {
        if (fill(x, y)) return x;
      }
      return -1;
    }

    // The chip's interior: the rows inside the token that carry a run of fill.
    // Its first and last give the band's height.
    int top = -1;
    int bottom = -1;
    for (
      int y = (token.top - 10).round();
      y <= (token.bottom + 10).round();
      y++
    ) {
      if (y < 0 || y >= px.height) continue;
      if (countAt(y) >= 6) {
        if (top < 0) top = y;
        bottom = y;
      }
    }
    expect(top, greaterThanOrEqualTo(0), reason: '表格里的代码没有底色');
    expect(bottom - top, greaterThanOrEqualTo(16), reason: '代码底色只有一条细线');

    final int mid = (top + bottom) ~/ 2;
    final int bandLeft = leftAt(mid);
    final int bandRight = rightAt(mid);
    expect(
      bandLeft,
      lessThanOrEqualTo(inner.left.round() - 3),
      reason: '代码左边没有内边距',
    );
    expect(
      bandRight,
      greaterThanOrEqualTo(inner.right.round() + 2),
      reason: '代码右边没有内边距',
    );

    // The rounded corner: on the top row the fill begins further in than it
    // does a few rows down. A rectangle would start on the same column.
    final int topLeft = leftAt(top);
    expect(topLeft, greaterThan(leftAt(top + 5)), reason: '圆角没有切出来：色带左上角还是实心的');
  });

  testWidgets('a caret inside inline code tears the chip down to source', (
    WidgetTester tester,
  ) async {
    // user: 「选中后没有恢复成编辑态」. The old chip kept its fill and accent
    // while the caret was inside the token, so it still looked rendered. It
    // has to drop the fill and show both backticks instead.
    const String text = '前 `code` 后';
    const int at = 5; // Inside the code.
    final _Pixels px = await shoot(
      tester,
      text,
      const TextSelection.collapsed(offset: at),
    );
    int fill = 0;
    for (int y = 0; y < px.height; y++) {
      for (int x = 0; x < px.width; x++) {
        if (px.isColor(px.palette.surfaceSunken, x, y, tolerance: 8)) fill++;
      }
    }
    expect(fill, 0, reason: '光标已经在代码里，底色却没有消失');

    final InlineSpan? tree = editable(tester).text;
    expect(tree, isNotNull);
    expect(
      tree!.toPlainText(),
      isNot(contains('\uFFFC')),
      reason: '编辑态还留着作为端帽的 widget，代码没有变回源码',
    );
    expect(tree.toPlainText(), contains('`code`'));
  });

  testWidgets('the caret is painted over a code block band', (
    WidgetTester tester,
  ) async {
    // Windows paints the caret *under* the text, so an opaque run background
    // covered it whole: 「行内代码挡住了输入光标」. The field's render object
    // must paint the caret last, above whatever the spans draw. Inline code no
    // longer paints a band under its own caret, but a fenced block still does.
    EditableText.debugDeterministicCursor = true;
    addTearDown(() => EditableText.debugDeterministicCursor = false);
    const String text = '```\ncode\n```\n';
    const int at = 5; // Inside the code line.
    final _Pixels px = await shoot(
      tester,
      text,
      const TextSelection.collapsed(offset: at),
    );
    final RenderEditable re = editable(tester);
    final Rect caret = re
        .getLocalRectForCaret(const TextPosition(offset: at))
        .shift(re.localToGlobal(Offset.zero));
    int visible = 0;
    for (int y = caret.top.round(); y < caret.bottom.round(); y++) {
      for (int x = caret.left.round() - 1; x <= caret.right.round(); x++) {
        if (px.isColor(px.palette.accent, x, y, tolerance: 8)) visible++;
      }
    }
    expect(
      visible,
      greaterThan((caret.height / 2).round()),
      reason: '光标被代码块的底色盖住了：${caret.height.round()} 行里只有 $visible 个光标像素',
    );
  });
}

class _Pixels {
  _Pixels(this.width, this.height, this.bytes, this.palette);

  final int width;
  final int height;
  final ByteData bytes;
  final AppPalette palette;

  /// Height of one editor line at the test's font size. Everything vertical in
  /// the table tests is expressed in rows, so hard-coding it here keeps the
  /// assertions readable.
  double get rowHeight => 28;

  (int, int, int) at(int x, int y) {
    final int i = (y * width + x) * 4;
    return (bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
  }

  bool isColor(Color color, int x, int y, {int tolerance = 10}) {
    final int argb = color.toARGB32();
    final (int, int, int) c = at(x, y);
    return (c.$1 - (argb >> 16 & 0xFF)).abs() <= tolerance &&
        (c.$2 - (argb >> 8 & 0xFF)).abs() <= tolerance &&
        (c.$3 - (argb & 0xFF)).abs() <= tolerance;
  }

  bool isSurface(int x, int y) => isColor(palette.surface, x, y, tolerance: 6);

  /// Horizontal runs where more than [minRun] pixels carry [color] — i.e. the
  /// rows of a box outline, grouped into bands of consecutive lines.
  List<List<int>> bandsOf(Color color, int minRun) {
    final List<List<int>> bands = <List<int>>[];
    int run = 0;
    for (int y = 0; y < height; y++) {
      int n = 0;
      for (int x = 0; x < width; x++) {
        if (isColor(color, x, y, tolerance: 24)) n++;
      }
      if (n >= minRun) {
        if (run == 0 || bands.last.last != y - 1) {
          bands.add(<int>[y]);
        } else {
          bands.last.add(y);
        }
        run++;
      }
    }
    return bands;
  }

  int firstOf(Color color, int y) {
    for (int x = 0; x < width; x++) {
      if (isColor(color, x, y, tolerance: 24)) return x;
    }
    return -1;
  }

  int lastOf(Color color, int y) {
    for (int x = width - 1; x >= 0; x--) {
      if (isColor(color, x, y, tolerance: 24)) return x;
    }
    return -1;
  }
}
