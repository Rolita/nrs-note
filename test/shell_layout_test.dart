import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/app_enums.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/core/utils/markdown_outline.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/canvas_store.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/canvas_controller.dart';
import 'package:nrs/state/notes_controller.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/state/template_settings.dart';
import 'package:nrs/ui/common/app_widgets.dart';
import 'package:nrs/ui/common/notices.dart';
import 'package:nrs/ui/canvas/canvas_board.dart';
import 'package:nrs/ui/editor/editor_context_menu.dart';
import 'package:nrs/ui/editor/editor_pane.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';
import 'package:nrs/ui/editor/image_panel.dart';
import 'package:nrs/ui/editor/outline_panel.dart';
import 'package:nrs/ui/editor/table_panel.dart';
import 'package:nrs/ui/graph/graph_view.dart';
import 'package:nrs/ui/image/image_pane.dart';
import 'package:nrs/ui/shell/app_shell.dart';
import 'package:nrs/ui/shell/function_rail.dart';
import 'package:nrs/ui/shell/note_list_panel.dart';
import 'package:nrs/ui/shell/pane_tab_strip.dart';
import 'package:nrs/ui/shell/title_bar.dart';
import 'package:nrs/ui/shell/title_bar_content.dart';
import 'package:nrs/ui/shell/vault_tree.dart';
import 'package:nrs/ui/templates/template_new_note_dialog.dart';
import 'package:nrs/ui/templates/template_picker.dart';

/// A tiny vault so the shell can be built without touching the real one.
/// 文件树只读 [CanvasController.canvases]，不碰存储。
///
/// 这些用例关心的是布局，不是白板；给一个永远空着的实现，省得为了一个
/// 空清单去建真目录。
class _NoCanvasStore implements CanvasStore {
  _NoCanvasStore({this.canvases = const <CanvasRef>[]});

  final List<CanvasRef> canvases;

  /// 内存回收站：白板删除用例要能验证「删掉 → 撤销 → 回来」这条路，
  /// 所以这里和桌面端一样留一份，而不是删了就没了。
  final Map<String, CanvasRef> trashed = <String, CanvasRef>{};
  int _nextTrashId = 0;

  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<CanvasRef>> list() async => canvases;

  @override
  Future<String> read(String relativePath) async => '{"nodes":[],"edges":[]}';

  @override
  Future<void> write(String relativePath, String contents) async {}

  @override
  Future<String> create(String folderPath, {String? title}) async {
    final String folder = folderPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final String base = canvasFileName(title);
    final Set<String> taken = <String>{
      for (final CanvasRef ref in canvases) ref.relativePath,
      ..._created,
    };
    for (int n = 1; n < 1000; n++) {
      final String name = n == 1 ? '$base.nrs' : '$base $n.nrs';
      final String relative = folder.isEmpty ? name : '$folder/$name';
      if (taken.contains(relative)) continue;
      _created.add(relative);
      return relative;
    }
    throw CanvasPathTaken('$base.nrs');
  }

  /// 建过但还没被 `createNew` 记进清单的路径，重名判断要用。
  final Set<String> _created = <String>{};

  @override
  Future<TrashEntry?> delete(String relativePath) async {
    final int index = canvases.indexWhere(
      (CanvasRef ref) => ref.relativePath == relativePath,
    );
    if (index < 0) return null;
    final CanvasRef board = canvases.removeAt(index);
    final String id = 'canvas-trash-${_nextTrashId++}';
    trashed[id] = board;
    return TrashEntry(
      id: id,
      originalPath: board.relativePath,
      title: board.title,
      deletedAt: DateTime(2026, 1, 2),
      size: 0,
    );
  }

  @override
  Future<bool> restoreTrash(String entryId) async {
    final CanvasRef? board = trashed.remove(entryId);
    if (board == null) return false;
    canvases.add(board);
    return true;
  }
}

class _VaultStore extends NoteStore {
  _VaultStore(
    this.notes, {
    List<String>? folders,
    this.files = const <VaultFile>[],
  }) : folders = <String>[...?folders];

  final List<Note> notes;
  final List<String> folders;
  final List<VaultFile> files;

  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<Note>> loadAll() async => List<Note>.of(notes);

  @override
  Future<List<VaultFile>> listFiles() async => files;

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
  Future<bool> folderHoldsOnlyNotes(
    String folderPath,
    Set<String> notePaths,
  ) async => Note.normalizeFolderPath(folderPath).isNotEmpty;

  @override
  Future<bool> deleteFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    folders.removeWhere(
      (String path) => path == folder || path.startsWith('$folder/'),
    );
    return true;
  }

  final Map<String, Note> trashed = <String, Note>{};

  @override
  Future<TrashEntry?> delete(Note note) async {
    notes.removeWhere((Note n) => n.id == note.id);
    final TrashEntry entry = TrashEntry(
      id: 'trash-${note.id}',
      originalPath: note.relativePath,
      title: note.title,
      deletedAt: DateTime(2026, 1, 2),
      size: note.toMarkdown().length,
    );
    trashed[entry.id] = note;
    return entry;
  }

  @override
  Future<Note?> restoreTrash(String entryId) async {
    final Note? note = trashed.remove(entryId);
    if (note == null) return null;
    notes.add(note);
    return note;
  }
}

