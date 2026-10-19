import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_enums.dart';
import '../core/theme/app_tokens.dart';

/// User preferences that survive restarts.
///
/// Everything here is a *view* preference — the notes themselves live in the
/// vault, so wiping these settings never touches user content.
class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs);

  final SharedPreferences _prefs;

  static const String _kTheme = 'nrs.theme';
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

  double get listWidth => _prefs.getDouble(_kListWidth) ?? 316;

  set listWidth(double value) {
    final double clamped = value.clamp(264, 460);
    if ((listWidth - clamped).abs() < 0.5) return;
    _prefs.setDouble(_kListWidth, clamped);
    notifyListeners();
  }

  /// Width of the document outline column, dragged by its own handle.
  double get outlineWidth =>
      _prefs.getDouble(_kOutlineWidth) ?? AppLayout.outlineWidth;

  set outlineWidth(double value) {
    final double clamped = value.clamp(200, 420);
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
