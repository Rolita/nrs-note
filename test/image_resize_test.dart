import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/image_markup.dart';
import 'package:nrs/ui/editor/line_layout/line_block_view.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// 图片右下角手柄的完整手势：悬停、预览、提交、取消与撤销。
///
/// 手柄是自绘块上的一个命中区，只能从外面测：先问渲染对象它把柄画在了哪里，
/// 再把指针按过去。
class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  _TestImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_TestImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _TestImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())),
  );
}

typedef _Editor = ({
  MarkdownSourceController controller,
  RenderLineEditable Function() field,
  Rect Function() handle,
});

void main() {
  const String imageLine = '![图](a.png)';
  const String text = '$imageLine\n下一行';

  Future<ui.Image> makeImage(WidgetTester tester, int width, int height) async {
    final ui.Image result = (await tester.runAsync(
      () => createTestImage(width: width, height: height),
    ))!;
    addTearDown(result.dispose);
    return result;
  }

  /// 一个只有图片行的编辑器；光标停在下一行行尾，图片因此保持渲染态。
  /// 传 null 的 [image] 是加载失败：块退成 360×120 的占位，手柄仍在。
  Future<_Editor> pumpEditor(
    WidgetTester tester, {
    ui.Image? image,
    List<String>? changes,
    String? document,
  }) async {
    final MarkdownSourceController controller = MarkdownSourceController(
      text: document ?? text,
    );
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          body: MarkdownEditor(
            controller: controller,
            focusNode: focus,
            scrollController: ScrollController(),
            fontSize: 15.5,
            padding: EdgeInsets.zero,
            imageProviderFor: (_) =>
                image == null ? null : _TestImageProvider(image),
            onChanged: changes?.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    controller.selection = const TextSelection.collapsed(offset: 15);
    await tester.pumpAndSettle();
    RenderLineEditable field() =>
        tester.allRenderObjects.whereType<RenderLineEditable>().first;
    Rect handle() => field().imageBlocks().single.chromeResizeHandle()!.rect;
    return (controller: controller, field: field, handle: handle);
  }

  testWidgets('悬停图片右下角给改宽光标，图上是点击，移开恢复', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    MouseCursor? cursor() => tester
        .widget<LineEditableText>(find.byKey(const Key('nrs-editor-field')))
        .mouseCursor;
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(mouse.hover(ed.handle().center));
    await tester.pumpAndSettle();
    expect(
      cursor(),
      SystemMouseCursors.resizeUpLeftDownRight,
      reason: '右下角是拖拽改宽，不是落光标',
    );

    // 图片本体：一次点击（选中它），不是 I-beam——光标落进图片行看不见。
    await tester.sendEventToBinding(
      mouse.hover(ed.handle().center - const Offset(200, 120)),
    );
    await tester.pumpAndSettle();
    expect(cursor(), SystemMouseCursors.click);

    // 离开图片、落到下一行正文上。
    await tester.sendEventToBinding(
      mouse.hover(ed.handle().center + const Offset(-200, 40)),
    );
    await tester.pumpAndSettle();
    expect(cursor(), SystemMouseCursors.text);
  });

  testWidgets('拖动只改预览，松手才写一次源码', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final List<String> changes = <String>[];
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      changes: changes,
    );
    final TextPainter below = ed.field().lineLayout!.laidOut[1].painter;
    final TextSelection before = ed.controller.selection;

    final TestGesture drag = await tester.startGesture(
      ed.handle().center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(120, 0));
    await tester.pump();

    expect(ed.controller.text, text, reason: '拖动期间绝不写源码');
    expect(changes, isEmpty, reason: '拖动期间不产生 onChanged');
    expect(ed.controller.selection, before, reason: '按手柄不移动光标');
    expect(ed.field().lineLayout!.laidOut[0].height, closeTo(260, 0.01));
    expect(
      ed.field().imageBlocks().single.chromeImageBounds().width,
      closeTo(520, 0.01),
      reason: '宽度跟手，行高按比例变',
    );
    expect(
      identical(ed.field().lineLayout!.laidOut[1].painter, below),
      isTrue,
      reason: '下方文字只被平移，不该重新量',
    );

    await drag.up();
    await tester.pumpAndSettle();

    expect(changes, hasLength(1), reason: '松手一次写值');
    expect(
      ed.controller.text,
      '<img src="a.png" width="520" alt="图">\n下一行',
    );
    expect(
      ImageMarkup.parseLine(ed.controller.text.split('\n').first)!.width,
      520,
    );
    expect(ed.field().lineLayout!.laidOut[0].height, closeTo(260, 0.01));
    expect(ed.controller.selection.baseOffset, greaterThan(0));
  });

  testWidgets('改宽后按一次 Ctrl+Z 回到拖动前的宽度', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);

    final TestGesture drag = await tester.startGesture(
      ed.handle().center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(80, 0));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(
      ed.controller.text,
      '<img src="a.png" width="480" alt="图">\n下一行',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(
      ed.controller.text,
      text,
      reason: '一次 Ctrl+Z 只回退改宽，不该把上一段文字也吞掉',
    );
    expect(ImageMarkup.parseLine(imageLine)!.width, isNull);

    // 撤销按公共前后缀把光标落在还原内容的末尾，也就是图片行行尾；那会让
    // 这一行按揭示规则退回源码。光标离开后，图片必须回到自然尺寸。
    ed.controller.selection = const TextSelection.collapsed(offset: 15);
    await tester.pumpAndSettle();
    expect(ed.field().lineLayout!.laidOut[0].height, closeTo(200, 0.01));
  });

  testWidgets('宽度夹在 96 与正文列宽之间', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);

    TestGesture drag = await tester.startGesture(
      ed.handle().center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(-1000, 0));
    await tester.pump();
    expect(
      ed.field().imageBlocks().single.chromeImageBounds().width,
      closeTo(96, 0.01),
      reason: '再窄也要留出能点住手柄的宽度',
    );
    await drag.up();
    await tester.pumpAndSettle();
    expect(ed.controller.text, '<img src="a.png" width="96" alt="图">\n下一行');

    drag = await tester.startGesture(
      ed.handle().center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(2000, 0));
    await tester.pump();
    expect(
      ed.field().imageBlocks().single.chromeImageBounds().width,
      closeTo(720, 0.01),
      reason: '不能宽出正文列',
    );
    await drag.up();
    await tester.pumpAndSettle();
    expect(ed.controller.text, '<img src="a.png" width="720" alt="图">\n下一行');
  });

  testWidgets('Esc 丢掉预览，源码不动', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final List<String> changes = <String>[];
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      changes: changes,
    );

    final TestGesture drag = await tester.startGesture(
      ed.handle().center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(120, 0));
    await tester.pump();
    expect(ed.field().lineLayout!.laidOut[0].height, closeTo(260, 0.01));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(ed.controller.text, text, reason: '取消不写源码');
    expect(changes, isEmpty);
    expect(ed.field().lineLayout!.laidOut[0].height, closeTo(200, 0.01));

    await drag.up();
    await tester.pumpAndSettle();
    expect(ed.controller.text, text, reason: 'Esc 之后抬手也不该提交');
  });

  testWidgets('图片加载失败也能从手柄改宽', (WidgetTester tester) async {
    final _Editor ed = await pumpEditor(tester);
    expect(ed.field().lineLayout!.laidOut[0].height, 120);

    final TestGesture drag = await tester.startGesture(
      ed.handle().center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(60, 0));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      ed.controller.text,
      '<img src="a.png" width="420" alt="图">\n下一行',
      reason: '图片坏了，宽度仍然写得回去',
    );
  });

  testWidgets('悬停出「编辑这个区块」，点开是图上方的源码行', (
    WidgetTester tester,
  ) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final List<String> changes = <String>[];
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      changes: changes,
    );
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    expect(find.byTooltip('编辑这个区块'), findsNothing, reason: '没悬停时不出现');

    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();
    expect(find.byTooltip('编辑这个区块'), findsOneWidget);

    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();

    // 浮层里是这一行的原文，而图片没有被源码顶掉。
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, imageLine);
    expect(ed.field().imageBlocks(), hasLength(1), reason: '编辑时图片仍然在');
    // 它不是弹窗：没有标题栏、没有「单元格」标签、没有快捷键提示。
    expect(find.text('图片'), findsNothing);
    expect(find.text('单元格'), findsNothing);
    expect(find.textContaining('Enter 确认'), findsNothing);
    expect(field.decoration?.border, InputBorder.none);
    // 主题里配了 `focusedBorder`，它比 `border` 优先——不逐个状态关掉，一进来
    // 就套着一个圆角强调色框，看着又像弹窗了。
    expect(field.decoration?.focusedBorder, InputBorder.none);
    expect(field.decoration?.enabledBorder, InputBorder.none);
    expect(field.decoration?.filled, isFalse, reason: '不能在纸色上再铺一层白');
    // 这一行是 HTML，不是链接：底色用正文色，具体每个词由词法着色决定。
    expect(field.style?.color, AppPalette.light.textPrimary);
    // 光标落在行尾而不是全选：整行被选区染色就是一根紫条，看着又像面板了。
    expect(field.controller!.selection.isCollapsed, isTrue);
    expect(field.controller!.selection.baseOffset, imageLine.length);
    // 浮窗贴在图片左上角内侧：不占布局，图片一个像素都没动。
    expect(ed.field().imageBlocks().single.chromeImageBounds(), bounds);
    final Rect window = tester.getRect(find.byType(TextField));
    expect(window.left, greaterThanOrEqualTo(bounds.left - 0.5));
    expect(window.top, greaterThanOrEqualTo(bounds.top - 0.5));
    expect(window.top, lessThan(bounds.bottom), reason: '浮在图上，不是挤进版面里');

    await tester.enterText(find.byType(TextField), '![新图](b.png)');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(changes.last, '![新图](b.png)\n下一行');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('源码行按 HTML 词法着色，不是整行一个链接色', (WidgetTester tester) async {
    const String html = '<img src="a.png" width="200" alt="图">';
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      document: '$html\n下一行',
    );
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(
      mouse.hover(ed.field().imageBlocks().single.chromeImageBounds().center),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();

    final TextField field = tester.widget<TextField>(find.byType(TextField));
    final TextSpan span = field.controller!.buildTextSpan(
      context: tester.element(find.byType(TextField)),
      style: field.style,
      withComposing: false,
    );
    expect(span.toPlainText(), html, reason: '着色不能动字');

    final List<TextSpan> children = span.children!.cast<TextSpan>();
    Iterable<String?> ofColor(Color color) => children
        .where((TextSpan s) => s.style?.color == color)
        .map((TextSpan s) => s.text);

    expect(ofColor(AppPalette.light.danger), contains('img'), reason: '标签名');
    expect(
      ofColor(AppPalette.light.warning),
      containsAll(<String>['src', 'width', 'alt']),
      reason: '属性名',
    );
    expect(
      ofColor(AppPalette.light.success),
      containsAll(<String>['a.png', '200', '图']),
      reason: '属性值',
    );
    expect(
      ofColor(AppPalette.light.accent),
      isEmpty,
      reason: '整行染成链接色会让人以为点它能跳转',
    );
  });

  testWidgets('Esc 关掉源码行，一个字都不动', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final List<String> changes = <String>[];
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      changes: changes,
    );
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(
      mouse.hover(ed.field().imageBlocks().single.chromeImageBounds().center),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '乱改一通');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(changes, isEmpty);
    expect(ed.controller.text, text);
  });

  testWidgets('关掉源码浮窗后按钮回来，第二次也开得出来', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byTooltip('编辑这个区块'),
      findsOneWidget,
      reason: '指针还停在图上，按钮不能凭空消失',
    );

    // 第二次：必须一开就出来。点一下没反应、得再点一次才灵，是最难受的那种坏。
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      imageLine,
    );
  });

  // ------------------------------------------------------- 点中 / 悬停的细则

  /// 点一下图片本体（走真实指针，好让命中链和 _ChromeShield 都参与）。
  Future<void> tapImage(WidgetTester tester, _Editor ed) async {
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    final TestGesture tap = await tester.startGesture(
      bounds.center,
      kind: PointerDeviceKind.mouse,
    );
    await tap.up();
    await tester.pumpAndSettle();
  }

  testWidgets('点图片不落光标，只画一圈边框', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final TextSelection before = ed.controller.selection;

    expect(
      ed.field().imageBlocks().single.chromeSelected,
      isFalse,
      reason: '还没点，不该有边框',
    );

    await tapImage(tester, ed);

    expect(
      ed.controller.selection,
      before,
      reason: '图片行是自绘的，光标落进去看不见——点图不该移动光标',
    );
    expect(ed.field().imageBlocks().single.chromeSelected, isTrue);
    expect(ed.controller.text, text, reason: '点一下不该改文档');
  });

  testWidgets('点图片本体拖不动：搬图只能从右上角的按钮开始', (
    WidgetTester tester,
  ) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();

    // 从图片正中间按下去，拖到正文下方。
    final TestGesture drag = await tester.startGesture(
      bounds.center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    await drag.moveTo(Offset(bounds.center.dx, bounds.bottom + 60));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      ed.controller.text,
      text,
      reason: '图片是正文里最大的一块，随手一拖就搬走比拖不动难受得多',
    );
    // 这一下仍然算「点中它」：边框该在，按钮该出来。
    expect(ed.field().imageBlocks().single.chromeSelected, isTrue);
  });

  testWidgets('点中之后两个按钮固定显示，点别处收起', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tapImage(tester, ed);
    // 指针跑远：悬停早没了，按钮还在。
    await tester.sendEventToBinding(mouse.hover(const Offset(5, 400)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看大图'), findsOneWidget);
    expect(find.byTooltip('编辑这个区块'), findsOneWidget);

    // 点正文把选中收掉。
    final TestGesture elsewhere = await tester.startGesture(
      const Offset(20, 400),
      kind: PointerDeviceKind.mouse,
    );
    await elsewhere.up();
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看大图'), findsNothing);
    expect(find.byTooltip('编辑这个区块'), findsNothing);
    expect(ed.field().imageBlocks().single.chromeSelected, isFalse);
  });

  testWidgets('悬停图片出两个按钮，移开就没了', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    expect(find.byTooltip('查看大图'), findsNothing);

    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看大图'), findsOneWidget);
    expect(find.byTooltip('编辑这个区块'), findsOneWidget);

    await tester.sendEventToBinding(mouse.hover(const Offset(5, 400)));
    await tester.pumpAndSettle();
    expect(find.byTooltip('查看大图'), findsNothing);
    expect(find.byTooltip('编辑这个区块'), findsNothing);
  });

  // ------------------------------------------------------------- 删除整张图

  testWidgets('光标停在图片行尾按 Backspace，整张图一起走', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);

    // 图片右侧：行尾。
    ed.controller.selection = TextSelection.collapsed(offset: imageLine.length);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();

    expect(
      ed.controller.text,
      '下一行',
      reason: '只吃掉 `>` 会留下半截标签，图片也没了',
    );
    expect(ed.field().imageBlocks(), isEmpty);
  });

  testWidgets('光标停在图片行首按 Delete，整张图一起走', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);

    ed.controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();

    expect(ed.controller.text, '下一行', reason: '只吃掉 `<` 同样只剩废源码');
    expect(ed.field().imageBlocks(), isEmpty);
  });

  testWidgets('选中图片后按 Backspace / Delete，整张图一起走', (
    WidgetTester tester,
  ) async {
    final ui.Image image = await makeImage(tester, 400, 200);

    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.delete,
    ]) {
      final _Editor ed = await pumpEditor(tester, image: image);
      await tapImage(tester, ed);
      expect(
        ed.field().imageBlocks().single.chromeSelected,
        isTrue,
        reason: '先确认真的选中了',
      );

      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();

      expect(ed.controller.text, '下一行', reason: '$key 应该删掉整张图');
      expect(ed.field().imageBlocks(), isEmpty);
    }
  });

  // ------------------------------------------------------------- 拖动整块搬家

  /// 正文列里横向 [fraction] 处的全局 x：0 是左边缘，1 是右边缘。
  ///
  /// 落点贴哪一边就看它——左三分之一贴左，右三分之一贴右，中间独占一行。
  double columnX(_Editor ed, double fraction) {
    final RenderLineEditable field = ed.field();
    final double left = field.localToGlobal(Offset.zero).dx;
    return left + field.lineLayout!.width * fraction;
  }

  /// 从图片中间按住往外拖，落到 [target]。
  /// 把图片搬到 [target]。
  ///
  /// ⛔ 起点是右上角那颗「移动」按钮，不是图片本身：点图片本体只选中、不搬，
  /// 这是刻意的（图片是正文里最大的一块，随手一拖就把它挪走比「拖不动」难受）。
  Future<void> dragImage(
    WidgetTester tester,
    _Editor ed,
    Offset target,
  ) async {
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    // 按钮悬停才出来，先把指针挪到图上。
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();

    final TestGesture drag = await tester.startGesture(
      tester.getCenter(find.byTooltip('移动')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveTo(target);
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
  }

  testWidgets('把图片拖到正文下方：整行跟着走，松手只写一次', (
    WidgetTester tester,
  ) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final List<String> changes = <String>[];
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      changes: changes,
    );
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();

    // 拖到所有正文的下方、正文列的中间：落点吸附到最后一行之后，不贴边。
    await dragImage(
      tester,
      ed,
      Offset(columnX(ed, 0.5), bounds.bottom + 40),
    );

    expect(ed.controller.text, '下一行\n$imageLine');
    expect(changes, hasLength(1), reason: '拖动期间不写，松手落成一次');
    expect(ed.field().imageBlocks(), hasLength(1));
    expect(
      ed.field().imageBlocks().single.chromeSelected,
      isTrue,
      reason: '搬完仍然选中它，人得看得见自己挪的是哪张图',
    );
  });

  testWidgets('拖到右边三分之一：写成右浮动，正文绕到左边', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();

    // 落点还在图片自己身上：不搬家，只改贴哪一边。
    await dragImage(
      tester,
      ed,
      Offset(columnX(ed, 0.85), bounds.center.dy),
    );

    expect(
      ed.controller.text,
      '<img src="a.png" align="right" alt="图">\n下一行',
      reason: '贴右边要写进源码，别的编辑器读得到',
    );
    // 图片行不再独占一行：它和「下一行」共用同一段纵向空间。
    final RenderLineEditable field = ed.field();
    expect(field.imageBlocks(), hasLength(1));
    expect(
      field.lineLayout!.laidOut.first.height,
      0,
      reason: '浮动图片那一行高度为 0，正文才能绕到旁边',
    );
    expect(
      field.lineLayout!.laidOut.last.insets.right,
      greaterThan(100),
      reason: '右浮动的图片把正文挤到左边',
    );
  });

  testWidgets('拖到左边三分之一：写成左浮动，正文绕到右边', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();

    await dragImage(
      tester,
      ed,
      Offset(columnX(ed, 0.15), bounds.center.dy),
    );

    expect(
      ed.controller.text,
      '<img src="a.png" align="left" alt="图">\n下一行',
    );
    final RenderLineEditable field = ed.field();
    // 正文从图片右边起笔：gutter 让出了图片的宽度。
    expect(
      field.lineLayout!.laidOut.last.insets.left,
      greaterThan(100),
      reason: '左浮动的图片把正文挤到右边',
    );
  });

  testWidgets('已经在浮动，再拖回中间就取消浮动', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      document: '<img src="a.png" align="right" alt="图">\n下一行',
    );
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();

    await dragImage(tester, ed, Offset(columnX(ed, 0.5), bounds.center.dy));

    expect(ed.controller.text, '$imageLine\n下一行', reason: '回到独占一行');
  });

  testWidgets('悬停出「移动」按钮，按住它往右拖就成了右浮动', (
    WidgetTester tester,
  ) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();
    expect(find.byTooltip('移动'), findsOneWidget, reason: '悬停才露出来');

    // 按住那颗按钮往右拖：它存在的意义就是拖，不需要先走完拖拽阈值。
    final TestGesture drag = await tester.startGesture(
      tester.getCenter(find.byTooltip('移动')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveTo(Offset(columnX(ed, 0.85), bounds.center.dy));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(ed.controller.text, '<img src="a.png" align="right" alt="图">\n下一行');
    expect(ed.field().imageBlocks(), hasLength(1));
  });

  testWidgets('拖动途中文档一个字都不动，Esc 丢掉插入线', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    final List<String> changes = <String>[];

    // 从右上角的按钮起拖——点图片本体不搬。
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();

    final TestGesture drag = await tester.startGesture(
      tester.getCenter(find.byTooltip('移动')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(ed.controller.text, text, reason: '还没松手，源码不该动');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await drag.moveBy(const Offset(0, 40));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();

    expect(ed.controller.text, text, reason: 'Esc 之后这一拖作废');
    expect(changes, isEmpty);
  });

  testWidgets('拖回原处等于没拖：不写源码，也不进撤销栈', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final List<String> changes = <String>[];
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      changes: changes,
    );
    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();

    await dragImage(
      tester,
      ed,
      Offset(columnX(ed, 0.5), bounds.center.dy + 20),
    );

    expect(ed.controller.text, text, reason: '落点还在自己身上，搬了等于没搬');
    expect(changes, isEmpty);
  });

  testWidgets('查看大图铺满一屏，点一下就退出来', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    final Rect bounds = ed.field().imageBlocks().single.chromeImageBounds();
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看大图'));
    await tester.pumpAndSettle();

    // 放大层里才有 Image 控件：正文那张是自绘的，不是 widget。
    expect(find.byType(Image), findsOneWidget);
    expect(ed.field().imageBlocks(), hasLength(1), reason: '正文那张还在');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(ed.field().imageBlocks(), hasLength(1));
  });

  // ------------------------------------------------------- 块的生命周期

  testWidgets('在图片上方回车插一行，图片仍然按原尺寸画出来', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final double before = ed.field().imageBlocks().single.chromeImageBounds().height;
    expect(before, closeTo(200, 1));

    // 光标挪到图片行行首再回车：整行下移，块要跟着走。
    ed.controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final List<ImageBlockChrome> after = ed.field().imageBlocks();
    expect(after, hasLength(1));
    expect(
      after.single.chromeImageBounds().height,
      closeTo(200, 1),
      reason: '不能掉回 120 高的占位（那在深色主题下就是一整块黑的）',
    );
  });

  testWidgets('改宽度不重挂图片流：还是同一个块', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final ImageBlockChrome before = ed.field().imageBlocks().single;
    expect(before.chromeImageBounds().width, closeTo(400, 1));

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      mouse.hover(before.chromeImageBounds().center),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '<img src="a.png" width="200" alt="图">',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    final ImageBlockChrome after = ed.field().imageBlocks().single;
    expect(identical(after, before), isTrue, reason: '引用没变，不该重建块');
    expect(after.chromeImageBounds().width, closeTo(200, 1));
    expect(after.chromeImageBounds().height, closeTo(100, 1));
  });

  testWidgets('点开「编辑这个区块」只是浮出一块窗，版面一个像素都不动', (
    WidgetTester tester,
  ) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      document: '一\n\n二\n\n三\n\n四\n\n![图](a.png)\n下一行',
    );
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    final ImageBlockChrome block = ed.field().imageBlocks().single;
    final Rect before = block.chromeImageBounds();
    final double documentHeight = ed.field().lineLayout!.height;
    final double nextLineTop = ed.field().lineLayout!.laidOut.last.top;

    await tester.sendEventToBinding(mouse.hover(before.center));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();

    // 图片原地不动、整篇高度不变、下面那段文字也没被推下去。
    expect(block.chromeImageBounds(), before);
    expect(ed.field().lineLayout!.height, documentHeight);
    expect(ed.field().lineLayout!.laidOut.last.top, nextLineTop);

    // 浮窗压在图上，而不是在版面里占一行。
    final Rect window = tester.getRect(find.byType(TextField));
    expect(window.top, greaterThanOrEqualTo(before.top));
    expect(window.bottom, lessThanOrEqualTo(before.bottom));
    expect(window.left, greaterThanOrEqualTo(before.left - 0.5));
  });

  testWidgets('浮动图片点开源码浮窗，贴边与绕排都不变', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(
      tester,
      image: image,
      document: '<img src="a.png" align="right" alt="图">\n下一行',
    );
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    final ImageBlockChrome block = ed.field().imageBlocks().single;
    final Rect before = block.chromeImageBounds();
    final double insetBefore = ed.field().lineLayout!.laidOut.last.insets.right;

    await tester.sendEventToBinding(mouse.hover(before.center));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();

    expect(block.chromeImageBounds(), before, reason: '贴边的那张图不该跳回左边');
    expect(
      ed.field().lineLayout!.laidOut.last.insets.right,
      insetBefore,
      reason: '旁边的正文照旧绕排，不该因为改源码就重排',
    );
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('关掉源码浮窗，图片还在原处', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final _Editor ed = await pumpEditor(tester, image: image);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    final ImageBlockChrome block = ed.field().imageBlocks().single;
    final Rect before = block.chromeImageBounds();
    await tester.sendEventToBinding(mouse.hover(before.center));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑这个区块'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(block.chromeImageBounds(), before, reason: '从头到尾就没挪过');
  });

  testWidgets('查看大图盖住整个窗口，不只是编辑区', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester, 400, 200);
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
    );
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);
    bool leftTapped = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          body: Row(
            children: <Widget>[
              // 左边这一列冒充文件列表：它只有 200 宽，盖不盖得住一看便知。
              SizedBox(
                width: 200,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => leftTapped = true,
                  child: const ColoredBox(color: Color(0xFFE0E0E0)),
                ),
              ),
              Expanded(
                child: MarkdownEditor(
                  controller: controller,
                  focusNode: focus,
                  scrollController: ScrollController(),
                  fontSize: 15.5,
                  padding: EdgeInsets.zero,
                  imageProviderFor: (_) => _TestImageProvider(image),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    RenderLineEditable field() =>
        tester.allRenderObjects.whereType<RenderLineEditable>().first;
    final Rect bounds = field().imageBlocks().single.chromeImageBounds();

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看大图'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    // 点左边那一列：放大层盖着它，所以这一下是「关掉放大层」，不是点文件列表。
    await tester.tapAt(const Offset(100, 300));
    await tester.pumpAndSettle();
    expect(leftTapped, isFalse, reason: '放大层盖住了整个窗口');
    expect(find.byType(Image), findsNothing);
  });
}
