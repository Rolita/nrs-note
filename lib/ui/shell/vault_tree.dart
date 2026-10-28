import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/image_file.dart';
import '../../data/models/note.dart';
import '../../data/storage/canvas_store.dart';
import '../../data/storage/note_store.dart';
import '../../state/notes_controller.dart';
import '../common/app_widgets.dart';
import '../editor/editor_context_menu.dart';
import 'data_safety_dialogs.dart';

/// The real directory tree of the vault: folders first, then the files that
/// live directly in each one — notes, boards (`.nrs`) and everything else
/// (pictures, attachments).
///
/// Every expanded folder keeps its own row; an empty one simply shows nothing
/// underneath. Expansion is on purpose *not* persisted, and the vault opens
/// fully collapsed: with eight hundred notes, an all-expanded tree is a wall
/// the user has to fold back one folder at a time before it becomes a list.
///
/// Files select like a file manager: a plain click opens one, Shift+click takes
/// the visible range from the anchor, and a right-click offers the per-file
/// actions. The multi-selection is local to the tree — the editor still edits
/// the one note that was opened last.
///
/// Boards (`.nrs`) are selectable on exactly those terms: same highlight, same
/// Shift range, even across the two kinds. They are only *stored* apart, so a
/// menu acts on its own kind — a note row's 「删除」 takes notes, a board row's
/// takes boards — because deleting a note rebuilds markdown while deleting a
/// board moves a file.
class VaultTree extends StatefulWidget {
  const VaultTree({
    super.key,
    required this.notes,
    required this.onOpenNote,
    required this.onDeleteNotes,
    required this.onDeleteFolder,
    this.canvases = const <CanvasRef>[],
    this.files = const <VaultFile>[],
    this.activeCanvasPath,
    this.onOpenCanvas,
    this.onDeleteCanvas,
    this.onOpenFile,
    this.onAllExpandedChanged,
  });

  final NotesController notes;
  final ValueChanged<Note> onOpenNote;
  final ValueChanged<List<Note>> onDeleteNotes;

  /// 白板清单。它们和笔记一起排在同一层里，才能解释「这个文件夹里到底有
  /// 什么」——白板不打开的时候在别处根本看不见。
  final List<CanvasRef> canvases;

  /// 图片、附件这些非笔记文件。只显示，不解析。
  final List<VaultFile> files;

  /// 当前打开的那块白板，用来给它的行加高亮。
  final String? activeCanvasPath;

  final ValueChanged<CanvasRef>? onOpenCanvas;

  /// 右键「删除白板」。确认、移入回收站、撤销都由外壳负责，树只负责问。
  ///
  /// 传的是整段选中（可能不止一块），和 [onDeleteNotes] 一个形状。
  final ValueChanged<List<CanvasRef>>? onDeleteCanvas;

  final ValueChanged<VaultFile>? onOpenFile;

  /// Deletes a folder after the shell's confirmation. True means the folder or
  /// the notes inside it are gone, so this tree drops its local expansion state.
  final Future<bool> Function(String folderPath) onDeleteFolder;

  /// Reports whether every folder is open, so the toolbar can offer a single
  /// button that is either "全部展开" or "全部收起" — never both at once.
  final ValueChanged<bool>? onAllExpandedChanged;

  @override
  State<VaultTree> createState() => VaultTreeState();
}

class VaultTreeState extends State<VaultTree> {
  final Set<String> _expanded = <String>{};

  /// 选中的笔记（id）。
  final Set<String> _selected = <String>{};

  /// 选中的白板（相对路径）。
  ///
  /// 和笔记分开存，是因为「多选之后按删除」两边走的是两套确认卡片和两套
  /// 恢复：笔记要重建正文，白板要搬文件。混在一个集合里，每个用到的地方
  /// 都得先问一句「这个 key 是哪种文件」。高亮和 Shift 连选是共用一套。
  final Set<String> _selectedBoards = <String>{};

  /// Shift 连选的锚点：笔记 id，或者白板相对路径，两者互斥。
  String? _anchorId;
  String? _anchorBoardPath;

  bool _seeded = false;
  String? _lastSelectedId;

  /// F2 renames the row the user last clicked, which is the *end* of a
  /// Shift+click range rather than its anchor. Keeping that apart from
  /// [_anchorId] means the two actions never disagree about the target.
  String? _focusNoteId;
  String? _focusFolderPath;

  /// The row that is currently an inline text field, if any.
  String? _renamingNoteId;
  String? _renamingFolderPath;

  /// The folder row a drag is currently hovering, if any.
  ///
  /// The vault-root drop area needs this: a drop that lands on a folder belongs
  /// to that folder, and the empty space underneath must not take it instead.
  String? _hoverFolder;

  /// True while the drag is inside the vault root drop area, which has no row of
  /// its own to hover.
  bool _overRoot = false;

  /// Where the in-flight drag would land: a folder path, `''` for the vault
  /// root, or null while the pointer is over nothing that would take the drop.
  ///
  /// The floating drag preview lives in the overlay, out of reach of the tree's
  /// rebuilds, so it is told about every zone change through this notifier.
  final ValueNotifier<String?> _dropTarget = ValueNotifier<String?>(null);

  final FocusNode _treeFocus = FocusNode(debugLabel: 'vault-tree');
  final TextEditingController _rename = TextEditingController();
  final FocusNode _renameFocus = FocusNode(debugLabel: 'vault-rename');

  @override
  void initState() {
    super.initState();
    _seedIfReady();
    _lastSelectedId = widget.notes.selectedId;
    if (_lastSelectedId != null) {
      _selected.add(_lastSelectedId!);
      _anchorId = _lastSelectedId;
    }
    // Clicking anywhere else commits the rename, the way a file manager does.
    _renameFocus.addListener(_onRenameFocusChanged);
  }

  @override
  void dispose() {
    _renameFocus.removeListener(_onRenameFocusChanged);
    _rename.dispose();
    _renameFocus.dispose();
    _treeFocus.dispose();
    _dropTarget.dispose();
    super.dispose();
  }

