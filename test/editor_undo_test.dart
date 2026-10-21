import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/notes_controller.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/ui/editor/editor_pane.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个只活在内存里的笔记库，够标题框的撤销测试用。
class _VaultStore extends NoteStore {
  _VaultStore(this.notes);

  final List<Note> notes;

  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<Note>> loadAll() async => List<Note>.of(notes);

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
  Future<void> delete(Note note) async {
    notes.removeWhere((Note n) => n.id == note.id);
  }
}

/// 把带笔记库的编辑面板挂起来（正文、标题、自动保存都是真的）。
Future<void> _pumpPane(
  WidgetTester tester,
  NotesController notes,
  SettingsController settings,
) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<NotesController>.value(value: notes),
      ],
      child: MaterialApp(
        theme: AppTheme.build(AppPalette.dark),
        home: Scaffold(body: EditorPane(onDelete: (Note note) {})),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 撤销栈跟着控制器走，切笔记时必须清空。
///
/// 否则一次 Ctrl+Z 会把上一份笔记的正文恢复进当前笔记，自动保存再把它写回
/// 当前文件——用户丢数据的正是这条路径。
void main() {
  const String first = '# 甲笔记\n\n这是第一份笔记的正文。';
  const String second = '# 乙笔记\n\n这是第二份笔记的正文。';

  late MarkdownSourceController controller;
  late FocusNode focus;

  Widget build(String documentId) {
    return MaterialApp(
      theme: AppTheme.build(AppPalette.dark),
      home: Scaffold(
        body: MarkdownEditor(
          controller: controller,
          focusNode: focus,
          scrollController: ScrollController(),
          fontSize: 15.5,
          documentId: documentId,
        ),
      ),
    );
  }

  /// 输入走 `LineEditableText` 自己的 state：`tester.enterText` 只认
  /// `EditableText` 的 state，这个按行渲染的 fork 不在其中。
  void type(WidgetTester tester, String text) {
    tester
        .state<LineEditableTextState>(find.byType(LineEditableText))
        .userUpdateTextEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
          SelectionChangedCause.keyboard,
        );
  }

  testWidgets('切到另一份笔记后 Ctrl+Z 不会恢复上一份的正文', (WidgetTester tester) async {
    controller = MarkdownSourceController(text: first);
    focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(build('a'));
    focus.requestFocus();
    // 撤销栈的第一次压栈同样是 500ms 节流后的；先让它落栈，后面打的字才会
    // 成为第二个状态（只有两个以上状态时 canUndo 才为真）。
    await tester.pump(const Duration(milliseconds: 600));

    // 先在甲笔记里真打一次字，撤销栈里才会留下**甲**的历史。
    type(tester, '$first甲的新增');
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.text, '$first甲的新增');

    // 面板绑定新笔记：控制器被整段改写，随后带新的 documentId 重建。
    controller.text = second;
    await tester.pumpWidget(build('b'));
    await tester.pumpAndSettle();
    // 重建会换掉整个输入框的 State；焦点节点是外部传进来的，重新要一次，
    // 保证下面的 Ctrl+Z 真的送到编辑器，而不是在无人接收时空转。
    focus.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(controller.text, second, reason: '撤销不能跨笔记，恢复旧正文就等于用旧内容覆盖文件');
  });

  testWidgets('同一份笔记里 Ctrl+Z 仍然正常撤销', (WidgetTester tester) async {
    controller = MarkdownSourceController(text: first);
    focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(build('a'));
    focus.requestFocus();
    tester.testTextInput.register();
    // `UndoHistory` throttles pushes by 500 ms: the starting value has to land
    // before the edit, otherwise there is no earlier state to go back to.
    await tester.pump(const Duration(milliseconds: 600));

    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '$first追加',
        selection: TextSelection.collapsed(offset: first.length + 2),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.text, '$first追加');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 600));

    expect(controller.text, first);
    // 撤销还原的是正文，光标应留在刚才打字的位置（还原后的文末），而不是
    // 跟着栈里那条 selection=0 的初始状态跳回文首。
    expect(controller.selection.baseOffset, first.length);
  });

  testWidgets('切到另一份笔记后，标题框的 Ctrl+Z 不会改回旧标题', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = await SettingsController.load();
    final Note a = Note(
      id: 'a',
      title: '甲标题',
      body: '正文甲',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 3),
    );
    final Note b = Note(
      id: 'b',
      title: '乙标题',
      body: '正文乙',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final NotesController notes = NotesController(store: _VaultStore(<Note>[a, b]));
    addTearDown(notes.dispose);
    await notes.bootstrap();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<NotesController>.value(value: notes),
        ],
        child: MaterialApp(
          theme: AppTheme.build(AppPalette.dark),
          home: Scaffold(
            body: EditorPane(onDelete: (Note note) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 在甲笔记的标题里改一次名字，标题框的撤销栈里留下甲的历史。
    await tester.enterText(find.byType(TextField), '甲改');
    await tester.pump(const Duration(milliseconds: 600));
    expect(notes.draft?.title, '甲改');

    // 切到乙笔记：标题控制器被改写成乙的标题，标题框也应随之重建。
    notes.select('b');
    await tester.pumpAndSettle();
    expect(notes.draft?.title, '乙标题');

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      notes.draft?.title,
      '乙标题',
      reason: '撤销不能跨笔记：旧标题会被当成新标题，把当前文件按旧名字重命名',
    );
    // 保存完成后状态条还挂着 2 秒的「已保存」计时器，让它走完再结束测试。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('磁盘上的正文更新后编辑器跟着换，Ctrl+Z 不会把旧正文写回去', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = await SettingsController.load();
    final Note note = Note(
      id: 'a',
      title: '甲',
      body: '旧正文',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final _VaultStore store = _VaultStore(<Note>[note]);
    final NotesController notes = NotesController(store: store);
    addTearDown(notes.dispose);
    await notes.bootstrap();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<NotesController>.value(value: notes),
        ],
        child: MaterialApp(
          theme: AppTheme.build(AppPalette.dark),
          home: Scaffold(
            body: EditorPane(onDelete: (Note note) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    String editorText() => tester
        .widget<LineEditableText>(find.byType(LineEditableText))
        .controller
        .text;
    expect(editorText(), '旧正文');

    // 另一个程序（同步盘、外部编辑器）把磁盘上的这份笔记改了：未 dirty 时
    // 控制器采用磁盘版本，编辑器也必须跟着换。
    store.notes[0] = note.copyWith(body: '# 新标题\n\n磁盘上的新正文');
    await notes.refresh();
    await tester.pumpAndSettle();
    expect(editorText(), contains('磁盘上的新正文'));

    // 换进来的是「另一份正文」，撤销栈不能把它撤回到替换前的旧正文。
    await tester.tap(find.byType(LineEditableText));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      editorText(),
      contains('磁盘上的新正文'),
      reason: 'Ctrl+Z 恢复旧正文后，自动保存会把它写回磁盘',
    );
    expect(notes.draft?.body, contains('磁盘上的新正文'));
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('撤销后光标留在刚打字的位置，不跳回文首', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = await SettingsController.load();
    const String bodyText = '第一行\n第二行';
    final Note note = Note(
      id: 'a',
      title: '甲',
      body: bodyText,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final NotesController notes = NotesController(
      store: _VaultStore(<Note>[note]),
    );
    addTearDown(notes.dispose);
    await notes.bootstrap();
    await _pumpPane(tester, notes, settings);

    final TextEditingController body = tester
        .widget<LineEditableText>(find.byType(LineEditableText))
        .controller;
    tester.testTextInput.register();
    await tester.tap(find.byType(LineEditableText));
    // 绑定笔记时控制器被写成 selection=0；先让这条初始状态落进撤销栈。
    await tester.pump(const Duration(milliseconds: 600));

    const String typed = '$bodyText 新增';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: typed,
        selection: TextSelection.collapsed(offset: typed.length),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(body.text, typed);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 600));

    expect(body.text, bodyText);
    expect(
      body.selection.baseOffset,
      bodyText.length,
      reason: '撤销还原的是正文，光标应留在刚才打字的位置，不能跟着栈里的 selection=0 跳回文首',
    );
    await tester.pump(const Duration(seconds: 3));
  });
}
