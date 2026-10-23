import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/live_line_style.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// P2：揭示选区变化只重排受影响的行。
///
/// 所有几何断言都拿「同一份文本、同一份选区跑一次全量 `layoutLines`」做对照：
/// 局部重排的结果必须与全量**逐行逐字段一致**，不做「肉眼看不出来」的豁免。
const AppPalette palette = AppPalette.light;
const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
const double width = 680;

final String document = <String>[
  '# 标题',
  '',
  '正文 **粗体** *斜体* `代码` [[双链]] #标签',
  '',
  '> 引用一行',
  '',
  '- 项目一',
  '  - 子项目',
  '- [ ] 待办',
  '',
  '| 名称 | 说明 |',
  '| --- | --- |',
  '| a | 1 |',
  '| b | 2 |',
  '',
  '```dart',
  'void main() {}',
  '```',
  '',
  '收尾段落。',
].join('\n');

/// 生产路径的持久夹具：样式、表格测量与逐行布局都跨轮存活。
class Doc {
  Doc(this.text);

  final String text;
  TextSelection? reveal;
  Set<int> lastDirty = const <int>{};

  late final LiveLineStyle style = LiveLineStyle(
    base: base,
    palette: palette,
    reveal: () => reveal,
    source: text,
  );
  late final LiveTableBlocks blocks = LiveTableBlocks(
    base: base,
    palette: palette,
    text: () => text,
    selection: () => reveal,
  );

  LineDocumentLayout? _current;

  LineDocumentLayout get current => _current!;

  LineDocumentLayout full() {
    final LineDocumentLayout layout = layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: width,
      styleFor: style.styleFor,
      heightFor: style.heightFor,
      spanFor: style.spanFor,
      fillFor: style.fillsFor,
      insetFor: style.insetFor,
      blockFor: blocks.blockFor,
    );
    _current = layout;
    return layout;
  }

  /// 把揭示选区改到 [next]，只重排签名变化的行。
  LineDocumentLayout reflow(TextSelection? next) {
    final LineDocumentLayout previous = current;
    lastDirty = previous.revealDirtyLines(reveal, next);
    reveal = next;
    final LineDocumentLayout layout = relayoutLines(
      previous: previous,
      dirtyLines: lastDirty,
      text: text,
      baseStyle: base,
      contentWidth: width,
      styleFor: style.styleFor,
      heightFor: style.heightFor,
      spanFor: style.spanFor,
      fillFor: style.fillsFor,
      insetFor: style.insetFor,
      blockFor: blocks.blockFor,
    );
    _current = layout;
    return layout;
  }

  void dispose() {
    _current?.dispose();
    _current = null;
    blocks.dispose();
  }
}

/// 参照组：用同一份文本与选区完整跑一次 `layoutLines`。
LineDocumentLayout referenceLayout(String text, TextSelection? selection) {
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
    contentWidth: width,
    styleFor: style.styleFor,
    heightFor: style.heightFor,
    spanFor: style.spanFor,
    fillFor: style.fillsFor,
    insetFor: style.insetFor,
    blockFor: blocks.blockFor,
  );
  addTearDown(() {
    layout.dispose();
    blocks.dispose();
  });
  return layout;
}

/// 记下每一行的行顶：局部重排会就地平移复用行的 `top`，旧布局不能再当快照读。
List<double> topsOf(LineDocumentLayout layout) =>
    <double>[for (final LaidOutLine line in layout.laidOut) line.top];

/// 逐行比较两份布局的全部几何出口；任何差异都直接失败。
void expectSameLayout(LineDocumentLayout actual, LineDocumentLayout expected) {
  expect(
    actual.laidOut.length,
    expected.laidOut.length,
    reason: '行数不一致',
  );
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
      expect(
        a.painter.plainText,
        b.painter.plainText,
        reason: '$at 排版文字',
      );
    } else {
      expect(a.block, isNotNull, reason: '$at 自绘行消失');
      expect(a.block!.height, b.block!.height, reason: '$at 行块高');
      expect(a.block!.width, b.block!.width, reason: '$at 行块宽');
    }
  }
  expect(actual.height, expected.height, reason: '总高度');

  // 几何出口抽样：选区盒子、光标落点、命中、整段落矩形。
  final int length = actual.text.length;
  for (final TextSelection sel in <TextSelection>[
    TextSelection(baseOffset: 0, extentOffset: length),
    TextSelection(
      baseOffset: actual.lines[2].start,
      extentOffset: actual.lines[6].end,
    ),
  ]) {
    expect(
      actual.selectionRects(sel.start, sel.end),
      expected.selectionRects(sel.start, sel.end),
      reason: '选区盒子 $sel',
    );
  }
  for (final int offset in <int>[0, 3, actual.lines[5].start, length]) {
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
  expect(
    actual.blockRect(0, length),
    expected.blockRect(0, length),
    reason: '整段落矩形',
  );
}