  /// Publishes the zone the drag is over, for the floating preview to name.
  void _publishDropTarget() {
    _dropTarget.value = _hoverFolder ?? (_overRoot ? '' : null);
  }

  void _seedIfReady() {
    final NotesController notes = widget.notes;
    if (_seeded ||
        notes.isLoading ||
        (notes.folders.isEmpty && notes.allNotes.isEmpty)) {
      return;
    }
    // 启动时一个都不展开。八百多篇的库把每个文件夹都摊开，第一屏是一堵
    // 墙，而用户接下来要做的第一件事通常是「找到某一篇」，不是「看全部」。
    // 展开状态也不持久化：每次打开都从折叠开始，位置是可预期的。
    _seeded = true;
  }

  @override
  void didUpdateWidget(covariant VaultTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    final NotesController notes = widget.notes;
    _seedIfReady();

    final Set<String> existing = <String>{
      for (final Note n in notes.allNotes) n.id,
    };
    _selected.removeWhere((String id) => !existing.contains(id));
    final Set<String> boards = <String>{
      for (final CanvasRef b in widget.canvases) b.relativePath,
    };
    _selectedBoards.removeWhere((String path) => !boards.contains(path));

    final String? selected = notes.selectedId;
    if (selected != null &&
        selected != _lastSelectedId &&
        !_selected.contains(selected)) {
      _selected
        ..clear()
        ..add(selected);
      // 正文换了，说明用户是从别处打开了一篇笔记：白板那半边的高亮就不该
      // 继续挂着，否则屏幕上同时亮着两行，没人知道删除会删哪个。
      _selectedBoards.clear();
      _anchorId = selected;
      _anchorBoardPath = null;
    }
    if (_selected.isEmpty && _selectedBoards.isEmpty && selected != null) {
      _selected.add(selected);
      _anchorId ??= selected;
    }

    if (selected != null && selected != _lastSelectedId) {
      final Note? note = notes.selectedNote;
      if (note != null && note.folderPath.isNotEmpty) {
        _expandAncestors(note.folderPath);
      }
    }
    _lastSelectedId = selected;
  }

  /// Whether every folder in the vault is open right now. Drives the single
  /// expand/collapse button in the toolbar.
  bool get allExpanded {
    final List<String> folders = widget.notes.folders;
    return folders.every(_expanded.contains);
  }

  void _notifyExpansion() => widget.onAllExpandedChanged?.call(allExpanded);

  void expandAll() {
    setState(() {
      _expanded
        ..clear()
        ..addAll(widget.notes.folders);
      _seeded = true;
    });
    _notifyExpansion();
  }

  void collapseAll() {
    setState(() {
      _expanded.clear();
      _seeded = true;
      _pruneToVisible();
    });
    _notifyExpansion();
  }

  /// Opens [folderPath] and every folder above it. Used after creating a folder
  /// or a note, and whenever the selection jumps to a folded-away note.
  void revealFolder(String folderPath) {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return;
    setState(() => _expandAncestors(folder));
    _notifyExpansion();
  }

  void _expandAncestors(String folderPath) {
    String current = '';
    for (final String part in folderPath.split('/')) {
      if (part.isEmpty) continue;
      current = current.isEmpty ? part : '$current/$part';
      _expanded.add(current);
    }
  }

  List<Note> _visibleFiles() {
    return _rows(widget.notes)
        .map((_TreeRow row) => row.entry?.note)
        .whereType<Note>()
        .toList(growable: false);
  }

  /// 屏幕上能点选的行，按从上到下的顺序：笔记和白板，图片不算。
  ///
  /// Shift 连选要的是「这一行和那一行之间」，所以必须和渲染用的是同一份
  /// 顺序（[build] 里的 `rows`），不能各自排一遍。
  List<({Note? note, CanvasRef? board})> _selectableRows() {
    final List<({Note? note, CanvasRef? board})> out =
        <({Note? note, CanvasRef? board})>[];
    for (final _TreeRow row in _rows(widget.notes)) {
      final _FileEntry? entry = row.entry;
      if (entry == null) continue;
      if (entry.note != null) {
        out.add((note: entry.note, board: null));
      } else if (entry.canvas != null) {
        out.add((note: null, board: entry.canvas));
      }
    }
    return out;
  }

  List<CanvasRef> _visibleBoards() {
    return _rows(widget.notes)
        .map((_TreeRow row) => row.entry?.canvas)
        .whereType<CanvasRef>()
        .toList(growable: false);
  }

  /// 锚点落在第几行；锚点被折叠或删掉了就是 -1。
  int _anchorIndex(List<({Note? note, CanvasRef? board})> rows) {
    final String? id = _anchorId;
    if (id != null) {
      final int i = rows.indexWhere(
        (({Note? note, CanvasRef? board}) r) => r.note?.id == id,
      );
      if (i >= 0) return i;
    }
    final String? path = _anchorBoardPath;
    if (path == null) return -1;
    return rows.indexWhere(
      (({Note? note, CanvasRef? board}) r) => r.board?.relativePath == path,
    );
  }

  /// Keeps only files that are actually on screen, so a collapsed folder cannot
  /// leave a hidden note in a bulk delete.
  void _pruneToVisible() {
    final Set<String> visible = <String>{
      for (final Note n in _visibleFiles()) n.id,
    };
    _selected.removeWhere((String id) => !visible.contains(id));
    final Set<String> boards = <String>{
      for (final CanvasRef b in _visibleBoards()) b.relativePath,
    };
    _selectedBoards.removeWhere((String path) => !boards.contains(path));
  }

  void _selectOnly(Note note) {
    setState(() {
      _selected
        ..clear()
        ..add(note.id);
      _selectedBoards.clear();
      _anchorId = note.id;
      _anchorBoardPath = null;
    });
  }

  void _selectOnlyBoard(CanvasRef board) {
    setState(() {
      _selected.clear();
      _selectedBoards
        ..clear()
        ..add(board.relativePath);
      _anchorId = null;
      _anchorBoardPath = board.relativePath;
    });
  }

