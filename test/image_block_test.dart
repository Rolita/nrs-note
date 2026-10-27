import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';

/// 一张图需要 `ui.Image` 才能对齐尺寸规则，而测试里造图必须走真实解码。
/// 解析交给一次性 completer：缓存命中的同步回调正是要覆盖的分支。
class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  _TestImageProvider(ui.Image image)
    : image = image,
      future = SynchronousFuture<ImageInfo>(
        ImageInfo(image: image.clone()),
      );

  _TestImageProvider.deferred(this.image, this.future);

  final ui.Image image;
  final Future<ImageInfo> future;

  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_TestImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _TestImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(future);
}

class _FailingImageProvider extends ImageProvider<_FailingImageProvider> {
  @override
  Future<_FailingImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FailingImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    Future<ImageInfo>.error(StateError('corrupt image')),
  );
}

void main() {
  LineBlockContext context(double width) => LineBlockContext(
    contentWidth: width,
    textScaler: TextScaler.noScaling,
    textDirection: TextDirection.ltr,
  );

  Future<ui.Image> image(WidgetTester tester, int width, int height) async {
    final ui.Image result = (await tester.runAsync(
      () => createTestImage(width: width, height: height),
    ))!;
    addTearDown(result.dispose);
    return result;
  }

  testWidgets('只接管整行单图的段落，行内出现图片仍是普通文字', (
    WidgetTester tester,
  ) async {
    const String text =
        '![](a.png)\n前 ![](b.png) 后\n![](c.png) 尾\n尾 ![](d.png)\n![](e.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => null,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);
    final List<SourceLine> lines = scanSourceLines(text);

    expect(live.blockFor(lines[0], context(720)), isNotNull);
    expect(
      live.blockFor(lines[1], context(720)),
      isNull,
      reason: '图片前后有文字，不是整行单图',
    );
    expect(live.blockFor(lines[2], context(720)), isNull);
    expect(live.blockFor(lines[3], context(720)), isNull);
    expect(live.blockFor(lines[4], context(720)), isNotNull);
  });

  testWidgets('列表、标题、引用与代码行都不会变成图片块', (
    WidgetTester tester,
  ) async {
    const String text =
        '- ![](a.png)\n'
        '1. ![](b.png)\n'
        '# ![](c.png)\n'
        '> ![](d.png)\n'
        '```\n'
        '![](e.png)\n'
        '```';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => null,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);

    for (final SourceLine line in scanSourceLines(text)) {
      expect(
        live.blockFor(line, context(720)),
        isNull,
        reason: '「${line.text}」的 kind 不是 paragraph',
      );
    }
  });

  testWidgets('光标停在图片行上仍然显示图片，只有真的选字才退回源码', (
    WidgetTester tester,
  ) async {
    // 第一行是正文，好让图片行有一个「上一行」可用来试边界。
    const String text = '前言\n![图](a.png)\n正文';
    final SourceLine line = scanSourceLines(text)[1];
    TextSelection selection = const TextSelection.collapsed(offset: -1);
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => selection,
      imageProviderFor: (_) => null,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);

    expect(live.blockFor(line, context(720)), isNotNull);

    // 光标落在这一行的任何位置都不再摊开源码——粘贴完光标就停在行尾。
    for (final int caret in <int>[line.start, line.start + 2, line.end]) {
      selection = TextSelection.collapsed(offset: caret);
      expect(
        live.blockFor(line, context(720)),
        isNotNull,
        reason: '光标在 offset=$caret 时图片应该还在',
      );
    }

    // 真的在选这一行的字，才把标记摊开：那时要看见自己选了什么。
    selection = TextSelection(
      baseOffset: line.start + 2,
      extentOffset: line.start + 5,
    );
    expect(live.blockFor(line, context(720)), isNull);

    // 只碰到边界不算交集：从上一行一路选到这一行行首，图片不该变成源码。
    selection = TextSelection(baseOffset: 0, extentOffset: line.start);
    expect(
      live.blockFor(line, context(720)),
      isNotNull,
      reason: '选区停在行首边界上，没有选中本行的字',
    );

    selection = TextSelection.collapsed(offset: line.end + 1);
    expect(
      live.blockFor(line, context(720)),
      isNotNull,
      reason: '光标在下一行行首，图片行不该被揭示',
    );
  });

  testWidgets('自然尺寸缩进正文列', (WidgetTester tester) async {
    final ui.Image source = await image(tester, 1200, 800);
    final _TestImageProvider provider = _TestImageProvider(source);
    const String text = '![图](a.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => provider,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);
    final SourceLine line = scanSourceLines(text).single;

    final ImageLineBlock block =
        live.blockFor(line, context(720))! as ImageLineBlock;
    expect(block.width, 720);
    expect(block.height, 480);

    final ImageLineBlock narrow =
        live.blockFor(line, context(500))! as ImageLineBlock;
    expect(identical(narrow, block), isTrue, reason: '同一行复用同一块');
    expect(narrow.width, 500);
    expect(narrow.height, closeTo(333.33, 0.01));

    final ImageLineBlock wide =
        live.blockFor(line, context(1600))! as ImageLineBlock;
    expect(wide.width, 960, reason: '列再宽也受 640 高度上限约束');
    expect(wide.height, 640);
  });

  testWidgets('竖长图按 640 的软上限等比缩宽', (WidgetTester tester) async {
    final ui.Image source = await image(tester, 300, 1200);
    final _TestImageProvider provider = _TestImageProvider(source);
    const String text = '![长图](a.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => provider,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);

    final ImageLineBlock block =
        live.blockFor(scanSourceLines(text).single, context(720))!
            as ImageLineBlock;
    expect(block.height, 640);
    expect(block.width, 160);
  });

  testWidgets('显式宽度夹在 96 与列宽之间，不受高度上限约束', (
    WidgetTester tester,
  ) async {
    final ui.Image source = await image(tester, 1000, 500);
    final _TestImageProvider provider = _TestImageProvider(source);

    Future<ImageLineBlock> blockFor(String text, double width) async {
      final LiveImageBlocks live = LiveImageBlocks(
        palette: AppPalette.midnight,
        text: () => text,
        selection: () => const TextSelection.collapsed(offset: -1),
        imageProviderFor: (_) => provider,
        onLineInvalidated: (_) {},
      );
      addTearDown(live.dispose);
      return live.blockFor(
            scanSourceLines(text).single,
            context(width),
          )!
          as ImageLineBlock;
    }

    final ImageLineBlock normal = await blockFor(
      '<img src="a.png" width="320">',
      720,
    );
    expect(normal.width, 320);
    expect(normal.height, 160);

    final ImageLineBlock tiny = await blockFor(
      '<img src="a.png" width="50">',
      720,
    );
    expect(tiny.width, 96, reason: '再小也要留出能点住手柄的宽度');

    final ImageLineBlock huge = await blockFor(
      '<img src="a.png" width="2000">',
      720,
    );
    expect(huge.width, 720, reason: '宽度不能超出正文列');

    final ui.Image portrait = await image(tester, 100, 1000);
    final _TestImageProvider tallProvider = _TestImageProvider(portrait);
    const String tall = '<img src="b.png" width="300">';
    final LiveImageBlocks tallLive = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => tall,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => tallProvider,
      onLineInvalidated: (_) {},
    );
    addTearDown(tallLive.dispose);
    final ImageLineBlock tallBlock =
        tallLive.blockFor(scanSourceLines(tall).single, context(720))!
            as ImageLineBlock;
    expect(tallBlock.width, 300);
    expect(tallBlock.height, 3000, reason: '显式宽度是用户说了算，不被 640 截断');
  });

  testWidgets('拖拽预览宽度覆盖源码宽度，清除后回去', (WidgetTester tester) async {
    final ui.Image source = await image(tester, 1200, 800);
    final _TestImageProvider provider = _TestImageProvider(source);
    const String text = '![图](a.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => provider,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);
    final SourceLine line = scanSourceLines(text).single;

    live.setPreviewWidth(line.start, 480);
    expect(live.previewWidthOf(line.start), 480);
    final ImageLineBlock preview =
        live.blockFor(line, context(720))! as ImageLineBlock;
    expect(preview.width, 480);
    expect(preview.height, 320);

    live.setPreviewWidth(line.start, null);
    expect(live.previewWidthOf(line.start), isNull);
    final ImageLineBlock restored = live.blockFor(line, context(720))!
        as ImageLineBlock;
    expect(identical(restored, preview), isTrue);
    expect(restored.width, 720);
    expect(restored.height, 480);
  });

  testWidgets('画不出来时用 360×120 的占位，手柄照样存在', (
    WidgetTester tester,
  ) async {
    const String text = '![坏图](missing.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => null,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);
    final SourceLine line = scanSourceLines(text).single;

    final ImageLineBlock block =
        live.blockFor(line, context(720))! as ImageLineBlock;
    expect(block.failed, isTrue);
    expect(block.width, 360);
    expect(block.height, 120);
    expect(
      block.chromeResizeHandle(),
      isNotNull,
      reason: '宽度是源码属性，图片坏了也得能改',
    );

    final ImageLineBlock narrow =
        live.blockFor(line, context(300))! as ImageLineBlock;
    expect(narrow.width, 300);
    expect(narrow.height, 120);
  });

  testWidgets('解码完成与解码失败都只请求重排图片行', (WidgetTester tester) async {
    final ui.Image source = await image(tester, 400, 200);
    final Completer<ImageInfo> pending = Completer<ImageInfo>();
    final _TestImageProvider provider = _TestImageProvider.deferred(
      source,
      pending.future,
    );
    const String text = '![图](a.png)';
    final List<int> invalidated = <int>[];
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => provider,
      onLineInvalidated: invalidated.add,
    );
    addTearDown(live.dispose);
    final SourceLine line = scanSourceLines(text).single;

    final ImageLineBlock block =
        live.blockFor(line, context(720))! as ImageLineBlock;
    expect(block.width, 360, reason: '没解码前是占位宽度');
    expect(block.height, 120);

    pending.complete(ImageInfo(image: source.clone()));
    // 第一次 pump 只把回调送进来（并安排下一帧），重排请求在下一帧才发出。
    await tester.pump();
    await tester.pump();
    expect(block.width, 400);
    expect(block.height, 200);
    expect(invalidated, <int>[line.start]);

    const String broken = '![坏图](broken.png)';
    final List<int> failures = <int>[];
    final LiveImageBlocks failing = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => broken,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => _FailingImageProvider(),
      onLineInvalidated: failures.add,
    );
    addTearDown(failing.dispose);
    final ImageLineBlock failed = failing.blockFor(
      scanSourceLines(broken).single,
      context(720),
    )!
        as ImageLineBlock;
    // 错误经 microtask 才送达，重排请求又落下一帧的 post-frame。
    await tester.pump();
    await tester.pump();
    expect(failed.failed, isTrue);
    expect(failures, <int>[0]);
  });

  testWidgets('手柄挂在图片右下角，原点跟着行位置走', (WidgetTester tester) async {
    final ui.Image source = await image(tester, 400, 200);
    final _TestImageProvider provider = _TestImageProvider(source);
    const String text = '![图](a.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => provider,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);
    final ImageLineBlock block =
        live.blockFor(scanSourceLines(text).single, context(720))!
            as ImageLineBlock;

    expect(block.chromeImageBounds(), const Rect.fromLTWH(0, 0, 400, 200));
    block.chromeOrigin = const Offset(40, 68);
    expect(
      block.chromeImageBounds(),
      const Rect.fromLTWH(40, 68, 400, 200),
      reason: 'chrome 几何是全局坐标，原点由渲染层每帧回写',
    );
    final ImageResizeHandle handle = block.chromeResizeHandle()!;
    expect(handle.rect.size, const Size(14, 14));
    expect(handle.rect.center, const Offset(440, 268));

    block.chromeSourceRange(120, 131);
    expect(block.imageSourceStart, 120);
    expect(block.offsetAt(const Offset(10, 10)), 120);
    expect(block.offsetAt(const Offset(399, 10)), 131);
  });

  testWidgets('光标与选区几何覆盖整幅图，行外区间给空', (
    WidgetTester tester,
  ) async {
    final ui.Image source = await image(tester, 400, 200);
    final _TestImageProvider provider = _TestImageProvider(source);
    const String text = '![图](a.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => provider,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);
    final SourceLine line = scanSourceLines(text).single;
    final ImageLineBlock block =
        live.blockFor(line, context(720))! as ImageLineBlock;

    expect(block.caretRectAt(line.start), const Rect.fromLTWH(0, 0, 2, 200));
    expect(
      block.caretRectAt(line.end),
      const Rect.fromLTWH(398, 0, 2, 200),
    );
    expect(
      block.highlightRects(line.start, line.end),
      <Rect>[const Rect.fromLTWH(0, 0, 400, 200)],
    );
    expect(block.highlightRects(line.start, line.start), isEmpty);
    expect(block.highlightRects(line.end + 1, line.end + 5), isEmpty);
  });

  testWidgets('同一行复用同一块，只有换了图才换块', (WidgetTester tester) async {
    final ui.Image source = await image(tester, 400, 200);
    final _TestImageProvider provider = _TestImageProvider(source);
    final List<String> asked = <String>[];
    String text = '![图](a.png)';
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (String src) {
        asked.add(src);
        return provider;
      },
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);

    final LineBlockView? first = live.blockFor(
      scanSourceLines(text).single,
      context(720),
    );
    final LineBlockView? again = live.blockFor(
      scanSourceLines(text).single,
      context(720),
    );
    expect(identical(first, again), isTrue, reason: '文件流不该每次 build 重挂');

    // 同一张图换个写法：块留着，图片流不用重挂（重挂就会闪一下占位）。
    text = '<img src="a.png" width="200">';
    final LineBlockView? changed = live.blockFor(
      scanSourceLines(text).single,
      context(720),
    );
    expect(identical(first, changed), isTrue);
    expect((changed! as ImageLineBlock).width, 200);

    // 真的换了图：块还留着，但图片流必须重新挂一次。
    expect(asked, <String>['a.png'], reason: '换写法不该重新解析图片');
    text = '![图](b.png)';
    final LineBlockView? other = live.blockFor(
      scanSourceLines(text).single,
      context(720),
    );
    expect((other! as ImageLineBlock).markup.source, 'b.png');
    expect(asked.last, 'b.png');
  });

  testWidgets('要改源码时只是浮出一块窗，行高与图片都不动', (WidgetTester tester) async {
    final ui.Image source = await image(tester, 400, 200);
    final _TestImageProvider provider = _TestImageProvider(source);
    const String text = '![图](a.png)';
    int? editing;
    final LiveImageBlocks live = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      editingLine: () => editing,
      sourceFontSize: 15.5,
      imageProviderFor: (_) => provider,
      onLineInvalidated: (_) {},
    );
    addTearDown(live.dispose);

    final ImageLineBlock block =
        live.blockFor(scanSourceLines(text).single, context(720))!
            as ImageLineBlock;
    expect(block.height, closeTo(200, 1));
    expect(block.chromeSourceBounds(), Rect.zero, reason: '不编辑时没有浮窗');

    editing = 0;
    live.blockFor(scanSourceLines(text).single, context(720));
    final Rect band = block.chromeSourceBounds();
    expect(band.isEmpty, isFalse, reason: '编辑时浮出一块源码窗');
    expect(band.height, greaterThan(15));
    // 浮窗压在图上，不是挤进版面：行高、图片位置、图片大小一个都不变。
    expect(block.height, closeTo(200, 0.01), reason: '行高不动');
    expect(
      block.chromeImageBounds().top,
      0,
      reason: '图片不再被源码行顶下去',
    );
    expect(block.chromeImageBounds().height, closeTo(200, 0.01));
    expect(band.top, greaterThanOrEqualTo(0));
    expect(band.bottom, lessThanOrEqualTo(block.chromeImageBounds().bottom));

    editing = null;
    live.blockFor(scanSourceLines(text).single, context(720));
    expect(block.height, closeTo(200, 0.01));
    expect(block.chromeSourceBounds(), Rect.zero);
  });
}
