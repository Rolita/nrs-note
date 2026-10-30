import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../core/app_enums.dart';
import '../../core/platform/drop_support.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../data/storage/canvas_store.dart';
import '../../data/storage/note_store.dart';
import '../../state/canvas_controller.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';
import '../common/notices.dart';
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
    required this.onDeleteFolder,
    required this.onSwitchView,
    required this.onRevealOffset,
    this.onOpenNote,
    this.onOpenCanvas,
    this.onDeleteCanvas,
    this.onOpenFile,
    this.onSplit,
    this.onClosePane,
  });

  final SidebarView view;
  final VoidCallback onCreateNote;
  final void Function(List<Note> notes) onDeleteNotes;

  /// Deletes a folder after its own confirmation; true when the tree should
  /// forget the folder and the notes that lived there.
  final Future<bool> Function(String folderPath) onDeleteFolder;
  final ValueChanged<SidebarView> onSwitchView;

  /// 点开一篇笔记。外壳要做的不只是选中：主区可能正停在图谱或白板上，
  /// 只换选中的那篇而不切视图，用户看到的就是「点了没反应」。
  final ValueChanged<Note>? onOpenNote;

  /// Asks the editor to scroll to a body offset after a search result opened
  /// its note — the panel has no handle on the editor, the shell does.
  final ValueChanged<int> onRevealOffset;

  /// 文件树里点开一块白板 / 一个附件。白板要切到白板视图，附件交给系统，
  /// 两件事都只有外壳能做。
  final ValueChanged<CanvasRef>? onOpenCanvas;

  /// 文件树里右键白板点了「删除」。确认与移入回收站都在外壳里做。
  final ValueChanged<List<CanvasRef>>? onDeleteCanvas;

  final ValueChanged<VaultFile>? onOpenFile;

  /// 把这个格子上下切成两半。`null` = 侧边栏没有分块（比如单独预览时）。
  ///
  /// 分割本身是外壳的事：它持有那棵树。面板只负责给一个按钮。
  final VoidCallback? onSplit;

  /// 关掉这一格。`null` = 只剩这一格了，没得关。
  final VoidCallback? onClosePane;

  @override
  State<NoteListPanel> createState() => NoteListPanelState();
}

