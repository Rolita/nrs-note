import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/live_line_style.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// P4：编辑的行级增量布局。
///
/// 每个用例都拿「同一份新文本跑一次全量 `layoutLines`」做对照：增量结果必须
/// 与全量逐行逐字段一致。性能断言只看重建行数——单字符编辑不该碰到整篇。
const AppPalette palette = AppPalette.light;
const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
const double width = 680;

/// 新旧文本之间唯一的替换区间，与渲染层的 `_editBetween` 同构。
({int start, int removed, int inserted}) diffOf(String before, String after) {
  final int max = math.min(before.length, after.length);
  int prefix = 0;
  while (prefix < max &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  int suffix = 0;
  final int limit = max - prefix;
  while (suffix < limit &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  return (
    start: prefix,
    removed: before.length - prefix - suffix,
    inserted: after.length - prefix - suffix,
  );
}

/// 生产路径的持久夹具：一次编辑 = 上一份布局 + 新的解析器实例（同语义键）。
class Session {
  Session(this.text, {this.selection, this.folded = const <int>{}}) {
    _resolve();
    layout = _full();
  }

  String text;
  TextSelection? selection;
  Set<int> folded;

  late LiveLineStyle style;
  late LiveTableBlocks blocks;
  late LineDocumentLayout layout;
  final List<LiveTableBlocks> _retired = <LiveTableBlocks>[];

  /// 稳定的方法引用：`LiveLineStyle.styleKey` 里有它，每次新建实例仍相等。
  TextSelection? reveal() => selection;

  void _resolve() {
    style = LiveLineStyle(
      base: base,
      palette: palette,
      reveal: reveal,
      source: text,
    );
    final LiveTableBlocks? old = _blocks;
    if (old != null) _retired.add(old);
    blocks = _blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: reveal,
    );
  }

  LiveTableBlocks? _blocks;

  LineDocumentLayout _full() => layoutLines(
    text: text,
    baseStyle: base,
    contentWidth: width,
    styleFor: style.styleFor,
    heightFor: style.heightFor,
    spanFor: style.spanFor,
    fillFor: style.fillsFor,
    insetFor: style.insetFor,
    blockFor: blocks.blockFor,
    foldedLines: folded,
  );

  /// 把正文改成 [next] 并走编辑增量；返回本轮统计。
  ///
  /// 增量返回 `null` 时按生产路径退回全量，返回值的 `ok` 为 false。
  ({bool ok, LineLayoutStats stats}) edit(
    String next, {
    TextSelection? revealAfter,
  }) {
    final String before = text;
    final TextSelection? revealBefore = selection;
    text = next;
    if (revealAfter != null) selection = revealAfter;
    _resolve();
    final ({int start, int removed, int inserted}) diff = diffOf(before, next);
    final LineLayoutStats stats = LineLayoutStats();
    final LineDocumentLayout? result = relayoutOnEdit(
      previous: layout,
      text: next,
      editStart: diff.start,
      removedLength: diff.removed,
      insertedLength: diff.inserted,
      baseStyle: base,
      contentWidth: width,
      styleFor: style.styleFor,
      heightFor: style.heightFor,
      spanFor: style.spanFor,
      fillFor: style.fillsFor,
      insetFor: style.insetFor,
      blockFor: blocks.blockFor,
      foldedLines: folded,
      revealBefore: revealBefore,
      revealAfter: selection,
      stats: stats,
    );
    if (result == null) {
      layout.dispose();
      layout = _full();
      return (ok: false, stats: stats);
    }
    layout = result;
    return (ok: true, stats: stats);
  }

  void dispose() {
    layout.dispose();
    blocks.dispose();
    for (final LiveTableBlocks b in _retired) {
      b.dispose();
    }
  }
}

/// 参照组：用同一份文本与选区完整跑一次 `layoutLines`。
class Reference {
  Reference(String text, TextSelection? selection, {Set<int> folded = const <int>{}}) {
    style = LiveLineStyle(
      base: base,
      palette: palette,
      reveal: () => selection,
      source: text,
    );
    blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => selection,
    );
    layout = layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: width,
      styleFor: style.styleFor,
      heightFor: style.heightFor,
      spanFor: style.spanFor,
      fillFor: style.fillsFor,
      insetFor: style.insetFor,
      blockFor: blocks.blockFor,
      foldedLines: folded,
    );
  }

  late final LiveLineStyle style;
  late final LiveTableBlocks blocks;
  late final LineDocumentLayout layout;

  void dispose() {
    layout.dispose();
    blocks.dispose();
  }
}

