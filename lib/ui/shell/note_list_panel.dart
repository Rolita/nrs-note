import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';
import 'note_list_tile.dart';

/// The middle column: search, filter chips and the note list itself.
class NoteListPanel extends StatefulWidget {
  const NoteListPanel({
    super.key,
    required this.onCreateNote,
    required this.onDeleteNote,
    required this.onOpenPalette,
  });

  final VoidCallback onCreateNote;
  final void Function(Note note) onDeleteNote;
  final VoidCallback onOpenPalette;

  @override
  State<NoteListPanel> createState() => _NoteListPanelState();
}

class _NoteListPanelState extends State<NoteListPanel> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _search.text = context.read<NotesController>().query;
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncScrollToSelection(List<Note> visible) {
    final String? id = context.read<NotesController>().selectedId;
    if (id == null) return;
    final int index = visible.indexWhere((Note n) => n.id == id);
    if (index < 0) return;
    // Approximate row height — good enough to keep the selection on screen.
    const double approx = 108;
    final double target = index * approx;
    if (!_scroll.hasClients) return;
    final double viewStart = _scroll.offset;
    final double viewEnd = viewStart + _scroll.position.viewportDimension;
    if (target < viewStart || target + approx > viewEnd) {
      _scroll.animateTo(
        (target - 60).clamp(0, _scroll.position.maxScrollExtent),
        duration: AppMotion.base,
        curve: AppMotion.enter,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();
    final SettingsController settings = context.watch<SettingsController>();
    final List<Note> visible = notes.visibleNotes;

    if (_search.text != notes.query && !_searchFocus.hasFocus) {
      _search.text = notes.query;
    }

    return Container(
      color: p.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(p, notes, settings),
          if (notes.isFiltered) _filterBar(p, notes),
          Divider(height: 1, color: p.outlineSoft),
          Expanded(
            child: visible.isEmpty
                ? _empty(p, notes)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                    itemCount: visible.length,
                    itemBuilder: (BuildContext context, int i) {
                      final Note note = visible[i];
                      return NoteListTile(
                        note: note,
                        selected: note.id == notes.selectedId,
                        query: notes.query,
                        onTap: () {
                          notes.select(note.id);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _syncScrollToSelection(visible);
                          });
                        },
                        onTogglePin: () => notes.togglePinned(note),
                        onToggleFavorite: () => notes.toggleFavorite(note),
                        onDelete: () => widget.onDeleteNote(note),
                      );
                    },
                  ),
          ),
          Divider(height: 1, color: p.outlineSoft),
          _footer(p, notes, visible.length),
        ],
      ),
    );
  }

  Widget _header(
    AppPalette p,
    NotesController notes,
    SettingsController settings,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.md, AppSpace.sm, AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: _searchField(p, notes),
              ),
              const SizedBox(width: AppSpace.xs),
              Tooltip(
                message: '新建笔记  ·  Ctrl+N',
                child: GestureDetector(
                  onTap: widget.onCreateNote,
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: AppRadius.mdAll,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: p.accent.withValues(alpha: 0.28),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Icon(
                      Icons.add_rounded,
                      size: 18,
                      color: p.onAccent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: <Widget>[
              Text(
                _title(notes),
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: p.textSecondary,
                ),
              ),
              const Spacer(),
              _SortButton(settings: settings, notes: notes),
            ],
          ),
        ],
      ),
    );
  }

  String _title(NotesController notes) {
    if (notes.activeTag != null) return '#${notes.activeTag}';
    return notes.scope.label;
  }

  Widget _searchField(AppPalette p, NotesController notes) {
    final bool focused = _searchFocus.hasFocus;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: focused ? p.surfaceRaised : p.surfaceSunken,
        borderRadius: AppRadius.mdAll,
        border: Border.all(
          color: focused ? p.accent.withValues(alpha: 0.5) : p.outlineSoft,
          width: focused ? 1.3 : 1,
        ),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 10),
          Icon(
            Icons.search_rounded,
            size: 15,
            color: focused ? p.accent : p.textTertiary,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: notes.setQuery,
              cursorColor: p.accent,
              cursorWidth: 1.4,
              style: TextStyle(
                fontSize: 13,
                color: p.textPrimary,
                height: 1.2,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '搜索标题、正文或标签',
                hintStyle: TextStyle(fontSize: 12.5, color: p.textTertiary),
              ),
            ),
          ),
          if (notes.query.isNotEmpty)
            AppIconButton(
              icon: Icons.close_rounded,
              tooltip: '清除',
              size: 24,
              iconSize: 13,
              onPressed: () {
                _search.clear();
                notes.setQuery('');
              },
            ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _filterBar(AppPalette p, NotesController notes) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpace.md,
        right: AppSpace.sm,
        bottom: AppSpace.sm,
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (notes.scope != NoteScope.all)
            TagPill(
              label: notes.scope.label,
              selected: true,
              onTap: () => notes.setScope(NoteScope.all),
              onRemove: () => notes.setScope(NoteScope.all),
            ),
          if (notes.activeTag != null)
            TagPill(
              label: '#${notes.activeTag}',
              selected: true,
              onTap: () => notes.toggleTag(notes.activeTag!),
              onRemove: () => notes.toggleTag(notes.activeTag!),
            ),
          if (notes.query.isNotEmpty)
            TagPill(
              label: '"${notes.query}"',
              selected: true,
              onTap: () {
                _search.clear();
                notes.setQuery('');
              },
              onRemove: () {
                _search.clear();
                notes.setQuery('');
              },
            ),
        ],
      ),
    );
  }

  Widget _empty(AppPalette p, NotesController notes) {
    if (notes.allNotes.isEmpty) {
      return EmptyState(
        icon: Icons.edit_note_rounded,
        title: '笔记库还是空的',
        message: '写下第一个念头 —— 它会立刻变成一个可以被任何编辑器打开的 .md 文件。',
        action: FilledButton.icon(
          onPressed: widget.onCreateNote,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('新建笔记'),
        ),
      );
    }
    return EmptyState(
      compact: true,
      icon: Icons.search_off_rounded,
      title: '没有匹配的笔记',
      message: '试试别的关键词,或者清空当前的筛选条件。',
      action: AppTextButton(
        label: '清空筛选',
        icon: Icons.filter_alt_off_outlined,
        onPressed: notes.clearFilters,
      ),
    );
  }

  Widget _footer(AppPalette p, NotesController notes, int visibleCount) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      child: Row(
        children: <Widget>[
          Text(
            '${notes.allNotes.length} 篇笔记',
            style: TextStyle(fontSize: 10.5, color: p.textTertiary),
          ),
          const SizedBox(width: 10),
          Container(width: 1, height: 10, color: p.outlineSoft),
          const SizedBox(width: 10),
          Text(
            '共 ${_compact(notes.totalWords)} 字',
            style: TextStyle(fontSize: 10.5, color: p.textTertiary),
          ),
          const Spacer(),
          if (notes.isFiltered)
            Text(
              '筛选出 $visibleCount 篇',
              style: TextStyle(fontSize: 10.5, color: p.textTertiary),
            ),
        ],
      ),
    );
  }

  static String _compact(int value) {
    if (value < 1000) return '$value';
    if (value < 10000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '${(value / 10000).toStringAsFixed(1)} 万';
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.settings, required this.notes});

  final SettingsController settings;
  final NotesController notes;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return PopupMenuButton<SortMode>(
      tooltip: '排序方式',
      position: PopupMenuPosition.under,
      color: p.surfaceRaised,
      onSelected: (SortMode mode) {
        settings.sort = mode;
        notes.sortMode = mode;
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<SortMode>>[
        for (final SortMode mode in SortMode.values)
          PopupMenuItem<SortMode>(
            value: mode,
            height: 36,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 22,
                  child: settings.sort == mode
                      ? Icon(Icons.check_rounded, size: 15, color: p.accent)
                      : null,
                ),
                Text(
                  mode.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: p.textPrimary,
                    fontWeight: settings.sort == mode
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) => Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          decoration: BoxDecoration(
            color: hovered ? p.surfaceRaised : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.swap_vert_rounded,
                size: 14,
                color: hovered ? p.textSecondary : p.textTertiary,
              ),
              const SizedBox(width: 5),
              Text(
                settings.sort.label,
                style: TextStyle(
                  fontSize: 11.5,
                  color: hovered ? p.textSecondary : p.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