class NoteListPanelState extends State<NoteListPanel> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final GlobalKey<VaultTreeState> _treeKey = GlobalKey<VaultTreeState>();

  /// Mirrors [VaultTreeState.allExpanded] so the toolbar button can flip its
  /// own label without waiting for a rebuild to read the tree.
  ///
  /// 从 false 开始：树在启动时是全折叠的（见 `VaultTreeState._seedIfReady`），
  /// 按钮第一次出现时该提供的是「全部展开」。
  bool _allExpanded = false;

  /// Result groups the user folded shut, by note id. Search results stay open
  /// by default — a result you have to open is a result you did not find.
  final Set<String> _collapsedResults = <String>{};

  /// True while a file is being dragged over the list, so the panel can show
  /// where it will land before the user lets go.
  bool _dropping = false;

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

  /// One click, one folder — and then straight into renaming it.
  ///
  /// 建在库根，建完立刻把这一行变成输入框：名字是下一个动作，中间再要求
  /// 用户去点一下（或按 F2）就是多一道手续。名字不想要，Esc 就退回
  /// 「新建文件夹」。
  Future<void> _createFolder() async {
    final NotesController notes = context.read<NotesController>();
    final String? path = await notes.createFolder('新建文件夹');
    if (!mounted || path == null) return;
    _treeKey.currentState?.startRenameFolder(path);
  }

  /// Brings [folderPath] into view; used by the template picker's empty state.
  void revealFolder(String folderPath) =>
      _treeKey.currentState?.revealFolder(folderPath);

  // -------------------------------------------------------------------- drop

  void _setDropping(bool value) {
    if (!mounted || _dropping == value) return;
    setState(() => _dropping = value);
  }

  /// Turns the `.md` files in a drop into notes.
  ///
  /// The files are read outside the vault and written back in as new notes, so
  /// nothing that is already there can be replaced — a name in the way gets the
  /// ` 2` rule. Anything that is not a `.md` is skipped and counted.
  Future<void> _onDropFiles(PerformDropEvent event) async {
    final List<String> paths = <String>[];
    for (final DropItem item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null || !reader.canProvide(Formats.fileUri)) continue;
      // 拖放期间不能 await 平台通道，读取只能是回调式的；包一层 Completer
      // 才能按顺序把一份拖放的几个文件都读完。
      final Completer<String?> done = Completer<String?>();
      reader.getValue<Uri>(
        Formats.fileUri,
        (Uri? uri) {
          if (done.isCompleted) return;
          if (uri == null || uri.scheme != 'file') {
            done.complete(null);
            return;
          }
          try {
            done.complete(uri.toFilePath());
          } on UnsupportedError {
            done.complete(null);
          }
        },
        onError: (Object error) {
          if (!done.isCompleted) done.complete(null);
        },
      );
      final String? path = await done.future;
      if (path != null) paths.add(path);
    }
    _setDropping(false);
    if (!mounted || paths.isEmpty) return;

    final NotesController notes = context.read<NotesController>();
    final ({int imported, int refused, List<String> paths}) result = await notes
        .importMarkdownFiles(paths);
    if (!mounted) return;

    final int skipped = result.refused;
    NoticeScope.maybeOf(context)?.show(
      NoticeData(
        message: result.imported == 0
            ? '没有可导入的文件'
            : '已导入 ${result.imported} 篇笔记',
        detail: result.imported == 0
            ? '只能拖入 .md 笔记文件'
            : (skipped == 0 ? null : '$skipped 个文件不是 .md，已跳过'),
        kind: result.imported == 0 ? NoticeKind.info : NoticeKind.success,
      ),
    );
  }

  /// The list, made droppable.
  ///
  /// Only `file://` is claimed here: text and links dragged over the sidebar
  /// belong to the editor, and a region that accepted everything would swallow
  /// them on the way past.
  Widget _dropTarget(AppPalette p, Widget child) {
    final Widget stack = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child,
        if (_dropping) IgnorePointer(child: _DropHighlight(palette: p)),
      ],
    );
    // `flutter test` has no native drag layer; building the region there
    // throws asynchronously, so it is simply not built.
    if (!systemDragAndDropAvailable) return stack;
    return DropRegion(
      formats: const <DataFormat>[Formats.fileUri],
      hitTestBehavior: HitTestBehavior.translucent,
      onDropOver: (DropOverEvent event) => DropOperation.copy,
      onDropEnter: (_) => _setDropping(true),
      onDropLeave: (_) => _setDropping(false),
      onDropEnded: (_) => _setDropping(false),
      onPerformDrop: _onDropFiles,
      child: stack,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.read<NotesController>();
    if (widget.view == SidebarView.files) {
      // 文件树只跟结构变化、选中项与筛选条件走。正文输入不改变这些值，
      // 因此不再重建整棵树；每行的任务徽标由行内单独订阅。
      context.select<NotesController, (int, String?, String, bool, SortMode)>(
        (NotesController n) => (
          n.structureRevision,
          n.selectedId,
          n.query,
          n.caseSensitive,
          n.sortMode,
        ),
      );
    } else {
      // 搜索与标签视图的列表内容直接来自正文，仍按整个控制器订阅。
      context.watch<NotesController>();
    }
    final SettingsController settings = context.watch<SettingsController>();
    final List<Note> visible = notes.visibleNotes;

    // The field mirrors the query, including when the query was set from
    // outside — clicking a `#tag` in the editor types `tag:#入门` here, and a
    // field that kept the old text while the list changed underneath it would
    // look broken. While the user types, `text == query` already, so this never
    // fights the caret.
    if (_search.text != notes.query) {
      _search.value = TextEditingValue(
        text: notes.query,
        selection: TextSelection.collapsed(offset: notes.query.length),
      );
    }

    return Container(
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.view == SidebarView.files) ...<Widget>[
            _fileHeader(p, notes, settings),
            Divider(height: 1, color: p.outlineSoft),
            Expanded(
              child: _dropTarget(
                p,
                VaultTree(
                  key: _treeKey,
                  notes: notes,
                  canvases: context.watch<CanvasController>().canvases,
                  files: notes.files,
                  activeCanvasPath: context.watch<CanvasController>().path,
                  onOpenCanvas: widget.onOpenCanvas,
                  onDeleteCanvas: widget.onDeleteCanvas,
                  onOpenFile: widget.onOpenFile,
                  onOpenNote: (Note note) {
                    if (widget.onOpenNote != null) {
                      widget.onOpenNote!(note);
                    } else {
                      notes.select(note.id);
                    }
                  },
                  onDeleteNotes: widget.onDeleteNotes,
                  onDeleteFolder: widget.onDeleteFolder,
                  onAllExpandedChanged: (bool all) {
                    if (!mounted || all == _allExpanded) return;
                    setState(() => _allExpanded = all);
                  },
                ),
              ),
            ),
          ] else if (widget.view == SidebarView.search) ...<Widget>[
            _searchField(p, notes),
            if (notes.isFiltered)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md + 2,
                  0,
                  AppSpace.xs,
                  AppSpace.xs,
                ),
                child: Row(
                  children: <Widget>[
                    Text(
                      '${visible.length} 项结果',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: p.textTertiary,
                      ),
                    ),
                    const Spacer(),
                    _SortButton(
                      settings: settings,
                      notes: notes,
                      showLabel: true,
                    ),
                  ],
                ),
              ),
            Expanded(child: _dropTarget(p, _searchResults(p, notes))),
          ] else ...<Widget>[
            _panelHeader(p, '标签', notes, count: '${notes.tags.length}'),
            Divider(height: 1, color: p.outlineSoft),
            Expanded(child: _dropTarget(p, _tags(p, notes))),
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

  /// The file view's header.
  ///
  /// It used to be a 40px strip of five bare icons with no label above it —
  /// five shapes the eye had to decode every time it entered the panel. Folding
  /// them into the 32px header the other two views already use gives the panel
  /// a name, a count, and a place for its actions without spending a second
  /// row on chrome.
  Widget _fileHeader(
    AppPalette p,
    NotesController notes,
    SettingsController settings,
  ) {
    Widget action(
      IconData icon,
      String tooltip,
      VoidCallback? onPressed, {
      String? shortcut,
    }) => AppIconButton(
      icon: icon,
      tooltip: tooltip,
      shortcut: shortcut,
      size: 24,
      iconSize: AppIconSize.sm - 2,
      onPressed: onPressed,
    );

    return _panelHeader(
      p,
      '文件',
      notes,
      count: '${notes.allNotes.length}',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _SortButton(settings: settings, notes: notes),
          // One button, two faces: it always offers the opposite of what the
          // tree is showing right now.
          action(
            _allExpanded
                ? LucideIcons.chevronsDownUp
                : LucideIcons.chevronsUpDown,
            _allExpanded ? '全部收起' : '全部展开',
            () {
              final VaultTreeState? tree = _treeKey.currentState;
              if (tree == null) return;
              if (_allExpanded) {
                tree.collapseAll();
              } else {
                tree.expandAll();
              }
            },
          ),
          action(LucideIcons.folderPlus, '新建文件夹', _createFolder),
          action(
            LucideIcons.filePlus2,
            '新建笔记',
            widget.onCreateNote,
            shortcut: 'Ctrl+N',
          ),
        ],
      ),
    );
  }

  Widget _panelHeader(
    AppPalette p,
    String label,
    NotesController notes, {
    String? count,
    Widget? trailing,
  }) {
    return SizedBox(
      height: AppLayout.panelHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.xs, 0),
        child: Row(
          children: <Widget>[
            // The label and its count share the whole space the actions leave,
            // inside one Expanded. A bare `Flexible` beside a `Spacer` would
            // split the free space between them instead — and the label's
            // unused half would strand the actions ~55px off the right edge.
            // Flexible inside, because at the panel's minimum width the label
            // must give up its last glyph rather than push the buttons out.
            Expanded(
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
                  if (count != null) ...<Widget>[
                    const SizedBox(width: AppSpace.xs + 2),
                    Text(
                      count,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ?trailing,
            // 分块的两个入口。放在所有视图共用的头部里，而不是各视图自己
            // 加一遍——「这一格怎么分」和「这一格显示什么」是两件事。
            if (widget.onSplit != null)
              AppIconButton(
                icon: LucideIcons.rows2,
                tooltip: '上下分割',
                size: 24,
                iconSize: AppIconSize.sm - 2,
                onPressed: widget.onSplit,
              ),
            if (widget.onClosePane != null)
              AppIconButton(
                icon: LucideIcons.x,
                tooltip: '关掉这一格',
                size: 24,
                iconSize: AppIconSize.sm - 2,
                onPressed: widget.onClosePane,
              ),
            if (notes.isFiltered) ...<Widget>[
              const SizedBox(width: AppSpace.sm),
              AppTextButton(
                label: '清空',
                icon: LucideIcons.filterX,
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

  Widget _searchField(AppPalette p, NotesController notes) {
    final bool focused = _searchFocus.hasFocus;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.sm),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        height: AppLayout.fieldHeight,
        decoration: BoxDecoration(
          // Three signals on focus, because one is not enough to find: the
          // fill warms to the accent wash, the border goes full accent, and a
          // 2px ring lifts the field off the panel. A colour change alone was
          // invisible against the sidebar's own grey.
          color: focused ? p.accentSoft : p.surfaceRaised,
          borderRadius: AppRadius.mdAll,
          border: Border.all(color: focused ? p.accent : p.outline),
          boxShadow: focused
              ? <BoxShadow>[
                  BoxShadow(
                    color: p.accent.withValues(alpha: 0.18),
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: <Widget>[
            const SizedBox(width: AppSpace.sm),
            Icon(
              LucideIcons.search,
              size: AppIconSize.sm,
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
                  hintStyle: TextStyle(
                    fontSize: AppText.ui,
                    color: p.textTertiary,
                  ),
                ),
              ),
            ),
            if (notes.query.isNotEmpty)
              AppIconButton(
                icon: LucideIcons.x,
                tooltip: '清除',
                size: 24,
                iconSize: AppIconSize.xs,
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
            const SizedBox(width: AppSpace.xs),
          ],
        ),
      ),
    );
  }

  Widget _searchResults(AppPalette p, NotesController notes) {
    // Nothing asked yet — no query, no tag — so the panel waits with a hint
    // rather than listing the whole vault, which would just be the file tree
    // over again.
    if (!notes.isFiltered) {
      return const EmptyState(
        compact: true,
        icon: LucideIcons.search,
        title: '搜索笔记',
        message: '输入关键词 —— 标题、正文和 #标签 都会被搜到。',
      );
    }

    final List<SearchHit> hits = notes.searchHits;
    if (hits.isEmpty) {
      if (notes.allNotes.isEmpty) {
        return EmptyState(
          compact: true,
          icon: LucideIcons.notebookPen,
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
          style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      itemCount: hits.length,
      itemBuilder: (BuildContext context, int i) {
        final SearchHit hit = hits[i];
        final String id = hit.note.id;
        return _SearchResultGroup(
          hit: hit,
          selected: id == notes.selectedId,
          collapsed: _collapsedResults.contains(id),
          onToggle: () => setState(() {
            if (!_collapsedResults.remove(id)) _collapsedResults.add(id);
          }),
          onOpen: (int offset) {
            notes.setActiveFolder(hit.note.folderPath);
            // 搜索结果也要切回正文：否则从图谱 / 白板搜到一篇，点开只有
            // 侧栏的高亮变了，屏幕上还是那张图。
            if (widget.onOpenNote != null) {
              widget.onOpenNote!(hit.note);
            } else {
              notes.select(id);
            }
            widget.onRevealOffset(offset);
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
          style: TextStyle(fontSize: 11.5, height: 1.7, color: p.textTertiary),
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
                border: selected
                    ? Border(left: BorderSide(color: p.accent, width: 2))
                    : null,
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
                        fontWeight: selected
                            ? FontWeight.w500
                            : FontWeight.w400,
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
          _WordTotal(p: p),
          const Spacer(),
          if (notes.isFiltered)
            Text(
              '筛选出 $visibleCount 篇',
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
              ),
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

/// 底部「共 N 字」。
///
/// 字数随正文输入变化，但它只是一个小文本：单独订阅字数总和，
/// 避免为了这一个数字把整个文件树一起重建。
class _WordTotal extends StatelessWidget {
  const _WordTotal({required this.p});

  final AppPalette p;

  @override
  Widget build(BuildContext context) {
    final int words = context.select<NotesController, int>(
      (NotesController notes) => notes.totalWords,
    );
    return Text(
      '共 ${NoteListPanelState._compact(words)} 字',
      style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
    );
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

/// One file's worth of search results: a header you can fold, and a card per
/// matching line.
///
/// Grouping by file is what makes a multi-match search readable: ten mentions
/// of a tag across three notes is three groups, not ten rows that all start with
/// the same name. The number on the right is how many lines matched, so the
/// header is a summary before it is a control.
class _SearchResultGroup extends StatelessWidget {
  const _SearchResultGroup({
    required this.hit,
    required this.selected,
    required this.collapsed,
    required this.onToggle,
    required this.onOpen,
  });

  final SearchHit hit;
  final bool selected;
  final bool collapsed;
  final VoidCallback onToggle;

  /// Opens the note and jumps to the body offset of the snippet that was hit.
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // The file name, not the title: this is a list of files, and the `.md` is
    // the only part of the name the editor never shows.
    final String raw = hit.note.fileName.isNotEmpty
        ? hit.note.fileName
        : hit.note.title;
    final String name = raw
        .replaceFirst(RegExp(r'\.md$', caseSensitive: false), '')
        .trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        HoverBuilder(
          cursor: SystemMouseCursors.click,
          builder: (BuildContext context, bool hovered) => GestureDetector(
            onTap: onToggle,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: AppLayout.rowHeight + 2,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs + 1),
              child: Row(
                children: <Widget>[
                  AnimatedRotation(
                    turns: collapsed ? -0.25 : 0,
                    duration: AppMotion.fast,
                    child: Icon(
                      LucideIcons.chevronDown,
                      size: AppIconSize.sm,
                      color: hovered ? p.textSecondary : p.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      name.isEmpty ? '未命名' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        // Never the accent: amber is for the thing being
                        // searched, not for the file it happens to be in.
                        color: selected || hovered
                            ? p.textPrimary
                            : p.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${hit.matchCount}',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
        if (!collapsed)
          for (final SearchSnippet snippet in hit.snippets)
            _SnippetCard(
              snippet: snippet,
              onTap: () => onOpen(snippet.matchOffset),
            ),
      ],
    );
  }
}

/// One matching line.
///
/// The highlight stays neutral until the pointer is on the card: a page of
/// results where every match glows yellow reads as an alarm, and the eye has no
/// way to tell which one it is about to click. Hover turns the one under the
/// pointer into the accent colour.
class _SnippetCard extends StatefulWidget {
  const _SnippetCard({required this.snippet, required this.onTap});

  final SearchSnippet snippet;
  final VoidCallback onTap;

  @override
  State<_SnippetCard> createState() => _SnippetCardState();
}

class _SnippetCardState extends State<_SnippetCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md + 4,
        0,
        AppSpace.xs + 2,
        AppSpace.xs,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
            decoration: BoxDecoration(
              color: _hovered
                  ? p.surfaceRaised
                  : p.surfaceRaised.withValues(alpha: 0.55),
              borderRadius: AppRadius.smAll,
              border: Border.all(color: p.outlineSoft),
            ),
            child: Text.rich(
              _span(p),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.caption,
                height: 1.55,
                color: p.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  TextSpan _span(AppPalette p) {
    final SearchSnippet snippet = widget.snippet;
    if (!snippet.hasHighlight) return TextSpan(text: snippet.text);
    return TextSpan(
      children: <InlineSpan>[
        TextSpan(text: snippet.text.substring(0, snippet.matchStart)),
        TextSpan(
          text: snippet.text.substring(snippet.matchStart, snippet.matchEnd),
          style: TextStyle(
            // 命中词一出现就着色，不用等鼠标移上去；正文里的搜索色带也用
            // 同一组 accentSoft / accent，两边看起来是同一个紫。
            backgroundColor: p.accentSoft,
            color: p.accent,
            fontWeight: FontWeight.w500,
          ),
        ),
        TextSpan(text: snippet.text.substring(snippet.matchEnd)),
      ],
    );
  }
}

/// Sort icon + the six modes, grouped by what they sort on.
class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.settings,
    required this.notes,
    this.showLabel = false,
  });

  final SettingsController settings;
  final NotesController notes;

  /// Show the current mode's name beside the glyph — the search panel has room
  /// for it and a bare icon does not say *what* the results are ordered by.
  final bool showLabel;

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
      child: _SortTrigger(showLabel: showLabel, label: settings.sort.label),
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
                ? Icon(LucideIcons.check, size: 15, color: p.accent)
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
  const _SortTrigger({this.showLabel = false, this.label = ''});

  final bool showLabel;
  final String label;

  @override
  State<_SortTrigger> createState() => _SortTriggerState();
}

class _SortTriggerState extends State<_SortTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color foreground = _hovered ? p.textPrimary : p.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        height: widget.showLabel ? 22 : 24,
        width: widget.showLabel ? null : 24,
        padding: widget.showLabel
            ? const EdgeInsets.symmetric(horizontal: 5)
            : null,
        decoration: BoxDecoration(
          color: _hovered ? p.surfaceRaised : Colors.transparent,
          borderRadius: AppRadius.smAll,
        ),
        child: widget.showLabel
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: _hovered ? p.textSecondary : p.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    LucideIcons.chevronsUpDown,
                    size: AppIconSize.xs,
                    color: _hovered ? p.textSecondary : p.textTertiary,
                  ),
                ],
              )
            : Icon(
                LucideIcons.arrowUpDown,
                size: AppIconSize.sm - 2,
                color: foreground,
              ),
      ),
    );
  }
}

/// What the list looks like while a `.md` is being dragged over it.
///
/// The whole column is tinted rather than one row, because a drop lands in the
/// folder you are standing in, not at the pointer: promising a position the drop
/// will not honour is worse than promising none.
class _DropHighlight extends StatelessWidget {
  const _DropHighlight({required this.palette});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: palette.accent.withValues(alpha: 0.45),
          width: 1.5,
        ),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
        decoration: BoxDecoration(
          color: palette.surfaceRaised,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: palette.outline),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: palette.shadow,
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LucideIcons.fileDown, size: 18, color: palette.accent),
            const SizedBox(height: 6),
            Text(
              '松手导入',
              style: TextStyle(
                fontSize: AppText.caption,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '只收 .md · 同名自动编号',
              style: TextStyle(fontSize: 10, color: palette.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
