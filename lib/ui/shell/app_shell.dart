import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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
import 'pane_doc.dart';
import 'pane_drop_zone.dart';
import 'pane_tab_strip.dart';
import 'split_host.dart';
import 'side_layout.dart';
import 'tab_drag.dart';
import 'tab_group.dart';
import 'split_tree.dart';
import 'data_safety_dialogs.dart';
import 'editor_layout.dart';
import 'editor_status_float.dart';
import 'function_rail.dart';
import 'note_list_panel.dart';
import 'settings_page.dart';
import 'title_bar.dart';
import 'title_bar_content.dart';
import 'vault_tree.dart';

/// 设计稿里的极光壁纸，从 `design/shell-refine.html` 原样取出。
const String _kShellWallpaper = 'assets/backgrounds/graphite-wallpaper.jpg';

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
  /// 每个编辑区格子一个 key。
  ///
  /// 和侧边栏同一个理由：分割之后同时有几个 `EditorPane`，共用一个
  /// `GlobalKey` 会直接抛错。按格子的 id 取，重建时才能找回同一个 State
  /// （撤销栈、滚动位置、光标都活在里面）。
  final Map<String, GlobalKey<EditorPaneState>> _editorKeys =
      <String, GlobalKey<EditorPaneState>>{};

  GlobalKey<EditorPaneState> _editorKeyFor(String paneId) =>
      _editorKeys.putIfAbsent(
        paneId,
        () => GlobalKey<EditorPaneState>(debugLabel: 'nrs-editor-$paneId'),
      );

  /// 「聚焦那一格」的 key。大纲、表格工具、搜索跳转都作用在它身上。
  GlobalKey<EditorPaneState> get _editorKey => _editorKeyFor(_editorFocusId);

  final GlobalKey<CanvasBoardState> _canvasKey = GlobalKey<CanvasBoardState>();

  /// 每个侧边栏格子一个 key。
  ///
  /// 不能共用一个 `GlobalKey`：分割之后同时有两个 `NoteListPanel`，同一个
  /// key 挂在两棵子树上会直接抛错。按格子的 id 取，重建时才能找回同一个
  /// State（`revealFolder`、展开状态都活在里面）。
  final Map<String, GlobalKey<NoteListPanelState>> _listKeys =
      <String, GlobalKey<NoteListPanelState>>{};

  GlobalKey<NoteListPanelState> _listKeyFor(String paneId) =>
      _listKeys.putIfAbsent(
        paneId,
        () => GlobalKey<NoteListPanelState>(debugLabel: 'nrs-list-$paneId'),
      );
  final FocusNode _shellFocus = FocusNode(debugLabel: 'nrs-shell');
  final NoticeController _notices = NoticeController();
  final TemplateService _templates = const TemplateService();

  /// The body field's value, republished by [EditorPane] for the table tools.
  /// It lives here so the panel can rebuild on a caret move without rebuilding
  /// the shell around it.
  final ValueNotifier<TextEditingValue> _bodyValue =
      ValueNotifier<TextEditingValue>(const TextEditingValue());

  /// 聚焦格的光标行列，给编辑区右下角的状态浮片读。
  ///
  /// 浮片不挂在某一格里：分屏后点哪格，外壳把同一个 notifier 交给新的活格子，
  /// 浮片内容跟着换、位置不动。只读格拿到的是 `null`，不会两格抢着写。
  final ValueNotifier<EditorCaret> _caret = ValueNotifier<EditorCaret>((
    line: 0,
    column: 1,
  ));

  late final NotesController _notes;
  late final SettingsController _settings;
  late final CanvasController _canvas;

  /// 启动时那块白板文档还在路上，但上次退出时主区正看着它。
  ///
  /// 白板是在 `main` 里等 vault 读完才打开的（`open` 要用 vault 路径），
  /// 那一刻外壳早就建好了。所以这里先记下「打开之后要切过去」，等控制器
  /// 通知「文档来了」再切——否则启动后停在哪一页全看两边谁先跑完。
  bool _pendingCanvasActivate = false;

  /// 两侧边栏共用的一种页（[SidePage]）：文件 / 搜索 / 标签 / 大纲 / 表格 / 图片。
  ///
  /// 左栏和右栏各有一棵分割树，但叶子装的是同一种东西——所以一页能拖到对面
  /// 那一栏去，跨栏拖是搬家不是复印。树从偏好里恢复（[SideLayout]）：分了几
  /// 格、每格排着哪些页、比例多少，下次启动还是原样。
  late SplitNode<TabGroup<SidePage>> _sideTree;

  /// 左栏当前聚焦的那一格。[_showPage] 找不到现成的页时开在它这儿；点哪格
  /// 就改哪格。右栏没有「聚焦」这回事。
  String _sideFocusId = 'side-0';

  /// 新格子的 id 计数器。用递增数字而不是随机：同一会话里不会重，而且
  /// 调试时一眼能看出先后。恢复布局后从存档里最大的序号接着数。
  int _sideSeq = 0;

  /// 侧边栏聚焦那一格的标签组。
  TabGroup<SidePage> get _sideGroup =>
      SplitTree.findLeaf<TabGroup<SidePage>>(_sideTree, _sideFocusId)?.value ??
      SplitTree.firstLeaf<TabGroup<SidePage>>(_sideTree).value;

  /// 右栏的分割树。和左栏同构，两栏的页可以互相搬。
  late SplitNode<TabGroup<SidePage>> _rightTree;

  /// 右栏新格子的 id 计数器，理由同 [_sideSeq]。
  int _rightSeq = 0;

  /// 分割线拖动时合并写盘：一次拖拽会连着来几十个 delta。
  Timer? _layoutSaveTimer;

  /// 有没有哪一格正显示搜索页；正文据此画命中高亮。
  ///
  /// 搜索可以从左栏搬到右栏，所以不能只看左栏聚焦那格。
  bool get _searchOnScreen {
    bool showsSearch(SplitNode<TabGroup<SidePage>> tree) =>
        SplitTree.leaves<TabGroup<SidePage>>(tree).any(
          (SplitLeaf<TabGroup<SidePage>> l) =>
              l.value.current == SidePage.search,
        );
    return showsSearch(_sideTree) ||
        (_settings.rightSidebarVisible && showsSearch(_rightTree));
  }

  /// 偏好里那三颗开关现在指的是哪一页；全关 = 上格没有右栏页。
  ///
  /// 三个 setter 互斥，所以最多只有一个为真。顺序只影响「偏好被手改坏、
  /// 两个同时为真」这种局面，按视觉优先取表格、图片，最后才是大纲。
  RightView? get _rightActiveView {
    if (_settings.tablePanelVisible) return RightView.table;
    if (_settings.imagePanelVisible) return RightView.images;
    if (_settings.outlineVisible) return RightView.outline;
    return null;
  }

  /// 编辑区的分割树。
  ///
  /// 一格里装一个标签组（[TabGroup]，至少一页 [PaneDoc]）：一篇笔记、图谱、
  /// 白板或图片。默认只有一格一页；把标签拖到格子边上才会长成两格——
  /// 分割只走拖拽，没有按钮。
  SplitNode<TabGroup<PaneDoc>> _editorTree = const SplitLeaf<TabGroup<PaneDoc>>(
    id: 'editor-0',
    value: TabGroup<PaneDoc>(<PaneDoc>[NoteDoc(null)], 0),
  );

  /// 编辑区当前聚焦的那一格：笔记格只有它绑草稿、能写。
  String _editorFocusId = 'editor-0';

  /// 编辑区新格子的 id 计数器，理由同 [_sideSeq]。
  int _editorSeq = 0;

  /// 上一次落盘时的树 / 聚焦格 / 活页那一篇。
  ///
  /// 树是不可变的，改一次换一个实例——比 `identical` 就知道布局有没有变，不用
  /// 在十几个 setState 点各调一次保存（漏一个就丢一次布局）。
  SplitNode<TabGroup<PaneDoc>>? _lastSavedEditorTree;
  String? _lastSavedEditorFocus;
  String? _lastSavedLiveNote;

  /// 编辑区布局的写盘防抖：拖分割线会连着来几十个 delta。
  Timer? _editorLayoutTimer;

  /// 读盘还没落地时先搁着的编辑区存档。  ///
  /// `runApp` 在 `bootstrap` 之前跑，首帧的 vault 是空的；这时候拿 `noteById`
  /// 去核存档等于把每一页都当已删除。搁到 `isLoading` 变假再装（见
  /// [_restoreEditorLayout]）。
  EditorLayout? _pendingEditorLayout;

  /// 离开正文时记下的光标 / 选区。
  ///
  /// 设置 / 模板 / 回收站占着格子时，编辑器不在树上，`TextEditingController`
  /// 连同选区一起没了。模板的「插入到光标处」要把这一笔放回去，否则插到文末。
  TextSelection? _stashedSelection;

  /// 正在写的那一篇。交接「活的格子」时用它把原来那格钉住。
  String? get _liveNoteId => _notes.draft?.id ?? _notes.selectedId;

  /// 聚焦那一格的标签组。
  TabGroup<PaneDoc> get _focusGroup =>
      SplitTree.findLeaf<TabGroup<PaneDoc>>(
        _editorTree,
        _editorFocusId,
      )?.value ??
      const TabGroup<PaneDoc>(<PaneDoc>[NoteDoc(null)], 0);

  /// 聚焦那一格当前那一页。
  PaneDoc get _focusDoc => _focusGroup.current;

  /// 主区（聚焦那一格）显示笔记还是图谱。
  ///
  /// 以前是外壳上的一个字段，现在由聚焦那一格的当前页推出来——右侧面板的
  /// 显隐、功能栏的高亮、白板会话里的「是不是正在看它」都读这个。
  MainView get _mainView => _focusDoc.view;

  /// 有没有哪一格**正在显示**这份文档。
  ///
  /// 只看 `current`：一份文档可能只是某格标签组里的一页，没被切到前面——
  /// 那时它没画出来，就该待在停靠区里。
  bool _hasDoc(String identity) =>
      SplitTree.leaves<TabGroup<PaneDoc>>(_editorTree).any(
        (SplitLeaf<TabGroup<PaneDoc>> leaf) =>
            leaf.value.current.identity == identity,
      );

  /// 图谱被打开过（哪怕现在正停靠在停靠区里）。
  ///
  /// 首屏不建图：一次收敛要几十毫秒，而大多数人启动后是来写字的。等第一次
  /// 点开图谱再建，之后就一直挂在树上，切来切去不重建。
  bool _graphAlive = false;

  /// 图片页正在看的那张图（vault 相对路径），`null` = 图片页没开。
  ///
  /// **所有图片共用这一页**：从文件树点另一张只是换这里的值，不新开一格。
  /// 点 tab 上的 × 才把它清掉。
  String? _imagePath;

  /// 三个单例文档的 key。
  ///
  /// 它们会在「格子」和「停靠区」之间来回搬（把笔记拖进图谱那一格、或者
  /// 反过来），靠这三个 `GlobalKey` 把 State 一起搬过去——Flutter 允许同一个
  /// key 在**同一帧内**换位置，State 跟着走。没有它，白板一换格视角就复位。
  final GlobalKey<GraphViewState> _graphKey = GlobalKey<GraphViewState>();
  final GlobalKey _imageKey = GlobalKey(debugLabel: 'nrs-image');

  int _cursorLine = 0;
  VoidCallback? _stopVaultSync;

  @override
  void initState() {
    super.initState();
    _notes = context.read<NotesController>();
    _settings = context.read<SettingsController>();
    _canvas = context.read<CanvasController>();
    // 编辑区那棵树也落盘：分了几格、每格排着哪些页、比例多少、哪格是活的。
    //
    // ⛔ **不能在这里直接恢复**。`main.dart` 把 `runApp` 排在 `bootstrap`
    // 之前（三份等待要重叠），所以首帧时 vault 还是空的——此刻 `noteById`
    // 一片 null，照它核一遍就会把用户分好的屏当成「笔记全删了」整棵摘掉，
    // 再把残树写回存档，那才是真的没了。vault 没读完就先搁着，读完再恢复
    // （[_restoreEditorLayout]）。
    final EditorLayout? savedEditor = decodeEditorLayout(
      _settings.editorLayout,
    );
    if (savedEditor != null) {
      if (_notes.isLoading) {
        _pendingEditorLayout = savedEditor;
        _notes.addListener(_restoreEditorLayoutWhenReady);
      } else {
        _restoreEditorLayout(savedEditor);
      }
    }
    _lastSavedEditorTree = _editorTree;
    _lastSavedEditorFocus = _editorFocusId;
    _lastSavedLiveNote = _liveNoteId;
    // 两侧边栏的布局从偏好里回来：分几格、每格排哪些页、比例多少。
    // 存档坏了就退回默认的一格三页（布局是视图状态，不能挡住开窗）。
    final SideLayout left =
        decodeSideLayout(_settings.sideLayout) ?? defaultLeftSideLayout();
    _sideTree = left.root;
    _sideFocusId = left.focusId;
    _sideSeq = nextSideSeq(_sideTree);
    final String? savedRight = _settings.rightLayout;
    final SideLayout right =
        decodeSideLayout(savedRight) ?? defaultRightSideLayout();
    _rightTree = right.root;
    _rightSeq = nextSideSeq(_rightTree);
    final SplitLeaf<TabGroup<SidePage>> rightTop =
        SplitTree.firstLeaf<TabGroup<SidePage>>(_rightTree);
    if (savedRight == null) {
      // 第一次用这套布局：旧版本只存了三颗互斥开关。把上格停在当时开着
      // 的那一页（大纲 / 表格 / 图片），别让升级把用户的面板换掉。
      final RightView? active = _rightActiveView;
      if (active != null) {
        _rightTree = SplitTree.replaceValue<TabGroup<SidePage>>(
          _rightTree,
          rightTop.id,
          rightTop.value.open(SidePage.ofRight(active)),
        );
      }
    } else if (_settings.rightSidebarVisible) {
      // 有布局的：三颗开关只是上格的影子，启动时对齐一次。
      //
      // 只能等首帧之后：`initState` 还在 build 里，这时改设置会
      // `notifyListeners`，Provider 会报「markNeedsBuild during build」。
      final RightView? view = rightTop.value.current.rightView;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (view == null) {
          _settings.clearRightViewFlags();
        } else {
          _settings.rememberRightView(view);
        }
      });
    }
    _notes.onBlankNoteCreated = _applyFolderTemplate;
    // 上次退出时正看着白板：文档由 `main` 恢复，这里只管「来了就切过去」。
    // 路径为 null 时这个标志没有意义（没有白板可切），一并挡掉。
    _pendingCanvasActivate =
        _settings.sessionCanvasActive && _settings.sessionCanvasPath != null;
    _canvas.addListener(_onCanvasChanged);
    // 右栏上格的那排标签和顶栏三颗开关是同一件事：偏好在别处被改（快捷键、
    // 顶栏、测试）时，把上格切到对应的那一页。
    _settings.addListener(_syncRightFromSettings);
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
    _layoutSaveTimer?.cancel();
    // 最后一次拖分割线可能还在防抖窗口里：关窗 / 换树前补一笔。
    _editorLayoutTimer?.cancel();
    _writeEditorLayout();
    _notes.removeListener(_restoreEditorLayoutWhenReady);
    _canvas.removeListener(_onCanvasChanged);
    _settings.removeListener(_syncRightFromSettings);
    _notes.onBlankNoteCreated = null;
    _stopVaultSync?.call();
    _notices.dispose();
    _shellFocus.dispose();
    _bodyValue.dispose();
    _caret.dispose();
    super.dispose();
  }

  /// 白板文档换了（打开 / 新建 / 关掉 / 删除）时：记住这一页，必要时切过去。
  void _onCanvasChanged() {
    if (!mounted) return;
    if (!_canvas.hasDocument) {
      _saveCanvasSession();
      return;
    }
    if (_pendingCanvasActivate) {
      _pendingCanvasActivate = false;
      _selectMainView(MainView.canvas);
      return;
    }
    // 文档开着、人却没在看它（启动时恢复的那块，或者别处打开的）：标签要有
    // 一页，但**不能切过去**——上次退出时人在写笔记，这次还得停在笔记上。
    if (!_tabsContain(const CanvasDoc())) {
      setState(() {
        _editorTree = SplitTree.replaceValue<TabGroup<PaneDoc>>(
          _editorTree,
          _editorFocusId,
          _focusGroup.appended(const CanvasDoc()),
        );
      });
    }
    _saveCanvasSession();
  }

  /// 有没有哪一格的标签组里排着这一页（不管是不是当前页）。
  bool _tabsContain(PaneDoc doc) => SplitTree.leaves<TabGroup<PaneDoc>>(
    _editorTree,
  ).any((SplitLeaf<TabGroup<PaneDoc>> leaf) => leaf.value.contains(doc));

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

  // ------------------------------------------------------------ 两侧边栏
  //
  // 两棵树都在这里改。叶子装的是同一种 [SidePage]，所以一页能从左栏搬到
  // 右栏，也能搬回来。跨栏和同栏跨格一样是**搬家**：先从来源格摘掉，再落进
  // 目标格；摘空了就收掉来源格（整列只剩这一页时不动——一列总得有一页）。

  SplitNode<TabGroup<SidePage>> _treeFor(SideColumn column) =>
      column.isLeft ? _sideTree : _rightTree;

  void _setTree(SideColumn column, SplitNode<TabGroup<SidePage>> tree) {
    if (column.isLeft) {
      _sideTree = tree;
    } else {
      _rightTree = tree;
    }
  }

  /// 把两侧布局写进偏好。树很小，一次编一条；值没变 [SettingsController]
  /// 不会碰磁盘。
  void _saveSideLayouts() {
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = null;
    _settings.saveSidebarLayout(
      left: encodeSideLayout(
        SideLayout(root: _sideTree, focusId: _sideFocusId),
      ),
      right: encodeSideLayout(
        SideLayout(
          root: _rightTree,
          focusId: SplitTree.firstLeaf<TabGroup<SidePage>>(_rightTree).id,
        ),
      ),
    );
  }

  /// 拖分割线时别每一帧都写盘。
  void _scheduleSideLayoutSave() {
    _layoutSaveTimer?.cancel();
    _layoutSaveTimer = Timer(
      const Duration(milliseconds: 250),
      _saveSideLayouts,
    );
  }

  /// 一次布局改动之后：右栏上格换了页就把三颗开关拨过去，再把布局存下来。
  void _afterSideLayoutChange() {
    if (_settings.rightSidebarVisible) _syncRightTopFlag();
    _saveSideLayouts();
  }

  /// 编辑区那棵树 / 聚焦格 / 活页那一篇变了就排一次落盘。
  ///
  /// 在 `build` 开头调：树是不可变的，改一次换一个实例，比 `identical` 就够。
  /// 不去十几个 `setState` 点各插一句——漏一个就丢一次布局。
  void _maybeSaveEditorLayout() {
    // 存档还没装回去（vault 还在读）：这一帧的树是占位的默认值，写出去就把
    // 用户分好的屏抹了。
    if (_pendingEditorLayout != null) return;
    if (identical(_lastSavedEditorTree, _editorTree) &&
        _lastSavedEditorFocus == _editorFocusId &&
        _lastSavedLiveNote == _liveNoteId) {
      return;
    }
    _lastSavedEditorTree = _editorTree;
    _lastSavedEditorFocus = _editorFocusId;
    _lastSavedLiveNote = _liveNoteId;
    _editorLayoutTimer?.cancel();
    _editorLayoutTimer = Timer(
      const Duration(milliseconds: 250),
      _writeEditorLayout,
    );
  }

  /// 把编辑区布局写进偏好。值没变 [SettingsController] 不会碰磁盘。
  void _writeEditorLayout() {
    _editorLayoutTimer?.cancel();
    _editorLayoutTimer = null;
    // 存档都还没装回来（读盘没落地就关窗）：这时候的树是占位的默认值，别写。
    if (_pendingEditorLayout != null) return;
    _settings.saveEditorLayout(
      encodeEditorLayout(
        EditorLayout(
          root: _editorTree,
          focusId: _editorFocusId,
          liveNoteId: _liveNoteId,
        ),
      ),
    );
  }

  /// 读盘落地了：这时候 `noteById` 才是真的，可以把搁着的存档装回去。
  ///
  /// 控制器在异步收尾里 `notifyListeners`，所以这里既不在 build 里，也不该在
  /// 通知链里直接 `setState`——挪到这一帧之后再做。
  void _restoreEditorLayoutWhenReady() {
    if (_notes.isLoading) return;
    _notes.removeListener(_restoreEditorLayoutWhenReady);
    final EditorLayout? saved = _pendingEditorLayout;
    _pendingEditorLayout = null;
    if (saved == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _restoreEditorLayout(saved));
    });
  }

  /// 把存档装回编辑区。
  ///
  /// 先按「这次真的有什么」摘一遍——笔记可能删了、白板这次没开、图片页没有图
  /// （图片路径本来就不落盘）；摘空的格子连同分割线一起收掉，全空就退回一格
  /// 一页。最后交给 `_handOver` 归一化：只有聚焦那格排着「活的那一页」。
  void _restoreEditorLayout(EditorLayout saved) {
    final SplitNode<TabGroup<PaneDoc>>? pruned = pruneEditorTree(
      saved.root,
      noteExists: (String id) => _notes.noteById(id) != null,
      singletons: <String>{
        if (_canvas.hasDocument) 'canvas',
        if (_imagePath != null) 'image',
        // 图谱首屏不建，只有它当时就在屏幕上才认这一页。
        if (hasCurrentDoc(saved.root, 'graph')) 'graph',
      },
    );
    if (pruned == null) return;
    // 标签栏的 id 要从**归一化之前**的树上取：`_handOver` 会把聚焦那格的
    // 当前页换成「活的那一页」（没有 id），那篇就不算进标签栏了。
    final List<String> tabs = noteIdsIn(pruned);
    _editorFocusId = saved.focusId;
    _editorTree = _handOver(pruned, saved.focusId, saved.liveNoteId ?? '');
    _editorSeq = nextEditorSeq(_editorTree);
    _graphAlive = hasCurrentDoc(_editorTree, 'graph');
    // 标签栏跟着树走：`_openIds` 不再由上次会话说了算。
    //
    // ⛔ 不能在这儿直接调：可能还在 build / 通知链里，`notifyListeners` 会被
    // Provider 判成「build 期间 markNeedsBuild」。等这一帧之后再对齐。
    final String? live = saved.liveNoteId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notes.adoptTabs(tabs, live);
      // 标签上写的是「活的那一页」显示的那一篇：选中换了，标签条得重画
      // （外壳不 watch 选中，平时靠各自的 setState）。
      setState(() {});
    });
  }

  /// 找哪一格的标签组里有这一页；先看左栏聚焦那格，再按屏幕顺序找两侧。
  ({SideColumn column, SplitLeaf<TabGroup<SidePage>> leaf})? _findPage(
    SidePage page,
  ) {
    final SplitLeaf<TabGroup<SidePage>>? focused =
        SplitTree.findLeaf<TabGroup<SidePage>>(_sideTree, _sideFocusId);
    if (focused != null && focused.value.contains(page)) {
      return (column: SideColumn.left, leaf: focused);
    }
    for (final SplitLeaf<TabGroup<SidePage>> leaf
        in SplitTree.leaves<TabGroup<SidePage>>(_sideTree)) {
      if (leaf.value.contains(page)) {
        return (column: SideColumn.left, leaf: leaf);
      }
    }
    for (final SplitLeaf<TabGroup<SidePage>> leaf
        in SplitTree.leaves<TabGroup<SidePage>>(_rightTree)) {
      if (leaf.value.contains(page)) {
        return (column: SideColumn.right, leaf: leaf);
      }
    }
    return null;
  }

  /// 把一页摆到眼前。
  ///
  /// 两栏互通之后，「切到文件」不再等于「改左栏聚焦那格」：文件可能已经被
  /// 搬到右栏了。所以先找它在哪，找不到才开在左栏聚焦那格。返回托管它的
  /// 格子 id——模板目录要拿它去找那棵文件树。
  String? _showPage(SidePage page) {
    final SettingsController settings = context.read<SettingsController>();
    final ({SideColumn column, SplitLeaf<TabGroup<SidePage>> leaf})? found =
        _findPage(page);
    late String paneId;
    setState(() {
      if (found == null) {
        paneId = _sideFocusId;
        _sideTree = SplitTree.replaceValue<TabGroup<SidePage>>(
          _sideTree,
          paneId,
          _sideGroup.open(page),
        );
      } else {
        paneId = found.leaf.id;
        final SideColumn column = found.column;
        _setTree(
          column,
          SplitTree.replaceValue<TabGroup<SidePage>>(
            _treeFor(column),
            paneId,
            found.leaf.value.open(page),
          ),
        );
        if (column.isLeft) _sideFocusId = paneId;
      }
    });
    if (found == null || found.column.isLeft) {
      if (settings.sidebarCollapsed) settings.sidebarCollapsed = false;
    } else {
      settings.rightSidebarVisible = true;
    }
    // 专注模式把两侧面板都藏起来了，切到某个视图却看不到它等于没切。
    if (settings.focusMode) settings.focusMode = false;
    _afterSideLayoutChange();
    return paneId;
  }

  void _selectView(SidebarView view) {
    _showPage(SidePage.ofLeft(view));
  }

  /// 把某一格切到另一页。和 [_selectSideTab] 的区别是「改哪一格」：
  /// 这个由面板自己调（比如标签页里点了某个标签，要切到搜索）。
  void _openPageInPane(SideColumn column, String paneId, SidePage page) {
    final SplitLeaf<TabGroup<SidePage>>? leaf =
        SplitTree.findLeaf<TabGroup<SidePage>>(_treeFor(column), paneId);
    if (leaf == null) return;
    setState(() {
      _setTree(
        column,
        SplitTree.replaceValue<TabGroup<SidePage>>(
          _treeFor(column),
          paneId,
          leaf.value.open(page),
        ),
      );
      if (column.isLeft) _sideFocusId = paneId;
    });
    _afterSideLayoutChange();
  }

  /// 点标签条上那一页。
  ///
  /// 右栏上格再点**面板那三颗**的当前页 = 收起整列——它们以前就是顶栏的
  /// 开关，用户对「再点一下关掉」已经形成了肌肉记忆。左栏没有这层含义（顶上
  /// 那颗侧栏开关管开合），下格也没有，只是切页；文件 / 搜索 / 标签被搬到
  /// 右栏后也只是普通的页，点当前页不该让整列消失。
  void _selectSideTab(SideColumn column, String paneId, int at) {
    final SplitLeaf<TabGroup<SidePage>>? leaf =
        SplitTree.findLeaf<TabGroup<SidePage>>(_treeFor(column), paneId);
    if (leaf == null || at < 0 || at >= leaf.value.length) return;
    final bool topRight =
        !column.isLeft &&
        SplitTree.firstLeaf<TabGroup<SidePage>>(_rightTree).id == paneId;
    if (topRight &&
        at == leaf.value.index &&
        leaf.value.tabs[at].rightView != null) {
      _settings.closeRightPanels();
      return;
    }
    if (at == leaf.value.index) return;
    setState(() {
      _setTree(
        column,
        SplitTree.replaceValue<TabGroup<SidePage>>(
          _treeFor(column),
          paneId,
          leaf.value.select(at),
        ),
      );
      if (column.isLeft) _sideFocusId = paneId;
    });
    if (topRight) _syncRightTopFlag();
    _saveSideLayouts();
  }

  /// 把一个侧边栏页拖进某一格的某个位置。
  ///
  /// 两栏都能收、都能发：目标栏接住两种来源（[SidePageDrag.fromColumn] 说
  /// 它原来在哪）。落中间 = 那一格切到这一页；落边上 = 在那一侧切出新格，
  /// 新格只装拖过来的这一页。从别的格子拖过来的一律是**搬家**——先摘再落，
  /// 和编辑区一个口径。
  ///
  /// 侧边栏只能上下切：它本来就窄，左右各 28% 会把整格吃掉。
  void _dropSidePage(
    SideColumn targetColumn,
    String paneId,
    DropZone zone,
    SidePageDrag drag,
  ) {
    final SplitNode<TabGroup<SidePage>> sourceTree = _treeFor(drag.fromColumn);
    final SplitLeaf<TabGroup<SidePage>>? sourceLeaf = drag.fromPane == null
        ? null
        : SplitTree.findLeaf<TabGroup<SidePage>>(sourceTree, drag.fromPane!);
    final bool fromHere =
        sourceLeaf != null && sourceLeaf.value.contains(drag.page);

    // 落回自己那一格的中间 = 本来就在这儿，什么都不用做。
    if (fromHere &&
        drag.fromColumn == targetColumn &&
        drag.fromPane == paneId) {
      if (!zone.isEdge) return;
      // 同一格、又只有这一页：搬过去再在原地留一份一模一样的，等于没做。
      if (sourceLeaf.value.length <= 1) return;
    }

    // 整列只剩这一页：不让搬。那一列会变空，连一页都没得画。
    if (fromHere &&
        drag.fromColumn != targetColumn &&
        SplitTree.leaves<TabGroup<SidePage>>(sourceTree).length == 1 &&
        sourceLeaf.value.length == 1) {
      return;
    }

    String? newPaneId;
    setState(() {
      SplitNode<TabGroup<SidePage>> source = sourceTree;
      SplitNode<TabGroup<SidePage>> target = targetColumn == drag.fromColumn
          ? sourceTree
          : _treeFor(targetColumn);
      bool emptied = false;

      if (fromHere) {
        final ({SplitNode<TabGroup<SidePage>> tree, bool emptied}) cut =
            _cutSidePage(source, drag.fromPane!, drag.page);
        source = cut.tree;
        emptied = cut.emptied;
        if (targetColumn == drag.fromColumn) target = source;
      }

      if (!zone.isEdge) {
        final SplitLeaf<TabGroup<SidePage>>? targetLeaf =
            SplitTree.findLeaf<TabGroup<SidePage>>(target, paneId);
        if (targetLeaf != null) {
          target = SplitTree.replaceValue<TabGroup<SidePage>>(
            target,
            paneId,
            targetLeaf.value.open(drag.page),
          );
        }
      } else {
        final int seq = targetColumn.isLeft ? ++_sideSeq : ++_rightSeq;
        final String prefix = targetColumn.isLeft ? 'side' : 'right';
        final String id = '$prefix-$seq';
        newPaneId = id;
        target = SplitTree.split<TabGroup<SidePage>>(
          root: target,
          leafId: paneId,
          axis: Axis.vertical,
          // 和编辑区一样：新格只拿拖过来的这一页。
          value: TabGroup<SidePage>.of(drag.page),
          newLeafId: id,
          newBranchId: '$prefix-branch-$seq',
          before: zone.verticalized.before,
        );
      }

      if (targetColumn == drag.fromColumn) {
        if (emptied &&
            SplitTree.leaves<TabGroup<SidePage>>(target).length > 1) {
          target =
              SplitTree.remove<TabGroup<SidePage>>(target, drag.fromPane!) ??
              target;
          _listKeys.remove(drag.fromPane);
        }
        _setTree(targetColumn, target);
      } else {
        if (emptied) {
          source =
              SplitTree.remove<TabGroup<SidePage>>(source, drag.fromPane!) ??
              source;
          _listKeys.remove(drag.fromPane);
        }
        _setTree(drag.fromColumn, source);
        _setTree(targetColumn, target);
      }

      if (targetColumn.isLeft) {
        _sideFocusId = newPaneId ?? paneId;
        if (SplitTree.findLeaf<TabGroup<SidePage>>(_sideTree, _sideFocusId) ==
            null) {
          _sideFocusId = SplitTree.firstLeaf<TabGroup<SidePage>>(_sideTree).id;
        }
      } else if (drag.fromColumn.isLeft &&
          emptied &&
          _sideFocusId == drag.fromPane) {
        // 左栏被搬走的是聚焦那格：聚焦挪到剩下第一格，别指着一个不存在的。
        _sideFocusId = SplitTree.firstLeaf<TabGroup<SidePage>>(_sideTree).id;
      }
    });
    _afterSideLayoutChange();
  }

  /// 从某一格里摘掉搬走的那一页。摘空了只报信（[emptied]）、不动树——
  /// 那一格可能正是要分割的格子。
  ({SplitNode<TabGroup<SidePage>> tree, bool emptied}) _cutSidePage(
    SplitNode<TabGroup<SidePage>> tree,
    String paneId,
    SidePage page,
  ) {
    final SplitLeaf<TabGroup<SidePage>>? leaf =
        SplitTree.findLeaf<TabGroup<SidePage>>(tree, paneId);
    if (leaf == null) return (tree: tree, emptied: false);
    final int at = leaf.value.indexOf(page);
    if (at < 0) return (tree: tree, emptied: false);
    if (leaf.value.length == 1) return (tree: tree, emptied: true);
    return (
      tree: SplitTree.replaceValue<TabGroup<SidePage>>(
        tree,
        paneId,
        leaf.value.closeAt(at, leaf.value.tabs[at == 0 ? 1 : 0]),
      ),
      emptied: false,
    );
  }

  // ---------------------------------------------------------------- 右栏格子
  //
  // 右栏的分格、拖动、合并和左栏走同一套（[_dropSidePage] / [_selectSideTab]），
  // 这里只剩「偏好里的三颗开关和上格那一页对表」。

  /// 顶栏三颗开关改了：把右栏上格切到对应的那一页。
  ///
  /// 上格的标签页和顶栏的开关是同一件事，只是画在不同层。用户在顶栏点
  /// 「图片」、按 `Ctrl+Shift+O`、或者测试直接改偏好，都要落到上格；反过来，
  /// 点右栏上格的标签也要写回偏好（见 [_selectSideTab]）。
  ///
  /// 三颗一起落下时：如果上格停的正是右栏的面板，那就是「收起整列」；
  /// 如果上格停的是左栏页（文件 / 搜索 / 标签），三颗不代表整列开合。
  void _syncRightFromSettings() {
    if (!mounted) return;
    final RightView? active = _rightActiveView;
    if (active == null) {
      if (_settings.rightSidebarVisible &&
          SplitTree.firstLeaf<TabGroup<SidePage>>(
                _rightTree,
              ).value.current.rightView !=
              null) {
        _settings.rightSidebarVisible = false;
      }
      return;
    }
    if (!_settings.rightSidebarVisible) return;
    final SidePage page = SidePage.ofRight(active);
    final SplitLeaf<TabGroup<SidePage>> top =
        SplitTree.firstLeaf<TabGroup<SidePage>>(_rightTree);
    if (top.value.current == page) return;
    setState(() {
      _rightTree = SplitTree.replaceValue<TabGroup<SidePage>>(
        _rightTree,
        top.id,
        top.value.open(page),
      );
    });
    _saveSideLayouts();
  }

  /// 上格现在显示哪一页，就把它写回那三颗开关。
  ///
  /// 分屏、合并、搬家都可能换掉上格的当前页；偏好必须跟着走，否则顶栏
  /// （右栏收起时）和右栏（收起再打开时）会各说各的。上格停的是左栏页时
  /// 三颗都落下——它们只代表右栏的面板。
  void _syncRightTopFlag() {
    // 先钉住「整列开着」再看页：上格要是停在文件 / 搜索 / 标签，下面会把
    // 三颗面板开关全部落下，推导出来的开合会跟着翻成「关」。
    _settings.rightSidebarVisible = true;
    final SidePage page = SplitTree.firstLeaf<TabGroup<SidePage>>(
      _rightTree,
    ).value.current;
    final RightView? view = page.rightView;
    if (view == null) {
      _settings.clearRightViewFlags();
    } else {
      _settings.rememberRightView(view);
    }
  }

  // ---------------------------------------------------------------- 编辑区格子

  /// 点哪一格，哪一格就接手「跟着选中走」的那一份（于是它能写）。
  ///
  /// 原来那格钉在它此刻显示的那篇上，转成只读。树里始终只有一格是活的：
  /// 草稿、自动保存、撤销栈和冲突检测都只服务它，不必复制成多份。
  void _focusEditorPane(String paneId) {
    if (_editorFocusId == paneId) return;
    final SplitLeaf<TabGroup<PaneDoc>>? leaf =
        SplitTree.findLeaf<TabGroup<PaneDoc>>(_editorTree, paneId);
    if (leaf == null) return;
    final PaneDoc doc = leaf.value.current;
    setState(() {
      _editorFocusId = paneId;
      _editorTree = _handOver(_editorTree, paneId, _liveNoteId ?? '');
    });
    // 点到的是一格正看着某一篇的笔记格：全局选中也跟过去。不跟的话「活的
    // 那一份」会把它换成另一篇，看起来就像点错了格。
    if (doc is NoteDoc &&
        doc.noteId != null &&
        doc.noteId != _notes.selectedId) {
      _notes.select(doc.noteId!);
    }
  }

  /// 把 [liveId] 那一格变成唯一的「活格子」，其余的笔记页钉在 [noteId] 上。
  ///
  /// [noteId] 为空串（一篇笔记都没选中）时钉住的那几页显示空状态——这不是
  /// 特例，`noteById('')` 本来就找不到任何东西。⛔ 别在这种情况下跳过交接：
  /// 树里留下两个「活的」页，之后选中一篇笔记时两格会一起跟着跑。
  ///
  /// 只碰笔记页：图谱 / 白板 / 图片没有「活的那一份」这回事。注意找的是
  /// **组里的任意一页**而不是 `current`：活的那一页可能只是别的格子标签条
  /// 上排着的一页，还没被切到前面。
  SplitNode<TabGroup<PaneDoc>> _handOver(
    SplitNode<TabGroup<PaneDoc>> tree,
    String liveId,
    String noteId,
  ) {
    for (final SplitLeaf<TabGroup<PaneDoc>> leaf
        in SplitTree.leaves<TabGroup<PaneDoc>>(tree)) {
      TabGroup<PaneDoc> g = leaf.value;
      if (leaf.id == liveId) {
        final PaneDoc cur = g.current;
        if (cur is NoteDoc && !cur.isLive) {
          g = g.replaceCurrent(const NoteDoc(null));
        }
      } else {
        final int at = g.tabs.indexWhere(
          (PaneDoc d) => d is NoteDoc && d.isLive,
        );
        if (at >= 0) g = g.replaceAt(at, NoteDoc(noteId));
      }
      if (!identical(g, leaf.value)) {
        tree = SplitTree.replaceValue<TabGroup<PaneDoc>>(tree, leaf.id, g);
      }
    }
    return tree;
  }

  /// 把树里所有满足 [test] 的**页**关掉（关掉某一页时用）。
  SplitNode<TabGroup<PaneDoc>> _dropDoc(
    SplitNode<TabGroup<PaneDoc>> tree,
    bool Function(PaneDoc doc) test,
  ) {
    final String noteId = _liveNoteId ?? '';
    for (final SplitLeaf<TabGroup<PaneDoc>> leaf
        in SplitTree.leaves<TabGroup<PaneDoc>>(tree)) {
      TabGroup<PaneDoc> g = leaf.value;
      final PaneDoc fallback = leaf.id == _editorFocusId
          ? const NoteDoc(null)
          : NoteDoc(noteId);
      for (int i = g.tabs.length - 1; i >= 0; i--) {
        if (test(g.tabs[i])) g = g.closeAt(i, fallback);
      }
      if (!identical(g, leaf.value)) {
        tree = SplitTree.replaceValue<TabGroup<PaneDoc>>(tree, leaf.id, g);
      }
    }
    return tree;
  }

  /// 关掉一格。只剩一格时什么都不做——容器总得有一格。
  void _closeEditorPane(String paneId) {
    if (SplitTree.leaves<TabGroup<PaneDoc>>(_editorTree).length <= 1) return;
    final SplitNode<TabGroup<PaneDoc>>? next =
        SplitTree.remove<TabGroup<PaneDoc>>(_editorTree, paneId);
    if (next == null) return;
    final String focus = _editorFocusId == paneId
        ? SplitTree.firstLeaf<TabGroup<PaneDoc>>(next).id
        : _editorFocusId;
    // 接手的那一格原来在看什么，交接之后就让它看什么。`_handOver` 会把它的
    // 当前页换成「活的那一份」，所以这一篇得先读出来、之后再让全局选中跟过去
    // ——否则它会被钉成刚关掉的那篇，关掉一格反而把另一格换成了别人的内容。
    final PaneDoc kept =
        SplitTree.findLeaf<TabGroup<PaneDoc>>(next, focus)?.value.current ??
        const NoteDoc(null);
    setState(() {
      _editorFocusId = focus;
      _editorTree = _handOver(
        next,
        focus,
        kept is NoteDoc
            ? (kept.noteId ?? _liveNoteId ?? '')
            : (_liveNoteId ?? ''),
      );
    });
    _editorKeys.remove(paneId);
    if (kept is NoteDoc &&
        kept.noteId != null &&
        kept.noteId != _notes.selectedId) {
      _notes.select(kept.noteId!);
    }
    _shellFocus.requestFocus();
  }

  /// 点某一格标签条上的某一页。
  void _selectTab(String paneId, int at) {
    final SplitLeaf<TabGroup<PaneDoc>>? leaf =
        SplitTree.findLeaf<TabGroup<PaneDoc>>(_editorTree, paneId);
    if (leaf == null || at < 0 || at >= leaf.value.length) return;
    final PaneDoc doc = leaf.value.tabs[at];
    final String? prev = _liveNoteId;
    setState(() {
      TabGroup<PaneDoc> g = leaf.value;
      // 活的那一页跟着选中走、没有自己的 id：换页之前先把它钉到此刻显示的
      // 那一篇上，否则切走之后它就没有内容可跟了。点到它自己时跳过。
      final bool targetIsLive = doc is NoteDoc && doc.noteId == null;
      if (!targetIsLive && prev != null) {
        final int liveAt = g.tabs.indexWhere(
          (PaneDoc d) => d is NoteDoc && d.isLive,
        );
        if (liveAt >= 0 && liveAt != at) g = g.replaceAt(liveAt, NoteDoc(prev));
      }
      _editorFocusId = paneId;
      _editorTree = _handOver(
        SplitTree.replaceValue<TabGroup<PaneDoc>>(
          _editorTree,
          paneId,
          g.select(at),
        ),
        paneId,
        doc is NoteDoc && doc.noteId != null ? doc.noteId! : (prev ?? ''),
      );
    });
    if (doc is NoteDoc && doc.noteId != null) _notes.select(doc.noteId!);
    _afterPaneSwitch(doc);
  }

  /// 关掉某一格标签条上的一页。
  ///
  /// 笔记走 `NotesController.closeTab`（它负责把选中挪到邻居上），单例文档
  /// 走各自那套「放下文档」的收尾。
  ///
  /// ⛔ **关掉一格里的最后一页 = 关掉这一格**（分割自己收回去，剩下那格铺满）。
  /// 拿别的页顶住的话，看起来就像「关掉一篇，隔壁那篇被搬了过来」——用户
  /// 原话：「我关闭了这个 tab 后，应该是自动恢复布局，关掉这个分割，而不是把
  /// 第一个编辑栏的 tab 继续放到这个第二个 tab 里」。
  void _closeTab(String paneId, int at) {
    final SplitLeaf<TabGroup<PaneDoc>>? leaf =
        SplitTree.findLeaf<TabGroup<PaneDoc>>(_editorTree, paneId);
    if (leaf == null || at < 0 || at >= leaf.value.length) return;
    final PaneDoc doc = leaf.value.tabs[at];
    // ⛔ 关掉一格里的最后一页 = 关掉这一格（分割自己收回去，剩下那格铺满）。
    // 拿别的页顶住的话，看起来就像「关掉一篇，隔壁那篇被搬了过来」——用户
    // 原话：「我关闭了这个 tab 后，应该是自动恢复布局，关掉这个分割，而不是把
    // 第一个编辑栏的 tab 继续放到这个第二个 tab 里」。
    if (leaf.value.length == 1) {
      if (_hasManyPanes) {
        if (doc is GraphDoc) _graphAlive = false;
        if (doc is ImageDoc) _imagePath = null;
        if (doc is CanvasDoc) unawaited(_canvas.close());
        if (doc is NoteDoc) {
          final String? id = doc.noteId ?? _liveNoteId;
          // 这一篇在**别的**格子里还开着的话，会话里就别关它。
          if (id != null && !_otherPaneHas(paneId, NoteDoc(id))) {
            _notes.closeTab(id);
          }
        }
        _closeEditorPane(paneId);
        return;
      }
      _emptyLastTab(paneId, doc);
      return;
    }
    if (doc is GraphDoc) return _closeGraph();
    if (doc is CanvasDoc) return _closeCanvas();
    if (doc is ImageDoc) return _closeImage();
    if (doc is SettingsDoc) return _closeSettings();
    if (doc is TemplatesDoc) return _closeTemplates();
    if (doc is TrashDoc) return _closeTrash();
    final String? id = (doc as NoteDoc).noteId ?? _liveNoteId;
    if (id == null) return;
    final TabGroup<PaneDoc> g = leaf.value.closeAt(
      at,
      paneId == _editorFocusId
          ? const NoteDoc(null)
          : NoteDoc(_liveNoteId ?? ''),
    );
    final PaneDoc now = g.current;
    final String nowId = now is NoteDoc
        ? (now.noteId ?? _liveNoteId ?? '')
        : '';
    setState(() {
      _editorTree = _handOver(
        SplitTree.replaceValue<TabGroup<PaneDoc>>(_editorTree, paneId, g),
        _editorFocusId,
        nowId,
      );
    });
    if (!_otherPaneHas(paneId, NoteDoc(id))) _notes.closeTab(id);
    // 关掉之后这一格换到另一篇笔记上：全局选中也跟过去，否则活的那一页
    // 会被钉成刚关掉的那篇。
    if (now is NoteDoc &&
        now.noteId != null &&
        now.noteId != _notes.selectedId) {
      _notes.select(now.noteId!);
    }
  }

  /// 编辑区不止一格。
  bool get _hasManyPanes =>
      SplitTree.leaves<TabGroup<PaneDoc>>(_editorTree).length > 1;

  /// 关掉**整个编辑区最后那一页**：原地留一个空标签页，不递补任何笔记。
  ///
  /// ⛔ 这里不能走 `closeAt(at, fallback)`：它留下的那一页还是「活的那一份」，
  /// 跟着全局选中走。只要 `_openIds` 里还排着点过的笔记，`closeTab` 就会把
  /// 选中交给邻居——关一次换一篇，看起来就是「关掉一个 tab，又冒出一个新
  /// tab」，而且永远关不完。所以选中必须一起清掉（[NotesController.clearTabs]），
  /// 留下的那页才会显示空状态。用户原话：「我关掉最后一个 tab 后，还是一直
  /// 出现新的 tab，这是不对的！……就显示空标签页！」
  void _emptyLastTab(String paneId, PaneDoc doc) {
    if (doc is GraphDoc) _graphAlive = false;
    if (doc is ImageDoc) _imagePath = null;
    setState(() {
      _editorFocusId = paneId;
      _editorTree = SplitTree.replaceValue<TabGroup<PaneDoc>>(
        _editorTree,
        paneId,
        const TabGroup<PaneDoc>(<PaneDoc>[NoteDoc(null)], 0),
      );
    });
    _notes.clearTabs();
    // 白板的收尾放最后：`close()` 会通知一次，那时树上已经没有这一页了，
    // `_onCanvasChanged` 走「没有文档」那条路，顺手把会话里那块清掉，也不会
    // 再补一页回来。这里不要提前 `_saveCanvasSession()`——那一刻 `path` 还在。
    if (doc is CanvasDoc) unawaited(_canvas.close());
  }

  /// 除了 [paneId] 之外，还有没有哪一格的标签组里排着 [doc]。
  bool _otherPaneHas(String paneId, PaneDoc doc) =>
      SplitTree.leaves<TabGroup<PaneDoc>>(_editorTree).any(
        (SplitLeaf<TabGroup<PaneDoc>> leaf) =>
            leaf.id != paneId && leaf.value.contains(doc),
      );

  /// 切完页之后那点收尾：专注模式、键盘焦点、白板要一次键盘。
  void _afterPaneSwitch(PaneDoc doc) {
    final SettingsController settings = context.read<SettingsController>();
    if (doc is! NoteDoc) {
      // 图谱、白板和图片都是全宽的：专注模式下面板都藏起来了，它们也需要
      // 那块地方。
      if (settings.focusMode) settings.focusMode = false;
      // 正文被藏起来了但还挂在树上（为了保住撤销栈），焦点必须收回外壳，
      // 否则在图谱界面敲字会写进看不见的编辑器里。
      //
      // ⛔ 只在**离开正文**的时候收焦点。切到一篇笔记时也收的话，点文件树
      // 那一行会把树的焦点抢走——F2 改名、方向键上下走全都不灵了。
      _shellFocus.requestFocus();
    }
    // 白板要自己收键盘（空格抓手、Ctrl+0）：`autofocus` 只在挂载那一次
    // 生效，切回来时不会重来一遍，所以这里显式要一次。
    if (doc is CanvasDoc) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _canvasKey.currentState?.requestFocus();
      });
    }
    _saveCanvasSession();
  }

  /// 把一页开到聚焦那一格：已经开着就切过去，没开着就加在最后。
  void _openTabInFocus(PaneDoc doc) {
    final String? prev = _liveNoteId;
    final String? id = doc is NoteDoc ? doc.noteId : null;
    if (id != null) _notes.select(id);
    if (doc is GraphDoc) _graphAlive = true;
    setState(() {
      TabGroup<PaneDoc> g = _focusGroup;
      // ⛔ 先把「活的那一页」钉到它此刻显示的那篇上，再动别的。
      //
      // 它跟着全局选中走、自己没有 id。不钉就往下走的话，`notes.select`
      // 已经把选中换成目标那篇了，这一页也就变成目标那篇——于是同一篇排
      // 出两页来（一次「先点乙文再点甲文」就能看到两个「甲文」）。
      final int liveAt = g.tabs.indexWhere(
        (PaneDoc d) => d is NoteDoc && d.isLive,
      );
      if (doc is NoteDoc && id == null) {
        // 「活的那一份」：已经有一页活着就切到它，没有才开一页新的。
        g = g.open(const NoteDoc(null));
      } else {
        if (liveAt >= 0 && prev != null) g = g.replaceAt(liveAt, NoteDoc(prev));
        if (doc is! NoteDoc) {
          // 图谱 / 白板 / 图片：它自己就是一页，已经开着就切过去。
          g = g.open(doc);
        } else {
          final int at = g.indexOf(NoteDoc(id!));
          g = at >= 0 ? g.select(at) : g.open(const NoteDoc(null));
        }
      }
      _editorTree = _handOver(
        SplitTree.replaceValue<TabGroup<PaneDoc>>(
          _editorTree,
          _editorFocusId,
          g,
        ),
        _editorFocusId,
        id ?? _liveNoteId ?? '',
      );
    });
    _afterPaneSwitch(doc);
  }

  /// 从某一格里摘掉「搬走的那一页」。
  ///
  /// 拖出去是**搬家**不是复印：原来那一格不能再留着同一篇，否则两格显示同一篇。
  /// 用户原话：「我分割后，这个 tab 就属于第二个编辑栏了，不再属于第一个编辑栏
  /// 了。」
  ///
  /// 找页的时候不能只按 `==` 比：[wasLive] 时那一页的身份是常量 `note:*`，它
  /// 显示的是全局选中的那篇——按身份找不到，得按「它是活页」认。
  ///
  /// 摘空了只报信（[emptied]）、**不动树**：那一格这会儿可能正是要分割的格子，
  /// 提前删掉会让分割找不到落脚点。调用方在分割之后用 [_dropEmptyPane] 收它。
  ({SplitNode<TabGroup<PaneDoc>> tree, bool emptied}) _cutPage(
    SplitNode<TabGroup<PaneDoc>> tree,
    String paneId,
    PaneDoc doc,
    String? id,
    bool wasLive,
  ) {
    final SplitLeaf<TabGroup<PaneDoc>>? leaf =
        SplitTree.findLeaf<TabGroup<PaneDoc>>(tree, paneId);
    if (leaf == null) return (tree: tree, emptied: false);
    final int at = leaf.value.tabs.indexWhere(
      (PaneDoc d) => doc is NoteDoc
          ? d is NoteDoc &&
                (wasLive ? d.isLive : (id != null && d.noteId == id))
          : d == doc,
    );
    if (at < 0) return (tree: tree, emptied: false);
    if (leaf.value.length == 1) return (tree: tree, emptied: true);
    return (
      tree: SplitTree.replaceValue<TabGroup<PaneDoc>>(
        tree,
        paneId,
        leaf.value.closeAt(at, const NoteDoc(null)),
      ),
      emptied: false,
    );
  }

  /// 收掉被摘空的那一格（它的兄弟顶上来）。
  SplitNode<TabGroup<PaneDoc>> _dropEmptyPane(
    SplitNode<TabGroup<PaneDoc>> tree,
    String paneId,
  ) {
    final SplitNode<TabGroup<PaneDoc>>? next =
        SplitTree.remove<TabGroup<PaneDoc>>(tree, paneId);
    if (next == null) return tree;
    _editorKeys.remove(paneId);
    return next;
  }

  /// 把一个 tab 拖进某一格的某个位置。
  ///
  /// 拖出去是**搬家**：无论落在中间还是边上，原来那一格都不再留着这一页。
  void _dropTab(String paneId, DropZone zone, TabDrag tab) {
    if (tab is! DocDrag) return;
    final PaneDoc doc = tab.doc;
    final String? from = tab.fromPane;
    if (doc is GraphDoc) _graphAlive = true;

    // 「活的那一页」没有自己的 id，它显示的是此刻全局选中的那篇。拎起来搬走
    // 之后显示的仍是那篇，所以 [id] 得现取。
    final bool wasLive = doc is NoteDoc && doc.noteId == null;
    final String? id = doc is NoteDoc ? (doc.noteId ?? _liveNoteId) : null;

    if (!zone.isEdge) {
      // 落在中间 = 这一格收下这一页并切过去。落在自己那一格就是「点它一下」。
      if (from == paneId) {
        final TabGroup<PaneDoc>? g = SplitTree.findLeaf<TabGroup<PaneDoc>>(
          _editorTree,
          paneId,
        )?.value;
        final int at = g?.indexOf(doc) ?? -1;
        if (at >= 0) _selectTab(paneId, at);
        return;
      }
      _moveTabIntoPane(paneId, doc, from: from, id: id, wasLive: wasLive);
      return;
    }
    _moveTabToNewPane(
      paneId,
      doc,
      from: from,
      id: id,
      wasLive: wasLive,
      axis: zone == DropZone.left || zone == DropZone.right
          ? Axis.horizontal
          : Axis.vertical,
      // 落在左 / 上边 = 新格在前，落在右 / 下边 = 新格在后。
      before: zone == DropZone.left || zone == DropZone.top,
    );
  }

  /// 把一页搬到某一格的标签条上（落在格子中间）。
  void _moveTabIntoPane(
    String paneId,
    PaneDoc doc, {
    required String? from,
    required String? id,
    required bool wasLive,
  }) {
    setState(() {
      SplitNode<TabGroup<PaneDoc>> tree = _editorTree;
      bool sourceEmptied = false;
      if (from != null) {
        final ({SplitNode<TabGroup<PaneDoc>> tree, bool emptied}) cut =
            _cutPage(tree, from, doc, id, wasLive);
        tree = cut.tree;
        sourceEmptied = cut.emptied;
      }
      final SplitLeaf<TabGroup<PaneDoc>>? target =
          SplitTree.findLeaf<TabGroup<PaneDoc>>(tree, paneId);
      if (target == null) return;
      tree = SplitTree.replaceValue<TabGroup<PaneDoc>>(
        tree,
        paneId,
        target.value.open(wasLive ? const NoteDoc(null) : doc),
      );
      _editorFocusId = paneId;
      // ⛔ 别的格子里的活页钉回**它此刻显示的那篇**（`_liveNoteId`），不是钉到
      // 搬走的那篇：搬一次家就让隔壁换内容，用户看到的是「拖走一篇，原来那一
      // 格也变成了它」。
      tree = _handOver(tree, paneId, _liveNoteId ?? '');
      if (sourceEmptied && from != null) tree = _dropEmptyPane(tree, from);
      _editorTree = tree;
    });
    _shellFocus.requestFocus();
    if (id != null) _notes.select(id);
  }

  /// 分出一格，把一页**搬**过去（拖到某一格的边上）。
  ///
  /// 顺序是「先分割、再交接、最后收掉空掉的源格」：
  /// * 先分割，新格才有地方接那一页，`_editorFocusId` 也才有新格可指；
  /// * 源格被摘空了就整格收掉。⛔ 别拿 `fallback` 顶住——那一页和搬走的是同一
  ///   篇，看起来就是原地留了个复制品。
  void _moveTabToNewPane(
    String paneId,
    PaneDoc doc, {
    required String? from,
    required String? id,
    required bool wasLive,
    required Axis axis,
    required bool before,
  }) {
    // 同一格、又只有这一页：把它搬到新格、原地再留一份一模一样的，等于什么都
    // 没做——一格总要有一页，分不出第二份来。
    if (from == paneId) {
      final TabGroup<PaneDoc>? g = SplitTree.findLeaf<TabGroup<PaneDoc>>(
        _editorTree,
        paneId,
      )?.value;
      if (g == null || g.length <= 1) return;
    }
    final int seq = ++_editorSeq;
    final String newId = 'editor-$seq';
    setState(() {
      SplitNode<TabGroup<PaneDoc>> tree = _editorTree;
      bool sourceEmptied = false;
      if (from != null) {
        final ({SplitNode<TabGroup<PaneDoc>> tree, bool emptied}) cut =
            _cutPage(tree, from, doc, id, wasLive);
        tree = cut.tree;
        sourceEmptied = cut.emptied;
      }
      tree = SplitTree.split<TabGroup<PaneDoc>>(
        root: tree,
        leafId: paneId,
        axis: axis,
        value: TabGroup<PaneDoc>.of(wasLive ? const NoteDoc(null) : doc),
        newLeafId: newId,
        newBranchId: 'editor-branch-$seq',
        before: before,
      );
      _editorFocusId = newId;
      tree = _handOver(tree, newId, _liveNoteId ?? '');
      if (sourceEmptied && from != null) tree = _dropEmptyPane(tree, from);
      _editorTree = tree;
    });
    _shellFocus.requestFocus();
    if (id != null) _notes.select(id);
  }

  /// 标签条上一页写什么字。
  String _docLabel(PaneDoc doc) => switch (doc) {
    NoteDoc(:final String? noteId) => _noteTabLabel(noteId),
    GraphDoc() => '关系图谱',
    CanvasDoc() => _canvas.path == null ? '白板' : canvasTitleOf(_canvas.path!),
    ImageDoc() => _imagePath?.split('/').last ?? '图片',
    SettingsDoc() => '设置',
    TemplatesDoc() => '模板',
    TrashDoc() => '回收站',
  };

  /// 标签条上那一页的 key。
  ///
  /// 按**这一页显示的那一篇**取，不按 `PaneDoc` 的身份取：「活的那一份」
  /// 的身份是常量 `note:*`，拿它当 key 的话每换一篇笔记 key 都不变、每换
  /// 一次焦点 key 又变，测试和动画都跟着乱。
  ///
  /// 白板 / 图片那两页的 key 是固定的：同一时刻只开着一块，从文件树换一块
  /// 时是**这一页原地换名字**，不是多开一页。
  String _tabKey(PaneDoc doc) => switch (doc) {
    NoteDoc(:final String? noteId) =>
      'note-tab-${noteId ?? _liveNoteId ?? '*'}',
    GraphDoc() => 'graph-tab',
    CanvasDoc() => 'canvas-tab',
    ImageDoc() => 'image-tab',
    SettingsDoc() => 'settings-tab',
    TemplatesDoc() => 'templates-tab',
    TrashDoc() => 'trash-tab',
  };

  String _noteTabLabel(String? id) {
    final Note? note = id == null ? _notes.selectedNote : _notes.noteById(id);
    // 一篇都没选中 = 刚关掉最后一页留下的那个空标签页，别写成「未命名」——
    // 那看起来像一篇标题为空的笔记。
    if (note == null) return id == null ? '新标签页' : '未命名';
    final String title = note.title.trim();
    return title.isEmpty ? '未命名' : title;
  }

  /// 画一个编辑区格子：顶上是这一格自己的标签条，底下是当前那一页。
  ///
  /// [trailingInset] 是标签条右端要让给浮在它上面的那几颗按钮的宽度。
  Widget _editorPane(
    SplitLeaf<TabGroup<PaneDoc>> leaf, {
    double trailingInset = 0,
  }) {
    final TabGroup<PaneDoc> group = leaf.value;
    final bool live = leaf.id == _editorFocusId;
    final PaneDoc doc = group.current;
    return Listener(
      // 点一下就把「能写的那份」交给它。
      onPointerDown: (_) => _focusEditorPane(leaf.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneTabStrip(
            tabs: <PaneTabData>[
              for (final PaneDoc d in group.tabs)
                PaneTabData(
                  key: ValueKey<String>(_tabKey(d)),
                  label: _docLabel(d),
                  drag: DocDrag(d, label: _docLabel(d), fromPane: leaf.id),
                ),
            ],
            index: group.index,
            focused: live,
            onSelect: (int i) => _selectTab(leaf.id, i),
            onClose: (int i) => _closeTab(leaf.id, i),
            // 标签条就是窗口最上面那条带子：没被标签占住的那一段拖窗口。
            filler: titleBarGrip(),
            trailingInset: trailingInset,
            // 丢到这一格的标签条上 = 并进这一格（和丢在格子中间一样，
            // 只是多了块更好瞄的地方）。自己这一格拎起来的不收。
            acceptsTab: (TabDrag t) => t is DocDrag && t.fromPane != leaf.id,
            onDropTab: (TabDrag t) {
              if (t is! DocDrag) return;
              _dropTab(leaf.id, DropZone.center, t);
            },
          ),
          Expanded(
            child: PaneDropZone(
              // 编辑区只收文档；侧边栏 / 右栏的图标拖过来不该亮起预览。
              accepts: (TabDrag t) => t is DocDrag,
              onDrop: (DropZone zone, TabDrag tab) =>
                  _dropTab(leaf.id, zone, tab),
              child: switch (doc) {
                NoteDoc(:final String? noteId) => EditorPane(
                  key: _editorKeyFor(leaf.id),
                  // 表格工具和状态浮片读的是「正在写的那一份」，只读格不发布。
                  bodyValue: live ? _bodyValue : null,
                  caretValue: live ? _caret : null,
                  noteId: noteId,
                  readOnly: !live,
                  // 右缘刻度跟聚焦格的大纲行号走；只读格不画。
                  outlineLine: live ? _cursorLine : null,
                  showSearchHighlights: _searchOnScreen,
                  onDelete: _confirmDelete,
                  onOpenSearch: () => _selectView(SidebarView.search),
                  // 大纲跟着聚焦那一格走：只读格的光标不归它管。
                  onCursorLineChanged: live
                      ? (int line) {
                          if (line == _cursorLine) return;
                          setState(() => _cursorLine = line);
                        }
                      : null,
                  onClosePane:
                      SplitTree.leaves<TabGroup<PaneDoc>>(_editorTree).length >
                          1
                      ? () => _closeEditorPane(leaf.id)
                      : null,
                ),
                GraphDoc() => _graphBody(),
                CanvasDoc() => _canvasBody(),
                ImageDoc() => _imageBody(),
                SettingsDoc() => const SettingsPage(key: Key('settings-page')),
                TemplatesDoc() => TemplatesPage(
                  key: const Key('templates-page'),
                  onAction: _handleTemplateAction,
                  onClose: _closeTemplates,
                ),
                TrashDoc() => TrashPage(
                  key: const Key('trash-page'),
                  onClose: _closeTrash,
                ),
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 画一侧边栏的一格：顶上一条图标标签条，底下是当前那一页。
  ///
  /// 两栏共用一个画法，只有壳子的量法不同：左栏是 32 的方块、从 6 起；
  /// 右栏是 28 的紧凑版、从 0 起（窗顶那三颗的位置不能变）。页本身是同一套
  /// [SidePage]，所以文件可以被搬到右栏、大纲可以被搬到左栏。
  Widget _sidePane(SideColumn column, SplitLeaf<TabGroup<SidePage>> leaf) {
    final TabGroup<SidePage> group = leaf.value;
    final bool left = column.isLeft;
    final bool top =
        !left &&
        SplitTree.firstLeaf<TabGroup<SidePage>>(_rightTree).id == leaf.id;
    final double width = left ? _settings.listWidth : _settings.rightPanelWidth;
    return Listener(
      // 点哪一格，[_showPage] / 模板目录就改哪一格（只有左栏有聚焦这回事）。
      onPointerDown: left
          ? (_) {
              if (_sideFocusId == leaf.id) return;
              setState(() => _sideFocusId = leaf.id);
            }
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PaneTabStrip(
            tabs: <PaneTabData>[
              for (final SidePage page in group.tabs)
                PaneTabData(
                  key: ValueKey<String>(
                    'side-tab-${column.name}-${leaf.id}-${page.name}',
                  ),
                  label: page.label,
                  // 大纲那颗以前是顶栏开关，快捷键跟着它一起搬过来。
                  tooltip: page == SidePage.outline
                      ? '大纲  ·  Ctrl+Shift+O'
                      : page.label,
                  icon: page.icon,
                  drag: SidePageDrag(
                    page,
                    label: page.label,
                    fromColumn: column,
                    fromPane: leaf.id,
                  ),
                ),
            ],
            index: group.index,
            // 右栏没有「聚焦哪一格」这回事：每一格都把当前页亮出来。
            focused: left ? leaf.id == _sideFocusId : true,
            trailingInset: top ? (kIsWeb ? 0 : kCaptionWidth) : 0,
            // 只有贴着窗口顶的那一条是拖窗口的那段；下格顶上再拖窗口就怪了。
            filler: left || top ? titleBarGrip() : null,
            onSelect: (int i) => _selectSideTab(column, leaf.id, i),
            // 侧边栏的页不能关：它们是一排常驻的视图，分割只能靠拖。
            onClose: (_) {},
            acceptsTab: (TabDrag t) =>
                t is SidePageDrag &&
                !(t.fromColumn == column && t.fromPane == leaf.id),
            onDropTab: (TabDrag t) {
              if (t is! SidePageDrag) return;
              _dropSidePage(column, leaf.id, DropZone.center, t);
            },
          ),
          Expanded(
            child: PaneDropZone(
              // 侧边栏的格子只收视图页，而且只上下切——它本来就很窄。
              verticalOnly: true,
              accepts: (TabDrag t) => t is SidePageDrag,
              onDrop: (DropZone zone, TabDrag t) {
                if (t is! SidePageDrag) return;
                _dropSidePage(column, leaf.id, zone, t);
              },
              child: _sidePageBody(
                column: column,
                paneId: leaf.id,
                page: group.current,
                width: width,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 一侧边栏的一格里装什么。
  ///
  /// 文件 / 搜索 / 标签共用一块 [NoteListPanel]，只是 `view` 不同；大纲 /
  /// 表格 / 图片是三块各自的面板。页可以住在任意一栏，所以这些分支不按
  /// 「哪一栏」分，只按页分。
  Widget _sidePageBody({
    required SideColumn column,
    required String paneId,
    required SidePage page,
    required double width,
  }) {
    return switch (page) {
      SidePage.files || SidePage.search || SidePage.tags => NoteListPanel(
        key: _listKeyFor(paneId),
        view: page.leftView!,
        onCreateNote: _createNote,
        onDeleteNotes: _confirmDeleteMany,
        onDeleteFolder: _confirmDeleteFolder,
        onSwitchView: (SidebarView v) =>
            _openPageInPane(column, paneId, SidePage.ofLeft(v)),
        onOpenNote: _openNote,
        onOpenCanvas: _openCanvasFile,
        onDeleteCanvas: _confirmDeleteCanvas,
        onOpenFile: _openVaultFile,
        // 搜索结果先开笔记，正文要等这一帧绑定完才可用，所以跳转挂到帧末。
        onRevealOffset: (int offset) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _editorKey.currentState?.goToOffset(offset);
          });
        },
      ),
      SidePage.outline => _OutlineRegion(
        currentLine: _cursorLine,
        width: width,
        onSelect: (int line) => _editorKey.currentState?.goToHeading(line),
      ),
      SidePage.table => TablePanel(
        width: width,
        value: _bodyValue,
        onApply: (MarkdownEditFn fn) => _editorKey.currentState?.applyEdit(fn),
        onJump: (int offset) => _editorKey.currentState?.goToOffset(offset),
      ),
      SidePage.images => _ImageRegion(
        width: width,
        onSelect: (int offset) => _editorKey.currentState?.goToOffset(offset),
      ),
    };
  }

  // ------------------------------------------------------------ 三份单例文档
  //
  // 图谱 / 白板 / 图片全局只有一份，装在某一格里。不在格子里的时候（被笔记
  // 顶掉、或者干脆没开），它们停在 [_park] 里——`Offstage` 不排版，但 State
  // 还在，所以搬回来时视角、相机、缩放都是原样。

  Widget _graphBody() => GraphView(
    key: _graphKey,
    notes: context.watch<NotesController>().allNotes,
    currentId: context.watch<NotesController>().selectedId,
    onOpenNote: _openFromGraph,
    settings: _settings,
  );

  /// 白板那一格。
  ///
  /// 文件进白板的**唯一**通道是左侧文件列表拖过来的笔记（桌面上的文件先拖
  /// 进列表导入成笔记）。画布那层 `DropRegion` 只负责把桌面来的一律挡回去；
  /// 文件夹拖拽不接——那是移动，不是引用。
  Widget _canvasBody() {
    final String? canvasPath = _canvas.path;
    return DragTarget<VaultDragPayload>(
      onWillAcceptWithDetails: (DragTargetDetails<VaultDragPayload> d) =>
          d.data.folder == null && d.data.referencePaths().isNotEmpty,
      onAcceptWithDetails: (DragTargetDetails<VaultDragPayload> d) {
        final Offset? pointer = d.data.pointer;
        final List<String> paths = d.data.referencePaths();
        if (pointer == null || paths.isEmpty) return;
        _canvasKey.currentState?.addReferencedNotesFromGlobal(paths, pointer);
      },
      builder:
          (
            BuildContext context,
            List<VaultDragPayload?> candidate,
            List<dynamic> rejected,
          ) => CanvasBoard(
            key: _canvasKey,
            document: context.watch<CanvasController>().document,
            onChanged: context.read<CanvasController>().markDirty,
            files: <({String path, String title})>[
              for (final Note note in context.watch<NotesController>().allNotes)
                (path: note.relativePath, title: _displayTitle(note)),
            ],
            // 文件卡片显示的就是这份正文：白板引用笔记，不是复制一份。
            // 笔记一改，外壳重建，卡片下一帧就是新的。
            noteBodies: <String, String>{
              for (final Note note in context.watch<NotesController>().allNotes)
                note.relativePath: note.body,
            },
            onOpenFile: _openFromCanvas,
            onOpenLink: _openCanvasLink,
            onEditFileBody: (String path, String body) =>
                context.read<NotesController>().writeNoteBody(path, body),
            // 图片卡片的字节：画布只认相对路径，读盘这一步在外壳（画布不能
            // 碰 `dart:io`，Web 也要编译）。
            imageBytesOf: (String path) {
              final String? vault = _notes.vaultPath;
              if (vault == null) return Future<Uint8List?>.value(null);
              return imageBytesAt('$vault/$path');
            },
            // 粘贴的截图先存成库里的一份文件，卡片只引用它（§14.20）。
            onSaveImage: (Uint8List png) {
              if (canvasPath == null) return Future<String?>.value(null);
              return _notes.saveCanvasImage(canvasPath, png);
            },
            // 从桌面拖进来的图片：读字节 → 存进库里 → 返回相对路径。
            onDropImageFiles: (List<String> paths) async {
              final List<String> out = <String>[];
              if (canvasPath == null) return out;
              for (final String path in paths) {
                final Uint8List? bytes = await imageBytesAt(path);
                if (bytes == null) continue;
                final String? saved = await _notes.saveCanvasImage(
                  canvasPath,
                  bytes,
                );
                if (saved != null) out.add(saved);
              }
              return out;
            },
          ),
    );
  }

  /// 图片页：所有图片共用这一份 State。换图只换 `_imagePath`，缩放状态由
  /// `didUpdateWidget` 复位，不重建整棵子树。
  Widget _imageBody() => ImagePane(
    key: _imageKey,
    source: _imagePath ?? '',
    absolutePath: '${_notes.vaultPath ?? ''}/${_imagePath ?? ''}',
    onOpenExternal: _openImageExternally,
  );

  /// 停靠区：暂时没有格子装着的单例文档挂在这儿。
  ///
  /// `Offstage` 只跳过排版和绘制，widget 和 State 都还在树上；再配合上面那
  /// 三个 `GlobalKey`，同一帧内把它从这儿搬回格子里，State 就跟着走了。
  Widget _park(Widget child) =>
      Offstage(offstage: true, child: SizedBox.expand(child: child));

  /// 把**聚焦那一格**换成另一屏。
  ///
  /// 分块之后「主区」不再是一整块：这个动作只作用于聚焦的格子，别的格子
  /// 各自看着自己的东西。
  void _selectMainView(MainView view) {
    if (_mainView == view) return;
    // 离开正文前把光标 / 选区记一笔：设置、模板这些页占着格子的时候编辑器
    // 不在树上，切回来时选区已经没了。模板「插入到光标处」全靠这一笔。
    if (_mainView == MainView.note) {
      _stashedSelection = _editorKey.currentState?.bodySelection;
    }
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
    final PaneDoc doc = switch (view) {
      MainView.note => const NoteDoc(null),
      MainView.graph => const GraphDoc(),
      MainView.canvas => const CanvasDoc(),
      MainView.image => const ImageDoc(),
      MainView.settings => const SettingsDoc(),
      MainView.templates => const TemplatesDoc(),
      MainView.trash => const TrashDoc(),
    };
    // 这一份已经在别的格里了：把焦点交给那一格，别把它搬过来。
    // 「点图谱标签」的意思是「我要看图谱」，不是「把图谱挪到我这儿」。
    if (doc.isSingleton) {
      for (final SplitLeaf<TabGroup<PaneDoc>> leaf
          in SplitTree.leaves<TabGroup<PaneDoc>>(_editorTree)) {
        if (leaf.id == _editorFocusId) continue;
        final int at = leaf.value.indexOf(doc);
        if (at < 0) continue;
        _selectTab(leaf.id, at);
        return;
      }
    }
    _openTabInFocus(doc);
  }

  /// 打开设置页（功能栏那颗齿轮、`Ctrl+,`）。
  ///
  /// 设置现在也是编辑区里的一页：开着就切过去，没开着就开在聚焦那一格。
  /// 以前这里弹一层 `showDialog`——改字号看不见正文，改完还得关掉。
  void _openSettings() => _selectMainView(MainView.settings);

  /// 关掉「白板」页（点 tab 上的 ×）。
  ///
  /// 和笔记标签一样，只有点 × 才算关：装着它的格子退回正文，文档本身放下
  /// （会先落盘）。文件还在，文件树里那一行照旧，点它就能再开。
  void _closeCanvas() {
    if (!_canvas.hasDocument) return;
    setState(() {
      _editorTree = _dropDoc(_editorTree, (PaneDoc d) => d is CanvasDoc);
    });
    // `close()` 会先 flush 再清空，然后通知——标签跟着 `hasDocument` 消失。
    unawaited(_canvas.close());
    _shellFocus.requestFocus();
  }

  /// 关掉「关系图谱」页。
  ///
  /// 和图谱页同一条口径：只有点 × 才算关。装着它的格子退回正文，图谱从树
  /// 上摘掉；下次再打开会是一张重新建好的图。
  void _closeGraph() {
    if (!_graphAlive) return;
    setState(() {
      _graphAlive = false;
      _editorTree = _dropDoc(_editorTree, (PaneDoc d) => d is GraphDoc);
    });
    _shellFocus.requestFocus();
  }

  /// 关掉「图片」页。
  ///
  /// 和图谱页同一条口径：只有点 × 才算关。装着它的格子退回正文，并且把
  /// [_imagePath] 清掉——下次点图片会重新进来（不再是上次那张）。
  void _closeImage() {
    if (_imagePath == null) return;
    setState(() {
      _imagePath = null;
      _editorTree = _dropDoc(_editorTree, (PaneDoc d) => d is ImageDoc);
    });
    _shellFocus.requestFocus();
  }

  /// 关掉「设置」页。
  ///
  /// 设置没有要放下的文档（不像白板要先落盘），摘掉这一页就完事；下次点齿轮
  /// 是同一页，停在原来滚动的位置（State 跟着 `GlobalKey` 走）。
  void _closeSettings() {
    setState(() {
      _editorTree = _dropDoc(_editorTree, (PaneDoc d) => d is SettingsDoc);
    });
    _shellFocus.requestFocus();
  }

  /// 关掉「模板」页。它没有要放下的文档，摘掉这一页就完事。
  void _closeTemplates() {
    setState(() {
      _editorTree = _dropDoc(_editorTree, (PaneDoc d) => d is TemplatesDoc);
    });
    _shellFocus.requestFocus();
  }

  /// 关掉「回收站」页。
  void _closeTrash() {
    setState(() {
      _editorTree = _dropDoc(_editorTree, (PaneDoc d) => d is TrashDoc);
    });
    _shellFocus.requestFocus();
  }

  /// 打开回收站（功能栏那颗垃圾桶）。以前是 `showTrashDialog` 弹窗。
  void _openTrash() => _selectMainView(MainView.trash);

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
    setState(() => _imagePath = file.relativePath);
    // 图片页只有一页，所有图片共用：第二张只是换这一页的内容。
    _openTabInFocus(const ImageDoc());
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
      _openTabInFocus(NoteDoc(note.id));
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
    _openTabInFocus(NoteDoc(noteId));
  }

  /// 列表里点开一篇笔记：选中它，并把主区切回正文。
  ///
  /// 只 `select` 不切视图，就是「点了没反应」——主区还停在图谱或白板上，
  /// 屏幕上的东西一点没变，用户只能再去找那个标签页。
  void _openNote(Note note) {
    _openTabInFocus(NoteDoc(note.id));
  }

  void _toggleSidebar() {
    final SettingsController settings = context.read<SettingsController>();
    settings.sidebarCollapsed = !settings.sidebarCollapsed;
    if (settings.focusMode) settings.focusMode = false;
  }

  /// 收 / 展右侧边栏——顶上那颗按钮是**右栏的**，不是编辑栏的。
  ///
  /// 收起走 [SettingsController.closeRightPanels]：和点右栏当前那一页一样，
  /// 整列关上、三颗开关一起落下。展开前先把三颗开关对齐上格当前页：
  /// [SettingsController.rememberRightView] 只改开关、不叫醒整列，而
  /// [_syncRightFromSettings] 看到「三颗都暗着 + 上格停着右栏页」会当成
  /// 收起——先亮开关、再开整列，才不会被自己的同步逻辑关回去。
  void _toggleRightSidebar() {
    if (_settings.rightSidebarVisible) {
      _settings.closeRightPanels();
      return;
    }
    final SidePage page = SplitTree.firstLeaf<TabGroup<SidePage>>(
      _rightTree,
    ).value.current;
    final RightView? view = page.rightView;
    if (view == null) {
      _settings.clearRightViewFlags();
    } else {
      _settings.rememberRightView(view);
    }
    _settings.rightSidebarVisible = true;
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
    // 新建的那篇会成为「活的那一份」，所以这里只是把标签切过去；标签组里
    // 还没有活的那一页时才真的多开一页。
    if (_notes.selectedId != null) _openTabInFocus(const NoteDoc(null));
  }

  // --------------------------------------------------------------- templates

  /// 打开模板页（功能栏那颗、`Ctrl+P`）。
  ///
  /// 以前是 `showTemplatePicker` 弹窗：插一次开一次。现在它是编辑区里的一页，
  /// 开着就一直开着，插完还留在原处。
  void _openTemplates() => _selectMainView(MainView.templates);

  /// 模板页上做的事。以前是弹窗的返回值，现在走回调——页面不关，做完接着看。
  Future<void> _handleTemplateAction(
    TemplatePickerAction action,
    Note? template,
  ) async {
    if (!mounted) return;
    switch (action) {
      case TemplatePickerAction.insert:
        if (template == null) return;
        // 先把正文翻回眼前：模板页占着这一格的时候，编辑器根本没挂在树上，
        // 光标也就无从谈起。切回去、等这一帧画完，再把光标放回原处。
        final TextSelection? selection = _stashedSelection;
        _selectMainView(MainView.note);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        final EditorPaneState? editor = _editorKey.currentState;
        if (selection != null) editor?.restoreSelection(selection);
        await _insertTemplate(template);
      case TemplatePickerAction.newNote:
        if (template == null) return;
        await _createNoteFromTemplate(template);
        if (!mounted) return;
        _selectMainView(MainView.note);
      case TemplatePickerAction.openFolder:
        await _showTemplatesFolder();
      case TemplatePickerAction.newTemplate:
        await _createTemplateNote();
      case TemplatePickerAction.edit:
        if (template == null) return;
        _selectMainView(MainView.note);
        _notes.select(template.id);
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
    // 文件页可能被搬到右栏了；[_showPage] 会把它翻出来并告诉我们它在哪一格。
    final String? paneId = _showPage(SidePage.files);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || paneId == null) return;
    _listKeyFor(paneId).currentState?.revealFolder(folder);
  }

  Future<void> _createTemplateNote() async {
    final String folder = _settings.templatesFolder;
    if (!await _notes.ensureFolder(folder)) return;
    if (!mounted) return;
    // 文件页可能被搬到右栏了；先把它翻到眼前，新模板才看得见。
    _showPage(SidePage.files);
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
              _openTemplates,
          const SingleActivator(LogicalKeyboardKey.comma, control: true):
              _openSettings,
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
    // 布局变没变在这一帧顺手看一眼，变了就排一次落盘（见 [_maybeSaveEditorLayout]）。
    _maybeSaveEditorLayout();
    final AppPalette base = context.palette;
    // 外壳只需要错误横幅；正文、选中等变化交给各自的面板订阅。
    // 以前这里 watch 整个控制器，用户每敲一个字都会重建整棵外壳。
    final String? error = context.select<NotesController, String?>(
      (NotesController notes) => notes.error,
    );
    final SettingsController settings = context.watch<SettingsController>();
    final bool zen = settings.focusMode;
    // 壁纸外观：还是同一块石墨，只是把大块面层压到用户调的不透明度；
    // 文字、图标和 1px 缝线不在这一版里变淡（见 `AppPalette.backdrop`）。
    final bool wallpaper = settings.appearance == ShellAppearance.wallpaper;
    final AppPalette p = wallpaper
        ? base.backdrop(settings.surfaceOpacity)
        : base;

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
                // 图谱、图片和设置要整块画布：右侧那一栏（大纲 / 表格 /
                // 图片列表）在它们里收起来，退出来自动回来——所以这里只做
                // 「不显示」，不去改 `settings.*Visible`。改设置会写盘，而且
                // 「关掉再打开」会把用户原来的选择弄丢。
                final bool panelAllowed =
                    _mainView != MainView.graph &&
                    _mainView != MainView.image &&
                    _mainView != MainView.settings &&
                    _mainView != MainView.templates &&
                    _mainView != MainView.trash;
                // 右栏开不开由单独的偏好说（`rightSidebarVisible`）。以前是
                // 「三颗面板开关里有一颗亮着 = 开着」，但右栏现在也可能停着
                // 文件 / 搜索 / 标签——那三颗开关只代表右栏的面板页，决定不了
                // 整列还在不在。
                final bool showRight =
                    panelAllowed &&
                    !zen &&
                    c.maxWidth >= AppLayout.outlineMinShellWidth &&
                    settings.rightSidebarVisible;
                // The toggle pair aligns with the *panel*, not with the drag
                // handle in front of it, so the handle's width is not counted.
                // 右栏的几格共用同一列、同一个宽度，所以这里不需要分支。
                final double rightInset = showRight
                    ? settings.rightPanelWidth
                    : 0;
                // 右栏那颗收 / 展按钮：图谱 / 图片里右栏整列不出现，窗口挤到
                // 容不下右栏时也不出现——留着能点却没东西可开，比不画更怪。
                final bool showRightToggle =
                    panelAllowed &&
                    !zen &&
                    c.maxWidth >= AppLayout.outlineMinShellWidth;
                // 右栏那几格的顶上还是右栏的标签条；编辑区最右那一格的标签
                // 条要避开收 / 展按钮。右栏收起时没有那三颗面板图标了——它们
                // 是右栏自己的页，跟着整列一起收——右端只剩这颗按钮和三个
                // 窗口按钮，标签条按它们让位。
                final double stripTrailingInset = rightInset > 0
                    ? kRightSidebarToggleSlot
                    : kCaptionWidth +
                          (showRightToggle ? kRightSidebarToggleSlot : 0);
                // 只有贴着窗口右边缘的那几格要让位。左右分屏时左边那格离右边还
                // 远着，给它也留 220px，看起来就是标签条中间空了一大块、加号被
                // 推到格子中间。
                final Set<String> rightEdgePanes =
                    SplitTree.leavesTouchingEnd<TabGroup<PaneDoc>>(
                      _editorTree,
                      Axis.horizontal,
                    ).map((SplitLeaf<TabGroup<PaneDoc>> l) => l.id).toSet();
                // ⛔ **顶上只有一条带子**：标签条就顶在窗口最上面，顶栏的按钮
                // 浮在它上面。以前这里是 `Column[顶栏 40, 正文]`，标签条又被塞
                // 进每一格的顶上，于是窗口上方压了两条横带、上面那条还是空的
                // ——用户原话：「让 tab 还是在顶部栏显示啊。为什么往下移了？」
                return Theme(
                  data: Theme.of(
                    context,
                  ).copyWith(extensions: <ThemeExtension<dynamic>>[p]),
                  child: Stack(
                    clipBehavior: Clip.none,
                    fit: StackFit.expand,
                    children: <Widget>[
                      // 壁纸外观：图垫在所有面板下面，面板的面层已经是半透明的。
                      // 它不接指针，只当背景。
                      if (wallpaper)
                        Positioned.fill(
                          child: Image.asset(
                            _kShellWallpaper,
                            key: const ValueKey<String>('shell-wallpaper'),
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          // The rail keeps only the global actions. 文件 / 搜索 /
                          // 标签 已经和右栏的大纲 / 表格 / 图片 一样，是侧边栏
                          // 自己的标签页，不再占这一列。
                          if (!zen)
                            AppRail(
                              // 功能栏跟着右边那块地走：边栏在就是侧边栏色，
                              // 收起就并进编辑区的纸面；顶上 40 永远是顶带色。
                              sidebarVisible: !settings.sidebarCollapsed,
                              onOpenTemplates: _openTemplates,
                              onOpenGraph: () =>
                                  _selectMainView(MainView.graph),
                              onOpenCanvas: _newCanvasBoard,
                              onOpenTrash: _openTrash,
                              onOpenSettings: _openSettings,
                              graphActive: _mainView == MainView.graph,
                              canvasActive: _mainView == MainView.canvas,
                              settingsActive: _mainView == MainView.settings,
                              templatesActive: _mainView == MainView.templates,
                              trashActive: _mainView == MainView.trash,
                            ),
                          // The panes each get a handle on the edge that faces the
                          // editor, and each handle is carved out of the pane it
                          // follows, so its hairline lands on the seam and the
                          // boundary reads the same everywhere.
                          if (!zen && !settings.sidebarCollapsed) ...<Widget>[
                            SizedBox(
                              width: settings.listWidth,
                              // 侧边栏和编辑区共用同一个分割组件；两侧边栏又
                              // 共用同一种页，所以叶子只按栏别画。
                              child: SplitHost<TabGroup<SidePage>>(
                                root: _sideTree,
                                dividerThickness: AppLayout.splitSeamWidth,
                                // 缝跟着侧边栏的底色：两格之间不画线。
                                dividerColor: p.sidebar,
                                onRatioChanged:
                                    (
                                      SplitBranch<TabGroup<SidePage>> branch,
                                      double ratio,
                                    ) {
                                      setState(() {
                                        _sideTree =
                                            SplitTree.setRatio<
                                              TabGroup<SidePage>
                                            >(_sideTree, branch.id, ratio);
                                      });
                                      // 拖动会连着来几十个 delta，合并写盘。
                                      _scheduleSideLayoutSave();
                                    },
                                leafBuilder:
                                    (
                                      BuildContext context,
                                      SplitLeaf<TabGroup<SidePage>> leaf,
                                    ) => _sidePane(SideColumn.left, leaf),
                              ),
                            ),
                            ResizeHandle(
                              background: p.sidebar,
                              onDelta: (double d) =>
                                  settings.listWidth = settings.listWidth + d,
                            ),
                          ],
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                // 格子树。每一格的 State（撤销栈、光标、
                                // 滚动位置）都活在树上，所以切走再回来
                                // 还是原样——这也是为什么整棵树一直挂着，
                                // 而不是按当前视图重建。
                                SplitHost<TabGroup<PaneDoc>>(
                                  root: _editorTree,
                                  dividerThickness: AppLayout.splitSeamWidth,
                                  onRatioChanged:
                                      (
                                        SplitBranch<TabGroup<PaneDoc>> branch,
                                        double ratio,
                                      ) {
                                        setState(() {
                                          _editorTree =
                                              SplitTree.setRatio<
                                                TabGroup<PaneDoc>
                                              >(_editorTree, branch.id, ratio);
                                        });
                                      },
                                  leafBuilder:
                                      (
                                        BuildContext context,
                                        SplitLeaf<TabGroup<PaneDoc>> leaf,
                                      ) => _editorPane(
                                        leaf,
                                        trailingInset:
                                            rightEdgePanes.contains(leaf.id)
                                            ? stripTrailingInset
                                            : 0,
                                      ),
                                ),
                                // 停靠区：这三份文档全局只有一份，眼下
                                // 没有格子装着它们（被笔记顶掉了、或者
                                // 压根没开）时挂在这儿。`Offstage` 只跳过
                                // 排版，State 还在；配合各自的 GlobalKey，
                                // 同一帧内搬回格子里，视角和相机都跟着走。
                                if (_graphAlive && !_hasDoc('graph'))
                                  _park(_graphBody()),
                                if (_canvas.hasDocument && !_hasDoc('canvas'))
                                  _park(_canvasBody()),
                                if (_imagePath != null && !_hasDoc('image'))
                                  _park(_imageBody()),
                                // 状态浮片：编辑区右下角，压在所有格子和停靠区
                                // 上面。位置不跟格走；非笔记页淡出，免得「看着
                                // 图谱却显示某篇笔记的字数」。
                                //
                                // ⛔ 不用 `Positioned(right:, bottom:)`：只给
                                // 两个定位边时 Stack 交给子树的宽度是无限的，
                                // 浮片里的 LayoutBuilder 永远读到 ∞，窄窗收项
                                // 那三档就再也不会触发。铺满 + Align 才能把
                                // 编辑区宽度原样传下去。
                                Positioned.fill(
                                  child: Align(
                                    alignment: Alignment.bottomRight,
                                    child: Padding(
                                      padding: const EdgeInsets.only(
                                        right: 14,
                                        bottom: 12,
                                      ),
                                      child: IgnorePointer(
                                        child: AnimatedSwitcher(
                                          duration: AppMotion.fast,
                                          child: switch (_focusDoc) {
                                            NoteDoc(:final String? noteId) =>
                                              EditorStatusFloat(
                                                key: const ValueKey<String>(
                                                  'editor-status-float',
                                                ),
                                                noteId: noteId,
                                                caret: _caret,
                                              ),
                                            _ => const SizedBox.shrink(),
                                          },
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (showRight) ...<Widget>[
                            // The handle sits left of the right column, so
                            // dragging it rightwards narrows the column.
                            //
                            // ⛔ 和左栏那条同一个口径：缝从**它右边那一栏**身上
                            // 切下来，整条（连顶上 40px）都是右栏的底色，于是缝
                            // 和右栏连成一片，只剩编辑区与右栏之间那道正常的
                            // 色差。⛔ 别再填 `p.surface` / `p.canvas`——那会在
                            // 两栏之间画出一条比两边都暗的竖带。用户原话：「编辑
                            // 栏和右侧边栏之间怎么有一条这么粗的黑线？移除它。」
                            ResizeHandle(
                              background: p.sidebar,
                              onDelta: (double d) => settings.rightPanelWidth =
                                  settings.rightPanelWidth - d,
                            ),
                            // 右栏自己也是一棵分割树，叶子和左栏一样装
                            // [SidePage]——所以「文件」能拖到这边，「大纲」也
                            // 能拖到左边。整列从窗口最上面开始：上格的标签条
                            // 正好占着顶栏那 40px，不用再给顶栏垫一条空白。
                            SizedBox(
                              width: settings.rightPanelWidth,
                              child: SplitHost<TabGroup<SidePage>>(
                                root: _rightTree,
                                dividerThickness: AppLayout.splitSeamWidth,
                                // 同上：缝填右栏的底色，两格之间不画线。
                                dividerColor: p.sidebar,
                                onRatioChanged:
                                    (
                                      SplitBranch<TabGroup<SidePage>> branch,
                                      double ratio,
                                    ) {
                                      setState(() {
                                        _rightTree =
                                            SplitTree.setRatio<
                                              TabGroup<SidePage>
                                            >(_rightTree, branch.id, ratio);
                                      });
                                      _scheduleSideLayoutSave();
                                    },
                                leafBuilder:
                                    (
                                      BuildContext context,
                                      SplitLeaf<TabGroup<SidePage>> leaf,
                                    ) => _sidePane(SideColumn.right, leaf),
                              ),
                            ),
                          ],
                        ],
                      ),
                      // The notice lives in the window's top-right corner,
                      // where the eye already is after a toolbar action.
                      // It may overlap the outline; the countdown is short
                      // and it is the one piece of chrome allowed to float.
                      // 它在标签条下面——标签条现在就是窗口最上面那条带子。
                      Positioned(
                        top: AppLayout.titleBarHeight + AppSpace.xs,
                        left: 10,
                        right: 10,
                        child: Align(
                          alignment: Alignment.topRight,
                          child: NoticeHost(controller: _notices),
                        ),
                      ),
                      // 出错时那条横幅也压在正文顶上，不另占一行：顶栏和标签条
                      // 已经是同一条带子，再插一条就把标签推下去了。
                      if (error != null)
                        Positioned(
                          top: AppLayout.titleBarHeight,
                          left: 0,
                          right: 0,
                          child: _ErrorBanner(message: error),
                        ),
                      // 顶栏：只剩几颗浮在标签条上面的按钮。中间留空，鼠标穿过去
                      // 就是下面的标签条——它没有自己的底色，也没有命中区域。
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: AppLayout.titleBarHeight,
                        child: AppTitleBar(
                          onToggleSidebar: _toggleSidebar,
                          showSidebarToggle: !zen,
                          rightInset: rightInset,
                          showRightToggle: showRightToggle,
                          onToggleRight: _toggleRightSidebar,
                        ),
                      ),
                    ],
                  ),
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
