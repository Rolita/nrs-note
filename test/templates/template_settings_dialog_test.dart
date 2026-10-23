import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/notes_controller.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/state/template_settings.dart';
import 'package:nrs/ui/shell/settings_dialog.dart';
import 'package:nrs/ui/templates/template_hotkeys_dialog.dart';

class _Store extends NoteStore {
  _Store(this.notes, this.folders);

  final List<Note> notes;
  final List<String> folders;

  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<Note>> loadAll() async => List<Note>.of(notes);

  @override
  Future<List<String>> listFolders() async => List<String>.of(folders);

  @override
  Future<String> createFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return '';
    if (!folders.contains(folder)) folders.add(folder);
    return folder;
  }

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    notes.removeWhere(
      (Note n) =>
          n.id == note.id ||
          (previousPath != null && n.relativePath == previousPath),
    );
    notes.add(note);
  }

  @override
  Future<TrashEntry?> delete(Note note) async => null;
}

Note _note(String id, String title, {String folder = ''}) => Note(
  id: id,
  title: title,
  folderPath: folder,
  body: '# $title\n',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 2),
);

Future<({SettingsController settings, NotesController notes})> pumpSettings(
  WidgetTester tester, {
  List<Note>? vault,
  List<String>? folders,
}) async {
  tester.view.physicalSize = const Size(1100, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SettingsController settings = await SettingsController.load();
  final NotesController notes = NotesController(
    store: _Store(
      vault ?? <Note>[_note('a', '一篇笔记')],
      folders ?? <String>['项目', '模板'],
    ),
  );
  addTearDown(notes.dispose);
  await notes.bootstrap();

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<NotesController>.value(value: notes),
      ],
      child: MaterialApp(
        theme: AppTheme.build(settings.paletteFor(Brightness.light)),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showSettingsDialog(context),
              child: const Text('settings'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('settings'));
  await tester.pumpAndSettle();
  return (settings: settings, notes: notes);
}

Future<void> scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    220,
    scrollable: find
        .descendant(of: find.byType(Dialog), matching: find.byType(Scrollable))
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> pressCtrlShift(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('模板文件夹在回车后保存规范化路径', (WidgetTester tester) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpSettings(tester);

    await scrollTo(tester, find.text('模板文件夹'));
    final Finder field = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);

    await tester.enterText(field, ' 工作 / 模板 ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(app.settings.templatesFolder, '工作/模板');
    expect(
      tester.widget<TextField>(field).controller?.text,
      '工作/模板',
      reason: '提交后输入框要显示真正保存下来的路径',
    );
  });

  testWidgets('模板文件夹可以从库里已有的文件夹中选择', (WidgetTester tester) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpSettings(tester);
    final Finder field = find.byKey(
      const ValueKey<String>('templates-folder'),
    );

    await scrollTo(tester, field);
    await tester.tap(find.byTooltip('选择已有文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目').last);
    await tester.pumpAndSettle();

    expect(app.settings.templatesFolder, '项目');
    expect(tester.widget<TextField>(field).controller?.text, '项目');
  });

  testWidgets('关闭设置时输入中的路径也会保存', (WidgetTester tester) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpSettings(tester);
    final Finder field = find.byKey(
      const ValueKey<String>('templates-folder'),
    );

    await scrollTo(tester, field);
    await tester.enterText(field, '工作/我的模板');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsNothing);
    expect(app.settings.templatesFolder, '工作/我的模板');
  });

  testWidgets('自动套用开关可切换，文件夹规则可增删改', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpSettings(
          tester,
          vault: <Note>[
            _note('a', '一篇笔记'),
            _note('daily', '日报', folder: '模板'),
            _note('weekly', '周报', folder: '模板'),
          ],
          folders: <String>['项目', '模板', '模板/子'],
        );

    await scrollTo(tester, find.text('新建笔记时套用文件夹模板'));
    final Finder switchRow = find
        .ancestor(
          of: find.text('新建笔记时套用文件夹模板'),
          matching: find.byType(Row),
        )
        .first;
    await tester.tap(
      find.descendant(of: switchRow, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(app.settings.autoApplyFolderTemplates, isTrue);

    await scrollTo(tester, find.text('添加规则'));
    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();

    expect(app.settings.folderTemplateRules, hasLength(1));
    expect(app.settings.folderTemplateRules.single.folderPath, '');
    expect(find.byType(DropdownButton<String>), findsNWidgets(2));

    // 根目录规则改成「项目」。
    await tester.ensureVisible(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目').last);
    await tester.pumpAndSettle();
    expect(app.settings.folderTemplateRules.single.folderPath, '项目');

    // 换成另一篇模板。
    final String before = app.settings.folderTemplateRules.single.templateId;
    final Note other = app.notes.allNotes.firstWhere(
      (Note n) => n.id != before && n.folderPath == '模板',
    );
    await tester.tap(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text(other.title).last);
    await tester.pumpAndSettle();
    expect(app.settings.folderTemplateRules.single.templateId, other.id);

    await tester.tap(find.byTooltip('删除规则'));
    await tester.pumpAndSettle();
    expect(app.settings.folderTemplateRules, isEmpty);
    expect(find.text('还没有规则。'), findsOneWidget);
  });

  testWidgets('录制快捷键后立刻保存，并能改动作和清除', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpSettings(
          tester,
          vault: <Note>[
            _note('a', '一篇笔记'),
            _note('daily', '日报', folder: '模板'),
            _note('weekly', '周报', folder: '模板'),
          ],
        );

    await scrollTo(tester, find.text('模板快捷键'));
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    expect(find.byType(TemplateHotkeysDialog), findsOneWidget);
    expect(find.text('未绑定'), findsNWidgets(2));

    await tester.tap(find.text('未绑定').first);
    await tester.pump();
    await pressCtrlShift(tester, LogicalKeyboardKey.keyJ);

    final TemplateHotkey binding = app.settings.templateHotkeys.values.single;
    expect(binding.keyId, LogicalKeyboardKey.keyJ.keyId);
    expect(binding.control, isTrue);
    expect(binding.shift, isTrue);
    expect(binding.action, TemplateAction.insert);
    expect(find.text('Ctrl + Shift + J'), findsOneWidget);

    // 插入 → 新建。
    await tester.tap(find.text('插入到当前笔记').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建笔记').last);
    await tester.pumpAndSettle();
    expect(
      app.settings.templateHotkeys.values.single.action,
      TemplateAction.create,
    );

    await tester.tap(find.byTooltip('清除快捷键'));
    await tester.pumpAndSettle();
    expect(app.settings.templateHotkeys, isEmpty);
    expect(find.text('未绑定'), findsNWidgets(2));
  });

  testWidgets('内置快捷键和其他模板已用的组合会被拒绝', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpSettings(
          tester,
          vault: <Note>[
            _note('a', '一篇笔记'),
            _note('daily', '日报', folder: '模板'),
            _note('weekly', '周报', folder: '模板'),
          ],
        );

    await scrollTo(tester, find.text('模板快捷键'));
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();

    // Ctrl+N 是内置的新建笔记：拒绝并说明原因。
    await tester.tap(find.text('未绑定').first);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.textContaining('已经被「新建笔记」使用'), findsOneWidget);
    expect(app.settings.templateHotkeys, isEmpty);

    // 换一个不冲突的组合，成功一个。
    await pressCtrlShift(tester, LogicalKeyboardKey.keyK);
    expect(app.settings.templateHotkeys, hasLength(1));

    // 第二个模板再按同一个组合：被第一个模板占用。
    await tester.tap(find.text('未绑定').first);
    await tester.pump();
    await pressCtrlShift(tester, LogicalKeyboardKey.keyK);
    expect(find.textContaining('已被模板'), findsOneWidget);
    expect(app.settings.templateHotkeys, hasLength(1));

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(TemplateHotkeysDialog), findsNothing);
  });

  testWidgets('指向已删除模板的快捷键会被列出并可清除', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpSettings(
          tester,
          vault: <Note>[
            _note('a', '一篇笔记'),
            _note('daily', '日报', folder: '模板'),
          ],
        );
    app.settings.templateHotkeys = <String, TemplateHotkey>{
      'gone': const TemplateHotkey(
        templateId: 'gone',
        keyId: 74,
        action: TemplateAction.insert,
        control: true,
        shift: true,
      ),
    };

    await scrollTo(tester, find.text('模板快捷键'));
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();

    expect(find.text('1 个快捷键指向已删除的模板'), findsOneWidget);
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(app.settings.templateHotkeys, isEmpty);
    expect(find.text('1 个快捷键指向已删除的模板'), findsNothing);
  });
}
