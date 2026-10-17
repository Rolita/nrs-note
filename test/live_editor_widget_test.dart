import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/data/models/note.dart';
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
            focusNode: FocusNode(),
            scrollController: ScrollController(),
            fontSize: 15.5,
            hintText: '',
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
    const String text = '# 标题\n\n- 列表\n- [ ] 待办\n\n---\n\n> 引用\n\n```\ncode\n```\n';
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

  testWidgets('tapping a tag pill reports the tag', (WidgetTester tester) async {
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
      final TextPosition got = re.getPositionForPoint(re.localToGlobal(box.center));
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
    final MarkdownSourceController controller = await pump(
      tester,
      '普通段落\n- 甲\n1. 乙\n',
    );
    await tester.tap(find.byKey(const Key('nrs-editor-field')));
    await tester.pump();

    // Caret at the end of the `- 甲` line — `普通段落\n- 甲` is 8 characters.
    const int caret = 8;
    expect(controller.text.substring(0, caret), '普通段落\n- 甲');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '普通段落\n- 甲\n\n1. 乙\n',
        selection: TextSelection.collapsed(offset: caret + 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.text, '普通段落\n- 甲\n- \n1. 乙\n');
    expect(
      controller.selection.baseOffset,
      caret + 3,
      reason: '光标应落在新记号之后',
    );
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

  testWidgets('the highlight of a selection tiles line to line', (
    WidgetTester tester,
  ) async {
    // A paragraph paints each line's highlight as its own rectangle, sized
    // `fontSize * height`, but it *advances* by the rounded product. A ratio
    // that leaves a fraction — `15.5 * 1.78 = 27.59` against a 28px step —
    // makes every band 0.41px shorter than the gap to the next one, so a
    // multi-line selection reads as a stack of stripes with the paper showing
    // through between them (43% lighter at the seam, measured on the real
    // widget). See `snapLineHeight`.
    const String text =
        '# 标题一\n'
        '## 标题二\n'
        '\n'
        '普通段落，含 **粗体** 与 `代码`。\n'
        '\n'
        '带 #标签 和 [[双链]] 的一行\n'
        '\n'
        '- 无序项\n'
        '- [ ] 待办事项\n'
        '1. [x] 有序待办\n'
        '\n'
        '> 引用\n'
        '\n'
        '---\n'
        '\n'
        '```dart\n'
        'final int a = 1;\n'
        '```\n';
    final MarkdownSourceController controller = await pump(tester, text);
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: text.length,
    );
    await tester.pumpAndSettle();

    // One line emits one box per run, so group them by their y-range to get a
    // single band per line.
    final Map<String, double> bands = <String, double>{};
    for (final TextBox box in editable(
      tester,
    ).getBoxesForSelection(controller.selection)) {
      if (box.top == box.bottom) continue;
      bands.putIfAbsent(
        box.top.toStringAsFixed(3),
        () => double.parse(box.bottom.toStringAsFixed(3)),
      );
    }
    final List<double> tops =
        bands.keys.map(double.parse).toList()..sort();
    expect(tops.length, greaterThan(10), reason: '没有测到足够的行');
    for (int i = 1; i < tops.length; i++) {
      final double gap = tops[i] - bands[tops[i - 1].toStringAsFixed(3)]!;
      expect(
        gap.abs(),
        lessThanOrEqualTo(0.05),
        reason:
            '第 ${i + 1} 行的选区高亮和上一行之间有 '
            '${gap.toStringAsFixed(3)}px 的缝（行高必须落在整数像素上，'
            '见 live_markdown.dart 的 snapLineHeight）',
      );
    }
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
}
