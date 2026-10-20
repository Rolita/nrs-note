import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_enums.dart';
import '../core/theme/app_palette.dart';
import '../core/theme/app_tokens.dart';
import '../core/theme/theme_presets.dart';

/// User preferences that survive restarts.
///
/// Everything here is a *view* preference — the notes themselves live in the
/// vault, so wiping these settings never touches user content.
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs);

  final SharedPreferences _prefs;

  static const String _kTheme = 'nrs.theme';
  static const String _kThemePreset = 'nrs.themePreset';
  static const String _kThemeCustom = 'nrs.themeCustom';
  static const String _kSort = 'nrs.sort';
  static const String _kSidebar = 'nrs.sidebarCollapsed';
  static const String _kOutline = 'nrs.outlineVisible';
  static const String _kListWidth = 'nrs.listWidth';
  static const String _kOutlineWidth = 'nrs.outlineWidth';
  static const String _kProseSize = 'nrs.proseSize';
  static const String _kFocus = 'nrs.focusMode';
  static const String _kTypewriter = 'nrs.typewriter';

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
  /// 石墨素白 — and is deliberately *not* rewritten, so a downgrade still reads.
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

  /// The user's own board. The in-memory draft wins over what is on disk, so a
  /// drag under the pointer is reflected the instant it moves.
  CustomPalette? get customPalette =>
      _draftCustom ?? CustomPalette.decode(_prefs.getString(_kThemeCustom));

  /// While the pointer is down: update the draft and notify, **do not write**.
  ///
  /// On Windows every `setString` rewrites the whole preferences file, so
  /// committing on each drag frame would be sixty file writes per second.
  void previewCustomPalette(CustomPalette value) {
    _draftCustom = value;
    notifyListeners();
  }

  /// On pointer-up / on committing a hex field: write it out and drop the draft.
  void commitCustomPalette(CustomPalette value) {
    final bool unchanged = _prefs.getString(_kThemeCustom) == value.raw;
    _draftCustom = null;
    if (unchanged) return;
    _prefs.setString(_kThemeCustom, value.raw);
    notifyListeners();
  }

  /// Rolls *both* keys back to [snapshot] — the editor's 「取消」.
  ///
  /// The snapshot is a whole pair, so a user who was on 石墨素白 with no custom
  /// board, opened the editor (which switches to `custom`) and cancelled, comes
  /// back to 石墨素白 with the custom board erased — no residue left behind.
  void restoreTheme(({ThemePresetId preset, CustomPalette? custom}) snapshot) {
    _draftCustom = null;
    if (snapshot.preset == ThemePresetId.fallback) {
      _prefs.remove(_kThemePreset);
    } else {
      _prefs.setString(_kThemePreset, snapshot.preset.name);
    }
    if (snapshot.custom == null) {
      _prefs.remove(_kThemeCustom);
    } else {
      _prefs.setString(_kThemeCustom, snapshot.custom!.raw);
    }
    notifyListeners();
  }

  /// The palette in force for a given face of the current scheme.
  AppPalette paletteFor(Brightness brightness) => ThemePresets.resolve(
    preset: themePreset,
    custom: customPalette,
    brightness: brightness,
  );

  /// Memo key for the two `ThemeData` objects: any change to either key, or to
  /// the draft, changes it.
  String get themeSignature =>
      '${themePreset.name}|'
      '${_draftCustom?.raw ?? _prefs.getString(_kThemeCustom) ?? ''}';

  /// True while the editor dialog is open, so `MaterialApp` can drop its theme
  /// tween: frame-by-frame cross-fades between a colour and the finger that is
  /// dragging it feel sticky, and mid-tween boards briefly report a stale
  /// `isDark`.
  bool themeEditing = false;

  CustomPalette? _draftCustom;

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

  /// Typewriter mode keeps the caret vertically centred while you type.
  bool get typewriter => _prefs.getBool(_kTypewriter) ?? false;

  set typewriter(bool value) {
    if (typewriter == value) return;
    _prefs.setBool(_kTypewriter, value);
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

  set outlineVisible(bool value) {
    if (outlineVisible == value) return;
    _prefs.setBool(_kOutline, value);
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

  // ------------------------------------------------------------ typography

  /// Body size of the editor, in logical pixels.
  double get proseSize => _prefs.getDouble(_kProseSize) ?? 15.5;

  set proseSize(double value) {
    final double clamped = value.clamp(13, 22);
    if ((proseSize - clamped).abs() < 0.05) return;
    _prefs.setDouble(_kProseSize, clamped);
    notifyListeners();
  }
}
