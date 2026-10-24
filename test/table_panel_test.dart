import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/ui/editor/table_panel.dart';

/// The table tools column: an empty state outside a table, and inside one the
/// same commands the right-click menu offers, in seven titled rows.
void main() {
  const String table =
      '| 名称 | 数量 |\n'
      '| --- | --- |\n'
      '| 苹果 | 10 |\n'
      '| 香蕉 | 2 |';

  Future<
    ({
      ValueNotifier<TextEditingValue> value,
      List<MarkdownEditFn> applied,
      List<int> jumped,
    })
  >
  pump(WidgetTester tester, String text, int caret) async {
    final ValueNotifier<TextEditingValue> value =
        ValueNotifier<TextEditingValue>(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: caret),
          ),
        );
    addTearDown(value.dispose);
    final List<MarkdownEditFn> applied = <MarkdownEditFn>[];
    final List<int> jumped = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          body: TablePanel(
            width: 252,
            value: value,
            onApply: applied.add,
            onJump: jumped.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (value: value, applied: applied, jumped: jumped);
  }

  testWidgets('a file without tables explains how to make one', (
    WidgetTester tester,
  ) async {
    await pump(tester, '只是一段正文，没有表格。', 0);

    expect(find.text('没有表格'), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('选择'), findsNothing);
  });

  testWidgets('outside a table it shows each table as a real mini grid', (
    WidgetTester tester,
  ) async {
    const String text =
        '开头\n\n$table\n\n中间\n\n| 城市 | 人口 |\n| --- | --- |\n| 杭州 | 900 |\n\n结尾';
    final state = await pump(tester, text, 1);

    expect(find.text('全文 2 张表 · 点击跳转'), findsOneWidget);
    // Header cells are drawn as cells, not joined into one run of text.
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('数量'), findsOneWidget);
    expect(find.text('苹果'), findsOneWidget);
    expect(find.text('城市'), findsOneWidget);
    expect(find.text('杭州'), findsOneWidget);
    expect(find.text('3 × 2 · L3'), findsOneWidget);
    expect(find.text('2 × 2 · L10'), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);

    // Picking one only moves the caret: no command runs.
    await tester.tap(find.text('杭州'));
    await tester.pumpAndSettle();
    expect(state.jumped, <int>[text.indexOf('| 城市')]);
    expect(state.applied, isEmpty);
  });

  testWidgets('each table is labelled with the heading above it', (
    WidgetTester tester,
  ) async {
    const String doc =
        '开头\n\n| 前 | 置 |\n| --- | --- |\n| 1 | 2 |\n\n'
        '# 总览\n\n| 总 | 值 |\n| --- | --- |\n| 1 | 2 |\n\n'
        '## 预算\n\n| 项目 | 2026 |\n| --- | --- |\n| 研发 | 4800 |';
    await pump(tester, doc, 0);

    // Each card carries its nearest heading, with the heading's own level.
    expect(find.text('（无小节标题）'), findsOneWidget);
    expect(find.text('#'), findsOneWidget);
    expect(find.text('##'), findsOneWidget);
    expect(find.text('总览'), findsOneWidget);
    expect(find.text('预算'), findsOneWidget);
    expect(find.text('2 × 2 · L3'), findsOneWidget);
    expect(find.text('2 × 2 · L9'), findsOneWidget);
    expect(find.text('2 × 2 · L15'), findsOneWidget);
  });

  testWidgets('inside a table every command is one glyph with a full name', (
    WidgetTester tester,
  ) async {
    await pump(tester, table, table.indexOf('苹果'));

    for (final String label in <String>['选择', '行', '列', '对齐', '数据', '汇总']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // The last group is named after the panel itself, so the title and the
    // group head both read 「表格」.
    expect(find.text('表格'), findsNWidgets(2));
    // 3 + 6 + 6 + 4 + 5 + 5 + 4
    expect(find.byType(Tooltip), findsNWidgets(33));
    expect(find.byTooltip('选中整行'), findsOneWidget);
    expect(find.byTooltip('删除本列'), findsOneWidget);

    // The header names the cell under the caret and the table the tools act on.
    expect(find.text('A2'), findsOneWidget);
    expect(find.text('第 1 张表 · 3 × 2 · 「名称」列'), findsOneWidget);
  });

  testWidgets('a command runs the same action the menu runs', (
    WidgetTester tester,
  ) async {
    final state = await pump(tester, table, table.indexOf('苹果'));

    await tester.tap(find.byTooltip('选中整行'));
    await tester.pumpAndSettle();

    expect(state.applied, hasLength(1));
    final TextEditingValue out = state.applied.single(state.value.value);
    expect(
      out.text.substring(out.selection.start, out.selection.end),
      '| 苹果 | 10 |\n',
    );
  });

  testWidgets('leaving the table clears the tools again', (
    WidgetTester tester,
  ) async {
    final state = await pump(tester, table, table.indexOf('苹果'));
    expect(find.byType(Tooltip), findsNWidgets(33));

    state.value.value = const TextEditingValue(
      text: '正文',
      selection: TextSelection.collapsed(offset: 1),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('没有表格'), findsOneWidget);
  });
}
