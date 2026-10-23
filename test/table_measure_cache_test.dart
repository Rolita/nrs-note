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

    const LineBlockContext narrow = LineBlockContext(
      contentWidth: 320,
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );
    layoutTables(narrow);
    expect(blocks.debugTableMeasures, 4);
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
