import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/ui/templates/template_dialog_frame.dart';
import 'package:nrs/ui/templates/template_new_note_dialog.dart';
import 'package:nrs/ui/templates/template_picker.dart';
import 'package:nrs/ui/templates/template_prompt_dialog.dart';
import 'package:nrs/ui/templates/template_suggester_dialog.dart';

/// Result of one dialog round-trip: [done] flips when the future resolves, so a
/// test can tell "still open" from "closed with null".
class _Probe<T> {
  bool done = false;
  T? value;

  void complete(T? v) {
    value = v;
    done = true;
  }
}

Future<_Probe<T>> _openDialog<T>(
  WidgetTester tester,
  Future<T?> Function(BuildContext context) show,
) async {
  final _Probe<T> probe = _Probe<T>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.light),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => probe.complete(await show(context)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return probe;
}

/// Opens a second dialog after the first one closed.
Future<void> _reopen(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Note templateNote(
  String id,
  String title, {
  String folder = '模板',
  DateTime? updatedAt,
}) => Note(
  id: id,
  title: title,
  folderPath: folder,
  body: '# $title\n',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: updatedAt ?? DateTime(2026, 10, 20, 9, 30),
);

Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  group('模板选择器', () {
    testWidgets('按文件夹分组，搜索后 Enter 插入选中的模板', (
      WidgetTester tester,
    ) async {
      final _Probe<TemplatePickerResult> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePicker(
          context,
          templates: <Note>[
            templateNote('daily', '日记'),
            templateNote('meeting', '会议记录', folder: '模板/会议'),
          ],
          templatesFolder: '模板',
          canInsert: true,
        ),
      );

      expect(find.byType(TemplatePickerDialog), findsOneWidget);
      expect(find.text('日记'), findsWidgets);
      expect(find.text('会议记录'), findsWidgets);
      expect(find.text('会议'), findsOneWidget, reason: '子文件夹要成为分组标题');

      await tester.enterText(find.byType(TextField), '会议');
      await tester.pumpAndSettle();
      expect(find.text('日记'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value?.action, TemplatePickerAction.insert);
      expect(probe.value?.template?.id, 'meeting');
    });

    testWidgets('预览右上角的编辑按钮返回编辑动作', (WidgetTester tester) async {
      final _Probe<TemplatePickerResult> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePicker(
          context,
          templates: <Note>[templateNote('daily', '日记')],
          templatesFolder: '模板',
          canInsert: true,
        ),
      );

      await tester.tap(find.byTooltip('编辑这个模板'));
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value?.action, TemplatePickerAction.edit);
      expect(probe.value?.template?.id, 'daily');
    });

    testWidgets('方向键移动高亮，Ctrl+Enter 走新建笔记', (
      WidgetTester tester,
    ) async {
      final _Probe<TemplatePickerResult> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePicker(
          context,
          templates: <Note>[
            templateNote('a', '甲'),
            templateNote('b', '乙'),
            templateNote('c', '丙'),
          ],
          templatesFolder: '模板',
          canInsert: true,
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await pressCtrl(tester, LogicalKeyboardKey.enter);

      expect(probe.value?.action, TemplatePickerAction.newNote);
      expect(probe.value?.template?.id, 'c');
    });

    testWidgets('没有打开的笔记时插入被禁用，但新建笔记仍可用', (
      WidgetTester tester,
    ) async {
      final _Probe<TemplatePickerResult> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePicker(
          context,
          templates: <Note>[templateNote('a', '甲')],
          templatesFolder: '模板',
          canInsert: false,
        ),
      );

      final TemplateDialogButton insert = tester.widget<TemplateDialogButton>(
        find.widgetWithText(TemplateDialogButton, '插入到当前笔记'),
      );
      expect(insert.onPressed, isNull);
      final TemplateDialogButton create = tester.widget<TemplateDialogButton>(
        find.widgetWithText(TemplateDialogButton, '新建笔记'),
      );
      expect(create.onPressed, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(probe.done, isFalse, reason: '插入不可用时 Enter 不能悄悄变成别的动作');

      await pressCtrl(tester, LogicalKeyboardKey.enter);
      expect(probe.value?.action, TemplatePickerAction.newNote);
    });

    testWidgets('空状态给出打开文件夹和新建模板两条路', (
      WidgetTester tester,
    ) async {
      final _Probe<TemplatePickerResult> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePicker(
          context,
          templates: const <Note>[],
          templatesFolder: '模板',
          canInsert: true,
        ),
      );

      expect(find.text('还没有模板'), findsOneWidget);
      expect(find.textContaining('「模板」文件夹'), findsWidgets);

      await tester.tap(find.text('打开模板文件夹'));
      await tester.pumpAndSettle();
      expect(probe.value?.action, TemplatePickerAction.openFolder);

      await _reopen(tester);
      await tester.tap(find.text('新建模板'));
      await tester.pumpAndSettle();
      expect(probe.value?.action, TemplatePickerAction.newTemplate);
    });

    testWidgets('搜不到时说明原因，清空后列表回来', (WidgetTester tester) async {
      final _Probe<TemplatePickerResult> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePicker(
          context,
          templates: <Note>[templateNote('a', '甲')],
          templatesFolder: '模板',
          canInsert: true,
        ),
      );

      await tester.enterText(find.byType(TextField), '不存在的名字');
      await tester.pumpAndSettle();
      expect(find.text('没有找到模板'), findsOneWidget);
      expect(find.textContaining('不存在的名字'), findsWidgets);

      final TemplateDialogButton insert = tester.widget<TemplateDialogButton>(
        find.widgetWithText(TemplateDialogButton, '插入到当前笔记'),
      );
      expect(insert.onPressed, isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(probe.done, isFalse);

      await tester.tap(find.byTooltip('清除'));
      await tester.pumpAndSettle();
      expect(find.text('甲'), findsWidgets);
      expect(find.text('没有找到模板'), findsNothing);
    });

    testWidgets('Esc 关闭选择器，不返回任何动作', (WidgetTester tester) async {
      final _Probe<TemplatePickerResult> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePicker(
          context,
          templates: <Note>[templateNote('a', '甲')],
          templatesFolder: '模板',
          canInsert: true,
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value, isNull);
      expect(find.byType(TemplatePickerDialog), findsNothing);
    });
  });

  group('模板 prompt', () {
    testWidgets('默认答案已填好，Enter 返回改过的内容', (
      WidgetTester tester,
    ) async {
      final _Probe<String> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePromptDialog(
          context,
          text: '笔记标题',
          defaultValue: '默认标题',
          multiline: false,
        ),
      );

      expect(find.text('笔记标题'), findsOneWidget);
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.text, '默认标题');

      await tester.enterText(find.byType(TextField), '改过的标题');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(probe.value, '改过的标题');
    });

    testWidgets('空答案也是答案，不会被当成取消', (WidgetTester tester) async {
      final _Probe<String> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePromptDialog(
          context,
          text: '留空试试',
          defaultValue: '',
          multiline: false,
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value, '');
    });

    testWidgets('Esc 取消整次渲染', (WidgetTester tester) async {
      final _Probe<String> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePromptDialog(
          context,
          text: '笔记标题',
          defaultValue: '默认标题',
          multiline: false,
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value, isNull);
    });

    testWidgets('多行输入里 Enter 只换行，Ctrl+Enter 才提交', (
      WidgetTester tester,
    ) async {
      final _Probe<String> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplatePromptDialog(
          context,
          text: '正文',
          defaultValue: '',
          multiline: true,
        ),
      );

      await tester.enterText(find.byType(TextField), '第一行\n第二行');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(probe.done, isFalse, reason: '多行输入里的 Enter 不能结束整个模板');

      await pressCtrl(tester, LogicalKeyboardKey.enter);
      expect(probe.value, contains('第二行'));
    });
  });

  group('模板 suggester', () {
    testWidgets('过滤之后返回的仍是原列表下标', (WidgetTester tester) async {
      final _Probe<int> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplateSuggesterDialog(
          context,
          options: <String>['苹果', '香蕉', '苹果派'],
          placeholder: '选一种水果',
        ),
      );

      expect(find.text('选一种水果'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '苹果');
      await tester.pumpAndSettle();
      expect(find.text('香蕉'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(probe.value, 2, reason: '下拉过滤不能打乱模板拿到的下标');
    });

    testWidgets('没有匹配项时确定不可用', (WidgetTester tester) async {
      final _Probe<int> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplateSuggesterDialog(
          context,
          options: <String>['苹果', '香蕉'],
          placeholder: '',
        ),
      );

      expect(find.text('选择一个选项'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '西瓜');
      await tester.pumpAndSettle();

      expect(find.text('没有匹配的选项'), findsOneWidget);
      final TemplateDialogButton confirm = tester.widget<TemplateDialogButton>(
        find.widgetWithText(TemplateDialogButton, '确定'),
      );
      expect(confirm.onPressed, isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(probe.done, isFalse);
    });

    testWidgets('Esc 取消返回 null', (WidgetTester tester) async {
      final _Probe<int> probe = await _openDialog(
        tester,
        (BuildContext context) => showTemplateSuggesterDialog(
          context,
          options: <String>['苹果'],
          placeholder: '选一种水果',
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value, isNull);
    });
  });

  group('用模板新建笔记', () {
    testWidgets('标题去掉首尾空格后返回', (WidgetTester tester) async {
      final _Probe<String> probe = await _openDialog(
        tester,
        (BuildContext context) =>
            showTemplateNewNoteDialog(context, templateTitle: '日记'),
      );

      expect(find.text('用模板新建笔记'), findsOneWidget);
      expect(find.textContaining('日记'), findsWidgets);

      await tester.enterText(find.byType(TextField), '  周报  ');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(probe.value, '周报');
    });

    testWidgets('空标题返回空串，交给控制器命名为未命名', (
      WidgetTester tester,
    ) async {
      final _Probe<String> probe = await _openDialog(
        tester,
        (BuildContext context) =>
            showTemplateNewNoteDialog(context, templateTitle: '日记'),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value, '');
    });

    testWidgets('Esc 取消时一篇笔记也不创建', (WidgetTester tester) async {
      final _Probe<String> probe = await _openDialog(
        tester,
        (BuildContext context) =>
            showTemplateNewNoteDialog(context, templateTitle: '日记'),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(probe.done, isTrue);
      expect(probe.value, isNull);
    });
  });
}
