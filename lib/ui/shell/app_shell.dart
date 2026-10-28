import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_enums.dart';
import '../../core/platform/vault_sync.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/external_link.dart';
import '../../core/utils/image_file.dart';
import '../../data/storage/canvas_store.dart';
import '../../data/storage/canvas_store_factory.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/markdown_outline.dart';
import '../../core/utils/note_image.dart';
import '../../core/utils/note_images.dart';
import '../../data/models/note.dart';
import '../../data/storage/note_store.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../../state/template_settings.dart';
import '../../templates/template_error.dart';
import '../../templates/template_interpreter.dart';
import '../../templates/template_service.dart';
import '../common/app_widgets.dart';
import '../common/delete_dialog.dart';
import '../common/notices.dart';
import '../../state/canvas_controller.dart';
import '../canvas/canvas_board.dart';
import '../editor/editor_pane.dart';
import '../editor/image_panel.dart';
import '../editor/outline_panel.dart';
import '../editor/table_panel.dart';
import '../graph/graph_view.dart';
import '../image/image_pane.dart';
import '../templates/template_interaction.dart';
import '../templates/template_new_note_dialog.dart';
import '../templates/template_picker.dart';
import 'main_view.dart';
import 'data_safety_dialogs.dart';
import 'function_rail.dart';
import 'note_list_panel.dart';
import 'settings_dialog.dart';
import 'title_bar.dart';
import 'vault_tree.dart';

