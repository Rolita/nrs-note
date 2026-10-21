@Tags(<String>['perf'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// Benchmarks for the live renderer. Tagged so CI can leave them out: a shared
/// runner's timings are noise, while a local run gives the number to compare
/// against after a change.
///
/// Run with `flutter test --tags perf test/live_markdown_perf_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const AppPalette palette = AppPalette.light;
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

  double averageMs(String text, {int warmup = 5, int runs = 20}) {
    for (int i = 0; i < warmup; i++) {
      buildLiveSpans(
        text: text,
        base: base,
        p: palette,
        selection: const TextSelection.collapsed(offset: -1),
        contentWidth: 680,
      );
    }
    final Stopwatch watch = Stopwatch()..start();
    for (int i = 0; i < runs; i++) {
      buildLiveSpans(
        text: text,
        base: base,
        p: palette,
        selection: const TextSelection.collapsed(offset: -1),
        contentWidth: 680,
      );
    }
    watch.stop();
    return watch.elapsedMicroseconds / runs / 1000;
  }

  test('100 × 10 table', () {
    final String text = tableDocument(100, 10);
    final List<TableGeometry> tables = measureTables(
      text: text,
      base: base,
      p: palette,
      contentWidth: 680,
    );
    expect(tables.length, 1);
    expect(tables.single.rows.length, 101);

    final double ms = averageMs(text);
    // ignore: avoid_print
    print('perf: 100×10 table = ${ms.toStringAsFixed(2)} ms/build');
    // A loose ceiling: it exists to catch an order-of-magnitude regression, not
    // to police a few milliseconds on a loaded machine.
    expect(ms, lessThan(100));
  });

  test('5000-line mixed document', () {
    final String text = mixedDocument(5000);
    final double ms = averageMs(text, runs: 10);
    // ignore: avoid_print
    print('perf: 5000-line mixed document = ${ms.toStringAsFixed(2)} ms/build');
    expect(ms, lessThan(200));
  });
}
