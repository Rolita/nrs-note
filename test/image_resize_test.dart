import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/image_markup.dart';
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
  }) async {
    final MarkdownSourceController controller = MarkdownSourceController(
      text: text,
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

  testWidgets('悬停图片右下角给改宽光标，移开恢复', (WidgetTester tester) async {
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

    await tester.sendEventToBinding(
      mouse.hover(ed.handle().center - const Offset(200, 120)),
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
}
