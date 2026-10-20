import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_enums.dart';
import '../../core/platform/vault_sync.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_outline.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';
import '../editor/editor_pane.dart';
import '../editor/outline_panel.dart';
import 'function_rail.dart';
import 'note_list_panel.dart';
import 'settings_dialog.dart';
import 'title_bar.dart';

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
  final FocusNode _shellFocus = FocusNode(debugLabel: 'nrs-shell');

  SidebarView _view = SidebarView.files;
  int _cursorLine = 0;
  VoidCallback? _stopVaultSync;

  @override
  void initState() {
    super.initState();
    // Prefer the newest note on first paint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final NotesController notes = context.read<NotesController>();
      if (notes.selectedId == null && notes.allNotes.isNotEmpty) {
        notes.select(notes.allNotes.first.id);
      }
    });
    // Coming back to the window is when an edit made in another program can be
    // picked up. Autosave keeps the draft authoritative while it is dirty.
    _stopVaultSync = startVaultSync(_pullFromDisk);
  }

  @override
  void dispose() {
    _stopVaultSync?.call();
    _shellFocus.dispose();
    super.dispose();
  }

  Future<void> _pullFromDisk() async {
    if (!mounted) return;
    final String? notice = await context.read<NotesController>().syncFromDisk();
    if (!mounted || notice == null) return;
    _toast(notice);
  }

  void _toast(String message, {String? actionLabel, VoidCallback? onAction}) {
    if (!mounted) return;
    final AppPalette p = context.palette;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: Duration(seconds: onAction == null ? 2 : 6),
        content: Row(
          children: <Widget>[
            Icon(LucideIcons.circleCheck, size: 15, color: p.success),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        action: onAction == null
            ? null
            : SnackBarAction(
                label: actionLabel ?? '撤销',
                textColor: p.accent,
                onPressed: onAction,
              ),
      ),
    );
  }

  void _selectView(SidebarView view) {
    final SettingsController settings = context.read<SettingsController>();
    setState(() => _view = view);
    if (settings.sidebarCollapsed) settings.sidebarCollapsed = false;
  }

  void _toggleSidebar() {
    final SettingsController settings = context.read<SettingsController>();
    settings.sidebarCollapsed = !settings.sidebarCollapsed;
    if (settings.focusMode) settings.focusMode = false;
  }

  static String _displayTitle(Note note) =>
      note.title.trim().isEmpty ? '未命名笔记' : note.title.trim();

  /// Deletes one note, with a dialog that shows exactly which file disappears.
  Future<void> _confirmDelete(Note note) async {
    final AppPalette p = context.palette;
    final NotesController notes = context.read<NotesController>();
    final String title = _displayTitle(note);
    // Snapshot before the file disappears so "撤销" can rebuild it byte for byte.
    final String backup = note.toMarkdown();
    final String fileName = note.fileName;
    final String folderPath = note.folderPath;
    final String path = note.relativePath;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierColor: p.overlay,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这篇笔记?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('「$title」将从笔记库中移除。'),
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm + 2,
                vertical: AppSpace.sm,
              ),
              decoration: BoxDecoration(
                color: p.surfaceSunken,
                borderRadius: AppRadius.smAll,
                border: Border.all(color: p.outlineSoft),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    LucideIcons.fileText,
                    size: 13,
                    color: p.textTertiary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      path,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        fontFamily: AppFonts.mono,
                        fontFamilyFallback: AppFonts.monoFallback,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: p.danger,
              // A solid `danger` fill cannot assume anything about the palette:
              // a deep red wants white text, a light salmon wants black. Let the
              // actual contrast decide instead of the brightness flag.
              foregroundColor: AppPalette.readableOn(p.danger),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await notes.deleteNote(note);
    _toast(
      '已删除「$title」',
      actionLabel: '撤销',
      onAction: () =>
          notes.restoreNote(backup, fileName, folderPath: folderPath),
    );
  }

  /// Deletes what the file tree has selected. One file keeps the single-file
  /// dialog above; several get their titles listed, because a bulk delete is
  /// exactly where "what am I about to lose" needs to be on screen.
  ///
  /// Every file is snapshotted before it goes, so one 「撤销」 puts the whole
  /// batch back. A note whose name was taken in the meantime is restored under
  /// its own ` 2` name rather than overwriting the newer file — that is the
  /// store's `writeNewMarkdown`, not this dialog's, job.
  Future<void> _confirmDeleteMany(List<Note> targets) async {
    if (targets.isEmpty) return;
    if (targets.length == 1) return _confirmDelete(targets.single);

    final AppPalette p = context.palette;
    final NotesController notes = context.read<NotesController>();
    final List<DeletedNote> backups = <DeletedNote>[
      for (final Note note in targets)
        (
          raw: note.toMarkdown(),
          fileName: note.fileName,
          folderPath: note.folderPath,
        ),
    ];
    final List<String> titles = targets.map(_displayTitle).toList();
    const int listed = 5;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierColor: p.overlay,
      builder: (BuildContext context) => AlertDialog(
        title: Text('删除这 ${targets.length} 篇笔记?'),
        content: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('连同磁盘上的 .md 文件一起移除。'),
              const SizedBox(height: AppSpace.md),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.sm + 2,
                  vertical: AppSpace.sm,
                ),
                decoration: BoxDecoration(
                  color: p.surfaceSunken,
                  borderRadius: AppRadius.smAll,
                  border: Border.all(color: p.outlineSoft),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final String title in titles.take(listed))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1.5),
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: p.textSecondary,
                          ),
                        ),
                      ),
                    if (titles.length > listed)
                      Padding(
                        padding: const EdgeInsets.only(top: 1.5),
                        child: Text(
                          '…还有 ${titles.length - listed} 篇',
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: p.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: p.danger,
              // A solid `danger` fill cannot assume anything about the palette:
              // a deep red wants white text, a light salmon wants black. Let the
              // actual contrast decide instead of the brightness flag.
              foregroundColor: AppPalette.readableOn(p.danger),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await notes.deleteNotes(targets);
    _toast(
      '已删除 ${targets.length} 篇笔记',
      actionLabel: '撤销',
      onAction: () => notes.restoreNotes(backups),
    );
  }

  void _createNote() {
    context.read<NotesController>().createNote();
  }

  Map<ShortcutActivator, VoidCallback> _globalShortcuts() {
    final NotesController notes = context.read<NotesController>();
    final SettingsController settings = context.read<SettingsController>();
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): _createNote,
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
          showSettingsDialog(context),
      const SingleActivator(LogicalKeyboardKey.backslash, control: true):
          _toggleSidebar,
      const SingleActivator(
        LogicalKeyboardKey.keyF,
        control: true,
        shift: true,
      ): () => settings.focusMode = !settings.focusMode,
      const SingleActivator(
        LogicalKeyboardKey.keyO,
        control: true,
        shift: true,
      ): () => settings.outlineVisible = !settings.outlineVisible,
      const SingleActivator(
        LogicalKeyboardKey.arrowUp,
        control: true,
        alt: true,
      ): () => notes.selectAdjacentInList(notes.visibleNotes, -1),
      const SingleActivator(
        LogicalKeyboardKey.arrowDown,
        control: true,
        alt: true,
      ): () => notes.selectAdjacentInList(notes.visibleNotes, 1),
      // Ctrl+Tab walks the open tabs, the way every tabbed app does.
      const SingleActivator(LogicalKeyboardKey.tab, control: true): () =>
          notes.selectAdjacentTab(1),
      const SingleActivator(
        LogicalKeyboardKey.tab,
        control: true,
        shift: true,
      ): () => notes.selectAdjacentTab(-1),
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (settings.focusMode) settings.focusMode = false;
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();
    final SettingsController settings = context.watch<SettingsController>();
    final bool zen = settings.focusMode;
    final Note? open = notes.draft ?? notes.selectedNote;
    final List<Heading> headings = open == null
        ? const <Heading>[]
        : extractHeadings(open.body);

    return CallbackShortcuts(
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
              final bool showOutline =
                  !zen &&
                  settings.outlineVisible &&
                  c.maxWidth >= AppLayout.outlineMinShellWidth;
              final double leftInset = zen
                  ? 0
                  : AppLayout.railWidth +
                        (settings.sidebarCollapsed
                            ? 0
                            : settings.listWidth +
                                  AppLayout.resizeHandleWidth);
              // The outline button aligns with the *panel*, not with the drag
              // handle in front of it, so the handle's width is not counted.
              final double rightInset = showOutline ? settings.outlineWidth : 0;

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
                    leftInset: leftInset,
                    rightInset: rightInset,
                  ),
                  if (notes.error != null)
                    _ErrorBanner(message: notes.error!),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // The rail keeps only what has no place in the caption:
                        // the tag view and settings.
                        if (!zen)
                          AppRail(
                            view: _view,
                            onSelectView: _selectView,
                            onOpenSettings: () => showSettingsDialog(context),
                          ),
                        // The panes each get a handle on the edge that faces the
                        // editor, and each handle is carved out of the pane it
                        // follows, so its hairline lands on the seam and the
                        // boundary reads the same everywhere.
                        if (!zen && !settings.sidebarCollapsed) ...<Widget>[
                          SizedBox(
                            width: settings.listWidth,
                            child: NoteListPanel(
                              view: _view,
                              onCreateNote: _createNote,
                              onDeleteNotes: _confirmDeleteMany,
                              onSwitchView: _selectView,
                            ),
                          ),
                          ResizeHandle(
                            background: p.sidebar,
                            onDelta: (double d) =>
                                settings.listWidth = settings.listWidth + d,
                          ),
                        ],
                        Expanded(
                          child: EditorPane(
                            key: _editorKey,
                            onDelete: _confirmDelete,
                            onOpenSearch: () =>
                                _selectView(SidebarView.search),
                            onCursorLineChanged: (int line) {
                              if (line == _cursorLine) return;
                              setState(() => _cursorLine = line);
                            },
                          ),
                        ),
                        if (showOutline) ...<Widget>[
                          // The handle sits left of the outline, so dragging it
                          // rightwards narrows the column.
                          ResizeHandle(
                            background: p.surface,
                            onDelta: (double d) =>
                                settings.outlineWidth = settings.outlineWidth - d,
                          ),
                          OutlinePanel(
                            headings: headings,
                            currentLine: _cursorLine,
                            width: settings.outlineWidth,
                            onSelect: (int line) =>
                                _editorKey.currentState?.goToHeading(line),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
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
