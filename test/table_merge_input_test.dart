import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/table_model.dart';

/// Keyboard movement over merged tables: a merge is **one** cell. Tab, the
/// arrows and Home/End step over every covered cell, and the escape hatch — a
/// caret that got into a covered cell from outside the keyboard — moves through
/// that cell as the unmerged table the user is looking at.
void main() {
  TextEditingValue value(String text, int offset) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: offset),
  );

  TableCell cellAt(String text, int row, int column) =>
      TableBlock.parse(text, 0)!.bodyRows[row].cells[column];

  group('column span', () {
    // The covered cell holds text on purpose: that is the source the escape
    // hatch has to give back.
    const String table =
        '| <!--nrs c=2-->合并 | 隐藏 |\n'
        '| --- | --- |\n'
        '| a | b |';

    test('Tab leaves the merge as one cell, skipping the covered one', () {
      final TableCell anchor = cellAt(table, 0, 0);
      final TextEditingValue next = tableCellStep(
        value(table, anchor.contentEnd),
        forward: true,
      )!;
      expect(table.substring(next.selection.start, next.selection.end), 'a');

      final TextEditingValue back = tableCellStep(next, forward: false)!;
      expect(table.substring(back.selection.start, back.selection.end), '合并');
    });

    test('Home and End stay on the anchor text', () {
      final TableCell anchor = cellAt(table, 0, 0);
      final TextEditingValue home = tableCaretToCellEdge(
        value(table, anchor.contentStart + 1),
        end: false,
      )!;
      expect(home.selection.start, anchor.contentStart);
      final TextEditingValue end = tableCaretToCellEdge(
        value(table, anchor.contentStart + 1),
        end: true,
      )!;
      expect(end.selection.start, anchor.contentEnd);
    });

    test('Left / Right step over the whole block', () {
      final TableCell anchor = cellAt(table, 0, 0);
      final TextEditingValue right = tableCaretStepCell(
        value(table, anchor.contentEnd),
        forward: true,
      )!;
      expect(right.selection.start, cellAt(table, 1, 0).contentStart);

      final TextEditingValue left = tableCaretStepCell(
        value(table, cellAt(table, 1, 0).contentStart),
        forward: false,
      )!;
      expect(left.selection.start, anchor.contentEnd);

      expect(
        tableCaretStepCell(
          value(table, anchor.contentStart + 1),
          forward: true,
        ),
        isNull,
        reason: '格内移动交给输入框',
      );
    });

    test('the escape hatch moves through the covered cell itself', () {
      final TableCell hidden = cellAt(table, 0, 1);
      final TextEditingValue home = tableCaretToCellEdge(
        value(table, hidden.contentStart + 1),
        end: false,
      )!;
      expect(home.selection.start, hidden.contentStart);

      final TextEditingValue left = tableCaretStepCell(
        value(table, hidden.contentStart),
        forward: false,
      )!;
      expect(
        left.selection.start,
        cellAt(table, 0, 0).contentEnd,
        reason: '向前一格是屏幕上左边那一格',
      );
    });
  });

  group('row span', () {
    const String table =
        '| a | b |\n'
        '| --- | --- |\n'
        '| <!--nrs r=2-->c | d |\n'
        '| e | f |\n'
        '| g | h |';

    test('Down / Up leave the block, not the row', () {
      final TextEditingValue down = tableCaretVertical(
        value(table, cellAt(table, 1, 0).contentStart),
        down: true,
      )!;
      expect(down.selection.start, cellAt(table, 3, 0).contentStart);
      expect(cellAt(table, 3, 0).text, 'g');

      // The next column is ordinary: one row down is one line down.
      final TextEditingValue plainDown = tableCaretVertical(
        value(table, cellAt(table, 1, 1).contentStart),
        down: true,
      )!;
      expect(plainDown.selection.start, cellAt(table, 2, 1).contentStart);
      expect(cellAt(table, 2, 1).text, 'f');

      final TextEditingValue up = tableCaretVertical(
        value(table, cellAt(table, 2, 1).contentStart),
        down: false,
      )!;
      expect(up.selection.start, cellAt(table, 1, 1).contentStart);
      expect(cellAt(table, 1, 1).text, 'd');
    });

    test('a block that reaches the table edge consumes the key', () {
      const String edge =
          '| a | b |\n'
          '| --- | --- |\n'
          '| <!--nrs r=2-->c | d |\n'
          '| e | f |';
      final TableCell anchor = cellAt(edge, 1, 0);
      final TextEditingValue? down = tableCaretVertical(
        value(edge, anchor.contentStart),
        down: true,
      );
      expect(down, isNotNull, reason: '不能用原生行移动落进覆盖格');
      expect(down!.selection.start, anchor.contentStart);

      final TextEditingValue up = tableCaretVertical(
        value(edge, anchor.contentStart),
        down: false,
      )!;
      expect(up.selection.start, cellAt(edge, 0, 0).contentStart);
      expect(cellAt(edge, 0, 0).text, 'a');
    });

    test('moving up into a covered row lands on the anchor', () {
      // Row 3 sits directly below the block: its left cell maps to the anchor
      // even though the raw row above is a covered one.
      final TextEditingValue up = tableCaretVertical(
        value(table, cellAt(table, 3, 0).contentStart),
        down: false,
      )!;
      expect(up.selection.start, cellAt(table, 1, 0).contentStart);
      expect(cellAt(table, 1, 0).text, 'c');
    });

    test('Down at the last row is the normal leave-the-table signal', () {
      expect(
        tableCaretVertical(
          value(table, cellAt(table, 3, 1).contentStart),
          down: true,
        ),
        isNull,
      );
    });
  });

  test('Enter below a rowspan adds the row after the whole block', () {
    const String table =
        '| a | b |\n'
        '| --- | --- |\n'
        '| <!--nrs r=2-->c | d |\n'
        '| e | f |';
    final TableCell anchor = cellAt(table, 1, 0);
    final TextEditingValue next = tableRowBelow(
      value(table, anchor.contentStart),
    )!;

    expect(
      next.text,
      '| a | b |\n'
      '| --- | --- |\n'
      '| <!--nrs r=2-->c | d |\n'
      '| e | f |\n'
      '|  |  |',
      reason: '新行插在合并块之后，而不是块里面',
    );
    final TableBlock grown = TableBlock.parse(next.text, 0)!;
    expect(grown.bodyRows, hasLength(4));
    expect(next.text.substring(next.selection.start, next.selection.end), '  ');
  });
}
