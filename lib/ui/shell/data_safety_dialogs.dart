import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../data/storage/note_store.dart';
import '../../state/notes_controller.dart';
import '../common/app_widgets.dart';
import '../common/delete_dialog.dart';

/// The vault's recycle bin: everything deleted, restorable until the user
/// empties it by hand.
Future<void> showTrashDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: context.palette.overlay,
    builder: (BuildContext context) => const _TrashDialog(),
  );
}

/// Read-only snapshots of one note, with a restore that first saves what is on
/// disk now so even the restore can be undone.
Future<void> showVersionHistoryDialog(BuildContext context, Note note) {
  return showDialog<void>(
    context: context,
    barrierColor: context.palette.overlay,
    builder: (BuildContext context) => _HistoryDialog(note: note),
  );
}

class _TrashDialog extends StatefulWidget {
  const _TrashDialog();

  @override
  State<_TrashDialog> createState() => _TrashDialogState();
}

class _TrashDialogState extends State<_TrashDialog> {
  List<TrashEntry>? _entries;
  _TrashTree _tree = _TrashTree.empty;
  bool _busy = false;
  String? _error;

  /// null = 全部条目；空字符串 = 笔记库根目录；其余是文件夹路径。
  String? _selected;

  NotesController get _notes => context.read<NotesController>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<TrashEntry> entries = await _notes.listTrash();
    if (!mounted) return;
    final _TrashTree tree = _TrashTree.build(entries);
    setState(() {
      _entries = entries;
      _tree = tree;
      final String? selected = _selected;
      if (selected != null &&
          selected.isNotEmpty &&
          tree.folderAt(selected) == null) {
        _selected = null;
      }
    });
  }

  Future<void> _restore(List<TrashEntry> entries) async {
    if (_busy || entries.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final int restored = await _notes.restoreTrashEntries(<String>[
      for (final TrashEntry entry in entries) entry.id,
    ]);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (restored == 0) _error = '恢复失败，条目仍保留在回收站';
    });
    if (restored > 0) await _load();
  }

  Future<void> _purge(List<TrashEntry> entries) async {
    if (_busy || entries.isEmpty) return;
    final bool single = entries.length == 1;
    final bool confirmed = await _confirm(
      title: single ? '永久删除这个条目？' : '永久删除这 ${entries.length} 项？',
      message: single
          ? '「${_displayTitle(entries.single)}」将从回收站中移除，此操作不可恢复。'
          : '这 ${entries.length} 项将从回收站中移除，此操作不可恢复。',
      entries: entries,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    bool clean = true;
    for (final TrashEntry entry in entries) {
      if (!await _notes.purgeTrash(entry.id)) clean = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!clean) _error = '永久删除失败，条目仍在回收站';
    });
    await _load();
  }

  Future<void> _empty() async {
    final List<TrashEntry> entries = _entries ?? const <TrashEntry>[];
    if (_busy || entries.isEmpty) return;
    final bool confirmed = await _confirm(
      title: '清空回收站？',
      message: '回收站里的 ${entries.length} 项将被永久删除，此操作不可恢复。',
      entries: entries,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final bool emptied = await _notes.emptyTrash();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!emptied) _error = '清空回收站失败，条目仍保留';
    });
    await _load();
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required List<TrashEntry> entries,
  }) async {
    final bool? result = await showDeleteDialog(
      context,
      title: title,
      message: message,
      targets: <DeleteTarget>[
        for (final TrashEntry entry in entries.take(4))
          DeleteTarget(name: _displayTitle(entry), meta: entry.originalPath),
      ],
      overflowLabel: entries.length > 4 ? '…还有 ${entries.length - 4} 项' : null,
    );
    return result ?? false;
  }

  String _displayTitle(TrashEntry entry) =>
      entry.title.trim().isEmpty ? '未命名笔记' : entry.title.trim();

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final List<TrashEntry>? entries = _entries;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl + AppSpace.xs),
            child: SizedBox(
              width: 680,
              height: 460,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surfaceRaised,
                  borderRadius: AppRadius.xlAll,
                  border: Border.all(color: p.outline),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: p.shadow,
                      blurRadius: 34,
                      offset: const Offset(0, 12),
                    ),
                    BoxShadow(
                      color: p.shadow,
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: AppRadius.xlAll,
                  child: Column(
                    children: <Widget>[
                      _header(p, entries),
                      Divider(height: 1, color: p.outlineSoft),
                      Expanded(
                        child: entries == null
                            ? const Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : entries.isEmpty
                            ? const EmptyState(
                                icon: LucideIcons.trash2,
                                title: '回收站是空的',
                                message: '删除的笔记和文件夹会出现在这里，直到你手动清空。',
                                compact: true,
                              )
                            : _browser(p),
                      ),
                      Divider(height: 1, color: p.outlineSoft),
                      _footer(p, entries),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppPalette p, List<TrashEntry>? entries) {
    final int notes = entries?.length ?? 0;
    final int bytes =
        entries?.fold<int>(0, (int sum, TrashEntry e) => sum + e.size) ?? 0;
    final String meta = entries == null
        ? '删除的笔记和文件夹会一直保留，直到你手动清空。'
        : '$notes 项 · ${_tree.folderCount} 个文件夹 · '
              '${formatRecoverySize(bytes)} · 一直保留，直到你手动清空';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 13, 12, 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: p.surfaceSunken,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: p.outlineSoft),
            ),
            child: Icon(LucideIcons.trash2, size: 14, color: p.textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '回收站',
                    style: TextStyle(
                      fontSize: AppText.title,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          AppIconButton(
            icon: LucideIcons.x,
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _browser(AppPalette p) {
    final String? selected = _selected;
    final _TrashFolder? folder = selected == null || selected.isEmpty
        ? null
        : _tree.folderAt(selected);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          width: 206,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.sidebar,
              border: Border(right: BorderSide(color: p.outlineSoft)),
            ),
            child: _scopePane(p),
          ),
        ),
        Expanded(child: _entryPane(p, folder)),
      ],
    );
  }

  Widget _scopePane(AppPalette p) {
    return ListView(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      children: <Widget>[
        _scopeRow(
          p,
          icon: LucideIcons.archive,
          label: '全部',
          count: _tree.noteCount,
          selected: _selected == null,
          onTap: () => setState(() => _selected = null),
        ),
        _scopeRow(
          p,
          icon: LucideIcons.inbox,
          label: '笔记库根目录',
          count: _tree.rootNotes.length,
          selected: _selected == '',
          onTap: () => setState(() => _selected = ''),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
          child: Text(
            '文件夹 ${_tree.folderCount}',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: p.textTertiary,
            ),
          ),
        ),
        for (final _TrashFolder folder in _tree.allFolders)
          _scopeRow(
            p,
            icon: LucideIcons.folder,
            label: folder.name,
            count: folder.noteCount,
            depth: folder.depth,
            selected: _selected == folder.path,
            onTap: () => setState(() => _selected = folder.path),
          ),
      ],
    );
  }

  Widget _scopeRow(
    AppPalette p, {
    required IconData icon,
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
    int depth = 0,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) {
          final Color fg = selected
              ? p.accent
              : (hovered ? p.textPrimary : p.textSecondary);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Stack(
              children: <Widget>[
                Container(
                  height: 26,
                  padding: EdgeInsets.only(left: 7 + depth * 14, right: 7),
                  decoration: BoxDecoration(
                    color: selected
                        ? p.accentSoft
                        : (hovered
                              ? p.textPrimary.withValues(alpha: 0.05)
                              : Colors.transparent),
                    borderRadius: AppRadius.smAll,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        icon,
                        size: 14,
                        color: selected ? p.accent : p.textTertiary,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.label,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: fg,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: selected ? p.accent : p.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Positioned(
                    left: 0,
                    top: 6.5,
                    width: 2,
                    height: 13,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _entryPane(AppPalette p, _TrashFolder? folder) {
    final String? selected = _selected;
    final String crumb;
    final String meta;
    final List<Widget> rows = <Widget>[];

    if (selected == null) {
      crumb = '全部';
      meta = '${_tree.noteCount} 项 · ${_tree.folderCount} 个文件夹';
      for (final TrashEntry entry in _tree.rootNotes) {
        rows.add(_noteRow(p, entry));
      }
      for (final _TrashFolder root in _tree.folders) {
        _folderRows(p, rows, root, 0);
      }
    } else if (folder == null) {
      crumb = '笔记库根目录';
      meta =
          '${_tree.rootNotes.length} 篇 · '
          '${formatRecoverySize(_tree.rootNotes.fold<int>(0, (int sum, TrashEntry e) => sum + e.size))}';
      for (final TrashEntry entry in _tree.rootNotes) {
        rows.add(_noteRow(p, entry));
      }
    } else {
      crumb = folder.path;
      meta =
          '${folder.noteCount} 篇 · ${formatRecoverySize(folder.bytes)} · '
          '${formatDeletedAt(folder.latest)}';
      for (final TrashEntry entry in folder.notes) {
        rows.add(_noteRow(p, entry));
      }
      for (final _TrashFolder child in folder.children) {
        _folderRows(p, rows, child, 0);
      }
    }

    final List<TrashEntry> scope;
    if (selected == null) {
      scope = _entries ?? const <TrashEntry>[];
    } else if (folder == null) {
      scope = _tree.rootNotes;
    } else {
      scope = folder.allNotes;
    }
    final String restoreLabel = selected == null
        ? '全部恢复'
        : folder == null
        ? '恢复这 ${scope.length} 篇'
        : '恢复此文件夹（${folder.noteCount}）';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 10, 6),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        crumb,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppText.label,
                          fontWeight: FontWeight.w600,
                          color: p.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Text(
                      meta,
                      maxLines: 1,
                      style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                    ),
                  ],
                ),
              ),
              if (scope.isNotEmpty) ...<Widget>[
                const SizedBox(width: AppSpace.sm),
                _PanelButton(
                  label: restoreLabel,
                  icon: LucideIcons.rotateCcw,
                  ghost: true,
                  onPressed: _busy ? null : () => _restore(scope),
                ),
              ],
            ],
          ),
        ),
        _tableHead(p),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    '这个位置没有条目',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  itemCount: rows.length,
                  itemExtent: 30,
                  itemBuilder: (BuildContext context, int index) => rows[index],
                ),
        ),
      ],
    );
  }

  Widget _tableHead(AppPalette p) {
    final TextStyle style = TextStyle(
      fontSize: 10,
      letterSpacing: 0.4,
      color: p.textTertiary,
    );
    return Container(
      height: 24,
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.outlineSoft)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('名称', style: style)),
          const SizedBox(width: AppSpace.sm),
          SizedBox(width: 88, child: Text('删除时间', style: style)),
          const SizedBox(width: AppSpace.sm),
          SizedBox(width: 58, child: Text('大小', style: style)),
          const SizedBox(width: AppSpace.sm),
          const SizedBox(width: 84),
        ],
      ),
    );
  }

  Widget _rowShell(
    AppPalette p, {
    required Widget Function(bool hovered) builder,
  }) {
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) {
        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          decoration: BoxDecoration(
            color: hovered
                ? p.textPrimary.withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: builder(hovered),
        );
      },
    );
  }

  Widget _noteRow(AppPalette p, TrashEntry entry, {int depth = 0}) {
    final TextStyle metaStyle = TextStyle(
      fontSize: 10.5,
      color: p.textTertiary,
    );
    return _rowShell(
      p,
      builder: (bool hovered) => Row(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                SizedBox(width: depth * 14.0),
                Icon(
                  LucideIcons.fileText,
                  size: AppIconSize.xs,
                  color: p.textTertiary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    _displayTitle(entry),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.label,
                      color: p.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          SizedBox(
            width: 88,
            child: Text(
              formatDeletedAt(entry.deletedAt),
              maxLines: 1,
              style: metaStyle,
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          SizedBox(
            width: 58,
            child: Text(
              formatRecoverySize(entry.size),
              maxLines: 1,
              style: metaStyle,
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          SizedBox(
            width: 84,
            child: _ops(
              p,
              hovered,
              onRestore: () => _restore(<TrashEntry>[entry]),
              onPurge: () => _purge(<TrashEntry>[entry]),
            ),
          ),
        ],
      ),
    );
  }

  void _folderRows(
    AppPalette p,
    List<Widget> rows,
    _TrashFolder folder,
    int depth,
  ) {
    rows.add(_folderRow(p, folder, depth));
    for (final TrashEntry entry in folder.notes) {
      rows.add(_noteRow(p, entry, depth: depth));
    }
    for (final _TrashFolder child in folder.children) {
      _folderRows(p, rows, child, depth + 1);
    }
  }

  Widget _folderRow(AppPalette p, _TrashFolder folder, int depth) {
    final TextStyle metaStyle = TextStyle(
      fontSize: 10.5,
      color: p.textTertiary,
    );
    return _rowShell(
      p,
      builder: (bool hovered) => Row(
        children: <Widget>[
          Expanded(
            child: Row(
              children: <Widget>[
                SizedBox(width: depth * 14.0),
                Icon(
                  LucideIcons.folder,
                  size: AppIconSize.xs,
                  color: p.textSecondary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    folder.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.label,
                      fontWeight: FontWeight.w500,
                      color: p.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Text('${folder.noteCount} 篇', maxLines: 1, style: metaStyle),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          SizedBox(
            width: 88,
            child: Text(
              formatDeletedAt(folder.latest),
              maxLines: 1,
              style: metaStyle,
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          SizedBox(
            width: 58,
            child: Text(
              formatRecoverySize(folder.bytes),
              maxLines: 1,
              style: metaStyle,
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          SizedBox(
            width: 84,
            child: _ops(
              p,
              hovered,
              onRestore: () => _restore(folder.allNotes),
              onPurge: () => _purge(folder.allNotes),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ops(
    AppPalette p,
    bool hovered, {
    required VoidCallback onRestore,
    required VoidCallback onPurge,
  }) {
    return AnimatedOpacity(
      duration: AppMotion.fast,
      opacity: hovered ? 1 : 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          _MiniAction(
            icon: LucideIcons.rotateCcw,
            tooltip: '恢复',
            onPressed: _busy ? null : onRestore,
          ),
          _MiniAction(
            icon: LucideIcons.trash2,
            tooltip: '永久删除',
            danger: true,
            onPressed: _busy ? null : onPurge,
          ),
        ],
      ),
    );
  }

  Widget _footer(AppPalette p, List<TrashEntry>? entries) {
    final bool empty = entries == null || entries.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 9, 12, 9),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              _error ?? '恢复后回到原文件夹，重名会自动加「 2」',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: _error == null ? p.textTertiary : p.danger,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          _PanelButton(
            label: '清空回收站',
            icon: LucideIcons.trash2,
            danger: true,
            onPressed: empty || _busy ? null : _empty,
          ),
        ],
      ),
    );
  }
}

/// A folder reconstructed from the original paths of the trashed notes.
///
/// The trash only ever stores one directory per note, so a folder exists here
/// only because notes that lived in it were deleted. [notes] are the entries
/// that sat directly in it; [children] are the folders below it.
class _TrashFolder {
  const _TrashFolder({
    required this.path,
    required this.depth,
    required this.notes,
    required this.children,
  });

  final String path;
  final int depth;
  final List<TrashEntry> notes;
  final List<_TrashFolder> children;

  String get name => path.split('/').last;

  int get noteCount =>
      notes.length +
      children.fold<int>(0, (int sum, _TrashFolder c) => sum + c.noteCount);

  int get bytes =>
      notes.fold<int>(0, (int sum, TrashEntry e) => sum + e.size) +
      children.fold<int>(0, (int sum, _TrashFolder c) => sum + c.bytes);

  DateTime get latest {
    DateTime best = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    for (final TrashEntry entry in notes) {
      if (entry.deletedAt.isAfter(best)) best = entry.deletedAt;
    }
    for (final _TrashFolder child in children) {
      final DateTime childLatest = child.latest;
      if (childLatest.isAfter(best)) best = childLatest;
    }
    return best;
  }

  /// Every note in this folder and below it — what a folder-level restore or
  /// purge has to touch.
  List<TrashEntry> get allNotes => <TrashEntry>[
    ...notes,
    for (final _TrashFolder child in children) ...child.allNotes,
  ];

  List<_TrashFolder> get all => <_TrashFolder>[
    this,
    for (final _TrashFolder child in children) ...child.all,
  ];
}

/// The trashed entries, split into the ones that sat at the vault root and a
/// tree of the folders they came from.
class _TrashTree {
  const _TrashTree({required this.rootNotes, required this.folders});

  static const _TrashTree empty = _TrashTree(
    rootNotes: <TrashEntry>[],
    folders: <_TrashFolder>[],
  );

  final List<TrashEntry> rootNotes;
  final List<_TrashFolder> folders;

  int get noteCount =>
      rootNotes.length +
      folders.fold<int>(0, (int sum, _TrashFolder f) => sum + f.noteCount);

  int get folderCount =>
      folders.fold<int>(0, (int sum, _TrashFolder f) => sum + f.all.length);

  List<_TrashFolder> get allFolders => <_TrashFolder>[
    for (final _TrashFolder folder in folders) ...folder.all,
  ];

  _TrashFolder? folderAt(String path) {
    for (final _TrashFolder folder in allFolders) {
      if (folder.path == path) return folder;
    }
    return null;
  }

  static _TrashTree build(List<TrashEntry> entries) {
    final Map<String, List<TrashEntry>> byFolder = <String, List<TrashEntry>>{};
    final Set<String> paths = <String>{};

    for (final TrashEntry entry in entries) {
      final int cut = entry.originalPath.lastIndexOf('/');
      final String parent = cut < 0 ? '' : entry.originalPath.substring(0, cut);
      byFolder.putIfAbsent(parent, () => <TrashEntry>[]).add(entry);
      if (parent.isEmpty) continue;
      // A note deleted from `a/b` implies `a` exists too, even when no note was
      // trashed directly in it.
      final List<String> parts = parent.split('/');
      for (int i = 1; i <= parts.length; i++) {
        paths.add(parts.take(i).join('/'));
      }
    }

    final List<String> sorted = paths.toList()..sort();

    _TrashFolder buildFolder(String path, int depth) {
      final String prefix = '$path/';
      final List<_TrashFolder> children = <_TrashFolder>[
        for (final String candidate in sorted)
          if (candidate.startsWith(prefix) &&
              !candidate.substring(prefix.length).contains('/'))
            buildFolder(candidate, depth + 1),
      ];
      return _TrashFolder(
        path: path,
        depth: depth,
        notes: byFolder[path] ?? const <TrashEntry>[],
        children: children,
      );
    }

    return _TrashTree(
      rootNotes: byFolder[''] ?? const <TrashEntry>[],
      folders: <_TrashFolder>[
        for (final String path in sorted)
          if (!path.contains('/')) buildFolder(path, 0),
      ],
    );
  }
}

/// The 22px row affordance: restore, or purge.
class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: HoverBuilder(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        builder: (BuildContext context, bool hovered) {
          final bool hot = hovered && enabled;
          final Color fg = danger
              ? p.danger.withValues(alpha: enabled ? 1 : 0.4)
              : (hot
                    ? p.textPrimary
                    : p.textTertiary.withValues(alpha: enabled ? 1 : 0.4));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: AnimatedContainer(
              duration: AppMotion.instant,
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: hot
                    ? (danger
                          ? p.dangerSoft
                          : p.textPrimary.withValues(alpha: 0.08))
                    : Colors.transparent,
                borderRadius: AppRadius.smAll,
              ),
              child: Icon(icon, size: 13, color: fg),
            ),
          );
        },
      ),
    );
  }
}

/// A 27px panel button: the ghost one in the breadcrumb bar, the danger-soft
/// one in the footer.
class _PanelButton extends StatelessWidget {
  const _PanelButton({
    required this.label,
    this.icon,
    required this.onPressed,
    this.danger = false,
    this.ghost = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool danger;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool enabled = onPressed != null;
    return HoverBuilder(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      builder: (BuildContext context, bool hovered) {
        final bool hot = hovered && enabled;
        final Color bg = danger
            ? (hot
                  ? p.danger
                  : p.dangerSoft.withValues(alpha: enabled ? 1 : 0.5))
            : (hot
                  ? p.textPrimary.withValues(alpha: 0.06)
                  : Colors.transparent);
        final Color fg = danger
            ? (hot
                  ? AppPalette.readableOn(p.danger)
                  : p.danger.withValues(alpha: enabled ? 1 : 0.5))
            : (hot ? p.textPrimary : p.textSecondary);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 27,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: ghost ? p.outline : Colors.transparent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 13, color: fg),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppText.label,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.note});

  final Note note;

  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  List<NoteVersion>? _versions;
  String? _selectedId;
  String? _previewBody;
  String? _error;
  bool _loadingPreview = false;
  bool _restoring = false;
  int _previewToken = 0;

  NotesController get _notes => context.read<NotesController>();

  Note get _note => _notes.noteById(widget.note.id) ?? widget.note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<NoteVersion> versions = await _notes.historyOf(_note);
    if (!mounted) return;
    setState(() {
      _versions = versions;
      _selectedId = versions.isEmpty ? null : versions.first.id;
    });
    if (versions.isNotEmpty) await _loadPreview(versions.first.id);
  }

  Future<void> _select(NoteVersion version) async {
    setState(() {
      _selectedId = version.id;
      _previewBody = null;
      _error = null;
    });
    await _loadPreview(version.id);
  }

  Future<void> _loadPreview(String versionId) async {
    final int token = ++_previewToken;
    setState(() {
      _loadingPreview = true;
      _error = null;
    });
    final String? raw = await _notes.readVersion(_note, versionId);
    if (!mounted || token != _previewToken) return;
    setState(() {
      _loadingPreview = false;
      if (raw == null) {
        _previewBody = null;
        _error = '这个版本已不存在,可能已被清理';
      } else {
        _previewBody = Note.splitFrontMatter(raw).body;
      }
    });
  }

  Future<void> _restore() async {
    final String? versionId = _selectedId;
    if (versionId == null || _restoring) return;
    final AppPalette p = context.palette;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierColor: p.overlay,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('恢复这个版本?'),
        content: SizedBox(
          width: 360,
          child: Text(
            '当前正文会替换为这个版本。恢复前,当前内容会先存为一个新版本,'
            '所以这一步也可以撤回。',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _restoring = true;
      _error = null;
    });
    final bool restored = await _notes.restoreVersion(_note, versionId);
    if (!mounted) return;
    if (restored) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _restoring = false;
      _error = '恢复失败,当前笔记未被修改';
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final List<NoteVersion>? versions = _versions;
    final String title = _note.title.trim().isEmpty
        ? Note.titleOfFileName(_note.fileName)
        : _note.title.trim();

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                AppSpace.lg,
                AppSpace.md,
                AppSpace.sm,
              ),
              child: Row(
                children: <Widget>[
                  Icon(LucideIcons.history, size: 18, color: p.textSecondary),
                  const SizedBox(width: AppSpace.sm + 2),
                  Expanded(
                    child: Text(
                      '历史版本 · $title',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.display,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: p.textPrimary,
                      ),
                    ),
                  ),
                  AppIconButton(
                    icon: LucideIcons.x,
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.outlineSoft),
            Flexible(
              child: versions == null
                  ? const SizedBox(
                      height: 280,
                      child: Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : versions.isEmpty
                  ? _emptyState(p)
                  : Row(
                      children: <Widget>[
                        SizedBox(
                          width: 196,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(
                              vertical: AppSpace.xs,
                            ),
                            itemCount: versions.length,
                            itemBuilder: (BuildContext context, int index) =>
                                _versionRow(p, versions[index]),
                          ),
                        ),
                        VerticalDivider(width: 1, color: p.outlineSoft),
                        Expanded(child: _preview(p)),
                      ],
                    ),
            ),
            Divider(height: 1, color: p.outlineSoft),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                AppSpace.sm,
                AppSpace.xl,
                AppSpace.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.xs),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: AppText.caption,
                          color: p.danger,
                        ),
                      ),
                    ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '恢复前会先把当前内容存为一个新版本。',
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: p.textTertiary,
                          ),
                        ),
                      ),
                      AppTextButton(
                        label: '取消',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: AppSpace.xs),
                      FilledButton(
                        onPressed:
                            versions == null ||
                                versions.isEmpty ||
                                _selectedId == null ||
                                _restoring
                            ? null
                            : _restore,
                        child: Text(_restoring ? '恢复中…' : '恢复此版本'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState(AppPalette p) {
    return SizedBox(
      height: 280,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              LucideIcons.history,
              size: 26,
              color: p.textTertiary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              '还没有历史版本',
              style: TextStyle(
                fontSize: AppText.body,
                fontWeight: FontWeight.w500,
                color: p.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              '编辑后每 10 分钟最多保存一版。',
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionRow(AppPalette p, NoteVersion version) {
    final bool selected = version.id == _selectedId;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        return GestureDetector(
          onTap: () => _select(version),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            margin: const EdgeInsets.symmetric(
              horizontal: AppSpace.xs,
              vertical: 1,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm + 2,
              vertical: 7,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? p.accentSoft
                  : (hovered ? p.surfaceRaised : Colors.transparent),
              borderRadius: AppRadius.mdAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  formatVersionTime(version.capturedAt),
                  style: TextStyle(
                    fontSize: AppText.ui,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? p.accent : p.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatRecoverySize(version.size),
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: p.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _preview(AppPalette p) {
    if (_loadingPreview) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final String? body = _previewBody;
    if (body == null) {
      return Center(
        child: Text(
          _error ?? '选择一个版本查看内容',
          style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
        ),
      );
    }
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.xl,
          AppSpace.md,
          AppSpace.xl,
          AppSpace.lg,
        ),
        child: body.trim().isEmpty
            ? Text(
                '（空白正文）',
                style: TextStyle(fontSize: AppText.body, color: p.textTertiary),
              )
            : SelectableText(
                body,
                style: TextStyle(
                  fontSize: AppText.body,
                  height: 1.7,
                  fontFamily: AppFonts.prose,
                  fontFamilyFallback: AppFonts.proseFallback,
                  color: p.textPrimary,
                ),
              ),
      ),
    );
  }
}

/// `2 分钟前` for a deletion, with an absolute date once it is old enough that
/// "43 天前" stops being easier to read than the date itself.
String formatDeletedAt(DateTime time) {
  final DateTime local = time.toLocal();
  final Duration diff = DateTime.now().difference(local);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${local.year}-${_two(local.month)}-${_two(local.day)}';
}

/// `今天 14:20`, `昨天 18:32`, then a calendar date.
String formatVersionTime(DateTime time) {
  final DateTime local = time.toLocal();
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(local.year, local.month, local.day);
  final int days = today.difference(day).inDays;
  final String clock = '${_two(local.hour)}:${_two(local.minute)}';
  if (days == 0) return '今天 $clock';
  if (days == 1) return '昨天 $clock';
  if (local.year == now.year) {
    return '${local.month} 月 ${local.day} 日 $clock';
  }
  return '${local.year}-${_two(local.month)}-${_two(local.day)} $clock';
}

String formatRecoverySize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final double kb = bytes / 1024;
  if (kb < 1024) {
    return '${kb < 10 ? kb.toStringAsFixed(1) : kb.toStringAsFixed(0)} KB';
  }
  return '${(kb / 1024).toStringAsFixed(1)} MB';
}

String _two(int value) => value.toString().padLeft(2, '0');
