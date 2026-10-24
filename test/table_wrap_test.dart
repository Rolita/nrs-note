import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// 超宽表格不再用负字距硬挤，而是在格子内部换行（方案 §3.3 A）。
///
/// 窄表必须保持原来的列宽与行高；宽表允许变高，但每一列都要有可读宽度，
/// 每个字符的光标与命中都要能往返。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const AppPalette palette = AppPalette.light;
  const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
  const LineBlockContext context = LineBlockContext(
    contentWidth: 680,
    textScaler: TextScaler.noScaling,
    textDirection: TextDirection.ltr,
  );

  List<SourceLine> tableLines(String source) => scanSourceLines(source)
      .where(
        (SourceLine line) =>
            line.kind == LineBlockKind.table ||
            line.kind == LineBlockKind.tableHeader,
      )
      .toList();

  ({LiveTableBlocks blocks, List<SourceLine> lines, List<LineBlockView> rows})
  build(String text, {LineBlockContext ctx = context}) {
    final LiveTableBlocks blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
    );
    final List<SourceLine> lines = tableLines(text);
    final List<LineBlockView> rows = <LineBlockView>[
      for (final SourceLine line in lines) blocks.blockFor(line, ctx)!,
    ];
    return (blocks: blocks, lines: lines, rows: rows);
  }

  Iterable<TextSpan> spansOf(InlineSpan span) sync* {
    if (span is! TextSpan) return;
    yield span;
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      yield* spansOf(child);
    }
  }

  void expectNoNegativeTracking(List<LineBlockView> rows) {
    for (final LineBlockView row in rows) {
      for (final InlineSpan span in (row as TableRowChrome).chromeCellSpans()) {
        for (final TextSpan text in spansOf(span)) {
          expect(
            text.style?.letterSpacing ?? 0,
            greaterThanOrEqualTo(0),
            reason: '表格不再用负字距把文字挤进列宽',
          );
        }
      }
    }
  }

  /// 每一格文字范围内的偏移：光标矩形 → 命中偏移，必须回到同一个偏移。
  void expectCaretRoundTrip(
    List<SourceLine> lines,
    List<LineBlockView> rows,
  ) {
    for (int r = 0; r < rows.length; r++) {
      final String line = lines[r].text;
      for (final (int rawFrom, int rawTo) in tableCellsOf(line)) {
        // 内边距空格不属于用户点击的内容：它们的折行位置由排版器决定，
        // 光标落在哪一条视觉行的行首本来就不唯一。
        int from = rawFrom;
        int to = rawTo;
        while (from < to && line[from] == ' ') {
          from++;
        }
        while (to > from && line[to - 1] == ' ') {
          to--;
        }
        for (int offset = from; offset <= to; offset++) {
          final int absolute = lines[r].start + offset;
          final Rect caret = rows[r].caretRectAt(absolute);
          expect(
            rows[r].offsetAt(Offset(caret.left, caret.center.dy)),
            absolute,
            reason: '第 ${lines[r].index} 行 offset $absolute',
          );
        }
      }
    }
  }

  test('窄表列宽、行高与改造前一致', () {
    const String text =
        '| a | b |\n'
        '| --- | --- |\n'
        '| c | d |\n';
    final built = build(text);
    addTearDown(built.blocks.dispose);

    expect(built.rows, hasLength(2));
    for (final LineBlockView row in built.rows) {
      final List<Rect> cells = (row as TableRowChrome).chromeCells();
      // 单字符的列停在 _kMinCell：64 的文字区 + 两侧各 8 的内边距。
      expect(cells.map((Rect cell) => cell.width), <double>[80, 80]);
      expect(row.width, 160);
      expect(row.height, closeTo(28, 0.5));
    }
    expectNoNegativeTracking(built.rows);
    expectCaretRoundTrip(built.lines, built.rows);
  });

  test('右对齐的窄表仍然贴着列的右边缘', () {
    const String text =
        '| a | b |\n'
        '| --- | ---: |\n'
        '| c | d |\n';
    final built = build(text);
    addTearDown(built.blocks.dispose);

    final LineBlockView row = built.rows.first;
    final Rect cell = (row as TableRowChrome).chromeCells()[1];
    final int offset =
        built.lines.first.start + tableCellsOf(built.lines.first.text)[1].$2;
    // 右对齐：格内文字区的右边缘，而不是整格（含内边距）的右边缘。
    expect(row.caretRectAt(offset).left, closeTo(cell.right - 8, 0.5));
  });

  test('超宽表格给每列可读地板，长内容在格内换行', () {
    const String cell = '第一列 的 一段 很长 的 说明 文字';
    final String text =
        '| 列一 | 列二 | 列三 | 列四 |\n'
        '| --- | --- | --- | --- |\n'
        '| $cell | $cell | $cell | $cell |\n';
    final built = build(text);
    addTearDown(built.blocks.dispose);

    expect(built.rows, hasLength(2));
    for (final Rect box
        in (built.rows.first as TableRowChrome).chromeCells()) {
      // 可读地板 88 + 两侧内边距。
      expect(box.width, greaterThanOrEqualTo(88 + 2 * 8 - 0.01));
    }
    // 表格铺满正文列的可用宽度，不再缩成一列条。
    expect(built.rows.first.width, closeTo(679, 1));
    // 表头只有一行；数据格换成两行，行高随之变高。
    expect(built.rows.first.height, closeTo(28, 0.5));
    expect(built.rows[1].height, greaterThan(28 + 20));
    expectNoNegativeTracking(built.rows);
    expectCaretRoundTrip(built.lines, built.rows);
  });

  test('列数多到放不下地板时等分，长词在格内折断', () {
    final List<String> cells = <String>[
      'h',
      for (int c = 1; c < 10; c++) 'c$c',
    ];
    final String text =
        '| ${cells.join(' | ')} |\n'
        '| ${List<String>.filled(10, '---').join(' | ')} |\n'
        '| ${List<String>.filled(10, 'a').join(' | ')} |\n';
    final built = build(text);
    addTearDown(built.blocks.dispose);

    final List<Rect> boxes = (built.rows.first as TableRowChrome).chromeCells();
    // 等分：每列的框宽完全一致，总宽仍是正文列的可用宽度。
    final double width = boxes.first.width;
    for (final Rect box in boxes) {
      expect(box.width, closeTo(width, 0.01));
    }
    expect(built.rows.first.width, closeTo(679, 1));
    expectNoNegativeTracking(built.rows);
    expectCaretRoundTrip(built.lines, built.rows);
  });
}
