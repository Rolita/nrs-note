import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../common/app_widgets.dart';
import '../editor/editor_context_menu.dart';
import 'data_safety_dialogs.dart';

/// The real directory tree of the vault: folders first, then the notes that
/// live directly in each one.
///
/// Every expanded folder keeps its own row; an empty one simply shows nothing
/// underneath. Expansion is on purpose *not* persisted: after a restart the
/// vault opens with every folder visible, which is the state that hides the
/// fewest notes.
///
/// Files select like a file manager: a plain click opens one, Shift+click takes
/// the visible range from the anchor, and a right-click offers the per-file
/// actions. The multi-selection is local to the tree — the editor still edits
/// the one note that was opened last.
class VaultTree extends StatefulWidget {
  const VaultTree({
    super.key,
    required this.notes,
    required this.onOpenNote,
    required this.onDeleteNotes,
    required this.onDeleteFolder,
    this.onAllExpandedChanged,
  });

  final NotesController notes;
  final ValueChanged<Note> onOpenNote;
  final ValueChanged<List<Note>> onDeleteNotes;

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
  final Set<String> _selected = <String>{};
  String? _anchorId;
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
    _expanded.addAll(notes.folders);
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

    final String? selected = notes.selectedId;
    if (selected != null &&
        selected != _lastSelectedId &&
        !_selected.contains(selected)) {
      _selected
        ..clear()
        ..add(selected);
      _anchorId = selected;
    }
    if (_selected.isEmpty && selected != null) {
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
        .where((_TreeRow row) => row.note != null)
        .map((_TreeRow row) => row.note!)
        .toList(growable: false);
  }

  /// Keeps only files that are actually on screen, so a collapsed folder cannot
  /// leave a hidden note in a bulk delete.
  void _pruneToVisible() {
    final Set<String> visible = <String>{
      for (final Note n in _visibleFiles()) n.id,
    };
    _selected.removeWhere((String id) => !visible.contains(id));
  }

  void _selectOnly(Note note) {
    setState(() {
      _selected
        ..clear()
        ..add(note.id);
      _anchorId = note.id;
    });
  }

  void _selectRangeTo(Note target) {
    final List<Note> files = _visibleFiles();
    final int anchor = files.indexWhere((Note n) => n.id == _anchorId);
    final int index = files.indexWhere((Note n) => n.id == target.id);
    if (anchor < 0 || index < 0) {
      _selectOnly(target);
      return;
    }
    final int start = math.min(anchor, index);
    final int end = math.max(anchor, index);
    setState(() {
      _selected
        ..clear()
        ..addAll(files.sublist(start, end + 1).map((Note n) => n.id));
    });
  }

