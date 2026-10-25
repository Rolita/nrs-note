import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/ui/editor/table_panel.dart';
import 'package:nrs/ui/theme/app_color_picker.dart';

/// The table tools column: an empty state outside a table, and inside one a
/// scope switch plus the commands that scope can actually run.
void main() {
  const String table =
      '| 名称 | 数量 |\n'
      '| --- | --- |\n'
      '| 苹果 | 10 |\n'
      '| 香蕉 | 2 |';
  const String wide =
      '| 甲 | 乙 | 丙 |\n'
      '| --- | --- | --- |\n'
      '| a | b | c |\n'
      '| d | e | f |';

  Future<
    ({
      ValueNotifier<TextEditingValue> value,
      List<MarkdownEditFn> applied,
      List<int> jumped,
    })
  >
  pump(
    WidgetTester tester,
    String text,
    int caret, {
    TextSelection? selection,
  }) async {
    final ValueNotifier<TextEditingValue> value =
        ValueNotifier<TextEditingValue>(
          TextEditingValue(
            text: text,
            selection: selection ?? TextSelection.collapsed(offset: caret),
          ),
        );
    addTearDown(value.dispose);
    final List<MarkdownEditFn> applied = <MarkdownEditFn>[];
    final List<int> jumped = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          // The real shell pins the column to the right edge; the palette has
          // to be clamped there, not just where the test happens to start.
          body: Align(
            alignment: Alignment.centerRight,
            child: TablePanel(
              width: 252,
              value: value,
              onApply: applied.add,
              onJump: jumped.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (value: value, applied: applied, jumped: jumped);
  }

  /// Applies the last command the panel emitted and rebuilds on the result.
  Future<TextEditingValue> runLast(
    WidgetTester tester,
    ({
      ValueNotifier<TextEditingValue> value,
      List<MarkdownEditFn> applied,
      List<int> jumped,
    })
    state,
  ) async {
    final TextEditingValue out = state.applied.last(state.value.value);
    state.value.value = out;
    await tester.pumpAndSettle();
    return out;
  }

  TextSelection cellsOf(String text, String from, String to) => TextSelection(
    baseOffset: text.indexOf(from),
    extentOffset: text.indexOf(to) + to.length,
  );

  testWidgets('a file without tables explains how to make one', (
    WidgetTester tester,
  ) async {
    await pump(tester, '只是一段正文，没有表格。', 0);

    expect(find.text('没有表格'), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('格式'), findsNothing);
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

  testWidgets('a caret in a cell offers only the cell commands', (
    WidgetTester tester,
  ) async {
    await pump(tester, table, table.indexOf('苹果'));

    // The scope switch names what every destructive command below it acts on.
    for (final String label in <String>['单元格', '整行', '整列', '整表']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // 格式 is the one group that never goes away; the rest follow the scope.
    expect(find.text('格式'), findsOneWidget);
    expect(find.text('对齐'), findsOneWidget);
    expect(find.text('数据'), findsOneWidget);
    expect(find.text('汇总行'), findsOneWidget);

    // Rows, columns and table-wide tools are one tap away, not on screen.
    expect(find.text('行'), findsNothing);
    expect(find.text('列'), findsNothing);
    expect(find.byTooltip('选中整行'), findsNothing);
    expect(find.byTooltip('删除本列'), findsNothing);
    expect(find.byTooltip('删除整张表格'), findsNothing);

    // 4 (格式) + 4 (对齐) + 5 (数据)
    expect(find.byType(Tooltip), findsNWidgets(13));
    expect(find.byTooltip('合并居中'), findsOneWidget);
    expect(find.byTooltip('填充颜色'), findsOneWidget);
    expect(find.byTooltip('按本列升序'), findsOneWidget);

    // The header names the cell under the caret and the table the tools act on.
    expect(find.text('A2'), findsOneWidget);
    expect(find.text('第 1 张表 · 3 × 2 · 「名称」列'), findsOneWidget);
  });

  testWidgets('the scope switch retargets the panel and the selection', (
    WidgetTester tester,
  ) async {
    final state = await pump(tester, table, table.indexOf('苹果'));

    await tester.tap(find.text('整行'));
    await tester.pumpAndSettle();
    TextEditingValue out = await runLast(tester, state);
    expect(
      out.text.substring(out.selection.start, out.selection.end),
      '| 苹果 | 10 |\n',
    );
    // 格式 + 行
    expect(find.text('行'), findsOneWidget);
    expect(find.byTooltip('删除本行'), findsOneWidget);
    expect(find.text('数据'), findsNothing);
    expect(find.byType(Tooltip), findsNWidgets(10));

    await tester.tap(find.text('整列'));
    await tester.pumpAndSettle();
    out = await runLast(tester, state);
    expect(out.selection.start, isNot(out.selection.end));
    expect(find.text('列'), findsOneWidget);
    expect(find.byTooltip('删除本列'), findsOneWidget);
    expect(find.text('对齐'), findsOneWidget);
    // 格式 + 列 + 对齐
    expect(find.byType(Tooltip), findsNWidgets(14));

    await tester.tap(find.text('整表'));
    await tester.pumpAndSettle();
    await runLast(tester, state);
    // The title and the group head both read 「表格」 in this scope.
    expect(find.text('表格'), findsNWidgets(2));
    expect(find.byTooltip('删除整张表格'), findsOneWidget);
    // No explicit widths yet, so the width row only points at the canvas.
    expect(find.textContaining('列宽'), findsOneWidget);
    expect(find.text('拖表格竖线'), findsOneWidget);
    // 格式 + 表格
    expect(find.byType(Tooltip), findsNWidgets(8));

    await tester.tap(find.text('单元格'));
    await tester.pumpAndSettle();
    out = await runLast(tester, state);
    expect(out.selection.isCollapsed, isTrue, reason: '回到单格');
    expect(find.text('对齐'), findsOneWidget);
    expect(find.text('数据'), findsOneWidget);
  });

  testWidgets('the width row steps the caret column once widths exist', (
    WidgetTester tester,
  ) async {
    const String sized =
        '| <!--nrs w=96,120-->甲 | 乙 |\n'
        '| --- | --- |\n'
        '| a | b |';
    final state = await pump(tester, sized, sized.indexOf('a'));

    // The row belongs to 整表: a cell caret never sees it.
    expect(find.textContaining('列宽'), findsNothing);

    await tester.tap(find.text('整表'));
    await tester.pumpAndSettle();
    await runLast(tester, state);

    expect(find.text('A 列宽'), findsOneWidget);
    expect(find.text('96'), findsOneWidget);
    await tester.tap(find.byTooltip('加宽本列'));
    await tester.pumpAndSettle();
    TextEditingValue out = await runLast(tester, state);
    expect(out.text, contains('w=104,120'), reason: out.text);

    // The drag has no other way back to auto sizing.
    await tester.tap(find.byTooltip('恢复自适应'));
    await tester.pumpAndSettle();
    out = await runLast(tester, state);
    expect(out.text, isNot(contains('w=')), reason: out.text);
    expect(find.text('拖表格竖线'), findsOneWidget);
  });

  testWidgets('the summary button opens one named list, not five glyphs', (
    WidgetTester tester,
  ) async {
    // 数量 holds numbers, so 合计 and the rest of the arithmetic rows are live.
    final state = await pump(tester, table, table.indexOf('10'));

    await tester.tap(find.text('汇总行'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('table-menu-popover')),
      findsOneWidget,
    );
    for (final String label in <String>['合计', '平均', '计数', '最小值', '最大值']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('合计'));
    await tester.pumpAndSettle();
    final TextEditingValue out = await runLast(tester, state);
    expect(out.text, contains('合计'), reason: out.text);
  });

  testWidgets('merge waits for a rectangle, split waits for a merge', (
    WidgetTester tester,
  ) async {
    final state = await pump(tester, wide, wide.indexOf('a'));

    await tester.tap(find.byTooltip('合并居中'));
    await tester.tap(find.byTooltip('拆分单元格'));
    await tester.pumpAndSettle();
    expect(state.applied, isEmpty, reason: '单格没有可合并的矩形');

    final mergedState = await pump(
      tester,
      wide,
      wide.indexOf('a'),
      selection: cellsOf(wide, 'a', 'e'),
    );
    await tester.tap(find.byTooltip('合并居中'));
    await tester.pumpAndSettle();
    final TextEditingValue merged = await runLast(tester, mergedState);
    expect(
      merged.text,
      contains('| <!--nrs c=2 r=2-->a<br>b<br>d<br>e |  | c |\n|  |  | f |'),
      reason: merged.text,
    );
  });

  testWidgets('a merged cell can be split back without losing its text', (
    WidgetTester tester,
  ) async {
    final state = await pump(
      tester,
      wide,
      wide.indexOf('a'),
      selection: cellsOf(wide, 'a', 'e'),
    );
    await tester.tap(find.byTooltip('合并居中'));
    await tester.pumpAndSettle();
    await runLast(tester, state);

    await tester.tap(find.byTooltip('拆分单元格'));
    await tester.pumpAndSettle();
    final TextEditingValue split = await runLast(tester, state);
    expect(split.text, isNot(contains('<!--nrs')));
    expect(split.text, contains('a<br>b<br>d<br>e'));
  });

  testWidgets('cutting through a merge asks for a split first', (
    WidgetTester tester,
  ) async {
    const String merged =
        '| <!--nrs c=2 r=2-->a<br>b<br>d<br>e |  | c |\n'
        '| --- | --- | --- |\n'
        '|  |  | f |\n'
        '| g | h | i |';
    const String middle = '|  |  | f |';
    final int start = merged.indexOf(middle);
    final state = await pump(
      tester,
      merged,
      start,
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + middle.length,
      ),
    );

    // A whole-row selection is exactly one row of a two-row merge, so the
    // button is off and the tooltip names the blocker.
    expect(find.byTooltip('先拆分已合并的单元格'), findsOneWidget);
    expect(find.byTooltip('合并居中'), findsNothing);
    await tester.tap(find.byTooltip('先拆分已合并的单元格'));
    await tester.pumpAndSettle();
    expect(state.applied, isEmpty);
  });

  testWidgets('fill and text color are two trips to the same palette', (
    WidgetTester tester,
  ) async {
    final state = await pump(
      tester,
      wide,
      wide.indexOf('a'),
      selection: cellsOf(wide, 'a', 'b'),
    );

    await tester.tap(find.byTooltip('填充颜色'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('table-color-popover')),
      findsOneWidget,
    );
    expect(find.text('填充颜色'), findsOneWidget);
    expect(find.text('无填充'), findsOneWidget);
    await tester.tap(find.byTooltip('琥珀色'));
    await tester.pumpAndSettle();

    final TextEditingValue filled = await runLast(tester, state);
    expect(
      filled.text,
      contains('| <!--nrs bg=amber-->a | <!--nrs bg=amber-->b | c |'),
      reason: filled.text,
    );
    expect(
      filled.selection.baseOffset,
      isNot(filled.selection.extentOffset),
      reason: '上色后矩形应保持选中',
    );

    // The underline reports the color the two cells now share.
    final Container bar = tester.widget<Container>(
      find.byKey(const ValueKey<String>('table-swatch-填充颜色')),
    );
    expect(
      (bar.decoration! as BoxDecoration).color,
      AppPalette.light.warningSoft,
    );

    await tester.tap(find.byTooltip('文字颜色'));
    await tester.pumpAndSettle();
    expect(find.text('文字颜色'), findsOneWidget);
    expect(find.text('无颜色'), findsOneWidget);
    await tester.tap(find.byTooltip('红色'));
    await tester.pumpAndSettle();
    final TextEditingValue inked = await runLast(tester, state);
    expect(
      inked.text,
      contains(
        '| <!--nrs bg=amber fg=red-->a | <!--nrs bg=amber fg=red-->b | c |',
      ),
      reason: inked.text,
    );
  });

  testWidgets('the palette clears a fill and stays inside the window', (
    WidgetTester tester,
  ) async {
    final state = await pump(
      tester,
      table,
      table.indexOf('苹果'),
      selection: cellsOf(table, '苹果', '10'),
    );
    await tester.tap(find.byTooltip('填充颜色'));
    await tester.pumpAndSettle();

    final Rect popover = tester.getRect(
      find.byKey(const ValueKey<String>('table-color-popover')),
    );
    expect(popover.width, 220);
    expect(popover.right, lessThanOrEqualTo(790), reason: '浮层不能被窗口裁掉');
    expect(popover.left, greaterThanOrEqualTo(548), reason: '浮层仍在侧栏上');

    await tester.tap(find.byTooltip('绿色'));
    await tester.pumpAndSettle();
    expect((await runLast(tester, state)).text, contains('bg=green'));

    await tester.tap(find.byTooltip('填充颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('无填充'));
    await tester.pumpAndSettle();
    final TextEditingValue cleared = await runLast(tester, state);
    expect(cleared.text, isNot(contains('<!--nrs')));
  });

  testWidgets(
    'the palette inherits no fallback underline and names its wells',
    (WidgetTester tester) async {
      await pump(tester, table, table.indexOf('苹果'));
      await tester.tap(find.byTooltip('填充颜色'));
      await tester.pumpAndSettle();

      // The raw overlay sits above the Navigator's Material; without one of its
      // own, every label picks up MaterialApp's yellow double-underline error
      // style. A single underlined run here means that ancestor is missing.
      final Finder popover = find.byKey(
        const ValueKey<String>('table-color-popover'),
      );
      final Iterable<RichText> runs = tester.widgetList<RichText>(
        find.descendant(of: popover, matching: find.byType(RichText)),
      );
      expect(runs, isNotEmpty);
      for (final RichText run in runs) {
        expect(
          run.text.style?.decoration,
          isNot(TextDecoration.underline),
          reason: run.text.toPlainText(),
        );
      }

      // The six presets are wells only; their names live in hover tooltips.
      for (final String short in <String>['灰', '琥珀', '绿', '蓝', '紫', '红']) {
        expect(find.text(short), findsNothing, reason: short);
      }
      for (final String name in <String>['灰色', '琥珀色', '绿色', '蓝色', '紫色', '红色']) {
        expect(find.byTooltip(name), findsOneWidget, reason: name);
      }
    },
  );

  testWidgets('custom… opens the picker once and commits one color', (
    WidgetTester tester,
  ) async {
    final state = await pump(tester, table, table.indexOf('苹果'));

    await tester.tap(find.byTooltip('填充颜色'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义…'));
    await tester.pumpAndSettle();

    expect(find.byType(AppColorPicker), findsOneWidget);
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(state.applied, hasLength(1));
    final TextEditingValue out = await runLast(tester, state);
    expect(out.text, contains('bg=#'), reason: out.text);
  });

  testWidgets('a command runs the same action the menu runs', (
    WidgetTester tester,
  ) async {
    final state = await pump(tester, table, table.indexOf('苹果'));

    await tester.tap(find.text('整行'));
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
    expect(find.byType(Tooltip), findsNWidgets(13));

    state.value.value = const TextEditingValue(
      text: '正文',
      selection: TextSelection.collapsed(offset: 1),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Tooltip), findsNothing);
    expect(find.text('没有表格'), findsOneWidget);
  });
}
