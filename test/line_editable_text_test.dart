import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/live_line_style.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';

/// 测试字体（Ahem）每个字形都是 [fontSize] 见方，行高 `16 * 1.5 = 24`。
const TextStyle _style = TextStyle(fontSize: 16, height: 1.5);
const double _row = 24;

Widget _host(
  TextEditingController controller,
  FocusNode focusNode,
  double width, {
  LiveLineStyle? styles,
  double? height = 400,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          height: height,
          child: LineEditableText(
            controller: controller,
            focusNode: focusNode,
            style: _style,
            cursorColor: const Color(0xFF000000),
            backgroundCursorColor: const Color(0xFFBBBBBB),
            selectionColor: const Color(0x33000000),
            maxLines: null,
            lineStyleFor: styles?.styleFor,
            lineHeightFor: styles?.heightFor,
            lineInsetFor: styles?.insetFor,
          ),
        ),
      ),
    ),
  );
}

RenderLineEditable _render(WidgetTester tester) {
  final LineEditableTextState state = tester.state<LineEditableTextState>(
    find.byType(LineEditableText),
  );
  return state.renderEditable as RenderLineEditable;
}

/// 桌面端的鼠标拖选才有意义；测试结束后必须复位，否则框架会报调试变量泄漏。
Future<void> _desktop(WidgetTester tester, Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets('空文档可以排版，行高为正', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final TextEditingController controller = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      final RenderLineEditable render = _render(tester);

      expect(render.preferredLineHeight, closeTo(_row, 0.01));
      expect(render.size.width, 360);
    });
  });

  test('reuses painters for unchanged lines and shifts their visuals', () {
    final LineLayoutCache cache = LineLayoutCache();
    addTearDown(cache.dispose);
    String document(String middle) => '第一行\n$middle\n第三行\n第四行';

    final LineDocumentLayout before = layoutLines(
      text: document('中间'),
      baseStyle: _style,
      contentWidth: 300,
      cache: cache,
    );
    final LineDocumentLayout after = layoutLines(
      text: document('中间改'),
      baseStyle: _style,
      contentWidth: 300,
      cache: cache,
    );

    // 未变行：painter 与高度原样复用。
    expect(identical(before.laidOut[0].painter, after.laidOut[0].painter), isTrue);
    expect(after.laidOut[0].height, before.laidOut[0].height);

    // 改动行：不能复用。
    expect(identical(before.laidOut[1].painter, after.laidOut[1].painter), isFalse);

    // 后续未变行的偏移整体 +1，但 painter 仍复用。
    expect(identical(before.laidOut[2].painter, after.laidOut[2].painter), isTrue);
    expect(
      after.laidOut[2].visuals.first.start,
      before.laidOut[2].visuals.first.start + 1,
    );
    expect(
      after.laidOut[2].visuals.first.end,
      before.laidOut[2].visuals.first.end + 1,
    );

    before.dispose();
    after.dispose();
  });

  testWidgets('dry layout agrees with the real layout for plain text', (
    WidgetTester tester,
  ) async {
    await _desktop(tester, () async {
      // 让 2000 行文档完整展开，而不是被 600px 的测试视口截断。
      tester.view.physicalSize = const Size(400, 60000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final List<String> documents = <String>[
        '',
        '一行',
        List<String>.generate(2000, (int i) => '第 $i 行').join('\n'),
      ];
      for (final String text in documents) {
        final TextEditingController controller = TextEditingController(
          text: text,
        );
        final FocusNode focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(_host(controller, focusNode, 360, height: null));
        final RenderLineEditable render = _render(tester);

        // 宽度不同 → 缓存不命中，走估算分支；纯文本每行都不折行，
        // 估算必须与真实布局逐像素一致。
        final Size dry = render.computeDryLayout(
          const BoxConstraints.tightFor(width: 300),
        );
        expect(
          dry.height,
          closeTo(render.size.height, 0.01),
          reason: 'dry layout 与真实布局高度不一致',
        );
      }
    });
  });

  testWidgets('光标 x 随偏移单调递增', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final TextEditingController controller = TextEditingController(
        text: 'abc',
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      final RenderLineEditable render = _render(tester);

      final Rect head = render.getLocalRectForCaret(
        const TextPosition(offset: 0),
      );
      final Rect tail = render.getLocalRectForCaret(
        const TextPosition(offset: 3),
      );
      expect(head.left, 0);
      expect(tail.left, greaterThan(head.left));
      expect(tail.top, closeTo(head.top, 0.01));
    });
  });

  testWidgets('点击第二行把光标放到第二行', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final TextEditingController controller = TextEditingController(
        text: 'aaa\nbbb',
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      final RenderLineEditable render = _render(tester);
      final Offset origin = render.localToGlobal(Offset.zero);

      await tester.tapAt(origin + const Offset(20, _row + 10));
      await tester.pump();

      expect(controller.selection.extentOffset, inInclusiveRange(4, 7));
    });
  });

  // 裸 `EditableText` 本身不带拖选识别器（SDK 里由 `TextField` 的
  // `TextSelectionGestureDetectorBuilder` 提供），所以这里直接调用手势层最终
  // 会调用的入口 `selectPositionAt`，验证的是行布局的命中与几何。
  testWidgets('跨行拖选得到多块选区几何', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final TextEditingController controller = TextEditingController(
        text: 'aaa\nbbb\nccc',
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      final RenderLineEditable render = _render(tester);
      final Offset origin = render.localToGlobal(Offset.zero);

      render.selectPositionAt(
        from: origin + const Offset(2, 10),
        to: origin + const Offset(30, _row * 2 + 10),
        cause: SelectionChangedCause.drag,
      );
      await tester.pump();

      expect(controller.selection.isCollapsed, isFalse);
      final List<TextBox> boxes = render.getBoxesForSelection(
        controller.selection,
      );
      expect(boxes.length, greaterThanOrEqualTo(2));
      expect(boxes.last.top, greaterThan(boxes.first.top));
    });
  });

  testWidgets('从下往上拖选时方向相反', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final TextEditingController controller = TextEditingController(
        text: 'aaa\nbbb\nccc',
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      final RenderLineEditable render = _render(tester);
      final Offset origin = render.localToGlobal(Offset.zero);

      render.selectPositionAt(
        from: origin + const Offset(30, _row * 2 + 10),
        to: origin + const Offset(2, 10),
        cause: SelectionChangedCause.drag,
      );
      await tester.pump();

      expect(controller.selection.isValid, isTrue);
      expect(
        controller.selection.extentOffset,
        lessThan(controller.selection.baseOffset),
      );
    });
  });

  testWidgets('IME 组字区间可写入并给出几何', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final TextEditingController controller = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      // fork 后的 state 类型不是 `EditableTextState`，不能用
      // `tester.showKeyboard`（它按 SDK 类型取 state），直接请求焦点即可。
      focusNode.requestFocus();
      await tester.pump();
      final RenderLineEditable render = _render(tester);

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '你好',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();

      expect(controller.text, '你好');
      expect(controller.selection.baseOffset, 2);
      expect(controller.value.composing, const TextRange(start: 0, end: 2));
      expect(
        render.getRectForComposingRange(controller.value.composing),
        isNotNull,
      );
    });
  });

  testWidgets('方向键与 Home/End 不越界', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final TextEditingController controller = TextEditingController(
        text: 'abc',
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      focusNode.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controller.selection.extentOffset, 2);

      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(controller.selection.extentOffset, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(controller.selection.extentOffset, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(controller.selection.extentOffset, 3);
    });
  });

  testWidgets('有序列表续行从正文列开始（悬挂缩进）', (WidgetTester tester) async {
    await _desktop(tester, () async {
      const String text = '1. 这是一段很长的有序列表正文，用来验证第二条视觉行从序号之后开始而不是行首';
      final TextEditingController controller = TextEditingController(
        text: text,
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 200));
      final RenderLineEditable render = _render(tester);

      final LineDocumentLayout layout = layoutLines(
        text: text,
        baseStyle: _style,
        contentWidth: 200,
      );
      addTearDown(layout.dispose);

      final LaidOutLine line = layout.laidOut.first;
      expect(line.visuals.length, greaterThan(1));
      expect(line.gutter, greaterThan(20));

      final int secondStart = line.visuals[1].start;
      final Rect caret = render.getLocalRectForCaret(
        TextPosition(offset: secondStart),
      );
      expect(caret.left, closeTo(line.gutter, 0.01));
      expect(caret.top, closeTo(_row, 1));
    });
  });

  testWidgets('多行文档每行高度恒为 24', (WidgetTester tester) async {
    await _desktop(tester, () async {
      final String text = List<String>.generate(
        50,
        (int i) => 'line $i',
      ).join('\n');
      final TextEditingController controller = TextEditingController(
        text: text,
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 360));
      final RenderLineEditable render = _render(tester);

      for (final int lineIndex in <int>[0, 1, 25, 49]) {
        final int offset = text
            .split('\n')
            .take(lineIndex)
            .fold<int>(0, (int sum, String line) => sum + line.length + 1);
        final Rect caret = render.getLocalRectForCaret(
          TextPosition(offset: offset),
        );
        expect(caret.top, closeTo(lineIndex * _row, 1));
      }
    });
  });

  testWidgets('点击列表标记槽位时光标吸附到正文列', (WidgetTester tester) async {
    await _desktop(tester, () async {
      const String text = '- 项目内容需要足够长才能撑开这一行文字并确认槽位点击行为';
      final TextEditingController controller = TextEditingController(
        text: text,
      );
      final FocusNode focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(_host(controller, focusNode, 320));
      final RenderLineEditable render = _render(tester);
      final Offset origin = render.localToGlobal(Offset.zero);

      await tester.tapAt(origin + const Offset(4, 10));
      await tester.pump();

      expect(controller.selection.extentOffset, 2);
    });
  });

  group('live 行样式', () {
    final LiveLineStyle styles = LiveLineStyle(
      base: _style,
      palette: AppPalette.light,
    );

    test('标题放大、代码等宽、围栏折叠', () {
      final List<SourceLine> lines = scanSourceLines(
        '# 标题\n正文\n```dart\nfinal x = 1;\n```\n- 项',
      );

      expect(lines[0].kind, LineBlockKind.heading);
      expect(styles.styleFor(lines[0]).fontSize, greaterThan(16));
      expect(styles.styleFor(lines[1]).fontSize, 16);
      expect(styles.styleFor(lines[3]).fontFamily, AppFonts.mono);
      expect(styles.heightFor(lines[2]), 16);
      expect(styles.heightFor(lines[4]), 0);
      expect(styles.heightFor(lines[0]), isNull);
    });

    test('代码行与围栏行让出卡片内边距，其余行贴边', () {
      final List<SourceLine> lines = scanSourceLines('正文\n```dart\n代码\n```');

      expect(styles.insetFor(lines[0]), EdgeInsets.zero);
      expect(
        styles.insetFor(lines[1]),
        const EdgeInsets.symmetric(horizontal: 16),
      );
      expect(
        styles.insetFor(lines[2]),
        const EdgeInsets.symmetric(horizontal: 16),
      );
      expect(
        styles.insetFor(lines[3]),
        const EdgeInsets.symmetric(horizontal: 16),
      );
    });

    test('代码行按 token 着色，字符账不变', () {
      final String text = '```dart\nfinal x = 1;\n```';
      final List<SourceLine> lines = scanSourceLines(text);
      final LiveLineStyle styled = LiveLineStyle(
        base: _style,
        palette: AppPalette.light,
        source: text,
      );
      final InlineSpan span = styled.spanFor(lines[1]);

      expect(span.toPlainText(), 'final x = 1;');
      final Set<Color> colors = <Color>{
        for (final InlineSpan part in (span as TextSpan).children ?? const [])
          if (part.style?.color != null) part.style!.color!,
      };
      // 关键字、数字与普通标识符至少有两种颜色，说明确实走了高亮而不是纯文本。
      expect(colors.length, greaterThan(1));
    });

    test('标签行铺胶囊底片，源码原样留在 span 树里', () {
      final SourceLine line = scanSourceLines('前 #日常 后').single;
      final List<LineFillRun> fills = styles.fillsFor(line);

      expect(fills, hasLength(1));
      expect(line.text.substring(fills.single.from, fills.single.to), '#日常');
      expect(fills.single.fill, AppPalette.light.accentSoft);
      expect(fills.single.radius, 5);
      expect(fills.single.padX, 6);
      // 胶囊只改变字形样式，字符账必须和源码逐字相同。
      expect(styles.spanFor(line).toPlainText(), line.text);
    });

    test('悬停的标签换成实心胶囊与 on-accent 字', () {
      final SourceLine line = scanSourceLines('前 #日常 后').single;
      final LiveLineStyle lit = LiveLineStyle(
        base: styles.base,
        palette: AppPalette.light,
        hoverTag: const TextRange(start: 2, end: 5),
      );

      expect(lit.fillsFor(line).single.fill, AppPalette.light.accent);
      final TextSpan span = lit.spanFor(line) as TextSpan;
      final TextSpan tag = span.children!.whereType<TextSpan>().firstWhere(
        (TextSpan s) => s.text == '#日常',
      );
      expect(tag.style!.color, AppPalette.light.onAccent);
    });

    testWidgets('代码行的光标退进卡片内边距', (WidgetTester tester) async {
      await _desktop(tester, () async {
        const String text = '```dart\nabc\n```';
        final TextEditingController controller = TextEditingController(
          text: text,
        );
        final FocusNode focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          _host(controller, focusNode, 360, styles: styles),
        );
        final RenderLineEditable render = _render(tester);

        final Rect caret = render.getLocalRectForCaret(
          TextPosition(offset: text.indexOf('abc')),
        );
        expect(caret.left, closeTo(16, 0.01));
      });
    });

    testWidgets('标题行按级别放大，正文行回到正文行高', (WidgetTester tester) async {
      await _desktop(tester, () async {
        const String text = '# 标题\n正文';
        final TextEditingController controller = TextEditingController(
          text: text,
        );
        final FocusNode focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          _host(controller, focusNode, 360, styles: styles),
        );
        final RenderLineEditable render = _render(tester);

        final LineDocumentLayout layout = layoutLines(
          text: text,
          baseStyle: _style,
          contentWidth: 360,
          styleFor: styles.styleFor,
          heightFor: styles.heightFor,
        );
        addTearDown(layout.dispose);

        final double heading = layout.laidOut.first.height;
        expect(heading, greaterThan(_row));
        expect(
          render.getLocalRectForCaret(const TextPosition(offset: 0)).top,
          closeTo(0, 1),
        );
        expect(
          render
              .getLocalRectForCaret(TextPosition(offset: text.indexOf('正文')))
              .top,
          closeTo(heading, 1),
        );
      });
    });

    testWidgets('代码块：开围栏 16px、闭围栏压成 0', (WidgetTester tester) async {
      await _desktop(tester, () async {
        const String text = '```dart\nfinal x = 1;\n```\n正文';
        final TextEditingController controller = TextEditingController(
          text: text,
        );
        final FocusNode focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          _host(controller, focusNode, 360, styles: styles),
        );
        final RenderLineEditable render = _render(tester);

        final LineDocumentLayout layout = layoutLines(
          text: text,
          baseStyle: _style,
          contentWidth: 360,
          styleFor: styles.styleFor,
          heightFor: styles.heightFor,
        );
        addTearDown(layout.dispose);

        expect(layout.laidOut[0].height, 16);
        expect(layout.laidOut[2].height, 0);
        final double codeRow = layout.laidOut[1].height;
        expect(codeRow, lessThan(_row));

        expect(
          render
              .getLocalRectForCaret(TextPosition(offset: text.indexOf('正文')))
              .top,
          closeTo(16 + codeRow, 1),
        );
      });
    });

    testWidgets('闪烁开关一变就请求重画，光标才会真的闪', (WidgetTester tester) async {
      await _desktop(tester, () async {
        final TextEditingController controller = TextEditingController(
          text: '正文',
        );
        final FocusNode focusNode = FocusNode();
        addTearDown(controller.dispose);
        addTearDown(focusNode.dispose);

        await tester.pumpWidget(
          _host(controller, focusNode, 360, styles: styles),
        );
        final RenderLineEditable render = _render(tester);
        await tester.pump();
        expect(render.debugNeedsPaint, isFalse, reason: '先把上一帧画干净');

        // 光标画在本类的 `paint` 里，父类那条闪烁链路只重画它自己的子绘制
        // 对象；少了这个监听，闪烁只改状态、不重画，光标要等下次点击才更新。
        render.showCursor.value = false;
        expect(render.debugNeedsPaint, isTrue);
      });
    });
  });
}
