import 'package:flutter/material.dart';

/// Semantic colour tokens for the whole application.
///
/// Instead of sprinkling raw hex values through the widget tree, every surface
/// and text colour is named by *role*. Both the light and the dark palette
/// implement the exact same contract so a widget never needs to know which
/// brightness is active.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.canvas,
    required this.sidebar,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.outline,
    required this.outlineSoft,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentHover,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.danger,
    required this.dangerSoft,
    required this.selection,
    required this.selectionEdge,
    required this.shadow,
    required this.overlay,
  });

  final Brightness brightness;

  /// Window background, behind every panel.
  final Color canvas;

  /// The tall navigation column on the far left.
  final Color sidebar;

  /// Main content panels (note list, editor, preview).
  final Color surface;

  /// Cards, chips, popovers and inputs that sit *on top of* [surface].
  final Color surfaceRaised;

  /// Recessed areas: code blocks, inline code, scrollbar tracks.
  final Color surfaceSunken;

  final Color outline;
  final Color outlineSoft;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color accent;
  final Color accentHover;
  final Color accentSoft;
  final Color onAccent;

  final Color success;
  final Color successSoft;
  final Color warning;
  final Color warningSoft;
  final Color danger;
  final Color dangerSoft;

  /// Text selection highlight inside the editor.
  final Color selection;

  /// The one-pixel edge around a selected **block** (a run of table cells).
  ///
  /// Deeper than [accent] on purpose: at 1px an `accent` line reads as a glow
  /// rather than as an edge, which in a table turns into a bright box around
  /// every row instead of one shape around the selection.
  final Color selectionEdge;

  /// Ambient shadow colour (already alpha-composited).
  final Color shadow;

  /// Scrim used behind dialogs / modal sheets.
  final Color overlay;

  bool get isDark => brightness == Brightness.dark;

  /// A warm, paper-like light theme.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFF4F2EE),
    sidebar: Color(0xFFEFEDE8),
    surface: Color(0xFFFFFEFC),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF2F0EB),
    outline: Color(0xFFE3DFD7),
    outlineSoft: Color(0xFFEDEAE3),
    textPrimary: Color(0xFF1B1A18),
    textSecondary: Color(0xFF6A655D),
    textTertiary: Color(0xFF9C968B),
    accent: Color(0xFF6B5BD2),
    accentHover: Color(0xFF5B4BC4),
    accentSoft: Color(0xFFEEEBFC),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF2E8B62),
    successSoft: Color(0xFFE3F3EA),
    warning: Color(0xFFB57B1A),
    warningSoft: Color(0xFFFBF0DC),
    danger: Color(0xFFC4473F),
    dangerSoft: Color(0xFFFBEAE8),
    selection: Color(0x336B5BD2),
    selectionEdge: Color(0xFF6B5BD2),
    shadow: Color(0x14000000),
    overlay: Color(0x331B1A18),
  );

  /// A deep, low-contrast dark theme that stays readable for long sessions.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF111113),
    sidebar: Color(0xFF16161A),
    surface: Color(0xFF1A1A1E),
    surfaceRaised: Color(0xFF232329),
    surfaceSunken: Color(0xFF141418),
    outline: Color(0xFF2C2C34),
    outlineSoft: Color(0xFF232329),
    textPrimary: Color(0xFFECECF0),
    textSecondary: Color(0xFFA3A3AF),
    textTertiary: Color(0xFF71717E),
    accent: Color(0xFF9E90F7),
    accentHover: Color(0xFFB1A5FA),
    accentSoft: Color(0xFF272342),
    onAccent: Color(0xFF17122B),
    success: Color(0xFF5FC79A),
    successSoft: Color(0xFF16281F),
    warning: Color(0xFFE0B054),
    warningSoft: Color(0xFF2C2416),
    danger: Color(0xFFE4796F),
    dangerSoft: Color(0xFF2E1C1A),
    selection: Color(0x449E90F7),
    selectionEdge: Color(0xFF8A5CF5),
    shadow: Color(0x66000000),
    overlay: Color(0x99000000),
  );

  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  @override
  AppPalette copyWith({Brightness? brightness}) => AppPalette(
    brightness: brightness ?? this.brightness,
    canvas: canvas,
    sidebar: sidebar,
    surface: surface,
    surfaceRaised: surfaceRaised,
    surfaceSunken: surfaceSunken,
    outline: outline,
    outlineSoft: outlineSoft,
    textPrimary: textPrimary,
    textSecondary: textSecondary,
    textTertiary: textTertiary,
    accent: accent,
    accentHover: accentHover,
    accentSoft: accentSoft,
    onAccent: onAccent,
    success: success,
    successSoft: successSoft,
    warning: warning,
    warningSoft: warningSoft,
    danger: danger,
    dangerSoft: dangerSoft,
    selection: selection,
    selectionEdge: selectionEdge,
    shadow: shadow,
    overlay: overlay,
  );

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvas: mix(canvas, other.canvas),
      sidebar: mix(sidebar, other.sidebar),
      surface: mix(surface, other.surface),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      surfaceSunken: mix(surfaceSunken, other.surfaceSunken),
      outline: mix(outline, other.outline),
      outlineSoft: mix(outlineSoft, other.outlineSoft),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      accent: mix(accent, other.accent),
      accentHover: mix(accentHover, other.accentHover),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      success: mix(success, other.success),
      successSoft: mix(successSoft, other.successSoft),
      warning: mix(warning, other.warning),
      warningSoft: mix(warningSoft, other.warningSoft),
      danger: mix(danger, other.danger),
      dangerSoft: mix(dangerSoft, other.dangerSoft),
      selection: mix(selection, other.selection),
      selectionEdge: mix(selectionEdge, other.selectionEdge),
      shadow: mix(shadow, other.shadow),
      overlay: mix(overlay, other.overlay),
    );
  }
}

/// Ergonomic access: `context.palette.accent`.
extension AppPaletteContext on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
}