/// 逐行比较两份布局的全部几何出口。
void expectSameLayout(LineDocumentLayout actual, LineDocumentLayout expected) {
  expect(actual.laidOut.length, expected.laidOut.length, reason: '行数不一致');
  for (int i = 0; i < actual.laidOut.length; i++) {
    final LaidOutLine a = actual.laidOut[i];
    final LaidOutLine b = expected.laidOut[i];
    final String at = '第 $i 行（${a.source.kind.name}）';
    expect(a.source.start, b.source.start, reason: '$at 起偏移');
    expect(a.source.end, b.source.end, reason: '$at 止偏移');
    expect(a.top, b.top, reason: '$at top');
    expect(a.height, b.height, reason: '$at 高度');
    expect(a.hidden, b.hidden, reason: '$at 隐藏位');
    expect(a.folded, b.folded, reason: '$at 折叠位');
    expect(a.paintedFrom, b.paintedFrom, reason: '$at 排版起点');
    expect(a.insets, b.insets, reason: '$at 内边距');
    expect(a.slot.level, b.slot.level, reason: '$at 槽位层级');
    expect(a.slot.indent, b.slot.indent, reason: '$at 槽位缩进');
    expect(a.slot.marker, b.slot.marker, reason: '$at 槽位标记宽');
    expect(a.slot.digitWidth, b.slot.digitWidth, reason: '$at 数字宽');
    expect(a.slot.ownRailAbove, b.slot.ownRailAbove, reason: '$at 上方导轨');
    expect(a.slot.revealedMarkers, b.slot.revealedMarkers, reason: '$at 标记摊开');
    expect(a.slot.railXs, b.slot.railXs, reason: '$at 导轨');
    expect(a.visuals.length, b.visuals.length, reason: '$at 视觉行数');
    for (int v = 0; v < a.visuals.length; v++) {
      expect(a.visuals[v].top, b.visuals[v].top, reason: '$at 视觉行 $v top');
      expect(a.visuals[v].height, b.visuals[v].height, reason: '$at 视觉行 $v 高');
      expect(a.visuals[v].start, b.visuals[v].start, reason: '$at 视觉行 $v 起');
      expect(a.visuals[v].end, b.visuals[v].end, reason: '$at 视觉行 $v 止');
      expect(a.visuals[v].width, b.visuals[v].width, reason: '$at 视觉行 $v 宽');
    }
    if (b.block == null) {
      expect(a.block, isNull, reason: '$at 自绘行出现/消失');
      expect(a.painter.plainText, b.painter.plainText, reason: '$at 排版文字');
    } else {
      expect(a.block, isNotNull, reason: '$at 自绘行消失');
      expect(a.block!.height, b.block!.height, reason: '$at 行块高');
      expect(a.block!.width, b.block!.width, reason: '$at 行块宽');
    }
  }
  expect(actual.height, expected.height, reason: '总高度');

  for (final TextSelection sel in <TextSelection>[
    TextSelection(baseOffset: 0, extentOffset: actual.text.length),
    TextSelection(
      baseOffset: actual.lines.first.start,
      extentOffset: actual.lines.last.end,
    ),
  ]) {
    expect(
      actual.selectionRects(sel.start, sel.end),
      expected.selectionRects(sel.start, sel.end),
      reason: '选区盒子 $sel',
    );
  }
  // 光标落点只探真正有字形的行：空行、纯空白行、只有 `# ` 之类的标记行
  // 没有字形盒，`getOffsetForCaret` 会踩到 Flutter 内部断言，那不是布局差异。
  final RegExp glyphs = RegExp(r'[0-9A-Za-z\u4e00-\u9fff]');
  final List<int> probes = <int>[];
  for (final LaidOutLine line in actual.laidOut) {
    if (line.hidden || line.block != null) continue;
    if (!glyphs.hasMatch(line.painter.plainText)) continue;
    probes.add(line.source.paintStart);
  }
  final List<int> caretOffsets = probes.isEmpty
      ? const <int>[]
      : <int>{probes.first, probes[probes.length ~/ 2], probes.last}.toList();
  for (final int offset in caretOffsets) {
    final CaretGeometry a = actual.caretGeometryAt(offset);
    final CaretGeometry b = expected.caretGeometryAt(offset);
    expect(a.origin, b.origin, reason: '光标 $offset 原点');
    expect(a.height, b.height, reason: '光标 $offset 高');
    expect(a.lineIndex, b.lineIndex, reason: '光标 $offset 行号');
  }
  for (final double y in <double>[0, actual.height / 2, actual.height - 1]) {
    expect(
      actual.offsetAtPoint(Offset(12, y)),
      expected.offsetAtPoint(Offset(12, y)),
      reason: '命中 y=$y',
    );
  }
}

