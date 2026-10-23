@Tags(<String>['perf'])
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/live_line_style.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// 持久实例下的生产路径基准（方案 §4 的手册夹具 + §5.5 的 P1 退出条件）。
///
/// 与 `live_markdown_perf_test.dart` 的区别：那里每轮 build 都新建
/// `LiveLineStyle` / `LiveTableBlocks`，测的是冷路径；这里像 `markdown_editor`
/// 一样让 `LiveTableBlocks` 与 `LineLayoutCache` 跨 build 存活，`LiveLineStyle`
/// 只在源码变化时重建，测的才是编辑时的真实开销。
///
/// 单独跑：`flutter test --tags perf test/live_markdown_reuse_perf_test.dart`。
const AppPalette palette = AppPalette.light;
const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
const int fixtureLines = 1867;

/// 手册规模的混合文档：1,867 行，其中 20 张表（每张 16 行，共 320 行）。
///
/// [withTables] 为 false 时把同样 320 行换成行数相同的普通段落，作为
/// 「表外编辑耗时 ≈ 无表基线」的对照组。
String manualLike({required bool withTables}) {
  final List<String> out = <String>[
    '# 手册',
    '',
    '这里是 **粗体**、*斜体*、~~删除~~、`行内代码`、[[双链]] 和 #标签 的混合正文。',
    '',
  ];
  for (int t = 1; t <= 20; t++) {
    out.add('## 第 $t 节');
    out.add('');
    if (withTables) {
      out.add('| 功能 | 说明 | 状态 |');
      out.add('| --- | --- | --- |');
      for (int r = 1; r <= 14; r++) {
        out.add('| f$t-$r | 第 $t 节第 $r 行说明 | 完成 |');
      }
    } else {
      for (int r = 1; r <= 16; r++) {
        out.add('第 $t 节第 $r 行：这是替换表格的正文，字数与表格行相近的普通段落。');
      }
    }
    out.add('');
  }
  int i = 0;
  while (out.length < fixtureLines) {
    out.addAll(<String>[
      '## 附录 $i',
      '',
      '正文 **粗体** *斜体* ~~删除~~ `代码` [[双链]] #标签 $i',
      '',
      '- 项目一',
      '  - 子项目',
      '- [ ] 待办 $i',
      '',
      '> 引用 $i',
      '',
      '```dart',
      'void main() { print($i); }',
      '```',
      '',
    ]);
    i++;
  }
  return out.take(fixtureLines).join('\n');
}

