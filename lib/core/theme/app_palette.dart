import 'package:flutter/material.dart';

/// Semantic colour tokens for the whole application.
///
/// Instead of sprinkling raw hex values through the widget tree, every surface
/// and text colour is named by *role*. Both the light and the dark palette
/// implement the exact same contract so a widget never needs to know which
/// brightness is active.
///
/// The dark theme is the primary one: five clearly separated neutral steps
/// (canvas → sidebar → surface → surfaceRaised, plus surfaceSunken below the
/// canvas), a single warm amber accent, and no decorative tint anywhere else.
/// Neighbouring steps sit at least five levels apart on purpose — that gap is
/// what lets the four shell regions separate with a hairline instead of a
/// border and a shadow fighting each other.
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
    required this.rule,
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

  /// Window background, behind every panel. Also the function rail, which reads
  /// as the deepest step so the sidebar can sit *above* it rather than beside it.
  final Color canvas;

  /// The switchable file / search / tags sidebar, and the document outline.
  ///
  /// One step above [canvas] and one below [surface]: the editor stays the
  /// brightest surface on screen, which is where the eye should land.
  final Color sidebar;

  /// Main content surface: the editor, and every dialog that reads as a sheet
  /// of paper.
  final Color surface;

  /// Cards, chips, popovers, inputs and hovered rows that sit *on top of*
  /// [surface].
  final Color surfaceRaised;

  /// Recessed areas: code blocks, inline code, scrollbar tracks.
  final Color surfaceSunken;

  /// The hairline between two regions, and the edge of a control.
  final Color outline;

  /// The weaker divider used *inside* a region, where a full-strength line
  /// would cut the panel in two.
  final Color outlineSoft;

  /// A hairline drawn on top of the *content* surface: the editor's table grid
  /// and its horizontal rules.
  ///
  /// The two outline steps above are chrome colours, measured against the panel
  /// steps they separate. On the editor's [surface] they both fail: the soft one
  /// sits four levels off the dark surface (1.04:1 — literally invisible) and the
  /// strong one is only 1.27:1. Content rules are spaced further from their
  /// background than panel edges are, so they need their own step rather than a
  /// borrowed one.
  final Color rule;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// The one warm accent: selection, focus, tags, the current row.
  ///
  /// Everything else in the shell is neutral grey, so this colour is only ever
  /// spent on the thing the user is looking at.
  final Color accent;

  final Color accentHover;

  /// A quiet amber wash for a selected row's background.
  final Color accentSoft;

  /// Text and icons sitting *on* a solid [accent] fill.
  final Color onAccent;

  final Color success;
  final Color successSoft;

  /// Attention, not decoration. Deliberately pushed towards burnt orange so it
  /// stays distinguishable from the amber [accent].
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

  /// Ambient shadow colour (already alpha-composited). Spent only on floating
  /// layers — popovers, dialogs, the drag preview.
  final Color shadow;

  /// Scrim used behind dialogs / modal sheets.
  final Color overlay;

  bool get isDark => brightness == Brightness.dark;

  /// A neutral, cool grey light theme.
  ///
  /// The amber has to be darkened a long way to keep its contrast on a white
  /// surface, which is why the light accent is not the same hue value as the
  /// dark one.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFF6F6F7),
    sidebar: Color(0xFFF1F1F3),
    surface: Color(0xFFFBFBFC),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFEDEDEF),
    outline: Color(0xFFDCDCE2),
    outlineSoft: Color(0xFFE8E8EC),
    rule: Color(0xFFD4D4DB),
    textPrimary: Color(0xFF191919),
    textSecondary: Color(0xFF5C5C66),
    textTertiary: Color(0xFF8E8E99),
    accent: Color(0xFFB45309),
    accentHover: Color(0xFF92400E),
    accentSoft: Color(0xFFFEF3C7),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF2E8B62),
    successSoft: Color(0xFFE3F3EA),
    warning: Color(0xFFC25A12),
    warningSoft: Color(0xFFFBEDE0),
    danger: Color(0xFFC4473F),
    dangerSoft: Color(0xFFFBEAE8),
    selection: Color(0x33B45309),
    selectionEdge: Color(0xFFB45309),
    shadow: Color(0x14000000),
    overlay: Color(0x33191919),
  );

  /// The primary theme: five separated grey steps, one amber accent.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF17171A),
    sidebar: Color(0xFF1C1C1F),
    surface: Color(0xFF202024),
    surfaceRaised: Color(0xFF27272C),
    surfaceSunken: Color(0xFF141416),
    outline: Color(0xFF31313A),
    outlineSoft: Color(0xFF24242A),
    rule: Color(0xFF3A3A44),
    textPrimary: Color(0xFFE8E8ED),
    textSecondary: Color(0xFF9A9AA6),
    textTertiary: Color(0xFF6B6B78),
    accent: Color(0xFFE0A44A),
    accentHover: Color(0xFFEDB463),
    accentSoft: Color(0xFF352C1A),
    onAccent: Color(0xFF241A08),
    success: Color(0xFF5FC79A),
    successSoft: Color(0xFF16281F),
    warning: Color(0xFFE5843F),
    warningSoft: Color(0xFF33220F),
    danger: Color(0xFFE4796F),
    dangerSoft: Color(0xFF2E1C1A),
    selection: Color(0x4DE0A44A),
    selectionEdge: Color(0xFFC08A2E),
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
    rule: rule,
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
      rule: mix(rule, other.rule),
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