String manyLines(int count) =>
    List<String>.generate(count, (int i) => '第 $i 行正文').join('\n');

void main() {
  group('编辑增量与全量一致', () {
    test('单字符插入：只重建被编辑行，尾部行整体复用', () {
      final Session s = Session(manyLines(200));
      addTearDown(s.dispose);
      final String text = s.text;
      final int at = text.indexOf('第 100 行正文') + '第 100 行正'.length;
      final ({bool ok, LineLayoutStats stats}) r = s.edit(
        '${text.substring(0, at)}新${text.substring(at)}',
      );

      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, 1, reason: '只有被编辑行需要重排');
      expect(r.stats.paintersMeasured, 1);
      expect(r.stats.reusedLines, 199);

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('单字符删除：同样只重建一行', () {
      final Session s = Session(manyLines(120));
      addTearDown(s.dispose);
      final String text = s.text;
      final int at = text.indexOf('第 60 行正文') + 2;
      final ({bool ok, LineLayoutStats stats}) r = s.edit(
        text.substring(0, at) + text.substring(at + 1),
      );

      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, 1);

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('行尾回车拆行', () {
      final Session s = Session('第一段\n第二段\n第三段\n第四段');
      addTearDown(s.dispose);
      final ({bool ok, LineLayoutStats stats}) r = s.edit('第一段\n\n第二段\n第三段\n第四段');
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, lessThanOrEqualTo(3));
      expect(r.stats.reusedLines, greaterThanOrEqualTo(2));

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('行首退格把两行合并', () {
      final Session s = Session('第一段\n第二段\n第三段\n第四段');
      addTearDown(s.dispose);
      final ({bool ok, LineLayoutStats stats}) r = s.edit('第一段\n第二段第三段\n第四段');
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, lessThanOrEqualTo(3));

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('文首插入与文末追加', () {
      final Session s = Session('甲\n乙\n丙');
      addTearDown(s.dispose);
      expect(s.edit('头甲\n乙\n丙').ok, isTrue);
      Reference ref = Reference(s.text, s.selection);
      expectSameLayout(s.layout, ref.layout);
      ref.dispose();

      expect(s.edit('头甲\n乙\n丙尾').ok, isTrue);
      final Reference ref2 = Reference(s.text, s.selection);
      addTearDown(ref2.dispose);
      expectSameLayout(s.layout, ref2.layout);
    });

    test('中文 IME 一次提交整词替换', () {
      final Session s = Session('你好世界\n第二行\n第三行');
      addTearDown(s.dispose);
      final ({bool ok, LineLayoutStats stats}) r = s.edit('你好地球\n第二行\n第三行');
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, lessThanOrEqualTo(2));

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('emoji（代理对）插入与删除', () {
      final Session s = Session('表情：\n第二行\n第三行');
      addTearDown(s.dispose);
      expect(s.edit('表情：😀\n第二行\n第三行').ok, isTrue);
      Reference ref = Reference(s.text, s.selection);
      expectSameLayout(s.layout, ref.layout);
      ref.dispose();

      expect(s.edit('表情：\n第二行\n第三行').ok, isTrue);
      final Reference ref2 = Reference(s.text, s.selection);
      addTearDown(ref2.dispose);
      expectSameLayout(s.layout, ref2.layout);
    });

    test('空文档到首字符，以及末尾换行', () {
      final Session s = Session('');
      addTearDown(s.dispose);
      expect(s.edit('a').ok, isTrue);
      Reference ref = Reference(s.text, s.selection);
      expectSameLayout(s.layout, ref.layout);
      ref.dispose();

      expect(s.edit('a\n').ok, isTrue);
      final Reference ref2 = Reference(s.text, s.selection);
      addTearDown(ref2.dispose);
      expectSameLayout(s.layout, ref2.layout);
    });
  });

  group('结构传播', () {
    test('列表条目内改字：其余条目编号与导轨不变', () {
      final Session s = Session('1. 甲\n2. 乙\n3. 丙\n\n尾行');
      addTearDown(s.dispose);
      final ({bool ok, LineLayoutStats stats}) r = s.edit(
        '1. 甲改\n2. 乙\n3. 丙\n\n尾行',
      );
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, 1);
      expect(r.stats.reusedLines, 4);

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('列表插入新条目并整体重编号：整组重建，尾部行复用', () {
      final Session s = Session('1. 甲\n2. 乙\n3. 丙\n\n尾行');
      addTearDown(s.dispose);
      final ({bool ok, LineLayoutStats stats}) r = s.edit(
        '1. 甲\n2. 新\n3. 乙\n4. 丙\n\n尾行',
      );
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, greaterThanOrEqualTo(3));
      expect(r.stats.reusedLines, greaterThanOrEqualTo(1));

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('围栏内编辑：整块重建，块外行复用', () {
      final Session s = Session(
        '前言\n\n```dart\nvoid main() {}\n```\n\n后记\n收尾',
      );
      addTearDown(s.dispose);
      final ({bool ok, LineLayoutStats stats}) r = s.edit(
        '前言\n\n```dart\nvoid main() { print(1); }\n```\n\n后记\n收尾',
      );
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, 3, reason: '围栏两行 + 代码行');
      expect(r.stats.reusedLines, greaterThanOrEqualTo(3));

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('表格单元格编辑：整表重建，表外行复用', () {
      final Session s = Session(
        '前言\n\n| 名称 | 说明 |\n| --- | --- |\n| a | 1 |\n| b | 2 |\n\n后记',
      );
      addTearDown(s.dispose);
      final ({bool ok, LineLayoutStats stats}) r = s.edit(
        '前言\n\n| 名称 | 说明 |\n| --- | --- |\n| a | 11 |\n| b | 2 |\n\n后记',
      );
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, 4, reason: '表头 + 分隔行 + 两行数据');
      expect(r.stats.reusedLines, greaterThanOrEqualTo(2));

      final Reference ref = Reference(s.text, s.selection);
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });

    test('表格前后插行：表格仍按整表连带', () {
      final Session s = Session('前言\n\n| 名称 | 说明 |\n| --- | --- |\n| a | 1 |\n\n后记');
      addTearDown(s.dispose);
      expect(
        s.edit('前言\n\n| 名称 | 说明 |\n| --- | --- |\n| a | 1 |\n| b | 2 |\n\n后记').ok,
        isTrue,
      );
      Reference ref = Reference(s.text, s.selection);
      expectSameLayout(s.layout, ref.layout);
      ref.dispose();

      expect(s.edit('前言\n\n| 名称 | 说明 |\n| --- | --- |\n| a | 1 |\n| b | 2 |\n\n后\n记').ok, isTrue);
      final Reference ref2 = Reference(s.text, s.selection);
      addTearDown(ref2.dispose);
      expectSameLayout(s.layout, ref2.layout);
    });

    test('折叠状态下编辑父项', () {
      final String text = '- 父项\n  - 子项一\n  - 子项二\n\n尾行';
      final int parentStart = 0;
      final Session s = Session(
        text,
        folded: <int>{parentStart},
      );
      addTearDown(() => s.dispose());
      final ({bool ok, LineLayoutStats stats}) r = s.edit(
        '- 父项改\n  - 子项一\n  - 子项二\n\n尾行',
      );
      expect(r.ok, isTrue);
      expect(r.stats.rebuiltLines, 1, reason: '被藏起来的行不测量');

      final Reference ref = Reference(
        s.text,
        s.selection,
        folded: s.folded,
      );
      addTearDown(ref.dispose);
      expectSameLayout(s.layout, ref.layout);
    });
  });

  group('安全边界', () {
    test('宽度变化与差分不符时拒绝增量', () {
      final Session s = Session('甲\n乙\n丙');
      addTearDown(s.dispose);
      final LineDocumentLayout previous = s.layout;

      expect(
        relayoutOnEdit(
          previous: previous,
          text: '甲\n乙丙',
          editStart: 2,
          removedLength: 1,
          insertedLength: 0,
          baseStyle: base,
          contentWidth: width + 10,
        ),
        isNull,
        reason: '宽度变了必须退回全量',
      );

      final ({int start, int removed, int inserted}) diff = diffOf('甲\n乙\n丙', '甲\n乙丙');
      expect(
        relayoutOnEdit(
          previous: previous,
          text: '甲\n乙丙',
          editStart: diff.start,
          removedLength: diff.removed + 1,
          insertedLength: diff.inserted,
          baseStyle: base,
          contentWidth: width,
        ),
        isNull,
        reason: '尾部对不上就说明区间不是真实差分',
      );
    });

    test('固定种子随机编辑序列：逐步与全量对照，零退化', () {
      final math.Random rnd = math.Random(20261023);
      final Session s = Session('第一行\n第二行\n\n- 项目\n  续行\n\n尾行');
      addTearDown(s.dispose);
      const List<String> inserts = <String>['a', '中', '新', '\n', '# ', '- ', '|', ' '];
      int fallbacks = 0;

      for (int step = 0; step < 80; step++) {
        final String current = s.text;
        final int at = current.isEmpty ? 0 : rnd.nextInt(current.length + 1);
        final int op = rnd.nextInt(3);
        String next;
        if (op == 0 || current.isEmpty) {
          next = current.substring(0, at) +
              inserts[rnd.nextInt(inserts.length)] +
              current.substring(at);
        } else if (op == 1 && at < current.length) {
          final int count = math.min(1 + rnd.nextInt(4), current.length - at);
          next = current.substring(0, at) + current.substring(at + count);
        } else {
          next = current + inserts[rnd.nextInt(inserts.length)];
        }
        expect(next, isNot(current), reason: '第 $step 步没有产生变化');
        final ({bool ok, LineLayoutStats stats}) r = s.edit(next);
        if (!r.ok) fallbacks++;

        final Reference ref = Reference(s.text, s.selection);
        expectSameLayout(s.layout, ref.layout);
        ref.dispose();
      }

      expect(fallbacks, 0, reason: '真实编辑的差分区间不该触发退化');
    });
  });

  group('渲染层接线', () {
    testWidgets('普通输入走编辑增量，不触发全量重排', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final MarkdownSourceController controller = MarkdownSourceController(
        text: '第一段\n第二段\n第三段\n第四段',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppPalette.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 720,
                height: 300,
                child: MarkdownEditor(
                  controller: controller,
                  focusNode: FocusNode(),
                  scrollController: ScrollController(),
                  fontSize: 15.5,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final RenderLineEditable render = tester.allRenderObjects
          .whereType<RenderLineEditable>()
          .first;
      expect(render.debugFullLayouts, greaterThanOrEqualTo(1));
      final int fullBefore = render.debugFullLayouts;
      final TextPainter lastPainter =
          render.lineLayout!.laidOut.last.painter;

      controller.value = const TextEditingValue(
        text: '第一段\n第二段改\n第三段\n第四段',
        selection: TextSelection.collapsed(offset: 9),
      );
      await tester.pump();
      await tester.pump();

      expect(render.debugEditRelayouts, 1, reason: '应该走编辑增量');
      expect(render.debugFullLayouts, fullBefore, reason: '不该退回全量');
      expect(render.lineLayout!.text, '第一段\n第二段改\n第三段\n第四段');
      // 未编辑的行整对象换壳复用同一个 painter。
      expect(
        identical(lastPainter, render.lineLayout!.laidOut.last.painter),
        isTrue,
      );
    });
  });
}