/// 生产路径的持久实例夹具。
///
/// - `LiveTableBlocks` 构造一次，跨 build 存活（对应 `_resolveTableBlocks`
///   的按样式缓存）；
/// - `LiveLineStyle` 按 `source` 缓存，源码不变就不重建（对应
///   `_resolveLineStyle`），`reveal` 是稳定的方法 tear-off；
/// - `LineLayoutCache` 与 `LineLayoutStats` 跨 build 存活（对应渲染对象的
///   `_lineCache`）。
class Harness {
  Harness({required this.withTables}) {
    text = manualLike(withTables: withTables);
    blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => selection,
    );
  }

  final bool withTables;
  late String text;
  TextSelection? selection = const TextSelection.collapsed(offset: -1);
  final LineLayoutCache cache = LineLayoutCache();
  final LineLayoutStats stats = LineLayoutStats();
  late final LiveTableBlocks blocks;

  LiveLineStyle? _style;
  String? _styleText;

  TextSelection? _reveal() => selection;

  LiveLineStyle get style {
    if (_style == null || _styleText != text) {
      _style = LiveLineStyle(
        base: base,
        palette: palette,
        reveal: _reveal,
        source: text,
      );
      _styleText = text;
    }
    return _style!;
  }

  LineDocumentLayout layout({Set<int> foldedLines = const <int>{}}) {
    final LiveLineStyle s = style;
    return layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: 680,
      styleFor: s.styleFor,
      heightFor: s.heightFor,
      spanFor: s.spanFor,
      fillFor: s.fillsFor,
      insetFor: s.insetFor,
      blockFor: blocks.blockFor,
      foldedLines: foldedLines,
      cache: cache,
      stats: stats,
    );
  }

  void dispose() {
    cache.dispose();
    blocks.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<int> proseOffsets(String source) {
    final List<int> out = <int>[];
    for (final SourceLine line in scanSourceLines(source)) {
      if (line.kind == LineBlockKind.table ||
          line.kind == LineBlockKind.tableHeader ||
          line.kind == LineBlockKind.tableDivider) {
        continue;
      }
      out.add((line.start + line.end) ~/ 2);
    }
    return out;
  }

  /// 第 [table]（0 起）张表第一行第一个格子里面的偏移（`| ` 之后一格）。
  int tableCellOffset(String source, {int table = 0}) {
    final List<SourceLine> lines = scanSourceLines(source);
    int seen = 0;
    for (final SourceLine line in lines) {
      if (line.kind != LineBlockKind.table) continue;
      if (seen < table * 14) {
        seen++;
        continue;
      }
      return line.start + 3;
    }
    fail('没有找到第 $table 张表的正文行');
  }

  test('持久实例：冷开（1,867 行，20 张表）', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    final Stopwatch watch = Stopwatch()..start();
    final LineDocumentLayout layout = h.layout();
    watch.stop();
    final double ms = watch.elapsedMicroseconds / 1000;
    // ignore: avoid_print
    print(
      'perf(持久实例): 冷开 = ${ms.toStringAsFixed(2)} ms '
      '(measured=${h.stats.paintersMeasured}, '
      'hits=${h.stats.cacheHits}, '
      'blockResolves=${h.stats.blockResolves})',
    );
    expect(layout.laidOut, hasLength(fixtureLines));
    expect(h.blocks.debugTableMeasures, 20);
    expect(h.stats.blockResolves, fixtureLines);
    expect(h.stats.cacheHits, 0);
    layout.dispose();
    expect(ms, lessThan(1500));
  });

  test('持久实例：光标在正文移动，表格零重测', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    h.layout().dispose();
    expect(h.blocks.debugTableMeasures, 20);

    final List<int> offsets = proseOffsets(h.text);
    final int step = offsets.length ~/ 10;
    final Stopwatch watch = Stopwatch()..start();
    for (int i = 0; i < 10; i++) {
      h.selection = TextSelection.collapsed(offset: offsets[i * step]);
      h.layout().dispose();
    }
    watch.stop();
    final double ms = watch.elapsedMicroseconds / 10 / 1000;
    // ignore: avoid_print
    print(
      'perf(持久实例): 正文光标移动 = ${ms.toStringAsFixed(2)} ms/次 '
      '(measured=${h.stats.paintersMeasured}, '
      'hits=${h.stats.cacheHits}, '
      'blockResolves=${h.stats.blockResolves})',
    );
    expect(h.blocks.debugTableMeasures, 20);
    expect(ms, lessThan(1000));
  });

  test('持久实例：表外打字 ≈ 无表基线', () {
    final Harness t = Harness(withTables: true);
    final Harness n = Harness(withTables: false);
    addTearDown(t.dispose);
    addTearDown(n.dispose);
    t.layout().dispose();
    n.layout().dispose();

    // 两版夹具的引言完全相同；在引言的同一个位置逐轮多打一个字符。
    const int pos = 12;
    final Stopwatch watchT = Stopwatch()..start();
    for (int i = 1; i <= 6; i++) {
      t.text = t.text.replaceRange(pos, pos, 'x' * i);
      t.layout().dispose();
    }
    watchT.stop();
    final Stopwatch watchN = Stopwatch()..start();
    for (int i = 1; i <= 6; i++) {
      n.text = n.text.replaceRange(pos, pos, 'x' * i);
      n.layout().dispose();
    }
    watchN.stop();
    final double msT = watchT.elapsedMicroseconds / 6 / 1000;
    final double msN = watchN.elapsedMicroseconds / 6 / 1000;
    // ignore: avoid_print
    print(
      'perf(持久实例): 表外打字 = ${msT.toStringAsFixed(2)} ms/次 '
      'vs 无表基线 ${msN.toStringAsFixed(2)} ms/次 '
      '(ratio=${(msT / msN).toStringAsFixed(2)}, '
      'measures=${t.blocks.debugTableMeasures})',
    );
    expect(t.blocks.debugTableMeasures, 20);
    expect(msT / msN, lessThan(1.35));
  });

  test('持久实例：表内改一格，每次只重测所在表', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    h.layout().dispose();
    expect(h.blocks.debugTableMeasures, 20);

    final int cell = tableCellOffset(h.text);
    h.selection = TextSelection.collapsed(offset: cell);
    for (int i = 1; i <= 3; i++) {
      h.text = h.text.replaceRange(cell, cell, 'x' * i);
      h.layout().dispose();
    }
    expect(h.blocks.debugTableMeasures, 23);
  });

  test('持久实例：光标进出表格的重测次数', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    h.layout().dispose();
    expect(h.blocks.debugTableMeasures, 20);

    h.selection = TextSelection.collapsed(
      offset: tableCellOffset(h.text),
    );
    h.layout().dispose();
    expect(h.blocks.debugTableMeasures, 21);

    h.selection = TextSelection.collapsed(
      offset: tableCellOffset(h.text) + 1,
    );
    h.layout().dispose();
    expect(h.blocks.debugTableMeasures, 21);

    // 跳到第二张表：离开第一张表（编辑格状态复位）+ 进入第二张表，共两张重测。
    h.selection = TextSelection.collapsed(
      offset: tableCellOffset(h.text, table: 1),
    );
    h.layout().dispose();
    expect(h.blocks.debugTableMeasures, 23);

    // 回到正文：离开第二张表，只有它重测。
    h.selection = TextSelection.collapsed(offset: proseOffsets(h.text).first);
    h.layout().dispose();
    expect(h.blocks.debugTableMeasures, 24);
  });

  test('持久实例：P2 光标移动只重排脏行', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    LineDocumentLayout layout = h.layout();
    expect(h.blocks.debugTableMeasures, 20);

    final List<int> offsets = proseOffsets(h.text);
    final int step = offsets.length ~/ 10;
    h.stats.reset();
    int maxDirty = 0;
    final Stopwatch watch = Stopwatch()..start();
    for (int i = 0; i < 10; i++) {
      final TextSelection? before = h.selection;
      final TextSelection after = TextSelection.collapsed(
        offset: offsets[i * step],
      );
      final Set<int> dirty = layout.revealDirtyLines(before, after);
      maxDirty = math.max(maxDirty, dirty.length);
      h.selection = after;
      final LineDocumentLayout next = relayoutLines(
        previous: layout,
        dirtyLines: dirty,
        text: h.text,
        baseStyle: base,
        contentWidth: 680,
        styleFor: h.style.styleFor,
        heightFor: h.style.heightFor,
        spanFor: h.style.spanFor,
        fillFor: h.style.fillsFor,
        insetFor: h.style.insetFor,
        blockFor: h.blocks.blockFor,
        stats: h.stats,
      );
      layout.handOverOwnership();
      layout = next;
    }
    watch.stop();
    final double ms = watch.elapsedMicroseconds / 10 / 1000;
    // ignore: avoid_print
    print(
      'perf(持久实例): P2 光标移动 = ${ms.toStringAsFixed(2)} ms/次 '
      '(rebuilt=${h.stats.rebuiltLines}, reused=${h.stats.reusedLines}, '
      'maxDirty=$maxDirty, blockResolves=${h.stats.blockResolves})',
    );
    expect(maxDirty, lessThanOrEqualTo(2));
    expect(h.stats.rebuiltLines, lessThanOrEqualTo(20));
    expect(h.stats.reusedLines, greaterThanOrEqualTo(fixtureLines * 9));
    // 纯正文移动不碰表格测量。
    expect(h.blocks.debugTableMeasures, 20);
    expect(layout.laidOut, hasLength(fixtureLines));
    expect(ms, lessThan(250));
    layout.dispose();
  });

  test('持久实例：折叠 100 个子树', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    h.layout().dispose();

    final List<SourceLine> sources = scanSourceLines(h.text);
    final List<int> parents = <int>[
      for (final ListFold fold in scanListFolds(sources)) fold.parentIndex,
    ].take(100).toList();
    expect(parents, isNotEmpty);

    final Set<int> folded = <int>{
      for (final int p in parents) sources[p].start,
    };
    final LineDocumentLayout unfolded = h.layout();
    final Stopwatch watch = Stopwatch()..start();
    final LineDocumentLayout foldedLayout = h.layout(foldedLines: folded);
    watch.stop();
    final double ms = watch.elapsedMicroseconds / 1000;
    // ignore: avoid_print
    print(
      'perf(持久实例): 折叠 100 子树 = ${ms.toStringAsFixed(2)} ms/次',
    );
    expect(foldedLayout.height, lessThan(unfolded.height));
    unfolded.dispose();
    foldedLayout.dispose();
    expect(ms, lessThan(1500));
  });

  test('持久实例：第 900 行 Enter 后撤销', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    final LineDocumentLayout layout = h.layout();
    expect(h.blocks.debugTableMeasures, 20);
    final double originalHeight = layout.height;

    // 找第 900 行附近的一条非空普通段落行：表格/围栏/列表会把 dirty 扩到
    // 整块，测出来的就不是「一行回车」的真实成本了。
    final List<SourceLine> sources = scanSourceLines(h.text);
    int index = 899;
    while (index < sources.length &&
        (sources[index].kind != LineBlockKind.paragraph ||
            sources[index].text.isEmpty)) {
      index++;
    }
    expect(index, lessThan(sources.length));
    final int at = sources[index].end;

    final String before = h.text;
    h.text = '${before.substring(0, at)}\n${before.substring(at)}';
    h.selection = const TextSelection.collapsed(offset: -1);
    h.stats.reset();
    final Stopwatch enterWatch = Stopwatch()..start();
    final LineDocumentLayout? entered = relayoutOnEdit(
      previous: layout,
      text: h.text,
      editStart: at,
      removedLength: 0,
      insertedLength: 1,
      baseStyle: base,
      contentWidth: 680,
      styleFor: h.style.styleFor,
      heightFor: h.style.heightFor,
      spanFor: h.style.spanFor,
      fillFor: h.style.fillsFor,
      insetFor: h.style.insetFor,
      blockFor: h.blocks.blockFor,
      revealBefore: TextSelection.collapsed(offset: at),
      revealAfter: TextSelection.collapsed(offset: at + 1),
      stats: h.stats,
    );
    enterWatch.stop();
    expect(entered, isNotNull);
    final int enterRebuilt = h.stats.rebuiltLines;
    final int enterReused = h.stats.reusedLines;
    expect(entered!.laidOut, hasLength(fixtureLines + 1));
    // 只重排被拆开的那一行（拆成两行）；尾部整段换壳复用。
    expect(enterRebuilt, lessThanOrEqualTo(4));
    expect(enterReused, greaterThanOrEqualTo(fixtureLines - 3));
    // 正文插行不牵动表格测量。
    expect(h.blocks.debugTableMeasures, 20);

    // 撤销：删掉刚插入的换行，回到原文。
    h.text = before;
    h.selection = TextSelection.collapsed(offset: at);
    h.stats.reset();
    final Stopwatch undoWatch = Stopwatch()..start();
    final LineDocumentLayout? undone = relayoutOnEdit(
      previous: entered,
      text: h.text,
      editStart: at,
      removedLength: 1,
      insertedLength: 0,
      baseStyle: base,
      contentWidth: 680,
      styleFor: h.style.styleFor,
      heightFor: h.style.heightFor,
      spanFor: h.style.spanFor,
      fillFor: h.style.fillsFor,
      insetFor: h.style.insetFor,
      blockFor: h.blocks.blockFor,
      revealBefore: TextSelection.collapsed(offset: at + 1),
      revealAfter: TextSelection.collapsed(offset: at),
      stats: h.stats,
    );
    undoWatch.stop();
    expect(undone, isNotNull);
    final int undoRebuilt = h.stats.rebuiltLines;
    final int undoReused = h.stats.reusedLines;
    expect(undone!.laidOut, hasLength(fixtureLines));
    expect(undone.height, closeTo(originalHeight, 0.01));
    expect(undoRebuilt, lessThanOrEqualTo(4));
    expect(undoReused, greaterThanOrEqualTo(fixtureLines - 3));
    expect(h.blocks.debugTableMeasures, 20);

    final double enterMs = enterWatch.elapsedMicroseconds / 1000;
    final double undoMs = undoWatch.elapsedMicroseconds / 1000;
    // ignore: avoid_print
    print(
      'perf(持久实例): 第 900 行 Enter = ${enterMs.toStringAsFixed(2)} ms '
      '(rebuilt=$enterRebuilt, reused=$enterReused)；'
      '撤销 = ${undoMs.toStringAsFixed(2)} ms '
      '(rebuilt=$undoRebuilt, reused=$undoReused)',
    );
    expect(enterMs, lessThan(250));
    expect(undoMs, lessThan(250));
    entered.dispose();
    undone.dispose();
  });

  test('持久实例：拖选 200 行', () {
    final Harness h = Harness(withTables: true);
    addTearDown(h.dispose);
    LineDocumentLayout layout = h.layout();
    expect(h.blocks.debugTableMeasures, 20);

    // 附录段全是正文/列表/围栏，没有表格——这样 dirty 行数就是选区覆盖的行数。
    final List<SourceLine> sources = scanSourceLines(h.text);
    const int from = 400;
    const int count = 200;
    expect(sources, hasLength(fixtureLines));
    final TextSelection after = TextSelection(
      baseOffset: sources[from].start,
      extentOffset: sources[from + count - 1].end,
    );
    final Set<int> dirty = layout.revealDirtyLines(h.selection, after);
    expect(dirty, hasLength(count));
    h.selection = after;

    h.stats.reset();
    final Stopwatch watch = Stopwatch()..start();
    final LineDocumentLayout next = relayoutLines(
      previous: layout,
      dirtyLines: dirty,
      text: h.text,
      baseStyle: base,
      contentWidth: 680,
      styleFor: h.style.styleFor,
      heightFor: h.style.heightFor,
      spanFor: h.style.spanFor,
      fillFor: h.style.fillsFor,
      insetFor: h.style.insetFor,
      blockFor: h.blocks.blockFor,
      stats: h.stats,
    );
    watch.stop();
    final double ms = watch.elapsedMicroseconds / 1000;
    // ignore: avoid_print
    print(
      'perf(持久实例): 拖选 200 行 = ${ms.toStringAsFixed(2)} ms '
      '(rebuilt=${h.stats.rebuiltLines}, reused=${h.stats.reusedLines}, '
      'blockResolves=${h.stats.blockResolves})',
    );
    expect(next.laidOut, hasLength(fixtureLines));
    expect(h.stats.rebuiltLines, count);
    expect(h.stats.reusedLines, fixtureLines - count);
    // 选区变化不碰表格测量。
    expect(h.blocks.debugTableMeasures, 20);
    expect(ms, lessThan(250));
    layout.handOverOwnership();
    layout = next;
    layout.dispose();
  });
}