  /// Shift 连选：从锚点到 [note] / [board] 之间，屏幕上看得见的每一行都选中。
  ///
  /// 跨类型也照选：一段里既有笔记又有白板时，两边各自记各自的，右键哪一类
  /// 就只对哪一类生效。
  void _selectRangeTo({Note? note, CanvasRef? board}) {
    final List<({Note? note, CanvasRef? board})> rows = _selectableRows();
    final int anchor = _anchorIndex(rows);
    final int index = rows.indexWhere(
      (({Note? note, CanvasRef? board}) r) => note != null
          ? r.note?.id == note.id
          : r.board?.relativePath == board?.relativePath,
    );
    if (anchor < 0 || index < 0) {
      // 锚点不见了（文件夹被折叠、那篇笔记被删）：退化成单选，别让整段
      // 高亮凭空消失。
      if (note != null) {
        _selectOnly(note);
      } else if (board != null) {
        _selectOnlyBoard(board);
      }
      return;
    }
    final int start = math.min(anchor, index);
    final int end = math.max(anchor, index);
    final List<({Note? note, CanvasRef? board})> range = rows.sublist(
      start,
      end + 1,
    );
    setState(() {
      _selected
        ..clear()
        ..addAll(
          range
              .map((({Note? note, CanvasRef? board}) r) => r.note?.id)
              .whereType<String>(),
        );
      _selectedBoards
        ..clear()
        ..addAll(
          range
              .map(
                (({Note? note, CanvasRef? board}) r) => r.board?.relativePath,
              )
              .whereType<String>(),
        );
    });
  }

  /// A plain click opens the note. Shift+click extends the selection from the
  /// anchor instead — it changes *what a delete would take*, so it deliberately
  /// leaves the editor where it was rather than swapping the document out from
  /// under someone who is still picking the end of the range.
  ///
  /// 白板走同一条路：点一下选中并打开，Shift+click 只改选中范围。区别只在
  /// 打开的是白板视图而不是正文。
  void _tapRow({Note? note, CanvasRef? board}) {
    _treeFocus.requestFocus();
    if (note != null) {
      widget.notes.setActiveFolder(note.folderPath);
      _focusNoteId = note.id;
      _focusFolderPath = null;
    } else {
      _focusNoteId = null;
      _focusFolderPath = null;
    }
    if (HardwareKeyboard.instance.isShiftPressed &&
        _anchorIndex(_selectableRows()) >= 0) {
      _selectRangeTo(note: note, board: board);
      return;
    }
    if (note != null) {
      _selectOnly(note);
      widget.onOpenNote(note);
      return;
    }
    _selectOnlyBoard(board!);
    widget.onOpenCanvas?.call(board);
  }

  Future<void> _showFileMenu(Note note, Offset position) async {
    _treeFocus.requestFocus();
    _focusNoteId = note.id;
    _focusFolderPath = null;
    if (!_selected.contains(note.id)) {
      _selectOnly(note);
    }
    final Set<String> ids = <String>{..._selected};
    ids.add(note.id);
    final Set<String> visible = <String>{
      for (final Note n in _visibleFiles()) n.id,
    };
    final List<Note> targets = _visibleFiles()
        .where((Note n) => ids.contains(n.id) && visible.contains(n.id))
        .toList(growable: false);
    // What the menu acts on: the whole visible selection, or just the row that
    // was right-clicked when nothing else is selected.
    final List<Note> affected = targets.isEmpty ? <Note>[note] : targets;
    final String deleteLabel = affected.length > 1
        ? '删除 ${affected.length} 篇笔记'
        : '删除笔记';

    // The same panel the editor opens on a right-click — one menu design for the
    // whole app, not a `PopupMenu` here and a hand-built one there.
    await showAppMenu(
      context,
      globalPosition: position,
      entries: <MenuNode>[
        MenuAction(
          label: '打开',
          icon: LucideIcons.externalLink,
          onPressed: () {
            widget.notes.setActiveFolder(note.folderPath);
            widget.onOpenNote(note);
          },
        ),
        const MenuSeparator(),
        MenuAction(
          label: '重命名',
          icon: LucideIcons.filePen,
          shortcut: 'F2',
          onPressed: () => _startRenameNote(note),
        ),
        MenuAction(
          label: '移到文件夹…',
          icon: LucideIcons.folderInput,
          onPressed: () => unawaited(_pickFolder(affected)),
        ),
        if (widget.notes.supportsHistory && affected.length == 1)
          MenuAction(
            label: '历史版本…',
            icon: LucideIcons.history,
            onPressed: () => showVersionHistoryDialog(context, note),
          ),
        const MenuSeparator(),
        MenuAction(
          label: deleteLabel,
          icon: LucideIcons.trash2,
          danger: true,
          onPressed: () => widget.onDeleteNotes(affected),
        ),
      ],
    );
  }

  Future<void> _showFolderMenu(
    String folder,
    String name,
    Offset position,
  ) async {
    _treeFocus.requestFocus();
    _focusFolderPath = folder;
    _focusNoteId = null;
    await showAppMenu(
      context,
      globalPosition: position,
      entries: <MenuNode>[
        MenuAction(
          label: '重命名',
          icon: LucideIcons.filePen,
          shortcut: 'F2',
          onPressed: () => _startRenameFolder(folder, name),
        ),
        const MenuSeparator(),
        MenuAction(
          label: '删除文件夹',
          icon: LucideIcons.trash2,
          danger: true,
          onPressed: () => unawaited(_deleteFolder(folder)),
        ),
      ],
    );
  }

  /// Runs the folder delete and forgets local tree state only after something
  /// actually moved. A refusal — a file the trash cannot hold — leaves the
  /// expansion and focus exactly where they were.
  Future<void> _deleteFolder(String folder) async {
    final bool changed = await widget.onDeleteFolder(folder);
    if (!mounted || !changed) return;
    setState(() {
      _expanded.removeWhere(
        (String path) => path == folder || path.startsWith('$folder/'),
      );
      final String? focus = _focusFolderPath;
      if (focus == folder || (focus?.startsWith('$folder/') ?? false)) {
        _focusFolderPath = null;
      }
      _pruneToVisible();
    });
    _notifyExpansion();
  }

