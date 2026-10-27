import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/app.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/highlight_colors.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/core/utils/table_selection.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/ui/editor/selection_wash.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/live_markdown.dart'
    show ImageBlockChrome, ImageLineBlock, kTagPadX;
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
    FocusNode? focusNode,
    ValueChanged<String>? onWikilinkTap,
    EdgeInsets padding = EdgeInsets.zero,
    ImageProvider? Function(String)? imageProviderFor,
  }) async {
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.midnight),
        home: Scaffold(
          body: MarkdownEditor(
            controller: controller,
            focusNode: focusNode ?? FocusNode(),
            scrollController: ScrollController(),
            fontSize: 15.5,
            padding: padding,
            onWikilinkTap: onWikilinkTap,
            imageProviderFor: imageProviderFor,
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

  /// 造一张真实解码的图：尺寸规则与 `drawImageRect` 都只认 `ui.Image`。
  Future<ui.Image> makeImage(
    WidgetTester tester,
    int width,
    int height,
  ) async {
    final ui.Image result = (await tester.runAsync(
      () => createTestImage(width: width, height: height),
    ))!;
    addTearDown(result.dispose);
    return result;
  }

  /// 纯色图，供像素探针判断「这块颜色确实来自图片」。
  Future<ui.Image> solidImage(
    WidgetTester tester, {
    required int width,
    required int height,
    required Color color,
  }) async {
    final ui.Image result = (await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = color,
      );
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(width, height);
      picture.dispose();
      return image;
    }))!;
    addTearDown(result.dispose);
    return result;
  }

  testWidgets('标题框保持主题选区色，透明只给正文', (WidgetTester tester) async {
    final TextEditingController title = TextEditingController(text: '快速入门');
    final FocusNode titleFocus = FocusNode();
    addTearDown(title.dispose);
    addTearDown(titleFocus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.midnight),
        home: Scaffold(
          body: MarkdownEditor(
            controller: MarkdownSourceController(text: '正文'),
            focusNode: FocusNode(),
            scrollController: ScrollController(),
            fontSize: 15.5,
            padding: EdgeInsets.zero,
            header: TextField(controller: title, focusNode: titleFocus),
          ),
        ),
      ),
    );
    titleFocus.requestFocus();
    await tester.pumpAndSettle();

    final EditableText titleField = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      ),
    );
    expect(
      titleField.selectionColor,
      AppPalette.midnight.selection,
      reason: '标题的选区高亮必须是可见的',
    );
    expect(
      tester.widget<LineEditableText>(find.byType(LineEditableText))
          .selectionColor,
      Colors.transparent,
      reason: '正文洗色由 EditorSelectionPainter 画',
    );
  });

  testWidgets('鼠标悬停标签时胶囊变实心，移开恢复', (WidgetTester tester) async {
    const String text = '前 #日常 后';
    await pump(tester, text);
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;

    LineFillRun fill() => field.lineLayout!.laidOut.single.fills.single;
    expect(fill().fill, AppPalette.midnight.accentSoft);

    final Rect local = field.getLocalRectForCaret(
      const TextPosition(offset: 3),
    );
    final Rect caret = field.localToGlobal(local.topLeft) & local.size;
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(caret.center));
    await tester.pumpAndSettle();
    expect(fill().fill, AppPalette.midnight.accent, reason: '悬停应换成实心胶囊');

    await tester.sendEventToBinding(mouse.hover(Offset.zero));
    await tester.pumpAndSettle();
    expect(fill().fill, AppPalette.midnight.accentSoft, reason: '移开应恢复');
  });

  testWidgets('行首标签的胶囊与行中标签同形，左边内边距不被裁掉', (WidgetTester tester) async {
    const String text = '#欢迎 #欢迎\n正文 #欢迎';
    final MarkdownSourceController controller = await pump(tester, text);
    // 光标停在第二行行首：第一行的两枚标签都保持胶囊态，第二行开头的
    // 正文也不该被让位逻辑误伤。
    controller.selection = const TextSelection.collapsed(offset: 8);
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final LineDocumentLayout layout = field.lineLayout!;
    final LaidOutLine tagLine = layout.laidOut[0];
    final LaidOutLine plainLine = layout.laidOut[1];

    // 行首标签让出一颗胶囊的左内边距；普通正文行照旧贴着正文列。
    expect(tagLine.insets.left, kTagPadX);
    expect(plainLine.insets, EdgeInsets.zero);
    expect(tagLine.gutter, kTagPadX);

    Rect glyphs(LaidOutLine line, int from, int to) => line.painter
        .getBoxesForSelection(TextSelection(baseOffset: from, extentOffset: to))
        .first
        .toRect();

    final Rect first = glyphs(tagLine, 0, 3);
    final Rect second = glyphs(tagLine, 4, 7);
    // 底片按渲染层的同一公式从字形左缘往外铺 kTagPadX。行首那枚的起点正好
    // 压在正文列边缘（0）——没有被渲染对象裁掉，左边的内边距和中段一样在。
    final double firstPillLeft = tagLine.gutter + first.left - kTagPadX;
    final double secondPillLeft = tagLine.gutter + second.left - kTagPadX;
    expect(firstPillLeft, 0);
    expect(secondPillLeft, greaterThan(0));
    expect(
      tagLine.gutter + first.left - firstPillLeft,
      kTagPadX,
      reason: '行首胶囊：字形退进底片 kTagPadX',
    );
    expect(
      tagLine.gutter + second.left - secondPillLeft,
      kTagPadX,
      reason: '行中胶囊：字形退进底片 kTagPadX',
    );
  });

  testWidgets('点击双链把目标交给宿主，代码里的方括号不算', (WidgetTester tester) async {
    const String text = '看 [[target]] 和 `[[code]]` 结尾';
    final List<String> opened = <String>[];
    await pump(tester, text, onWikilinkTap: opened.add);
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;

    Offset pointIn(int offset) {
      final Rect local = field.getLocalRectForCaret(
        TextPosition(offset: offset),
      );
      return field.localToGlobal(local.topLeft) + Offset(2, local.height / 2);
    }

    await tester.tapAt(pointIn(text.indexOf('target') + 2));
    await tester.pumpAndSettle();
    expect(opened, <String>['target']);

    await tester.tapAt(pointIn(text.indexOf('[[code]]') + 5));
    await tester.pumpAndSettle();
    expect(opened, <String>['target'], reason: '行内代码里的方括号不是链接');
  });

  /// Renders [text] into its own [RepaintBoundary] and hands back the pixels, so
  /// a test can assert on what was **painted** rather than on the widget tree.
  ///
  /// The paper lives *inside* the boundary: the boundary captures only its own
  /// subtree, and every pixel outside it would read as transparent.
  Future<_Pixels> shoot(
    WidgetTester tester,
    String text,
    TextSelection selection, {
    AppPalette palette = AppPalette.midnight,
    TextSelection? frozen,
    ImageProvider? Function(String)? imageProviderFor,
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
                imageProviderFor: imageProviderFor,
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

  testWidgets('行首的标签胶囊与行中的一样宽（底片夹取在画布坐标里做）', (WidgetTester tester) async {
    final _Pixels px = await shoot(
      tester,
      '#欢迎 #欢迎\n正文',
      const TextSelection.collapsed(offset: 8),
    );

    // 底片是 accentSoft；按列数出两条实心带，字形叠上去的列像素少，用阈值
    // 跳过。两枚同字的胶囊必须一样宽——旧实现先在画笔坐标里夹左缘再平移
    // gutter，行首那段让出来的 6px 会被平移吃掉，第一枚窄一条内边距。
    final List<(int, int)> runs = <(int, int)>[];
    int? start;
    for (int x = 0; x < px.width; x++) {
      int n = 0;
      for (int y = 0; y < px.height; y++) {
        if (px.isColor(AppPalette.midnight.accentSoft, x, y)) n++;
      }
      if (n > 4) {
        start ??= x;
      } else if (start != null) {
        runs.add((start, x - 1));
        start = null;
      }
    }
    if (start != null) runs.add((start, px.width - 1));

    expect(runs, hasLength(2), reason: '一行里的两枚标签各是一条底片');
    final int first = runs[0].$2 - runs[0].$1;
    final int second = runs[1].$2 - runs[1].$1;
    expect(first, closeTo(second, 1), reason: '行首胶囊不该少一条左边内边距');
  });

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
      tree!.toPlainText(),
      controller.text,
      reason: '交给渲染对象的 span 必须逐字符等于源码',
    );
    // 按行排版后装饰不再进 span：live 的 WidgetSpan 会用一个 U+FFFC 顶掉
    // 标记字符，引擎就认不出列表行了。字由每行自己的 `TextPainter` 画。
    expect(widgetCount(tree), 0);
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
    //
    // 复选框现在由渲染层直接画，没有 widget 可以量：矩形从渲染对象拿，和上屏
    // 的方框逐像素一致。
    final List<Rect> boxes = (editable(tester) as RenderLineEditable)
        .taskCheckboxRects();
    expect(boxes, hasLength(2));
    await tester.tapAt(boxes.last.center);
    await tester.pump();

    expect(controller.text, '- [ ] 待办\n- [x] 另一件\n');
    // 勾待办是最高频的动作：翻一下就完，**不进编辑态**。整行变成 `- [x] 源码`
    // 太吵，而且光标也会被拽进标记里。摊开标记只由点序号/圆点触发。
    final RenderLineEditable r = editable(tester) as RenderLineEditable;
    final LaidOutLine second = r.lineLayout!.laidOut.firstWhere(
      (LaidOutLine l) => l.source.start == 9,
    );
    expect(second.slot.revealedMarkers, isFalse, reason: '点方框不该摊开标记');
    expect(second.slot.width, second.slot.indent + second.slot.marker);
    expect(
      controller.selection.baseOffset,
      0,
      reason: 'flipping a box should not move the insertion point',
    );
  });

  testWidgets('clicking an ordered task’s number still opens number and box', (
    WidgetTester tester,
  ) async {
    // 有序任务那一行有两段标记：序号 `1. ` 和复选框 `[ ] `。点序号进编辑态时
    // 两段要一起摊开——不能只露序号、方框还画在槽位里。
    final MarkdownSourceController controller = await pump(
      tester,
      '1. [ ] 甲\n2. [ ] 乙\n',
    );
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    final RenderLineEditable r = editable(tester) as RenderLineEditable;
    // 从第二行复选框的矩形往左退一点，就落在序号 `2.` 上（序号和方框同属
    // 槽位里的标记，坐标只能从渲染对象拿）。
    final List<Rect> boxes = r.taskCheckboxRects();
    expect(boxes, hasLength(2));
    final Rect box = boxes.last;
    await tester.tapAt(Offset(box.left - 8, box.center.dy));
    await tester.pump();

    final LaidOutLine opened = r.lineLayout!.laidOut.firstWhere(
      (LaidOutLine l) => l.source.start == 9,
    );
    expect(opened.slot.revealedMarkers, isTrue, reason: '点序号要摊开这一行');
    expect(
      opened.slot.width,
      opened.slot.indent,
      reason: '摊开之后槽位只剩缩进，序号和方框一起让出宽度',
    );
    // 方框跟着变成源码：不再有画出来的复选框。
    expect(
      r.taskCheckboxRects(),
      hasLength(1),
      reason: '只剩第一行那个还画着，第二行已经是 `[ ]` 源码',
    );
    expect(controller.text, '1. [ ] 甲\n2. [ ] 乙\n', reason: '点序号不翻转');
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

    final List<Rect> boxes = (editable(tester) as RenderLineEditable)
        .taskCheckboxRects();
    expect(boxes, hasLength(2));
    final Rect rect = boxes.first;

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

  testWidgets('hovering a checkbox shows the plain arrow, not the I-beam', (
    WidgetTester tester,
  ) async {
    await pump(tester, '- [ ] 待办\n正文\n');
    final RenderLineEditable re = editable(tester) as RenderLineEditable;
    final Rect box = re.taskCheckboxRects().first;
    MouseCursor? cursor() => tester
        .widget<LineEditableText>(find.byKey(const Key('nrs-editor-field')))
        .mouseCursor;
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(mouse.hover(box.center));
    await tester.pump();
    expect(cursor(), SystemMouseCursors.basic, reason: '复选框是一次勾选，不是一段可输入的文字');

    // 离开方框就恢复输入光标，别把整个标记槽位都当成箭头区。
    await tester.sendEventToBinding(
      mouse.hover(box.center + const Offset(60, 0)),
    );
    await tester.pump();
    expect(cursor(), SystemMouseCursors.text);
  });

  testWidgets('列表序号左边的页边留白不给输入光标', (WidgetTester tester) async {
    await pump(
      tester,
      '1. 第一项\n正文\n',
      padding: const EdgeInsets.fromLTRB(40, 0, 40, 0),
    );
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final Offset origin = field.localToGlobal(Offset.zero);
    final double middle = field.lineLayout!.laidOut.first.height / 2;
    MouseCursor? cursor() => tester
        .widget<LineEditableText>(find.byKey(const Key('nrs-editor-field')))
        .mouseCursor;
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(mouse.hover(origin + Offset(-20, middle)));
    await tester.pump();
    expect(
      cursor(),
      SystemMouseCursors.basic,
      reason: '正文列左边的页边不是编辑区，别提示成输入光标',
    );

    await tester.sendEventToBinding(mouse.hover(origin + Offset(4, middle)));
    await tester.pump();
    expect(cursor(), SystemMouseCursors.text, reason: '序号本身可以点开编辑');

    await tester.sendEventToBinding(mouse.hover(origin + Offset(60, middle)));
    await tester.pump();
    expect(cursor(), SystemMouseCursors.text);
  });

  testWidgets('嵌套列表序号前的缩进也不给输入光标', (WidgetTester tester) async {
    await pump(tester, '  - 子项\n正文\n');
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final Offset origin = field.localToGlobal(Offset.zero);
    final double middle = field.lineLayout!.laidOut.first.height / 2;
    MouseCursor? cursor() => tester
        .widget<LineEditableText>(find.byKey(const Key('nrs-editor-field')))
        .mouseCursor;
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(mouse.hover(origin + Offset(8, middle)));
    await tester.pump();
    expect(cursor(), SystemMouseCursors.basic, reason: '序号前面的缩进没有字形');

    await tester.sendEventToBinding(mouse.hover(origin + Offset(30, middle)));
    await tester.pump();
    expect(cursor(), SystemMouseCursors.text, reason: '圆点所在的标记区可以点开编辑');
  });

  testWidgets('only the painted marker itself opens a list line', (
    WidgetTester tester,
  ) async {
    await pump(tester, '4. [ ]\n正文\n');
    final RenderLineEditable f = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    LaidOutLine line() => f.lineLayout!.laidOut.first;
    final Offset origin = f.localToGlobal(Offset.zero);
    final double middle = line().visuals.first.height / 2;
    final double number = line().slot.indent + 4;

    // 方框下方的空白：行高比字形高，这一截什么都不算，别把标记摊开。
    await tester.tapAt(origin + Offset(number, line().height - 1));
    await tester.pump();
    expect(line().slot.revealedMarkers, isFalse);

    // 点在序号上：这里才是「4. [ ]」本身，摊成可编辑源码。
    await tester.tapAt(origin + Offset(number, middle));
    await tester.pump();
    expect(line().slot.revealedMarkers, isTrue);

    // 点右侧正文：收起，回到渲染态。摊开后的正文列从 0 起算，落点要放到
    // 内联前缀（`4. [ ]`）右边。
    await tester.tapAt(origin + Offset(number + 60, middle));
    await tester.pump();
    expect(line().slot.revealedMarkers, isFalse);
  });

  group('列表子树折叠', () {
    const String text = '- 父\n  1. 子\n  2. 次子\n- 末尾';

    RenderLineEditable fieldOf(WidgetTester tester) =>
        tester.allRenderObjects.whereType<RenderLineEditable>().first;

    Future<void> collapse(WidgetTester tester) async {
      final RenderLineEditable field = fieldOf(tester);
      final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
      // 展开的箭头只在悬停这一行时显形；先停上去再点。
      await tester.sendEventToBinding(
        mouse.hover(field.foldHandles().single.row.center),
      );
      await tester.pump();
      await tester.sendEventToBinding(
        mouse.down(field.foldHandles().single.button.center),
      );
      await tester.sendEventToBinding(mouse.up());
      await tester.pumpAndSettle();
    }

    testWidgets('点箭头收起子树，再点一次展开', (WidgetTester tester) async {
      final MarkdownSourceController controller = await pump(
        tester,
        text,
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 0),
      );
      controller.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      final RenderLineEditable field = fieldOf(tester);
      final double openHeight = field.lineLayout!.height;
      final double hiddenRows =
          field.lineLayout!.laidOut[1].height +
          field.lineLayout!.laidOut[2].height;
      expect(field.foldHandles().single.folded, isFalse);
      expect(field.foldHandles().single.ellipsis, isNull, reason: '展开时不提示省略');

      await collapse(tester);
      expect(field.foldHandles().single.folded, isTrue);
      expect(
        field.foldHandles().single.ellipsis,
        isNotNull,
        reason: '收起后行尾接上省略号',
      );
      expect(field.lineLayout!.laidOut[1].height, 0);
      expect(field.lineLayout!.laidOut[2].height, 0);
      expect(field.lineLayout!.height, closeTo(openHeight - hiddenRows, 0.01));
      expect(controller.selection.extentOffset, 1, reason: '点箭头不是点正文，光标不动');

      final TestPointer mouse = TestPointer(2, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.down(field.foldHandles().single.button.center),
      );
      await tester.sendEventToBinding(mouse.up());
      await tester.pumpAndSettle();

      expect(field.foldHandles().single.folded, isFalse);
      expect(field.foldHandles().single.ellipsis, isNull, reason: '展开后省略号消失');
      expect(field.lineLayout!.height, closeTo(openHeight, 0.01));
      expect(controller.selection.extentOffset, 1);
    });

    testWidgets('悬停折叠箭头给点击光标', (WidgetTester tester) async {
      await pump(
        tester,
        text,
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 0),
      );
      final RenderLineEditable field = fieldOf(tester);
      final ListFoldHandle handle = field.foldHandles().single;
      MouseCursor? cursor() => tester
          .widget<LineEditableText>(find.byKey(const Key('nrs-editor-field')))
          .mouseCursor;
      final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(mouse.hover(handle.row.center));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.text, reason: '行内是正文，照常输入');

      await tester.sendEventToBinding(mouse.hover(handle.button.center));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.click, reason: '箭头是一次点击');
    });

    testWidgets('光标走进收起的子树时自动展开', (WidgetTester tester) async {
      final MarkdownSourceController controller = await pump(
        tester,
        text,
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 0),
      );
      final RenderLineEditable field = fieldOf(tester);

      await collapse(tester);
      expect(field.foldHandles().single.folded, isTrue);

      controller.selection = TextSelection.collapsed(offset: text.indexOf('子'));
      await tester.pumpAndSettle();

      expect(
        field.foldHandles().single.folded,
        isFalse,
        reason: '看不见的行不能放光标，宁可把子树展开',
      );
    });

    testWidgets('折叠键跟着编辑平移，插入前言也不丢', (WidgetTester tester) async {
      final MarkdownSourceController controller = await pump(
        tester,
        text,
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 0),
      );
      final RenderLineEditable field = fieldOf(tester);

      await collapse(tester);
      expect(field.foldHandles().single.folded, isTrue);

      controller.value = TextEditingValue(
        text: '前言\n$text',
        selection: const TextSelection.collapsed(offset: 0),
      );
      await tester.pumpAndSettle();

      final ListFoldHandle handle = field.foldHandles().single;
      expect(handle.lineStart, '前言\n'.length);
      expect(handle.folded, isTrue, reason: '折叠键按行首偏移平移，换了上文也还落在同一个列表项上');
    });
  });

  testWidgets('a rule is a line across the column, not three hyphens', (
    WidgetTester tester,
  ) async {
    // 分隔线不再是一个零宽 widget：源码行自己是排版单元，`---` 在未揭示时
    // 不落墨，线由渲染层横着画出来。
    final _Pixels px = await shoot(
      tester,
      '---\n下一段\n',
      const TextSelection.collapsed(offset: 4),
    );
    final RenderLineEditable re = editable(tester) as RenderLineEditable;
    final LaidOutLine rule = re.lineLayout!.laidOut.first;
    expect(rule.source.kind, LineBlockKind.rule);
    expect(rule.fills, isEmpty, reason: '分隔线不是行内代码，不该有底片');
    expect(
      rule.painter.text!.style!.color,
      Colors.transparent,
      reason: '光标不在这一行时 `---` 不该上屏',
    );

    // 线本身：正文列上最长的一段横线。按像素找，因为渲染层直接画，没有
    // 渲染对象可以量。
    final Offset origin = re.localToGlobal(Offset.zero);
    int best = 0;
    for (int y = origin.dy.round(); y < origin.dy.round() + 80; y++) {
      int run = 0;
      for (int x = 0; x < px.width; x++) {
        if (px.isColor(px.palette.rule, x, y, tolerance: 6)) {
          run++;
          if (run > best) best = run;
        } else {
          run = 0;
        }
      }
    }
    expect(best, greaterThan(200), reason: '分隔线没有横贯正文列');
  });

  testWidgets('a rule with the caret on it shows its source, not the line', (
    WidgetTester tester,
  ) async {
    // 编辑这一行时 `---` 自己上屏；横线若照画不误，会从三个减号中间穿过去。
    final _Pixels px = await shoot(
      tester,
      '---\n下一段\n',
      const TextSelection.collapsed(offset: 1),
    );
    final RenderLineEditable re = editable(tester) as RenderLineEditable;
    final LaidOutLine rule = re.lineLayout!.laidOut.first;
    expect(
      rule.painter.text!.style!.color,
      isNot(Colors.transparent),
      reason: '光标在这一行时 `---` 应该显形',
    );

    final Offset origin = re.localToGlobal(Offset.zero);
    int best = 0;
    for (int y = origin.dy.round(); y < origin.dy.round() + 80; y++) {
      int run = 0;
      for (int x = 0; x < px.width; x++) {
        if (px.isColor(px.palette.rule, x, y, tolerance: 6)) {
          run++;
          if (run > best) best = run;
        } else {
          run = 0;
        }
      }
    }
    expect(best, lessThan(200), reason: '源码显形时不该再横贯一条分割线');
  });

  /// The accent bar on the left of a quote: it stands in for the hidden `>` and
  /// has to disappear the moment the source shows, or the marker is drawn twice.
  int quoteBarPixels(_Pixels px, RenderLineEditable re) {
    final LaidOutLine quote = re.lineLayout!.laidOut.first;
    final Offset origin = re.localToGlobal(Offset.zero);
    final int x = origin.dx.round() + 3;
    final int top = origin.dy.round() + quote.visuals.first.top.round();
    final int bottom = top + quote.visuals.first.height.round();
    int bar = 0;
    for (int y = top + 1; y < bottom - 1; y++) {
      if (px.isColor(px.palette.accent, x, y, tolerance: 10)) bar++;
    }
    return bar;
  }

  testWidgets('a rendered quote keeps its accent bar', (
    WidgetTester tester,
  ) async {
    final _Pixels px = await shoot(
      tester,
      '> 引用\n正文\n',
      const TextSelection.collapsed(offset: 6),
    );
    final RenderLineEditable re = editable(tester) as RenderLineEditable;
    final double row = re.lineLayout!.laidOut.first.visuals.first.height;
    expect(
      quoteBarPixels(px, re),
      greaterThan(row.round() - 8),
      reason: '引用左侧应有强调色竖线',
    );
  });

  testWidgets('a quote hides the bar once its source shows', (
    WidgetTester tester,
  ) async {
    final _Pixels px = await shoot(
      tester,
      '> 引用\n正文\n',
      const TextSelection.collapsed(offset: 2),
    );
    final RenderLineEditable re = editable(tester) as RenderLineEditable;
    final double row = re.lineLayout!.laidOut.first.visuals.first.height;
    expect(
      quoteBarPixels(px, re),
      lessThan(row.round() / 2),
      reason: '光标落进引用行后 `>` 显形，竖线该让位',
    );
  });

  testWidgets('an open IME composition keeps the offset map', (
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
    expect(tree!.toPlainText(), typed, reason: '拼音还没上屏，偏移映射就已经对不上了');
    expect(
      controller.value.composing,
      const TextRange(start: typed.length - 2, end: typed.length),
      reason: '组合区间被输入法之外的东西改掉了',
    );
  });

  testWidgets('the editor still accepts typing', (WidgetTester tester) async {
    final MarkdownSourceController controller = await pump(tester, '');
    await tester.tap(find.byKey(const Key('nrs-editor-field')));
    await tester.pump();
    // `tester.enterText` 走的是 `EditableText` 的 state；字段换成了按行渲染的
    // fork，输入直接交给它自己的 state。
    final LineEditableTextState state = tester.state<LineEditableTextState>(
      find.byType(LineEditableText),
    );
    state.userUpdateTextEditingValue(
      const TextEditingValue(
        text: '# 标题',
        selection: TextSelection.collapsed(offset: 4),
      ),
      SelectionChangedCause.keyboard,
    );
    await tester.pump();
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

  /// 序号是文档结构，不该要求用户自己维护：删掉 16 那一条，下面的 17 要变回
  /// 16；在 15 后面回车插一条，后面的序号依次后移。
  ///
  /// 这里走真实输入框的 formatter 链，确认重编号确实接在续行格式化器之后。
  testWidgets('有序列表在增删行后自动接上序号', (WidgetTester tester) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    const String text = '15. [ ] 甲\n16. [ ] 乙\n17. [ ] 丙';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      focusNode: focus,
    );
    focus.requestFocus();
    tester.testTextInput.register();
    await tester.pumpAndSettle();

    // 在 15 的末尾回车：新条目 16，原来的 16、17 依次后移。
    const int at = 9; // '15. [ ] 甲'.length
    controller.selection = const TextSelection.collapsed(offset: at);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${text.substring(0, at)}\n${text.substring(at)}',
        selection: const TextSelection.collapsed(offset: at + 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, '15. [ ] 甲\n16. [ ] \n17. [ ] 乙\n18. [ ] 丙');

    // 删掉整条第 16 行（含行尾换行）：下面的 17 变回 16。
    final String inserted = controller.text;
    final int start = inserted.indexOf('16. [ ] \n');
    final int end = start + '16. [ ] \n'.length;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: inserted.substring(0, start) + inserted.substring(end),
        selection: TextSelection.collapsed(offset: start),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, '15. [ ] 甲\n16. [ ] 乙\n17. [ ] 丙');
  });

  testWidgets('行中回车把后半段拆成下一个序号', (WidgetTester tester) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    const String text = '15. [ ] 序号排列问题\n16. [ ] 乙';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      focusNode: focus,
    );
    focus.requestFocus();
    tester.testTextInput.register();
    await tester.pumpAndSettle();

    final int at = text.indexOf('问题');
    controller.selection = TextSelection.collapsed(offset: at);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${text.substring(0, at)}\n${text.substring(at)}',
        selection: TextSelection.collapsed(offset: at + 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, '15. [ ] 序号排列\n16. [ ] 问题\n17. [ ] 乙');
  });

  /// 序号不是插图：点在 `15.` 上应该把它展开成真正的源码放着光标，能直接改；
  /// 点正文则保持渲染态，标记继续画在槽位里。
  testWidgets('点列表标记展开成可编辑源码，点正文不展开', (WidgetTester tester) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    const String text = '15. [ ] 甲';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      focusNode: focus,
    );
    focus.requestFocus();
    tester.testTextInput.register();
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    LaidOutLine line() => field.lineLayout!.laidOut.single;
    expect(line().slot.revealedMarkers, isFalse);

    // 序号槽位：正文列左边那一段。点最左端，光标落在标记起点、直接改序号。
    await tester.tapAt(
      field.localToGlobal(Offset(line().slot.indent + 1, line().top + 8)),
    );
    await tester.pumpAndSettle();

    expect(line().slot.revealedMarkers, isTrue, reason: '点标记应展开源码');
    expect(line().paintedFrom, 0, reason: '序号要摊进正文才可编辑');
    expect(
      controller.selection,
      const TextSelection.collapsed(offset: 0),
      reason: '光标应落在序号起点',
    );

    // 序号自己是字形了：0 和 1 两个光标位不再重合。
    final Rect zero = field.getLocalRectForCaret(const TextPosition(offset: 0));
    final Rect one = field.getLocalRectForCaret(const TextPosition(offset: 1));
    expect(one.left, greaterThan(zero.left), reason: '序号必须能容纳光标');

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '515. [ ] 甲',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, '515. [ ] 甲', reason: '展开后应能直接改序号');

    // 点正文：标记回到槽位，不再占正文宽度。
    final int at = controller.text.indexOf('甲');
    final Rect glyph = field
        .getBoxesForSelection(
          TextSelection(baseOffset: at, extentOffset: at + 1),
        )
        .first
        .toRect();
    await tester.tapAt(field.localToGlobal(glyph.center));
    await tester.pumpAndSettle();

    expect(line().slot.revealedMarkers, isFalse, reason: '点正文不该展开标记');
    expect(line().paintedFrom, line().source.paintStart);
  });

  /// 嵌套列表的序号摊开后仍要停在原来的层级上：缩进由槽位保留，序号不会被
  /// 打回行首；光标也落在序号起点，输入直接改序号。
  testWidgets('点嵌套列表的序号，源码留在自己的缩进上', (WidgetTester tester) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '- 父\n  2. [ ] 子',
      focusNode: focus,
    );
    focus.requestFocus();
    tester.testTextInput.register();
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    LaidOutLine row() => field.lineLayout!.laidOut[1];
    final double indent = row().slot.indent;
    expect(indent, greaterThan(0), reason: '第二行是嵌套项');

    await tester.tapAt(field.localToGlobal(Offset(indent + 4, row().top + 8)));
    await tester.pumpAndSettle();

    final LaidOutLine revealed = row();
    expect(revealed.slot.revealedMarkers, isTrue);
    expect(revealed.paintedFrom, revealed.source.markerStart, reason: '缩进不进正文');
    expect(revealed.gutter, closeTo(indent, 0.01), reason: '序号仍从缩进后起排');
    expect(
      controller.selection.extentOffset,
      revealed.source.markerStart,
      reason: '光标落在序号起点',
    );

    final Rect digit = field
        .getBoxesForSelection(
          TextSelection(
            baseOffset: revealed.source.markerStart,
            extentOffset: revealed.source.markerStart + 1,
          ),
        )
        .first
        .toRect();
    expect(digit.left, closeTo(indent, 0.5), reason: '序号字形留在缩进之后');
    expect(
      field
          .getLocalRectForCaret(
            TextPosition(offset: revealed.source.markerStart),
          )
          .left,
      closeTo(indent, 0.5),
    );
  });

  /// 点 `1.` 的中间或右边时，光标落在点中的字间，而不是被拽回标记最左边。
  testWidgets('点序号的不同位置，光标落在点中的字间', (WidgetTester tester) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '1. 甲',
      focusNode: focus,
    );
    focus.requestFocus();
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    LaidOutLine line() => field.lineLayout!.laidOut.single;

    // 先在标记起点点一下摊开源码，量出 `1` 和 `.` 各自结束的 x：槽位宽度
    // 与摊开后的前缀用同一套字体度量，量一次两边通用。
    await tester.tapAt(
      field.localToGlobal(Offset(line().slot.indent + 1, line().top + 8)),
    );
    await tester.pumpAndSettle();
    expect(line().slot.revealedMarkers, isTrue);
    double endOf(int offset) => field
        .getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: offset),
        )
        .last
        .toRect()
        .right;
    final double oneEnd = endOf(1);
    final double dotEnd = endOf(2);
    expect(dotEnd, greaterThan(oneEnd + 2), reason: '`.` 要有足够的宽度做左右两半');

    // 点正文收起标记，回到槽位里的序号。
    Future<void> hide() async {
      final Rect glyph = field
          .getBoxesForSelection(
            const TextSelection(baseOffset: 3, extentOffset: 4),
          )
          .first
          .toRect();
      await tester.tapAt(field.localToGlobal(glyph.center));
      await tester.pumpAndSettle();
      expect(line().slot.revealedMarkers, isFalse);
    }

    await hide();

    // `1` 和 `.` 的中间：落点离「1 之后」这条缝只有 1px，光标应停在那里。
    await tester.tapAt(field.localToGlobal(Offset(oneEnd + 1, line().top + 8)));
    await tester.pumpAndSettle();
    expect(line().slot.revealedMarkers, isTrue);
    expect(
      controller.selection.extentOffset,
      1,
      reason: '点 1 和 . 的中间，光标落在两者之间',
    );
    expect(
      field.getLocalRectForCaret(const TextPosition(offset: 1)).left,
      closeTo(oneEnd, 1),
      reason: '光标画在点中的位置，不在行首',
    );

    await hide();

    // `.` 的右边：落点离「. 之后」这条缝只有 1px，光标应停在 `.` 之后。
    await tester.tapAt(field.localToGlobal(Offset(dotEnd + 1, line().top + 8)));
    await tester.pumpAndSettle();
    expect(line().slot.revealedMarkers, isTrue);
    expect(controller.selection.extentOffset, 2, reason: '点 . 的右边，光标落在 . 之后');
  });

  /// 缩进槽里没有字形：点在那里属于「这一行正文的起点」，不能算点开标记。
  /// 否则光标会被夹回 `3. ` 的起点，接着输入（含输入法组合）就把文字插进
  /// 标记前面，`  3. [ ] 子` 变成 `  qie3. [ ] 子`。
  testWidgets('点嵌套列表的缩进槽，光标落在正文起点而不是标记前面', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    const String text = '- 父\n  3. [ ] 子';
    final MarkdownSourceController controller = await pump(
      tester,
      text,
      focusNode: focus,
    );
    focus.requestFocus();
    tester.testTextInput.register();
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    LaidOutLine row() => field.lineLayout!.laidOut[1];
    final int paintStart = row().source.paintStart;
    final double indent = row().slot.indent;
    expect(indent, greaterThan(4), reason: '第二行是嵌套项，缩进槽应当可点');

    // 缩进槽中点：在标记带的纵向范围内，但完全落在标记字形左边。
    await tester.tapAt(field.localToGlobal(Offset(indent / 2, row().top + 8)));
    await tester.pumpAndSettle();

    expect(row().slot.revealedMarkers, isFalse, reason: '点缩进不该摊开标记');
    expect(
      controller.selection,
      TextSelection.collapsed(offset: paintStart),
      reason: '光标应落在标记之后、正文起点',
    );
    expect(paintStart, greaterThan(row().source.markerStart));

    // 模拟输入法还没上屏的组合串：必须接在标记后面，标记留在行首。
    final int caret = controller.selection.baseOffset;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text.replaceRange(caret, caret, 'qie'),
        selection: TextSelection.collapsed(offset: caret + 3),
        composing: TextRange(start: caret, end: caret + 3),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, '- 父\n  3. [ ] qie子');
  });

  /// 标记摊开后缩进槽仍是空白：点它等同点正文，光标同样归到正文起点，
  /// 不能借 revealed 的 `paintedFrom = markerStart` 退回标记之前。
  testWidgets('标记摊开后点缩进槽，光标也不退回标记起点', (WidgetTester tester) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '- 父\n  3. [ ] 子',
      focusNode: focus,
    );
    focus.requestFocus();
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    LaidOutLine row() => field.lineLayout!.laidOut[1];
    final double indent = row().slot.indent;

    await tester.tapAt(field.localToGlobal(Offset(indent + 4, row().top + 8)));
    await tester.pumpAndSettle();
    expect(row().slot.revealedMarkers, isTrue);

    final int paintStart = row().source.paintStart;
    await tester.tapAt(field.localToGlobal(Offset(indent / 2, row().top + 8)));
    await tester.pumpAndSettle();

    expect(row().slot.revealedMarkers, isFalse, reason: '点缩进等同点正文，标记收起');
    expect(
      controller.selection,
      TextSelection.collapsed(offset: paintStart),
      reason: '光标仍落在正文起点，不得回到 markerStart',
    );
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

    // 列表标记（`- ` / `[ ] `）由渲染层画成圆点和复选框，源码字符不上屏：
    // 点在这一段里本来就该吸附到正文列，没有「指到那个字」可言。
    final Set<int> markers = <int>{
      for (final SourceLine line in scanSourceLines(body))
        for (int i = line.start; i < line.paintStart; i++) i,
    };

    final List<String> drifted = <String>[];
    for (int i = 0; i < body.length; i++) {
      if (body[i] == '\n') continue;
      if (markers.contains(i)) continue;
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

  testWidgets('从列表正文第一个字拖选，不会把隐藏的标记一起选中', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      const String body = '1. [x] 任务列表\n';
      final MarkdownSourceController controller = await pump(tester, body);
      // 光标停在别处，列表标记保持折叠态 —— 屏幕上只有正文，没有 `1. [x] `。
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      final RenderLineEditable field = tester.allRenderObjects
          .whereType<RenderLineEditable>()
          .first;
      final SourceLine line = field.lineLayout!.lines.first;
      final int bodyStart = line.paintStart;
      expect(body.substring(0, bodyStart), '1. [x] ');

      Rect glyph(int index) => field
          .getBoxesForSelection(
            TextSelection(baseOffset: index, extentOffset: index + 1),
          )
          .first
          .toRect()
          .shift(field.localToGlobal(Offset.zero));

      final TestGesture drag = await tester.startGesture(
        glyph(bodyStart).centerLeft + const Offset(1, 0),
      );
      await tester.pump();
      await drag.moveTo(glyph(bodyStart + 3).center);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect(
        controller.selection.start,
        bodyStart,
        reason: '标记在屏幕上没显示，不该跟着正文一起被选中',
      );
      expect(
        controller.selection.textInside(controller.text),
        isNot(contains('[')),
      );
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

  /// 空子项上的第二次回车只负责“上一级”：它要退回父级并生成父级记号，而不是
  /// 把标记删光留一条裸行；这同样是走平台真实送来的 newline，不是直接调规则表。
  testWidgets('a second Enter on a nested item steps out to its parent', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '- 甲\n  - 乙',
      focusNode: focus,
    );
    focus.requestFocus();
    await tester.pump();

    // Caret at the end of the child line: `- 甲\n  - 乙` is 9 characters.
    const int caret = 9;
    controller.selection = const TextSelection.collapsed(offset: caret);
    await tester.pump();

    // First Enter: a fresh child marker.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '- 甲\n  - 乙\n',
        selection: TextSelection.collapsed(offset: caret + 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.text, '- 甲\n  - 乙\n  - ');
    expect(controller.selection.baseOffset, controller.text.length);

    // Second Enter: the empty child steps out. No blank line is left behind.
    final int empty = controller.text.length;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${controller.text}\n',
        selection: TextSelection.collapsed(offset: empty + 1),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.text, '- 甲\n  - 乙\n- ');
    expect(controller.selection.baseOffset, controller.text.length);
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

  /// The field's box is exactly as tall as its text, so a drag that starts on
  /// the paper below it never reaches the field's gesture recognisers: 从空白处
  /// 从下往上框选选不中，只有在盒子内起手才有效。On a desktop a held left
  /// button is the select gesture anywhere in the editing surface, so the
  /// editor anchors at the nearest text and drives the range itself.
  testWidgets(
    'dragging up from the paper below selects to the end of the note',
    (WidgetTester tester) async {
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      final MarkdownSourceController controller = await pump(
        tester,
        '第一行文字\n第二行文字\n第三行文字',
        focusNode: focus,
      );
      final Rect field = tester.getRect(
        find.byKey(const Key('nrs-editor-field')),
      );
      final RenderEditable re = editable(tester);
      final int second = controller.text.indexOf('第二');
      final Rect glyph = re
          .getBoxesForSelection(
            TextSelection(baseOffset: second, extentOffset: second + 1),
          )
          .first
          .toRect()
          .shift(re.localToGlobal(Offset.zero));
      final Offset target = glyph.centerLeft + const Offset(1, 0);
      final int expected = re.getPositionForPoint(target).offset;

      final TestGesture drag = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await drag.down(Offset(field.center.dx, field.bottom + 80));
      await tester.pump();
      await drag.moveTo(target);
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();

      expect(focus.hasFocus, isTrue, reason: '从空白处开始拖选也要拿到焦点');
      expect(
        controller.selection.baseOffset,
        controller.text.length,
        reason: '从文末下方起手，锚点应该在文末',
      );
      expect(
        controller.selection.extentOffset,
        expected,
        reason: '选区应该跟着指针走到第二行，而不是原地不动',
      );
      expect(controller.revealAs, isNull, reason: '松手后要把 reveal 交还给实时选区');
    },
  );

  /// The same box rule sideways: the prose column is narrower than the pane, so
  /// a press to the right of a line is outside the field too. Dragging from
  /// there selects from the end of that line toward the pointer.
  testWidgets('dragging from the margin beside a line selects from it', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '第一行文字\n第二行文字\n第三行文字',
      focusNode: focus,
    );
    final Rect field = tester.getRect(
      find.byKey(const Key('nrs-editor-field')),
    );
    final RenderEditable re = editable(tester);
    final Rect secondLineGlyph = re
        .getBoxesForSelection(
          TextSelection(
            baseOffset: controller.text.indexOf('第二'),
            extentOffset: controller.text.indexOf('第二') + 1,
          ),
        )
        .first
        .toRect()
        .shift(re.localToGlobal(Offset.zero));
    final Offset start = Offset(field.right + 20, secondLineGlyph.center.dy);
    final int anchor = re.getPositionForPoint(start).offset;
    final Offset target = Offset(
      field.left + 1,
      re
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .first
          .toRect()
          .shift(re.localToGlobal(Offset.zero))
          .center
          .dy,
    );
    final int expected = re.getPositionForPoint(target).offset;

    final TestGesture drag = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await drag.down(start);
    await tester.pump();
    await drag.moveTo(target);
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(controller.selection.end, anchor, reason: '从第二行右侧起手，锚点应该停在第二行行末');
    expect(controller.selection.start, expected, reason: '选区应该跟着指针走到第一行');
  });

  /// While the reveal is frozen a heading's `# ` is hidden and zero-width, so
  /// the pointer at the visual start of the line maps to the offset *after* the
  /// prefix. On release the line reveals and the `#` shows up — outside the
  /// wash. Dragging up from the paper below has to take the whole heading.
  testWidgets('dragging up to a heading start selects its hidden marker', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '# 入门\n\n正文第一段\n正文第二段',
      focusNode: focus,
    );
    final Rect field = tester.getRect(
      find.byKey(const Key('nrs-editor-field')),
    );
    final RenderEditable re = editable(tester);
    final Offset origin = re.localToGlobal(Offset.zero);
    // "入" — the first visible glyph of the heading, at the line's left edge
    // while the `# ` has no width.
    final Rect firstGlyph = re
        .getBoxesForSelection(
          const TextSelection(baseOffset: 2, extentOffset: 3),
        )
        .first
        .toRect()
        .shift(origin);

    final TestGesture drag = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await drag.down(Offset(field.center.dx, field.bottom + 60));
    await tester.pump();
    await drag.moveTo(Offset(origin.dx + 2, firstGlyph.center.dy));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      controller.selection.baseOffset,
      controller.text.length,
      reason: '从文末下方起手，锚点应该在文末',
    );
    expect(
      controller.selection.extentOffset,
      0,
      reason: '框到标题行首时，零宽的 `# ` 前缀也应该计入选区',
    );
    final Rect marker = re
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first
        .toRect();
    expect(marker.width, greaterThan(0), reason: '松手后标题应该展开，`#` 应该被覆盖');
  });

  /// The same correction for a range the field's own recognisers wrote: it was
  /// measured against the frozen reveal too, so it is fixed on release, while
  /// the prefix is still hidden.
  testWidgets('dragging inside the field up to a heading start keeps the #', (
    WidgetTester tester,
  ) async {
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final MarkdownSourceController controller = await pump(
      tester,
      '# 入门\n\n正文第一段\n正文第二段',
      focusNode: focus,
    );
    final RenderEditable re = editable(tester);
    final Offset origin = re.localToGlobal(Offset.zero);
    final Rect firstGlyph = re
        .getBoxesForSelection(
          const TextSelection(baseOffset: 2, extentOffset: 3),
        )
        .first
        .toRect()
        .shift(origin);
    final int lastChar = controller.text.lastIndexOf('段');
    final Rect lastGlyph = re
        .getBoxesForSelection(
          TextSelection(baseOffset: lastChar, extentOffset: lastChar + 1),
        )
        .first
        .toRect()
        .shift(origin);

    final TestGesture drag = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await drag.down(lastGlyph.center);
    await tester.pump();
    await drag.moveTo(Offset(origin.dx + 2, firstGlyph.center.dy));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(controller.selection.start, 0, reason: '盒内拖到标题行首时，`# ` 前缀也应该计入选区');
    expect(controller.selection.isCollapsed, isFalse);
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
      AppPalette.midnight,
      AppPalette.midnight,
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
  /// copying, hugs the glyphs instead. The boxes now come straight from the line
  /// engine (`selectionBands`), so there is no `BoxWidthStyle` left to assert
  /// on; what has to hold is the geometry itself.
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

  /// `==高亮==` 的色带与参考项目 EPUB Reader V7 同一套几何：圆角 4px、
  /// 左右各外扩 1.5px，纵向按视觉行高上下各内缩 16%（色带高 ≈ 行高 68%）。
  testWidgets('==高亮 的色带按参考项目内缩 16%', (WidgetTester tester) async {
    const String text = '==先做功能 再做界面。==\n下一行';
    final _Pixels px = await shoot(
      tester,
      text,
      TextSelection.collapsed(offset: text.length),
    );
    final Color band = HighlightColors.darkFill;

    int top = -1;
    int bottom = -1;
    for (int y = 0; y < px.height; y++) {
      int n = 0;
      for (int x = 0; x < px.width; x++) {
        if (px.isColor(band, x, y)) n++;
      }
      if (n > 10) {
        if (top < 0) top = y;
        bottom = y;
      }
    }
    expect(top, greaterThanOrEqualTo(0), reason: '没找到高亮色带');

    final RenderLineEditable re = editable(tester) as RenderLineEditable;
    final double row = re.lineLayout!.laidOut.first.visuals.first.height;
    expect(
      (bottom - top + 1).toDouble(),
      closeTo(row * 0.68, 2),
      reason: '色带高 ${bottom - top + 1}px，行盒 $row px —— 上下各应内缩 16%',
    );
  });

  /// 暗色高亮是荧光金底配深色字；光标落进去时底片和深色字一起撤掉，源码
  /// 重新用正文色，不能在深色纸上留下看不见的深字。
  testWidgets('暗色高亮的底片与字色一起切换', (WidgetTester tester) async {
    const String text = '==先做功能 再做界面。==\n下一行';
    final _Pixels lit = await shoot(
      tester,
      text,
      TextSelection.collapsed(offset: text.length),
      palette: AppPalette.midnight,
    );

    int band = 0;
    int ink = 0;
    for (int y = 0; y < lit.height; y++) {
      for (int x = 0; x < lit.width; x++) {
        if (lit.isColor(HighlightColors.darkFill, x, y)) band++;
        if (lit.isColor(HighlightColors.darkInk, x, y)) ink++;
      }
    }
    expect(band, greaterThan(100), reason: '暗色高亮的荧光金底片没有铺出来');
    expect(ink, greaterThan(20), reason: '高亮里的字没有转成深色');

    final _Pixels editing = await shoot(
      tester,
      text,
      const TextSelection.collapsed(offset: 3),
      palette: AppPalette.midnight,
    );
    int litWhileEditing = 0;
    int inkWhileEditing = 0;
    for (int y = 0; y < editing.height; y++) {
      for (int x = 0; x < editing.width; x++) {
        if (editing.isColor(HighlightColors.darkFill, x, y)) litWhileEditing++;
        if (editing.isColor(HighlightColors.darkInk, x, y)) inkWhileEditing++;
      }
    }
    expect(litWhileEditing, lessThan(50), reason: '编辑态不该还留着荧光底片');
    expect(inkWhileEditing, lessThan(10), reason: '编辑态的源码仍应是正文色');
  });

  /// 光标落进 `==高亮==` 时和高亮标签一样退回源码：只留 `==文字==`，
  /// 底片撤掉。
  testWidgets('编辑态的高亮退回源码，不铺底片', (WidgetTester tester) async {
    const String text = '==先做功能 再做界面。==\n下一行';
    for (final int at in <int>[0, 2, 5, 11, 12, 14]) {
      final _Pixels px = await shoot(
        tester,
        text,
        TextSelection.collapsed(offset: at),
      );
      final Color band = HighlightColors.darkFill;
      int lit = 0;
      for (int y = 0; y < px.height; y++) {
        for (int x = 0; x < px.width; x++) {
          if (px.isColor(band, x, y)) lit++;
        }
      }
      expect(lit, lessThan(50), reason: '光标在 $at 时不该还有高亮底片');
    }
  });

  /// The caret belongs to the line its offset points at, not to a line anchor
  /// measured through the 1px strut.
  ///
  /// That strut is what keeps a code row at its own 20px, but [RenderEditable]
  /// also measures the caret's line with it: an end-of-text caret was painted
  /// ~15px above its paragraph, and every other line sat a few pixels off.
  /// The editor re-seats the caret on the paragraph's own line box after each
  /// move; this holds that shape on every kind of line.
  testWidgets('the caret sits on its own line', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      const String text = '第一段\n\n```\ncode\n```\n\n## 标题\n\n最后一段';
      final FocusNode focus = FocusNode();
      addTearDown(focus.dispose);
      final MarkdownSourceController controller = await pump(
        tester,
        text,
        focusNode: focus,
      );
      focus.requestFocus();
      await tester.pumpAndSettle();
      final RenderEditable re = editable(tester);

      Future<void> expectSeated(int pos, String where) async {
        controller.selection = TextSelection.collapsed(offset: pos);
        await tester.pumpAndSettle();

        // The same box `_seatCaret` seats the caret on: the paragraph's line.
        // A range is needed because a collapsed selection has no boxes.
        final ui.BoxHeightStyle style = re.selectionHeightStyle;
        re.selectionHeightStyle = ui.BoxHeightStyle.max;
        final List<TextBox> boxes = pos == text.length
            ? re.getBoxesForSelection(
                TextSelection(baseOffset: pos - 1, extentOffset: pos),
              )
            : re.getBoxesForSelection(
                TextSelection(baseOffset: pos, extentOffset: pos + 1),
              );
        re.selectionHeightStyle = style;
        expect(boxes, isNotEmpty, reason: '$where：没测到行盒');

        final Rect line = boxes.first.toRect();
        final Rect caret = re.getLocalRectForCaret(TextPosition(offset: pos));
        // 按行排版后光标跟随**这一行**的高度：标题行就该是一整个标题行高，
        // 不再被整篇共用的正文行高压住。
        final double wanted = line.height;
        expect(
          caret.height,
          closeTo(wanted, 1.0),
          reason: '$where：光标高 ${caret.height}，期望 $wanted',
        );
        expect(
          caret.center.dy,
          closeTo(line.center.dy, 1.0),
          reason: '$where：光标中心 ${caret.center.dy}，行中心 ${line.center.dy}',
        );
      }

      await expectSeated(1, '正文行中');
      await expectSeated(3, '正文行尾');
      await expectSeated(4, '空行');
      final int code = text.indexOf('code');
      await expectSeated(code + 4, '代码行');
      await expectSeated(text.indexOf('标题') + 2, '标题行');
      await expectSeated(text.length, '文末');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  /// Seating the caret after the frame painted it was a visible jump: every
  /// move first drew the native (strut-misaligned) position and then snapped to
  /// the line — 「第一次在偏移的位置显示，然后再回到正确位置，有点抖动」.
  ///
  /// The seat now runs during the field's layout, before the frame is painted,
  /// so the very first frame must already equal the settled one. This watches
  /// that first frame on every kind of line, including the empty line after a
  /// trailing newline (where the caret has no character box of its own).
  testWidgets('the caret is seated in the frame it moves', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      Future<void> expectFirstFrame(
        String text,
        List<(int, String)> cases,
      ) async {
        final FocusNode focus = FocusNode();
        addTearDown(focus.dispose);
        final MarkdownSourceController controller = await pump(
          tester,
          text,
          focusNode: focus,
        );
        focus.requestFocus();
        await tester.pumpAndSettle();
        final RenderEditable re = editable(tester);

        Rect lineBoxAt(int pos) {
          final ui.BoxHeightStyle style = re.selectionHeightStyle;
          re.selectionHeightStyle = ui.BoxHeightStyle.max;
          final List<TextBox> boxes = pos == text.length
              ? re.getBoxesForSelection(
                  TextSelection(baseOffset: pos - 1, extentOffset: pos),
                )
              : re.getBoxesForSelection(
                  TextSelection(baseOffset: pos, extentOffset: pos + 1),
                );
          re.selectionHeightStyle = style;
          expect(boxes, isNotEmpty, reason: 'pos $pos：没测到行盒');
          return boxes.first.toRect();
        }

        for (final (int pos, String where) in cases) {
          controller.selection = TextSelection.collapsed(offset: pos);
          // Exactly one frame: the frame the move is painted in.
          await tester.pump();

          final Rect line = lineBoxAt(pos);
          final bool phantom =
              pos == text.length && text.codeUnitAt(pos - 1) == 0x0A;
          final double wanted = phantom
              ? line.bottom + re.preferredLineHeight / 2
              : line.center.dy;
          final Rect first = re.getLocalRectForCaret(TextPosition(offset: pos));
          expect(
            first.center.dy,
            closeTo(wanted, 1.0),
            reason:
                '$where：第一帧光标中心 ${first.center.dy}，'
                '期望 $wanted（行 ${line.top}..${line.bottom}）',
          );

          await tester.pumpAndSettle();
          final Rect settled = re.getLocalRectForCaret(
            TextPosition(offset: pos),
          );
          expect(
            settled.center.dy,
            closeTo(first.center.dy, 0.01),
            reason:
                '$where：光标在第一帧后又动了 '
                '${settled.center.dy - first.center.dy}px',
          );
          expect(
            settled.height,
            closeTo(first.height, 0.01),
            reason:
                '$where：光标高度在第一帧后又变了 '
                '${first.height} → ${settled.height}',
          );
        }
      }

      const String mixed = '第一段\n\n```\ncode\n```\n\n## 标题\n\n最后一段';
      await expectFirstFrame(mixed, <(int, String)>[
        (1, '正文行中'),
        (mixed.indexOf('code') + 4, '代码行'),
        (mixed.indexOf('标题') + 2, '标题行'),
        (mixed.length, '文末'),
      ]);
      const String trailing = '第一段\n\n最后一段\n';
      await expectFirstFrame(trailing, <(int, String)>[
        (trailing.length, '尾随换行后的空行'),
      ]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
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
        AppPalette.midnight,
        AppPalette.midnight,
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

    // 表格不在段落里排版，行与格子的 span 树由自绘层持有：叶子要从
    // `chromeCellSpans` 读，`re.text` 只剩纯源码。
    List<TableRowChrome> rows() =>
        (editable(tester) as RenderLineEditable).tableRows().toList()..sort(
          (TableRowChrome a, TableRowChrome b) =>
              a.chromeRowIndex.compareTo(b.chromeRowIndex),
        );

    // A rendered cell's backticks are collapsed to `fontSize: 0`; an open
    // cell's are real glyphs. Counting both is enough to tell which cells the
    // painter is showing as source.
    int ticks({required bool visible}) {
      Iterable<TextSpan> all() sync* {
        for (final TableRowChrome row in rows()) {
          for (final InlineSpan cell in row.chromeCellSpans()) {
            yield* leaves(cell);
          }
        }
      }

      return all()
          .where(
            (TextSpan s) =>
                s.text == '`' && ((s.style?.fontSize ?? 0) > 0) == visible,
          )
          .length;
    }

    expect(ticks(visible: true), 0);
    expect(ticks(visible: false), 4, reason: '两颗格子里的代码都应先渲染成 chip');

    final List<List<Rect>> before = <List<Rect>>[
      for (final TableRowChrome row in rows()) row.chromeCells(),
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
      for (final TableRowChrome row in rows()) row.chromeCells(),
    ];
    // 展开一格不能改变任何一列的位置与宽度：列宽仍由渲染态决定，光标下的表
    // 不会在点击瞬间被重新分栏。展开的源码比渲染态多出标记字符（这里是两颗
    // 反引号），而表格已经不再用负字距硬挤，所以被展开的这一行可以多占一行
    // 高度；其余行的高度不变。
    for (int r = 0; r < before.length; r++) {
      for (int c = 0; c < before[r].length; c++) {
        expect(
          after[r][c].left,
          before[r][c].left,
          reason: '第 $r 行第 $c 格的左边缘被展开动作挤动了',
        );
        expect(
          after[r][c].width,
          before[r][c].width,
          reason: '第 $r 行第 $c 格的列宽被展开动作挤动了',
        );
      }
      if (r > 0) {
        expect(
          after[r][0].height,
          before[r][0].height,
          reason: '展开第 0 行不应改变第 $r 行的高度',
        );
      }
    }
    expect(after.first.first.height, greaterThanOrEqualTo(before.first.first.height));

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
      // 行不再是段落里的 `_TableRowView` widget，而是引擎的自绘块：两行都还
      // 是块，就说明这一张表没有被拖回源码。
      final List<TableRowChrome> rows = (editable(tester) as RenderLineEditable)
          .tableRows()
          .toList();
      expect(rows, hasLength(2), reason: '拖选进行中，两行都必须保持成品渲染');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a nested row steps exactly one marker column', (
    WidgetTester tester,
  ) async {
    // Two typed spaces are worth ~9px, so nesting used to be invisible. One
    // level must be worth exactly one marker column (2 + 15 + 9), which is what
    // makes a child's marker line up under its parent's text.
    //
    // 复选框由渲染层画，几何直接从渲染对象拿；导轨由 `_paintRails` 负责，
    // 像素断言在「the rail is painted」里。
    await pump(tester, '- [ ] 甲\n  - [ ] 乙\n    - [ ] 丙\n');

    final List<Rect> boxes = (editable(tester) as RenderLineEditable)
        .taskCheckboxRects();
    expect(boxes, hasLength(3));
    expect(boxes[1].left - boxes[0].left, 26);
    expect(boxes[2].left - boxes[1].left, 26);
  });

  testWidgets('the rail spans the child block and never runs between siblings', (
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
    final AppPalette p = AppPalette.midnight;

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

    // The longest unbroken run of ink in one column: glyphs are broken up by
    // the gap between lines (Ahem fills the em box, not the line box), while a
    // rail spans the child rows end to end.
    (int top, int run) columnRun(int x) {
      int best = 0;
      int bestTop = -1;
      int run = 0;
      for (int y = 0; y < height; y++) {
        if (!isPaper(x, y)) {
          run++;
          if (run > best) {
            best = run;
            bestTop = y - run + 1;
          }
        } else {
          run = 0;
        }
      }
      return (bestTop, best);
    }

    final RenderEditable re = editable(tester);
    final double left = re.localToGlobal(Offset.zero).dx;
    // 一像素线落在半像素上，取 ±1 范围内最长的那个点。
    (int top, int run, int x) columnNear(double target) {
      (int, int, int) best = (-1, 0, -1);
      for (int x = (target - 1).round(); x <= (target + 1).round(); x++) {
        final (int top, int run) = columnRun(x);
        if (run > best.$2) best = (top, run, x);
      }
      return best;
    }

    // 父级那一列在行首 +9.5（复选框中心）。同级自己那一列（26 + 9.5）在
    // 这里**不该出现**：乙和丙都没有子项，连续两个兄弟之间不穿线。
    final (int parentTop, int parentRun, int parentX) = columnNear(left + 9.5);
    final (int ownTop, int ownRun, int ownX) = columnNear(left + 35.5);
    expect(parentRun, greaterThan(40), reason: '父级竖线要跨过整段子级（x=$parentX）');
    expect(
      ownRun,
      lessThanOrEqualTo(6),
      reason: '连续同级兄弟之间不该再穿一条竖线（x=$ownX）',
    );
    // …and the parent's rail starts on the *second* line, not on its own row.
    expect(parentTop, greaterThan(20), reason: '父级自己那一行不该有竖线');
    expect(ownTop, greaterThan(20), reason: '同上');
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
    final AppPalette p = AppPalette.midnight;

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
    // Two columns mean three rules: left edge, the divider, and the right
    // edge. The row clip used to round the outermost rule past the table's
    // fractional width, so the right border vanished.
    final List<List<int>> clusters = <List<int>>[];
    for (final int x in rules) {
      if (clusters.isEmpty || x - clusters.last.last > 1) {
        clusters.add(<int>[x]);
      } else {
        clusters.last.add(x);
      }
    }
    expect(clusters, hasLength(3), reason: '竖线应有左/中/右三根，实际 x = $rules');
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
        if (px.isColor(
          px.palette.selectionEdge,
          x,
          y,
          tolerance: _Pixels.edgeTolerance,
        )) {
          n++;
        }
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

  testWidgets('a column selection tints only the chips inside that column', (
    WidgetTester tester,
  ) async {
    // The wash is a rectangle of *cells*, but a chip's fill used to be driven by
    // the linear source range. Selecting the `就写` column therefore also lit
    // every `Ctrl + …` chip in the column to its right: those characters sit
    // between the selection's two ends, so `ctx.selected` called them selected
    // even though the wash never touched their cells. user:
    // 「表格我只选中的一列，为什么旁边的代码也被选中了」
    const String text =
        '| 想要 | 就写 | 快捷键 |\n'
        '| --- | --- | --- |\n'
        '| 加粗 | `**文字**` | `Ctrl + B` |\n'
        '| 斜体 | `*文字*` | `Ctrl + I` |\n';
    final TableBlock block = TableBlock.parse(text, 0)!;
    final _Pixels px = await shoot(
      tester,
      text,
      TableRange.columnsOf(block, 1, 1).toTextSelection(),
      // The theme in the report: its selection is blue, so a tinted chip cannot
      // be confused with the neutral wash or with antialiased glyphs.
      palette: AppPalette.midnight,
    );

    final List<List<int>> bands = px.bandsOf(px.palette.selectionEdge, 40);
    expect(bands, hasLength(2), reason: '选一列只有上下两条外框');
    final int top = bands.first.last;
    final int bottom = bands.last.first;
    final int left = px.firstOf(px.palette.selectionEdge, top);
    final int right = px.lastOf(px.palette.selectionEdge, top);

    final Color selectedChip = Color.alphaBlend(
      px.palette.selection,
      px.palette.surfaceSunken,
    );

    int tinted(int x0, int x1) {
      int n = 0;
      for (int y = top + 2; y < bottom - 1; y++) {
        for (int x = x0; x <= x1; x++) {
          if (px.isColor(selectedChip, x, y, tolerance: 6)) n++;
        }
      }
      return n;
    }

    expect(
      tinted(left + 2, right - 2),
      greaterThan(200),
      reason: '选中的那一列里的代码胶囊应该带上选区底色',
    );
    expect(
      tinted(right + 2, px.width - 1),
      lessThan(60),
      reason: '右边那一列没有选中，里面的代码胶囊不该披上选中色',
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

    // One chip, not three: the zero-size backticks sit on a different baseline
    // box than the code between them, so grouping boxes by `top` used to flush
    // three fills with page-colored gaps where the backticks' padding is.
    int bandBottom = bandY;
    while (bandBottom + 1 < px.height && fill(left, bandBottom + 1)) {
      bandBottom++;
    }
    for (int y = bandTop + 4; y <= bandBottom - 4; y++) {
      final int rowLeft = leftAt(y);
      final int rowRight = rightAt(y);
      for (int x = rowLeft + 4; x <= rowRight - 4; x++) {
        expect(px.isSurface(x, y), isFalse, reason: '代码胶囊在 x=$x, y=$y 处被切成两段');
      }
    }
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
    final MarkdownSourceController controller = await pump(tester, text);
    final RenderLineEditable re = editable(tester) as RenderLineEditable;

    // 底片是行布局的一部分（`fillsFor` 用同一个扫描器），所以直接问引擎：
    // 光标落在代码里时这一行不再有底片。
    const int at = 5; // Inside the code.
    controller.selection = const TextSelection.collapsed(offset: at);
    await tester.pumpAndSettle();
    expect(
      re.lineLayout!.laidOut.single.fills,
      isEmpty,
      reason: '光标已经在代码里，底色却没有消失',
    );

    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();
    final List<LineFillRun> chips = re.lineLayout!.laidOut.single.fills;
    expect(chips, hasLength(1), reason: '光标离开后代码应该重新变成胶囊');
    expect(text.substring(chips.single.from, chips.single.to), '`code`');
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

  testWidgets('a quote shows its `>` once the caret enters', (
    WidgetTester tester,
  ) async {
    final MarkdownSourceController controller = await pump(
      tester,
      '> 引用\n正文\n',
    );
    final RenderLineEditable re = editable(tester) as RenderLineEditable;

    TextSpan? prefix() {
      TextSpan? found;
      void walk(InlineSpan span) {
        if (found != null || span is! TextSpan) return;
        if (span.text == '> ') {
          found = span;
          return;
        }
        for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }

      walk(re.lineLayout!.laidOut.first.painter.text!);
      return found;
    }

    expect(prefix()!.style!.color!.a, 0, reason: '未揭示时 `>` 只透明、不缩字');

    controller.selection = const TextSelection.collapsed(offset: 2);
    controller.repaint();
    await tester.pumpAndSettle();

    // 行尾前缀只改颜色、不改字体度量，排版缓存曾把这一行当成「没变」，
    // 光标移进来后复用旧 painter，`>` 就永远不显形。
    expect(
      prefix()!.style!.color!.a,
      greaterThan(0),
      reason: '光标移进引用行后 `>` 应显形',
    );
  });

  /// 拖动滚动条是滚动，不是选中文字。
  ///
  /// 滚动条画在滚动视图的右缘、输入框外面，按下会先落到编辑器那层裸
  /// `Listener` 上；没有拦截时它被当成「正文旁的留白」，按下即锚定选区，
  /// 往下拖就成了选中文字。这里按住条的上端往下拖，选区必须原地不动。
  testWidgets('dragging the scrollbar scrolls instead of selecting text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final String text = List<String>.generate(
      120,
      (int i) => '第 $i 行正文',
    ).join('\n');
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    addTearDown(controller.dispose);
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      MaterialApp(
        // 桌面才有滚动条：`MaterialScrollBehavior` 只在 linux / macOS / windows
        // 上给竖向滚动视图加条，主题里的 platform 就是它读到的那一个。
        theme: AppTheme.build(
          AppPalette.midnight,
        ).copyWith(platform: TargetPlatform.windows),
        scrollBehavior: const NrsScrollBehavior(),
        home: Scaffold(
          body: MarkdownEditor(
            controller: controller,
            focusNode: focus,
            scrollController: scroll,
            fontSize: 15.5,
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    await tester.pump();

    expect(scroll.position.maxScrollExtent, greaterThan(0), reason: '内容要能滚动才有条');

    // 按在视口右缘的滚动条轨道上（8px 条 + 两侧 2px 边距 = 最右 12px），
    // 往下拖一段：这一段是滚动条的地盘，输入框里的选区不能跟着动。
    const Offset onBar = Offset(795, 30);
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    final TestGesture drag = await tester.startGesture(
      onBar,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, 140));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      controller.selection,
      const TextSelection.collapsed(offset: 0),
      reason: '按住滚动条往下拉不该选中任何文字',
    );
  });

  testWidgets('图片行渲染成块，下方文字被整块挤下去', (WidgetTester tester) async {
    final ui.Image source = await makeImage(tester, 400, 200);
    await pump(
      tester,
      '![图](assets/a.png)\n下一行',
      imageProviderFor: (_) => _FixedTestImageProvider(source),
    );
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final LineDocumentLayout layout = field.lineLayout!;

    expect(layout.laidOut, hasLength(2));
    expect(layout.laidOut[0].block, isNotNull);
    expect(layout.laidOut[0].height, 200, reason: '行高等于图片高度');
    expect(layout.laidOut[1].top, 200, reason: '正文被推到图片下方');

    final List<ImageBlockChrome> blocks = field.imageBlocks();
    expect(blocks, hasLength(1));
    expect(blocks.single.chromeImageBounds().size, const Size(400, 200));
    expect(blocks.single.imageSourceStart, 0);
    expect(blocks.single.chromeResizeHandle(), isNotNull);
  });

  testWidgets('光标停在图片行上图片还在，真的选字才退回源码', (
    WidgetTester tester,
  ) async {
    final ui.Image source = await makeImage(tester, 400, 200);
    final MarkdownSourceController controller = await pump(
      tester,
      '![图](assets/a.png)\n下一行',
      imageProviderFor: (_) => _FixedTestImageProvider(source),
    );
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    expect(field.lineLayout!.laidOut[0].height, 200);

    // 粘贴完光标就压在这一行上：图片必须照样画着，不能退回源码。
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();
    expect(field.imageBlocks(), hasLength(1), reason: '光标压在本行，图片仍在');
    expect(field.lineLayout!.laidOut[0].height, 200);

    // 真的在选这一行的字，才摊开源码——那时要看见自己选了什么。
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    await tester.pumpAndSettle();
    expect(field.imageBlocks(), isEmpty);
    expect(field.lineLayout!.laidOut[0].block, isNull);
    expect(field.lineLayout!.laidOut[0].height, lessThan(200));

    controller.selection = const TextSelection.collapsed(offset: 19);
    await tester.pumpAndSettle();
    expect(field.imageBlocks(), hasLength(1), reason: '光标移到下一行，图片应恢复');
    expect(field.lineLayout!.laidOut[0].height, 200);
  });

  testWidgets('图片加载失败留下 120 高占位，不拦住后续正文', (WidgetTester tester) async {
    await pump(tester, '![坏](missing.png)\n正文');
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final LineDocumentLayout layout = field.lineLayout!;

    expect(layout.laidOut[0].block, isNotNull);
    expect(layout.laidOut[0].height, 120);
    expect(layout.laidOut[1].top, 120);
    final ImageLineBlock block = layout.laidOut[0].block! as ImageLineBlock;
    expect(block.failed, isTrue);
    expect(field.imageBlocks().single.chromeResizeHandle(), isNotNull);
  });

  testWidgets('图片解码完成只重排图片那一行', (WidgetTester tester) async {
    final ui.Image source = await makeImage(tester, 400, 200);
    final Completer<ImageInfo> pending = Completer<ImageInfo>();
    await pump(
      tester,
      '上一行\n![图](assets/a.png)\n下一行',
      imageProviderFor: (_) => _DeferredTestImageProvider(pending.future),
    );
    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final LineDocumentLayout before = field.lineLayout!;
    expect(before.laidOut[1].height, 120);
    final LineBlockView? imageBlock = before.laidOut[1].block;
    final TextPainter below = before.laidOut[2].painter;
    final double belowTop = before.laidOut[2].top;

    pending.complete(ImageInfo(image: source.clone()));
    await tester.pump();
    await tester.pumpAndSettle();

    final LineDocumentLayout after = field.lineLayout!;
    expect(after.laidOut[1].height, 200);
    expect(
      identical(after.laidOut[1].block, imageBlock),
      isTrue,
      reason: '图片流不该因为重排被重挂',
    );
    expect(
      identical(after.laidOut[2].painter, below),
      isTrue,
      reason: '没改字的行应整行复用，不重新量',
    );
    expect(after.laidOut[2].top, closeTo(belowTop + 80, 0.01));
  });

  testWidgets('图片真的画进正文列（像素探针）', (WidgetTester tester) async {
    const Color green = Color(0xFF12A34B);
    final ui.Image source = await solidImage(
      tester,
      width: 200,
      height: 100,
      color: green,
    );
    final _Pixels px = await shoot(
      tester,
      '![图](assets/a.png)\n下一行',
      const TextSelection.collapsed(offset: 19),
      imageProviderFor: (_) => _FixedTestImageProvider(source),
    );

    int minX = px.width;
    int maxX = -1;
    int minY = px.height;
    int maxY = -1;
    for (int y = 0; y < px.height; y++) {
      for (int x = 0; x < px.width; x++) {
        if (!px.isColor(green, x, y)) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
    expect(maxX, greaterThanOrEqualTo(minX), reason: '图片必须真的画出来');
    expect(maxX - minX + 1, closeTo(200, 4));
    expect(maxY - minY + 1, closeTo(100, 4));
    expect(minX, greaterThanOrEqualTo(40), reason: '图片在正文列内，不越过左内边距');
  });
}

class _FixedTestImageProvider extends ImageProvider<_FixedTestImageProvider> {
  _FixedTestImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_FixedTestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FixedTestImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FixedTestImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())),
  );
}

class _DeferredTestImageProvider
    extends ImageProvider<_DeferredTestImageProvider> {
  _DeferredTestImageProvider(this.info);

  final Future<ImageInfo> info;

  @override
  Future<_DeferredTestImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture<_DeferredTestImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _DeferredTestImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(info);
}

class _Pixels {
  _Pixels(this.width, this.height, this.bytes, this.palette);

  final int width;
  final int height;
  final ByteData bytes;
  final AppPalette palette;

  /// How far a pixel may drift from the outline's colour and still count as the
  /// outline. Deliberately tighter than [isColor]'s own default.
  ///
  /// The edge is stroked on the pixel grid, so its own pixels land on the exact
  /// value and need no room at all. A looser window starts reading *ink* as
  /// edge instead: at `tolerance: 24` a row of glyphs reached the same pixel
  /// count as a real box edge — which is why a part-of-a-table selection used
  /// to report a phantom band through its middle.
  /// 16 is where the leak starts, so this sits safely below it.
  static const int edgeTolerance = 12;

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
        if (isColor(color, x, y, tolerance: edgeTolerance)) n++;
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
      if (isColor(color, x, y, tolerance: edgeTolerance)) return x;
    }
    return -1;
  }

  int lastOf(Color color, int y) {
    for (int x = width - 1; x >= 0; x--) {
      if (isColor(color, x, y, tolerance: edgeTolerance)) return x;
    }
    return -1;
  }
}