  /// A plain click opens the note. Shift+click extends the selection from the
  /// anchor instead — it changes *what a delete would take*, so it deliberately
  /// leaves the editor where it was rather than swapping the document out from
  /// under someone who is still picking the end of the range.
  void _tapFile(Note note) {
    _treeFocus.requestFocus();
    widget.notes.setActiveFolder(note.folderPath);
    _focusNoteId = note.id;
    _focusFolderPath = null;
    if (HardwareKeyboard.instance.isShiftPressed && _anchorId != null) {
      _selectRangeTo(note);
      return;
    }
    _selectOnly(note);
    widget.onOpenNote(note);
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
  bool _canDrop(_DragPayload payload, String folder) {
    final String? moving = payload.folder;
    if (moving != null) {
      // A folder cannot go inside itself or its own sub-folder — that would
      // detach the whole branch from the vault.
      if (folder == moving || folder.startsWith('$moving/')) return false;
      return _parentOf(moving) != folder;
    }
    return _dragTargets().any((Note n) => n.folderPath != folder);
  }

  Future<void> _dropPayload(_DragPayload payload, String folder) async {
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
    final Map<String, List<Note>> notesByFolder = <String, List<Note>>{};
    for (final Note note in notes.allNotes) {
      notesByFolder.putIfAbsent(note.folderPath, () => <Note>[]).add(note);
    }

    List<String> childrenOf(String parent) {
      final Set<String>? children = childFolders[parent];
      if (children == null) return const <String>[];
      return children.toList()
        ..sort(
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
      for (final Note note in notesByFolder[parent] ?? const <Note>[]) {
        rows.add(_TreeRow.file(note, depth));
      }
    }

    walk('', 0);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final NotesController notes = widget.notes;
    if (notes.allNotes.isEmpty && notes.folders.isEmpty) {
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
      child: DragTarget<_DragPayload>(
        onWillAcceptWithDetails: (DragTargetDetails<_DragPayload> d) {
          final bool accepted =
              _hoverFolder == null && d.data.tree._canDrop(d.data, '');
          if (accepted) {
            _overRoot = true;
            _publishDropTarget();
          }
          return accepted;
        },
        onLeave: (_DragPayload? _) {
          _overRoot = false;
          _publishDropTarget();
        },
        onAcceptWithDetails: (DragTargetDetails<_DragPayload> d) =>
            d.data.tree._dropPayload(d.data, ''),
        builder:
            (
              BuildContext context,
              List<_DragPayload?> candidate,
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
                final Note? note = row.note;
                if (note != null) return _fileRow(row, note, notes);
                return _folderRow(row, notes);
              },
            ),
      ),
    );
  }

  Widget _fileRow(_TreeRow row, Note note, NotesController notes) {
    final bool renaming = _renamingNoteId == note.id;
    final Widget content = _FileRow(
      note: note,
      depth: row.depth,
      selected: _selected.contains(note.id),
      active: note.id == notes.selectedId,
      renameField: renaming ? _renameField() : null,
      onTap: () => _tapFile(note),
      onSecondaryTapDown: (TapDownDetails d) =>
          _showFileMenu(note, d.globalPosition),
    );
    // Renaming wins over dragging: a text field full of selected characters
    // must drag like text, not like a file.
    if (renaming) return content;
    return Draggable<_DragPayload>(
      data: _DragPayload.notes(this),
      onDragStarted: () => _beginDrag(note),
      // The preview names the row and, live, the folder it would land in; the
      // row itself fades while the drag is in flight.
      feedback: _dragPreview(label: () => _dragLabel(note)),
      childWhenDragging: Opacity(opacity: 0.4, child: content),
      child: content,
    );
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
    return DragTarget<_DragPayload>(
      // Accepts every drop, even one that would change nothing: holding on to
      // the drop is what stops it falling through to the vault root below.
      onWillAcceptWithDetails: (DragTargetDetails<_DragPayload> d) {
        _hoverFolder = folder;
        _publishDropTarget();
        return true;
      },
      onLeave: (_DragPayload? _) {
        if (_hoverFolder == folder) {
          _hoverFolder = null;
          _publishDropTarget();
        }
      },
      onAcceptWithDetails: (DragTargetDetails<_DragPayload> d) =>
          d.data.tree._dropPayload(d.data, folder),
      builder:
          (
            BuildContext context,
            List<_DragPayload?> candidate,
            List<dynamic> rejected,
          ) {
            final _DragPayload? hovering = candidate.isEmpty
                ? null
                : candidate.first;
            return Draggable<_DragPayload>(
              data: _DragPayload.folder(this, folder),
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
class _DragPayload {
  const _DragPayload.notes(this.tree) : folder = null;

  const _DragPayload.folder(this.tree, String this.folder);

  final VaultTreeState tree;

  /// The folder being moved, or null when the drag carries the note selection.
  final String? folder;
}

class _TreeRow {
  const _TreeRow._({
    required this.depth,
    this.folderPath,
    this.name = '',
    this.note,
  });

  factory _TreeRow.folder(String path, String name, int depth) =>
      _TreeRow._(depth: depth, folderPath: path, name: name);

  factory _TreeRow.file(Note note, int depth) =>
      _TreeRow._(depth: depth, note: note);

  final int depth;
  final String? folderPath;
  final String name;
  final Note? note;
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
    required this.note,
    required this.depth,
    required this.selected,
    required this.active,
    required this.onTap,
    required this.onSecondaryTapDown,
    this.renameField,
  });

  final Note note;
  final int depth;
  final bool selected;
  final bool active;
  final VoidCallback onTap;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;

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
                  const SizedBox(width: 19),
                  Expanded(
                    child:
                        renameField ??
                        Tooltip(
                          message: note.relativePath,
                          waitDuration: const Duration(milliseconds: 600),
                          child: Text(
                            note.title.trim().isEmpty
                                ? '未命名'
                                : note.title.trim(),
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
                  _TaskBadge(noteId: note.id),
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
