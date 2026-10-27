import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// 合并单元格的画法与几何。
///
/// 这里只走生产入口 `blockFor`：`chromeCells()` 给出每一列实际占的像素，
/// 覆盖格必须是零宽，跨列锚点必须横跨整块，跨行锚点的文字必须在整块里居中。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const AppPalette palette = AppPalette.midnight;
  const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
  const LineBlockContext context = LineBlockContext(
    contentWidth: 680,
    textScaler: TextScaler.noScaling,
    textDirection: TextDirection.ltr,
  );

  late String text;
  TextSelection? selection;
  late LiveTableBlocks blocks;

  setUp(() {
    selection = const TextSelection.collapsed(offset: -1);
    blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => selection,
    );
  });

  tearDown(() => blocks.dispose());

  List<SourceLine> tableLines() => scanSourceLines(text)
      .where(
        (SourceLine line) =>
            line.kind == LineBlockKind.table ||
            line.kind == LineBlockKind.tableHeader,
      )
      .toList();

  /// Every row block, in document order; the divider has none.
  List<(LineBlockView, TableRowChrome)> rows([
    LineBlockContext ctx = context,
  ]) => <(LineBlockView, TableRowChrome)>[
    for (final SourceLine line in tableLines())
      () {
        final LineBlockView view = blocks.blockFor(line, ctx)!;
        return (view, view as TableRowChrome);
      }(),
  ];

  group('column span', () {
    const String merged =
        '| <!--nrs c=2-->合并 |  |\n'
        '| --- | --- |\n'
        '| aa | b |';

    setUp(() => text = merged);

    test('the anchor takes the whole block, the covered cell none', () {
      final List<(LineBlockView, TableRowChrome)> all = rows();
      final List<Rect> header = all[0].$2.chromeCells();
      final List<Rect> body = all[1].$2.chromeCells();

      expect(header, hasLength(2), reason: '每列一个盒子，覆盖列宽度为零');
      expect(header[0].width, closeTo(body[0].width + body[1].width, 0.01));
      expect(header[1].width, 0);
      expect(header[0].height, all[0].$1.height);
    });

    test('the merged text is centred in the block', () {
      final List<(LineBlockView, TableRowChrome)> all = rows();
      final Rect anchor = all[0].$2.chromeCells().first;
      final Rect leftAligned = all[1].$2.chromeCells().first;
      final TableCell cell = TableBlock.parse(
        merged,
        0,
      )!.bodyRows.first.cells.first;

      final Rect start = all[0].$1.caretRectAt(cell.contentStart);
      final Rect end = all[0].$1.caretRectAt(cell.contentEnd);
      final Rect bodyStart = all[1].$1.caretRectAt(
        TableBlock.parse(merged, 0)!.bodyRows[1].cells.first.contentStart,
      );

      // A left-aligned cell starts at the padding edge; a centred one is
      // pushed in by half the free space, far past that.
      expect(bodyStart.left, lessThan(leftAligned.left + 40));
      expect(start.left, greaterThan(bodyStart.left + 40));
      expect(end.left, greaterThan(start.left));
      expect(end.left, lessThan(anchor.right));
    });

    test('pointing at the covered half lands in the anchor text', () {
      final List<(LineBlockView, TableRowChrome)> all = rows();
      final Rect anchor = all[0].$2.chromeCells().first;
      final TableCell cell = TableBlock.parse(
        merged,
        0,
      )!.bodyRows.first.cells.first;
      final int at = all[0].$1.offsetAt(
        Offset(anchor.right - 4, anchor.height / 2),
      );

      expect(at, inInclusiveRange(cell.start, cell.end));

      final TableCell b = TableBlock.parse(merged, 0)!.bodyRows[1].cells[1];
      final int bodyAt = all[1].$1.offsetAt(
        Offset(all[1].$2.chromeCells()[1].right - 4, 4),
      );
      expect(bodyAt, inInclusiveRange(b.start, b.end));
    });

    test('a caret in the covered cell renders the table unmerged', () {
      final TableBlock block = TableBlock.parse(merged, 0)!;
      final TableCell covered = block.bodyRows.first.cells[1];
      selection = TextSelection.collapsed(offset: covered.start);
      final List<(LineBlockView, TableRowChrome)> all = rows();

      final List<Rect> header = all[0].$2.chromeCells();
      expect(header[0].width, greaterThan(0));
      expect(header[1].width, greaterThan(0));
      expect(header[0].width, closeTo(80, 0.01));
      expect(header[1].width, closeTo(80, 0.01));

      // Leaving the cell restores the merge.
      selection = TextSelection.collapsed(
        offset: block.bodyRows.first.cells.first.contentStart,
      );
      final List<Rect> again = rows()[0].$2.chromeCells();
      expect(again[1].width, 0);
      expect(again[0].width, closeTo(160, 0.01));
    });
  });

  group('row span', () {
    const String merged =
        '| <!--nrs r=2-->合并 | 这是一段很长很长的表头内容它会把表头撑高很多行 |\n'
        '| --- | --- |\n'
        '| c | d |';

    setUp(() => text = merged);

    const LineBlockContext narrow = LineBlockContext(
      contentWidth: 200,
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );

    test('the anchor is vertically centred in the whole block', () {
      final List<(LineBlockView, TableRowChrome)> all = rows(narrow);
      expect(all, hasLength(2));
      final double blockHeight = all[0].$1.height + all[1].$1.height;
      expect(all[0].$1.height, greaterThan(all[1].$1.height));

      final TableCell cell = TableBlock.parse(
        merged,
        0,
      )!.bodyRows.first.cells.first;
      final Rect top = all[0].$1.caretRectAt(cell.contentStart);
      final Rect bottom = all[0].$1.caretRectAt(cell.contentEnd);

      final double above = top.top;
      final double below = blockHeight - (bottom.top + bottom.height);
      expect(above, closeTo(below, 1.5), reason: '单行文字应在整块里居中');
    });

    test('pointing into a covered row still lands in the anchor', () {
      final List<(LineBlockView, TableRowChrome)> all = rows(narrow);
      final TableCell anchor = TableBlock.parse(
        merged,
        0,
      )!.bodyRows.first.cells.first;
      final int at = all[1].$1.offsetAt(const Offset(4, 4));

      expect(at, inInclusiveRange(anchor.start, anchor.end));
    });

    test('a caret in a covered row renders the table unmerged', () {
      final TableBlock block = TableBlock.parse(merged, 0)!;
      final TableCell covered = block.bodyRows[1].cells[0];
      selection = TextSelection.collapsed(offset: covered.start);
      final List<(LineBlockView, TableRowChrome)> all = rows(narrow);

      // The covered cell gets its own column box again, and the rows stop
      // sharing the anchor's height.
      expect(all[1].$2.chromeCells()[0].width, greaterThan(0));
      expect(all[0].$1.height, greaterThan(all[1].$1.height));

      selection = const TextSelection.collapsed(offset: -1);
      final List<(LineBlockView, TableRowChrome)> restored = rows(narrow);
      expect(restored[1].$2.chromeCells()[0].width, 0);
    });
  });

  test('selecting part of a merge washes the whole block', () {
    text =
        '| <!--nrs c=2 r=2-->合并 |  |\n'
        '| --- | --- |\n'
        '|  |  |\n'
        '| z | w |';
    final TableBlock block = TableBlock.parse(text, 0)!;
    final TableCell anchor = block.bodyRows.first.cells.first;
    selection = TextSelection(
      baseOffset: anchor.contentStart,
      extentOffset: anchor.contentStart + 1,
    );
    rows();

    final List<(double, double)?> bands = blocks.debugBandsOfTable(0);
    expect(bands, hasLength(3));
    expect(bands[0], isNotNull);
    expect(bands[1], isNotNull, reason: '合并块覆盖的第二行也是整条色带');
    expect(bands[0]!.$1, 0);
    expect(bands[0]!.$2, closeTo(160, 0.01));
    expect(bands[1]!.$2, closeTo(160, 0.01));
    expect(bands[2], isNull);
  });

  test('an ordinary table keeps one full-width box per column', () {
    text = '| a | b |\n| --- | --- |\n| c | d |';
    final List<(LineBlockView, TableRowChrome)> all = rows();
    for (final (LineBlockView view, TableRowChrome chrome) in all) {
      final List<Rect> cells = chrome.chromeCells();
      expect(cells, hasLength(2));
      expect(cells[0].width, closeTo(80, 0.01));
      expect(cells[1].width, closeTo(80, 0.01));
      expect(view.width, closeTo(160, 0.01));
    }
  });
}
