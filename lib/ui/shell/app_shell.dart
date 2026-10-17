import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';
import '../editor/editor_pane.dart';
import 'command_palette.dart';
import 'note_list_panel.dart';
import 'settings_dialog.dart';
import 'sidebar.dart';

/// The three-pane application shell.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final GlobalKey<EditorPaneState> _editorKey = GlobalKey<EditorPaneState>();
  final FocusNode _shellFocus = FocusNode(debugLabel: 'nrs-shell');

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
  }

  @override
  void dispose() {
    _shellFocus.dispose();
    super.dispose();
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
            Icon(Icons.check_circle_rounded, size: 15, color: p.success),
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

  Future<void> _confirmDelete(Note note) async {
    final AppPalette p = context.palette;
    final NotesController notes = context.read<NotesController>();
    final String title = note.title.trim().isEmpty ? '未命名笔记' : note.title.trim();
    // Snapshot before the file disappears so "撤销" can rebuild it byte for byte.
    final String backup = note.toMarkdown();
    final String fileName = note.fileName;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0x44000000),
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
                    Icons.description_outlined,
                    size: 13,
                    color: p.textTertiary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      fileName,
                      style: TextStyle(
                        fontSize: 11.5,
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
              foregroundColor: Colors.white,
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
      onAction: () => notes.restoreNote(backup, fileName),
    );
  }

  void _createNote() {
    context.read<NotesController>().createNote();
    _toast('已创建新笔记');
  }

  void _openPalette() {
    final NotesController notes = context.read<NotesController>();
    final SettingsController settings = context.read<SettingsController>();
    CommandPalette.show(
      context,
      notes: notes.allNotes,
      onSelectNote: (Note note) => notes.select(note.id),
      actions: <PaletteAction>[
        PaletteAction(
          label: '新建笔记',
          icon: Icons.add_rounded,
          hint: 'Ctrl + N',
          run: _createNote,
        ),
        PaletteAction(
          label: '切换主题',
          icon: Icons.brightness_6_outlined,
          hint: '当前:${settings.theme.label}',
          run: () {
            final int next = (settings.theme.index + 1) % ThemePreference.values.length;
            settings.theme = ThemePreference.values[next];
            _toast('主题:${settings.theme.label}');
          },
        ),
        PaletteAction(
          label: settings.outlineVisible ? '隐藏大纲' : '显示大纲',
          icon: Icons.account_tree_outlined,
          hint: 'Ctrl + Shift + O',
          run: () => settings.outlineVisible = !settings.outlineVisible,
        ),
        PaletteAction(
          label: settings.focusMode ? '退出专注模式' : '进入专注模式',
          icon: Icons.fullscreen_rounded,
          hint: 'Ctrl + Shift + F',
          run: () => settings.focusMode = !settings.focusMode,
        ),
        PaletteAction(
          label: settings.typewriter ? '关闭打字机模式' : '开启打字机模式',
          icon: Icons.vertical_align_center_rounded,
          run: () => settings.typewriter = !settings.typewriter,
        ),
        PaletteAction(
          label: '复制当前笔记的 Markdown',
          icon: Icons.content_copy_rounded,
          run: () async {
            final String md = notes.exportSelectedMarkdown();
            if (md.isEmpty) return;
            await Clipboard.setData(ClipboardData(text: md));
            _toast('已复制 Markdown 到剪贴板');
          },
        ),
        if (notes.supportsNativeFiles)
          PaletteAction(
            label: '打开笔记库文件夹',
            icon: Icons.folder_open_outlined,
            run: () => notes.revealVault(),
          ),
        PaletteAction(
          label: '从磁盘重新载入',
          icon: Icons.refresh_rounded,
          run: () => notes.refresh(),
        ),
        PaletteAction(
          label: '打开设置',
          icon: Icons.settings_outlined,
          hint: 'Ctrl + ,',
          run: () => showSettingsDialog(context),
        ),
      ],
    );
  }

  Map<ShortcutActivator, VoidCallback> _globalShortcuts() {
    final NotesController notes = context.read<NotesController>();
    final SettingsController settings = context.read<SettingsController>();
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): _createNote,
      const SingleActivator(LogicalKeyboardKey.keyP, control: true): _openPalette,
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
          showSettingsDialog(context),
      const SingleActivator(LogicalKeyboardKey.backslash, control: true): () =>
          settings.sidebarCollapsed = !settings.sidebarCollapsed,
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

    return CallbackShortcuts(
      bindings: _globalShortcuts(),
      child: Focus(
        focusNode: _shellFocus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: p.canvas,
          body: Column(
            children: <Widget>[
              if (notes.error != null) _ErrorBanner(message: notes.error!),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (!zen) ...<Widget>[
                      AppSidebar(
                        onOpenSettings: () => showSettingsDialog(context),
                        onOpenPalette: _openPalette,
                        onToggleCollapsed: () =>
                            settings.sidebarCollapsed = !settings.sidebarCollapsed,
                      ),
                      ResizeHandle(
                        width: 5,
                        onDelta: (double d) =>
                            settings.listWidth = settings.listWidth + d,
                      ),
                      SizedBox(
                        width: zen ? 0 : settings.listWidth,
                        child: NoteListPanel(
                          onCreateNote: _createNote,
                          onDeleteNote: _confirmDelete,
                          onOpenPalette: _openPalette,
                        ),
                      ),
                      Container(width: 1, color: p.outline),
                    ],
                    Expanded(
                      child: EditorPane(
                        key: _editorKey,
                        onDelete: _confirmDelete,
                        onToast: _toast,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
          Icon(Icons.error_outline_rounded, size: 15, color: p.danger),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12.5, color: p.danger),
            ),
          ),
          AppIconButton(
            icon: Icons.close_rounded,
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
