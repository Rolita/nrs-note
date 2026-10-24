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
  build(
    String text, {
    LineBlockContext ctx = context,
    TextStyle style = base,
  }) {
    final LiveTableBlocks blocks = LiveTableBlocks(
      base: style,
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
      // 单字符的列停在 kTableMinColumnWidth：64 的文字区 + 两侧各 8 的内边距。
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

  group('手动列宽', () {
    test('w= 决定每列宽度，并把几何交给指针层', () {
      const String text =
          '| <!--nrs w=180,240-->指标 | 本周 |\n'
          '| --- | --- |\n'
          '| 新增 | 42 |\n';
      final built = build(text);
      addTearDown(built.blocks.dispose);

      final TableRowChrome first = built.rows.first as TableRowChrome;
      // 180 + 240 的设计像素，加上每格两侧各 8 的内边距。
      expect(first.chromeCells().map((Rect r) => r.width), <double>[
        196,
        256,
      ]);
      expect(built.rows.first.width, 452);
      expect(first.chromeColumnWidths(), <double>[180, 240]);
      // 正文 680 − 1，再减掉两列共 32 的内边距。
      expect(first.chromeColumnRoom(), closeTo(647, 0.01));
      expect(first.chromeWidthScale(), 1);
    });

    test('手动列宽随字号与文字缩放等比换算', () {
      const String text =
          '| <!--nrs w=90,120-->a | b |\n'
          '| --- | --- |\n'
          '| c | d |\n';

      final built = build(
        text,
        style: const TextStyle(fontSize: 31, height: 1.78),
      );
      addTearDown(built.blocks.dispose);
      final TableRowChrome doubled = built.rows.first as TableRowChrome;
      expect(doubled.chromeColumnWidths(), <double>[180, 240]);
      expect(doubled.chromeWidthScale(), 2);

      final scaled = build(
        text,
        ctx: const LineBlockContext(
          contentWidth: 680,
          textScaler: TextScaler.linear(1.5),
          textDirection: TextDirection.ltr,
        ),
      );
      addTearDown(scaled.blocks.dispose);
      final TableRowChrome scaledRow = scaled.rows.first as TableRowChrome;
      expect(scaledRow.chromeColumnWidths(), <double>[135, 180]);
      expect(scaledRow.chromeWidthScale(), 1.5);
    });

    test('手动列宽超出正文时仍按可读地板收缩', () {
      const String text =
          '| <!--nrs w=300,400-->a | b |\n'
          '| --- | --- |\n'
          '| c | d |\n';
      final built = build(
        text,
        ctx: const LineBlockContext(
          contentWidth: 500,
          textScaler: TextScaler.noScaling,
          textDirection: TextDirection.ltr,
        ),
      );
      addTearDown(built.blocks.dispose);

      final List<double> widths =
          (built.rows.first as TableRowChrome).chromeColumnWidths();
      // fit = 499 − 2 × 2 × 8 = 467；两列都有 88 的可读地板，
      // 超出的部分按各自还想要的宽度分。
      expect(widths[0], closeTo(205.73, 0.1));
      expect(widths[1], closeTo(261.27, 0.1));
      expect(widths[0] + widths[1], closeTo(467, 0.01));
      expect(built.rows.first.width, closeTo(499, 0.01));
    });

    test('非法 w 整条忽略，几何回到自动列宽', () {
      const String text =
          '| <!--nrs w=180-->a | b |\n'
          '| --- | --- |\n'
          '| c | d |\n';
      final built = build(text);
      addTearDown(built.blocks.dispose);

      // 两列却只有一项：不是合法列宽列表。
      expect(
        (built.rows.first as TableRowChrome).chromeCells().map(
          (Rect r) => r.width,
        ),
        <double>[80, 80],
      );
      expect(built.rows.first.width, 160);
    });

    test('合并表头不会撑开手动列宽，文字在块内换行', () {
      const String header =
          '年度汇总与区域明细以及更多说明文字再次补充一些内容以及其他需要说明的事项';
      const String text =
          '| <!--nrs c=2 w=180,240-->$header |  |\n'
          '| --- | --- |\n'
          '| a | 1 |\n'
          '| b | 2 |\n';
      final built = build(text);
      addTearDown(built.blocks.dispose);

      // 表头的自然宽度超过了 180 + 240 + 一格内边距，但手动列宽优先。
      final TableRowChrome first = built.rows.first as TableRowChrome;
      expect(first.chromeColumnWidths(), <double>[180, 240]);
      expect(first.chromeCells().first.width, 452);
      final TableRowChrome data = built.rows[1] as TableRowChrome;
      expect(data.chromeCells().map((Rect r) => r.width), <double>[196, 256]);
    });
  });

  group('列宽拖拽分配', () {
    (double, double) drag({
      required double left,
      required double right,
      required double dx,
      required double room,
    }) => resizeColumnPair(left: left, right: right, dx: dx, room: room);

    test('有余量时只长左列，右列不动', () {
      // room 300：两列 64 之外还有 172 的余量。
      expect(drag(left: 64, right: 64, dx: 40, room: 300), (104.0, 64.0));
      expect(
        drag(left: 64, right: 64, dx: 400, room: 300),
        (236.0, 64.0),
        reason: '表格长到正文宽度就停，右列始终没动',
      );
    });

    test('表格长满后右列让位，最低到 64', () {
      expect(drag(left: 200, right: 200, dx: 100, room: 400), (300.0, 100.0));
      expect(
        drag(left: 200, right: 200, dx: 400, room: 400),
        (336.0, 64.0),
        reason: '右列只让到 64，剩下的行程不再生效',
      );
    });

    test('往左拖只缩左列，右列不动', () {
      expect(drag(left: 200, right: 100, dx: -100, room: 400), (100.0, 100.0));
      expect(drag(left: 200, right: 100, dx: -400, room: 400), (64.0, 100.0));
    });

    test('已经低于地板的表只能从左边长回来', () {
      // 表比正文窄，但右列没到 64，没有可让的宽度。
      expect(drag(left: 40, right: 50, dx: -10, room: 200), (40.0, 50.0));
      expect(drag(left: 40, right: 50, dx: 10, room: 200), (50.0, 50.0));
    });

    test('正好满宽且右列到地板时，向右拖不动', () {
      expect(drag(left: 100, right: 64, dx: 40, room: 164), (100.0, 64.0));
      expect(
        drag(left: 100, right: 64, dx: -100, room: 164),
        (64.0, 64.0),
        reason: '向左仍可以缩左列，让整张表变窄',
      );
    });
  });

  group('列宽拖拽手柄', () {
    List<TableChromeTarget> resizers(List<LineBlockView> rows) =>
        <TableChromeTarget>[
          for (final LineBlockView row in rows)
            for (final TableChromeTarget target
                in (row as TableRowChrome).chromeTargets())
              if (target.kind == TableChromeKind.resizeColumn) target,
        ];

    test('每个露出的边界在每一行都有自己的手柄', () {
      const String text =
          '| a | b | c |\n'
          '| --- | --- | --- |\n'
          '| d | e | f |';
      final built = build(text);
      addTearDown(built.blocks.dispose);

      final List<TableChromeTarget> targets = resizers(built.rows);
      expect(
        targets.map((TableChromeTarget t) => t.index),
        <int>[0, 1, 2, 0, 1, 2],
        reason: '两行 ×（两条内部分隔线 + 右外沿）',
      );

      final TableRowChrome first = built.rows.first as TableRowChrome;
      final List<Rect> cells = first.chromeCells();
      expect(targets[0].rect.left, cells[0].right);
      expect(targets[0].rect.width, 1);
      expect(targets[0].rect.height, built.rows.first.height);
      expect(targets[1].rect.left, cells[1].right);

      // 左外沿仍然不参与拖拽；右外沿可以拖（只改最后一列）。
      final Set<double> edges = targets
          .map((TableChromeTarget t) => t.rect.left)
          .toSet();
      expect(edges, isNot(contains(cells.first.left)));
      expect(edges, contains(cells.last.right));
    });

    test('合并块内部的边界没有手柄，右外沿不受合并影响', () {
      const String text =
          '| <!--nrs c=2-->合并表头 |  |\n'
          '| --- | --- |\n'
          '| a | b |';
      final built = build(text);
      addTearDown(built.blocks.dispose);

      List<int> of(LineBlockView row) => <int>[
        for (final TableChromeTarget t
            in (row as TableRowChrome).chromeTargets())
          if (t.kind == TableChromeKind.resizeColumn) t.index,
      ];

      expect(of(built.rows.first), <int>[1], reason: '表头那一格跨过了内部边界，右外沿还在');
      expect(of(built.rows[1]), <int>[0, 1]);
    });

    test('只有一列的表只剩右外沿可拖', () {
      const String text = '| a |\n| --- |\n| b |';
      final built = build(text);
      addTearDown(built.blocks.dispose);
      expect(
        resizers(built.rows).map((TableChromeTarget t) => t.index),
        <int>[0, 0],
        reason: '两行，各一条外沿',
      );
    });
  });
}