void main() {
  final List<SourceLine> lines = scanSourceLines(document);
  final int paragraphLine = 2;
  final int fenceOpenLine = 15;

  int startOf(int index) => lines[index].start;

  test('选区完全不变时脏行为空，不重排', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = const TextSelection.collapsed(offset: 3);
    doc.full();
    expect(
      doc.current.revealDirtyLines(
        doc.reveal,
        const TextSelection.collapsed(offset: 3),
      ),
      isEmpty,
    );
  });

  test('同一行内光标移动只重建该行，几何与全量一致', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = TextSelection.collapsed(offset: startOf(paragraphLine) + 1);
    final LineDocumentLayout before = doc.full();

    final TextSelection after = TextSelection.collapsed(
      offset: startOf(paragraphLine) + 4,
    );
    final LineDocumentLayout next = doc.reflow(after);
    expect(doc.lastDirty, <int>{paragraphLine});

    for (int i = 0; i < before.laidOut.length; i++) {
      if (i == paragraphLine) {
        expect(identical(before.laidOut[i], next.laidOut[i]), isFalse);
      } else {
        expect(
          identical(before.laidOut[i], next.laidOut[i]),
          isTrue,
          reason: '第 $i 行不该重建',
        );
      }
    }
    expectSameLayout(next, referenceLayout(document, after));
  });

  test('光标从 A 行移到 B 行：只重排两行，后续 top 不变', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = TextSelection.collapsed(offset: startOf(paragraphLine));
    final LineDocumentLayout before = doc.full();
    final List<double> beforeTops = topsOf(before);

    final TextSelection after = TextSelection.collapsed(
      offset: startOf(9),
    );
    final LineDocumentLayout next = doc.reflow(after);
    expect(doc.lastDirty, <int>{paragraphLine, 9});
    expectSameLayout(next, referenceLayout(document, after));

    // 两行都是正文行，行高没变 → 全篇 top 一处都不动。
    for (int i = 0; i < beforeTops.length; i++) {
      expect(
        next.laidOut[i].top,
        beforeTops[i],
        reason: '第 $i 行 top 不该动',
      );
    }
  });

  test('Shift 跨行拖选：只重排端点与覆盖行，几何与全量一致', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = TextSelection.collapsed(offset: startOf(paragraphLine));
    doc.full();

    final TextSelection after = TextSelection(
      baseOffset: startOf(paragraphLine) + 2,
      extentOffset: startOf(8) + 4,
    );
    final LineDocumentLayout next = doc.reflow(after);
    expect(
      doc.lastDirty,
      <int>{
        for (int i = paragraphLine; i <= 8; i++) i,
      },
    );
    expectSameLayout(next, referenceLayout(document, after));
  });

  test('光标进出表格：整段表格 run 一起重建，只重测该表', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = TextSelection.collapsed(offset: startOf(paragraphLine));
    doc.full();
    final int initialMeasures = doc.blocks.debugTableMeasures;

    // 进表：光标落在表头第一个格子。
    final TextSelection inTable = TextSelection.collapsed(
      offset: startOf(10) + 3,
    );
    final LineDocumentLayout entered = doc.reflow(inTable);
    expect(doc.blocks.debugTableMeasures, initialMeasures + 1);
    for (int i = 0; i < 4; i++) {
      expect(doc.lastDirty.contains(10 + i), isTrue, reason: '表行 ${10 + i}');
    }
    expectSameLayout(entered, referenceLayout(document, inTable));

    // 离表：回到正文，表格离开编辑态，只重测它自己。
    final TextSelection outTable = TextSelection.collapsed(
      offset: startOf(paragraphLine) + 1,
    );
    final LineDocumentLayout left = doc.reflow(outTable);
    expect(doc.blocks.debugTableMeasures, initialMeasures + 2);
    expectSameLayout(left, referenceLayout(document, outTable));
  });

  test('光标进出围栏行：行高切换，后续 top 与总高度一起更新', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = TextSelection.collapsed(offset: startOf(paragraphLine));
    final LineDocumentLayout before = doc.full();
    final List<double> beforeTops = topsOf(before);
    final double foldedHeight = before.laidOut[fenceOpenLine].height;
    expect(foldedHeight, lessThan(24));

    final TextSelection onFence = TextSelection.collapsed(
      offset: startOf(fenceOpenLine),
    );
    final LineDocumentLayout opened = doc.reflow(onFence);
    expect(opened.laidOut[fenceOpenLine].height, greaterThan(foldedHeight));
    expect(opened.height, greaterThan(before.height));
    expect(
      opened.laidOut[fenceOpenLine + 1].top,
      greaterThan(beforeTops[fenceOpenLine + 1]),
    );
    expectSameLayout(opened, referenceLayout(document, onFence));

    final TextSelection away = TextSelection.collapsed(offset: 0);
    final LineDocumentLayout closed = doc.reflow(away);
    expect(closed.laidOut[fenceOpenLine].height, foldedHeight);
    expect(closed.height, before.height);
    expectSameLayout(closed, referenceLayout(document, away));
  });

  test('Ctrl+A 全选（揭示全文）等价于全量重排', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = TextSelection.collapsed(offset: startOf(paragraphLine));
    doc.full();

    final TextSelection all = TextSelection(
      baseOffset: 0,
      extentOffset: document.length,
    );
    final LineDocumentLayout next = doc.reflow(all);
    expect(doc.lastDirty.length, doc.current.laidOut.length);
    expectSameLayout(next, referenceLayout(document, all));
  });

  test('局部重排后旧布局 dispose 是空操作，复用的 painter 仍然可用', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = TextSelection.collapsed(offset: startOf(paragraphLine));
    final LineDocumentLayout before = doc.full();

    final LineDocumentLayout next = doc.reflow(
      TextSelection.collapsed(offset: startOf(9)),
    );
    // 交接所有权后旧布局不再释放任何行；重复 dispose 也必须安全。
    before.dispose();
    before.dispose();

    expect(next.caretGeometryAt(0).origin, isNotNull);
    expect(next.selectionRects(0, document.length), isNotEmpty);
  });

  test('一串光标/拖选序列：每一步都与全量布局逐行一致', () {
    final Doc doc = Doc(document);
    addTearDown(doc.dispose);
    doc.reveal = const TextSelection.collapsed(offset: -1);
    doc.full();

    final List<TextSelection> sequence = <TextSelection>[
      TextSelection.collapsed(offset: startOf(paragraphLine) + 1),
      TextSelection.collapsed(offset: startOf(paragraphLine) + 6),
      TextSelection.collapsed(offset: startOf(9) + 2),
      TextSelection(
        baseOffset: startOf(paragraphLine),
        extentOffset: startOf(9) + 2,
      ),
      TextSelection.collapsed(offset: startOf(10) + 4),
      TextSelection(
        baseOffset: startOf(10),
        extentOffset: startOf(12) + 2,
      ),
      TextSelection.collapsed(offset: startOf(fenceOpenLine) + 1),
      TextSelection.collapsed(offset: 0),
      TextSelection(baseOffset: 0, extentOffset: document.length),
      TextSelection.collapsed(offset: startOf(paragraphLine) + 3),
    ];
    for (final TextSelection step in sequence) {
      final LineDocumentLayout next = doc.reflow(step);
      expectSameLayout(next, referenceLayout(document, step));
    }
  });

  group('渲染对象', () {
    const String text = '第一行正文\n第二行正文\n第三行正文\n第四行正文';
    const TextStyle style = TextStyle(fontSize: 16, height: 1.5);

    TextSelection? reveal;
    final LiveLineStyle styles = LiveLineStyle(
      base: style,
      palette: palette,
      reveal: () => reveal,
      source: text,
    );

    Widget host(TextEditingController controller, FocusNode focus) {
      return MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              height: 400,
              child: LineEditableText(
                controller: controller,
                focusNode: focus,
                style: style,
                cursorColor: const Color(0xFF000000),
                backgroundCursorColor: const Color(0xFFBBBBBB),
                selectionColor: const Color(0x33000000),
                maxLines: null,
                lineStyleFor: styles.styleFor,
                lineHeightFor: styles.heightFor,
                lineSpanFor: styles.spanFor,
                lineFillFor: styles.fillsFor,
                lineInsetFor: styles.insetFor,
                revealSelection: () => reveal,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('revealSelection 变化只重建脏行，未变行整对象复用', (
      WidgetTester tester,
    ) async {
      final TextEditingController controller = TextEditingController(text: text);
      final FocusNode focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);

      reveal = null;
      await tester.pumpWidget(host(controller, focus));
      final RenderLineEditable render =
          tester.state<LineEditableTextState>(find.byType(LineEditableText))
                  .renderEditable
              as RenderLineEditable;
      final LineDocumentLayout before = render.lineLayout!;

      reveal = const TextSelection.collapsed(offset: 2);
      await tester.pumpWidget(host(controller, focus));
      final LineDocumentLayout after = render.lineLayout!;

      expect(after, isNot(same(before)));
      expect(identical(before.laidOut[0], after.laidOut[0]), isFalse);
      for (int i = 1; i < 4; i++) {
        expect(
          identical(before.laidOut[i], after.laidOut[i]),
          isTrue,
          reason: '第 $i 行不该重建',
        );
      }
      expect(after.height, before.height);
    });

    testWidgets('IME 组合区间变化（文本与选区不变）不重排布局', (
      WidgetTester tester,
    ) async {
      final TextEditingController controller = TextEditingController(text: text);
      final FocusNode focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);

      reveal = const TextSelection.collapsed(offset: 2);
      await tester.pumpWidget(host(controller, focus));
      final RenderLineEditable render =
          tester.state<LineEditableTextState>(find.byType(LineEditableText))
                  .renderEditable
              as RenderLineEditable;
      final LineDocumentLayout before = render.lineLayout!;

      controller.value = controller.value.copyWith(
        composing: const TextRange(start: 0, end: 2),
      );
      await tester.pumpWidget(host(controller, focus));

      expect(identical(before, render.lineLayout), isTrue);
    });
  });
}
