import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';
import 'vault_tree.dart';

/// The switchable middle sidebar.
///
/// Files is a real directory tree; search looks the vault up by name and shows
/// the matches as a plain list; tags lists every tag in the vault. The rail on
/// its left decides which one is on screen.
class NoteListPanel extends StatefulWidget {
  const NoteListPanel({
    super.key,
    required this.view,
    required this.onCreateNote,
    required this.onDeleteNotes,
    required this.onSwitchView,
    required this.onToast,
  });

  final SidebarView view;
  final VoidCallback onCreateNote;
  final void Function(List<Note> notes) onDeleteNotes;
  final ValueChanged<SidebarView> onSwitchView;
  final void Function(String message) onToast;

  @override
  State<NoteListPanel> createState() => NoteListPanelState();
}

class NoteListPanelState extends State<NoteListPanel> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey<VaultTreeState> _treeKey = GlobalKey<VaultTreeState>();

  /// Mirrors [VaultTreeState.allExpanded] so the toolbar button can flip its
  /// own label without waiting for a rebuild to read the tree.
  bool _allExpanded = true;

  @override
  void initState() {
    super.initState();
    _search.text = context.read<NotesController>().query;
  }

  @override
  void didUpdateWidget(covariant NoteListPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.view == SidebarView.search &&
        oldWidget.view != SidebarView.search) {
      _focusSearchSoon();
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void focusSearch() {
    if (widget.view != SidebarView.search) {
      widget.onSwitchView(SidebarView.search);
    }
    _focusSearchSoon();
  }

  void _focusSearchSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocus.requestFocus();
      _search.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _search.text.length,
      );
    });
  }

  void _openSearch() {
    if (widget.view == SidebarView.search) {
      focusSearch();
    } else {
      widget.onSwitchView(SidebarView.search);
    }
  }

  /// One click, one folder — the name is picked up later with F2 / 右键重命名,
  /// the same way an untitled note starts life as 「未命名」.
  Future<void> _createFolder() async {
    final NotesController notes = context.read<NotesController>();
    final String? path = await notes.createFolder('新建文件夹');
    if (!mounted) return;
    if (path == null) {
      widget.onToast('文件夹名称无效');
      return;
    }
    _treeKey.currentState?.revealFolder(path);
    widget.onToast('已创建文件夹「${path.split('/').last}」');
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
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.view == SidebarView.files) ...<Widget>[
            _fileToolbar(p, notes, settings),
            Divider(height: 1, color: p.outlineSoft),
            Expanded(
              child: VaultTree(
                key: _treeKey,
                notes: notes,
                onOpenNote: (Note note) => notes.select(note.id),
                onDeleteNotes: widget.onDeleteNotes,
                onAllExpandedChanged: (bool all) {
                  if (!mounted || all == _allExpanded) return;
                  setState(() => _allExpanded = all);
                },
              ),
            ),
          ] else if (widget.view == SidebarView.search) ...<Widget>[
            _searchField(p, notes, settings),
            Expanded(child: _searchResults(p, notes, visible)),
          ] else ...<Widget>[
            _panelHeader(
              p,
              '标签',
              notes,
              trailing: Text(
                '${notes.tags.length}',
                style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
              ),
            ),
            Divider(height: 1, color: p.outlineSoft),
            Expanded(child: _tags(p, notes)),
          ],
          // The search panel is just a field and its answers — no counts bar,
          // the way the rest of the panel stays out of the way too.
          if (widget.view != SidebarView.search) ...<Widget>[
            Divider(height: 1, color: p.outlineSoft),
            _footer(p, notes, visible.length),
          ],
        ],
      ),
    );
  }

  // ----------------------------------------------------------------- toolbar

  Widget _fileToolbar(
    AppPalette p,
    NotesController notes,
    SettingsController settings,
  ) {
    return SizedBox(
      height: AppLayout.toolbarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
        child: Row(
          children: <Widget>[
            AppIconButton(
              icon: Icons.note_add_outlined,
              tooltip: '新建笔记',
              shortcut: 'Ctrl+N',
              onPressed: widget.onCreateNote,
            ),
            AppIconButton(
              icon: Icons.create_new_folder_outlined,
              tooltip: '新建文件夹',
              onPressed: _createFolder,
            ),
            AppIconButton(
              icon: Icons.search_rounded,
              tooltip: '搜索笔记',
              onPressed: _openSearch,
            ),
            _SortButton(settings: settings, notes: notes),
            // One button, two faces: it always offers the opposite of what the
            // tree is showing right now.
            AppIconButton(
              icon: _allExpanded
                  ? Icons.unfold_less_rounded
                  : Icons.unfold_more_rounded,
              tooltip: _allExpanded ? '全部收起' : '全部展开',
              onPressed: () {
                final VaultTreeState? tree = _treeKey.currentState;
                if (tree == null) return;
                if (_allExpanded) {
                  tree.collapseAll();
                } else {
                  tree.expandAll();
                }
              },
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _panelHeader(
    AppPalette p,
    String label,
    NotesController notes, {
    Widget? trailing,
  }) {
    return SizedBox(
      height: AppLayout.panelHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.xs, 0),
        child: Row(
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
            const Spacer(),
            ?trailing,
            if (notes.isFiltered) ...<Widget>[
              const SizedBox(width: AppSpace.sm),
              AppTextButton(
                label: '清空',
                icon: Icons.filter_alt_off_outlined,
                onPressed: () {
                  _search.clear();
                  notes.clearFilters();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _searchField(
    AppPalette p,
    NotesController notes,
    SettingsController settings,
  ) {
    final bool focused = _searchFocus.hasFocus;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.sm),
      child: Container(
        height: AppLayout.fieldHeight,
        decoration: BoxDecoration(
          color: p.surfaceRaised,
          borderRadius: AppRadius.smAll,
          border: Border.all(color: focused ? p.accent : p.outline),
        ),
        child: Row(
          children: <Widget>[
            const SizedBox(width: AppSpace.sm),
            Icon(
              Icons.search_rounded,
              size: 14.5,
              color: focused ? p.accent : p.textTertiary,
            ),
            const SizedBox(width: AppSpace.sm),
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
                  hintText: '输入并开始搜索...',
                  hintStyle: TextStyle(fontSize: AppText.ui, color: p.textTertiary),
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
                  _searchFocus.requestFocus();
                },
              ),
            // The two switches the field carries: how to match, how to order.
            _CaseToggle(
              active: notes.caseSensitive,
              onPressed: () => notes.setCaseSensitive(!notes.caseSensitive),
            ),
            _SortButton(settings: settings, notes: notes),
            const SizedBox(width: AppSpace.xs),
          ],
        ),
      ),
    );
  }

  Widget _searchResults(
    AppPalette p,
    NotesController notes,
    List<Note> visible,
  ) {
    // Nothing asked yet — no query, no tag — so the panel waits with a hint
    // rather than listing the whole vault, which would just be the file tree
    // over again.
    if (!notes.isFiltered) {
      return const EmptyState(
        compact: true,
        icon: Icons.search_rounded,
        title: '搜索笔记',
        message: '输入关键词 —— 标题、正文和 #标签 都会被搜到。',
      );
    }

    if (visible.isEmpty) {
      if (notes.allNotes.isEmpty) {
        return EmptyState(
          compact: true,
          icon: Icons.edit_note_rounded,
          title: '笔记库还是空的',
          message: '写下第一个念头 —— 它会立刻变成一个可以被任何编辑器打开的 .md 文件。',
        );
      }
      // Nothing matched: one quiet line under the field, not a panel full of
      // apology — the next keystroke is the answer.
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.md + 2, 2, AppSpace.md, 0),
        child: Text(
          '未找到匹配结果。',
          style: TextStyle(fontSize: 11.5, color: p.textTertiary),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      itemCount: visible.length,
      itemBuilder: (BuildContext context, int i) {
        final Note note = visible[i];
        final String name = note.title.trim();
        return _SearchResultRow(
          name: name.isEmpty ? '未命名' : name,
          selected: note.id == notes.selectedId,
          onTap: () {
            notes.setActiveFolder(note.folderPath);
            notes.select(note.id);
          },
        );
      },
    );
  }

  Widget _tags(AppPalette p, NotesController notes) {
    final List<TagStat> tags = notes.tags;
    if (tags.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Text(
          '给笔记打上 #标签,\n它们会按使用次数出现在这里。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.7,
            color: p.textTertiary,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xs,
        AppSpace.xs,
        AppSpace.xs,
        AppSpace.xl,
      ),
      itemCount: tags.length,
      itemBuilder: (BuildContext context, int i) {
        final TagStat tag = tags[i];
        final bool selected = notes.activeTag == tag.name;
        return HoverBuilder(
          cursor: SystemMouseCursors.click,
          builder: (BuildContext context, bool hovered) => GestureDetector(
            onTap: () {
              notes.toggleTag(tag.name);
              widget.onSwitchView(SidebarView.search);
            },
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              height: AppLayout.rowHeight,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              decoration: BoxDecoration(
                color: selected
                    ? p.accentSoft
                    : (hovered ? p.surfaceRaised : Colors.transparent),
                borderRadius: AppRadius.smAll,
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    '#',
                    style: TextStyle(
                      fontSize: AppText.ui,
                      fontWeight: FontWeight.w600,
                      color: selected ? p.accent : p.textTertiary,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      tag.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.ui,
                        fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                        color: selected ? p.textPrimary : p.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    '${tag.count}',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _footer(AppPalette p, NotesController notes, int visibleCount) {
    return Container(
      height: AppLayout.footerHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      child: Row(
        children: <Widget>[
          Text(
            '${notes.allNotes.length} 篇笔记',
            style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
          ),
          const SizedBox(width: 10),
          Container(width: 1, height: 10, color: p.outlineSoft),
          const SizedBox(width: 10),
          Text(
            '共 ${_compact(notes.totalWords)} 字',
            style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
          ),
          const Spacer(),
          if (notes.isFiltered)
            Text(
              '筛选出 $visibleCount 篇',
              style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
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

/// The `Aa` switch inside the search field: match case, or ignore it.
class _CaseToggle extends StatelessWidget {
  const _CaseToggle({required this.active, required this.onPressed});

  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) => Tooltip(
        message: active ? '区分大小写' : '忽略大小写',
        child: GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? p.accentSoft
                  : (hovered ? p.surfaceRaised : Colors.transparent),
              borderRadius: AppRadius.smAll,
            ),
            child: Text(
              'Aa',
              style: TextStyle(
                fontSize: 11.5,
                height: 1,
                fontWeight: FontWeight.w600,
                color: active ? p.accent : p.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line of a search: the note's name, nothing else. A result list is a
/// lookup, not a gallery — the note cards belong to the note's own view.
class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) => GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: AppLayout.rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: selected
                  ? p.accentSoft
                  : (hovered ? p.surfaceRaised : Colors.transparent),
              borderRadius: AppRadius.smAll,
            ),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.ui,
                height: 1.2,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                color: selected ? p.textPrimary : p.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sort icon + the six modes, grouped by what they sort on.
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
      offset: const Offset(0, 4),
      color: p.surfaceRaised,
      constraints: const BoxConstraints(minWidth: 236),
      onSelected: (SortMode mode) {
        settings.sort = mode;
        notes.sortMode = mode;
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<SortMode>>[
        _item(p, SortMode.titleAsc),
        _item(p, SortMode.titleDesc),
        const PopupMenuDivider(height: 7),
        _item(p, SortMode.updatedDesc),
        _item(p, SortMode.updatedAsc),
        const PopupMenuDivider(height: 7),
        _item(p, SortMode.createdDesc),
        _item(p, SortMode.createdAsc),
      ],
      child: const _SortTrigger(),
    );
  }

  PopupMenuItem<SortMode> _item(AppPalette p, SortMode mode) {
    final bool active = settings.sort == mode;
    return PopupMenuItem<SortMode>(
      value: mode,
      height: 34,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 22,
            child: active
                ? Icon(Icons.check_rounded, size: 15, color: p.accent)
                : null,
          ),
          Text(
            mode.label,
            style: TextStyle(
              fontSize: AppText.ui,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? p.accent : p.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SortTrigger extends StatefulWidget {
  const _SortTrigger();

  @override
  State<_SortTrigger> createState() => _SortTriggerState();
}

class _SortTriggerState extends State<_SortTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: _hovered ? p.surfaceRaised : Colors.transparent,
          borderRadius: AppRadius.smAll,
        ),
        child: Icon(
          Icons.sort_rounded,
          size: 16.5,
          color: _hovered ? p.textPrimary : p.textSecondary,
        ),
      ),
    );
  }
}
