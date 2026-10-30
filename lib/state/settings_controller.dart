import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_enums.dart';
import '../core/theme/app_palette.dart';
import '../core/theme/app_tokens.dart';
import '../data/models/note.dart';
import 'template_settings.dart';

/// User preferences that survive restarts.
///
/// Everything here is a *view* preference — the notes themselves live in the
/// vault, so wiping these settings never touches user content.
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs);

  final SharedPreferences _prefs;

  static const String _kSort = 'nrs.sort';
  static const String _kSidebar = 'nrs.sidebarCollapsed';
  static const String _kOutline = 'nrs.outlineVisible';
  static const String _kTablePanel = 'nrs.tablePanelVisible';
  static const String _kImagePanel = 'nrs.imagePanelVisible';
  static const String _kRightVisible = 'nrs.rightSidebarVisible';
  static const String _kSideLayout = 'nrs.sideLayout';
  static const String _kRightLayout = 'nrs.rightLayout';
  static const String _kListWidth = 'nrs.listWidth';
  static const String _kRightPanelWidth = 'nrs.rightPanelWidth';

  /// 最右栏曾经按面板各存一条宽度（大纲 / 表格 / 图片）。三块面板本来就是
  /// 同一列轮流住，宽度却各记一份，切换面板时列边缘会跳一下。合并之后第一次
  /// 读取时把旧值捡回来——用户拖过的那一列不该在升级后跳回默认值。
  static const List<String> _kLegacyPanelWidths = <String>[
    'nrs.outlineWidth',
    'nrs.tablePanelWidth',
    'nrs.imagePanelWidth',
  ];
  static const String _kProseSize = 'nrs.proseSize';
  static const String _kGraphOrphans = 'nrs.graph.showOrphans';
  static const String _kGraphFolderColors = 'nrs.graph.useFolderColors';
  static const String _kGraphNodeScale = 'nrs.graph.nodeScale';
  static const String _kGraphLinkScale = 'nrs.graph.linkScale';
  static const String _kGraphLabelStart = 'nrs.graph.labelZoomStart';
  static const String _kGraphLabelFull = 'nrs.graph.labelZoomFull';
  static const String _kGraphSpin = 'nrs.graph.spinScale';
  static const String _kGraphSpinFalloff = 'nrs.graph.spinFalloff';
  static const String _kGraphDragLink = 'nrs.graph.dragLink';
  static const String _kGraphDragFarPull = 'nrs.graph.dragFarPull';
  static const String _kGraphDragStiffness = 'nrs.graph.dragStiffness';
  static const String _kGraphDragRepel = 'nrs.graph.dragRepel';
  static const String _kGraphDragGap = 'nrs.graph.dragGap';
  static const String _kFocus = 'nrs.focusMode';
  static const String _kSessionTabs = 'nrs.sessionTabs';
  static const String _kSessionSelected = 'nrs.sessionSelected';
  static const String _kSessionCanvas = 'nrs.sessionCanvas';
  static const String _kSessionCanvasActive = 'nrs.sessionCanvasActive';
  static const String _kTemplatesFolder = 'nrs.templatesFolder';
  static const String _kFolderTemplates = 'nrs.folderTemplates';
  static const String _kAutoApplyFolderTemplates =
      'nrs.autoApplyFolderTemplates';
  static const String _kTemplateHotkeys = 'nrs.templateHotkeys';

  static Future<SettingsController> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return SettingsController(prefs);
  }

  // ------------------------------------------------------------------ theme
  //
  // 只有一块色板：午夜靛（深色）。明暗模式、配色方案和自定义配色都在
  // 2026-10-27 移除了——它们各自都要一套「读到不认识的存储值怎么办」的兜底，
  // 而真正被用到的只有这一块。旧的偏好键（`nrs.theme`、`nrs.themePreset`、
  // `nrs.themeOverride.*`）不再读也不再写，留在磁盘上不碍事。

  /// 全应用的颜色。返回的是同一个 `const` 实例，所以 `LiveLineStyle` 那种
  /// 「按实例判断主题变没变」的地方天然稳定，不会因为一次重建就重排全文。
  AppPalette get palette => AppPalette.midnight;

  // ------------------------------------------------------------------ sorting

  SortMode get sort {
    final String? raw = _prefs.getString(_kSort);
    return SortMode.values.firstWhere(
      (SortMode e) => e.name == raw,
      orElse: () => SortMode.updatedDesc,
    );
  }

  set sort(SortMode value) {
    if (sort == value) return;
    _prefs.setString(_kSort, value.name);
    notifyListeners();
  }

  // ------------------------------------------------------------------ editor

  /// Focus mode dims everything but the text you are writing.
  bool get focusMode => _prefs.getBool(_kFocus) ?? false;

  set focusMode(bool value) {
    if (focusMode == value) return;
    _prefs.setBool(_kFocus, value);
    notifyListeners();
  }

  // ------------------------------------------------------------------ layout

  bool get sidebarCollapsed => _prefs.getBool(_kSidebar) ?? false;

  set sidebarCollapsed(bool value) {
    if (sidebarCollapsed == value) return;
    _prefs.setBool(_kSidebar, value);
    notifyListeners();
  }

  bool get outlineVisible => _prefs.getBool(_kOutline) ?? true;

  /// 整条右栏开不开。
  ///
  /// 以前「开着哪块面板」就是「整列开不开」，三颗开关互斥地兼着两个意思。
  /// 两侧边栏互通之后，右栏上格也可能停在文件 / 搜索 / 标签上——那时三颗
  /// 开关都说不清这一列算不算开。所以拆出一颗独立的开关：它只管整列，
  /// [_kOutline] / [_kTablePanel] / [_kImagePanel] 只管上格停在哪一页。
  ///
  /// 没存过时按老偏好的意思推：有任一面板开着 = 整列开着。
  bool get rightSidebarVisible =>
      _prefs.getBool(_kRightVisible) ??
      (outlineVisible || tablePanelVisible || imagePanelVisible);

  set rightSidebarVisible(bool value) {
    // 比的是**键里那颗值**，不是推导出来的结果。没存过的时候，整列的
    // 开合是看三颗面板开关推出来的；那一刻把它写成显式的 `true` 很重要：
    // 右栏上格一换成文件 / 搜索 / 标签，三颗开关就会落下，推导值会翻成
    // `false`，整列跟着消失。把「用户正看着右栏」这件事先钉住。
    if (_prefs.getBool(_kRightVisible) == value) return;
    final bool changed = rightSidebarVisible != value;
    _prefs.setBool(_kRightVisible, value);
    if (changed) notifyListeners();
  }

  /// The outline, the table tools and the image list share the far-right
  /// column, so at most one of them is open. Turning one on closes the others
  /// in the same write — the shell can then read the three flags without
  /// cross-checking them.
  set outlineVisible(bool value) {
    if (outlineVisible == value) {
      if (value) rightSidebarVisible = true;
      return;
    }
    _prefs.setBool(_kOutline, value);
    if (value) {
      _prefs.setBool(_kTablePanel, false);
      _prefs.setBool(_kImagePanel, false);
      _prefs.setBool(_kRightVisible, true);
    }
    notifyListeners();
  }

  bool get tablePanelVisible => _prefs.getBool(_kTablePanel) ?? false;

  set tablePanelVisible(bool value) {
    if (tablePanelVisible == value) {
      if (value) rightSidebarVisible = true;
      return;
    }
    _prefs.setBool(_kTablePanel, value);
    if (value) {
      _prefs.setBool(_kOutline, false);
      _prefs.setBool(_kImagePanel, false);
      _prefs.setBool(_kRightVisible, true);
    }
    notifyListeners();
  }

  bool get imagePanelVisible => _prefs.getBool(_kImagePanel) ?? false;

  set imagePanelVisible(bool value) {
    if (imagePanelVisible == value) {
      if (value) rightSidebarVisible = true;
      return;
    }
    _prefs.setBool(_kImagePanel, value);
    if (value) {
      _prefs.setBool(_kOutline, false);
      _prefs.setBool(_kTablePanel, false);
      _prefs.setBool(_kRightVisible, true);
    }
    notifyListeners();
  }

  /// 只记「右栏上格停在哪一页」，不碰整列的开合。
  ///
  /// 上格被拖成文件 / 搜索 / 标签时，三颗开关都得落下；但它只是换页，不该
  /// 顺手把整列关上。
  void rememberRightView(RightView view) {
    final bool outline = view == RightView.outline;
    final bool table = view == RightView.table;
    final bool images = view == RightView.images;
    if (outlineVisible == outline &&
        tablePanelVisible == table &&
        imagePanelVisible == images) {
      return;
    }
    _prefs.setBool(_kOutline, outline);
    _prefs.setBool(_kTablePanel, table);
    _prefs.setBool(_kImagePanel, images);
    notifyListeners();
  }

  /// 三颗都落下（右栏上格停在左栏的某页时，它们都不再代表上格）。
  void clearRightViewFlags() {
    if (!outlineVisible && !tablePanelVisible && !imagePanelVisible) return;
    _prefs.setBool(_kOutline, false);
    _prefs.setBool(_kTablePanel, false);
    _prefs.setBool(_kImagePanel, false);
    notifyListeners();
  }

  /// 收起整个右栏：整列关上，三颗开关一起落下去。
  ///
  /// 「收起」不等于「换一块面板继续占着」——点当前那格顶上的图标、或者整列
  /// 的开关，要的是它走开、把正文还给窗口。树本身不丢：下次从任意一颗开关
  /// 打开时，分格和页都还在（布局另有 [saveSidebarLayout] 落盘）。
  void closeRightPanels() {
    final bool hadView =
        outlineVisible || tablePanelVisible || imagePanelVisible;
    if (!hadView && !rightSidebarVisible) return;
    _prefs.setBool(_kOutline, false);
    _prefs.setBool(_kTablePanel, false);
    _prefs.setBool(_kImagePanel, false);
    _prefs.setBool(_kRightVisible, false);
    notifyListeners();
  }

  double get listWidth =>
      _prefs.getDouble(_kListWidth) ?? AppLayout.listDefaultWidth;

  set listWidth(double value) {
    final double clamped = value.clamp(
      AppLayout.listMinWidth,
      AppLayout.listMaxWidth,
    );
    if ((listWidth - clamped).abs() < 0.5) return;
    _prefs.setDouble(_kListWidth, clamped);
    notifyListeners();
  }

  /// 最右栏的宽度，大纲 / 表格 / 图片三块面板共用。
  ///
  /// 三块面板轮流住在同一列里，宽度只有**一份**：拖任何一块的把手改的都是
  /// 这个值，切换面板时列边缘不会动。
  double get rightPanelWidth {
    final double saved =
        _prefs.getDouble(_kRightPanelWidth) ??
        _kLegacyPanelWidths
            .map(_prefs.getDouble)
            .firstWhere((double? v) => v != null, orElse: () => null) ??
        AppLayout.rightPanelWidth;
    return saved.clamp(
      AppLayout.rightPanelMinWidth,
      AppLayout.rightPanelMaxWidth,
    );
  }

  set rightPanelWidth(double value) {
    final double clamped = value.clamp(
      AppLayout.rightPanelMinWidth,
      AppLayout.rightPanelMaxWidth,
    );
    if ((rightPanelWidth - clamped).abs() < 0.5) return;
    _prefs.setDouble(_kRightPanelWidth, clamped);
    notifyListeners();
  }

  // ------------------------------------------------------------ 侧边栏布局
  //
  // 左栏和右栏各是一棵分割树。分几格、每格排着哪些页、上下比例多少，都是
  // 用户摆出来的视图状态——关掉再打开、退出再启动都得是原样。树本身住在
  // 外壳里（不可变结构），这里只存编码好的那一小段 JSON。

  /// 左栏布局；`null` = 还没存过（用默认的一格三页）。
  String? get sideLayout => _prefs.getString(_kSideLayout);

  /// 右栏布局；`null` = 还没存过。
  String? get rightLayout => _prefs.getString(_kRightLayout);

  /// 两侧布局一起写。值没变就不碰磁盘——分屏拖动会连着来很多次。
  ///
  /// 这里**不**通知监听者：布局不是主题 / 宽度那种谁都要看的东西，外壳自己
  /// 改完自己画，别的面板不需要因此重建。
  void saveSidebarLayout({required String left, required String right}) {
    if (_prefs.getString(_kSideLayout) != left) {
      _prefs.setString(_kSideLayout, left);
    }
    if (_prefs.getString(_kRightLayout) != right) {
      _prefs.setString(_kRightLayout, right);
    }
  }

  // ------------------------------------------------------------ typography

  /// Body size of the editor, in logical pixels.
  double get proseSize => _prefs.getDouble(_kProseSize) ?? 15.5;

  set proseSize(double value) {
    final double clamped = value.clamp(13, 22);
    if ((proseSize - clamped).abs() < 0.05) return;
    _prefs.setDouble(_kProseSize, clamped);
    notifyListeners();
  }

  // ------------------------------------------------------------------ graph

  /// 图谱设置。读取返回 `null` 表示从未存过，调用方回落到
  /// [GraphSettings] 的默认值——默认值只在那一处维护，不在这里再抄一遍。
  bool? get graphShowOrphans => _prefs.getBool(_kGraphOrphans);

  set graphShowOrphans(bool value) {
    if (_prefs.getBool(_kGraphOrphans) == value) return;
    _prefs.setBool(_kGraphOrphans, value);
    notifyListeners();
  }

  bool? get graphUseFolderColors => _prefs.getBool(_kGraphFolderColors);

  set graphUseFolderColors(bool value) {
    if (_prefs.getBool(_kGraphFolderColors) == value) return;
    _prefs.setBool(_kGraphFolderColors, value);
    notifyListeners();
  }

  double? get graphNodeScale => _prefs.getDouble(_kGraphNodeScale);

  set graphNodeScale(double value) {
    if (_prefs.getDouble(_kGraphNodeScale) == value) return;
    _prefs.setDouble(_kGraphNodeScale, value);
    notifyListeners();
  }

  double? get graphLinkScale => _prefs.getDouble(_kGraphLinkScale);

  set graphLinkScale(double value) {
    if (_prefs.getDouble(_kGraphLinkScale) == value) return;
    _prefs.setDouble(_kGraphLinkScale, value);
    notifyListeners();
  }

  double? get graphLabelZoomStart => _prefs.getDouble(_kGraphLabelStart);

  set graphLabelZoomStart(double value) {
    if (_prefs.getDouble(_kGraphLabelStart) == value) return;
    _prefs.setDouble(_kGraphLabelStart, value);
    notifyListeners();
  }

  double? get graphLabelZoomFull => _prefs.getDouble(_kGraphLabelFull);

  set graphLabelZoomFull(double value) {
    if (_prefs.getDouble(_kGraphLabelFull) == value) return;
    _prefs.setDouble(_kGraphLabelFull, value);
    notifyListeners();
  }

  double? get graphSpinScale => _prefs.getDouble(_kGraphSpin);

  set graphSpinScale(double value) {
    if (_prefs.getDouble(_kGraphSpin) == value) return;
    _prefs.setDouble(_kGraphSpin, value);
    notifyListeners();
  }

  /// 拖动转动随放大倍率减速的强度（指数）。
  double? get graphSpinFalloff => _prefs.getDouble(_kGraphSpinFalloff);

  set graphSpinFalloff(double value) {
    if (_prefs.getDouble(_kGraphSpinFalloff) == value) return;
    _prefs.setDouble(_kGraphSpinFalloff, value);
    notifyListeners();
  }

  double? get graphDragLink => _prefs.getDouble(_kGraphDragLink);

  set graphDragLink(double value) {
    if (_prefs.getDouble(_kGraphDragLink) == value) return;
    _prefs.setDouble(_kGraphDragLink, value);
    notifyListeners();
  }

  double? get graphDragFarPull => _prefs.getDouble(_kGraphDragFarPull);

  set graphDragFarPull(double value) {
    if (_prefs.getDouble(_kGraphDragFarPull) == value) return;
    _prefs.setDouble(_kGraphDragFarPull, value);
    notifyListeners();
  }

  double? get graphDragStiffness => _prefs.getDouble(_kGraphDragStiffness);

  set graphDragStiffness(double value) {
    if (_prefs.getDouble(_kGraphDragStiffness) == value) return;
    _prefs.setDouble(_kGraphDragStiffness, value);
    notifyListeners();
  }

  double? get graphDragRepel => _prefs.getDouble(_kGraphDragRepel);

  set graphDragRepel(double value) {
    if (_prefs.getDouble(_kGraphDragRepel) == value) return;
    _prefs.setDouble(_kGraphDragRepel, value);
    notifyListeners();
  }

  double? get graphDragGap => _prefs.getDouble(_kGraphDragGap);

  set graphDragGap(double value) {
    if (_prefs.getDouble(_kGraphDragGap) == value) return;
    _prefs.setDouble(_kGraphDragGap, value);
    notifyListeners();
  }

  // --------------------------------------------------------------- templates

  /// Vault folder that holds template notes.
  ///
  /// Stored normalized and case-preserving. An empty or climbing path falls
  /// back to the default folder rather than turning the whole vault into
  /// templates.
  String get templatesFolder {
    final String stored = Note.normalizeFolderPath(
      _prefs.getString(_kTemplatesFolder) ?? '',
    );
    return stored.isEmpty ? kDefaultTemplatesFolder : stored;
  }

  set templatesFolder(String value) {
    final String normalized = Note.normalizeFolderPath(value);
    final String next = normalized.isEmpty
        ? kDefaultTemplatesFolder
        : normalized;
    if (templatesFolder == next) return;
    _prefs.setString(_kTemplatesFolder, next);
    notifyListeners();
  }

  List<FolderTemplateRule> get folderTemplateRules =>
      decodeFolderTemplateRules(_prefs.getString(_kFolderTemplates));

  set folderTemplateRules(List<FolderTemplateRule> value) {
    final String encoded = encodeFolderTemplateRules(value);
    if (_prefs.getString(_kFolderTemplates) == encoded) return;
    _prefs.setString(_kFolderTemplates, encoded);
    notifyListeners();
  }

  /// Whether a brand-new note picks up its folder's template.
  bool get autoApplyFolderTemplates =>
      _prefs.getBool(_kAutoApplyFolderTemplates) ?? false;

  set autoApplyFolderTemplates(bool value) {
    if (autoApplyFolderTemplates == value) return;
    _prefs.setBool(_kAutoApplyFolderTemplates, value);
    notifyListeners();
  }

  /// Template shortcuts, keyed by template note id.
  Map<String, TemplateHotkey> get templateHotkeys =>
      decodeTemplateHotkeys(_prefs.getString(_kTemplateHotkeys));

  set templateHotkeys(Map<String, TemplateHotkey> value) {
    final String encoded = encodeTemplateHotkeys(value);
    if (_prefs.getString(_kTemplateHotkeys) == encoded) return;
    _prefs.setString(_kTemplateHotkeys, encoded);
    notifyListeners();
  }

  // ------------------------------------------------------------- tab session
  //
  // 标签栏属于「下次打开时的样子」：和面板宽度一样是视图状态，不写进笔记。

  /// 上次退出时开着的标签（笔记 id，按标签顺序）；`null` 表示还没存过。
  ///
  /// 空列表是有效状态：用户把标签全关了，下次启动也不该替他打开一篇。
  List<String>? get sessionTabs => _prefs.getStringList(_kSessionTabs);

  /// 上次退出时选中的标签，没有选中页时为 `null`。
  String? get sessionSelectedTab => _prefs.getString(_kSessionSelected);

  /// 记下当前的标签栏；值没变就不碰磁盘。
  ///
  /// 通知每次正文输入也会来，而输入并不改变标签——不比较就会在打字时反复
  /// 重写整个偏好文件。
  void saveSession(List<String> tabs, String? selectedTab) {
    final bool sameTabs = listEquals(_prefs.getStringList(_kSessionTabs), tabs);
    final bool sameSelected =
        _prefs.getString(_kSessionSelected) == selectedTab;
    if (sameTabs && sameSelected) return;
    _prefs.setStringList(_kSessionTabs, tabs);
    if (selectedTab == null) {
      _prefs.remove(_kSessionSelected);
    } else {
      _prefs.setString(_kSessionSelected, selectedTab);
    }
  }

  // ------------------------------------------------------------- 白板会话
  //
  // 白板只有一页：同一时刻只开着一块（`CanvasController` 就一份文档）。
  // 所以这里存的是「上次开着哪一块」而不是一串标签。

  /// 上次退出时开着的白板（vault 相对路径），`null` = 没开。
  String? get sessionCanvasPath => _prefs.getString(_kSessionCanvas);

  /// 上次退出时主区停在哪——true 表示当时正看着那块白板。
  ///
  /// 单看 [sessionCanvasPath] 不够：白板页开着但用户在写笔记时，下次启动
  /// 该回到那篇笔记，而不是把白板顶到前面。
  bool get sessionCanvasActive =>
      _prefs.getBool(_kSessionCanvasActive) ?? false;

  /// 记下白板那一页的状态；值没变就不碰磁盘。
  void saveCanvasSession({required String? path, required bool active}) {
    // 没有白板就没有「正在看白板」这回事，两个键必须一起成立。
    final bool wantActive = path != null && active;
    final bool samePath = _prefs.getString(_kSessionCanvas) == path;
    final bool sameActive = sessionCanvasActive == wantActive;
    if (samePath && sameActive) return;
    if (path == null) {
      _prefs.remove(_kSessionCanvas);
    } else {
      _prefs.setString(_kSessionCanvas, path);
    }
    if (wantActive) {
      _prefs.setBool(_kSessionCanvasActive, true);
    } else {
      _prefs.remove(_kSessionCanvasActive);
    }
  }
}
