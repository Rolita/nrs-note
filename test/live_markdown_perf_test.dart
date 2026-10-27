@Tags(<String>['perf'])
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/live_line_style.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// 一次性交付的假图片源：模拟命中引擎 `ImageCache` 的第二次解码——同一张图
/// 再挂监听器时 `ImageInfo` 同步到货。生产里打字落在图片上方会触发全量布局
/// （行首偏移平移、每张图重建块、重新解析引用），这就是那条路径的成本。
class _CachedTestImageProvider extends ImageProvider<_CachedTestImageProvider> {
  _CachedTestImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_CachedTestImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_CachedTestImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _CachedTestImageProvider key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())),
  );
}

/// Benchmarks for the live renderer. Tagged so CI can leave them out: a shared
/// runner's timings are noise, while a local run gives the number to compare
/// against after a change.
///
/// Run with `flutter test --tags perf test/live_markdown_perf_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const AppPalette palette = AppPalette.midnight;
  const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);

  String tableDocument(int bodyRows, int columns) {
    final List<String> lines = <String>[
      '| ${<String>[for (int c = 0; c < columns; c++) 'h$c'].join(' | ')} |',
      '| ${<String>[for (int c = 0; c < columns; c++) '---'].join(' | ')} |',
    ];
    for (int r = 0; r < bodyRows; r++) {
      lines.add(
        '| ${<String>[for (int c = 0; c < columns; c++) '$r-$c'].join(' | ')} |',
      );
    }
    return lines.join('\n');
  }

  String mixedDocument(int lines) {
    final List<String> out = <String>[];
    for (int i = 0; out.length < lines; i++) {
      out.add('## 第 $i 节');
      out.add('');
      out.add('正文 **粗体** *斜体* ~~删除~~ `代码` [[双链]] #标签 $i');
      out.add('');
      out.add('- 项目一');
      out.add('  - 子项目');
      out.add('- [ ] 待办');
      out.add('');
      out.add('> 引用 $i');
      out.add('');
      out.add('```dart');
      out.add('void main() { print($i); }');
      out.add('```');
      out.add('');
    }
    return out.take(lines).join('\n');
  }

  // ---------------------------------------------------------------- production
  //
  // 生产路径是 `layoutLines` + `LiveLineStyle` + `LiveTableBlocks`，下面这些
  // 基准都按同一份文档给它建立，避免优化时拿一条已经不跑的实现当参照。

  /// 跑一次生产路径的排版，返回耗时（含表格测量）。
  LineDocumentLayout layoutProduction(String text, {LineLayoutCache? cache}) {
    const TextSelection selection = TextSelection.collapsed(offset: -1);
    final LiveLineStyle style = LiveLineStyle(
      base: base,
      palette: palette,
      reveal: () => selection,
      source: text,
    );
    final LiveTableBlocks blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => selection,
    );
    final LineDocumentLayout layout = layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: 680,
      styleFor: style.styleFor,
      heightFor: style.heightFor,
      spanFor: style.spanFor,
      fillFor: style.fillsFor,
      insetFor: style.insetFor,
      blockFor: blocks.blockFor,
      cache: cache,
    );
    // `render_line_editable` 只释放行布局，表格块由宿主释放。
    blocks.dispose();
    return layout;
  }

  double averageProductionMs(String text, {int warmup = 3, int runs = 10}) {
    for (int i = 0; i < warmup; i++) {
      layoutProduction(text).dispose();
    }
    final Stopwatch watch = Stopwatch()..start();
    for (int i = 0; i < runs; i++) {
      layoutProduction(text).dispose();
    }
    watch.stop();
    return watch.elapsedMicroseconds / runs / 1000;
  }

  test('production: 100 × 10 table', () {
    final String text = tableDocument(100, 10);
    final LineDocumentLayout layout = layoutProduction(text);
    expect(layout.laidOut, hasLength(102));
    expect(layout.laidOut.first.block, isNotNull);
    expect(layout.height, greaterThan(0));
    layout.dispose();

    final double ms = averageProductionMs(text);
    // ignore: avoid_print
    print(
      'perf(production): 100×10 table = ${ms.toStringAsFixed(2)} ms/build',
    );
    expect(ms, lessThan(300));
  });

  test('production: 5000-line mixed document', () {
    final String text = mixedDocument(5000);
    final LineDocumentLayout layout = layoutProduction(text);
    expect(layout.laidOut.length, greaterThan(4000));
    expect(layout.height, greaterThan(0));
    layout.dispose();

    final double ms = averageProductionMs(text);
    // ignore: avoid_print
    print(
      'perf(production): 5000-line mixed document = '
      '${ms.toStringAsFixed(2)} ms/build',
    );
    expect(ms, lessThan(1000));
  });

  test('production: 3000-line ordered list', () {
    final String text = List<String>.generate(
      3000,
      (int i) => '${i + 1}. 列表项 $i',
    ).join('\n');
    final LineDocumentLayout layout = layoutProduction(text);
    expect(layout.laidOut, hasLength(3000));
    expect(layout.laidOut.last.slot.width, greaterThan(0));
    layout.dispose();

    final double ms = averageProductionMs(text);
    // ignore: avoid_print
    print(
      'perf(production): 3000-line ordered list = '
      '${ms.toStringAsFixed(2)} ms/build',
    );
    expect(ms, lessThan(1000));
  });

  test('production: one-character edits in a 5000-line document', () {
    final String baseText = mixedDocument(5000);
    final int middle = baseText.length ~/ 2;
    final List<String> documents = <String>[
      for (int i = 0; i < 6; i++) baseText.replaceRange(middle, middle, 'x' * i),
    ];
    final LineLayoutCache cache = LineLayoutCache();
    addTearDown(cache.dispose);

    // 第一次全量建立池；后面五轮每轮只多一个字符。
    layoutProduction(documents.first, cache: cache).dispose();
    final Stopwatch watch = Stopwatch()..start();
    for (int i = 1; i < documents.length; i++) {
      layoutProduction(documents[i], cache: cache).dispose();
    }
    watch.stop();
    final double ms =
        watch.elapsedMicroseconds / (documents.length - 1) / 1000;
    // ignore: avoid_print
    print(
      'perf(production): one-character edit in 5000 lines = '
      '${ms.toStringAsFixed(2)} ms/build',
    );
    expect(ms, lessThan(1000));
  });

  test('production: edit outside a 2000-line code block', () {
    final String code = List<String>.generate(
      2000,
      (int i) => 'final value$i = $i;',
    ).join('\n');
    final List<String> documents = List<String>.generate(
      6,
      (int i) => '前言 $i\n\n```dart\n$code\n```\n\n尾部',
    );
    // 代码块内容完全不变，只有块外的一个字符不同；跨实例缓存应当命中。
    layoutProduction(documents.first).dispose();
    layoutProduction(documents[1]).dispose();
    final Stopwatch watch = Stopwatch()..start();
    for (final String text in documents) {
      layoutProduction(text).dispose();
    }
    watch.stop();
    final double ms = watch.elapsedMicroseconds / documents.length / 1000;
    // ignore: avoid_print
    print(
      'perf(production): edit outside 2000-line code block = '
      '${ms.toStringAsFixed(2)} ms/build',
    );
    expect(ms, lessThan(1000));
  });

  test('production: one-character edits in a 1000-line document with 20 images',
      () async {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    final ui.Image image = (await binding.runAsync(
      () => createTestImage(width: 320, height: 240),
    ))!;
    addTearDown(image.dispose);

    // 每 50 行一张图，共 20 张；打字落在文档中部，其后的图片行行首偏移
    // 全部平移，每轮都要重新解析引用、重建图片块——这是最贵的打字路径。
    final List<String> lines = <String>[
      for (int i = 0; i < 1000; i++)
        i % 50 == 25
            ? '![截图 ${i ~/ 50}](assets/fig_${i ~/ 50}.png)'
            : '正文第 $i 行：**粗体** *斜体* `代码` [[双链]] #标签',
    ];
    final String baseText = lines.join('\n');
    final int middle = baseText.length ~/ 2;
    final List<String> documents = <String>[
      for (int i = 0; i < 6; i++) baseText.replaceRange(middle, middle, 'x' * i),
    ];

    const TextSelection selection = TextSelection.collapsed(offset: -1);
    final LiveImageBlocks images = LiveImageBlocks(
      palette: palette,
      text: () => '',
      selection: () => selection,
      imageProviderFor: (_) => _CachedTestImageProvider(image),
      onLineInvalidated: (_) {},
    );
    addTearDown(images.dispose);
    final LineLayoutCache cache = LineLayoutCache();
    addTearDown(cache.dispose);

    // 生产路径同一份解析器贯穿多次编辑（图片块按行首偏移缓存）。
    LineDocumentLayout layoutWithImages(String text) {
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        reveal: () => selection,
        source: text,
      );
      return layoutLines(
        text: text,
        baseStyle: base,
        contentWidth: 680,
        styleFor: style.styleFor,
        heightFor: style.heightFor,
        spanFor: style.spanFor,
        fillFor: style.fillsFor,
        insetFor: style.insetFor,
        blockFor: images.blockFor,
        cache: cache,
      );
    }

    // 第一次全量建立；后面五轮每轮只多一个字符。
    final LineDocumentLayout first = layoutWithImages(documents.first);
    expect(first.laidOut, hasLength(1000));
    expect(
      first.laidOut.where((LaidOutLine l) => l.block != null).length,
      20,
      reason: '20 个图片行都该解析成图片块',
    );
    first.dispose();
    final Stopwatch watch = Stopwatch()..start();
    for (int i = 1; i < documents.length; i++) {
      layoutWithImages(documents[i]).dispose();
    }
    watch.stop();
    final double ms =
        watch.elapsedMicroseconds / (documents.length - 1) / 1000;
    // ignore: avoid_print
    print(
      'perf(production): one-character edit in 1000 lines + 20 images = '
      '${ms.toStringAsFixed(2)} ms/build',
    );
    expect(ms, lessThan(1000));
  });
}
