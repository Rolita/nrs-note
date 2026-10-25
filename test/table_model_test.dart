import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/table_model.dart';

/// The table model's spreadsheet commands: sort, duplicate, transpose,
/// alignment inference and summary rows. They are pure value transforms, so
/// they are tested away from the widget tree.
void main() {
  const String numbers =
      '| 名称 | 数量 |\n'
      '| --- | --- |\n'
      '| 苹果 | 10 |\n'
      '| 香蕉 | 2 |\n'
      '| 橙子 | 30 |';

  TableBlock blockOf(String text) => TableBlock.parse(text, 0)!;

  group('全文表格清单', () {
    test('lists every table in document order, with its own offsets', () {
      const String doc =
          '# 标题\n\n$numbers\n\n一段正文\n\n| 城市 | 人口 |\n| --- | --- |\n| 杭州 | 900 |';
      final List<TableBlock> tables = TableBlock.allIn(doc);

      expect(tables, hasLength(2));
      expect(tables[0].start, doc.indexOf('| 名称'));
      expect(tables[1].start, doc.indexOf('| 城市'));
      expect(tables[0].columns, 2);
      expect(tables[1].bodyRows, hasLength(2));
    });

    test('a table is listed once, not once per row', () {
      expect(TableBlock.allIn(numbers), hasLength(1));
    });

    test('pipe lines inside a fence are code, not tables', () {
      const String doc =
          '```\n| a | b |\n| --- | --- |\n| 1 | 2 |\n```\n\n| 真 | 表 |\n| --- | --- |';
      final List<TableBlock> tables = TableBlock.allIn(doc);
      expect(tables, hasLength(1));
      expect(tables.single.start, doc.indexOf('| 真'));
    });

    test('an empty document has no tables', () {
      expect(TableBlock.allIn(''), isEmpty);
      expect(TableBlock.allIn('只有正文\n没有管子'), isEmpty);
    });
  });

  test('sorts data rows by a numeric column and leaves the header on top', () {
    final TableEditResult out = TableCommands.sortRows(
      blockOf(numbers),
      column: 1,
      ascending: true,
      row: 0,
    )!;
    expect(
      out.text,
      '| 名称 | 数量 |\n'
      '| --- | --- |\n'
      '| 香蕉 | 2 |\n'
      '| 苹果 | 10 |\n'
      '| 橙子 | 30 |',
    );

    final TableEditResult desc = TableCommands.sortRows(
      blockOf(numbers),
      column: 1,
      ascending: false,
      row: 0,
    )!;
    expect(desc.text.split('\n')[2], '| 橙子 | 30 |');
    expect(desc.text.split('\n')[4], '| 香蕉 | 2 |');
  });

  test('empty cells sink in both directions and equal cells stay in order', () {
    const String table =
        '| 名称 | 数量 |\n'
        '| --- | --- |\n'
        '| a | 2 |\n'
        '| b |  |\n'
        '| c | 2 |\n'
        '| d | 1 |';
    for (final bool asc in <bool>[true, false]) {
      final TableEditResult out = TableCommands.sortRows(
        blockOf(table),
        column: 1,
        ascending: asc,
        row: 0,
      )!;
      expect(out.text.endsWith('| b |  |'), isTrue, reason: '空白永远排最后');
      if (asc) {
        expect(out.text, contains('| d | 1 |\n| a | 2 |\n| c | 2 |\n| b |  |'));
      } else {
        expect(out.text, contains('| a | 2 |\n| c | 2 |\n| d | 1 |\n| b |  |'));
      }
    }
    // One data row has nothing to reorder.
    expect(
      TableCommands.sortRows(
        blockOf('| h |\n| --- |\n| 1 |'),
        column: 0,
        ascending: true,
        row: 0,
      ),
      isNull,
    );
  });

  test('duplicates a row below itself and a column to its right', () {
    final TableEditResult row = TableCommands.duplicateRow(
      blockOf(numbers),
      row: 1,
      column: 1,
    );
    expect(
      row.text,
      '| 名称 | 数量 |\n'
      '| --- | --- |\n'
      '| 苹果 | 10 |\n'
      '| 苹果 | 10 |\n'
      '| 香蕉 | 2 |\n'
      '| 橙子 | 30 |',
    );
    // The caret is in the copy, not the original.
    expect(row.selection.baseOffset, greaterThan(row.text.indexOf('苹果 | 10')));

    const String aligned = '| a | b |\n| :--- | ---: |\n| 1 | 2 |';
    final TableEditResult column = TableCommands.duplicateColumn(
      blockOf(aligned),
      row: 1,
      column: 1,
    )!;
    expect(column.text, '| a | b | b |\n| :--- | ---: | ---: |\n| 1 | 2 | 2 |');
  });

  test('transposes the grid and keeps the header role on the first row', () {
    const String table = '| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |';
    final TableEditResult out = TableCommands.transpose(
      blockOf(table),
      row: 1,
      column: 1,
    );
    expect(out.text, '| a | 1 | 3 |\n| --- | --- | --- |\n| b | 2 | 4 |');
    // The cell under the caret keeps its coordinates swapped: old row 1,
    // column 1 held `2`; the caret now sits in front of that same `2`.
    expect(out.text[out.selection.start], '2');
  });

  test(
    'alignment inference turns numeric columns right and leaves the rest',
    () {
      const String table =
          '| 名称 | 数量 | 价格 |\n'
          '| --- | --- | --- |\n'
          '| 苹果 | 10 | ¥1,299 |\n'
          '| 香蕉 | 2 | 9.5 |\n'
          '| 橙子 |  | 30% |';
      final TableEditResult out = TableCommands.autoAlign(
        blockOf(table),
        row: 1,
        column: 0,
      );
      expect(out.text, contains('| --- | ---: | ---: |'));
      expect(out.text, contains('| 名称 | 数量 | 价格 |'));
    },
  );

  test('a summary row lands in the column it totals', () {
    final TableEditResult sum = TableCommands.appendAggregate(
      blockOf(numbers),
      column: 1,
      aggregate: TableAggregate.sum,
    )!;
    expect(
      sum.text,
      '| 名称 | 数量 |\n'
      '| --- | ---: |\n'
      '| 苹果 | 10 |\n'
      '| 香蕉 | 2 |\n'
      '| 橙子 | 30 |\n'
      '| 合计 | 42 |',
    );
    expect(
      sum.text.substring(sum.selection.start, sum.selection.end).trim(),
      '42',
    );

    final TableEditResult average = TableCommands.appendAggregate(
      blockOf(numbers),
      column: 1,
      aggregate: TableAggregate.average,
    )!;
    expect(average.text, contains('| 平均 | 14 |'));

    final TableEditResult count = TableCommands.appendAggregate(
      blockOf(numbers),
      column: 0,
      aggregate: TableAggregate.count,
    )!;
    expect(count.text, contains('| 3 | 计数 |'));

    final TableEditResult max = TableCommands.appendAggregate(
      blockOf(numbers),
      column: 1,
      aggregate: TableAggregate.max,
    )!;
    expect(max.text, contains('| 最大 | 30 |'));

    final TableEditResult min = TableCommands.appendAggregate(
      blockOf(numbers),
      column: 1,
      aggregate: TableAggregate.min,
    )!;
    expect(min.text, contains('| 最小 | 2 |'));

    expect(
      TableCommands.appendAggregate(
        blockOf('| 名称 |\n| --- |\n| 苹果 |'),
        column: 0,
        aggregate: TableAggregate.sum,
      ),
      isNull,
      reason: '没有数字就没有可求的和',
    );
  });

  group('按列去重', () {
    const String duplicates =
        '| 名称 | 数量 |\n'
        '| --- | --- |\n'
        '| 苹果 | 10 |\n'
        '| 香蕉 | 2 |\n'
        '| 苹果 | 30 |\n'
        '|  | 5 |\n'
        '|  | 6 |';

    test('keeps the header and the first of each repeated value', () {
      final TableEditResult out = TableCommands.dedupeColumn(
        blockOf(duplicates),
        column: 0,
        row: 1,
      )!;
      expect(
        out.text,
        '| 名称 | 数量 |\n'
        '| --- | --- |\n'
        '| 苹果 | 10 |\n'
        '| 香蕉 | 2 |\n'
        '|  | 5 |\n'
        '|  | 6 |',
        reason: '第一项留下，空值不算重复',
      );
      // The caret stays in the cell it was in — the surviving 苹果 row.
      expect(
        out.text.substring(
          out.selection.start,
          out.text.indexOf('苹果') + 2,
        ),
        '苹果',
      );
    });

    test('ignores case and surrounding spaces when comparing', () {
      const String table =
          '| 名称 |\n| --- |\n| Apple |\n| apple |\n|  APPLE  |';
      final TableEditResult out = TableCommands.dedupeColumn(
        blockOf(table),
        column: 0,
        row: 1,
      )!;
      expect(out.text, '| 名称 |\n| --- |\n| Apple |');
    });

    test('does not rewrite the text when nothing is repeated', () {
      final TableBlock block = blockOf(numbers);
      final TableEditResult out = TableCommands.dedupeColumn(
        block,
        column: 0,
        row: 1,
      )!;
      expect(out.text, numbers);
      expect(out.selection.start, block.bodyRows[1].cells[0].contentStart);
    });

    test('a single data row has nothing to dedupe', () {
      expect(
        TableCommands.dedupeColumn(
          blockOf('| h |\n| --- |\n| 1 |'),
          column: 0,
          row: 1,
        ),
        isNull,
      );
    });
  });

  test('the selected cells copy as tab-separated values', () {
    final String text = numbers;
    final int from = text.indexOf('苹果');
    final int to = text.indexOf('2', text.indexOf('香蕉')) + 1;
    expect(
      tableSelectionTsv(
        text,
        TextSelection(baseOffset: from, extentOffset: to),
      ),
      '苹果\t10\n香蕉\t2',
    );
    expect(
      tableSelectionTsv(
        text,
        TextSelection(
          baseOffset: text.indexOf('苹果'),
          extentOffset: text.indexOf('苹果') + 2,
        ),
      ),
      isNull,
      reason: '一个格子内是普通文本选择',
    );
  });

  group('a table without a divider', () {
    // The shape the welcome note had for a while: rows only, no `| --- |`.
    // `block.aligns` is a fixed-length filler here, so the column commands used
    // to throw when they inserted or removed an alignment.
    const String headerless =
        '| 想要 | 就写 | 快捷键 |  |\n'
        '| **加粗** | `**文字**` | `Ctrl + B` |  |\n'
        '| *斜体* | `*文字*` | `Ctrl + I` |  |';

    test('column commands keep every row and never throw', () {
      final TableBlock block = blockOf(headerless);
      expect(block.hasHeader, isFalse);

      final TableEditResult inserted = TableCommands.insertColumn(
        block,
        row: 1,
        column: 1,
        right: true,
      );
      expect(inserted.text.split('\n'), hasLength(3));
      expect(
        TableBlock.parse(inserted.text, 0)!
            .bodyRows
            .every((r) => r.cells.length == 5),
        isTrue,
      );

      final TableEditResult removed = TableCommands.deleteColumn(
        block,
        row: 1,
        column: 1,
      )!;
      expect(removed.text.split('\n'), hasLength(3));
      expect(
        TableBlock.parse(removed.text, 0)!
            .bodyRows
            .every((r) => r.cells.length == 3),
        isTrue,
      );

      final TableEditResult duplicated = TableCommands.duplicateColumn(
        block,
        row: 1,
        column: 1,
      )!;
      expect(duplicated.text, contains('| **加粗** | `**文字**` | `**文字**` |'));

      final TableEditResult moved = TableCommands.moveColumn(
        block,
        from: 0,
        to: 1,
        row: 1,
      )!;
      expect(moved.text.split('\n').first, '| 就写 | 想要 | 快捷键 |  |');
    });

    test('an explicit alignment grows the divider that stores it', () {
      final TableEditResult right = TableCommands.setAlign(
        blockOf(headerless),
        row: 1,
        column: 2,
        align: TableAlign.right,
      );
      expect(
        right.text,
        '| 想要 | 就写 | 快捷键 |  |\n'
        '| --- | --- | ---: | --- |\n'
        '| **加粗** | `**文字**` | `Ctrl + B` |  |\n'
        '| *斜体* | `*文字*` | `Ctrl + I` |  |',
      );
      expect(TableBlock.parse(right.text, 0)!.hasHeader, isTrue);

      // 「默认对齐」 asks for no alignment at all, so it must not invent a
      // divider for a table that never had one.
      final TableEditResult none = TableCommands.setAlign(
        blockOf(headerless),
        row: 1,
        column: 2,
        align: TableAlign.none,
      );
      expect(none.text, headerless);
    });

    test('the header switch adds and removes the divider, rows untouched', () {
      // No header yet: the first row becomes the header and a divider appears
      // under it, with the same column count.
      final TableEditResult on = TableCommands.setHeader(
        blockOf(headerless),
        header: true,
        row: 1,
        column: 2,
      );
      expect(
        on.text.split('\n'),
        <String>[
          '| 想要 | 就写 | 快捷键 |  |',
          '| --- | --- | --- | --- |',
          '| **加粗** | `**文字**` | `Ctrl + B` |  |',
          '| *斜体* | `*文字*` | `Ctrl + I` |  |',
        ],
      );
      final TableBlock after = TableBlock.parse(on.text, 0)!;
      expect(after.hasHeader, isTrue);
      // The caret stays in the cell it was in (`Ctrl + B`, column 2 of the row
      // that used to be the first data row).
      expect(after.bodyRows[1].cells[2].text.trim(), '`Ctrl + B`');
      expect(on.selection.start, after.bodyRows[1].cells[2].contentStart);

      // Switching back removes the divider — and therefore the alignment that
      // lives in it — but not a single row.
      final TableEditResult off = TableCommands.setHeader(
        blockOf(on.text),
        header: false,
        row: 2,
        column: 2,
      );
      expect(off.text.split('\n'), hasLength(3));
      expect(TableBlock.parse(off.text, 0)!.hasHeader, isFalse);
      expect(
        TableBlock.parse(off.text, 0)!.aligns,
        everyElement(TableAlign.none),
      );
    });

    test('the header switch is a no-op when already in that state', () {
      final TableBlock block = blockOf(headerless);
      final TableEditResult same = TableCommands.setHeader(
        block,
        header: false,
        row: 0,
        column: 0,
      );
      expect(same.text, headerless, reason: '已是无表头，不应重写空格');
    });

    test('a summary row keeps its right alignment', () {
      final TableEditResult out = TableCommands.appendAggregate(
        blockOf('| a | 1 |\n| b | 2 |'),
        column: 1,
        aggregate: TableAggregate.sum,
      )!;
      expect(
        out.text,
        '| a | 1 |\n'
        '| --- | ---: |\n'
        '| b | 2 |\n'
        '| 合计 | 3 |',
      );
    });
  });

  group('列宽语法', () {
    const String sized =
        '| <!--nrs w=180,240-->指标 | 本周 |\n'
        '| --- | ---: |\n'
        '| 新增 | 42 |';

    test('reads a width list off the first row and hides the directive', () {
      final TableBlock block = blockOf(sized);
      expect(block.columnWidths, <int>[180, 240]);
      expect(block.bodyRows.first.cells.first.text, '指标');
      expect(block.bodyRows.first.cells.first.hasDirective, isTrue);
    });

    test('no directive means automatic widths', () {
      expect(blockOf(numbers).columnWidths, isNull);
    });

    test('a list that is not one positive integer per column is ignored', () {
      for (final String widths in <String>[
        '180',
        '180,240,120',
        '180,0',
        '180,-240',
        '180,abc',
        '180,2.5',
      ]) {
        final TableBlock block = blockOf(
          '| <!--nrs w=$widths-->指标 | 本周 |\n'
          '| --- | ---: |\n'
          '| 新增 | 42 |',
        );
        expect(block.columnWidths, isNull, reason: widths);
      }
    });

    test('the first duplicate w wins and unknown keys do not interfere', () {
      final TableBlock block = blockOf(
        '| <!--nrs foo=1 w=180,240 w=300,400-->指标 | 本周 |\n'
        '| --- | ---: |\n'
        '| 新增 | 42 |',
      );
      expect(block.columnWidths, <int>[180, 240]);
    });

    test('rendering a grid writes the widths into the first row', () {
      final TableGrid grid = TableGrid.fromBlock(blockOf(sized));
      expect(grid.widths, <int>[180, 240]);
      expect(grid.render(), sized);
    });

    test('a new table has no manual widths', () {
      final TextEditingValue out = insertTable()(
        const TextEditingValue(selection: TextSelection.collapsed(offset: 0)),
      );
      expect(out.text, isNot(contains('w=')));
    });
  });

  group('列宽与结构命令', () {
    const String sized =
        '| <!--nrs w=180,240-->指标 | 本周 |\n'
        '| --- | ---: |\n'
        '| 新增 | 42 |';
    TableBlock sizedBlock() => blockOf(sized);

    test('inserting a column copies its neighbour and keeps the count', () {
      final TableEditResult right = TableCommands.insertColumn(
        sizedBlock(),
        row: 0,
        column: 0,
        right: true,
      );
      expect(right.text.split('\n').first, contains('w=180,180,240'));

      final TableEditResult left = TableCommands.insertColumn(
        sizedBlock(),
        row: 0,
        column: 0,
        right: false,
      );
      expect(left.text.split('\n').first, contains('w=180,180,240'));
    });

    test('deleting and moving a column move their width with it', () {
      final TableEditResult deleted = TableCommands.deleteColumn(
        sizedBlock(),
        row: 0,
        column: 0,
      )!;
      expect(deleted.text.split('\n').first, contains('w=240'));

      final TableEditResult moved = TableCommands.moveColumn(
        sizedBlock(),
        from: 0,
        to: 1,
        row: 0,
      )!;
      expect(moved.text.split('\n').first, contains('w=240,180'));
    });

    test('duplicating, clearing and inserting rows keep the widths', () {
      final TableEditResult duplicated = TableCommands.duplicateColumn(
        sizedBlock(),
        row: 0,
        column: 0,
      )!;
      expect(duplicated.text.split('\n').first, contains('w=180,180,240'));

      final TableEditResult cleared = TableCommands.clearRect(
        sizedBlock(),
        fromRow: 1,
        toRow: 1,
        fromColumn: 0,
        toColumn: 1,
      );
      expect(cleared.text.split('\n').first, contains('w=180,240'));

      final TableEditResult rowAdded = TableCommands.insertRow(
        sizedBlock(),
        row: 0,
        above: true,
      );
      expect(rowAdded.text.split('\n').first, contains('w=180,240'));
    });

    test('transposing drops the widths', () {
      final TableEditResult out = TableCommands.transpose(
        sizedBlock(),
        row: 0,
        column: 0,
      );
      expect(out.text, isNot(contains('w=')));
    });
  });

  group('resizeTableColumns', () {
    const String plain =
        '| 指标 | 本周 |\n'
        '| --- | ---: |\n'
        '| 新增 | 42 |';

    test('inserts a directive before the first cell and shifts the caret', () {
      final int caret = plain.indexOf('42') + 2;
      final TextEditingValue out = resizeTableColumns(
        TextEditingValue(
          text: plain,
          selection: TextSelection.collapsed(offset: caret),
        ),
        tableId: 0,
        widths: <int>[180, 240],
      )!;
      expect(
        out.text,
        '| <!--nrs w=180,240-->指标 | 本周 |\n'
        '| --- | ---: |\n'
        '| 新增 | 42 |',
      );
      expect(out.selection.start, caret + '<!--nrs w=180,240-->'.length);
      expect(out.composing, TextRange.empty);
    });

    test('rebuilds the directive in c r bg fg w order, keeping extras', () {
      const String formatted =
          '| <!--nrs c=2 bg=amber foo=1 w=180,240-->标题 |  |\n'
          '| --- | --- |\n'
          '| 一 | 二 |';
      final TextEditingValue out = resizeTableColumns(
        const TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: 0),
        ),
        tableId: 0,
        widths: <int>[200, 260],
      )!;
      expect(
        out.text.split('\n').first,
        '| <!--nrs c=2 bg=amber w=200,260 foo=1-->标题 |  |',
      );
      expect(out.selection.start, 0);
    });

    test('does nothing when the widths are already the stored ones', () {
      const String sized =
          '| <!--nrs w=180,240-->指标 | 本周 |\n'
          '| --- | ---: |\n'
          '| 新增 | 42 |';
      expect(
        resizeTableColumns(
          const TextEditingValue(
            text: sized,
            selection: TextSelection.collapsed(offset: 0),
          ),
          tableId: 0,
          widths: <int>[180, 240],
        ),
        isNull,
      );
    });

    test('rejects the wrong count and non-positive widths', () {
      const TextEditingValue raw = TextEditingValue(
        text: plain,
        selection: TextSelection.collapsed(offset: 0),
      );
      expect(
        resizeTableColumns(raw, tableId: 0, widths: <int>[180]),
        isNull,
      );
      expect(
        resizeTableColumns(raw, tableId: 0, widths: <int>[180, 0]),
        isNull,
      );
    });

    test('maps selections on both sides of the new directive', () {
      const String doc = '前文\n$plain\n后文';
      final int table = doc.indexOf('| 指标');
      final int after = doc.indexOf('后文');

      final TextEditingValue before = resizeTableColumns(
        TextEditingValue(
          text: doc,
          selection: const TextSelection.collapsed(offset: 1),
        ),
        tableId: table,
        widths: <int>[180, 240],
      )!;
      expect(before.selection.start, 1);

      final TextEditingValue afterEdit = resizeTableColumns(
        TextEditingValue(
          text: doc,
          selection: TextSelection(
            baseOffset: table,
            extentOffset: after,
          ),
        ),
        tableId: table,
        widths: <int>[180, 240],
      )!;
      expect(afterEdit.selection.baseOffset, table);
      expect(
        afterEdit.selection.extentOffset,
        after + '<!--nrs w=180,240-->'.length,
      );
    });
  });

  group('clearTableColumnWidths', () {
    test('removes the whole directive when w was all it carried', () {
      const String sized =
          '| <!--nrs w=180,240-->指标 | 本周 |\n'
          '| --- | ---: |\n'
          '| 新增 | 42 |';
      final TextEditingValue out = clearTableColumnWidths(
        const TextEditingValue(
          text: sized,
          selection: TextSelection.collapsed(offset: 0),
        ),
        tableId: 0,
      )!;
      expect(out.text.split('\n').first, '| 指标 | 本周 |');
      expect(out.text, isNot(contains('nrs')));
    });

    test('keeps spans, colors and keys this app does not own', () {
      const String formatted =
          '| <!--nrs c=2 bg=amber foo=1 w=180,240-->标题 |  |\n'
          '| --- | --- |\n'
          '| 一 | 二 |';
      final TextEditingValue out = clearTableColumnWidths(
        const TextEditingValue(
          text: formatted,
          selection: TextSelection.collapsed(offset: 0),
        ),
        tableId: 0,
      )!;
      expect(
        out.text.split('\n').first,
        '| <!--nrs c=2 bg=amber foo=1-->标题 |  |',
      );
    });

    test('is a no-op on a table that is already auto-sized', () {
      expect(
        clearTableColumnWidths(
          const TextEditingValue(
            text: '| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |',
            selection: TextSelection.collapsed(offset: 0),
          ),
          tableId: 0,
        ),
        isNull,
      );
    });
  });
}