void main() {
  /// 侧边栏顶上那颗「搜索」：就在「文件」右边。
  ///
  /// 侧边栏每一格都自带「文件 / 搜索」两页，搜索不再是功能栏上的一颗按钮。
  /// 分屏之后每格各有一颗，取最上面（也就是最先画出来）那格。
  Finder sideSearch() => find.descendant(
    of: find.byType(PaneTabStrip).first,
    matching: find.byTooltip('搜索'),
  );

  /// A vault row the test can point at without hitting the editor, which also
  /// renders the open note's title.
  Finder treeRow(String title) =>
      find.descendant(of: find.byType(VaultTree), matching: find.text(title));

  /// 一行现在填的是什么颜色。选中就是 `accentSoft`，没选中是透明或悬停色
  /// ——高亮只有这一处，所以量这个就等于量「选中了没有」。
  Color? rowFill(WidgetTester tester, String title) {
    final Finder container = find
        .ancestor(of: treeRow(title), matching: find.byType(Container))
        .first;
    final Container row = tester.widget<Container>(container);
    return (row.decoration as BoxDecoration?)?.color;
  }

  /// 树在启动时是全折叠的，所以要看、要拖文件夹里的东西，先得把它打开。
  ///
  /// 走工具栏那个按钮而不是逐个点文件夹：它和用户的第一反应一致，也不用
  /// 在用例里重复一遍路径。
  Future<void> expandEverything(WidgetTester tester) async {
    final Finder button = find.byTooltip('全部展开');
    if (button.evaluate().isEmpty) return;
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Note note(String id, String title, DateTime updatedAt) => Note(
    id: id,
    title: title,
    body: '# $title\n\n正文\n',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: updatedAt,
  );

  Future<
    ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
  >
  pumpShell(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    List<Note>? vault,
    List<String>? folders,
    List<CanvasRef>? canvases,
    List<VaultFile>? files,
    SortMode sort = SortMode.updatedDesc,

    /// 额外的偏好初值，比如「上次退出时正看着哪块白板」。
    Map<String, Object> extraPrefs = const <String, Object>{},
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues(<String, Object>{
      'nrs.sort': sort.name,
      ...extraPrefs,
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
      store: _VaultStore(
        vault ?? <Note>[note],
        folders: folders,
        files: files ?? const <VaultFile>[],
      ),
    )..sortMode = settings.sort;
    addTearDown(notes.dispose);
    await notes.bootstrap();

    // 文件树会读白板清单，外壳也会在白板视图里读当前打开的那份，所以这里
    // 必须有个 CanvasController。它不落盘：这些用例只关心布局。
    final CanvasController canvas = CanvasController(
      // 可变的一份：删除用例要把白板从清单里拿走，再从回收站放回来。
      store: _NoCanvasStore(
        canvases: List<CanvasRef>.of(canvases ?? const <CanvasRef>[]),
      ),
    );
    addTearDown(canvas.dispose);
    await canvas.refreshCanvases();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<NotesController>.value(value: notes),
          ChangeNotifierProvider<CanvasController>.value(value: canvas),
        ],
        child: MaterialApp(
          theme: AppTheme.build(settings.palette),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (settings: settings, notes: notes, canvas: canvas);
  }

  testWidgets('the shell is title bar, sidebar, editor and outline, in order', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(find.byType(NoteListPanel), findsOneWidget);
    expect(find.byType(OutlinePanel), findsOneWidget);

    // The file panel names itself, and its actions sit as one group at the
    // header's right edge — 排序、展开 / 收起、新建文件夹、新建笔记, left to
    // right. 侧边栏顶上那一页现在只是一颗文件夹图标，所以「文件」这两个字
    // 只出现在面板自己的头部（标题 + 计数）。
    expect(
      find.descendant(
        of: find.byType(NoteListPanel),
        matching: find.text('文件'),
      ),
      findsOneWidget,
    );
    const List<String> actions = <String>[
      '排序方式',
      // One expand/collapse button, showing 全部展开 while everything is folded
      // — which is how the tree starts.
      '全部展开',
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
    expect(find.byTooltip('全部收起'), findsNothing);
    // Nothing sits to their right: the group ends at the panel's own edge.
    final Rect panel = tester.getRect(find.byType(NoteListPanel));
    expect(panel.right - previousRight, lessThanOrEqualTo(AppSpace.xs));
    expect(find.text('一篇笔记'), findsWidgets);

    // 模板入口在左侧功能栏上方；底部工具组只留回收站和设置。
    final Finder templates = find.descendant(
      of: find.byType(AppRail),
      matching: find.byTooltip('插入模板  ·  Ctrl+P'),
    );
    expect(templates, findsOneWidget);
    expect(find.byTooltip('插入模板  ·  Ctrl+P'), findsOneWidget);
    final Rect rail = tester.getRect(find.byType(AppRail));
    final Rect templatesRect = tester.getRect(templates);
    final Rect trash = tester.getRect(find.byTooltip('回收站'));
    final Rect settingsButton = tester.getRect(find.byTooltip('设置  ·  Ctrl+,'));
    expect(templatesRect.top, lessThan(rail.center.dy));
    expect(trash.top, greaterThan(rail.center.dy));
    expect(settingsButton.top, greaterThan(trash.top));
  });

  testWidgets(
    'the tree follows renames and task edits without a full rebuild',
    (WidgetTester tester) async {
      final Note note = Note(
        id: 'task',
        title: '任务清单',
        body: '- [ ] 待办\n',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2),
      );
      final app = await pumpShell(tester, vault: <Note>[note]);
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
    },
  );

  /// 打开一篇笔记时，光标只是停在文首，并没有在编辑：第一行的 `# ` 不该一上屏
  /// 就摊开。用户点进正文之后，光标所在的那一行才揭示源码。
  testWidgets('a note opens rendered, with no line in source mode', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    RenderLineEditable field() =>
        tester.allRenderObjects.whereType<RenderLineEditable>().first;
    double markerWidth() => field()
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first
        .toRect()
        .width;

    expect(markerWidth(), 0, reason: '刚打开笔记，第一行的 # 不该露出来');

    final Rect caret = field().getLocalRectForCaret(
      const TextPosition(offset: 3),
    );
    await tester.tapAt(
      (field().localToGlobal(caret.topLeft) & caret.size).center,
    );
    await tester.pumpAndSettle();
    expect(markerWidth(), greaterThan(0), reason: '点进这一行后才展开源码');
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
    final app = await pumpShell(tester);
    expect(app.settings.listWidth, AppLayout.listDefaultWidth);
    expect(app.settings.rightPanelWidth, AppLayout.rightPanelWidth);

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
    expect(app.settings.rightPanelWidth, lessThan(AppLayout.rightPanelWidth));
  });

  testWidgets('侧边栏顶上三颗图标：文件 / 搜索 / 标签，功能栏不再管视图', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    // 侧边栏顶上是一排图标页：名字挂在 tooltip 上，标签条里没有「文件」这两个字。
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    Finder sideTab(String label) =>
        find.descendant(of: sideStrip, matching: find.byTooltip(label));
    expect(
      find.descendant(of: sideStrip, matching: find.text('文件')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: sideStrip,
        matching: find.byIcon(LucideIcons.folder),
      ),
      findsOneWidget,
    );
    // 搜索和标签都不在功能栏上：它们都是侧边栏顶上的图标。
    expect(
      find.descendant(
        of: find.byType(AppRail),
        matching: find.byTooltip('搜索'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(AppRail),
        matching: find.byTooltip('标签'),
      ),
      findsNothing,
    );
    expect(sideTab('标签'), findsOneWidget);

    await tester.tap(sideSearch());
    await tester.pumpAndSettle();
    expect(find.text('输入并开始搜索...'), findsOneWidget);
    expect(sideTab('搜索'), findsOneWidget);

    await tester.tap(sideTab('标签'));
    await tester.pumpAndSettle();
    expect(find.text('标签'), findsWidgets);
    expect(find.text('入门'), findsNothing);

    // 文件页一直排在标签条最左边：点它切回文件，三页都还在。
    expect(sideTab('文件'), findsOneWidget);
    await tester.tap(sideTab('文件'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('新建文件夹'), findsOneWidget);
    expect(sideTab('搜索'), findsOneWidget);
    expect(sideTab('标签'), findsOneWidget);
  });

  testWidgets(
    'the search panel waits with a hint instead of listing the vault',
    (WidgetTester tester) async {
      final app = await pumpShell(
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
      find.descendant(of: panel, matching: find.textContaining('正文里提到了甲')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panel, matching: find.byTooltip('删除')),
      findsNothing,
    );
  });

  testWidgets('a search result opens its note and jumps to the matched line', (
    WidgetTester tester,
  ) async {
    final StringBuffer body = StringBuffer('# 长文\n\n');
    for (int i = 0; i < 80; i++) {
      body.write('第 $i 行 填充内容\n');
    }
    body.write('这一行有独一无二的定位词\n');
    for (int i = 0; i < 20; i++) {
      body.write('尾部第 $i 行\n');
    }
    final List<String> lines = body.toString().split('\n');
    final int target = lines.indexWhere((String l) => l.contains('定位词'));
    expect(target, greaterThan(40), reason: '目标行必须远在首屏之外');

    final app = await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: '甲文',
          body: body.toString(),
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
        Note(
          id: 'b',
          title: '乙文',
          body: '# 乙文\n\n和搜索无关\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 3),
        ),
      ],
    );
    // 先打开另一篇，点击结果才真的需要切换过去。
    app.notes.select('b');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(NoteListPanel),
        matching: find.byType(TextField),
      ),
      '定位',
    );
    await tester.pumpAndSettle();

    final Finder snippet = find.descendant(
      of: find.byType(NoteListPanel),
      matching: find.textContaining('独一无二的定位词'),
    );
    expect(snippet, findsOneWidget);

    await tester.tap(snippet);
    await tester.pumpAndSettle();

    expect(app.notes.selectedId, 'a', reason: '点击结果要先切到命中的那篇笔记');

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final ({double top, double bottom}) band = field.visibleDocumentBounds;
    final double lineTop = field.lineTopFor(target);
    expect(
      lineTop <= band.bottom && lineTop >= band.top - 1,
      isTrue,
      reason: '命中的那一行要落进可见区间（band=$band lineTop=$lineTop）',
    );
    expect(
      field.debugSearchHighlightRects,
      greaterThan(0),
      reason: '跳过去之后，命中词在正文里要有色带，不必再逐行找',
    );
  });

  testWidgets('a tag query lists its notes with the line the tag sits on', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
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
    expect(find.descendant(of: panel, matching: find.text('闲话')), findsNothing);
  });

  testWidgets('a note with three matches is one group, always tinted', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: 'NRS 快速入门',
          fileName: 'NRS 快速入门.md',
          body: '# NRS 快速入门\n\n第一行 #入门\n第二行 #入门\n第三行 #入门\n',
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

    // 命中词一出现就着色，不再等指针移上来。
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
    expect(idle, isNotNull, reason: '命中的词要有底色');

    final TestGesture pointer = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(firstCard));
    await tester.pumpAndSettle();
    expect(highlightBackground(), idle, reason: '悬浮不再换色');

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
    final app = await pumpShell(
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
    // 侧边栏、编辑区、右栏（大纲默认开着）各一条。
    expect(find.byType(PaneTabStrip), findsNWidgets(3));

    await tester.tap(find.byTooltip('收起侧边栏  ·  Ctrl+\\'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteListPanel), findsNothing);
    // 侧边栏的标签条跟着走了，只剩编辑区和右栏那两条。
    expect(find.byType(PaneTabStrip), findsNWidgets(2));
    // 搜索那颗跟着侧边栏一起走：它就在侧边栏顶上的「文件」右边，不在功能栏上。
    expect(sideSearch(), findsNothing);
    // The toggle lives in the title bar, so it is still there to bring the
    // sidebar back — nothing has to stay on screen just to hold it.
    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(find.byTooltip('展开侧边栏  ·  Ctrl+\\'), findsOneWidget);

    await tester.tap(find.byTooltip('展开侧边栏  ·  Ctrl+\\'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteListPanel), findsOneWidget);
    expect(find.byType(PaneTabStrip), findsNWidgets(3));
    expect(
      find.descendant(
        of: find.byType(PaneTabStrip).first,
        matching: find.byTooltip('文件'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the outline yields to the editor in a narrow window', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(tester);
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
    final app = await pumpShell(tester);

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
    final app = await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲', DateTime(2026, 3, 1)),
        note('b', '乙', DateTime(2026, 2, 1)),
      ],
    );
    Finder inBar(String text) => find.descendant(
      of: find.byType(PaneTabStrip),
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

    // Closing the active tab hands the editor to its neighbour. 走标签上的 ×，
    // 不是直接调 `closeTab`——标签是格子自己的，光改控制器不会动这棵树。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('note-tab-a')),
        matching: find.byTooltip('关闭这一页'),
      ),
    );
    await tester.pumpAndSettle();
    expect(app.notes.openIds, <String>['b']);
    expect(app.notes.selectedId, 'b');
    expect(inBar('甲'), findsNothing);
  });

  testWidgets(
    'tabs start at the editor and the outline button at the outline',
    (WidgetTester tester) async {
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
              of: find.byType(PaneTabStrip),
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
    },
  );

  testWidgets('图片面板与大纲、表格共用最右一栏，列出当前文件的图片', (WidgetTester tester) async {
    final Note withImages = Note(
      id: 'img',
      title: '带图的笔记',
      body:
          '# 带图\n\n'
          '![一只猫](assets/a.png)\n\n'
          '字\n'
          '<img src="assets/b.png" width="320">\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 3, 1),
    );
    await pumpShell(tester, vault: <Note>[withImages]);

    expect(find.byType(OutlinePanel), findsOneWidget, reason: '默认是大纲');
    await tester.tap(find.byTooltip('图片'));
    await tester.pumpAndSettle();

    expect(find.byType(ImagePanel), findsOneWidget);
    expect(find.byType(OutlinePanel), findsNothing, reason: '同一栏，互斥');
    expect(find.text('一只猫'), findsOneWidget);
    expect(find.text('第 3 行 · 原尺寸'), findsOneWidget);
    expect(find.text('b.png'), findsOneWidget);
    expect(find.text('第 6 行 · 宽 320'), findsOneWidget);

    // 换成表格：图片面板让位，不是叠在一起。
    await tester.tap(find.byTooltip('表格'));
    await tester.pumpAndSettle();
    expect(find.byType(TablePanel), findsOneWidget);
    expect(find.byType(ImagePanel), findsNothing);

    // 再点一次表格按钮 = 收起这一栏，大纲不会自己回来。
    await tester.tap(find.byTooltip('表格'));
    await tester.pumpAndSettle();
    expect(find.byType(TablePanel), findsNothing);
    expect(find.byType(OutlinePanel), findsNothing);
    expect(find.byType(ImagePanel), findsNothing);
  });

  testWidgets('大纲 / 表格 / 图片三块面板共用同一列宽', (WidgetTester tester) async {
    final app = await pumpShell(tester);

    final double outline = tester.getRect(find.byType(OutlinePanel)).width;
    expect(outline, AppLayout.rightPanelWidth);

    await tester.tap(find.byTooltip('表格'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(TablePanel)).width,
      outline,
      reason: '换一块面板不该让这一列跳宽窄',
    );

    await tester.tap(find.byTooltip('图片'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ImagePanel)).width, outline);

    // 宽度只有一份：拖大纲的把手，表格面板换上来也是这个宽度。
    // 大纲按钮的提示里还带着快捷键，所以用前缀匹配。
    await tester.tap(find.byTooltip(RegExp('^大纲')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(ResizeHandle).last,
      const Offset(60, 0),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final double narrowed = app.settings.rightPanelWidth;
    expect(narrowed, lessThan(AppLayout.rightPanelWidth));
    expect(tester.getRect(find.byType(OutlinePanel)).width, narrowed);

    await tester.tap(find.byTooltip('表格'));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(TablePanel)).width,
      narrowed,
      reason: '三块面板共用一份宽度，不是各记各的',
    );
  });

  testWidgets('right-clicking a file in the tree offers delete for that file', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
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

    expect(find.text('删除这篇笔记？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(app.notes.allNotes.map((Note n) => n.title), <String>[
      'A 笔记',
      'C 笔记',
    ]);
    expect(treeRow('B 笔记'), findsNothing);
    // The menu closes on the row's tap, before the dialog opens. A menu route
    // left behind here paints nothing once its barrier is invisible but still
    // swallows every click over the app.
    expect(find.text('删除笔记'), findsNothing, reason: '删除完成后右键菜单必须已经关上');
    expect(find.text('移到文件夹…'), findsNothing);
  });

  testWidgets('Esc backs out of the delete dialog and keeps the note', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
      tester,
      sort: SortMode.titleAsc,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
    );

    await tester.tap(treeRow('A 笔记'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除笔记'));
    await tester.pumpAndSettle();
    expect(find.text('删除这篇笔记？'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('删除这篇笔记？'), findsNothing);
    expect(find.byKey(NoticeHost.cardKey), findsNothing);
    expect(app.notes.allNotes.map((Note n) => n.title), <String>['A 笔记']);
  });

  testWidgets('shift+click takes the range, and delete takes the whole range', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
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
    expect(find.text('删除这 3 篇笔记？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    // The undo card has a 6s countdown of its own; settle only far enough for
    // the dialog to leave and the card to arrive.
    await tester.pump(const Duration(milliseconds: 300));

    expect(app.notes.allNotes, isEmpty);
    expect(find.text('笔记库还是空的'), findsOneWidget);
    expect(find.text('已移入回收站'), findsOneWidget);
    expect(find.text('3 篇笔记'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    expect(
      find.text('删除 3 篇笔记'),
      findsNothing,
      reason: '菜单在点下删除时就该关掉，不能留一层隐形遮罩',
    );

    // The card hugs the window's top-right corner, clear of the caption.
    final Rect titleBar = tester.getRect(find.byType(AppTitleBar));
    final Rect card = tester.getRect(find.byKey(NoticeHost.cardKey));
    expect(titleBar.right - card.right, lessThanOrEqualTo(12));
    expect(card.top, greaterThanOrEqualTo(titleBar.bottom));
    expect(card.top - titleBar.bottom, lessThan(12));
    expect(card.width, lessThanOrEqualTo(352));
  });

  testWidgets('the function rail opens the trash', (WidgetTester tester) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('回收站'));
    await tester.pumpAndSettle();

    expect(find.text('回收站是空的'), findsOneWidget);
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

  testWidgets('新建文件夹 creates it outright, and goes straight into rename', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(tester);

    await tester.tap(find.byTooltip('新建文件夹'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(app.notes.folders, <String>['新建文件夹']);
    // Creating a folder says nothing: the new row appearing in the tree is the
    // only feedback the app gives.
    expect(find.byKey(NoticeHost.cardKey), findsNothing);

    // 建完就能打字：那一行已经变成输入框，名字整段选中，不用再点一下或
    // 按一次 F2。
    final Finder field = find.descendant(
      of: find.byType(VaultTree),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    final TextField input = tester.widget<TextField>(field);
    expect(input.controller?.text, '新建文件夹');
    expect(input.controller?.selection.baseOffset, 0);
    expect(
      input.controller?.selection.extentOffset,
      '新建文件夹'.length,
      reason: '整段选中：直接输入就是替换，不用先删一遍',
    );

    await tester.enterText(field, '项目');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(app.notes.folders, <String>['项目']);
    expect(
      find.descendant(
        of: find.byType(VaultTree),
        matching: find.byType(TextField),
      ),
      findsNothing,
      reason: '回车写完名字，输入框收起来',
    );
  });

  testWidgets('F2 renames the clicked row, and Enter writes the new name', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(tester, sort: SortMode.titleAsc);

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
    final app = await pumpShell(tester, sort: SortMode.titleAsc);

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
    final app = await pumpShell(
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
    final app = await pumpShell(
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

  testWidgets('a folder can be deleted from its menu, and the notice undoes it', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
      tester,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)).copyWith(folderPath: '项目'),
        note('b', 'B 笔记', DateTime(2026, 2, 1)),
      ],
      folders: <String>['项目'],
    );

    await tester.tap(
      find.descendant(of: find.byType(VaultTree), matching: find.text('项目')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('删除文件夹'), findsOneWidget);
    await tester.tap(find.text('删除文件夹'));
    await tester.pumpAndSettle();

    expect(find.text('删除文件夹「项目」？'), findsOneWidget);
    expect(find.textContaining('1 篇笔记将移入回收站'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The dialog's future resolves when the pop starts, so the delete and its
    // notice run while the barrier is still fading out. One more frame lets the
    // navigator drop the barrier before the notice is tapped.
    await tester.pump();

    expect(app.notes.allNotes.map((Note n) => n.title), <String>['B 笔记']);
    expect(treeRow('项目'), findsNothing);
    expect(find.text('已删除文件夹「项目」'), findsOneWidget);
    expect(find.text('1 篇笔记已移入回收站'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(
      app.notes.allNotes.map((Note n) => n.title),
      containsAll(<String>['A 笔记', 'B 笔记']),
    );
    expect(treeRow('项目'), findsOneWidget);
  });

  testWidgets('dragging a row onto a folder moves the note into it', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
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
      final app = await pumpShell(
        tester,
        vault: <Note>[
          note('a', 'A 笔记', DateTime(2026, 3, 1)).copyWith(folderPath: '项目'),
        ],
      );
      await expandEverything(tester);

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
    final app = await pumpShell(
      tester,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)).copyWith(folderPath: '项目'),
      ],
    );
    await expandEverything(tester);

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
    await expandEverything(tester);

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
    final app = await pumpShell(tester, folders: <String>['甲', '乙']);
    await expandEverything(tester);

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
    expect(
      tester.widget<OutlinePanel>(find.byType(OutlinePanel)).currentLine,
      0,
    );

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

  testWidgets(
    'the note title scrolls with the document, the path strip does not',
    (WidgetTester tester) async {
      final String body = <String>[
        '# 第一章',
        for (int i = 0; i < 80; i++) '正文 $i',
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

      final Finder title = find.byKey(const ValueKey<String>('title-a'));
      expect(title, findsOneWidget);
      final Rect titleBefore = tester.getRect(title);
      final Rect pathBefore = tester.getRect(find.text('笔记库'));

      // Drag the paper's right margin — outside the text column, so this is a
      // scroll and not a text selection.
      final Rect editor = tester.getRect(find.byType(MarkdownEditor));
      await tester.dragFrom(
        Offset(editor.right - 12, editor.center.dy),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getRect(title).top,
        lessThan(titleBefore.top - 100),
        reason: '标题是文档的第一行，滚动时必须跟着正文一起离开顶部',
      );
      expect(
        tester.getRect(find.text('笔记库')).top,
        pathBefore.top,
        reason: '路径条是面板的一部分，不随正文滚动',
      );
    },
  );

  testWidgets('the outline reuses its headings until the body changes', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(
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
    app.settings.rightPanelWidth = app.settings.rightPanelWidth + 10;
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

    // Everything starts folded, so the button offers to open.
    expect(find.byTooltip('全部展开'), findsOneWidget);
    expect(find.byTooltip('全部收起'), findsNothing);
    expect(treeRow('A 笔记'), findsNothing, reason: '折叠的文件夹不列里面的笔记');

    await tester.tap(find.byTooltip('全部展开'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('全部收起'), findsOneWidget);
    expect(find.byTooltip('全部展开'), findsNothing);
    expect(treeRow('A 笔记'), findsOneWidget);

    await tester.tap(find.byTooltip('全部收起'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('全部展开'), findsOneWidget);
    expect(treeRow('A 笔记'), findsNothing, reason: '收起要把文件夹里的笔记藏起来');
  });

  testWidgets('白板、图片和只有图片的文件夹都出现在文件树里，行尾带后缀', (WidgetTester tester) async {
    await pumpShell(
      tester,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      folders: <String>['assets'],
      canvases: <CanvasRef>[
        const CanvasRef(relativePath: '未命名白板.nrs', title: '未命名白板'),
      ],
      files: <VaultFile>[const VaultFile(relativePath: 'assets/pic.png')],
    );
    await expandEverything(tester);

    // 白板：行里是名字，行尾是 NRS。
    expect(treeRow('未命名白板'), findsOneWidget);
    expect(treeRow('NRS'), findsOneWidget);

    // assets 文件夹本身就是一行（它以前被藏起来了），里面那张图也在。
    expect(treeRow('assets'), findsOneWidget);
    expect(treeRow('pic'), findsOneWidget);
    expect(treeRow('PNG'), findsOneWidget);

    // 笔记是默认格式，行尾不加 MD —— 和 Obsidian 一致。
    expect(treeRow('MD'), findsNothing);
  });

  testWidgets('右键白板行可以删除，删掉的能从回收站撤销回来', (WidgetTester tester) async {
    await pumpShell(
      tester,
      sort: SortMode.titleAsc,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      canvases: <CanvasRef>[
        const CanvasRef(relativePath: '未命名白板.nrs', title: '未命名白板'),
      ],
    );

    await tester.tap(treeRow('未命名白板'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('删除白板'), findsOneWidget);

    await tester.tap(find.text('删除白板'));
    await tester.pumpAndSettle();
    expect(find.text('删除这块白板？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 和笔记那张确认卡片一样：删除和提示条在遮罩淡出期间就跑完了，
    // 再补一帧让导航栈把遮罩撤掉，才点得到提示条上的「撤销」。
    await tester.pump();

    expect(treeRow('未命名白板'), findsNothing);
    // 和笔记一样：先落进回收站，提示条上给一次撤销。
    expect(find.text('已移入回收站'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(treeRow('未命名白板'), findsOneWidget);
  });

  testWidgets('点一下白板行就高亮，用的和笔记行是同一种高亮', (WidgetTester tester) async {
    await pumpShell(
      tester,
      sort: SortMode.titleAsc,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      canvases: <CanvasRef>[
        const CanvasRef(relativePath: '白板一.nrs', title: '白板一'),
      ],
    );

    // 启动时正文里那篇笔记是选中的，先拿它的底色当基准。
    final Color? noteFill = rowFill(tester, 'A 笔记');
    expect(noteFill, isNotNull, reason: '打开着的笔记应该已经高亮');

    await tester.tap(treeRow('白板一'));
    await tester.pumpAndSettle();

    expect(find.byType(CanvasBoard), findsOneWidget, reason: '点一下也要把它打开');
    expect(rowFill(tester, '白板一'), noteFill, reason: '白板的高亮和笔记是同一块色');
    expect(
      rowFill(tester, 'A 笔记'),
      isNot(noteFill),
      reason: '白板亮着的时候笔记不该还亮着——同时亮两行，没人知道删除删哪个',
    );
  });

  testWidgets('Shift 连选能跨笔记和白板，删除只作用于选中的白板', (WidgetTester tester) async {
    await pumpShell(
      tester,
      sort: SortMode.titleAsc,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)),
        note('b', 'B 笔记', DateTime(2026, 2, 1)),
      ],
      canvases: <CanvasRef>[
        const CanvasRef(relativePath: '白板一.nrs', title: '白板一'),
        const CanvasRef(relativePath: '白板二.nrs', title: '白板二'),
      ],
    );

    // 锚点在 A 笔记，Shift 点到白板二：中间四行全进选中。
    await tester.tap(treeRow('A 笔记'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(treeRow('白板二'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    final Color? fill = rowFill(tester, '白板一');
    expect(fill, isNotNull);
    expect(rowFill(tester, '白板二'), fill);
    expect(rowFill(tester, 'A 笔记'), fill);
    expect(rowFill(tester, 'B 笔记'), fill, reason: '整段一起亮');

    // 右键白板：删除作用于选中的两块白板，笔记不掺进来。
    await tester.tap(treeRow('白板二'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('删除 2 块白板'), findsOneWidget);

    await tester.tap(find.text('删除 2 块白板'));
    await tester.pumpAndSettle();
    expect(find.text('删除这 2 块白板？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(treeRow('白板一'), findsNothing);
    expect(treeRow('白板二'), findsNothing);
    expect(treeRow('A 笔记'), findsOneWidget, reason: '笔记不该被一起删掉');
    expect(treeRow('B 笔记'), findsOneWidget);
    expect(find.text('已移入回收站'), findsOneWidget);
    expect(find.text('2 块白板'), findsOneWidget);
  });

  testWidgets('Shift 连选能跨笔记、白板和图片：文件列表里除了文件夹都能连选', (WidgetTester tester) async {
    await pumpShell(
      tester,
      sort: SortMode.titleAsc,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)),
        note('b', 'B 笔记', DateTime(2026, 2, 1)),
      ],
      canvases: <CanvasRef>[
        const CanvasRef(relativePath: '白板一.nrs', title: '白板一'),
      ],
      folders: <String>['assets'],
      files: <VaultFile>[
        const VaultFile(relativePath: 'assets/pic.png'),
        const VaultFile(relativePath: 'assets/doc.pdf'),
      ],
    );
    await expandEverything(tester);

    // 行的顺序是：assets 文件夹 → 里面的 doc、pic → 根目录的 A、B、白板一。
    // 锚点放在第一行图片上，Shift 点到最后的白板：中间所有行都进选中。
    await tester.tap(treeRow('pic'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final Color? fill = rowFill(tester, 'pic');
    expect(fill, isNotNull, reason: '点一下图片先选中它自己');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(treeRow('白板一'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    // 图片页里有解码转圈，`pumpAndSettle` 等不完，固定推两帧。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(rowFill(tester, 'A 笔记'), fill, reason: '笔记也算');
    expect(rowFill(tester, 'B 笔记'), fill);
    expect(rowFill(tester, '白板一'), fill, reason: 'Shift 点的那一行自己也要亮');
    expect(find.byType(CanvasBoard), findsNothing, reason: '连选不该顺手把白板打开');

    // 再往回 Shift 到 pdf（它在图片上面一行）：锚点不动，范围收成 doc..pic。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(treeRow('doc'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(rowFill(tester, 'doc'), fill, reason: 'pdf 也是文件列表里的一行');
    expect(rowFill(tester, 'pic'), fill);
    expect(rowFill(tester, 'A 笔记'), isNot(fill), reason: '范围收回来了');
  });

  testWidgets('图片也能当锚点：Shift 再点笔记，两行一起亮', (WidgetTester tester) async {
    await pumpShell(
      tester,
      sort: SortMode.titleAsc,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      folders: <String>['assets'],
      files: <VaultFile>[const VaultFile(relativePath: 'assets/pic.png')],
    );
    await expandEverything(tester);

    // 先点图片（会打开图片页），再 Shift 点笔记：从图片到笔记这一段都亮。
    await tester.tap(treeRow('pic'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(treeRow('A 笔记'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    // 图片页还开着，解码转圈让 `pumpAndSettle` 等不完。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final Color? fill = rowFill(tester, 'pic');
    expect(fill, isNotNull, reason: '图片当锚点也要亮');
    expect(rowFill(tester, 'A 笔记'), fill);
  });

  testWidgets('文件夹不参与连选：Shift 点文件夹只展开 / 收起，选中不变', (WidgetTester tester) async {
    await pumpShell(
      tester,
      sort: SortMode.titleAsc,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)),
        note('b', 'B 笔记', DateTime(2026, 2, 1)),
      ],
      folders: <String>['素材'],
    );
    await expandEverything(tester);

    await tester.tap(treeRow('A 笔记'));
    await tester.pumpAndSettle();
    final Color? noteFill = rowFill(tester, 'A 笔记');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(treeRow('素材'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();

    expect(rowFill(tester, 'A 笔记'), noteFill, reason: '选中没被 Shift 点文件夹改掉');
    expect(rowFill(tester, 'B 笔记'), isNot(noteFill), reason: '文件夹不在连选范围里');
  });

  testWidgets('功能栏的白板按钮直接新建一块未命名白板，不弹选择框', (WidgetTester tester) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('白板  ·  Ctrl+Shift+B'));
    await tester.pumpAndSettle();

    // 一块都没有时也能一步到位：按钮就是「新建」，不是「先挑再新建」。
    expect(treeRow('未命名白板'), findsOneWidget);
    expect(find.byType(CanvasBoard), findsOneWidget);

    // 再点一次是再要一块，重名自己加 2。
    await tester.tap(find.byTooltip('白板  ·  Ctrl+Shift+B'));
    await tester.pumpAndSettle();
    expect(treeRow('未命名白板 2'), findsOneWidget);
  });

  testWidgets('打开白板之后，标签条里多一页白板，和笔记标签一样', (WidgetTester tester) async {
    await pumpShell(tester);
    expect(find.byKey(const ValueKey<String>('canvas-tab')), findsNothing);

    await tester.tap(find.byTooltip('白板  ·  Ctrl+Shift+B'));
    await tester.pumpAndSettle();

    // 一页 tab，标题就是那块白板的名字——不是「白板」这种页类型名。
    final Finder tab = find.byKey(const ValueKey<String>('canvas-tab'));
    expect(tab, findsOneWidget);
    expect(
      find.descendant(of: tab, matching: find.text('未命名白板')),
      findsOneWidget,
    );
    expect(find.byType(CanvasBoard), findsOneWidget);
  });

  testWidgets('白板标签常驻：切回笔记再点它，回到那块白板', (WidgetTester tester) async {
    await pumpShell(tester);
    await tester.tap(find.byTooltip('白板  ·  Ctrl+Shift+B'));
    await tester.pumpAndSettle();
    expect(find.byType(CanvasBoard), findsOneWidget);

    // 点笔记标签回正文。
    await tester.tap(
      find.descendant(
        of: find.byType(PaneTabStrip),
        matching: find.text('一篇笔记'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CanvasBoard), findsNothing);
    // 白板那一页还在，只是没选中。
    expect(find.byKey(const ValueKey<String>('canvas-tab')), findsOneWidget);

    // 点回来，还是原来那块（不是重新新建的一块）。
    await tester.tap(find.byKey(const ValueKey<String>('canvas-tab')));
    await tester.pumpAndSettle();
    expect(find.byType(CanvasBoard), findsOneWidget);
  });

  testWidgets('上次退出时正看着白板，启动后打开那块并切过去', (WidgetTester tester) async {
    // `main` 里做的事：读完 vault 之后按会话把白板打开。外壳只负责
    // 「文档来了就切过去」——这里就照这个顺序走一遍。
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    app = await pumpShell(
      tester,
      canvases: <CanvasRef>[
        CanvasRef(
          relativePath: '未命名白板.nrs',
          title: '未命名白板',
          modified: DateTime(2026, 1, 1),
        ),
      ],
      extraPrefs: <String, Object>{
        'nrs.sessionCanvas': '未命名白板.nrs',
        'nrs.sessionCanvasActive': true,
      },
    );
    // 启动那一帧还没打开文档：主区还是正文。
    expect(find.byType(EditorPane), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('canvas-tab')), findsNothing);

    expect(await app.canvas.open('未命名白板.nrs'), isTrue);
    await tester.pumpAndSettle();

    // 文档一到，标签出现、主区切过去——不用用户再点一次。
    expect(find.byKey(const ValueKey<String>('canvas-tab')), findsOneWidget);
    expect(find.byType(CanvasBoard), findsOneWidget);
    expect(find.byType(EditorPane), findsNothing);
  });

  testWidgets('上次只是开着白板页、人在写笔记：启动后停在笔记', (WidgetTester tester) async {
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    app = await pumpShell(
      tester,
      canvases: <CanvasRef>[
        CanvasRef(
          relativePath: '未命名白板.nrs',
          title: '未命名白板',
          modified: DateTime(2026, 1, 1),
        ),
      ],
      extraPrefs: <String, Object>{'nrs.sessionCanvas': '未命名白板.nrs'},
    );

    expect(await app.canvas.open('未命名白板.nrs'), isTrue);
    await tester.pumpAndSettle();

    // 标签在（那块确实开着），但主区不该被抢走。
    expect(find.byKey(const ValueKey<String>('canvas-tab')), findsOneWidget);
    expect(find.byType(EditorPane), findsOneWidget);
    expect(find.byType(CanvasBoard), findsNothing);
  });

  testWidgets('点白板标签上的 ×：标签消失，主区回到正文', (WidgetTester tester) async {
    await pumpShell(tester);
    await tester.tap(find.byTooltip('白板  ·  Ctrl+Shift+B'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('canvas-tab')),
        matching: find.byIcon(LucideIcons.x),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('canvas-tab')), findsNothing);
    expect(find.byType(CanvasBoard), findsNothing);
    expect(find.byType(EditorPane), findsOneWidget);
    // 关的是那一页，不是那份文件：文件树里那一行还在。
    expect(treeRow('未命名白板'), findsOneWidget);
  });

  testWidgets('Ctrl+P 打开模板选择器，Enter 把模板插进当前笔记', (WidgetTester tester) async {
    final Note template = Note(
      id: 'tpl',
      title: '日报模板',
      folderPath: '模板',
      body: '## 今日进展\n\n- 完成了模板功能\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final app = await pumpShell(
      tester,
      vault: <Note>[note('a', '一篇笔记', DateTime(2026, 1, 2)), template],
    );

    // 功能栏的模板按钮和 Ctrl+P 打开的是同一个选择器。
    await tester.tap(find.byTooltip('插入模板  ·  Ctrl+P'));
    await tester.pumpAndSettle();
    expect(find.byType(TemplatePickerDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TemplatePickerDialog), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(TemplatePickerDialog), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(TemplatePickerDialog), findsNothing);
    expect(app.notes.draft?.body, contains('## 今日进展'));
    expect(app.notes.draft?.body, contains('完成了模板功能'));

    // Let the autosave debounce and the "已保存" timer run out.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('文件夹模板只在开关打开时套用到新建笔记', (WidgetTester tester) async {
    final Note template = Note(
      id: 'tpl',
      title: '会议模板',
      folderPath: '模板',
      body: '# 会议\n\n## 议程\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final app = await pumpShell(
      tester,
      vault: <Note>[note('a', '一篇笔记', DateTime(2026, 1, 2)), template],
    );
    app.settings.folderTemplateRules = <FolderTemplateRule>[
      const FolderTemplateRule(folderPath: '', templateId: 'tpl'),
    ];
    await tester.pump();

    // 开关关着：新笔记是空的，规则不生效。
    await tester.tap(find.byTooltip('新建笔记  ·  Ctrl+N'));
    await tester.pumpAndSettle();
    expect(app.notes.draft?.body, isEmpty);
    await tester.pump(const Duration(seconds: 3));

    app.settings.autoApplyFolderTemplates = true;
    await tester.pump();
    await tester.tap(find.byTooltip('新建笔记  ·  Ctrl+N'));
    await tester.pumpAndSettle();

    expect(app.notes.draft?.body, contains('# 会议'));
    expect(app.notes.draft?.body, contains('## 议程'));

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('模板快捷键按设置插入或新建，改动作后立刻生效', (WidgetTester tester) async {
    final Note template = Note(
      id: 'tpl',
      title: '日报模板',
      folderPath: '模板',
      body: '## 今日进展\n\n- 用快捷键插入\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final app = await pumpShell(
      tester,
      vault: <Note>[note('a', '一篇笔记', DateTime(2026, 1, 2)), template],
    );

    app.settings.templateHotkeys = <String, TemplateHotkey>{
      'tpl': TemplateHotkey(
        templateId: 'tpl',
        keyId: LogicalKeyboardKey.keyJ.keyId,
        action: TemplateAction.insert,
        control: true,
        shift: true,
      ),
    };
    await tester.pump();

    Future<void> pressChord(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await pressChord(LogicalKeyboardKey.keyJ);
    expect(app.notes.draft?.body, contains('用快捷键插入'));

    // 在同一页面改动作和组合键：外壳必须跟着设置重新注册。
    app.settings.templateHotkeys = <String, TemplateHotkey>{
      'tpl': TemplateHotkey(
        templateId: 'tpl',
        keyId: LogicalKeyboardKey.keyK.keyId,
        action: TemplateAction.create,
        control: true,
        shift: true,
      ),
    };
    await tester.pump();

    await pressChord(LogicalKeyboardKey.keyK);
    expect(find.byType(TemplateNewNoteDialog), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(TemplateNewNoteDialog),
        matching: find.byType(TextField),
      ),
      '今天的日报',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.byType(TemplateNewNoteDialog), findsNothing);
    final Note created = app.notes.allNotes.firstWhere(
      (Note n) => n.title == '今天的日报',
    );
    expect(created.body, contains('用快捷键插入'));

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Ctrl+Tab 换标签之后，正文仍然收得到键盘输入', (WidgetTester tester) async {
    // 用户报告：Ctrl+Tab 切到另一个标签后打不进任何字，得用鼠标再点一下
    // 那个标签才行。根因是正文输入框按 `documentId` 整块重建，而焦点节点
    // 是外面传进来的、一直有焦点——新输入框的 State 从来没收到过「获得焦点」
    // 的回调，也就不会开输入连接，键盘事件无处可去。
    final Note first = Note(
      id: 'a',
      title: '甲',
      body: '甲的正文\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );
    final Note second = Note(
      id: 'b',
      title: '乙',
      body: '乙的正文\n',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 3),
    );
    final app = await pumpShell(tester, vault: <Note>[first, second]);

    // 两个标签都开着，当前停在乙。
    app.notes.select('a');
    await tester.pumpAndSettle();
    app.notes.select('b');
    await tester.pumpAndSettle();
    expect(app.notes.selectedId, 'b');

    // 点一下正文：焦点落在输入框上，输入连接随之打开。
    await tester.tap(find.byKey(const Key('nrs-editor-field')));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: '点正文应该连上输入');

    // Ctrl+Tab 回到甲。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(app.notes.selectedId, 'a');

    // 焦点还在正文上，键盘输入就该直接落进这一份正文。
    final LineEditableText field = tester.widget<LineEditableText>(
      find.byKey(const Key('nrs-editor-field')),
    );
    expect(field.focusNode.hasFocus, isTrue, reason: '换标签不该把焦点扔掉');
    expect(
      tester.testTextInput.hasAnyClients,
      isTrue,
      reason: '换标签后输入框重建了，输入连接却没重开，键盘打字会全部丢失',
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '甲的正文新字\n',
        selection: TextSelection.collapsed(offset: 7),
      ),
    );
    await tester.pump();
    expect(app.notes.draft?.body, contains('新字'));

    // 光标闪烁的计时器得收掉，否则测试结束时会报 timersPending。
    field.focusNode.unfocus();
    // 这一笔写入的自动保存还在防抖里（300ms 落笔，之后还有 2s 的收尾计时），
    // 等它走完再结束。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('没打开图谱时标签条里只有笔记，两个入口都在左侧功能栏', (WidgetTester tester) async {
    await pumpShell(tester);

    // 图谱页只在打开时出现；没打开时标签条里只剩笔记。
    expect(find.text('关系图谱'), findsNothing);
    expect(find.text('白板'), findsNothing);

    final Finder graph = find.byTooltip('关系图谱');
    final Finder canvas = find.byTooltip('白板  ·  Ctrl+Shift+B');
    expect(graph, findsOneWidget);
    expect(canvas, findsOneWidget);

    // 图谱在白板上面，中间不夹别的东西。
    final Rect graphRect = tester.getRect(graph);
    final Rect canvasRect = tester.getRect(canvas);
    expect(graphRect.bottom, lessThanOrEqualTo(canvasRect.top));

    // 都在功能栏里，而不是飘到标题栏去。
    final Rect rail = tester.getRect(find.byType(AppRail));
    expect(rail.contains(graphRect.topLeft), isTrue);
    expect(rail.contains(canvasRect.topLeft), isTrue);
  });

  testWidgets('点功能栏的图谱按钮切到图谱，再点笔记标签切回来', (WidgetTester tester) async {
    await pumpShell(tester);

    await tester.tap(find.byTooltip('关系图谱'));
    await tester.pumpAndSettle();
    expect(find.byType(GraphView), findsOneWidget);

    await tester.tap(find.text('一篇笔记').first);
    await tester.pumpAndSettle();
    expect(find.byType(EditorPane), findsOneWidget);
  });

  testWidgets('打开图谱时新增关系图谱页，点 × 才关掉它', (WidgetTester tester) async {
    await pumpShell(tester);

    expect(find.text('关系图谱'), findsNothing, reason: '没打开时没有这一页');

    await tester.tap(find.byTooltip('关系图谱'));
    await tester.pumpAndSettle();
    expect(find.text('关系图谱'), findsOneWidget, reason: '打开图谱时新增这一页');

    // 和笔记页一样：切到笔记它还在，点它可以切回图谱。
    await tester.tap(find.text('一篇笔记').first);
    await tester.pumpAndSettle();
    expect(find.byType(EditorPane), findsOneWidget);
    expect(find.text('关系图谱'), findsOneWidget, reason: '切走只是不显示，不等于关掉');

    await tester.tap(find.text('关系图谱'));
    await tester.pumpAndSettle();
    expect(find.byType(GraphView), findsOneWidget, reason: '点页切回图谱');

    // 图谱页现在选中，× 可点。按那一页的 key 找，别按「最后一个 ×」——
    // 一格里排着几页时，顺序是布局细节，不是要断言的东西。
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('graph-tab')),
        matching: find.byTooltip('关闭这一页'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(GraphView), findsNothing, reason: '× 关掉图谱');
    expect(find.text('关系图谱'), findsNothing, reason: '关掉后这一页也消失');
    expect(find.byType(EditorPane), findsOneWidget);
  });

  testWidgets('进图谱收起右侧那一栏，退出图谱自己回来', (WidgetTester tester) async {
    final app = await pumpShell(tester);

    expect(find.byType(OutlinePanel), findsOneWidget, reason: '默认大纲是开着的');

    await tester.tap(find.byTooltip('关系图谱'));
    await tester.pumpAndSettle();

    expect(find.byType(OutlinePanel), findsNothing, reason: '图谱要整块画布');
    expect(
      find.byTooltip(RegExp('^大纲')),
      findsNothing,
      reason: '面板收起来了，开关也跟着走，不然点了没反应',
    );
    expect(
      app.settings.outlineVisible,
      isTrue,
      reason: '只是不显示，不能改用户的选择——退出图谱要原样还回来',
    );

    await tester.tap(find.text('一篇笔记').first);
    await tester.pumpAndSettle();

    expect(find.byType(OutlinePanel), findsOneWidget, reason: '退出图谱要还原');
    expect(find.byTooltip(RegExp('^大纲')), findsOneWidget);
  });

  testWidgets('图谱开着时点文件树里的笔记，主区切回正文', (WidgetTester tester) async {
    final app = await pumpShell(
      tester,
      vault: <Note>[
        note('a', 'A 笔记', DateTime(2026, 3, 1)),
        note('b', 'B 笔记', DateTime(2026, 3, 2)),
      ],
    );

    await tester.tap(find.byTooltip('关系图谱'));
    await tester.pumpAndSettle();
    expect(find.byType(GraphView), findsOneWidget);

    await tester.tap(treeRow('A 笔记'));
    await tester.pumpAndSettle();

    expect(find.byType(GraphView), findsNothing, reason: '点笔记要回到正文');
    expect(find.byType(EditorPane), findsOneWidget);
    expect(app.notes.selectedId, 'a');
  });

  testWidgets('白板开着时点文件树里的笔记，主区切回正文', (WidgetTester tester) async {
    final app = await pumpShell(
      tester,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      canvases: <CanvasRef>[const CanvasRef(relativePath: '板.nrs', title: '板')],
    );

    await tester.tap(treeRow('板'));
    await tester.pumpAndSettle();
    expect(find.byType(CanvasBoard), findsOneWidget);

    await tester.tap(treeRow('A 笔记'));
    await tester.pumpAndSettle();

    expect(find.byType(CanvasBoard), findsNothing, reason: '点笔记要回到正文');
    expect(find.byType(EditorPane), findsOneWidget);
    expect(app.notes.selectedId, 'a');
  });

  /// 图片页里有个解码转圈，`pumpAndSettle` 会一直等它转完——固定推两帧。
  Future<void> settleImage(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('文件树点图片：主区换成图片页，标题栏多一个图片 tab', (WidgetTester tester) async {
    await pumpShell(
      tester,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      folders: <String>['assets'],
      files: <VaultFile>[const VaultFile(relativePath: 'assets/pic.png')],
    );
    await expandEverything(tester);

    await tester.tap(treeRow('pic'));
    await settleImage(tester);

    expect(find.byType(ImagePane), findsOneWidget);
    expect(find.byType(EditorPane), findsNothing, reason: '正文要让位给图片');
    // tab 上是带后缀的文件名，文件树那一行只有名字——两者不会撞。
    expect(find.text('pic.png'), findsOneWidget);
  });

  testWidgets('所有图片共用同一个 tab：点第二张只换内容，不多开一页', (WidgetTester tester) async {
    await pumpShell(
      tester,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      folders: <String>['assets'],
      files: <VaultFile>[
        const VaultFile(relativePath: 'assets/a.png'),
        const VaultFile(relativePath: 'assets/b.png'),
      ],
    );
    await expandEverything(tester);

    await tester.tap(treeRow('a'));
    await settleImage(tester);
    expect(find.text('a.png'), findsOneWidget);

    await tester.tap(treeRow('b'));
    await settleImage(tester);

    expect(find.text('b.png'), findsOneWidget);
    expect(find.text('a.png'), findsNothing, reason: '换图不是再开一页');
    expect(find.byType(ImagePane), findsOneWidget);
  });

  testWidgets('点图片 tab 上的 ×：tab 消失，主区回到正文', (WidgetTester tester) async {
    await pumpShell(
      tester,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      folders: <String>['assets'],
      files: <VaultFile>[const VaultFile(relativePath: 'assets/pic.png')],
    );
    await expandEverything(tester);

    await tester.tap(treeRow('pic'));
    await settleImage(tester);
    expect(find.byType(ImagePane), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('image-tab')),
        matching: find.byIcon(LucideIcons.x),
      ),
    );
    await settleImage(tester);

    expect(find.byKey(const ValueKey<String>('image-tab')), findsNothing);
    expect(find.byType(ImagePane), findsNothing);
    expect(find.byType(EditorPane), findsOneWidget);
  });

  testWidgets('图片 tab 常驻：去看笔记再点它，回到原来那张图', (WidgetTester tester) async {
    await pumpShell(
      tester,
      vault: <Note>[note('a', 'A 笔记', DateTime(2026, 3, 1))],
      folders: <String>['assets'],
      files: <VaultFile>[const VaultFile(relativePath: 'assets/pic.png')],
    );
    await expandEverything(tester);

    await tester.tap(treeRow('pic'));
    await settleImage(tester);
    expect(find.byType(ImagePane), findsOneWidget);

    // 笔记 tab 和文件树里的行同名，得限定在标题栏里找。
    await tester.tap(
      find.descendant(
        of: find.byType(PaneTabStrip),
        matching: find.text('A 笔记'),
      ),
    );
    await settleImage(tester);
    expect(find.byType(ImagePane), findsNothing, reason: '回正文');
    expect(find.text('pic.png'), findsOneWidget, reason: '图片 tab 要留在条上');

    await tester.tap(find.text('pic.png'));
    await settleImage(tester);
    expect(find.byType(ImagePane), findsOneWidget);
  });

  testWidgets('从文件列表把图片拖进白板：卡片存路径，不拷贝字节', (WidgetTester tester) async {
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    s = await pumpShell(
      tester,
      canvases: <CanvasRef>[
        const CanvasRef(relativePath: '白板一.nrs', title: '白板一'),
      ],
      folders: <String>['assets'],
      files: <VaultFile>[const VaultFile(relativePath: 'assets/pic.png')],
    );

    await tester.tap(treeRow('白板一'));
    await tester.pumpAndSettle();
    // 打开白板之后树会重建一次（白板清单刷新），文件夹回到折叠态——所以
    // 展开要放在这之后，不然找不到文件夹里那张图。
    await expandEverything(tester);

    final Finder board = find.byType(CanvasBoard);
    expect(board, findsOneWidget);
    final Rect boardRect = tester.getRect(board);

    final Offset from = tester.getCenter(treeRow('pic'));
    final Offset to = Offset(boardRect.left + 400, boardRect.top + 300);
    final TestGesture gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    for (int i = 1; i <= 12; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final CanvasDocument? doc = s.canvas.document;
    final CanvasNode card = doc!.nodes.single;
    expect(card, isA<FileNode>());
    expect(
      (card as FileNode).file,
      'assets/pic.png',
      reason: '板子引用库里的那张图，不是把它拷进白板',
    );

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('从文件列表把笔记拖进白板：卡片落在松手的地方，不是拖拽的起点', (WidgetTester tester) async {
    // 这条用例走的是真外壳 + 真手势：拖拽途中文件树会重建（选中态、悬停
    // 文件夹高亮），载荷因此换过好几份。曾经指针记在载荷里，于是白板读到
    // 的是**拖拽开始时**那一份的指针——卡片一路落回列表那一侧。
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    s = await pumpShell(
      tester,
      canvases: <CanvasRef>[
        const CanvasRef(relativePath: '白板一.nrs', title: '白板一'),
      ],
    );

    await tester.tap(treeRow('白板一'));
    await tester.pumpAndSettle();

    final Finder board = find.byType(CanvasBoard);
    expect(board, findsOneWidget);
    final Rect boardRect = tester.getRect(board);

    final Offset from = tester.getCenter(treeRow('一篇笔记'));
    final Offset to = Offset(boardRect.left + 400, boardRect.top + 300);
    final TestGesture gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    // 一步一步挪过去，中途每一次都要让树有机会重建。
    for (int i = 1; i <= 12; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / 12)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    final CanvasDocument? doc = s.canvas.document;
    final CanvasNode card = doc!.nodes.single;
    final CanvasBoardState state = tester.state<CanvasBoardState>(board);
    // 世界坐标 → 画布内坐标 → 屏幕坐标，和用户眼睛看到的对齐。
    final Offset onScreen =
        state.debugCamera.toScreen(card.rect.topLeft, state.debugStage) +
        boardRect.topLeft;
    expect(onScreen.dx, closeTo(to.dx, 1));
    expect(onScreen.dy, closeTo(to.dy, 1));

    // 落卡会排一次自动保存；把它推过去，别给下一条用例留一个挂着的定时器。
    await tester.pump(const Duration(seconds: 2));
  });

  // ---------------------------------------------------------------- 分块

  /// 标签条上那一页。同名文字在文件树里也有，所以要限定在顶部栏里找。
  Finder tabOf(String label) => find.descendant(
    of: find.byType(PaneTabStrip),
    matching: find.text(label),
  );

  /// 从 [from] 拖到 [to]。
  ///
  /// ⛔ 必须分成好几小步：`Draggable` 的识别器在一次大跳里只来得及判「拖
  /// 开始了」，那一次位移被 `onStart` 吃掉，`onMove` 一次都收不到，落点就
  /// 永远停在起点。
  Future<void> dragTo(
    WidgetTester tester,
    Offset from,
    Offset to, {
    int steps = 10,
  }) async {
    final TestGesture gesture = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 20));
    for (int i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('左右分屏：把一页拖到右边缘，两格并排、各看一篇，点哪格哪格能写', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲文', DateTime(2026, 1, 2)),
        note('b', '乙文', DateTime(2026, 1, 2)),
      ],
    );
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();

    expect(find.byType(EditorPane), findsOneWidget);
    // 只有一格时没有「关掉这一格」——容器总得留一格。
    expect(find.byTooltip('关掉这一格'), findsNothing);
    // 分割只走拖拽：格子里不再有「左右 / 上下分屏」按钮。
    expect(find.byTooltip('左右分屏'), findsNothing);
    expect(find.byTooltip('上下分屏'), findsNothing);

    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      Offset(pane.right - 12, pane.center.dy),
    );

    final Finder panes = find.byType(EditorPane);
    expect(panes, findsNWidgets(2));
    final Rect first = tester.getRect(panes.at(0));
    final Rect second = tester.getRect(panes.at(1));
    // 左右分屏 = 并排，不是上下叠。
    expect(second.left, greaterThanOrEqualTo(first.right));
    expect(first.top, second.top);
    // 两格等高，宽度大致均分（分割线占 5px）。
    expect(first.height, closeTo(second.height, 0.5));
    expect(first.width, closeTo(second.width, 1));

    // 被拖走的那一页带着「活的那份」落在新格里，原来那格钉在剩下的那篇
    // 上、转成只读。
    expect(tester.widget<EditorPane>(panes.at(0)).readOnly, isTrue);
    expect(tester.widget<EditorPane>(panes.at(1)).readOnly, isFalse);
    expect(tester.widget<EditorPane>(panes.at(0)).noteId, 'a');
    expect(tester.widget<EditorPane>(panes.at(1)).noteId, isNull);

    // 点一下左边那格：能写的那份交给它，右边转成只读。
    await tester.tapAt(first.topLeft + const Offset(12, 8));
    await tester.pumpAndSettle();
    expect(tester.widget<EditorPane>(panes.at(0)).readOnly, isFalse);
    expect(tester.widget<EditorPane>(panes.at(1)).readOnly, isTrue);

    // 只读格钉在它当时显示的那一篇上，不会跟着左侧列表的选中乱跑。
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditorPane>(panes.at(0)).noteId, isNull);
    expect(tester.widget<EditorPane>(panes.at(1)).noteId, 'b');

    // 关掉一格回到单格。
    await tester.tap(find.byTooltip('关掉这一格').first);
    await tester.pumpAndSettle();
    expect(find.byType(EditorPane), findsOneWidget);
    expect(find.byTooltip('关掉这一格'), findsNothing);
  });

  testWidgets('上下分屏：把一页拖到下边缘，两格上下叠着，分割线能拖', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲文', DateTime(2026, 1, 2)),
        note('b', '乙文', DateTime(2026, 1, 2)),
      ],
    );
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();

    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      Offset(pane.center.dx, pane.bottom - 12),
    );

    final Finder panes = find.byType(EditorPane);
    expect(panes, findsNWidgets(2));
    final Rect top = tester.getRect(panes.at(0));
    final Rect bottom = tester.getRect(panes.at(1));
    expect(bottom.top, greaterThanOrEqualTo(top.bottom));
    expect(top.left, bottom.left);
    expect(top.width, closeTo(bottom.width, 0.5));

    // 拖分割线：上格变矮，下格变高，总高不变。
    final double total = top.height + bottom.height;
    final Offset seam = Offset(top.center.dx, top.bottom + 2.5);
    await tester.dragFrom(seam, const Offset(0, -80));
    await tester.pumpAndSettle();

    final Rect top2 = tester.getRect(panes.at(0));
    final Rect bottom2 = tester.getRect(panes.at(1));
    expect(top2.height, lessThan(top.height - 40));
    expect(top2.height + bottom2.height, closeTo(total, 1));
  });

  testWidgets('侧边栏只能拖拽分割：没有分割 / 关闭按钮，拖到下面多一格', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    expect(find.byType(NoteListPanel), findsOneWidget);
    // 用户要求：侧边栏不再有「上下分割」，也没有「关掉这一格」。
    expect(find.byTooltip('上下分割'), findsNothing);
    expect(find.byTooltip('关掉这一格'), findsNothing);

    final Finder sideStrip = find.byType(PaneTabStrip).first;
    final Rect side = tester.getRect(find.byType(NoteListPanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: sideStrip, matching: find.byTooltip('标签')),
      ),
      Offset(side.center.dx, side.bottom - 10),
    );

    final Finder panels = find.byType(NoteListPanel);
    expect(panels, findsNWidgets(2));
    final Rect upper = tester.getRect(panels.at(0));
    final Rect lower = tester.getRect(panels.at(1));
    expect(lower.top, greaterThanOrEqualTo(upper.bottom));
    expect(upper.left, lower.left);

    // 两格各有一份标题：它们不是同一个 State 被画了两次。拖出来的新格
    // 只装搬过去的那一页（标签），上面那格还是文件。
    expect(
      find.descendant(of: panels.at(0), matching: find.text('文件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: panels.at(1), matching: find.text('标签')),
      findsOneWidget,
    );
    expect(find.byTooltip('关掉这一格'), findsNothing);
  });

  testWidgets('把图谱 tab 拖到格子右边缘：右边多一格装着它', (WidgetTester tester) async {
    await pumpShell(tester);
    // 打开图谱再切回笔记：图谱页留在标签条里，人回到正文。
    await tester.tap(find.byTooltip('关系图谱'));
    await tester.pumpAndSettle();
    await tester.tap(tabOf('一篇笔记'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorPane), findsOneWidget);
    expect(find.byType(GraphView), findsNothing, reason: '切回笔记后图谱只是不显示');

    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('关系图谱')),
      Offset(pane.right - 12, pane.center.dy),
    );

    // 落在右边缘 = 在右边切一格，左边原来那一格还在。
    expect(find.byType(EditorPane), findsOneWidget);
    expect(find.byType(GraphView), findsOneWidget);
    final Rect note = tester.getRect(find.byType(EditorPane));
    final Rect graph = tester.getRect(find.byType(GraphView));
    expect(graph.left, greaterThanOrEqualTo(note.right));
    expect(note.top, graph.top);
  });

  testWidgets('拖到格子中间就换掉这一格，不分裂', (WidgetTester tester) async {
    await pumpShell(tester);
    await tester.tap(find.byTooltip('关系图谱'));
    await tester.pumpAndSettle();
    await tester.tap(tabOf('一篇笔记'));
    await tester.pumpAndSettle();

    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(tester, tester.getCenter(tabOf('关系图谱')), pane.center);

    expect(find.byType(EditorPane), findsNothing);
    expect(find.byType(GraphView), findsOneWidget);
    // 同一格、同一个左上角；右边更宽是因为图谱收起右侧那一栏（大纲）。
    final Rect graph = tester.getRect(find.byType(GraphView));
    expect(graph.left, pane.left);
    expect(graph.top, pane.top);
    expect(graph.right, greaterThan(pane.right));
  });

  testWidgets('把笔记拖进图谱那一格：图谱让位但不重建，拖回来还是同一份 State', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.byTooltip('关系图谱'));
    await tester.pumpAndSettle();

    final GraphViewState graphState = tester.state<GraphViewState>(
      find.byType(GraphView),
    );

    // 笔记 tab 拖到中间：这一格换成笔记，图谱被顶掉。
    final Rect pane = tester.getRect(find.byType(GraphView));
    await dragTo(tester, tester.getCenter(tabOf('一篇笔记')), pane.center);
    expect(find.byType(EditorPane), findsOneWidget);
    expect(find.byType(GraphView), findsNothing, reason: '不在格子里就不显示');

    // 但它只是被停靠在一边（Offstage），State 还在——相机和力导向都没重来。
    expect(
      find.byType(GraphView, skipOffstage: false),
      findsOneWidget,
      reason: '顶掉的图谱应该停在停靠区里，而不是被摘掉',
    );

    // 再拖回来：还是原来那个 State 对象。
    await dragTo(tester, tester.getCenter(tabOf('关系图谱')), pane.center);
    expect(
      identical(
        tester.state<GraphViewState>(find.byType(GraphView)),
        graphState,
      ),
      isTrue,
      reason: '图谱从停靠区搬回格子，State 必须跟着走',
    );
  });

  testWidgets('每一格都裁在自己的矩形里：自绘的画布不会画到隔壁格', (WidgetTester tester) async {
    await pumpShell(tester);
    await tester.tap(find.byTooltip('白板  ·  Ctrl+Shift+B'));
    await tester.pumpAndSettle();

    // 白板占着唯一那一格，把它的 tab 拖到右边缘：右边长出一格白板，
    // 左边那格退回笔记——正好是「白板和笔记并排」。
    final Rect pane = tester.getRect(find.byType(CanvasBoard));
    await dragTo(
      tester,
      tester.getCenter(tabOf('未命名白板')),
      Offset(pane.right - 12, pane.center.dy),
    );
    expect(find.byType(CanvasBoard), findsOneWidget);
    expect(find.byType(EditorPane), findsOneWidget);

    // 白板是 `CustomPaint` + 世界坐标：画到盒子外面不会被自动截断。以前它
    // 独占整块编辑区，看不出来；装进半格之后，越界的网格和卡片就盖到隔壁
    // 的笔记上，甚至一路盖到侧边栏。所以每一格外面必须有一层同尺寸的裁剪。
    final Finder clip = find.ancestor(
      of: find.byType(CanvasBoard),
      matching: find.byType(ClipRect),
    );
    expect(clip, findsWidgets);
    final Rect board = tester.getRect(find.byType(CanvasBoard));
    // 裁剪框是**整格**（标签条 + 正文），画布在它里面——画布自己不会越界，
    // 越界的是它画出来的网格和卡片。
    final Rect cell = tester.getRect(clip.first);
    expect(cell.top, lessThanOrEqualTo(board.top));
    expect(cell.left, lessThanOrEqualTo(board.left));
    expect(cell.right, greaterThanOrEqualTo(board.right));
    expect(cell.bottom, greaterThanOrEqualTo(board.bottom));
    expect(board.left, greaterThanOrEqualTo(pane.left));
    expect(board.right, lessThanOrEqualTo(pane.right));
  });

  testWidgets('把乙文 tab 拖到格子右边：左格留着甲文，右格是乙文', (WidgetTester tester) async {
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    app = await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: '甲文',
          body: '# 甲\n\n甲的正文\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
        Note(
          id: 'b',
          title: '乙文',
          body: '# 乙\n\n乙的正文\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
      ],
    );
    // 先把乙文开出来（点文件树那一行就开一页），再回到甲文。
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();

    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      Offset(pane.right - 12, pane.center.dy),
    );

    final Finder panes = find.byType(EditorPane);
    expect(panes, findsNWidgets(2));
    // 左边那格钉在拖之前看的那一篇上，右边那格接手「活着的那份」。
    expect(tester.widget<EditorPane>(panes.at(0)).noteId, 'a');
    expect(tester.widget<EditorPane>(panes.at(0)).readOnly, isTrue);
    expect(tester.widget<EditorPane>(panes.at(1)).noteId, isNull);
    expect(tester.widget<EditorPane>(panes.at(1)).readOnly, isFalse);
    // 落下来的那格接着看乙文：`select` 必须排在树更新之后，否则两格都会
    // 被钉到乙文上。
    expect(app.notes.selectedId, 'b');
  });

  testWidgets('从标签条拖出一页分割：原来那一格不再留着它', (WidgetTester tester) async {
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    app = await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: '甲文',
          body: '# 甲\n\n甲的正文\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
        Note(
          id: 'b',
          title: '乙文',
          body: '# 乙\n\n乙的正文\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
      ],
    );
    // 一格排两页：乙文在前（开着的那页），甲文在后。再点回甲文，于是拖的
    // 那一页是「钉住的那一页」，不是跟着选中走的那一页。
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    expect(tabOf('乙文'), findsOneWidget);
    expect(tabOf('甲文'), findsOneWidget);

    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      Offset(pane.right - 12, pane.center.dy),
    );

    expect(find.byType(EditorPane), findsNWidgets(2));
    // ⛔ 搬家不是复印：乙文只有一页，而且落在右边那一格。
    expect(tabOf('乙文'), findsOneWidget);
    final Rect right = tester.getRect(find.byType(EditorPane).at(1));
    expect(tester.getCenter(tabOf('乙文')).dx, greaterThan(right.left));
    // 左边那格只剩甲文——用户原话：「我分割后，这个 tab 就属于第二个编辑栏
    // 了，不再属于第一个编辑栏了。」
    final Finder leftStrip = find.byType(PaneTabStrip).at(1);
    expect(
      find.descendant(of: leftStrip, matching: find.text('甲文')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: leftStrip, matching: find.text('乙文')),
      findsNothing,
    );
    // 搬家不动会话：两篇都还开着，只是换了格子。
    expect(app.notes.openIds.toSet(), <String>{'a', 'b'});
  });

  testWidgets('把分屏那格唯一的一页拖回去：两页并回一条标签条', (
    WidgetTester tester,
  ) async {
    await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲文', DateTime(2026, 1, 2)),
        note('b', '乙文', DateTime(2026, 1, 2)),
      ],
    );
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();

    // 先把乙文拖出去分成两格。
    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      Offset(pane.right - 12, pane.center.dy),
    );
    expect(find.byType(EditorPane), findsNWidgets(2));

    // 再拖回来：丢在左边那格的标签条上，两页并回一条，分割自己收回去。
    final Finder leftStrip = find.byType(PaneTabStrip).at(1);
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      tester.getCenter(leftStrip),
    );

    expect(find.byType(EditorPane), findsOneWidget);
    expect(tabOf('甲文'), findsOneWidget);
    expect(tabOf('乙文'), findsOneWidget);
  });

  testWidgets('关掉分屏那格唯一的一页：分割自己收回去，不拿隔壁的页顶住', (WidgetTester tester) async {
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    app = await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: '甲文',
          body: '# 甲\n\n甲的正文\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
        Note(
          id: 'b',
          title: '乙文',
          body: '# 乙\n\n乙的正文\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
      ],
    );
    // 开两页（甲文、乙文），把乙文拖到右边分出一格。
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();
    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      Offset(pane.right - 12, pane.center.dy),
    );
    expect(find.byType(EditorPane), findsNWidgets(2));
    expect(tester.widget<EditorPane>(find.byType(EditorPane).at(1)).noteId,
        isNull);

    // 关掉右边那格唯一的一页。
    final Finder rightStrip = find.byType(PaneTabStrip).at(2);
    await tester.tap(
      find.descendant(of: rightStrip, matching: find.byTooltip('关闭这一页')),
    );
    await tester.pumpAndSettle();

    // ⛔ 分割收回去，而不是把左边那页搬过来顶住。用户原话：「我关闭了这个
    // tab 后，应该是自动恢复布局，关掉这个分割，而不是把第一个编辑栏的 tab
    // 继续放到这个第二个 tab 里。」
    expect(find.byType(EditorPane), findsOneWidget);
    final EditorPane only = tester.widget<EditorPane>(find.byType(EditorPane));
    expect(only.readOnly, isFalse);
    expect(app.notes.selectedId, 'a');
    expect(tabOf('甲文'), findsOneWidget);
    expect(tabOf('乙文'), findsNothing);
  });

  testWidgets('白板 tab 拖到格子左边：左边一格装白板，右边回到正文', (WidgetTester tester) async {
    await pumpShell(tester);
    await tester.tap(find.byTooltip('白板  ·  Ctrl+Shift+B'));
    await tester.pumpAndSettle();

    // 白板正占着唯一那一格，左边就是它的左边。
    final Rect pane = tester.getRect(find.byType(CanvasBoard));
    final CanvasBoardState boardState = tester.state<CanvasBoardState>(
      find.byType(CanvasBoard),
    );

    await dragTo(
      tester,
      tester.getCenter(tabOf('未命名白板')),
      Offset(pane.left + 12, pane.center.dy),
    );

    // 落在左边缘 = 在左边切一格。白板搬过去，原来那一格退回正文——
    // 单例文档在树里只能有一份，`_withDoc` 会把旧的那份让出来。
    expect(find.byType(CanvasBoard), findsOneWidget);
    expect(find.byType(EditorPane), findsOneWidget);
    final Rect board = tester.getRect(find.byType(CanvasBoard));
    final Rect note = tester.getRect(find.byType(EditorPane));
    expect(board.right, lessThanOrEqualTo(note.left));
    expect(board.top, note.top);
    // 搬格子不该重建：视口还在同一个 State 里。
    expect(
      identical(
        tester.state<CanvasBoardState>(find.byType(CanvasBoard)),
        boardState,
      ),
      isTrue,
    );
  });

  // -------------------------------------------------- 侧边栏：拖 / 右键分屏

  testWidgets('把侧边栏的标签页拖到上边缘：上面多一格标签，下面还是文件', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    expect(find.byType(NoteListPanel), findsOneWidget);

    // 打开标签页，再切回文件：一格排三页（文件 / 搜索 / 标签），当前是文件。
    await tester.tap(find.byTooltip('标签'));
    await tester.pumpAndSettle();
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    await tester.tap(
      find.descendant(of: sideStrip, matching: find.byTooltip('文件')),
    );
    await tester.pumpAndSettle();

    final Finder tagsTab = find.descendant(
      of: sideStrip,
      matching: find.byTooltip('标签'),
    );
    expect(tagsTab, findsOneWidget);

    final Rect side = tester.getRect(find.byType(NoteListPanel));
    await dragTo(
      tester,
      tester.getCenter(tagsTab),
      Offset(side.center.dx, side.top + 10),
    );

    final Finder panels = find.byType(NoteListPanel);
    expect(panels, findsNWidgets(2));
    // 「上边缘」= 新那格在上面，原来那格被推下去。
    final Rect upper = tester.getRect(panels.at(0));
    final Rect lower = tester.getRect(panels.at(1));
    expect(upper.bottom, lessThanOrEqualTo(lower.top));
    expect(tester.widget<NoteListPanel>(panels.at(0)).view, SidebarView.tags);
    // 搬家不是复印：标签整页搬到上面那格，下面那格不再留着它；
    // 文件 / 搜索是原来那格自带的开关，两颗都还在。
    final Finder upperStrip = find.byType(PaneTabStrip).first;
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('标签')),
      findsOneWidget,
    );
    // 拖出来的新格和编辑区一样，只装搬过去的那一页，不把开关再播一遍。
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('文件')),
      findsNothing,
    );
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('搜索')),
      findsNothing,
    );
    final Finder lowerStrip = find.byType(PaneTabStrip).at(1);
    expect(
      find.descendant(of: lowerStrip, matching: find.byTooltip('标签')),
      findsNothing,
    );
    expect(
      find.descendant(of: lowerStrip, matching: find.byTooltip('文件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: lowerStrip, matching: find.byTooltip('搜索')),
      findsOneWidget,
    );
    expect(tester.widget<NoteListPanel>(panels.at(1)).view, SidebarView.files);
  });

  testWidgets('侧边栏分割后，两格顶上都是图标按钮，没有「文件 ×」文字页', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    // 拖拽是唯一的分割方式：把标签拖到下边缘，上面留文件 / 搜索。
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    final Rect side = tester.getRect(find.byType(NoteListPanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: sideStrip, matching: find.byTooltip('标签')),
      ),
      Offset(side.center.dx, side.bottom - 10),
    );

    final Finder panels = find.byType(NoteListPanel);
    expect(panels, findsNWidgets(2));
    // 先序：0 / 1 是侧边栏的上下两格，2 是编辑区那一条，3 是右栏。
    final Finder strips = find.byType(PaneTabStrip);
    expect(strips, findsNWidgets(4));

    // 上格仍是文件 / 搜索两颗，顺序不变：文件在左、搜索紧挨在右。
    final Finder upper = strips.at(0);
    final Rect fileRect = tester.getRect(
      find.descendant(of: upper, matching: find.byTooltip('文件')),
    );
    final Rect searchRect = tester.getRect(
      find.descendant(of: upper, matching: find.byTooltip('搜索')),
    );
    expect(searchRect.left, greaterThanOrEqualTo(fileRect.right));
    // 下格只有搬过去的标签一页。
    expect(
      find.descendant(of: strips.at(1), matching: find.byTooltip('标签')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: strips.at(1), matching: find.byTooltip('文件')),
      findsNothing,
    );

    for (int i = 0; i < 2; i++) {
      final Finder strip = strips.at(i);
      // 每页都是一颗图标按钮，名字只挂在 tooltip 上。
      expect(
        find.descendant(of: strip, matching: find.byIcon(LucideIcons.folder)),
        i == 0 ? findsOneWidget : findsNothing,
      );
      expect(
        find.descendant(of: strip, matching: find.text('文件')),
        findsNothing,
        reason: '侧边栏顶上不该再出现「文件 ×」这种文字页',
      );
      expect(
        find.descendant(of: strip, matching: find.text('搜索')),
        findsNothing,
      );
      // 图标页没有 ×：侧边栏的页不许关。
      expect(
        find.descendant(of: strip, matching: find.byIcon(LucideIcons.x)),
        findsNothing,
      );
    }
  });

  testWidgets('侧边栏跨格拖标签：搬家，不是复印', (WidgetTester tester) async {
    await pumpShell(tester);
    // 拖拽分割：标签落到下格，上格留文件 / 搜索。
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    final Rect side = tester.getRect(find.byType(NoteListPanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: sideStrip, matching: find.byTooltip('标签')),
      ),
      Offset(side.center.dx, side.bottom - 10),
    );

    final Finder strips = find.byType(PaneTabStrip);
    final Finder lowerTags = find.descendant(
      of: strips.at(1),
      matching: find.byTooltip('标签'),
    );
    expect(lowerTags, findsOneWidget);

    // 拖到上面那格的中间：上面收下并切过去，下面那格摘空了，自己收回去。
    final Rect upper = tester.getRect(find.byType(NoteListPanel).at(0));
    await dragTo(tester, tester.getCenter(lowerTags), upper.center);

    expect(find.byType(NoteListPanel), findsOneWidget);
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel)).view,
      SidebarView.tags,
    );
    final Finder only = find.byType(PaneTabStrip).first;
    expect(
      find.descendant(of: only, matching: find.byTooltip('标签')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: only, matching: find.byTooltip('搜索')),
      findsOneWidget,
    );
  });

  testWidgets('侧边栏跨格拖搜索：搬家，不是复印', (WidgetTester tester) async {
    await pumpShell(tester);
    // 拖拽分割：标签落到下格，上格留文件 / 搜索。
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    final Rect side = tester.getRect(find.byType(NoteListPanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: sideStrip, matching: find.byTooltip('标签')),
      ),
      Offset(side.center.dx, side.bottom - 10),
    );

    final Finder strips = find.byType(PaneTabStrip);
    final Finder upperStrip = strips.first;
    final Finder lower = find.byType(NoteListPanel).at(1);
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('搜索')),
      findsOneWidget,
    );

    // 「文件 / 搜索」也是标签页：拖到另一格中间就搬家，原来那格不再留着它。
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: upperStrip, matching: find.byTooltip('搜索')),
      ),
      tester.getCenter(lower),
    );

    expect(tester.widget<NoteListPanel>(lower).view, SidebarView.search);
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('搜索')),
      findsNothing,
    );
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('文件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: strips.at(1), matching: find.byTooltip('标签')),
      findsOneWidget,
      reason: '下格原来的标签还在，只是旁边多了一页搜索',
    );
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel).at(0)).view,
      SidebarView.files,
    );
  });

  testWidgets('侧边栏拖出来的一格再拖回去：并回一格的两颗图标', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    // 把搜索拖到下面分割：上面只剩文件，下面只有搜索。
    final Finder strip = find.byType(PaneTabStrip).first;
    final Rect side = tester.getRect(find.byType(NoteListPanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: strip, matching: find.byTooltip('搜索')),
      ),
      Offset(side.center.dx, side.bottom - 10),
    );
    expect(find.byType(NoteListPanel), findsNWidgets(2));

    // 再拖回上面那格的标签条上：并回同一排图标，分割自己收回去。
    final Finder upperStrip = find.byType(PaneTabStrip).at(0);
    final Finder lowerStrip = find.byType(PaneTabStrip).at(1);
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: lowerStrip, matching: find.byTooltip('搜索')),
      ),
      tester.getCenter(upperStrip),
    );

    expect(find.byType(NoteListPanel), findsOneWidget);
    final Finder only = find.byType(PaneTabStrip).first;
    expect(
      find.descendant(of: only, matching: find.byTooltip('文件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: only, matching: find.byTooltip('搜索')),
      findsOneWidget,
    );
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel)).view,
      SidebarView.search,
    );
  });

  testWidgets('右键侧边栏标签页没有菜单：不能分屏、也不能关页', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    expect(find.byType(NoteListPanel), findsOneWidget);

    // 侧边栏的页只能靠拖拽分格，也没有「关闭这一页 / 关掉这一格」这回事。
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    await tester.tap(
      find.descendant(of: sideStrip, matching: find.byTooltip('文件')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('在上方分屏'), findsNothing);
    expect(find.text('在下方分屏'), findsNothing);
    expect(find.text('关闭这一页'), findsNothing);
    expect(find.text('关闭这一格'), findsNothing);
    expect(find.byType(NoteListPanel), findsOneWidget);
  });

  testWidgets('左栏的文件页拖到右栏：整页搬家，不是复印', (WidgetTester tester) async {
    final app = await pumpShell(tester);
    expect(find.byType(OutlinePanel), findsOneWidget);

    final Finder leftStrip = find.byType(PaneTabStrip).first;
    final Rect outline = tester.getRect(find.byType(OutlinePanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: leftStrip, matching: find.byTooltip('文件')),
      ),
      outline.center,
    );

    // 左栏少了文件页，当前退回搜索；右栏上格收下文件页并切过去。
    final Finder panels = find.byType(NoteListPanel);
    expect(panels, findsNWidgets(2));
    expect(tester.widget<NoteListPanel>(panels.at(0)).view, SidebarView.search);
    expect(tester.widget<NoteListPanel>(panels.at(1)).view, SidebarView.files);
    expect(find.byType(OutlinePanel), findsNothing);

    final Finder strips = find.byType(PaneTabStrip);
    expect(strips, findsNWidgets(3));
    expect(
      find.descendant(of: strips.first, matching: find.byTooltip('文件')),
      findsNothing,
      reason: '搬家不是复印：文件整页搬去右栏',
    );
    expect(
      find.descendant(of: strips.at(2), matching: find.byTooltip('文件')),
      findsOneWidget,
    );
    // 文件页不是右栏的三块面板之一，偏好里那三颗开关就该全落下——但整列
    // 仍然开着，右栏上格照样画着文件树。
    expect(app.settings.rightSidebarVisible, isTrue);
    expect(app.settings.outlineVisible, isFalse);
    // 文件树现在在编辑区右边。
    final Rect editor = tester.getRect(find.byType(EditorPane));
    expect(tester.getRect(panels.at(1)).left, greaterThanOrEqualTo(editor.right));

    // 「点当前页 = 收起整列」只属于右栏的面板三颗；文件搬过来后只是普通
    // 一页，点它不该把整列关掉。
    await tester.tap(
      find.descendant(of: strips.at(2), matching: find.byTooltip('文件')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NoteListPanel), findsNWidgets(2));
    expect(app.settings.rightSidebarVisible, isTrue);
  });

  testWidgets('右栏的大纲拖回左栏：两边互通，右栏不再留着它', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final Finder rightStrip = find.byType(PaneTabStrip).at(2);
    final Finder outlineTab = find.descendant(
      of: rightStrip,
      matching: find.byTooltip('大纲  ·  Ctrl+Shift+O'),
    );
    expect(outlineTab, findsOneWidget);

    final Rect leftPanel = tester.getRect(find.byType(NoteListPanel));
    await dragTo(tester, tester.getCenter(outlineTab), leftPanel.center);

    // 大纲整页搬到左栏：左上角那格切到大纲，右栏上格退回表格。
    expect(find.byType(NoteListPanel), findsNothing);
    final Rect outline = tester.getRect(find.byType(OutlinePanel));
    final Rect editor = tester.getRect(find.byType(EditorPane));
    final Rect table = tester.getRect(find.byType(TablePanel));
    expect(outline.right, lessThanOrEqualTo(editor.left));
    expect(table.left, greaterThanOrEqualTo(editor.right));

    final Finder strips = find.byType(PaneTabStrip);
    expect(strips, findsNWidgets(3));
    expect(
      find.descendant(of: strips.first, matching: find.byTooltip('大纲  ·  Ctrl+Shift+O')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: strips.at(2), matching: find.byTooltip('大纲  ·  Ctrl+Shift+O')),
      findsNothing,
      reason: '搬家不是复印：右栏不再留着大纲这一页',
    );
  });

  testWidgets('两侧边栏怎么分、每页住哪一栏，下次启动还是原样', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    // 1) 标签整页搬到右栏上格：左栏不再留着它。
    final Finder leftStrip = find.byType(PaneTabStrip).first;
    final Rect outline = tester.getRect(find.byType(OutlinePanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: leftStrip, matching: find.byTooltip('标签')),
      ),
      outline.center,
    );
    expect(find.byType(NoteListPanel), findsNWidgets(2));
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel).at(1)).view,
      SidebarView.tags,
    );

    // 2) 表格拖到右栏下边缘：右栏分成上下两格，上格还是标签。
    final Finder rightStrip = find.byType(PaneTabStrip).at(2);
    final Rect rightBody = tester.getRect(find.byType(NoteListPanel).at(1));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: rightStrip, matching: find.byTooltip('表格')),
      ),
      Offset(rightBody.center.dx, rightBody.bottom - 10),
    );
    expect(find.byType(TablePanel), findsOneWidget);
    expect(find.byType(PaneTabStrip), findsNWidgets(4));

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? leftJson = prefs.getString('nrs.sideLayout');
    final String? rightJson = prefs.getString('nrs.rightLayout');
    expect(leftJson, isNotNull);
    expect(rightJson, isNotNull);
    expect(prefs.getBool('nrs.rightSidebarVisible'), isTrue);

    // 3) 关掉整个壳，只把同一份偏好递回去——不重新拖一遍。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpShell(
      tester,
      extraPrefs: <String, Object>{
        'nrs.sideLayout': leftJson!,
        'nrs.rightLayout': rightJson!,
        'nrs.rightSidebarVisible': true,
      },
    );

    // 左栏：文件 / 搜索两页，当前是文件（标签搬走了）。
    final Finder panels = find.byType(NoteListPanel);
    expect(panels, findsNWidgets(2));
    expect(tester.widget<NoteListPanel>(panels.at(0)).view, SidebarView.files);
    // 右栏：上格停在标签，下格是表格——分割和当前页都还在。
    expect(tester.widget<NoteListPanel>(panels.at(1)).view, SidebarView.tags);
    expect(find.byType(TablePanel), findsOneWidget);
    expect(find.byType(OutlinePanel), findsNothing);
    final Finder strips = find.byType(PaneTabStrip);
    expect(strips, findsNWidgets(4));
    expect(
      find.descendant(of: strips.at(2), matching: find.byTooltip('表格')),
      findsNothing,
      reason: '表格已经搬到下格',
    );
    expect(
      find.descendant(of: strips.at(3), matching: find.byTooltip('表格')),
      findsOneWidget,
    );
    // 下格真的在下面。
    final Rect tagsPanel = tester.getRect(panels.at(1));
    final Rect table = tester.getRect(find.byType(TablePanel));
    expect(table.top, greaterThanOrEqualTo(tagsPanel.bottom));
    // 恢复的格子一样没有分割 / 关闭按钮。
    expect(find.byTooltip('关掉这一格'), findsNothing);
    expect(find.byTooltip('上下分割'), findsNothing);
  });

  testWidgets('窗口顶部只有一条带子：标签条和顶栏是同一个矩形', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final Rect bar = tester.getRect(find.byType(AppTitleBar));
    expect(bar.height, AppLayout.titleBarHeight);
    // ⛔ 顶栏不再是一条横带：它只是浮在标签条上的几颗按钮，所以和标签条
    // 顶在同一条边上、同一个高度。以前这里是 `bar.bottom == strip.top`。
    expect(bar.top, 0);

    final Finder editorStrip = find.byType(PaneTabStrip).at(1);
    final Rect strip = tester.getRect(editorStrip);
    final Rect body = tester.getRect(find.byType(EditorPane));
    expect(strip.top, 0, reason: '标签条就顶在窗口最上面，不能被顶栏挤下去一行');
    expect(strip.height, AppLayout.paneTabStripHeight);
    expect(AppLayout.paneTabStripHeight, AppLayout.titleBarHeight);
    // 正文紧接在标签条下面，中间没有多余的缝。
    expect(body.top, strip.bottom);
    // 左边和正文左边对齐——标签条是这一格的一部分。
    expect(strip.left, body.left);
  });

  testWidgets('右栏收起时只有最右那一格给窗口按钮让位', (WidgetTester tester) async {
    final app = await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲文', DateTime(2026, 1, 2)),
        note('b', '乙文', DateTime(2026, 1, 2)),
      ],
    );
    // 右栏开着的时候，右上角是右栏的开关 + 右栏自己，标签条只要让开那颗
    // 收 / 展按钮。
    app.settings.outlineVisible = false;
    await tester.pumpAndSettle();

    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();
    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('乙文')),
      Offset(pane.right - 12, pane.center.dy),
    );

    final Finder strips = find.byType(PaneTabStrip);
    expect(strips, findsNWidgets(3));
    double inset(int i) =>
        tester.widget<PaneTabStrip>(strips.at(i)).trailingInset;
    // 先序：0 是侧边栏，1 是左格，2 是右格。
    expect(inset(1), 0, reason: '左边那格离窗口右边缘还远，给它留白就是中间空一大块');
    expect(
      inset(2),
      kCaptionWidth + kRightSidebarToggleSlot,
      reason: '右端是收 / 展按钮 + 三个窗口按钮（那三颗面板图标跟着右栏收起了）',
    );
  });

  testWidgets('顶部栏跟侧边栏同色；功能栏跟着左边那块地换色', (WidgetTester tester) async {
    final app = await pumpShell(tester);
    const AppPalette palette = AppPalette.midnight;

    Color stripColor(int i) {
      final Container strip = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(PaneTabStrip).at(i),
              matching: find.byType(Container),
            )
            .first,
      );
      return strip.color!;
    }

    Color railColor() {
      final Container rail = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(AppRail),
              matching: find.byType(Container),
            )
            .first,
      );
      return (rail.decoration! as BoxDecoration).color!;
    }

    // 三条标签条（左栏 / 编辑区 / 右栏）都是侧边栏那一档：窗口顶上是一条
    // 完整的带子，不再是最深的画布色。
    expect(find.byType(PaneTabStrip), findsNWidgets(3));
    for (int i = 0; i < 3; i++) {
      expect(stripColor(i), palette.sidebar, reason: '第 $i 条标签条');
    }

    // 边栏开着：功能栏和它同色。
    expect(app.settings.sidebarCollapsed, isFalse);
    expect(railColor(), palette.sidebar);

    // 收起：功能栏并进编辑区的纸面，顶上那条带子不变。
    await tester.tap(find.byTooltip('收起侧边栏  ·  Ctrl+\\'));
    await tester.pumpAndSettle();
    expect(app.settings.sidebarCollapsed, isTrue);
    expect(railColor(), palette.surface);
    expect(find.byType(PaneTabStrip), findsNWidgets(2));
    expect(stripColor(0), palette.sidebar);
    expect(stripColor(1), palette.sidebar);

    // 再展开：功能栏跟着侧边栏回来。
    await tester.tap(find.byTooltip('展开侧边栏  ·  Ctrl+\\'));
    await tester.pumpAndSettle();
    expect(railColor(), palette.sidebar);
  });

  testWidgets('标签条末尾不再有新建笔记：那个位置换成右栏的收 / 展按钮', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    // 新建笔记只剩侧边栏面板头那一个（tooltip 带快捷键）；标签条末尾那颗
    // 加号已经按用户要求删掉。
    expect(find.byTooltip('新建笔记'), findsNothing);
    expect(find.byTooltip('新建笔记  ·  Ctrl+N'), findsOneWidget);

    final Rect outline = tester.getRect(find.byType(OutlinePanel));
    final Rect toggle = tester.getRect(find.byTooltip('收起右侧边栏'));
    expect(toggle.right, outline.left - 2, reason: '贴着右栏左缘，属于右栏');
    expect(toggle.width, kRightSidebarToggleSize);
    expect(toggle.height, kRightSidebarToggleSize);
  });

  testWidgets('点右栏那颗按钮=收起，再点=从原来那一页展开', (WidgetTester tester) async {
    final app = await pumpShell(tester);
    expect(find.byType(OutlinePanel), findsOneWidget);

    await tester.tap(find.byTooltip('收起右侧边栏'));
    await tester.pumpAndSettle();
    expect(find.byType(OutlinePanel), findsNothing);
    expect(app.settings.rightSidebarVisible, isFalse);
    expect(app.settings.outlineVisible, isFalse);

    // 收起时那三颗面板图标也跟着走——它们是右栏的一部分。顶栏右端只剩
    // 这颗左箭头和三个窗口按钮，中间隔 2px。
    expect(
      find.descendant(
        of: find.byType(AppTitleBar),
        matching: find.byTooltip(RegExp('^(大纲|表格|图片)')),
      ),
      findsNothing,
    );
    final Rect bar = tester.getRect(find.byType(AppTitleBar));
    final Rect expand = tester.getRect(find.byTooltip('展开右侧边栏'));
    expect(expand.right, bar.right - kCaptionWidth - 2);

    await tester.tap(find.byTooltip('展开右侧边栏'));
    await tester.pumpAndSettle();
    expect(find.byType(OutlinePanel), findsOneWidget);
    expect(app.settings.rightSidebarVisible, isTrue);
    expect(app.settings.outlineVisible, isTrue, reason: '回到收起前停的那一页');
    expect(find.byTooltip('收起右侧边栏'), findsOneWidget);
  });

  testWidgets('收 / 展右栏的按钮只有一颗：右栏分格也不复制', (WidgetTester tester) async {
    await pumpShell(tester);
    final Rect panel = tester.getRect(find.byType(OutlinePanel));
    await dragTo(
      tester,
      tester.getCenter(find.byTooltip('表格')),
      Offset(panel.center.dx, panel.bottom - 10),
    );
    expect(find.byType(TablePanel), findsOneWidget);
    expect(find.byType(PaneTabStrip), findsNWidgets(4));
    expect(find.byTooltip('收起右侧边栏'), findsOneWidget);
    expect(find.byTooltip('展开右侧边栏'), findsNothing);
  });

  testWidgets('右栏顶上画的是它自己的页：搬进来的文件跟着收起 / 展开', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    // 文件搬进右栏上格：那一排现在是 大纲 / 表格 / 图片 / 文件，当前是文件。
    final Finder leftStrip = find.byType(PaneTabStrip).first;
    final Rect outline = tester.getRect(find.byType(OutlinePanel));
    await dragTo(
      tester,
      tester.getCenter(
        find.descendant(of: leftStrip, matching: find.byTooltip('文件')),
      ),
      outline.center,
    );

    final Finder before = find.byType(PaneTabStrip).at(2);
    expect(
      find.descendant(of: before, matching: find.byType(PaneTab)),
      findsNWidgets(4),
      reason: '右栏顶上按树里实际的页画，不是写死的三颗',
    );
    expect(
      find.descendant(of: before, matching: find.byTooltip('文件')),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('收起右侧边栏'));
    await tester.pumpAndSettle();
    // 收起后顶栏一颗面板图标都不挂——它们都属于右栏，跟着整列一起走。
    expect(
      find.descendant(
        of: find.byType(AppTitleBar),
        matching: find.byTooltip(RegExp('^(大纲|表格|图片|文件|搜索|标签)')),
      ),
      findsNothing,
    );

    await tester.tap(find.byTooltip('展开右侧边栏'));
    await tester.pumpAndSettle();
    final Finder after = find.byType(PaneTabStrip).at(2);
    expect(
      find.descendant(of: after, matching: find.byType(PaneTab)),
      findsNWidgets(4),
      reason: '展开回到那一排实际的页，文件还在',
    );
    expect(
      find.descendant(of: after, matching: find.byTooltip('文件')),
      findsOneWidget,
    );
    expect(find.byType(NoteListPanel), findsNWidgets(2));
  });

  // ------------------------------------------------------- 右栏也能上下分割

  testWidgets('右栏顶上三颗是右栏自己的标签：贴着栏的左缘、28 方块', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final Rect outline = tester.getRect(find.byType(OutlinePanel));
    final Rect outlineTab = tester.getRect(
      find.byTooltip('大纲  ·  Ctrl+Shift+O'),
    );
    // 同一列、同一高度：这几颗属于右栏，收起时跟着整列一起走，顶栏不会有
    // 第二份。
    expect(outlineTab.left, outline.left);
    expect(outlineTab.top, 6);
    // 面板仍旧从顶栏那条带子下面开始，没被多出来的一条标签条顶下去。
    expect(outline.top, AppLayout.titleBarHeight);
    expect(
      tester.getRect(find.byType(PaneTabStrip).at(2)).top,
      0,
      reason: '右栏上格的标签条就顶在窗口最上面',
    );
    // 28 的方块 + 底边 6 的缝（这颗方块在 40 的带子里居中）。量具是整颗
    // 可点区域，所以高度是 34，但画出来的方块仍是 28。
    expect(outlineTab.width, 28);
    expect(outlineTab.height, 34);

    final Rect tableTab = tester.getRect(find.byTooltip('表格'));
    expect(tableTab.left, outlineTab.right + 2, reason: '三颗 28 加两道 2px 的缝');

    // 窗口按钮压在最右 132 上，标签条自己把这一段让出来。
    final PaneTabStrip rightStrip = tester.widget(
      find.byType(PaneTabStrip).at(2),
    );
    expect(rightStrip.trailingInset, kCaptionWidth);
    // 顶栏不再画第二份。
    expect(
      find.descendant(
        of: find.byType(AppTitleBar),
        matching: find.byTooltip('表格'),
      ),
      findsNothing,
    );
  });

  testWidgets('点右栏当前那颗图标 = 收起右栏，那三颗跟着一起走', (
    WidgetTester tester,
  ) async {
    final app = await pumpShell(tester);
    expect(find.byType(OutlinePanel), findsOneWidget);
    expect(app.settings.outlineVisible, isTrue);

    await tester.tap(find.byTooltip('大纲  ·  Ctrl+Shift+O'));
    await tester.pumpAndSettle();

    expect(find.byType(OutlinePanel), findsNothing);
    expect(app.settings.outlineVisible, isFalse);
    // 整列收起来：右栏那条标签条跟着走，顶栏**不补回**那三颗——它们本来
    // 就是右栏的页。右端只剩右栏自己的收 / 展按钮。
    expect(find.byType(PaneTabStrip), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byType(AppTitleBar),
        matching: find.byTooltip('大纲  ·  Ctrl+Shift+O'),
      ),
      findsNothing,
    );
    expect(find.byTooltip('展开右侧边栏'), findsOneWidget);

    // 从这颗按钮展开，再在右栏标签条上换到图片。
    await tester.tap(find.byTooltip('展开右侧边栏'));
    await tester.pumpAndSettle();
    expect(find.byType(OutlinePanel), findsOneWidget);
    await tester.tap(find.byTooltip('图片'));
    await tester.pumpAndSettle();
    expect(find.byType(ImagePanel), findsOneWidget);
    expect(find.byType(PaneTabStrip), findsNWidgets(3));
  });

  testWidgets('偏好里的开关一改，右栏上格就跟着换页', (WidgetTester tester) async {
    final app = await pumpShell(tester);
    expect(find.byType(OutlinePanel), findsOneWidget);

    // 快捷键 / 别处代码改的是偏好，不是标签条——上格得听偏好的。
    app.settings.imagePanelVisible = true;
    await tester.pumpAndSettle();
    expect(find.byType(ImagePanel), findsOneWidget);
    expect(find.byType(OutlinePanel), findsNothing);
    expect(
      tester.widget<PaneTabStrip>(find.byType(PaneTabStrip).at(2)).index,
      2,
      reason: '上格那一排是 大纲 / 表格 / 图片，当前页跟着偏好换到图片',
    );
  });

  testWidgets('右栏拖表格到下边缘：上格留大纲，下格装表格', (WidgetTester tester) async {
    final app = await pumpShell(tester);
    expect(find.byType(OutlinePanel), findsOneWidget);

    final Rect panel = tester.getRect(find.byType(OutlinePanel));
    await dragTo(
      tester,
      tester.getCenter(find.byTooltip('表格')),
      Offset(panel.center.dx, panel.bottom - 10),
    );

    expect(find.byType(OutlinePanel), findsOneWidget);
    expect(find.byType(TablePanel), findsOneWidget);
    // 先序：0 侧边栏，1 编辑区，2 右栏上格，3 右栏下格。
    final Finder strips = find.byType(PaneTabStrip);
    expect(strips, findsNWidgets(4));
    expect(
      find.descendant(of: strips.at(2), matching: find.byTooltip('表格')),
      findsNothing,
      reason: '搬家不是复印：表格整页搬去下格',
    );
    expect(
      find.descendant(of: strips.at(3), matching: find.byTooltip('表格')),
      findsOneWidget,
    );
    // 上格还是大纲：偏好说的是上格，不被下格顶掉。
    expect(app.settings.outlineVisible, isTrue);
    expect(app.settings.tablePanelVisible, isFalse);
  });

  testWidgets('把右栏下格的图标拖回上格标签条：并回一排，分割收回去', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final Rect panel = tester.getRect(find.byType(OutlinePanel));
    await dragTo(
      tester,
      tester.getCenter(find.byTooltip('表格')),
      Offset(panel.center.dx, panel.bottom - 10),
    );
    expect(find.byType(TablePanel), findsOneWidget);

    final Finder strips = find.byType(PaneTabStrip);
    // 上格标签条的右端被三个窗口按钮压着，落点要挑左边那段空白。
    final Rect upper = tester.getRect(strips.at(2));
    await dragTo(
      tester,
      tester.getCenter(find.byTooltip('表格')),
      Offset(upper.left + 100, upper.center.dy),
    );

    expect(find.byType(PaneTabStrip), findsNWidgets(3), reason: '两格并回一格');
    final Finder only = find.byType(PaneTabStrip).at(2);
    expect(
      find.descendant(of: only, matching: find.byType(PaneTab)),
      findsNWidgets(3),
    );
    // 丢在哪一页上就切到哪一页：三颗都还在，表格现在是当前页。
    expect(find.byType(TablePanel), findsOneWidget);
    expect(find.byType(OutlinePanel), findsNothing);
  });

  testWidgets('右键右栏图标没有菜单：既不能分屏，也没有关闭这一格', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(
      find.byTooltip('大纲  ·  Ctrl+Shift+O'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('在上方分屏'), findsNothing);
    expect(find.text('在下方分屏'), findsNothing);
    expect(find.text('关闭右栏'), findsNothing);
    expect(find.text('关闭这一格'), findsNothing);
    // 右栏照旧停在大纲，没有被右键关掉或分出一格。
    expect(find.byType(OutlinePanel), findsOneWidget);
    expect(find.byType(PaneTabStrip), findsNWidgets(3));
  });

  testWidgets('右栏的图标拖进编辑区不接：不会分格，也不会换页', (WidgetTester tester) async {
    await pumpShell(tester);
    final Rect editor = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(find.byTooltip('表格')),
      editor.center,
    );

    expect(find.byType(OutlinePanel), findsOneWidget);
    expect(find.byType(TablePanel), findsNothing);
    expect(find.byType(PaneTabStrip), findsNWidgets(3));
    expect(find.byType(EditorPane), findsOneWidget);
  });

  // ------------------------------------------------- 一格一组标签，可以有多页

  testWidgets('一格能排好几页：点两篇笔记就有两页，点哪页切哪页', (
    WidgetTester tester,
  ) async {
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    app = await pumpShell(
      tester,
      vault: <Note>[
        Note(
          id: 'a',
          title: '甲文',
          body: '# 甲\\n\\n甲的正文\\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
        Note(
          id: 'b',
          title: '乙文',
          body: '# 乙\\n\\n乙的正文\\n',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 2),
        ),
      ],
    );

    // 默认三条标签条：侧边栏一格一条、编辑区一格一条、右栏一格一条。
    // 标签条属于**格子**，不在顶栏里。
    expect(find.byType(PaneTabStrip), findsNWidgets(3));
    expect(
      find.descendant(
        of: find.byType(AppTitleBar),
        matching: find.byType(PaneTabStrip),
      ),
      findsNothing,
    );

    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();

    // 多一页不等于多一条：还是那一条，里面排了两页。
    expect(find.byType(PaneTabStrip), findsNWidgets(3));
    expect(tabOf('甲文'), findsOneWidget);
    expect(tabOf('乙文'), findsOneWidget);
    expect(app.notes.selectedId, 'b');

    await tester.tap(tabOf('甲文'));
    await tester.pumpAndSettle();
    expect(app.notes.selectedId, 'a');
    // 两页都还在，只是当前换成了甲文。
    expect(tabOf('甲文'), findsOneWidget);
    expect(tabOf('乙文'), findsOneWidget);
  });

  testWidgets('分屏之后每一格各长一条标签条，各排各的页', (WidgetTester tester) async {
    final ({
      SettingsController settings,
      NotesController notes,
      CanvasController canvas,
    })
    app = await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲文', DateTime(2026, 1, 2)),
        note('b', '乙文', DateTime(2026, 1, 2)),
        note('c', '丙文', DateTime(2026, 1, 2)),
      ],
    );
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('丙文'));
    await tester.pumpAndSettle();

    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('丙文')),
      Offset(pane.right - 12, pane.center.dy),
    );

    // 四条：侧边栏一条 + 编辑区两格各一条 + 右栏一条。
    expect(find.byType(PaneTabStrip), findsNWidgets(4));
    expect(find.byType(EditorPane), findsNWidgets(2));

    // 左边那一格留着甲、乙，右边那格是新切出来的、只有被拖过去的丙。
    // 标签条按屏幕顺序排：0 是侧边栏，1 是左格，2 是右格，3 是右栏。
    final Finder leftStrip = find.byType(PaneTabStrip).at(1);
    final Finder rightStrip = find.byType(PaneTabStrip).at(2);
    expect(
      find.descendant(of: leftStrip, matching: find.byType(PaneTab)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(of: rightStrip, matching: find.byType(PaneTab)),
      findsOneWidget,
    );
    // 右边那格接手「活的那一份」，看的是丙文。
    expect(
      find.descendant(of: rightStrip, matching: find.text('丙文')),
      findsOneWidget,
    );
    expect(app.notes.selectedId, 'c');
  });

  testWidgets('把一页拖到另一格：是搬家，不是复印', (WidgetTester tester) async {
    await pumpShell(
      tester,
      vault: <Note>[
        note('a', '甲文', DateTime(2026, 1, 2)),
        note('b', '乙文', DateTime(2026, 1, 2)),
        note('c', '丙文', DateTime(2026, 1, 2)),
      ],
    );
    await tester.tap(treeRow('甲文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('乙文'));
    await tester.pumpAndSettle();
    await tester.tap(treeRow('丙文'));
    await tester.pumpAndSettle();
    final Rect pane = tester.getRect(find.byType(EditorPane));
    await dragTo(
      tester,
      tester.getCenter(tabOf('丙文')),
      Offset(pane.right - 12, pane.center.dy),
    );

    // 现在：侧边栏一条、左格两页（甲、乙）、右格一页（丙）。
    expect(tabOf('甲文'), findsOneWidget);
    expect(tabOf('乙文'), findsOneWidget);
    expect(tabOf('丙文'), findsOneWidget);

    final Rect rightPane = tester.getRect(find.byType(EditorPane).at(1));
    await dragTo(
      tester,
      tester.getCenter(tabOf('甲文')),
      Offset(rightPane.center.dx, rightPane.center.dy),
    );

    // 甲文搬到右格去了：全局只剩一页，左格不再留着它。
    expect(tabOf('甲文'), findsOneWidget);
    final Finder leftStrip = find.byType(PaneTabStrip).at(1);
    expect(
      find.descendant(of: leftStrip, matching: find.text('甲文')),
      findsNothing,
    );
    expect(
      find.descendant(of: leftStrip, matching: find.byType(PaneTab)),
      findsOneWidget,
    );
  });

  testWidgets('侧边栏顶上并排三颗图标：文件 / 搜索 / 标签，点谁切谁', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);

    // 三颗常驻开关一起钉在侧边栏顶上：文件、搜索、标签。三颗都是页，也
    // 都可以拖去别的格子甚至另一侧边栏。
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    Finder sideTab(String label) =>
        find.descendant(of: sideStrip, matching: find.byTooltip(label));
    expect(sideTab('文件'), findsOneWidget);
    expect(sideTab('搜索'), findsOneWidget);
    expect(sideTab('标签'), findsOneWidget);

    final Rect fileRect = tester.getRect(sideTab('文件'));
    final Rect searchRect = tester.getRect(sideTab('搜索'));
    final Rect tagsRect = tester.getRect(sideTab('标签'));
    expect(
      searchRect.left,
      greaterThanOrEqualTo(fileRect.right),
      reason: '搜索紧跟在文件右边',
    );
    expect(
      tagsRect.left,
      greaterThanOrEqualTo(searchRect.right),
      reason: '标签排在搜索右边',
    );
    expect(searchRect.top, fileRect.top, reason: '三颗同一条带子上、一样高');
    expect(tagsRect.top, fileRect.top);

    await tester.tap(sideTab('搜索'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel)).view,
      SidebarView.search,
    );
    expect(find.text('输入并开始搜索...'), findsOneWidget);

    await tester.tap(sideTab('标签'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel)).view,
      SidebarView.tags,
    );

    // 点「文件」那一颗切回去，三颗一颗不少。
    await tester.tap(sideTab('文件'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel)).view,
      SidebarView.files,
    );
    expect(sideTab('搜索'), findsOneWidget);
    expect(sideTab('标签'), findsOneWidget);
  });

  testWidgets('标签页常驻、不能关：右键没有菜单，标签条上也没有 ×', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester);
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    Finder sideTab(String label) =>
        find.descendant(of: sideStrip, matching: find.byTooltip(label));
    expect(sideTab('标签'), findsOneWidget);

    await tester.tap(sideTab('标签'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel)).view,
      SidebarView.tags,
    );

    // 右键不再给菜单（以前这里有「关闭这一页」）；标签是常驻的一页，
    // 也不会画 × 按钮。
    await tester.tap(sideTab('标签'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('关闭这一页'), findsNothing);
    expect(
      find.descendant(of: sideStrip, matching: find.byIcon(LucideIcons.x)),
      findsNothing,
    );

    // 切走再切回来，标签一页还在。
    await tester.tap(sideTab('文件'));
    await tester.pumpAndSettle();
    await tester.tap(sideTab('标签'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NoteListPanel>(find.byType(NoteListPanel)).view,
      SidebarView.tags,
    );
  });

  testWidgets('侧边栏拖一页到下面分割：原来那一格不再留着它', (WidgetTester tester) async {
    await pumpShell(tester);
    // 标签是能搬的那一页：打开它，再切回文件，让它是「旁边那一页」而不是
    // 当前页。
    await tester.tap(find.byTooltip('标签'));
    await tester.pumpAndSettle();
    final Finder sideStrip = find.byType(PaneTabStrip).first;
    final Finder tagsTab = find.descendant(
      of: sideStrip,
      matching: find.byTooltip('标签'),
    );
    await tester.tap(
      find.descendant(of: sideStrip, matching: find.byTooltip('文件')),
    );
    await tester.pumpAndSettle();
    expect(tagsTab, findsOneWidget);

    final Rect side = tester.getRect(find.byType(NoteListPanel));
    await dragTo(
      tester,
      tester.getCenter(tagsTab),
      Offset(side.center.dx, side.bottom - 10),
    );

    final Finder panels = find.byType(NoteListPanel);
    expect(panels, findsNWidgets(2));
    // ⛔ 搬家不是复印：上面那格不再留着标签这一页，但文件 / 搜索两颗还都在。
    final Finder upperStrip = find.byType(PaneTabStrip).first;
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('标签')),
      findsNothing,
    );
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('文件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: upperStrip, matching: find.byTooltip('搜索')),
      findsOneWidget,
    );
    // 拖出来的下面那格只装搬过去的那一页，不把文件 / 搜索再复印一份。
    final Finder lowerStrip = find.byType(PaneTabStrip).at(1);
    expect(
      find.descendant(of: lowerStrip, matching: find.byTooltip('标签')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: lowerStrip, matching: find.byTooltip('文件')),
      findsNothing,
    );
    expect(
      find.descendant(of: lowerStrip, matching: find.byTooltip('搜索')),
      findsNothing,
    );
    // 下面那格停在搬过去的标签上；上面那格还是文件。
    expect(tester.widget<NoteListPanel>(panels.at(1)).view, SidebarView.tags);
    expect(tester.widget<NoteListPanel>(panels.at(0)).view, SidebarView.files);
  });
}