/// Four regions, left to right: the function rail, the switchable sidebar
/// (files / search / tags), the editor, and the document outline.
///
/// Focus mode drops everything but the editor; the outline also steps aside in
/// narrow windows, where it would squeeze the prose column instead of helping.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<EditorPaneState> _editorKey = GlobalKey<EditorPaneState>();
  final GlobalKey<CanvasBoardState> _canvasKey = GlobalKey<CanvasBoardState>();
  final GlobalKey<NoteListPanelState> _listKey =
      GlobalKey<NoteListPanelState>();
  final FocusNode _shellFocus = FocusNode(debugLabel: 'nrs-shell');
  final NoticeController _notices = NoticeController();
  final TemplateService _templates = const TemplateService();

  /// The body field's value, republished by [EditorPane] for the table tools.
  /// It lives here so the panel can rebuild on a caret move without rebuilding
  /// the shell around it.
  final ValueNotifier<TextEditingValue> _bodyValue =
      ValueNotifier<TextEditingValue>(const TextEditingValue());

  late final NotesController _notes;
  late final SettingsController _settings;
  late final CanvasController _canvas;

  /// 启动时那块白板文档还在路上，但上次退出时主区正看着它。
  ///
  /// 白板是在 `main` 里等 vault 读完才打开的（`open` 要用 vault 路径），
  /// 那一刻外壳早就建好了。所以这里先记下「打开之后要切过去」，等控制器
  /// 通知「文档来了」再切——否则启动后停在哪一页全看两边谁先跑完。
  bool _pendingCanvasActivate = false;

  SidebarView _view = SidebarView.files;

  /// 主区显示笔记还是图谱。会话级，不持久化：重启回到上次的笔记。
  ///
  /// 唯一的例外是白板：它记在偏好里（`sessionCanvasPath` +
  /// `sessionCanvasActive`），因为「关软件时正看着白板，下次打开还是它」
  /// 是用户明确要的行为。其余视图不需要——笔记有自己那套标签会话。
  MainView _mainView = MainView.note;

  /// 图谱被打开过一次。
  ///
  /// 首屏不建图：一次收敛要几十毫秒，而大多数人启动后是来写字的。等第一次
  /// 点开图谱再建，之后就一直挂在树上（`Offstage`），切来切去不重建。
  bool _graphOpened = false;

  /// 白板被打开过一次，理由同 [_graphOpened]。
  bool _canvasOpened = false;

  /// 图片页正在看的那张图（vault 相对路径），`null` = 图片页没开。
  ///
  /// **所有图片共用这一页**：从文件树点另一张只是换这里的值，不新开 tab。
  /// 点 tab 上的 × 才把它清掉。
  String? _imagePath;

  int _cursorLine = 0;
  VoidCallback? _stopVaultSync;

  @override
  void initState() {
    super.initState();
    _notes = context.read<NotesController>();
    _settings = context.read<SettingsController>();
    _canvas = context.read<CanvasController>();
    _notes.onBlankNoteCreated = _applyFolderTemplate;
    // 上次退出时正看着白板：文档由 `main` 恢复，这里只管「来了就切过去」。
    // 路径为 null 时这个标志没有意义（没有白板可切），一并挡掉。
    _pendingCanvasActivate =
        _settings.sessionCanvasActive && _settings.sessionCanvasPath != null;
    _canvas.addListener(_onCanvasChanged);
    // Prefer the newest note on first paint. A restored empty tab strip is a
    // state the user chose (they closed every tab), not an empty selection to
    // heal — `tabSessionRestored` keeps this from undoing it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_notes.selectedId == null &&
          _notes.allNotes.isNotEmpty &&
          !_notes.tabSessionRestored) {
        _notes.select(_notes.allNotes.first.id);
      }
    });
    // Coming back to the window is when an edit made in another program can be
    // picked up. Autosave keeps the draft authoritative while it is dirty.
    _stopVaultSync = startVaultSync(_pullFromDisk);
  }

  @override
  void dispose() {
    _canvas.removeListener(_onCanvasChanged);
    _notes.onBlankNoteCreated = null;
    _stopVaultSync?.call();
    _notices.dispose();
    _shellFocus.dispose();
    _bodyValue.dispose();
    super.dispose();
  }

  /// 白板文档换了（打开 / 新建 / 关掉 / 删除）时：记住这一页，必要时切过去。
  void _onCanvasChanged() {
    if (!mounted) return;
    if (_pendingCanvasActivate && _canvas.hasDocument) {
      _pendingCanvasActivate = false;
      _selectMainView(MainView.canvas);
      return;
    }
    _saveCanvasSession();
  }

  /// 把「开着哪块白板、是不是正在看它」写进偏好。
  ///
  /// 白板控制器每次自动保存都会通知一遍，但路径和主区视图都没变——所以
  /// 真正的写盘判断在 [SettingsController.saveCanvasSession] 里，值相同就
  /// 直接返回，打字时不会反复重写偏好文件。
  void _saveCanvasSession() {
    _settings.saveCanvasSession(
      path: _canvas.path,
      active: _mainView == MainView.canvas,
    );
  }

  Future<void> _pullFromDisk() async {
    if (!mounted) return;
    final String? notice = await context.read<NotesController>().syncFromDisk();
    if (!mounted || notice == null) return;
    _toast(notice, kind: NoticeKind.info, detail: '检测到外部修改');
  }

  void _toast(
    String message, {
    NoticeKind kind = NoticeKind.success,
    String? detail,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _notices.show(
      NoticeData(
        message: message,
        kind: kind,
        detail: detail,
        actionLabel: actionLabel,
        onAction: onAction,
      ),
    );
  }

  void _selectView(SidebarView view) {
    final SettingsController settings = context.read<SettingsController>();
    setState(() => _view = view);
    if (settings.sidebarCollapsed) settings.sidebarCollapsed = false;
    // 专注模式把两侧面板都藏起来了，切到某个视图却看不到它等于没切。
    if (settings.focusMode) settings.focusMode = false;
  }

  /// 切主区。图谱与正文共用同一块地方，所以这是「换一屏」而不是「开一个窗口」。
  void _selectMainView(MainView view) {
    if (_mainView == view) return;
    // 白板是一份文件，没有「空白的白板」这种状态：点进来之前得先有一份。
    // 这里只做「还没打开过就新建一块」，已经打开过就直接切过去。
    if (view == MainView.canvas &&
        !context.read<CanvasController>().hasDocument) {
      unawaited(_newCanvasBoard());
      return;
    }
    // 图片页也一样：没有「空的图片」这种状态。tab 还在但图被关掉之后，
    // 这里什么都不做，别把主区切成一块空白。
    if (view == MainView.image && _imagePath == null) return;
    final SettingsController settings = context.read<SettingsController>();
    setState(() {
      _mainView = view;
      if (view == MainView.graph) _graphOpened = true;
      if (view == MainView.canvas) _canvasOpened = true;
    });
    // 图谱、白板和图片都是全宽的：专注模式下面板都藏起来了，它们也需要
    // 那块地方。
    if (view != MainView.note && settings.focusMode) {
      settings.focusMode = false;
    }
    // 正文被藏起来了但还挂在树上（为了保住撤销栈），焦点必须收回外壳，
    // 否则在图谱界面敲字会写进看不见的编辑器里。
    _shellFocus.requestFocus();
    // 白板要自己收键盘（空格抓手、Ctrl+0）：`autofocus` 只在挂载那一次
    // 生效，切回来时不会重来一遍，所以这里显式要一次。等这一帧建完再要，
    // 否则 `currentState` 还是空的。
    if (view == MainView.canvas) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _canvasKey.currentState?.requestFocus();
      });
    }
    _saveCanvasSession();
  }

  /// 关掉「白板」页（点 tab 上的 ×）。
  ///
  /// 和笔记标签一样，只有点 × 才算关：放下那块文档（会先落盘），主区若正
  /// 停在这里就退回正文。文件本身还在，文件树里那一行照旧，点它就能再开。
  void _closeCanvas() {
    if (!_canvas.hasDocument) return;
    if (_mainView == MainView.canvas) {
      setState(() => _mainView = MainView.note);
    }
    // `close()` 会先 flush 再清空，然后通知——标签跟着 `hasDocument` 消失。
    unawaited(_canvas.close());
    _shellFocus.requestFocus();
  }

  /// 关掉「关系图谱」页。
  ///
  /// 和笔记标签一样，只有点 × 才算关：主区若正停在图谱就退回正文，并且
  /// 把 [GraphView] 从树上摘掉；下次再打开会是一张重新建好的图。
  void _closeGraph() {
    if (!_graphOpened) return;
    setState(() {
      _graphOpened = false;
      if (_mainView == MainView.graph) _mainView = MainView.note;
    });
    _shellFocus.requestFocus();
  }

  /// 关掉「图片」页。
  ///
  /// 和图谱页同一条口径：只有点 × 才算关。主区若正停在那张图上就退回正文，
  /// 并且把 [_imagePath] 清掉——下次点图片会重新进来（不再是上次那张）。
  void _closeImage() {
    if (_imagePath == null) return;
    setState(() {
      _imagePath = null;
      if (_mainView == MainView.image) _mainView = MainView.note;
    });
    _shellFocus.requestFocus();
  }

  /// 功能栏的白板按钮：新建一块「未命名白板.nrs」并切过去。
  ///
  /// 这里不弹选择框。白板是 vault 里的一份文件，已有的那几块本来就在文件
  /// 树里列着，要打开点它就行；按钮只做「再来一块」——和「新建笔记」是同
  /// 一个动作，只是产物是 `.nrs`。先弹一个框问「打开还是新建」，等于每次
  /// 新建都多一步。
  Future<void> _newCanvasBoard() async {
    final CanvasController canvas = context.read<CanvasController>();
    if (!await _newCanvas(canvas)) return;
    if (!mounted) return;
    _selectMainView(MainView.canvas);
  }

  /// 在当前笔记所在的文件夹里新建一块白板（没有当前笔记就落根目录）。
  Future<bool> _newCanvas(CanvasController canvas) async {
    final Note? open = _notes.draft ?? _notes.selectedNote;
    if (!await canvas.createNew(open?.folderPath ?? '')) {
      if (!mounted) return false;
      _toast('新建白板失败', kind: NoticeKind.error, detail: canvas.error);
      return false;
    }
    return true;
  }

  /// 文件树里点开一块白板：读进来，再切到白板视图。
  ///
  /// 这是「打开已有的那块」唯一的入口——功能栏那个按钮只负责新建。
  /// 用户已经挑好了是哪一块，这里不该再问一遍。
  Future<void> _openCanvasFile(CanvasRef board) async {
    final CanvasController canvas = context.read<CanvasController>();
    if (canvas.path != board.relativePath) {
      if (!await canvas.open(board.relativePath)) {
        if (mounted && canvas.error != null) {
          _toast('白板打不开', kind: NoticeKind.error, detail: canvas.error);
        }
        return;
      }
    }
    _selectMainView(MainView.canvas);
  }

  /// 文件树里点开一个附件。
  ///
  /// 图片在应用内开（主区那一页，所有图片共用一份）；其余交给系统的默认
  /// 程序——NRS 不解释 PDF、压缩包这些格式，在应用里硬画一遍只会多出一套
  /// 半成品预览。`svg` / `heic` / `tif` 也算「其余」：文件树给它们画图片
  /// 图标，但 Flutter 没有解码器，点开只会是一块空白。
  Future<void> _openVaultFile(VaultFile file) async {
    if (isViewableImageFileName(file.fileName)) {
      _openVaultImage(file);
      return;
    }
    final String? vault = _notes.vaultPath;
    if (vault == null) return;
    final String path = '$vault/${file.relativePath}';
    final bool opened = await openExternal(Uri.file(path).toString());
    if (!mounted || opened) return;
    _toast('打不开这个文件', kind: NoticeKind.error, detail: file.relativePath);
  }

  /// 在图片页里打开这张图。
  ///
  /// 已经停在图片页时只换内容，不切视图、不新开 tab——「所有图片共用这一个
  /// 图片 tab」就是这条：点第二张图，标题栏上那个 tab 还在原地，只是标题和
  /// 画面换了。
  void _openVaultImage(VaultFile file) {
    final SettingsController settings = context.read<SettingsController>();
    setState(() {
      _imagePath = file.relativePath;
      _mainView = MainView.image;
    });
    // 图片是整块画布：专注模式下面板都收起来了，它也需要那块地方。
    if (settings.focusMode) settings.focusMode = false;
    _shellFocus.requestFocus();
  }

  /// 把当前那张图交给系统看图程序。
  ///
  /// 应用内解不了的格式（`svg` / `heic` / `tif`）在图片页上给的就是这条路，
  /// 状态栏那枚按钮走的也是它。
  Future<void> _openImageExternally() async {
    final String? relative = _imagePath;
    final String? vault = _notes.vaultPath;
    if (relative == null || vault == null) return;
    final bool opened = await openExternal(
      Uri.file('$vault/$relative').toString(),
    );
    if (!mounted || opened) return;
    _toast('打不开这个文件', kind: NoticeKind.error, detail: relative);
  }

  /// 白板上双击一张文件卡片：打开那篇笔记并切回正文。
  ///
  /// 卡片里存的是相对路径（`FileNode.file`），所以按路径找笔记——白板
  /// 文件可以被别处改名，路径对不上就当这张卡片失效，什么都不做。
  void _openFromCanvas(String relativePath) {
    final NotesController notes = context.read<NotesController>();
    for (final Note note in notes.allNotes) {
      if (note.relativePath != relativePath) continue;
      notes.select(note.id);
      _selectMainView(MainView.note);
      return;
    }
    _toast('这篇笔记已经不在了', kind: NoticeKind.info, detail: relativePath);
  }

  Future<void> _openCanvasLink(String url) async {
    final bool opened = await openExternal(url);
    if (!mounted || opened) return;
    _toast('打不开这个链接', kind: NoticeKind.error, detail: url);
  }

  /// 图谱里双击一个节点：打开那篇笔记并切回正文。
  void _openFromGraph(String noteId) {
    context.read<NotesController>().select(noteId);
    _selectMainView(MainView.note);
  }

  /// 列表里点开一篇笔记：选中它，并把主区切回正文。
  ///
  /// 只 `select` 不切视图，就是「点了没反应」——主区还停在图谱或白板上，
  /// 屏幕上的东西一点没变，用户只能再去找那个标签页。
  void _openNote(Note note) {
    _notes.select(note.id);
    _selectMainView(MainView.note);
  }

  void _toggleSidebar() {
    final SettingsController settings = context.read<SettingsController>();
    settings.sidebarCollapsed = !settings.sidebarCollapsed;
    if (settings.focusMode) settings.focusMode = false;
  }

  static String _displayTitle(Note note) =>
      note.title.trim().isEmpty ? '未命名笔记' : note.title.trim();

  /// Deletes one note, with a dialog that shows exactly which file moves.
  Future<void> _confirmDelete(Note note) async {
    final NotesController notes = context.read<NotesController>();
    final String title = _displayTitle(note);
    final String path = note.relativePath;

    final bool? confirmed = await showDeleteDialog(
      context,
      title: '删除这篇笔记？',
      message: '「$title」将移入回收站，可在左侧功能栏的回收站中恢复。',
      targets: <DeleteTarget>[DeleteTarget(name: title, meta: path)],
    );

    if (confirmed != true) return;
    final DeleteOutcome outcome = await notes.deleteNotes(<Note>[note]);
    if (outcome.deleted == 0) return;
    _toast(
      '已移入回收站',
      detail: title,
      actionLabel: '撤销',
      onAction: outcome.receipts.isEmpty
          ? null
          : () => notes.restoreTrashEntries(<String>[
              for (final TrashEntry entry in outcome.receipts) entry.id,
            ]),
    );
  }

  /// Deletes what the file tree has selected. One file keeps the single-file
  /// dialog above; several get their titles listed, because a bulk delete is
  /// exactly where "what am I about to lose" needs to be on screen.
  ///
  /// Every file moves into the trash, so one 「撤销」 puts the whole batch back.
  /// A note whose name was taken in the meantime is restored under its own
  /// ` 2` name rather than overwriting the newer file — that is the store's
  /// `writeNewMarkdown`, not this dialog's, job.
  Future<void> _confirmDeleteMany(List<Note> targets) async {
    if (targets.isEmpty) return;
    if (targets.length == 1) return _confirmDelete(targets.single);

    final NotesController notes = context.read<NotesController>();
    final List<String> titles = targets.map(_displayTitle).toList();
    const int listed = 5;

    final bool? confirmed = await showDeleteDialog(
      context,
      title: '删除这 ${targets.length} 篇笔记？',
      message: '将移入回收站，可在左侧功能栏的回收站中恢复。',
      targets: <DeleteTarget>[
        for (final Note note in targets.take(listed))
          DeleteTarget(
            name: _displayTitle(note),
            meta: note.folderPath.isEmpty ? '根目录' : note.folderPath,
          ),
      ],
      overflowLabel: titles.length > listed
          ? '…还有 ${titles.length - listed} 篇'
          : null,
    );

    if (confirmed != true) return;
    final DeleteOutcome outcome = await notes.deleteNotes(targets);
    if (outcome.deleted == 0) return;
    final bool clean = outcome.failed == 0;
    _toast(
      clean ? '已移入回收站' : '${outcome.deleted} 篇移入回收站',
      detail: clean ? '${outcome.deleted} 篇笔记' : '${outcome.failed} 篇未能删除',
      actionLabel: '撤销',
      onAction: outcome.receipts.isEmpty
          ? null
          : () => notes.restoreTrashEntries(<String>[
              for (final TrashEntry entry in outcome.receipts) entry.id,
            ]),
    );
  }

  /// Deletes a folder and the notes inside it.
  ///
  /// The dialog counts the notes first, because one folder action can take many
  /// notes at once. The controller then refuses while everything is still in
  /// place if the folder holds anything the note trash cannot restore; that
  /// refusal is reported as an error notice rather than a half-done delete.
  Future<bool> _confirmDeleteFolder(String folderPath) async {
    final NotesController notes = context.read<NotesController>();
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    final String name = folder.split('/').last;
    final int noteCount = notes.allNotes
        .where(
          (Note note) =>
              note.folderPath == folder ||
              note.folderPath.startsWith('$folder/'),
        )
        .length;
    final int subfolders = notes.folders
        .where((String path) => path.startsWith('$folder/'))
        .length;

    final bool? confirmed = await showDeleteDialog(
      context,
      title: '删除文件夹「$name」？',
      message: noteCount == 0
          ? '文件夹里没有笔记，删除后不会进入回收站。'
          : '文件夹里的 $noteCount 篇笔记将移入回收站，可在左侧功能栏的回收站中恢复。',
      targets: <DeleteTarget>[
        DeleteTarget(
          name: folder,
          icon: LucideIcons.folder,
          monoName: true,
          meta: subfolders > 0 ? '$subfolders 个子文件夹' : null,
        ),
      ],
      warning: '若里面还有不是笔记的文件，整个删除会被取消。',
    );

    if (confirmed != true) return false;
    final FolderDeleteOutcome outcome = await notes.deleteFolder(folder);
    final bool undoable = outcome.receipts.isNotEmpty;
    void undo() => notes.restoreTrashEntries(<String>[
      for (final TrashEntry entry in outcome.receipts) entry.id,
    ]);

    if (outcome.blocked != null) {
      _toast('未能删除文件夹「$name」', kind: NoticeKind.error, detail: outcome.blocked);
      return false;
    }
    if (outcome.removed) {
      if (outcome.deleted == 0) {
        _toast('已删除空文件夹「$name」');
        return true;
      }
      _toast(
        '已删除文件夹「$name」',
        detail: '${outcome.deleted} 篇笔记已移入回收站',
        actionLabel: undoable ? '撤销' : null,
        onAction: undoable ? undo : null,
      );
      return true;
    }
    // The folder stayed. When nothing could be deleted the controller's error
    // banner already names the note and the reason; otherwise report the split
    // honestly and still offer to undo the notes that did move.
    if (outcome.deleted == 0 && outcome.failed > 0) return false;
    _toast(
      '文件夹「$name」未删除',
      kind: NoticeKind.error,
      detail: outcome.failed > 0
          ? '${outcome.deleted} 篇已移入回收站,${outcome.failed} 篇失败'
          : '里面还有别的内容',
      actionLabel: undoable ? '撤销' : null,
      onAction: undoable ? undo : null,
    );
    return outcome.deleted > 0;
  }

  /// 文件树里右键白板点了「删除白板」。
  ///
  /// 和删笔记走同一张确认卡片、同一个回收站：白板也是 vault 里的一份文件，
  /// 删错了应该能用同一套办法找回来。区别只在恢复——白板是把文件搬回去，
  /// 笔记是把正文写成一篇新的 `.md`（见回收站里的分流）。
  ///
  /// 传进来的可能是一段多选：一次确认、一次「撤销」把整段都放回去。
  Future<void> _confirmDeleteCanvas(List<CanvasRef> boards) async {
    if (boards.isEmpty) return;
    final CanvasController canvas = context.read<CanvasController>();
    String titleOf(CanvasRef board) =>
        board.title.trim().isEmpty ? '未命名白板' : board.title.trim();
    final bool single = boards.length == 1;
    const int listed = 5;

    final bool? confirmed = await showDeleteDialog(
      context,
      title: single ? '删除这块白板？' : '删除这 ${boards.length} 块白板？',
      message: single
          ? '「${titleOf(boards.single)}」将移入回收站，可在左侧功能栏的回收站中恢复。'
          : '将移入回收站，可在左侧功能栏的回收站中恢复。',
      targets: <DeleteTarget>[
        for (final CanvasRef board in boards.take(listed))
          DeleteTarget(
            name: titleOf(board),
            meta: board.relativePath,
            icon: LucideIcons.layoutDashboard,
          ),
      ],
      overflowLabel: boards.length > listed
          ? '…还有 ${boards.length - listed} 块'
          : null,
    );

    if (confirmed != true || !mounted) return;
    // 删之前记下主区正开着哪一块：删的要是它，画布上就没东西可画了。
    final String? openPath = canvas.path;
    final List<TrashEntry> receipts = <TrashEntry>[];
    int failed = 0;
    for (final CanvasRef board in boards) {
      final ({bool ok, TrashEntry? entry}) result = await canvas.deleteCanvas(
        board.relativePath,
      );
      if (!result.ok) {
        failed++;
        continue;
      }
      final TrashEntry? entry = result.entry;
      if (entry != null) receipts.add(entry);
    }
    if (!mounted) return;

    final bool deletedOpen =
        openPath != null &&
        boards.any((CanvasRef board) => board.relativePath == openPath);
    // 删掉的就是屏幕上这一块：主区已经没有东西可画了，退回正文，而不是
    // 留一块空白板让人以为「白板坏了」。
    if (deletedOpen && _mainView == MainView.canvas) {
      _selectMainView(MainView.note);
    }

    if (failed > 0 && receipts.isEmpty) {
      _toast('删除白板失败', kind: NoticeKind.error, detail: canvas.error);
      return;
    }
    if (receipts.isEmpty) {
      // 浏览器端没有回收站，没有可撤销的东西，就别提「回收站」。
      _toast(single ? '已删除白板' : '已删除 ${boards.length} 块白板');
      return;
    }
    _toast(
      failed == 0 ? '已移入回收站' : '${receipts.length} 块白板移入回收站',
      detail: single ? titleOf(boards.single) : '${receipts.length} 块白板',
      actionLabel: '撤销',
      onAction: () {
        for (final TrashEntry entry in receipts) {
          unawaited(canvas.restoreTrash(entry.id));
        }
      },
    );
  }

  void _createNote() {
    _notes.createNote();
  }

  // --------------------------------------------------------------- templates

  Future<void> _openTemplatePicker() async {
    if (!mounted) return;
    final String folder = _settings.templatesFolder;
    final TemplatePickerResult? result = await showTemplatePicker(
      context,
      templates: _templates.discoverTemplates(_notes.allNotes, folder),
      templatesFolder: folder,
      canInsert: _notes.selectedNote != null,
    );
    if (!mounted || result == null) return;

    switch (result.action) {
      case TemplatePickerAction.insert:
        final Note? template = result.template;
        if (template != null) await _insertTemplate(template);
      case TemplatePickerAction.newNote:
        final Note? template = result.template;
        if (template != null) await _createNoteFromTemplate(template);
      case TemplatePickerAction.openFolder:
        await _showTemplatesFolder();
      case TemplatePickerAction.newTemplate:
        await _createTemplateNote();
      case TemplatePickerAction.edit:
        final Note? template = result.template;
        if (template != null) _notes.select(template.id);
    }
  }

  Future<void> _insertTemplate(Note template) async {
    final Note? target = _notes.draft ?? _notes.selectedNote;
    if (target == null) return;
    final EditorPaneState? editor = _editorKey.currentState;
    final String selection = editor?.selectedBodyText ?? '';
    try {
      final NtlRenderResult rendered = await _templates.render(
        template: template,
        note: target,
        notes: _notes.allNotes,
        interaction: TemplateDialogInteraction(context),
        selection: selection,
        vaultRoot: _notes.vaultLocation,
      );
      if (!mounted || _notes.selectedNote?.id != target.id) return;
      // One edit: a single undo takes the whole template back out.
      _editorKey.currentState?.insertTemplate(
        rendered.text,
        cursorOffset: rendered.cursorOffset,
      );
    } on TemplateCancelled {
      // Closing a prompt is not a failure: the editor was never touched.
    } catch (e) {
      if (!mounted) return;
      _toast('模板渲染失败', kind: NoticeKind.error, detail: '$e');
    }
  }

  /// Runs one of the user's template shortcuts.
  ///
  /// The binding stores a note id, so a template that was deleted or renamed
  /// away simply stops firing. 「插入」 needs an open note; 「新建」 never does.
  Future<void> _runTemplateHotkey(TemplateHotkey hotkey) async {
    Note? template;
    for (final Note note in _notes.allNotes) {
      if (note.id == hotkey.templateId) {
        template = note;
        break;
      }
    }
    if (template == null || !mounted) return;

    if (hotkey.action == TemplateAction.create) {
      await _createNoteFromTemplate(template);
      return;
    }
    if (_notes.draft == null && _notes.selectedNote == null) {
      _toast('没有打开的笔记', kind: NoticeKind.info, detail: '先打开一篇笔记，或把动作改成「新建笔记」');
      return;
    }
    await _insertTemplate(template);
  }

  Future<void> _createNoteFromTemplate(Note template) async {
    final String? title = await showTemplateNewNoteDialog(
      context,
      templateTitle: template.title,
    );
    if (!mounted || title == null) return;
    final Note note = _notes.createNote(title: title, runCreationHook: false);
    await _renderIntoBlankNote(template, note, explicit: true);
  }

  /// Renders [template] into [note] and writes it only while the note is still
  /// empty. Shared by the explicit new-note flow and folder automation; the
  /// write itself re-checks emptiness because a prompt can stay open for a
  /// while and the user may already be typing underneath it.
  Future<void> _renderIntoBlankNote(
    Note template,
    Note note, {
    required bool explicit,
  }) async {
    final Note fresh = _notes.allNotes.firstWhere(
      (Note n) => n.id == note.id,
      orElse: () => note,
    );
    if (fresh.body.isNotEmpty) {
      if (explicit) {
        _toast('模板未套用', kind: NoticeKind.info, detail: '笔记里已经有内容了');
      }
      return;
    }

    try {
      final NtlRenderResult rendered = await _templates.render(
        template: template,
        note: fresh,
        notes: _notes.allNotes,
        interaction: TemplateDialogInteraction(context),
        vaultRoot: _notes.vaultLocation,
      );
      if (!mounted) return;
      final bool applied = await _notes.applyBodyIfEmpty(
        note.id,
        rendered.text,
      );
      if (!mounted) return;
      if (!applied) {
        if (explicit) {
          _toast('模板未套用', kind: NoticeKind.info, detail: '笔记里已经有内容了');
        }
        return;
      }
      await _placeCaretIn(
        note.id,
        rendered.cursorOffset ?? rendered.text.length,
      );
    } on TemplateCancelled {
      if (!mounted) return;
      _toast(
        explicit ? '已取消模板' : '已取消模板套用',
        kind: NoticeKind.info,
        detail: '笔记保留为空',
      );
    } catch (e) {
      if (!mounted) return;
      _toast('模板渲染失败', kind: NoticeKind.error, detail: '$e');
    }
  }

  Future<void> _placeCaretIn(String noteId, int offset) async {
    if (!mounted || _notes.selectedNote?.id != noteId) return;
    // The editor rebinds the new body on its next build; setting the caret
    // before that would clamp it into the still-empty old text.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _notes.selectedNote?.id != noteId) return;
    _editorKey.currentState?.placeCaretAt(offset);
  }

  /// The controller hook: every blank note created through the normal paths
  /// gets its folder's template, unless the user turned the switch off.
  Future<void> _applyFolderTemplate(Note note) async {
    if (!mounted || !_settings.autoApplyFolderTemplates) return;
    final Note? template = _templates.folderTemplateFor(
      notes: _notes.allNotes,
      folderPath: note.folderPath,
      templatesFolder: _settings.templatesFolder,
      rules: _settings.folderTemplateRules,
    );
    if (template == null || !mounted) return;
    await _renderIntoBlankNote(template, note, explicit: false);
  }

  Future<void> _showTemplatesFolder() async {
    final String folder = _settings.templatesFolder;
    if (!await _notes.ensureFolder(folder)) return;
    if (!mounted) return;
    _selectView(SidebarView.files);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _listKey.currentState?.revealFolder(folder);
  }

  Future<void> _createTemplateNote() async {
    final String folder = _settings.templatesFolder;
    if (!await _notes.ensureFolder(folder)) return;
    if (!mounted) return;
    _selectView(SidebarView.files);
    _notes.createNote(title: '新模板', folderPath: folder, runCreationHook: false);
  }

  Map<ShortcutActivator, VoidCallback> _globalShortcuts() {
    final NotesController notes = context.read<NotesController>();
    final SettingsController settings = context.read<SettingsController>();
    final Map<ShortcutActivator, VoidCallback> bindings =
        <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, control: true):
              _createNote,
          const SingleActivator(LogicalKeyboardKey.keyP, control: true):
              _openTemplatePicker,
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
              showSettingsDialog(context),
          // 图谱与正文共用主区，所以是「换一屏」的快捷键，不是「开窗口」。
          const SingleActivator(LogicalKeyboardKey.keyG, control: true): () =>
              _selectMainView(
                _mainView == MainView.graph ? MainView.note : MainView.graph,
              ),
          const SingleActivator(
            LogicalKeyboardKey.keyB,
            control: true,
            shift: true,
          ): () => _selectMainView(
            _mainView == MainView.canvas ? MainView.note : MainView.canvas,
          ),
          const SingleActivator(LogicalKeyboardKey.backslash, control: true):
              _toggleSidebar,
          const SingleActivator(
            LogicalKeyboardKey.keyF,
            control: true,
            shift: true,
          ): () =>
              settings.focusMode = !settings.focusMode,
          const SingleActivator(
            LogicalKeyboardKey.keyO,
            control: true,
            shift: true,
          ): () =>
              settings.outlineVisible = !settings.outlineVisible,
          const SingleActivator(
            LogicalKeyboardKey.arrowUp,
            control: true,
            alt: true,
          ): () =>
              notes.selectAdjacentInList(notes.visibleNotes, -1),
          const SingleActivator(
            LogicalKeyboardKey.arrowDown,
            control: true,
            alt: true,
          ): () =>
              notes.selectAdjacentInList(notes.visibleNotes, 1),
          // Ctrl+Tab walks the open tabs, the way every tabbed app does.
          const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
              notes.selectAdjacentTab(1),
          const SingleActivator(
            LogicalKeyboardKey.tab,
            control: true,
            shift: true,
          ): () =>
              notes.selectAdjacentTab(-1),
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (settings.focusMode) settings.focusMode = false;
          },
        };

    // Template bindings come from settings, so they are added on top of the
    // built-ins. putIfAbsent keeps a stale or hand-edited binding from
    // replacing the built-in shortcut it collides with; the hotkey dialog
    // refuses such chords in the first place.
    for (final TemplateHotkey hotkey in settings.templateHotkeys.values) {
      if (!hotkey.isValid) continue;
      final LogicalKeyboardKey? key = LogicalKeyboardKey.findKeyByKeyId(
        hotkey.keyId,
      );
      if (key == null) continue;
      bindings.putIfAbsent(
        SingleActivator(
          key,
          control: hotkey.control,
          alt: hotkey.alt,
          shift: hotkey.shift,
          includeRepeats: false,
        ),
        () => () {
          _runTemplateHotkey(hotkey);
        },
      );
    }
    return bindings;
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // 外壳只需要错误横幅；正文、选中等变化交给各自的面板订阅。
    // 以前这里 watch 整个控制器，用户每敲一个字都会重建整棵外壳。
    final String? error = context.select<NotesController, String?>(
      (NotesController notes) => notes.error,
    );
    final SettingsController settings = context.watch<SettingsController>();
    // 白板这一页的标题来自控制器：同一时刻只开着一块，换一块只是换名字。
    final String? canvasPath = context.select<CanvasController, String?>(
      (CanvasController canvas) => canvas.path,
    );
    final bool zen = settings.focusMode;

    return NoticeScope(
      controller: _notices,
      child: CallbackShortcuts(
        bindings: _globalShortcuts(),
        child: Focus(
          focusNode: _shellFocus,
          autofocus: true,
          child: Scaffold(
            backgroundColor: p.canvas,
            // The title bar aligns its tabs to the editor and its outline button
            // to the outline, so it has to know where those two seams are — and
            // they depend on the window width (the outline steps aside in a
            // narrow window) as well as on both drag handles.
            body: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                // 图谱和图片要整块画布：右侧那一栏（大纲 / 表格 / 图片列表）
                // 在它们里收起来，退出来自动回来——所以这里只做「不显示」，
                // 不去改 `settings.*Visible`。改设置会写盘，而且「关掉再打开」
                // 会把用户原来的选择弄丢。
                final bool panelAllowed =
                    _mainView != MainView.graph && _mainView != MainView.image;
                final bool showOutline =
                    panelAllowed &&
                    !zen &&
                    settings.outlineVisible &&
                    c.maxWidth >= AppLayout.outlineMinShellWidth;
                // 大纲与表格共用右侧那一栏：设置层已保证两者不会同时为真，
                // 这里只负责在窗口太窄时把这一栏让给正文。
                final bool showTable =
                    panelAllowed &&
                    !zen &&
                    settings.tablePanelVisible &&
                    c.maxWidth >= AppLayout.outlineMinShellWidth;
                // 图片列表是这一栏的第三个住户，互斥同样由设置层保证。
                final bool showImages =
                    panelAllowed &&
                    !zen &&
                    settings.imagePanelVisible &&
                    c.maxWidth >= AppLayout.outlineMinShellWidth;
                final double leftInset = zen
                    ? 0
                    : AppLayout.railWidth +
                          (settings.sidebarCollapsed
                              ? 0
                              : settings.listWidth +
                                    AppLayout.resizeHandleWidth);
                // The toggle pair aligns with the *panel*, not with the drag
                // handle in front of it, so the handle's width is not counted.
                // 三块面板共用同一列、同一个宽度，所以这里不需要分支。
                final double rightInset = showOutline || showTable || showImages
                    ? settings.rightPanelWidth
                    : 0;
                return Column(
                  children: <Widget>[
                    // The app's own caption: drag to move, double-click to
                    // maximize, and the three window buttons. It stays in focus
                    // mode too — without it there would be no way to move the
                    // window at all.
                    AppTitleBar(
                      view: _view,
                      onSelectView: _selectView,
                      onToggleSidebar: _toggleSidebar,
                      onCreateNote: _createNote,
                      mainView: _mainView,
                      onSelectMainView: _selectMainView,
                      graphOpen: _graphOpened,
                      onCloseGraph: _closeGraph,
                      imageTitle: _imagePath?.split('/').last,
                      onCloseImage: _closeImage,
                      canvasTitle: canvasPath == null
                          ? null
                          : canvasTitleOf(canvasPath),
                      onCloseCanvas: _closeCanvas,
                      leftInset: leftInset,
                      rightInset: rightInset,
                    ),
                    if (error != null) _ErrorBanner(message: error),
                    Expanded(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              // The rail keeps only what has no place in the caption:
                              // the tag view and the vault utilities.
                              if (!zen)
                                AppRail(
                                  view: _view,
                                  onSelectView: _selectView,
                                  onOpenTemplates: _openTemplatePicker,
                                  onOpenGraph: () =>
                                      _selectMainView(MainView.graph),
                                  onOpenCanvas: _newCanvasBoard,
                                  onOpenTrash: () => showTrashDialog(context),
                                  onOpenSettings: () =>
                                      showSettingsDialog(context),
                                  graphActive: _mainView == MainView.graph,
                                  canvasActive: _mainView == MainView.canvas,
                                ),
                              // The panes each get a handle on the edge that faces the
                              // editor, and each handle is carved out of the pane it
                              // follows, so its hairline lands on the seam and the
                              // boundary reads the same everywhere.
                              if (!zen &&
                                  !settings.sidebarCollapsed) ...<Widget>[
                                SizedBox(
                                  width: settings.listWidth,
                                  child: NoteListPanel(
                                    key: _listKey,
                                    view: _view,
                                    onCreateNote: _createNote,
                                    onDeleteNotes: _confirmDeleteMany,
                                    onDeleteFolder: _confirmDeleteFolder,
                                    onSwitchView: _selectView,
                                    onOpenNote: _openNote,
                                    onOpenCanvas: _openCanvasFile,
                                    onDeleteCanvas: _confirmDeleteCanvas,
                                    onOpenFile: _openVaultFile,
                                    // 搜索结果先开笔记，正文要等这一帧绑定
                                    // 完才可用，所以跳转挂到帧末。
                                    onRevealOffset: (int offset) {
                                      WidgetsBinding.instance
                                          .addPostFrameCallback((_) {
                                            if (!mounted) return;
                                            _editorKey.currentState?.goToOffset(
                                              offset,
                                            );
                                          });
                                    },
                                  ),
                                ),
                                ResizeHandle(
                                  background: p.sidebar,
                                  onDelta: (double d) => settings.listWidth =
                                      settings.listWidth + d,
                                ),
                              ],
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    // 正文用 Offstage 藏起来而不是从树上摘掉：
                                    // 摘掉会连撤销栈和光标一起丢，去图谱看一眼
                                    // 回来就 undo 不了了。
                                    Offstage(
                                      offstage: _mainView != MainView.note,
                                      child: EditorPane(
                                        key: _editorKey,
                                        bodyValue: _bodyValue,
                                        showSearchHighlights:
                                            _view == SidebarView.search,
                                        onDelete: _confirmDelete,
                                        onOpenSearch: () =>
                                            _selectView(SidebarView.search),
                                        onCursorLineChanged: (int line) {
                                          if (line == _cursorLine) return;
                                          setState(() => _cursorLine = line);
                                        },
                                      ),
                                    ),
                                    if (_graphOpened)
                                      Offstage(
                                        offstage: _mainView != MainView.graph,
                                        child: GraphView(
                                          notes: context
                                              .watch<NotesController>()
                                              .allNotes,
                                          currentId: context
                                              .watch<NotesController>()
                                              .selectedId,
                                          onOpenNote: _openFromGraph,
                                          settings: _settings,
                                        ),
                                      ),
                                    // 白板同理：懒建 + Offstage。视口和滚动位置
                                    // 都活在 State 里，摘掉子树会一起丢。
                                    if (_canvasOpened)
                                      Offstage(
                                        offstage: _mainView != MainView.canvas,
                                        // 文件进白板的**唯一**通道：左侧文件
                                        // 列表拖过来的笔记。桌面上的文件先拖
                                        // 进列表（导入成库里的笔记），再从这
                                        // 里拖进去；画布那层 `DropRegion` 只
                                        // 负责把桌面来的一律挡回去。
                                        // 文件夹拖拽不接——那是移动，不是引用。
                                        child: DragTarget<VaultDragPayload>(
                                          onWillAcceptWithDetails:
                                              (
                                                DragTargetDetails<
                                                  VaultDragPayload
                                                >
                                                d,
                                              ) =>
                                                  d.data.folder == null &&
                                                  d.data
                                                      .referencePaths()
                                                      .isNotEmpty,
                                          onAcceptWithDetails:
                                              (
                                                DragTargetDetails<
                                                  VaultDragPayload
                                                >
                                                d,
                                              ) {
                                                final Offset? pointer =
                                                    d.data.pointer;
                                                // 笔记和图片走同一条落卡通道：
                                                // 卡片里存的都是库内相对路径，
                                                // 板子不拷贝内容（§14.15）。
                                                final List<String> paths = d
                                                    .data
                                                    .referencePaths();
                                                if (pointer == null ||
                                                    paths.isEmpty) {
                                                  return;
                                                }
                                                _canvasKey.currentState
                                                    ?.addReferencedNotesFromGlobal(
                                                      paths,
                                                      pointer,
                                                    );
                                              },
                                          builder:
                                              (
                                                BuildContext context,
                                                List<VaultDragPayload?>
                                                candidate,
                                                List<dynamic> rejected,
                                              ) => CanvasBoard(
                                                key: _canvasKey,
                                                document: context
                                                    .watch<CanvasController>()
                                                    .document,
                                                onChanged: context
                                                    .read<CanvasController>()
                                                    .markDirty,
                                                files:
                                                    <
                                                      ({
                                                        String path,
                                                        String title,
                                                      })
                                                    >[
                                                      for (final Note note
                                                          in context
                                                              .watch<
                                                                NotesController
                                                              >()
                                                              .allNotes)
                                                        (
                                                          path:
                                                              note.relativePath,
                                                          title: _displayTitle(
                                                            note,
                                                          ),
                                                        ),
                                                    ],
                                                // 文件卡片显示的就是这份正文：白板引用
                                                // 笔记，不是复制一份。笔记一改，外壳
                                                // 重建，卡片下一帧就是新的。
                                                noteBodies: <String, String>{
                                                  for (final Note note
                                                      in context
                                                          .watch<
                                                            NotesController
                                                          >()
                                                          .allNotes)
                                                    note.relativePath:
                                                        note.body,
                                                },
                                                onOpenFile: _openFromCanvas,
                                                onOpenLink: _openCanvasLink,
                                                onEditFileBody:
                                                    (
                                                      String path,
                                                      String body,
                                                    ) => context
                                                        .read<NotesController>()
                                                        .writeNoteBody(
                                                          path,
                                                          body,
                                                        ),
                                                // 图片卡片的字节：画布只认相对
                                                // 路径，读盘这一步在外壳（画布
                                                // 不能碰 `dart:io`，Web 也要编译）。
                                                imageBytesOf: (String path) {
                                                  final String? vault =
                                                      _notes.vaultPath;
                                                  if (vault == null) {
                                                    return Future<
                                                      Uint8List?
                                                    >.value(null);
                                                  }
                                                  return imageBytesAt(
                                                    '$vault/$path',
                                                  );
                                                },
                                                // 粘贴的截图先存成库里的一份
                                                // 文件，卡片只引用它（§14.20）。
                                                onSaveImage: (Uint8List png) {
                                                  final String? board =
                                                      canvasPath;
                                                  if (board == null) {
                                                    return Future<
                                                      String?
                                                    >.value(null);
                                                  }
                                                  return _notes
                                                      .saveCanvasImage(
                                                        board,
                                                        png,
                                                      );
                                                },
                                                // 从桌面拖进来的图片：读字节
                                                // → 存进库里 → 返回相对路径。
                                                onDropImageFiles:
                                                    (List<String> paths) async {
                                                      final List<String> out =
                                                          <String>[];
                                                      final String? board =
                                                          canvasPath;
                                                      if (board == null) {
                                                        return out;
                                                      }
                                                      for (final String path
                                                          in paths) {
                                                        final Uint8List?
                                                        bytes =
                                                            await imageBytesAt(
                                                              path,
                                                            );
                                                        if (bytes == null) {
                                                          continue;
                                                        }
                                                        final String? saved =
                                                            await _notes
                                                                .saveCanvasImage(
                                                                  board,
                                                                  bytes,
                                                                );
                                                        if (saved != null) {
                                                          out.add(saved);
                                                        }
                                                      }
                                                      return out;
                                                    },
                                              ),
                                        ),
                                      ),
                                    // 图片页：所有图片共用这一份 State。换图只
                                    // 换 `_imagePath`，缩放状态由 `didUpdateWidget`
                                    // 复位，不重建整棵子树。
                                    if (_imagePath != null)
                                      Offstage(
                                        offstage: _mainView != MainView.image,
                                        child: ImagePane(
                                          source: _imagePath!,
                                          absolutePath:
                                              '${_notes.vaultPath ?? ''}/$_imagePath',
                                          onOpenExternal: _openImageExternally,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (showOutline) ...<Widget>[
                                // The handle sits left of the outline, so dragging it
                                // rightwards narrows the column.
                                ResizeHandle(
                                  background: p.surface,
                                  onDelta: (double d) =>
                                      settings.rightPanelWidth =
                                          settings.rightPanelWidth - d,
                                ),
                                _OutlineRegion(
                                  currentLine: _cursorLine,
                                  width: settings.rightPanelWidth,
                                  onSelect: (int line) => _editorKey
                                      .currentState
                                      ?.goToHeading(line),
                                ),
                              ],
                              if (showTable) ...<Widget>[
                                ResizeHandle(
                                  background: p.surface,
                                  onDelta: (double d) =>
                                      settings.rightPanelWidth =
                                          settings.rightPanelWidth - d,
                                ),
                                TablePanel(
                                  width: settings.rightPanelWidth,
                                  value: _bodyValue,
                                  onApply: (MarkdownEditFn fn) =>
                                      _editorKey.currentState?.applyEdit(fn),
                                  onJump: (int offset) => _editorKey
                                      .currentState
                                      ?.goToOffset(offset),
                                ),
                              ],
                              if (showImages) ...<Widget>[
                                ResizeHandle(
                                  background: p.surface,
                                  onDelta: (double d) =>
                                      settings.rightPanelWidth =
                                          settings.rightPanelWidth - d,
                                ),
                                _ImageRegion(
                                  width: settings.rightPanelWidth,
                                  onSelect: (int offset) => _editorKey
                                      .currentState
                                      ?.goToOffset(offset),
                                ),
                              ],
                            ],
                          ),
                          // The notice lives in the window's top-right corner,
                          // where the eye already is after a toolbar action.
                          // It may overlap the outline; the countdown is short
                          // and it is the one piece of chrome allowed to float.
                          Positioned(
                            top: AppSpace.xs,
                            left: 10,
                            right: 10,
                            child: Align(
                              alignment: Alignment.topRight,
                              child: NoticeHost(controller: _notices),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 大纲只订阅当前草稿，不再让一次击键重建整棵外壳。
///
/// 它仍然会在正文变化时重算（这是大纲的职责），但主题、保存状态、面板宽度
/// 等通知不会经过这里。正文对象没换时直接复用上一次的标题列表。
class _OutlineRegion extends StatefulWidget {
  const _OutlineRegion({
    required this.currentLine,
    required this.width,
    required this.onSelect,
  });

  final int currentLine;
  final double width;
  final ValueChanged<int> onSelect;

  @override
  State<_OutlineRegion> createState() => _OutlineRegionState();
}

class _OutlineRegionState extends State<_OutlineRegion> {
  String? _noteId;
  String? _body;
  List<Heading> _headings = const <Heading>[];

  @override
  Widget build(BuildContext context) {
    final Note? open = context.select<NotesController, Note?>(
      (NotesController notes) => notes.draft ?? notes.selectedNote,
    );
    final List<Heading> headings;
    if (open == null) {
      _noteId = null;
      _body = null;
      headings = _headings = const <Heading>[];
    } else if (_noteId == open.id && identical(_body, open.body)) {
      headings = _headings;
    } else {
      _noteId = open.id;
      _body = open.body;
      headings = _headings = extractHeadings(open.body);
    }

    return OutlinePanel(
      headings: headings,
      currentLine: widget.currentLine,
      width: widget.width,
      onSelect: widget.onSelect,
    );
  }
}

/// 图片列表只订阅当前草稿，和 [_OutlineRegion] 同一条规矩。
///
/// 正文对象没换就复用上一次扫出来的列表——否则主题、保存状态这些通知都会让
/// 整篇重新逐行扫一遍。缩略图本身由 `ImagePanel` 各自挂着，图片解码结果在
/// Flutter 的 `ImageCache` 里，切换面板不会重新下载。
class _ImageRegion extends StatefulWidget {
  const _ImageRegion({required this.width, required this.onSelect});

  final double width;

  /// 点了某一张：参数是那一行的行首偏移。
  final ValueChanged<int> onSelect;

  @override
  State<_ImageRegion> createState() => _ImageRegionState();
}

class _ImageRegionState extends State<_ImageRegion> {
  String? _noteId;
  String? _body;
  List<NoteImage> _images = const <NoteImage>[];

  @override
  Widget build(BuildContext context) {
    final Note? open = context.select<NotesController, Note?>(
      (NotesController notes) => notes.draft ?? notes.selectedNote,
    );
    final List<NoteImage> images;
    if (open == null) {
      _noteId = null;
      _body = null;
      images = _images = const <NoteImage>[];
    } else if (_noteId == open.id && identical(_body, open.body)) {
      images = _images;
    } else {
      _noteId = open.id;
      _body = open.body;
      images = _images = extractImages(open.body);
    }

    // `read` 而不是 `watch`：这里只要一个能随时问「这张图在磁盘哪儿」的句柄，
    // 不需要跟着每一次击键重建面板。
    final NotesController notes = context.read<NotesController>();
    return ImagePanel(
      images: images,
      width: widget.width,
      onSelect: widget.onSelect,
      providerFor: (NoteImage image) =>
          imageProviderFor(notes.assetPathFor(image.source), image.source),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.read<NotesController>();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.sm,
      ),
      color: p.dangerSoft,
      child: Row(
        children: <Widget>[
          Icon(LucideIcons.circleAlert, size: 15, color: p.danger),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: AppText.ui, color: p.danger),
            ),
          ),
          AppIconButton(
            icon: LucideIcons.x,
            tooltip: '关闭',
            size: 24,
            iconSize: 13,
            onPressed: () => notes.setError(null),
          ),
        ],
      ),
    );
  }
}
