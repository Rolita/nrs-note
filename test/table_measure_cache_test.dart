import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// 表格测量的按表缓存。
///
/// 这里只走生产入口 `blockFor`：引擎对每张表的每一行问一次，`debugTableMeasures`
/// 记录整表实际测量的次数。正文变化、光标移动都不该让没变的表重测。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const AppPalette palette = AppPalette.light;
  const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
  const LineBlockContext context = LineBlockContext(
    contentWidth: 680,
    textScaler: TextScaler.noScaling,
    textDirection: TextDirection.ltr,
  );

  const String twoTables =
      '前置\n\n'
      '| a | b |\n'
      '| --- | --- |\n'
      '| 1 | 2 |\n'
      '| 3 | 4 |\n'
      '\n中间\n\n'
      '| x | y |\n'
      '| --- | --- |\n'
      '| 9 | 8 |\n'
      '\n后记';

  late String text;
  TextSelection? selection;
  late LiveTableBlocks blocks;

  setUp(() {
    text = twoTables;
    selection = const TextSelection.collapsed(offset: -1);
    blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => selection,
    );
  });

  tearDown(() => blocks.dispose());

  Iterable<SourceLine> tableLines(String source) => scanSourceLines(source)
      .where(
        (SourceLine line) =>
            line.kind == LineBlockKind.table ||
            line.kind == LineBlockKind.tableHeader,
      );

  /// 像生产路径那样，把每一行表格都问一遍。
  void layoutTables([LineBlockContext ctx = context]) {
    for (final SourceLine line in tableLines(text)) {
      blocks.blockFor(line, ctx);
    }
  }

  LineBlockView? firstTableBlock([LineBlockContext ctx = context]) =>
      blocks.blockFor(tableLines(text).first, ctx);

  LineBlockView? lastTableBlock([LineBlockContext ctx = context]) =>
      blocks.blockFor(tableLines(text).last, ctx);

  test('光标在正文里移动不重测表格', () {
    layoutTables();
    expect(blocks.debugTableMeasures, 2);
    final LineBlockView? first = firstTableBlock();
    final LineBlockView? last = lastTableBlock();

    selection = const TextSelection.collapsed(offset: 0);
    layoutTables();
    selection = const TextSelection.collapsed(offset: 1);
    layoutTables();

    expect(blocks.debugTableMeasures, 2);
    expect(identical(firstTableBlock(), first), isTrue);
    expect(identical(lastTableBlock(), last), isTrue);
  });

  test('光标跨格才重测，同一格内移动复用', () {
    layoutTables();
    expect(blocks.debugTableMeasures, 2);

    final int a = text.indexOf('a');
    selection = TextSelection.collapsed(offset: a);
    layoutTables();
    expect(blocks.debugTableMeasures, 3);
    final LineBlockView? header = firstTableBlock();

    selection = TextSelection.collapsed(offset: a + 1);
    layoutTables();
    expect(blocks.debugTableMeasures, 3);
    expect(identical(firstTableBlock(), header), isTrue);

    selection = TextSelection.collapsed(offset: text.indexOf('b'));
    layoutTables();
    expect(blocks.debugTableMeasures, 4);

    selection = const TextSelection.collapsed(offset: 0);
    layoutTables();
    expect(blocks.debugTableMeasures, 5);
  });

  test('正文编辑与别的表编辑不重测这张表', () {
    layoutTables();
    expect(blocks.debugTableMeasures, 2);
    final LineBlockView? first = firstTableBlock();
    final LineBlockView? last = lastTableBlock();

    text = '序\n$text';
    layoutTables();
    expect(blocks.debugTableMeasures, 2);
    expect(identical(firstTableBlock(), first), isTrue);
    expect(identical(lastTableBlock(), last), isTrue);

    text = text.replaceFirst('| 9 |', '| 99 |');
    layoutTables();
    expect(blocks.debugTableMeasures, 3);
    expect(identical(firstTableBlock(), first), isTrue);
    expect(identical(lastTableBlock(), last), isFalse);
  });

  test('内容宽度变化让所有表重测', () {
    layoutTables();
    expect(blocks.debugTableMeasures, 2);
    // 两张表一共 10 个非编辑格，首次测量全部建树。
    expect(blocks.debugCellSpanBuilds, 10);

    const LineBlockContext narrow = LineBlockContext(
      contentWidth: 320,
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );
    layoutTables(narrow);
    expect(blocks.debugTableMeasures, 4);
    // 环境变化清空了按格缓存：所有格重新建树。
    expect(blocks.debugCellSpanBuilds, 20);
  });

  test('同一格连续输入只重建该格', () {
    // 被编辑的那一格远窄于同列其它内容：连打几个字符不会撑宽列，列宽
    // 不动，其余格的 painter 才能原样命中。列宽一旦变化，同列每一格都得
    // 重排（它们的挤压结果与列宽绑定），这是测量本身的约束。
    text =
        '| 宽列 | 很窄的列 |\n'
        '| --- | --- |\n'
        '| aaaaaaaaaaaaaaaaaaaaaa | x |\n'
        '| bbbbbbbbbbbbbbbbbbbbbb | y |\n';
    layoutTables();
    expect(blocks.debugTableMeasures, 1);
    final int baseSpans = blocks.debugCellSpanBuilds;
    final int basePainters = blocks.debugCellPainterBuilds;
    expect(baseSpans, 6);
    expect(basePainters, 6);

    // 进入这一格：整表重测一次，只有这一格需要新 painter。
    final int x = text.indexOf('x');
    selection = TextSelection.collapsed(offset: x + 1);
    layoutTables();
    expect(blocks.debugTableMeasures, 2);
    expect(blocks.debugCellSpanBuilds, baseSpans);
    expect(blocks.debugCellPainterBuilds, basePainters + 1);

    // 在同一格里连打三个字符：其余格全部命中缓存。
    for (int i = 0; i < 3; i++) {
      text = text.replaceRange(x + 1, x + 1, 'x');
      layoutTables();
    }
    expect(blocks.debugTableMeasures, 5);
    expect(blocks.debugCellSpanBuilds, baseSpans);
    expect(blocks.debugCellPainterBuilds, basePainters + 4);
  });

  test('增量测量与全新实例的几何一致', () {
    layoutTables();
    final int a = text.indexOf('a');
    selection = TextSelection.collapsed(offset: a + 1);
    for (int i = 0; i < 3; i++) {
      text = text.replaceRange(a + 1, a + 1, 'x');
      layoutTables();
    }

    final LiveTableBlocks fresh = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => selection,
    );
    addTearDown(fresh.dispose);

    for (final SourceLine line in tableLines(text)) {
      final LineBlockView incremental = blocks.blockFor(line, context)!;
      final LineBlockView expected = fresh.blockFor(line, context)!;
      expect(
        (incremental as TableRowChrome).chromeCells(),
        (expected as TableRowChrome).chromeCells(),
      );
      for (int offset = line.start; offset <= line.end; offset++) {
        expect(
          incremental.caretRectAt(offset),
          expected.caretRectAt(offset),
          reason: 'offset $offset on line ${line.index}',
        );
      }
    }
  });

  test('表格上方插入行后行号与偏移重绑，不重测', () {
    layoutTables();
    expect(blocks.debugTableMeasures, 2);
    final LineBlockView first = firstTableBlock()!;
    final TableRowChrome chrome = first as TableRowChrome;
    final int oldFirstCell = first.offsetAt(const Offset(-1, 0));
    final int oldTableId = chrome.chromeTableId;
    final int oldSourceStart = chrome.chromeSourceStart;

    text = text.replaceFirst('前置\n\n', '前置\n\n插入\n\n');
    layoutTables();
    expect(blocks.debugTableMeasures, 2);

    final LineBlockView moved = firstTableBlock()!;
    expect(identical(moved, first), isTrue);
    final TableRowChrome movedChrome = moved as TableRowChrome;
    // '插入\n\n' 的 UTF-16 长度。
    const int shift = 4;
    expect(moved.offsetAt(const Offset(-1, 0)), oldFirstCell + shift);
    expect(movedChrome.chromeTableId, oldTableId + shift);
    expect(movedChrome.chromeSourceStart, oldSourceStart + shift);
  });

  test('重复释放不抛异常', () {
    layoutTables();
    blocks.dispose();
    blocks.dispose();
  });
}