  // ------------------------------------------------------------------ rename

  void _startRenameNote(Note note) =>
      _beginRename(noteId: note.id, current: note.title);

  void _startRenameFolder(String folder, String name) =>
      _beginRename(folderPath: folder, current: name);

  void _beginRename({
    String? noteId,
    String? folderPath,
    required String current,
  }) {
    setState(() {
      _renamingNoteId = noteId;
      _renamingFolderPath = folderPath;
      _rename.text = current;
      _rename.selection = TextSelection(
        baseOffset: 0,
        extentOffset: current.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _renameFocus.requestFocus();
    });
  }

  void _onRenameFocusChanged() {
    if (!_renameFocus.hasFocus) _finishRename();
  }

  /// Writes the inline rename. An unchanged name simply closes the field, so
  /// pressing F2 by accident and leaving again costs nothing.
  void _finishRename() {
    final String? noteId = _renamingNoteId;
    final String? folder = _renamingFolderPath;
    if (noteId == null && folder == null) return;
    final String value = _rename.text;
    setState(() {
      _renamingNoteId = null;
      _renamingFolderPath = null;
    });
    if (folder != null) {
      unawaited(_renameFolderPath(folder, value));
      return;
    }
    final Note? note = _noteById(noteId!);
    if (note != null) unawaited(widget.notes.renameNote(note, value));
  }

  /// Esc closes the field without writing anything.
  void _cancelRename() {
    final bool wasRenaming =
        _renamingNoteId != null || _renamingFolderPath != null;
    if (!wasRenaming) return;
    setState(() {
      _renamingNoteId = null;
      _renamingFolderPath = null;
    });
    _rename.clear();
  }

  Future<void> _renameFolderPath(String folder, String name) async {
    final String? to = await widget.notes.renameFolder(folder, name);
    if (to == null || !mounted) return;
    // An open folder must not close itself just because it was renamed, so the
    // expansion moves with the name.
    setState(() {
      final List<String> moved = _expanded
          .where((String p) => p == folder || p.startsWith('$folder/'))
          .toList(growable: false);
      for (final String p in moved) {
        _expanded
          ..remove(p)
          ..add('$to${p.substring(folder.length)}');
      }
    });
  }

  KeyEventResult _onTreeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f2) {
      return KeyEventResult.ignored;
    }
    final String? folder = _focusFolderPath;
    if (folder != null) {
      _startRenameFolder(folder, folder.split('/').last);
      return KeyEventResult.handled;
    }
    final String? id = _focusNoteId;
    final Note? note = id == null ? null : _noteById(id);
    if (note == null) return KeyEventResult.ignored;
    _startRenameNote(note);
    return KeyEventResult.handled;
  }

  Note? _noteById(String id) {
    for (final Note n in widget.notes.allNotes) {
      if (n.id == id) return n;
    }
    return null;
  }

  Widget _renameField() {
    final AppPalette p = context.palette;
    return Focus(
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _cancelRename();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: TextField(
        controller: _rename,
        focusNode: _renameFocus,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (String _) => _finishRename(),
        cursorColor: p.accent,
        cursorWidth: 1.3,
        style: TextStyle(
          fontSize: AppText.ui,
          height: 1.2,
          color: p.textPrimary,
        ),
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: '名称',
          hintStyle: TextStyle(fontSize: AppText.ui, color: p.textTertiary),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------- move

  /// The notes a drag carries: the whole visible selection, which
  /// [onDragStarted] guarantees contains the row that was picked up.
  List<Note> _dragTargets() {
    final Set<String> visible = <String>{
      for (final Note n in _visibleFiles()) n.id,
    };
    return _visibleFiles()
        .where((Note n) => _selected.contains(n.id) && visible.contains(n.id))
        .toList(growable: false);
  }

  void _beginDrag(Note note) {
    _hoverFolder = null;
    if (!_selected.contains(note.id)) _selectOnly(note);
  }

  /// Whether a drop on [folder] would actually change something. A drop that
  /// changes nothing is still *taken* by the folder row (so it cannot fall
  /// through to the root), it just does nothing once it lands.
  bool _canDrop(VaultDragPayload payload, String folder) {
    final String? moving = payload.folder;
    if (moving != null) {
      // A folder cannot go inside itself or its own sub-folder — that would
      // detach the whole branch from the vault.
      if (folder == moving || folder.startsWith('$moving/')) return false;
      return _parentOf(moving) != folder;
    }
    return _dragTargets().any((Note n) => n.folderPath != folder);
  }

  Future<void> _dropPayload(VaultDragPayload payload, String folder) async {
    if (!_canDrop(payload, folder)) return;
    final String? moving = payload.folder;
    if (moving != null) {
      await widget.notes.moveFolder(moving, folder);
      return;
    }
    await _moveSelectionInto(folder);
  }

  static String _parentOf(String folder) =>
      folder.contains('/') ? folder.substring(0, folder.lastIndexOf('/')) : '';

  Future<void> _moveSelectionInto(String folder) async {
    final List<Note> targets = _dragTargets();
    if (targets.isEmpty) return;
    await widget.notes.moveNotes(targets, folder);
  }

  /// The keyboard path to the same move the drag does: pick a folder from a
  /// flat, indented list.
  Future<void> _pickFolder(List<Note> targets) async {
    final AppPalette p = context.palette;
    final List<String> folders = widget.notes.folders;
    final double height = (40 + folders.length * AppLayout.rowHeight)
        .clamp(56, 300)
        .toDouble();
    final String? folder = await showDialog<String>(
      context: context,
      barrierColor: p.overlay,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: p.surfaceRaised,
        title: Text(
          targets.length > 1 ? '把 ${targets.length} 篇笔记移到' : '把这篇笔记移到',
          style: TextStyle(
            fontSize: AppText.title,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        content: SizedBox(
          width: 330,
          height: height,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            children: <Widget>[
              _folderOption(p, '', '根目录', 0),
              for (final String path in folders)
                _folderOption(
                  p,
                  path,
                  path.split('/').last,
                  path.split('/').length - 1,
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (!mounted || folder == null) return;
    await widget.notes.moveNotes(targets, folder);
  }

  Widget _folderOption(AppPalette p, String path, String label, int depth) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(path),
      child: SizedBox(
        height: AppLayout.rowHeight + 4,
        child: Padding(
          padding: EdgeInsets.only(
            left: AppSpace.sm + depth * AppLayout.rowIndent,
            right: AppSpace.sm,
          ),
          child: Row(
            children: <Widget>[
              if (path.isNotEmpty)
                Icon(
                  LucideIcons.cornerDownRight,
                  size: AppIconSize.xs,
                  color: p.textTertiary,
                ),
              if (path.isNotEmpty) const SizedBox(width: AppSpace.xs + 2),
              Text(
                label,
                style: TextStyle(fontSize: AppText.ui, color: p.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_TreeRow> _rows(NotesController notes) {
    // 一次遍历建好两张表，替代原先「每个展开的目录都重扫一遍全库」：
    // 深树 + 大库时，旧写法的开销随目录数放大，而文件树在每次输入时都会重建。
    final Map<String, Set<String>> childFolders = <String, Set<String>>{};
    for (final String path in notes.folders) {
      String parent = '';
      for (final String part in path.split('/')) {
        if (part.isEmpty) continue;
        final String child = parent.isEmpty ? part : '$parent/$part';
        childFolders.putIfAbsent(parent, () => <String>{}).add(child);
        parent = child;
      }
    }

    // 三种文件放在同一张表里：同一层里它们要按同一套规则排序，分成三张
    // 表再拼起来，就只能「笔记全在前、白板全在后」，看着像两个列表。
    final Map<String, List<_FileEntry>> filesByFolder =
        <String, List<_FileEntry>>{};
    for (final Note note in notes.allNotes) {
      filesByFolder
          .putIfAbsent(note.folderPath, () => <_FileEntry>[])
          .add(_FileEntry.note(note));
    }
    for (final CanvasRef board in widget.canvases) {
      filesByFolder
          .putIfAbsent(board.folderPath, () => <_FileEntry>[])
          .add(_FileEntry.canvas(board));
    }
    for (final VaultFile file in widget.files) {
      filesByFolder
          .putIfAbsent(file.folderPath, () => <_FileEntry>[])
          .add(_FileEntry.asset(file));
    }
    // `allNotes` 已经按当前排序排好，所以只有掺进别的文件的那一组才需要
    // 重排。多数文件夹里没有白板和图片，这一步直接跳过。
    for (final List<_FileEntry> entries in filesByFolder.values) {
      if (!entries.any((_FileEntry e) => e.note == null)) continue;
      entries.sort(
        (_FileEntry a, _FileEntry b) => _compareEntries(a, b, notes.sortMode),
      );
    }

    List<String> childrenOf(String parent) {
      final Set<String>? children = childFolders[parent];
      if (children == null) return const <String>[];
      return children.toList()..sort(
        (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
      );
    }

    final List<_TreeRow> rows = <_TreeRow>[];
    void walk(String parent, int depth) {
      for (final String folder in childrenOf(parent)) {
        rows.add(_TreeRow.folder(folder, folder.split('/').last, depth));
        if (!_expanded.contains(folder)) continue;
        walk(folder, depth + 1);
      }
      for (final _FileEntry entry
          in filesByFolder[parent] ?? const <_FileEntry>[]) {
        rows.add(_TreeRow.file(entry, depth));
      }
    }

    walk('', 0);
    return rows;
  }

  /// 和 [NotesController] 的排序保持同一套规则，否则白板插进笔记中间时会
  /// 落在一个说不通的位置。白板没有创建时间，用修改时间顶上；图片两个都
  /// 没有，就固定排在后面。
  static int _compareEntries(_FileEntry a, _FileEntry b, SortMode mode) {
    final int primary = switch (mode) {
      SortMode.titleAsc => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      SortMode.titleDesc => b.title.toLowerCase().compareTo(
        a.title.toLowerCase(),
      ),
      SortMode.updatedDesc => _byDate(b.modified, a.modified),
      SortMode.updatedAsc => _byDate(a.modified, b.modified),
      SortMode.createdDesc => _byDate(b.created, a.created),
      SortMode.createdAsc => _byDate(a.created, b.created),
    };
    if (primary != 0) return primary;
    return a.path.toLowerCase().compareTo(b.path.toLowerCase());
  }

  /// 没有时间的那一方永远排在后面，不管正序倒序。
  static int _byDate(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  @override
  Widget build(BuildContext context) {
    final NotesController notes = widget.notes;
    if (notes.allNotes.isEmpty &&
        notes.folders.isEmpty &&
        widget.canvases.isEmpty &&
        widget.files.isEmpty) {
      return const EmptyState(
        compact: true,
        icon: LucideIcons.notebookPen,
        title: '笔记库还是空的',
        message: '写下第一个念头 —— 它会立刻变成一个可以被任何编辑器打开的 .md 文件。',
      );
    }

    final List<_TreeRow> rows = _rows(notes);
    return Focus(
      focusNode: _treeFocus,
      onKeyEvent: _onTreeKey,
      // Everything that is not a folder row is the vault root, so dragging a
      // note out of a folder and letting go below is how it goes back to the
      // top level. A folder row claims its own drops (see [_folderRow]), which
      // is what keeps a drop on a folder from landing here instead.
      child: DragTarget<VaultDragPayload>(
        onWillAcceptWithDetails: (DragTargetDetails<VaultDragPayload> d) {
          final bool accepted =
              _hoverFolder == null && d.data.tree._canDrop(d.data, '');
          if (accepted) {
            _overRoot = true;
            _publishDropTarget();
          }
          return accepted;
        },
        onLeave: (VaultDragPayload? _) {
          _overRoot = false;
          _publishDropTarget();
        },
        onAcceptWithDetails: (DragTargetDetails<VaultDragPayload> d) =>
            d.data.tree._dropPayload(d.data, ''),
        builder:
            (
              BuildContext context,
              List<VaultDragPayload?> candidate,
              List<dynamic> rejected,
            ) => ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xs,
                AppSpace.xs,
                AppSpace.xs,
                AppSpace.xl,
              ),
              itemCount: rows.length,
              itemBuilder: (BuildContext context, int i) {
                final _TreeRow row = rows[i];
                final _FileEntry? entry = row.entry;
                if (entry != null) return _fileRow(row, entry, notes);
                return _folderRow(row, notes);
              },
            ),
      ),
    );
  }

  Widget _fileRow(_TreeRow row, _FileEntry entry, NotesController notes) {
    final Note? note = entry.note;
    if (note == null) return _plainFileRow(row, entry);

    final bool renaming = _renamingNoteId == note.id;
    final Widget content = _FileRow(
      title: note.title.trim().isEmpty ? '未命名' : note.title.trim(),
      tooltip: note.relativePath,
      depth: row.depth,
      selected: _selected.contains(note.id),
      active: note.id == notes.selectedId,
      badge: entry.badge,
      trailing: _TaskBadge(noteId: note.id),
      renameField: renaming ? _renameField() : null,
      onTap: () => _tapRow(note: note),
      onSecondaryTapDown: (TapDownDetails d) =>
          _showFileMenu(note, d.globalPosition),
    );
    // Renaming wins over dragging: a text field full of selected characters
    // must drag like text, not like a file.
    if (renaming) return content;
    final VaultDragPayload payload = VaultDragPayload.notes(this);
    return Draggable<VaultDragPayload>(
      data: payload,
      onDragStarted: () => _beginDrag(note),
      // The canvas needs the pointer, not the feedback chip's corner: it puts
      // the new card where the user let go.
      onDragUpdate: (DragUpdateDetails d) => payload.pointer = d.globalPosition,
      // The preview names the row and, live, the folder it would land in; the
      // row itself fades while the drag is in flight.
      feedback: _dragPreview(label: () => _dragLabel(note)),
      childWhenDragging: Opacity(opacity: 0.4, child: content),
      child: content,
    );
  }

  /// 白板行：能点选、能打开，右键能删。
  ///
  /// 选中和 Shift 连选与笔记完全一致（同一套高亮、同一份行顺序），但多选
  /// 之后按删除时各走各的确认卡片：笔记那套会重建正文，白板那套搬文件。
  Widget _plainFileRow(_TreeRow row, _FileEntry entry) {
    final CanvasRef? board = entry.canvas;
    return _FileRow(
      title: entry.title,
      tooltip: entry.path,
      depth: row.depth,
      selected: board != null && _selectedBoards.contains(board.relativePath),
      active: board != null && board.relativePath == widget.activeCanvasPath,
      icon: board != null
          ? LucideIcons.layoutDashboard
          : _iconFor(entry.extension),
      badge: entry.badge,
      onTap: () {
        if (board != null) {
          _tapRow(board: board);
        } else if (entry.file != null) {
          widget.onOpenFile?.call(entry.file!);
        }
      },
      onSecondaryTapDown: board == null
          ? null
          : (TapDownDetails d) => _showCanvasMenu(board, d.globalPosition),
    );
  }

  /// 右键一块白板：打开，或者删掉。
  ///
  /// 菜单和笔记行是同一块面板（[showAppMenu]），只是条目更少——白板没有
  /// 标签、没有大纲、没有版本历史，能对它做的事本来就只有这两件。选中的
  /// 白板有好几块时，「删除」作用于整段选中，和笔记那边一个口径。
  Future<void> _showCanvasMenu(CanvasRef board, Offset position) async {
    _treeFocus.requestFocus();
    _focusNoteId = null;
    _focusFolderPath = null;
    if (!_selectedBoards.contains(board.relativePath)) _selectOnlyBoard(board);
    final Set<String> visible = <String>{
      for (final CanvasRef b in _visibleBoards()) b.relativePath,
    };
    final List<CanvasRef> affected = _visibleBoards()
        .where(
          (CanvasRef b) =>
              _selectedBoards.contains(b.relativePath) &&
              visible.contains(b.relativePath),
        )
        .toList(growable: false);
    final List<CanvasRef> targets = affected.isEmpty
        ? <CanvasRef>[board]
        : affected;
    final String deleteLabel = targets.length > 1
        ? '删除 ${targets.length} 块白板'
        : '删除白板';
    await showAppMenu(
      context,
      globalPosition: position,
      entries: <MenuNode>[
        MenuAction(
          label: '打开',
          icon: LucideIcons.externalLink,
          onPressed: () => widget.onOpenCanvas?.call(board),
        ),
        const MenuSeparator(),
        MenuAction(
          label: deleteLabel,
          icon: LucideIcons.trash2,
          danger: true,
          onPressed: () => widget.onDeleteCanvas?.call(targets),
        ),
      ],
    );
  }

  static IconData _iconFor(String extension) {
    final String ext = extension.toLowerCase();
    // 清单在 `core/utils/image_file.dart`：外壳判断「点了是开图片页还是交给
    // 系统」用的是同一份，两边不会一个画图片图标、一个弹系统看图程序。
    if (kImageExtensions.contains(ext)) return LucideIcons.image;
    if (ext == 'pdf') return LucideIcons.fileText;
    return LucideIcons.file;
  }

  Widget _folderRow(_TreeRow row, NotesController notes) {
    final String folder = row.folderPath!;
    final bool expanded = _expanded.contains(folder);
    final bool renaming = _renamingFolderPath == folder;

    Widget build({required bool hot}) => _FolderRow(
      name: row.name,
      depth: row.depth,
      expanded: expanded,
      dropTarget: hot,
      renameField: renaming ? _renameField() : null,
      onTap: () {
        _treeFocus.requestFocus();
        _focusFolderPath = folder;
        _focusNoteId = null;
        notes.setActiveFolder(folder);
        setState(() {
          if (expanded) {
            _expanded.remove(folder);
            _pruneToVisible();
          } else {
            _expanded.add(folder);
          }
          _seeded = true;
        });
        _notifyExpansion();
      },
      onSecondaryTapDown: (TapDownDetails d) =>
          _showFolderMenu(folder, row.name, d.globalPosition),
    );

    if (renaming) return build(hot: false);
    return DragTarget<VaultDragPayload>(
      // Accepts every drop, even one that would change nothing: holding on to
      // the drop is what stops it falling through to the vault root below.
      onWillAcceptWithDetails: (DragTargetDetails<VaultDragPayload> d) {
        _hoverFolder = folder;
        _publishDropTarget();
        return true;
      },
      onLeave: (VaultDragPayload? _) {
        if (_hoverFolder == folder) {
          _hoverFolder = null;
          _publishDropTarget();
        }
      },
      onAcceptWithDetails: (DragTargetDetails<VaultDragPayload> d) =>
          d.data.tree._dropPayload(d.data, folder),
      builder:
          (
            BuildContext context,
            List<VaultDragPayload?> candidate,
            List<dynamic> rejected,
          ) {
            final VaultDragPayload? hovering = candidate.isEmpty
                ? null
                : candidate.first;
            return Draggable<VaultDragPayload>(
              data: VaultDragPayload.folder(this, folder),
              feedback: _dragPreview(label: () => row.name),
              childWhenDragging: Opacity(
                opacity: 0.4,
                child: build(hot: false),
              ),
              child: build(hot: hovering != null && _canDrop(hovering, folder)),
            );
          },
    );
  }

  /// What the preview calls the row being dragged: its own title, or how many
  /// notes are coming along when a whole selection is on the move.
  String _dragLabel(Note note) {
    final int count = _dragTargets().length;
    if (count > 1) return '$count 篇笔记';
    return note.title.trim().isEmpty ? note.fileName : note.title.trim();
  }

  /// The card that follows the pointer while a row is in flight: the row on the
  /// first line, the folder it would land in on the second.
  ///
  /// [label] is a callback rather than a string because the drag can change the
  /// selection as it starts, and the destination is read from [_dropTarget] —
  /// both have to be re-read whenever this builder runs, not frozen at the
  /// moment the drag began.
  Widget _dragPreview({required String Function() label}) {
    return ValueListenableBuilder<String?>(
      valueListenable: _dropTarget,
      builder: (BuildContext context, String? target, Widget? child) {
        final AppPalette p = context.palette;
        return Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 240),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              color: p.surfaceRaised,
              borderRadius: AppRadius.smAll,
              border: Border.all(color: p.outline),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: p.shadow,
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.ui,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
                if (target != null) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    target.isEmpty ? '移到根目录' : '移动到「${target.split('/').last}」',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      height: 1.25,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// What a row is dragged as: either the note selection, or one whole folder.
///
/// It carries the tree rather than a `List<Note>` because [Draggable.data] is
/// evaluated when the drag begins — *before* `onDragStarted` folds the picked-up
/// row into the selection — and a drop must move what is selected at the moment
/// of the drop, not what happened to be selected before it.
///
/// The whiteboard is the second drop target: it reads [notePaths] to reference
/// the notes, and [pointer] for where the card lands. [DragTargetDetails.offset]
/// is the *feedback chip's* top-left (`pointer - dragStartPoint`), not the
/// pointer, so each `Draggable` keeps this field up to date in `onDragUpdate`.
class VaultDragPayload {
  VaultDragPayload.notes(this.tree) : folder = null;

  VaultDragPayload.folder(this.tree, String this.folder);

  final VaultTreeState tree;

  /// The folder being moved, or null when the drag carries the note selection.
  final String? folder;

  /// Global pointer position of the drag's latest update.
  Offset? pointer;

  /// The notes this drag would move / reference right now.
  List<String> notePaths() {
    if (folder != null) return const <String>[];
    return <String>[
      for (final Note note in tree._dragTargets()) note.relativePath,
    ];
  }
}

class _TreeRow {
  const _TreeRow._({
    required this.depth,
    this.folderPath,
    this.name = '',
    this.entry,
  });

  factory _TreeRow.folder(String path, String name, int depth) =>
      _TreeRow._(depth: depth, folderPath: path, name: name);

  factory _TreeRow.file(_FileEntry entry, int depth) =>
      _TreeRow._(depth: depth, entry: entry);

  final int depth;
  final String? folderPath;
  final String name;
  final _FileEntry? entry;
}

/// 文件树里的一行文件：笔记、白板，或者别的什么（图片、附件）。
///
/// 三者共用一套排序键，才能在同一层里混排——分成三种行、三套顺序拼起来，
/// 结果就是「笔记在前、白板在后」，看着像两个列表而不是一个文件夹。
class _FileEntry {
  _FileEntry.note(Note note)
    : this._(
        note: note,
        title: note.title,
        extension: 'md',
        modified: note.updatedAt,
        created: note.createdAt,
        path: note.relativePath,
      );

  _FileEntry.canvas(CanvasRef board)
    : this._(
        canvas: board,
        title: board.title,
        extension: 'nrs',
        modified: board.modified,
        created: board.modified,
        path: board.relativePath,
      );

  _FileEntry.asset(VaultFile file)
    : this._(
        file: file,
        title: file.title,
        extension: file.extension,
        modified: null,
        created: null,
        path: file.relativePath,
      );

  const _FileEntry._({
    required this.title,
    required this.extension,
    required this.modified,
    required this.created,
    required this.path,
    this.note,
    this.canvas,
    this.file,
  });

  final Note? note;
  final CanvasRef? canvas;
  final VaultFile? file;

  final String title;
  final String extension;
  final DateTime? modified;
  final DateTime? created;
  final String path;

  /// 行尾那个后缀。
  ///
  /// `.md` 是空串：笔记是这个库的默认格式，每行都挂一个 MD 只是噪音。
  /// 白板、图片、附件才是需要一眼认出来的东西——和 Obsidian 一致。
  String get badge =>
      extension.toLowerCase() == 'md' ? '' : extension.toUpperCase();
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.name,
    required this.depth,
    required this.expanded,
    required this.dropTarget,
    required this.onTap,
    required this.onSecondaryTapDown,
    this.renameField,
  });

  final String name;
  final int depth;
  final bool expanded;

  /// True while a dragged note is hovering this row.
  final bool dropTarget;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;

  /// Replaces the label while the folder is being renamed in place.
  final Widget? renameField;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) => GestureDetector(
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: AppLayout.rowHeight,
          decoration: BoxDecoration(
            color: dropTarget
                ? p.accentSoft
                : (hovered ? p.surfaceRaised : Colors.transparent),
            borderRadius: AppRadius.smAll,
          ),
          child: Row(
            children: <Widget>[
              _IndentGuides(depth: depth),
              const SizedBox(width: AppSpace.xs),
              SizedBox(
                width: 16,
                child: Icon(
                  expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                  size: AppIconSize.sm,
                  color: p.textTertiary,
                ),
              ),
              Expanded(
                child:
                    renameField ??
                    Tooltip(
                      message: name,
                      waitDuration: const Duration(milliseconds: 600),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppText.ui,
                          height: 1.2,
                          fontWeight: FontWeight.w500,
                          color: dropTarget
                              ? p.accent
                              : (hovered ? p.textPrimary : p.textSecondary),
                        ),
                      ),
                    ),
              ),
              const SizedBox(width: AppSpace.xs),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.title,
    required this.tooltip,
    required this.depth,
    required this.selected,
    required this.active,
    required this.onTap,
    this.icon,
    this.badge = '',
    this.trailing,
    this.onSecondaryTapDown,
    this.renameField,
  });

  final String title;

  /// 悬停时给出的完整路径：标题可能被截断，路径不会。
  final String tooltip;

  final int depth;
  final bool selected;
  final bool active;

  /// 行首的小图标。笔记没有——它和文件夹名对齐着，多一个图标反而像缩进。
  final IconData? icon;

  /// 行尾的后缀（`NRS`、`PNG`……）。空串表示不显示。
  final String badge;

  /// 任务进度之类的附加信息，排在标题和后缀之间。
  final Widget? trailing;

  final VoidCallback onTap;
  final ValueChanged<TapDownDetails>? onSecondaryTapDown;

  /// Replaces the label while the note is being renamed in place.
  final Widget? renameField;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) => GestureDetector(
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: AppLayout.rowHeight,
          decoration: BoxDecoration(
            color: selected
                ? p.accentSoft
                : (hovered ? p.surfaceRaised : Colors.transparent),
            borderRadius: AppRadius.smAll,
          ),
          // `StackFit.expand` keeps the row full-height even when there are no
          // indent guides to stretch it, so the label stays vertically centred
          // instead of sticking to the top of the row.
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // The open note marks itself with a short amber bar rather than
              // with amber text: in a dense tree, one bright mark per row is
              // what keeps the list scannable.
              if (active)
                Positioned(
                  left: 0,
                  top: AppSpace.xs,
                  bottom: AppSpace.xs,
                  child: Container(
                    width: 2,
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(AppRadius.xs),
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  _IndentGuides(depth: depth),
                  // Same left edge as a folder name: the folder row spends this
                  // width on its disclosure arrow.
                  SizedBox(
                    width: 19,
                    child: icon == null
                        ? null
                        : Center(
                            child: Icon(icon, size: 11, color: p.textTertiary),
                          ),
                  ),
                  Expanded(
                    child:
                        renameField ??
                        Tooltip(
                          message: tooltip,
                          waitDuration: const Duration(milliseconds: 600),
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppText.ui,
                              height: 1.2,
                              fontWeight: selected
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                              color: selected ? p.textPrimary : p.textSecondary,
                            ),
                          ),
                        ),
                  ),
                  ?trailing,
                  if (badge.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpace.xs),
                      child: Text(
                        badge,
                        style: TextStyle(
                          fontSize: 9.5,
                          height: 1.1,
                          letterSpacing: 0.3,
                          fontWeight: FontWeight.w500,
                          color: p.textTertiary,
                        ),
                      ),
                    ),
                  const SizedBox(width: AppSpace.xxs),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 文件行右侧的任务进度徽标。
///
/// 它单独订阅「这一篇笔记」的任务统计：正文输入只让开着的那一行重建，
/// 其余行与整棵树都不动；统计没变时 `select` 也不触发重建。
class _TaskBadge extends StatelessWidget {
  const _TaskBadge({required this.noteId});

  final String noteId;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final ({int done, int total}) counts = context
        .select<NotesController, ({int done, int total})>((
          NotesController notes,
        ) {
          final Note? live = notes.noteById(noteId);
          return (done: live?.taskDone ?? 0, total: live?.taskTotal ?? 0);
        });
    if (counts.total == 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '${counts.done}/${counts.total}',
          style: TextStyle(
            fontSize: 10,
            color: counts.done == counts.total ? p.success : p.textTertiary,
          ),
        ),
        const SizedBox(width: AppSpace.xs),
      ],
    );
  }
}

/// One hairline per ancestor level, so a deep row still says which folders it
/// belongs to after its parent row has scrolled away.
class _IndentGuides extends StatelessWidget {
  const _IndentGuides({required this.depth});

  final int depth;

  @override
  Widget build(BuildContext context) {
    if (depth <= 0) return const SizedBox.shrink();
    final AppPalette p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < depth; i++)
          SizedBox(
            width: AppLayout.rowIndent,
            child: Center(child: Container(width: 1, color: p.outlineSoft)),
          ),
      ],
    );
  }
}
