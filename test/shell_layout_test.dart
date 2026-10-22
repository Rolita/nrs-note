import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/app_enums.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/core/utils/markdown_outline.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/notes_controller.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/ui/common/app_widgets.dart';
import 'package:nrs/ui/editor/editor_context_menu.dart';
import 'package:nrs/ui/editor/editor_pane.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';
import 'package:nrs/ui/editor/outline_panel.dart';
import 'package:nrs/ui/shell/app_shell.dart';
import 'package:nrs/ui/shell/function_rail.dart';
import 'package:nrs/ui/shell/note_list_panel.dart';
import 'package:nrs/ui/shell/title_bar.dart';
import 'package:nrs/ui/shell/vault_tree.dart';

/// A tiny vault so the shell can be built without touching the real one.
class _VaultStore extends NoteStore {
  _VaultStore(this.notes, {List<String>? folders})
    : folders = <String>[...?folders];

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
  Future<bool> renameFolder(String from, String to) async {
    final String source = Note.normalizeFolderPath(from);
    final String target = Note.normalizeFolderPath(to);
    if (source.isEmpty || target.isEmpty || source == target) return false;
    if (folders.any((String f) => f.toLowerCase() == target.toLowerCase())) {
      return false;
    }
    final String prefix = '$source/';
    for (int i = 0; i < folders.length; i++) {
      if (folders[i] == source || folders[i].startsWith(prefix)) {
        folders[i] = '$target${folders[i].substring(source.length)}';
      }
    }
    for (int i = 0; i < notes.length; i++) {
      final String folder = notes[i].folderPath;
      if (folder == source || folder.startsWith(prefix)) {
        notes[i] = notes[i].copyWith(
          folderPath: '$target${folder.substring(source.length)}',
        );
      }
    }
    return true;
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
  Future<void> delete(Note note) async {
    notes.removeWhere((Note n) => n.id == note.id);
  }
}

void main() {
  /// A vault row the test can point at without hitting the editor, which also
  /// renders the open note's title.
  Finder treeRow(String title) =>
      find.descendant(of: find.byType(VaultTree), matching: find.text(title));

  Note note(String id, String title, DateTime updatedAt) => Note(
    id: id,
    title: title,
    body: '# $title\n\n正文\n',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: updatedAt,
  );

  Future<({SettingsController settings, NotesController notes})> pumpShell(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    List<Note>? vault,
    List<String>? folders,
    SortMode sort = SortMode.updatedDesc,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues(<String, Object>{
      'nrs.sort': sort.name,
      // Deliberately not the default board: the shell must hold up on the new
      // `paletteFor` path, not just on 石墨素白.
      'nrs.themePreset': 'vivid',
    });
    final SettingsController settings = await SettingsController.load();
    final Note note = Note(
      id: 'a',
      title: '一篇笔记',
      body: '# 标题\n\n正文\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final NotesController notes = NotesController(
      store: _VaultStore(vault ?? <Note>[note], folders: folders),
    )..sortMode = settings.sort;
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
          home: const AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (settings: settings, notes: notes);
  }

  testWidgets('the shell is title bar, sidebar, editor and outline, in order', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(find.byType(NoteListPanel), findsOneWidget);
    expect(find.byType(OutlinePanel), findsOneWidget);

    // The file panel names itself, and its four actions sit as one group at the
    // header's right edge — 排序、展开 / 收起、新建文件夹、新建笔记, left to right.
    expect(find.text('文件'), findsOneWidget);
    const List<String> actions = <String>[
      '排序方式',
      // One expand/collapse button, showing 全部收起 while everything is open.
      '全部收起',
      '新建文件夹',
      '新建笔记  ·  Ctrl+N',
    ];
    double previousRight = double.negativeInfinity;
    for (final String tooltip in actions) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
      final Rect rect = tester.getRect(find.byTooltip(tooltip));
      expect(rect.left, greaterThanOrEqualTo(previousRight), reason: tooltip);
      previousRight = rect.right;
    }
    expect(find.byTooltip('全部展开'), findsNothing);
    // Nothing sits to their right: the group ends at the panel's own edge.
    final Rect panel = tester.getRect(find.byType(NoteListPanel));
    expect(panel.right - previousRight, lessThanOrEqualTo(AppSpace.xs));
    expect(find.text('一篇笔记'), findsWidgets);
  });

  testWidgets('the tree follows renames and task edits without a full rebuild', (
    WidgetTester tester,
  ) async {
    final Note note = Note(
      id: 'task',
      title: '任务清单',
      body: '- [ ] 待办\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester, vault: <Note>[note]);
    app.notes.select('task');
    await tester.pump();

    Finder inTree(Finder finder) =>
        find.descendant(of: find.byType(VaultTree), matching: finder);
    expect(inTree(find.text('0/1')), findsOneWidget);

    // 正文输入只推进编辑版本号：树不重建，但这一行的任务徽标要自己更新。
    app.notes.updateBody('- [x] 待办\n');
    await tester.pump();
    expect(inTree(find.text('1/1')), findsOneWidget);

    // 标题即文件名，属于结构变化：树必须跟着换行。
    app.notes.updateTitle('任务清单 改');
    await tester.pump();
    expect(inTree(find.text('任务清单 改')), findsOneWidget);

    // 让防抖写入落地，否则测试结束时会留下挂起的定时器。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('only the sidebar and the outline can be dragged wider', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    // Two boundaries are draggable: sidebar|editor and editor|outline. The
    // rail is a fixed strip (tags, settings), so the file list starts right
    // after it.
    expect(find.byType(ResizeHandle), findsNWidgets(2));
    final Rect rail = tester.getRect(find.byType(AppRail));
    final Rect panel = tester.getRect(find.byType(NoteListPanel));
    expect(panel.left, rail.right);

    final Rect sidebarHandle = tester.getRect(find.byType(ResizeHandle).at(0));
    final Rect outlineHandle = tester.getRect(find.byType(ResizeHandle).at(1));
    expect(sidebarHandle.left, panel.right);
    expect(outlineHandle.right, tester.getRect(find.byType(OutlinePanel)).left);
  });

  testWidgets('dragging the handles resizes the sidebar and the outline', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester);
    expect(app.settings.listWidth, AppLayout.listDefaultWidth);
    expect(app.settings.outlineWidth, AppLayout.outlineWidth);

    await tester.drag(
      find.byType(ResizeHandle).first,
      const Offset(60, 0),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(app.settings.listWidth, greaterThan(AppLayout.listDefaultWidth));

    // The outline handle sits on the outline's left edge, so a rightward drag
    // narrows the column instead of widening it.
    await tester.drag(
      find.byType(ResizeHandle).last,
      const Offset(60, 0),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(app.settings.outlineWidth, lessThan(AppLayout.outlineWidth));
  });

  testWidgets('the rail switches the sidebar between files, search and tags', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(find.text('输入并开始搜索...'), findsOneWidget);

    await tester.tap(find.byTooltip('标签'));
    await tester.pumpAndSettle();
    expect(find.text('标签'), findsWidgets);
    expect(find.text('入门'), findsNothing);

    await tester.tap(find.byTooltip('文件'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('新建文件夹'), findsOneWidget);
  });

  testWidgets(
    'the search panel waits with a hint instead of listing the vault',
    (WidgetTester tester) async {
      final ({SettingsController settings, NotesController notes}) app =
          await pumpShell(
            tester,
            vault: <Note>[note('a', '甲', DateTime(2026, 1, 2))],
          );

      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();

      // The field carries the magnifier, the placeholder and its two switches —
      // and no scope chips row anywhere.
      expect(find.text('输入并开始搜索...'), findsOneWidget);
      expect(find.text('Aa'), findsOneWidget);
      expect(find.text('全部笔记'), findsNothing);
      expect(find.text('置顶'), findsNothing);
      expect(find.textContaining('篇笔记'), findsNothing, reason: '搜索视图没有底部计数条');
      // Nothing typed yet: a hint, not the whole vault listed.
      expect(find.text('搜索笔记'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NoteListPanel),
          matching: find.text('甲'),
        ),
        findsNothing,
      );

      // A name that matches nobody gets the one quiet line.
      await tester.enterText(
        find.descendant(
          of: find.byType(NoteListPanel),
          matching: find.byType(TextField),
        ),
        '找不到的怪词',
      );
      await tester.pumpAndSettle();
      expect(app.notes.query, '找不到的怪词');
      expect(find.text('未找到匹配结果。'), findsOneWidget);
    },
  );

  testWidgets('a search result shows the line that matched', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: '甲文',
          body: '# 标题\n\n正文里提到了甲\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
      ],
    );

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(NoteListPanel),
        matching: find.byType(TextField),
      ),
      '正文',
    );
    await tester.pumpAndSettle();

    final Finder panel = find.byType(NoteListPanel);
    expect(
      find.descendant(of: panel, matching: find.text('甲文')),
      findsOneWidget,
    );
    // The matching line sits under the name — a list of names would answer
    // "which notes", but a search asks "where in them".
    expect(
      find.descendant(
        of: panel,
        matching: find.textContaining('正文里提到了甲'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byTooltip('删除')),
      findsNothing,
    );
  });

  testWidgets('a tag query lists its notes with the line the tag sits on', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[
            Note(
              id: 'a',
              title: 'NRS 快速入门',
              body: '# NRS 快速入门\n\n正文里直接写 #入门 也会变成可点击的标签\n',
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 2),
            ),
            Note(
              id: 'b',
              title: '闲话',
              body: '# 闲话\n\n与标签无关\n',
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 1),
            ),
          ],
        );

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    // What clicking `#入门` in the text does: one visible query, no hidden
    // filter state.
    app.notes.setQuery('tag:#入门');
    await tester.pumpAndSettle();

    final Finder panel = find.byType(NoteListPanel);
    expect(
      find.descendant(of: panel, matching: find.text('tag:#入门')),
      findsOneWidget,
      reason: '搜索框要显示正在过滤什么',
    );
    expect(
      find.descendant(of: panel, matching: find.text('NRS 快速入门')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.textContaining('#入门 也会')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('闲话')),
      findsNothing,
    );
  });

  testWidgets('a note with three matches is one group, and hover lights it up', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[
            Note(
              id: 'a',
              title: 'NRS 快速入门',
              fileName: 'NRS 快速入门.md',
              body:
                  '# NRS 快速入门\n\n第一行 #入门\n第二行 #入门\n第三行 #入门\n',
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 2),
            ),
          ],
        );

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    app.notes.setQuery('tag:#入门');
    await tester.pumpAndSettle();

    final Finder panel = find.byType(NoteListPanel);
    // One group named after the file (without `.md`), with the match count.
    expect(
      find.descendant(of: panel, matching: find.text('NRS 快速入门')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.text('3')),
      findsOneWidget,
    );
    final Finder firstCard = find.descendant(
      of: panel,
      matching: find.textContaining('第一行'),
    );
    expect(firstCard, findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.textContaining('第三行')),
      findsOneWidget,
    );

    // The highlight is quiet until the pointer is on the card.
    Color? highlightBackground() {
      final Text text = tester.widget<Text>(firstCard);
      final TextSpan span = text.textSpan! as TextSpan;
      for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
        final Color? color = child.style?.backgroundColor;
        if (color != null) return color;
      }
      return null;
    }

    final Color? idle = highlightBackground();
    expect(idle, isNotNull, reason: '命中的标签要有底色');

    final TestGesture pointer = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(firstCard));
    await tester.pumpAndSettle();
    expect(highlightBackground(), isNot(idle), reason: '悬浮时才变黄');

    // The header folds its cards away.
    await tester.tap(
      find.descendant(of: panel, matching: find.text('NRS 快速入门')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: panel, matching: find.textContaining('第一行')),
      findsNothing,
    );
  });

  testWidgets('Aa flips case sensitivity, which changes what matches', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[note('a', 'Plan', DateTime(2026, 1, 2))],
        );

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(NoteListPanel),
        matching: find.byType(TextField),
      ),
      'plan',
    );
    await tester.pumpAndSettle();
    expect(app.notes.visibleNotes, hasLength(1), reason: '忽略大小写时命中');

    await tester.tap(find.text('Aa'));
    await tester.pumpAndSettle();
    expect(app.notes.caseSensitive, isTrue);
    expect(app.notes.visibleNotes, isEmpty, reason: '区分大小写后 "plan" 不匹配 "Plan"');
    expect(find.text('未找到匹配结果。'), findsOneWidget);
  });

  testWidgets('collapsing the sidebar leaves the title bar and the editor', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('收起侧边栏  ·  Ctrl+\\'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteListPanel), findsNothing);
    // The file and search buttons point at a panel that is no longer there.
    expect(find.byTooltip('文件'), findsNothing);
    expect(find.byTooltip('搜索'), findsNothing);
    // The toggle lives in the title bar, so it is still there to bring the
    // sidebar back — nothing has to stay on screen just to hold it.
    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(find.byTooltip('展开侧边栏  ·  Ctrl+\\'), findsOneWidget);

    await tester.tap(find.byTooltip('展开侧边栏  ·  Ctrl+\\'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteListPanel), findsOneWidget);
    expect(find.byTooltip('文件'), findsOneWidget);
    expect(find.byTooltip('搜索'), findsOneWidget);
  });

  testWidgets('the outline yields to the editor in a narrow window', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester);
    expect(find.byType(OutlinePanel), findsOneWidget);

    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpAndSettle();
    expect(find.byType(OutlinePanel), findsNothing);

    app.settings.outlineVisible = false;
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(find.byType(OutlinePanel), findsNothing);
  });

  testWidgets('focus mode hides every region but the editor', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester);

    app.settings.focusMode = true;
    await tester.pumpAndSettle();
    // The caption stays: it is the only way to move the window.
    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(find.byType(NoteListPanel), findsNothing);
    expect(find.byType(OutlinePanel), findsNothing);
  });

  testWidgets('opening a note adds a tab, and its neighbour takes over', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[
            note('a', '甲', DateTime(2026, 3, 1)),
            note('b', '乙', DateTime(2026, 2, 1)),
          ],
        );
    Finder inBar(String text) => find.descendant(
      of: find.byType(AppTitleBar),
      matching: find.text(text),
    );

    // The first note is open on its own.
    expect(app.notes.openIds, <String>['a']);
    expect(inBar('甲'), findsOneWidget);
    expect(inBar('乙'), findsNothing);

    await tester.tap(treeRow('乙'));
    await tester.pumpAndSettle();
    expect(app.notes.openIds, <String>['a', 'b']);
    expect(app.notes.selectedId, 'b');
    expect(inBar('甲'), findsOneWidget);
    expect(inBar('乙'), findsOneWidget);

    // Tapping a tab switches to it without opening a second one.
    await tester.tap(inBar('甲'));
    await tester.pumpAndSettle();
    expect(app.notes.selectedId, 'a');
    expect(app.notes.openIds, <String>['a', 'b']);

    // Closing the active tab hands the editor to its neighbour.
    app.notes.closeTab('a');
    await tester.pumpAndSettle();
    expect(app.notes.openIds, <String>['b']);
    expect(app.notes.selectedId, 'b');
    expect(inBar('甲'), findsNothing);
  });

  testWidgets('tabs start at the editor and the outline button at the outline', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲', DateTime(2026, 3, 1)),
        note('b', '乙', DateTime(2026, 2, 1)),
      ],
    );
    await tester.tap(treeRow('乙'));
    await tester.pumpAndSettle();

    // A tab sits exactly above the column it opens.
    final Rect editor = tester.getRect(find.byType(EditorPane));
    final Finder tab = find
        .ancestor(
          of: find.descendant(
            of: find.byType(AppTitleBar),
            matching: find.text('甲'),
          ),
          matching: find.byType(AnimatedContainer),
        )
        .first;
    expect(tester.getRect(tab).left, editor.left);

    // The outline toggle shares the outline panel's left edge.
    final Rect outline = tester.getRect(find.byType(OutlinePanel));
    final Rect outlineButton = tester.getRect(
      find.byTooltip('大纲  ·  Ctrl+Shift+O'),
    );
    expect(outlineButton.left, outline.left);
  });

  testWidgets('right-clicking a file in the tree offers delete for that file', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          sort: SortMode.titleAsc,
          vault: <Note>[
            note('a', 'A 笔记', DateTime(2026, 3, 1)),
            note('b', 'B 笔记', DateTime(2026, 2, 1)),
            note('c', 'C 笔记', DateTime(2026, 1, 1)),
          ],
        );

    await tester.tap(treeRow('B 笔记'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();

    expect(find.text('删除笔记'), findsOneWidget);
    await tester.tap(find.text('删除笔记'));
    await tester.pumpAndSettle();

    expect(find.text('删除这篇笔记?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(app.notes.allNotes.map((Note n) => n.title), <String>[
      'A 笔记',
      'C 笔记',
    ]);
    expect(treeRow('B 笔记'), findsNothing);
  });

  testWidgets('shift+click takes the range, and delete takes the whole range', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          sort: SortMode.titleAsc,
          vault: <Note>[
            note('a', 'A 笔记', DateTime(2026, 3, 1)),
            note('b', 'B 笔记', DateTime(2026, 2, 1)),
            note('c', 'C 笔记', DateTime(2026, 1, 1)),
          ],
        );

    // The first row is the anchor, so shift+clicking the last one takes all three.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(treeRow('C 笔记'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    await tester.tap(treeRow('C 笔记'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('删除 3 篇笔记'), findsOneWidget);

    await tester.tap(find.text('删除 3 篇笔记'));
    await tester.pumpAndSettle();
    expect(find.text('删除这 3 篇笔记?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(app.notes.allNotes, isEmpty);
    expect(find.text('笔记库还是空的'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
  });

  testWidgets('a file row paints its label centred inside the highlight', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    final Finder label = treeRow('一篇笔记');
    expect(label, findsOneWidget);
    final Finder row = find
        .ancestor(of: label, matching: find.byType(Container))
        .first;

    final Rect labelRect = tester.getRect(label);
    final Rect rowRect = tester.getRect(row);
    expect(
      (labelRect.center.dy - rowRect.center.dy).abs(),
      lessThan(1),
      reason: '选中的高亮块和里面的文字必须共用一条中线',
    );
  });

  testWidgets('an expanded empty folder draws no placeholder line', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      folders: <String>['空目录'],
    );

    // Folders open expanded, so the empty folder is already on screen.
    expect(find.text('空目录'), findsOneWidget);
    expect(find.text('空文件夹'), findsNothing);

    await tester.tap(find.text('空目录'));
    await tester.pumpAndSettle();
    expect(find.text('空文件夹'), findsNothing);
  });

  testWidgets('新建文件夹 creates it outright, without asking for a name', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester);

    await tester.tap(find.byTooltip('新建文件夹'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(app.notes.folders, <String>['新建文件夹']);
    // Creating a folder says nothing: the new row appearing in the tree is the
    // only feedback the app gives.
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('F2 renames the clicked row, and Enter writes the new name', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester, sort: SortMode.titleAsc);

    await tester.tap(treeRow('一篇笔记'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();

    final Finder field = find.descendant(
      of: find.byType(VaultTree),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller?.text, '一篇笔记');

    await tester.enterText(field, '新的名字');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(app.notes.allNotes.single.title, '新的名字');
    expect(
      app.notes.allNotes.single.fileName,
      '新的名字.md',
      reason: '标题就是文件名,改名必须两者一起改',
    );
    expect(treeRow('新的名字'), findsOneWidget);
  });

  testWidgets('Esc leaves the name alone and closes the field', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester, sort: SortMode.titleAsc);

    await tester.tap(treeRow('一篇笔记'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();

    final Finder field = find.descendant(
      of: find.byType(VaultTree),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '不要保存');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(field, findsNothing);
    expect(app.notes.allNotes.single.title, '一篇笔记');
    expect(treeRow('一篇笔记'), findsOneWidget);
  });

  testWidgets('右键 moves the whole selection into a folder', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          sort: SortMode.titleAsc,
          folders: <String>['项目'],
          vault: <Note>[
            note('a', 'A 笔记', DateTime(2026, 3, 1)),
            note('b', 'B 笔记', DateTime(2026, 2, 1)),
            note('c', 'C 笔记', DateTime(2026, 1, 1)),
          ],
        );

    // The first row is the anchor, so shift+clicking the second takes two.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(treeRow('B 笔记'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    await tester.tap(treeRow('B 笔记'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('重命名'), findsOneWidget);
    await tester.tap(find.text('移到文件夹…'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();

    final List<String> moved = app.notes.allNotes
        .where((Note n) => n.folderPath == '项目')
        .map((Note n) => n.title)
        .toList();
    expect(moved, <String>['A 笔记', 'B 笔记']);
  });

  testWidgets('a folder can be renamed from its right-click menu', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
          folders: <String>['项目'],
        );

    await tester.tap(find.text('项目'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(VaultTree),
        matching: find.byType(TextField),
      ),
      '归档',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(app.notes.folders, <String>['归档']);
    expect(treeRow('归档'), findsOneWidget);
  });

  testWidgets('dragging a row onto a folder moves the note into it', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
          folders: <String>['项目'],
        );

    final Offset from = tester.getCenter(treeRow('A 笔记'));
    final Offset to = tester.getCenter(treeRow('项目'));
    await tester.drag(treeRow('A 笔记'), to - from);
    await tester.pumpAndSettle();

    expect(app.notes.allNotes.single.folderPath, '项目');
  });

  testWidgets(
    'dragging a note out of a folder into empty space takes it home',
    (WidgetTester tester) async {
      final ({SettingsController settings, NotesController notes}) app =
          await pumpShell(
            tester,
            vault: <Note>[
              note(
                'a',
                'A 笔记',
                DateTime(2026, 3, 1),
              ).copyWith(folderPath: '项目'),
            ],
          );

      final Rect tree = tester.getRect(find.byType(VaultTree));
      final Offset from = tester.getCenter(treeRow('A 笔记'));
      await tester.drag(treeRow('A 笔记'), Offset(0, tree.bottom - 24 - from.dy));
      await tester.pumpAndSettle();

      expect(app.notes.allNotes.single.folderPath, '', reason: '拖到列表下方就是拖回根目录');
    },
  );

  testWidgets('letting go on its own folder does not send a note to the root', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[
            note('a', 'A 笔记', DateTime(2026, 3, 1)).copyWith(folderPath: '项目'),
          ],
        );

    final Offset from = tester.getCenter(treeRow('A 笔记'));
    final Offset to = tester.getCenter(treeRow('项目'));
    await tester.drag(treeRow('A 笔记'), to - from);
    await tester.pumpAndSettle();

    expect(
      app.notes.allNotes.single.folderPath,
      '项目',
      reason: '文件夹要接住这一下,不能让它穿透到根目录',
    );
  });

  testWidgets('the drag preview names the folder under the pointer', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)).copyWith(folderPath: '项目'),
      ],
      folders: <String>['项目'],
    );

    final Offset from = tester.getCenter(treeRow('A 笔记'));
    final TestGesture gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));

    // Over the folder: the second line names where the row would land.
    await gesture.moveTo(tester.getCenter(treeRow('项目')));
    await tester.pump();
    expect(find.text('移动到「项目」'), findsOneWidget);
    expect(find.text('移到根目录'), findsNothing);

    // Off the folder but still in the list: the vault root takes over.
    final Rect tree = tester.getRect(find.byType(VaultTree));
    await gesture.moveTo(Offset(tree.center.dx, tree.bottom - 24));
    await tester.pump();
    expect(find.text('移到根目录'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('移到根目录'), findsNothing);
  });

  testWidgets('dragging a folder onto another folder moves it inside', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(tester, folders: <String>['甲', '乙']);

    final Offset from = tester.getCenter(treeRow('甲'));
    final Offset to = tester.getCenter(treeRow('乙'));
    await tester.drag(treeRow('甲'), to - from);
    await tester.pumpAndSettle();

    expect(app.notes.folders, contains('乙/甲'));
    expect(treeRow('甲'), findsOneWidget, reason: '甲现在挂在乙下面');
  });

  testWidgets('the file menu is the editor’s panel, not a Material popup', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await tester.tapAt(
      tester.getRect(treeRow('一篇笔记')).center,
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('打开'), findsOneWidget);
    expect(
      find.byType(PopupMenuItem<String>),
      findsNothing,
      reason: '文件菜单不该再用 Material 的弹出菜单',
    );

    // 220pt wide with 28pt rows: the editor's own geometry. That is what
    // "one menu design for the app" means in pixels.
    final Finder panel = find.ancestor(
      of: find.text('打开'),
      matching: find.byType(DecoratedBox),
    );
    expect(
      panel.evaluate().any((Element e) {
        final RenderObject? ro = e.renderObject;
        return ro is RenderBox && ro.size.width == kMenuPanelWidth;
      }),
      isTrue,
      reason: '文件菜单的宽度应该和编辑器菜单一致',
    );
    expect(
      tester.getSize(find.text('打开')).height,
      lessThanOrEqualTo(kMenuRowHeight),
      reason: '行高要和编辑器菜单一致',
    );
  });

  testWidgets('one click on the empty paper below the text starts editing', (
    WidgetTester tester,
  ) async {
    // Desktop is the platform that matters here: it is the one where a press
    // outside a `TextField` unfocuses the primary focus.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpShell(tester);

      // A brand-new note puts the caret in the *title*, so the body is unfocused
      // when the user goes to click into it.
      await tester.tap(find.byTooltip('新建笔记  ·  Ctrl+N'));
      await tester.pumpAndSettle();

      final Rect field = tester.getRect(
        find.byKey(const Key('nrs-editor-field')),
      );
      await tester.tapAt(Offset(field.center.dx, field.bottom + 80));
      await tester.pumpAndSettle();

      final LineEditableText body = tester.widget<LineEditableText>(
        find.byKey(const Key('nrs-editor-field')),
      );
      expect(body.focusNode.hasFocus, isTrue, reason: '第一次点击空白处就该拿到光标，不该点两次');

      // Let the save debounce and the "已保存" timer run out before the tree goes.
      await tester.pump(const Duration(seconds: 3));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('scrolling the editor moves the outline highlight', (
    WidgetTester tester,
  ) async {
    // Three chapters, far enough apart that a wheel scroll lands inside the
    // second one.
    final String body = <String>[
      '# 第一章',
      for (int i = 0; i < 24; i++) '第一章的正文 $i',
      '',
      '# 第二章',
      for (int i = 0; i < 24; i++) '第二章的正文 $i',
      '',
      '# 第三章',
      for (int i = 0; i < 24; i++) '第三章的正文 $i',
    ].join('\n');

    await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: '长笔记',
          body: body,
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
      ],
    );

    // The caret is still on line 0, so the first heading is lit.
    expect(tester.widget<OutlinePanel>(find.byType(OutlinePanel)).currentLine, 0);

    // Drag the paper's right margin — outside the text column, so this is a
    // scroll and not a text selection.
    final Rect editor = tester.getRect(find.byType(MarkdownEditor));
    await tester.dragFrom(
      Offset(editor.right - 12, editor.center.dy),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();

    final int line = tester
        .widget<OutlinePanel>(find.byType(OutlinePanel))
        .currentLine;
    expect(line, greaterThan(0), reason: '滚动之后大纲还停在第一章');
    // …and it is the heading of the chapter the viewport now starts in, not the
    // caret's line (which never moved).
    expect(line, greaterThanOrEqualTo(27), reason: '滚动到的位置已经在第二章里了');
  });

  testWidgets('the outline reuses its headings until the body changes', (
    WidgetTester tester,
  ) async {
    final ({SettingsController settings, NotesController notes}) app =
        await pumpShell(
          tester,
          vault: <Note>[
            Note(
              id: 'a',
              title: '笔记',
              body: '# 标题\n\n正文\n',
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 1, 2),
            ),
          ],
        );

    final List<Heading> first = tester
        .widget<OutlinePanel>(find.byType(OutlinePanel))
        .headings;
    expect(first.map((Heading h) => h.plainText), <String>['标题']);

    // 只改面板宽度：正文对象没变，大纲列表应当是同一个对象。
    app.settings.outlineWidth = app.settings.outlineWidth + 10;
    await tester.pump();
    final List<Heading> afterResize = tester
        .widget<OutlinePanel>(find.byType(OutlinePanel))
        .headings;
    expect(afterResize, same(first));

    // 正文变了，缓存必须跟着失效。
    app.notes.updateBody('# 新标题\n\n正文\n');
    await tester.pump();
    final List<Heading> afterEdit = tester
        .widget<OutlinePanel>(find.byType(OutlinePanel))
        .headings;
    expect(afterEdit, isNot(same(first)));
    expect(afterEdit.map((Heading h) => h.plainText), <String>['新标题']);

    // 让自动保存去抖与「已保存」计时器都跑完，避免留下 pending timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('全部展开 and 全部收起 are one button that flips', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)).copyWith(folderPath: '项目'),
      ],
    );

    // Everything opens expanded, so the button offers to close.
    expect(find.byTooltip('全部收起'), findsOneWidget);
    expect(find.byTooltip('全部展开'), findsNothing);
    expect(treeRow('A 笔记'), findsOneWidget);

    await tester.tap(find.byTooltip('全部收起'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('全部展开'), findsOneWidget);
    expect(find.byTooltip('全部收起'), findsNothing);
    expect(treeRow('A 笔记'), findsNothing, reason: '收起要把文件夹里的笔记藏起来');

    await tester.tap(find.byTooltip('全部展开'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('全部收起'), findsOneWidget);
    expect(treeRow('A 笔记'), findsOneWidget);
  });
}
