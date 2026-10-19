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
}
