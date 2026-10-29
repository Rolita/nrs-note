import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/app_enums.dart';
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
import 'package:nrs/ui/shell/title_bar.dart';
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
    // right.
    expect(find.text('文件'), findsOneWidget);
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

  testWidgets('Shift 连选能跨笔记、白板和图片：文件列表里除了文件夹都能连选', (
    WidgetTester tester,
  ) async {
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

  testWidgets('文件夹不参与连选：Shift 点文件夹只展开 / 收起，选中不变', (
    WidgetTester tester,
  ) async {
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
        of: find.byType(AppTitleBar),
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

    final Finder graph = find.byTooltip('关系图谱  ·  Ctrl+G');
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

    await tester.tap(find.byTooltip('关系图谱  ·  Ctrl+G'));
    await tester.pumpAndSettle();
    expect(find.byType(GraphView), findsOneWidget);

    await tester.tap(find.text('一篇笔记').first);
    await tester.pumpAndSettle();
    expect(find.byType(EditorPane), findsOneWidget);
  });

  testWidgets('打开图谱时新增关系图谱页，点 × 才关掉它', (WidgetTester tester) async {
    await pumpShell(tester);

    expect(find.text('关系图谱'), findsNothing, reason: '没打开时没有这一页');

    await tester.tap(find.byTooltip('关系图谱  ·  Ctrl+G'));
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

    // 图谱页现在选中，× 可点；笔记页的 × 排在它前面。
    await tester.tap(
      find
          .descendant(
            of: find.byType(AppTitleBar),
            matching: find.byIcon(LucideIcons.x),
          )
          .last,
    );
    await tester.pumpAndSettle();

    expect(find.byType(GraphView), findsNothing, reason: '× 关掉图谱');
    expect(find.text('关系图谱'), findsNothing, reason: '关掉后这一页也消失');
    expect(find.byType(EditorPane), findsOneWidget);
  });

  testWidgets('进图谱收起右侧那一栏，退出图谱自己回来', (WidgetTester tester) async {
    final app = await pumpShell(tester);

    expect(find.byType(OutlinePanel), findsOneWidget, reason: '默认大纲是开着的');

    await tester.tap(find.byTooltip('关系图谱  ·  Ctrl+G'));
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

    await tester.tap(find.byTooltip('关系图谱  ·  Ctrl+G'));
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
        of: find.byType(AppTitleBar),
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

  testWidgets('从文件列表把图片拖进白板：卡片存路径，不拷贝字节', (
    WidgetTester tester,
  ) async {
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

  testWidgets(
    '从文件列表把笔记拖进白板：卡片落在松手的地方，不是拖拽的起点',
    (WidgetTester tester) async {
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
    },
  );
}
