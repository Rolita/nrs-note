import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_enums.dart';
import '../core/theme/app_palette.dart';
import '../core/theme/app_tokens.dart';
import '../core/theme/theme_presets.dart';
import '../data/models/note.dart';
import 'template_settings.dart';

/// User preferences that survive restarts.
///
/// Everything here is a *view* preference — the notes themselves live in the
/// vault, so wiping these settings never touches user content.
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs);

  final SharedPreferences _prefs;

  static const String _kTheme = 'nrs.theme';
  static const String _kThemePreset = 'nrs.themePreset';

  /// One overlay key per scheme: `nrs.themeOverride.obsidian` and friends.
  static const String _kThemeOverride = 'nrs.themeOverride.';
  static const String _kSort = 'nrs.sort';
  static const String _kSidebar = 'nrs.sidebarCollapsed';
  static const String _kOutline = 'nrs.outlineVisible';
  static const String _kTablePanel = 'nrs.tablePanelVisible';
  static const String _kImagePanel = 'nrs.imagePanelVisible';
  static const String _kListWidth = 'nrs.listWidth';
  static const String _kOutlineWidth = 'nrs.outlineWidth';
  static const String _kTablePanelWidth = 'nrs.tablePanelWidth';
  static const String _kImagePanelWidth = 'nrs.imagePanelWidth';
  static const String _kProseSize = 'nrs.proseSize';
  static const String _kFocus = 'nrs.focusMode';
  static const String _kSessionTabs = 'nrs.sessionTabs';
  static const String _kSessionSelected = 'nrs.sessionSelected';
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

  ThemePreference get theme {
    final String? raw = _prefs.getString(_kTheme);
    return ThemePreference.values.firstWhere(
      (ThemePreference e) => e.name == raw,
      orElse: () => ThemePreference.system,
    );
  }

  set theme(ThemePreference value) {
    if (theme == value) return;
    _prefs.setString(_kTheme, value.name);
    notifyListeners();
  }

  // --------------------------------------------------------- colour scheme
  //
  // 「配色方案」 and 「明暗模式」 are two orthogonal axes: the scheme picks which
  // board, the mode picks which *face* of that board. `_kTheme` above keeps
  // carrying the mode (system / light / dark); renaming it would throw away an
  // existing install's light-or-dark choice.

  /// The board the user picked. An unrecognised stored string falls back to
  /// 曜石 — and is deliberately *not* rewritten, so a downgrade still reads.
  ThemePresetId get themePreset {
    final String? raw = _prefs.getString(_kThemePreset);
    return ThemePresetId.values.firstWhere(
      (ThemePresetId e) => e.name == raw,
      orElse: () => ThemePresetId.fallback,
    );
  }

  set themePreset(ThemePresetId value) {
    if (themePreset == value) return;
    _prefs.setString(_kThemePreset, value.name);
    notifyListeners();
  }

  /// The user's edits to [preset], if any. The in-memory draft wins over what is
  /// on disk, so a drag under the pointer is reflected the instant it moves.
  ///
  /// Each scheme keeps its own overlay, so editing 曜石 leaves 午夜靛's colours
  /// exactly as they shipped.
  PaletteOverride? overrideFor(ThemePresetId preset) {
    final ({ThemePresetId preset, PaletteOverride board})? draft = _draft;
    if (draft != null && draft.preset == preset) return draft.board;
    return PaletteOverride.decode(
      _prefs.getString(_overrideKey(preset)),
      base: preset,
    );
  }

  /// While the pointer is down: update the draft and notify, **do not write**.
  ///
  /// On Windows every `setString` rewrites the whole preferences file, so
  /// committing on each drag frame would be sixty file writes per second.
  void previewOverride(ThemePresetId preset, PaletteOverride value) {
    _draft = (preset: preset, board: value);
    notifyListeners();
  }

  /// On pointer-up / on committing a hex field: write it out and drop the draft.
  void commitOverride(ThemePresetId preset, PaletteOverride value) {
    final String key = _overrideKey(preset);
    final bool unchanged = _prefs.getString(key) == value.raw;
    _draft = null;
    if (unchanged) return;
    _prefs.setString(key, value.raw);
    notifyListeners();
  }

  /// Drops [preset]'s overlay entirely, putting its built-in board back in
  /// force. Used by the editor's 「重置」 when it is committed.
  void clearOverride(ThemePresetId preset) {
    final String key = _overrideKey(preset);
    final ({ThemePresetId preset, PaletteOverride board})? draft = _draft;
    final bool hadDraft = draft != null && draft.preset == preset;
    final bool hadStored = _prefs.containsKey(key);
    _draft = hadDraft ? null : draft;
    if (hadStored) _prefs.remove(key);
    if (hadDraft || hadStored) notifyListeners();
  }

  /// Rolls the scheme *and that scheme's overlay* back to [snapshot] — the
  /// editor's 「取消」.
  ///
  /// The snapshot is a whole pair, so a user who was on 曜石 with no overlay,
  /// opened the editor and cancelled comes back to 曜石 with nothing left
  /// behind.
  void restoreTheme(
    ({ThemePresetId preset, PaletteOverride? override}) snapshot,
  ) {
    _draft = null;
    if (snapshot.preset == ThemePresetId.fallback) {
      _prefs.remove(_kThemePreset);
    } else {
      _prefs.setString(_kThemePreset, snapshot.preset.name);
    }
    final String key = _overrideKey(snapshot.preset);
    final PaletteOverride? layer = snapshot.override;
    if (layer == null) {
      _prefs.remove(key);
    } else {
      _prefs.setString(key, layer.raw);
    }
    notifyListeners();
  }

  /// The palette in force for a given face of the current scheme.
  ///
  /// `ThemePresets.resolve` builds a fresh [AppPalette] every call, and the
  /// editor's line layout identifies a theme by that instance
  /// (`LiveLineStyle.styleKey`). Handing out a new instance on every build
  /// would make it re-lay out the whole document while a theme switch is
  /// animating — once per frame. This keeps one instance per
  /// `(preset, brightness, overlay)`, so the palette only changes when the
  /// colours actually do.
  AppPalette paletteFor(Brightness brightness) {
    final ThemePresetId preset = themePreset;
    final String layer = _layerOf(preset);
    final (String, AppPalette)? hit = _palettes[(preset, brightness)];
    if (hit != null && hit.$1 == layer) return hit.$2;
    final AppPalette built = ThemePresets.resolve(
      preset: preset,
      override: overrideFor(preset),
      brightness: brightness,
    );
    _palettes[(preset, brightness)] = (layer, built);
    return built;
  }

  /// 每个（预设 × 明暗）只留一格：覆盖层一变（拖动取色）就换新实例。
  final Map<(ThemePresetId, Brightness), (String, AppPalette)> _palettes =
      <(ThemePresetId, Brightness), (String, AppPalette)>{};

  /// 当前预设覆盖层的原始串（草稿优先）。
  String _layerOf(ThemePresetId preset) {
    final ({ThemePresetId preset, PaletteOverride board})? draft = _draft;
    return draft != null && draft.preset == preset
        ? draft.board.raw
        : _prefs.getString(_overrideKey(preset)) ?? '';
  }

  /// Memo key for the two `ThemeData` objects: any change to either key, or to
  /// the draft, changes it.
  String get themeSignature => '${themePreset.name}|${_layerOf(themePreset)}';

  /// True while the editor dialog is open, so `MaterialApp` can drop its theme
  /// tween: frame-by-frame cross-fades between a colour and the finger that is
  /// dragging it feel sticky, and mid-tween boards briefly report a stale
  /// `isDark`.
  bool themeEditing = false;

  ({ThemePresetId preset, PaletteOverride board})? _draft;

  static String _overrideKey(ThemePresetId preset) =>
      '$_kThemeOverride${preset.name}';

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

  /// The outline, the table tools and the image list share the far-right
  /// column, so at most one of them is open. Turning one on closes the others
  /// in the same write — the shell can then read the three flags without
  /// cross-checking them.
  set outlineVisible(bool value) {
    if (outlineVisible == value) return;
    _prefs.setBool(_kOutline, value);
    if (value) {
      _prefs.setBool(_kTablePanel, false);
      _prefs.setBool(_kImagePanel, false);
    }
    notifyListeners();
  }

  bool get tablePanelVisible => _prefs.getBool(_kTablePanel) ?? false;

  set tablePanelVisible(bool value) {
    if (tablePanelVisible == value) return;
    _prefs.setBool(_kTablePanel, value);
    if (value) {
      _prefs.setBool(_kOutline, false);
      _prefs.setBool(_kImagePanel, false);
    }
    notifyListeners();
  }

  bool get imagePanelVisible => _prefs.getBool(_kImagePanel) ?? false;

  set imagePanelVisible(bool value) {
    if (imagePanelVisible == value) return;
    _prefs.setBool(_kImagePanel, value);
    if (value) {
      _prefs.setBool(_kOutline, false);
      _prefs.setBool(_kTablePanel, false);
    }
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

  /// Width of the document outline column, dragged by its own handle.
  double get outlineWidth =>
      _prefs.getDouble(_kOutlineWidth) ?? AppLayout.outlineWidth;

  set outlineWidth(double value) {
    final double clamped = value.clamp(
      AppLayout.outlineMinWidth,
      AppLayout.outlineMaxWidth,
    );
    if ((outlineWidth - clamped).abs() < 0.5) return;
    _prefs.setDouble(_kOutlineWidth, clamped);
    notifyListeners();
  }

  /// Width of the table tools column, dragged by its own handle.
  double get tablePanelWidth =>
      _prefs.getDouble(_kTablePanelWidth) ?? AppLayout.tablePanelWidth;

  set tablePanelWidth(double value) {
    final double clamped = value.clamp(
      AppLayout.tablePanelMinWidth,
      AppLayout.tablePanelMaxWidth,
    );
    if ((tablePanelWidth - clamped).abs() < 0.5) return;
    _prefs.setDouble(_kTablePanelWidth, clamped);
    notifyListeners();
  }

  /// Width of the image list column, dragged by its own handle.
  double get imagePanelWidth =>
      _prefs.getDouble(_kImagePanelWidth) ?? AppLayout.imagePanelWidth;

  set imagePanelWidth(double value) {
    final double clamped = value.clamp(
      AppLayout.imagePanelMinWidth,
      AppLayout.imagePanelMaxWidth,
    );
    if ((imagePanelWidth - clamped).abs() < 0.5) return;
    _prefs.setDouble(_kImagePanelWidth, clamped);
    notifyListeners();
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
}
