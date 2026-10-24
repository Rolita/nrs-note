import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/core/utils/table_selection.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// The formatting half of the table model: the hidden directive, spans and
/// colors. The rules are checked on the grid, away from the widget tree.
void main() {
  TableBlock blockOf(String text) => TableBlock.parse(text, 0)!;

  TableGrid gridOf(String text) => TableGrid.fromBlock(blockOf(text));

  List<List<String>> textsOf(TableGrid grid) => <List<String>>[
    for (final List<GridCell> row in grid.rows)
      <String>[for (final GridCell cell in row) cell.text],
  ];

  group('directive syntax', () {
    test('reads spans and theme colors from the leading comment', () {
      const String text =
          '| <!--nrs c=2 r=2 bg=amber fg=red-->年度汇总 |  |  |\n'
          '| --- | --- | --- |\n'
          '| 华东 | 12 | 8 |\n'
          '| 华南 | 9 | 7 |';
      final TableCell cell = blockOf(text).bodyRows.first.cells.first;

      expect(cell.hasDirective, isTrue);
      expect(cell.text, '年度汇总');
      expect(cell.style.columnSpan, 2);
      expect(cell.style.rowSpan, 2);
      expect(cell.style.fill, const CellColor.token(CellColorToken.amber));
      expect(cell.style.text, const CellColor.token(CellColorToken.red));
      expect(cell.contentStart, text.indexOf('年度'));
      expect(
        cell.directiveStart,
        text.indexOf('<!--nrs'),
        reason: '指令从单元格里的前导空格之后开始',
      );
      expect(cell.isEmpty, isFalse);
      expect(gridOf(text).merges.single.rowSpan, 2);
    });

    test('accepts leading padding and custom colors', () {
      const String text =
          '|   <!--nrs bg=#8012ab34 fg=#ff0000--> x   |\n'
          '| --- |';
      final TableCell cell = blockOf(text).bodyRows.first.cells.first;

      expect(cell.text, 'x');
      expect(cell.contentStart, text.indexOf('x'));
      expect(cell.contentEnd, text.indexOf('x') + 1);
      expect(cell.style.fill, CellColor.custom(0x8012AB34));
      expect(cell.style.text, CellColor.custom(0xFFFF0000));
      expect(cell.style.fill!.source, '#8012AB34');
      expect(cell.style.text!.source, '#FF0000');
    });

    test('ignores invalid spans and unknown color names, still hiding it', () {
      const String text =
          '| <!--nrs c=1 r=x bg=chartreuse fg=blue-->a |\n'
          '| --- |';
      final TableCell cell = blockOf(text).bodyRows.first.cells.first;

      expect(cell.text, 'a');
      expect(cell.style.spans, isFalse);
      expect(cell.style.fill, isNull);
      expect(cell.style.text, const CellColor.token(CellColorToken.blue));
      expect(gridOf(text).merges, isEmpty);
    });

    test('unknown keys are ignored, not shown', () {
      const String text =
          '| <!--nrs c=2 zz=9 bg=green-->a |  |\n'
          '| --- | --- |';
      final TableCell cell = blockOf(text).bodyRows.first.cells.first;

      expect(cell.text, 'a');
      expect(cell.style.columnSpan, 2);
      expect(cell.style.fill, const CellColor.token(CellColorToken.green));
      expect(gridOf(text).render().contains('zz='), isFalse);
    });

    test('a directive in the middle of a cell is ordinary text', () {
      const String text =
          '| a <!--nrs c=2--> | b |\n'
          '| --- | --- |';
      final TableCell cell = blockOf(text).bodyRows.first.cells.first;

      expect(cell.hasDirective, isFalse);
      expect(cell.text, 'a <!--nrs c=2-->');
      expect(tableCellDisplay(cell.raw), cell.raw);
    });

    test('an unclosed comment is ordinary text', () {
      const String text =
          '| <!--nrs c=2 | b |\n'
          '| --- | --- |';
      final TableCell cell = blockOf(text).bodyRows.first.cells.first;

      expect(cell.hasDirective, isFalse);
      expect(cell.text, '<!--nrs c=2');
    });

    test('a directive-only cell is empty but keeps its caret outside it', () {
      const String text =
          '| <!--nrs bg=red-->   | b |\n'
          '| --- | --- |';
      final TableCell cell = blockOf(text).bodyRows.first.cells.first;

      expect(cell.text, '');
      expect(cell.isEmpty, isTrue);
      expect(cell.hasDirective, isTrue);
      expect(cell.contentStart, greaterThanOrEqualTo(cell.directiveEnd!));
      expect(cell.contentEnd, cell.contentStart);
      expect(cell.style.fill, const CellColor.token(CellColorToken.red));
    });

    test('ordinary tables render without a directive', () {
      final String rendered = gridOf('| a | b |\n| --- | --- |').render();
      expect(rendered, '| a | b |\n| --- | --- |');
      expect(rendered.contains('<!--'), isFalse);
    });

    test('renders keys in a fixed order and round-trips the style', () {
      const TableCellStyle style = TableCellStyle(
        columnSpan: 2,
        rowSpan: 3,
        fill: CellColor.token(CellColorToken.purple),
        text: CellColor.custom(0xFF123456),
      );
      expect(
        style.directive,
        '<!--nrs c=2 r=3 bg=purple fg=#123456-->',
      );

      final TableCell? cell = TableBlock.parse(
        '| ${style.directive}a |  |\n| --- | --- |',
        0,
      )
          ?.bodyRows.first.cells.first;
      expect(cell?.style, style);
      expect(cell?.text, 'a');
    });

    test('display masks the directive without changing the source length', () {
      const String raw = r' <!--nrs bg=amber-->a \| b<br>c';
      final String display = tableCellDisplay(raw);

      expect(display.length, raw.length);
      expect(display.replaceAll('\u200b', ''), ' a | b↵c');
      expect(display.contains('nrs'), isFalse);
    });
  });

  group('merge and split', () {
    const String twoByTwo = '| 指标 | 本周 |\n| 新增 | 42 |';

    test('moves every visible text into the anchor, row-major', () {
      final TableEditResult result = TableCommands.mergeCells(
        blockOf(twoByTwo),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      )!;
      final TableGrid grid = gridOf(result.text);

      expect(textsOf(grid), <List<String>>[
        <String>['指标\n本周\n新增\n42', ''],
        <String>['', ''],
      ]);
      final TableMerge merge = grid.merges.single;
      expect((merge.row, merge.column), (0, 0));
      expect((merge.rowSpan, merge.columnSpan), (2, 2));
      expect(grid.rows[0][0].style.fill, isNull);
      expect(result.text, contains('<!--nrs c=2 r=2-->'));
      expect(result.text, contains('指标<br>本周<br>新增<br>42'));
    });

    test('keeps the anchor colors and clears covered formatting', () {
      const String text =
          '| <!--nrs bg=blue-->a | <!--nrs bg=red-->b |\n'
          '| c | d |';
      final TableEditResult result = TableCommands.mergeCells(
        blockOf(text),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      )!;
      final TableGrid grid = gridOf(result.text);

      expect(grid.rows[0][0].style.fill, const CellColor.token(CellColorToken.blue));
      expect(grid.rows[0][0].style.columnSpan, 2);
      expect(grid.rows[0][1].style.isEmpty, isTrue);
      expect(grid.rows[1][0].style.isEmpty, isTrue);
      expect(grid.rows[1][1].style.isEmpty, isTrue);
      expect(textsOf(grid), <List<String>>[
        <String>['a\nb\nc\nd', ''],
        <String>['', ''],
      ]);
    });

    test('refuses a single cell, overlapping merges and out-of-bounds', () {
      final TableBlock block = blockOf(twoByTwo);
      expect(
        TableCommands.mergeCells(
          block,
          fromRow: 0,
          toRow: 0,
          fromColumn: 0,
          toColumn: 0,
        ),
        isNull,
      );
      expect(
        TableCommands.mergeCells(
          block,
          fromRow: 0,
          toRow: 2,
          fromColumn: 0,
          toColumn: 1,
        ),
        isNull,
      );

      final String merged = TableCommands.mergeCells(
        block,
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      )!.text;
      final TableBlock again = blockOf(merged);
      expect(
        TableCommands.mergeCells(
          again,
          fromRow: 0,
          toRow: 0,
          fromColumn: 1,
          toColumn: 1,
        ),
        isNull,
        reason: '部分重叠不允许',
      );
      expect(
        TableCommands.mergeCells(
          again,
          fromRow: 0,
          toRow: 1,
          fromColumn: 0,
          toColumn: 1,
        ),
        isNull,
        reason: '完整覆盖也不叠加',
      );
    });

    test('split keeps the moved text in the anchor and removes the spans', () {
      final String merged = TableCommands.mergeCells(
        blockOf(twoByTwo),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      )!.text;
      final TableEditResult split = TableCommands.splitCell(
        blockOf(merged),
        row: 1,
        column: 1,
      )!;
      final TableGrid grid = gridOf(split.text);

      expect(grid.merges, isEmpty);
      expect(grid.rows[0][0].text, '指标\n本周\n新增\n42');
      expect(split.text.contains('<!--nrs'), isFalse);
      expect(
        TableCommands.splitCell(blockOf(twoByTwo), row: 0, column: 0),
        isNull,
      );
    });
  });

  group('structural rules', () {
    const String rowSpan =
        '| a | b |\n'
        '| <!--nrs r=2 bg=amber-->c | d |\n'
        '| e | f |';

    test('inserting inside a row span grows it; boundaries do not', () {
      final TableEditResult inside = TableCommands.insertRow(
        blockOf(rowSpan),
        row: 1,
        above: false,
      );
      final TableGrid grown = gridOf(inside.text);
      expect(grown.merges.single.row, 1);
      expect(grown.merges.single.rowSpan, 3);
      expect(grown.rows[1][0].style.fill, const CellColor.token(CellColorToken.amber));

      final TableGrid above = gridOf(
        TableCommands.insertRow(blockOf(rowSpan), row: 1, above: true).text,
      );
      expect(above.merges.single.row, 2);
      expect(above.merges.single.rowSpan, 2);

      final TableGrid below = gridOf(
        TableCommands.insertRow(blockOf(rowSpan), row: 2, above: false).text,
      );
      expect(below.merges.single.row, 1);
      expect(below.merges.single.rowSpan, 2);
    });

    test('deleting a covered row shrinks the span; the anchor keeps color', () {
      final TableEditResult result = TableCommands.deleteRow(
        blockOf(rowSpan),
        2,
      );
      final TableGrid grid = gridOf(result.text);

      expect(grid.merges, isEmpty);
      expect(grid.rows[1][0].text, 'c');
      expect(grid.rows[1][0].style.fill, const CellColor.token(CellColorToken.amber));
      expect(result.text, contains('<!--nrs bg=amber-->'));
      expect(result.text.contains('r='), isFalse);
    });

    test('deleting the anchor deletes the merge', () {
      final TableGrid grid = gridOf(
        TableCommands.deleteRow(blockOf(rowSpan), 1).text,
      );
      expect(grid.merges, isEmpty);
      expect(grid.rows.map((List<GridCell> r) => r[0].text), <String>['a', 'e']);
    });

    test('deleting above moves the merge intact', () {
      final TableGrid grid = gridOf(
        TableCommands.deleteRow(blockOf(rowSpan), 0).text,
      );
      expect(grid.merges.single.row, 0);
      expect(grid.merges.single.rowSpan, 2);
      expect(grid.rows[0][0].style.fill, const CellColor.token(CellColorToken.amber));
    });

    test('column insertion and deletion follow the same span rules', () {
      const String columnSpan =
          '| <!--nrs c=2-->a | b |\n'
          '| c | d |';
      final TableGrid inserted = gridOf(
        TableCommands.insertColumn(
          blockOf(columnSpan),
          row: 1,
          column: 1,
          right: false,
        ).text,
      );
      expect(inserted.merges.single.columnSpan, 3);
      expect(inserted.merges.single.column, 0);

      final TableGrid boundary = gridOf(
        TableCommands.insertColumn(
          blockOf(columnSpan),
          row: 1,
          column: 1,
          right: true,
        ).text,
      );
      expect(boundary.merges.single.columnSpan, 2);

      final TableGrid shrunk = gridOf(
        TableCommands.deleteColumn(blockOf(columnSpan), row: 1, column: 1)!.text,
      );
      expect(shrunk.merges, isEmpty);
      expect(shrunk.rows[0][0].text, 'a');
    });

    test('moving rows and columns drops merges but keeps colors', () {
      final TableEditResult moved = TableCommands.moveRow(
        blockOf(rowSpan),
        from: 2,
        to: 0,
        column: 0,
      )!;
      final TableGrid grid = gridOf(moved.text);
      expect(grid.merges, isEmpty);
      expect(moved.text, contains('bg=amber'));
      expect(moved.text.contains('c='), isFalse);
      expect(moved.text.contains('r='), isFalse);
      expect(
        grid.rows.expand((List<GridCell> r) => r).where(
          (GridCell c) => c.style.fill == const CellColor.token(CellColorToken.amber),
        ),
        hasLength(1),
      );
    });

    test('sort drops merges and carries colors with the row', () {
      const String text =
          '| b | 2 |\n'
          '| <!--nrs r=2 bg=amber-->a | 1 |\n'
          '| c | 3 |';
      final TableEditResult sorted = TableCommands.sortRows(
        blockOf(text),
        column: 1,
        ascending: true,
        row: 0,
      )!;
      final TableGrid grid = gridOf(sorted.text);
      expect(grid.merges, isEmpty);
      expect(grid.rows[0][0].text, 'a');
      expect(grid.rows[0][0].style.fill, const CellColor.token(CellColorToken.amber));
      expect(sorted.text, contains('bg=amber'));
    });

    test('duplicate rows keeps colors and drops spans', () {
      final TableEditResult duplicated = TableCommands.duplicateRow(
        blockOf(rowSpan),
        row: 1,
        column: 0,
      );
      final TableGrid grid = gridOf(duplicated.text);
      expect(grid.merges, isEmpty);
      expect(
        grid.rows.where(
          (List<GridCell> r) =>
              r[0].style.fill == const CellColor.token(CellColorToken.amber),
        ),
        hasLength(2),
      );
    });

    test('transpose moves each cell color to its transposed slot', () {
      const String text =
          '| a | b |\n'
          '| <!--nrs bg=amber-->c | d |';
      final TableEditResult result = TableCommands.transpose(
        blockOf(text),
        row: 1,
        column: 0,
      );
      final TableGrid grid = gridOf(result.text);
      expect(grid.merges, isEmpty);
      expect(grid.rows[0][1].text, 'c');
      expect(
        grid.rows[0][1].style.fill,
        const CellColor.token(CellColorToken.amber),
      );
    });
  });

  group('cell colors', () {
    const String plain = '| a | b |\n| c | d |';

    test('sets and clears one channel over a range', () {
      final TableEditResult filled = TableCommands.setCellColor(
        blockOf(plain),
        fromRow: 0,
        toRow: 0,
        fromColumn: 0,
        toColumn: 1,
        channel: TableCellColorChannel.fill,
        color: const CellColor.token(CellColorToken.amber),
      );
      expect(
        filled.text,
        '| <!--nrs bg=amber-->a | <!--nrs bg=amber-->b |\n| c | d |',
      );

      final TableEditResult text = TableCommands.setCellColor(
        blockOf(filled.text),
        fromRow: 0,
        toRow: 0,
        fromColumn: 0,
        toColumn: 0,
        channel: TableCellColorChannel.text,
        color: const CellColor.token(CellColorToken.red),
      );
      expect(text.text, contains('bg=amber fg=red'));

      final TableEditResult cleared = TableCommands.setCellColor(
        blockOf(text.text),
        fromRow: 0,
        toRow: 0,
        fromColumn: 0,
        toColumn: 0,
        channel: TableCellColorChannel.fill,
        color: null,
      );
      final TableGrid grid = gridOf(cleared.text);
      expect(cleared.text, contains('<!--nrs fg=red-->a'));
      expect(grid.rows[0][0].style.fill, isNull);
      expect(
        grid.rows[0][1].style.fill,
        const CellColor.token(CellColorToken.amber),
        reason: '清空只作用于选中的那一格',
      );
    });

    test('custom colors round-trip through the source', () {
      final CellColor color = CellColor.parse('#8012AB34')!;
      final TableEditResult result = TableCommands.setCellColor(
        blockOf(plain),
        fromRow: 0,
        toRow: 0,
        fromColumn: 0,
        toColumn: 0,
        channel: TableCellColorChannel.fill,
        color: color,
      );
      expect(result.text, contains('bg=#8012AB34'));
      expect(
        gridOf(result.text).rows[0][0].style.fill,
        color,
      );
    });

    test('a merged block is painted through its anchor only', () {
      final String merged = TableCommands.mergeCells(
        blockOf(plain),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      )!.text;
      final TableEditResult colored = TableCommands.setCellColor(
        blockOf(merged),
        fromRow: 0,
        toRow: 0,
        fromColumn: 1,
        toColumn: 1,
        channel: TableCellColorChannel.fill,
        color: const CellColor.token(CellColorToken.green),
      );
      final TableGrid grid = gridOf(colored.text);
      expect(grid.merges.single.rowSpan, 2);
      expect(
        grid.rows[0][0].style.fill,
        const CellColor.token(CellColorToken.green),
      );
      expect(grid.rows[0][1].style.fill, isNull);
      expect(
        TableCommands.cellColor(
          blockOf(colored.text),
          row: 1,
          column: 1,
          channel: TableCellColorChannel.fill,
        ),
        const CellColor.token(CellColorToken.green),
        reason: '覆盖格读回的是锚点颜色',
      );
    });

    test('clearing a rectangle clears the whole merged block, keeping spans', () {
      final String merged = TableCommands.mergeCells(
        blockOf(plain),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      )!.text;
      final String colored = TableCommands.setCellColor(
        blockOf(merged),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
        channel: TableCellColorChannel.fill,
        color: const CellColor.token(CellColorToken.blue),
      ).text;
      final TableEditResult cleared = TableCommands.clearRect(
        blockOf(colored),
        fromRow: 1,
        toRow: 1,
        fromColumn: 1,
        toColumn: 1,
      );
      final TableGrid grid = gridOf(cleared.text);
      expect(grid.merges.single.rowSpan, 2);
      expect(grid.rows[0][0].text, '');
      expect(
        grid.rows[0][0].style.fill,
        const CellColor.token(CellColorToken.blue),
      );
      expect(cleared.text.contains('<!--nrs c=2 r=2 bg=blue-->'), isTrue);

      final TableRange range = TableRange.rect(
        blockOf(cleared.text),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      );
      final TableCell anchor = blockOf(cleared.text).bodyRows[0].cells[0];
      final TextSelection selection = range.toTextSelection();
      expect(selection.start, greaterThanOrEqualTo(anchor.directiveEnd!));
      expect(
        selection.textInside(cleared.text).contains('nrs'),
        isFalse,
        reason: '空格式格的选区不能包含隐藏指令',
      );
    });
  });

  group('writes', () {
    late String merged;

    setUp(() {
      merged = TableCommands.mergeCells(
        blockOf('| a | b |\n| c | d |'),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      )!.text;
    });

    test('a single write in the anchor keeps the merge', () {
      final TableEditResult result = TableCommands.writeRect(
        blockOf(merged),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
        atRow: 0,
        atColumn: 0,
        values: <List<String>>[
          <String>['X'],
        ],
      );
      final TableGrid grid = gridOf(result.text);
      expect(grid.merges.single.rowSpan, 2);
      expect(grid.rows[0][0].text, 'X');
    });

    test('a multi-cell write splits every merge it touches, keeping color', () {
      final String colored = TableCommands.setCellColor(
        blockOf(merged),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
        channel: TableCellColorChannel.fill,
        color: const CellColor.token(CellColorToken.amber),
      ).text;
      final TableEditResult written = TableCommands.writeRect(
        blockOf(colored),
        fromRow: 0,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
        atRow: 0,
        atColumn: 0,
        values: <List<String>>[
          <String>['1', '2'],
          <String>['3', '4'],
        ],
      );
      final TableGrid grid = gridOf(written.text);
      expect(grid.merges, isEmpty);
      expect(textsOf(grid), <List<String>>[
        <String>['1', '2'],
        <String>['3', '4'],
      ]);
      expect(grid.rows[0][0].style.fill, const CellColor.token(CellColorToken.amber));
    });

    test('writing into a covered cell splits the merge', () {
      final TableEditResult written = TableCommands.writeRect(
        blockOf(merged),
        fromRow: 0,
        toRow: 0,
        fromColumn: 1,
        toColumn: 1,
        atRow: 0,
        atColumn: 1,
        values: <List<String>>[
          <String>['X'],
        ],
      );
      final TableGrid grid = gridOf(written.text);
      expect(grid.merges, isEmpty);
      expect(grid.rows[0][1].text, 'X');
      expect(grid.rows[0][0].text, 'a\nb\nc\nd');
    });

    test('writing keeps the destination cell colors', () {
      final String colored = TableCommands.setCellColor(
        blockOf('| a | b |\n| c | d |'),
        fromRow: 0,
        toRow: 0,
        fromColumn: 0,
        toColumn: 0,
        channel: TableCellColorChannel.fill,
        color: const CellColor.token(CellColorToken.purple),
      ).text;
      final TableEditResult written = TableCommands.writeRect(
        blockOf(colored),
        fromRow: 0,
        toRow: 0,
        fromColumn: 0,
        toColumn: 0,
        atRow: 0,
        atColumn: 0,
        values: <List<String>>[
          <String>['X'],
        ],
      );
      expect(
        gridOf(written.text).rows[0][0].style.fill,
        const CellColor.token(CellColorToken.purple),
      );
      expect(written.text, contains('<!--nrs bg=purple-->X'));
    });

    test('the F2 commit preserves the cell directive', () {
      final String colored = TableCommands.setCellColor(
        blockOf('| a | b |\n| c | d |'),
        fromRow: 0,
        toRow: 0,
        fromColumn: 0,
        toColumn: 0,
        channel: TableCellColorChannel.fill,
        color: const CellColor.token(CellColorToken.amber),
      ).text;
      final TextEditingValue? value = setTableCellText(
        TextEditingValue(
          text: colored,
          selection: const TextSelection.collapsed(offset: 0),
        ),
        tableStart: 0,
        row: 0,
        column: 0,
        text: 'X',
      );
      expect(value, isNotNull);
      expect(value!.text, contains('<!--nrs bg=amber-->X'));
    });
  });
}
