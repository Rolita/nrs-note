import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// 指针停在图片上时滚轮还得能滚。
///
/// `_ChromeShield` 命中图片本体就 `return true`、不再往下问——光标才不会落进
/// 图片那一行。代价是 `SingleChildScrollView` 整棵子树被从命中链上剪掉，而
/// `PointerSignalEvent` 只发给命中链上的监听者：滚轮到不了 `Scrollable`，指针
/// 一停在图上就滚不动。这里从外面量出来。
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

void main() {
  const String imageLine = '![图](a.png)';

  /// 图片在最上面，后面跟一屏放不下的正文：既能悬停到图，也有地方可滚。
  final String document = <String>[
    imageLine,
    ...List<String>.generate(120, (int i) => '第 $i 行正文，用来把版面撑长。'),
  ].join('\n');

  Future<ui.Image> makeImage(WidgetTester tester) async {
    final ui.Image result = (await tester.runAsync(
      () => createTestImage(width: 400, height: 200),
    ))!;
    addTearDown(result.dispose);
    return result;
  }

  Future<({ScrollController scroll, RenderLineEditable field})> pumpEditor(
    WidgetTester tester,
    ui.Image image,
  ) async {
    final MarkdownSourceController controller = MarkdownSourceController(
      text: document,
    );
    final FocusNode focus = FocusNode();
    final ScrollController scroll = ScrollController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          body: MarkdownEditor(
            controller: controller,
            focusNode: focus,
            scrollController: scroll,
            fontSize: 15.5,
            padding: EdgeInsets.zero,
            imageProviderFor: (_) => _TestImageProvider(image),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    // 光标落在正文里，图片因此保持渲染态（光标停在图片行会退回源码）。
    controller.selection = TextSelection.collapsed(
      offset: document.indexOf('第 0 行'),
    );
    await tester.pumpAndSettle();
    return (
      scroll: scroll,
      field: tester.allRenderObjects.whereType<RenderLineEditable>().first,
    );
  }

  testWidgets('指针停在图片上，滚轮照样滚', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester);
    final ({ScrollController scroll, RenderLineEditable field}) ed =
        await pumpEditor(tester, image);

    expect(ed.scroll.offset, 0);
    final Rect bounds = ed.field.imageBlocks().single.chromeImageBounds();
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();

    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();

    expect(
      ed.scroll.offset,
      greaterThan(0),
      reason: '指针停在图片上，滚轮不能被挡住',
    );
  });

  testWidgets('图上滚和字上滚走一样远，不会滚两下', (WidgetTester tester) async {
    final ui.Image image = await makeImage(tester);
    final ({ScrollController scroll, RenderLineEditable field}) ed =
        await pumpEditor(tester, image);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    // 先在图下面的正文上滚一次，记下正常的那一段距离。
    final Rect bounds = ed.field.imageBlocks().single.chromeImageBounds();
    await tester.sendEventToBinding(
      mouse.hover(Offset(bounds.center.dx, bounds.bottom + 80)),
    );
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();
    final double onText = ed.scroll.offset;
    expect(onText, greaterThan(0), reason: '正文上本来就能滚');

    // 回到顶部，改在图本体上滚同样一格。
    ed.scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(mouse.hover(bounds.center));
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();

    expect(
      ed.scroll.offset,
      onText,
      reason: '图上的滚动要和正文上完全一致：不能没有，也不能滚两倍',
    );
  });
}
