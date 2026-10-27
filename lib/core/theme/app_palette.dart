import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Semantic colour tokens for the whole application.
///
/// Instead of sprinkling raw hex values through the widget tree, every surface
/// and text colour is named by *role*. There is exactly **one** board — 午夜靛,
/// dark — so a widget never needs to know which palette is active.
///
/// Five clearly separated neutral steps (canvas → sidebar → surface →
/// surfaceRaised, plus surfaceSunken below the canvas), one accent, and no
/// decorative tint anywhere else. Neighbouring steps sit at least five levels
/// apart on purpose — that gap is what lets the four shell regions separate
/// with a hairline instead of a border and a shadow fighting each other.
///
/// ⛔ **Team rule: only [AppPaletteContext.palette] decides which palette is in
/// force.** New code must go through `context.palette`. There is no second
/// board to pick from and no user-editable one: the app ships dark-only since
/// 2026-10-27 (light themes and the colour editor were removed), so a colour
/// that reads badly here has to be fixed here rather than worked around by a
/// second palette.
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

  /// Selection, focus, tags, the current row — the colour spent on the thing
  /// the user is looking at. Near-black in the light board, near-white in the dark one.
  final Color accent;

  final Color accentHover;

  /// A quiet wash for a selected row's background.
  final Color accentSoft;

  /// Text and icons sitting *on* a solid [accent] fill.
  final Color onAccent;

  final Color success;
  final Color successSoft;

  /// Attention, not decoration. Deliberately pushed away from [accent] in hue
  /// so the two stay distinguishable.
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

  /// 午夜靛 — the only board the app ships.
  ///
  /// 深色、偏冷的靛蓝：画布 `#0E0F13`、侧栏 `#131419`、编辑区 `#17181E`、
  /// 浮层 `#1F2027`、下沉 `#0A0B0E`；强调色是一支偏紫的靛蓝 `#8B94F2`，
  /// 在近黑的纸面上够亮又不刺眼。
  ///
  /// [selectionEdge] 是 [accent] 降一档亮度（×0.86）的结果：1px 的强调色
  /// 在深色板上读起来是发光而不是描边，压暗一点才收得住。
  static const AppPalette midnight = AppPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF0E0F13),
    sidebar: Color(0xFF131419),
    surface: Color(0xFF17181E),
    surfaceRaised: Color(0xFF1F2027),
    surfaceSunken: Color(0xFF0A0B0E),
    outline: Color(0xFF2A2C36),
    outlineSoft: Color(0xFF1E2028),
    rule: Color(0xFF32343F),
    textPrimary: Color(0xFFE6E8EF),
    textSecondary: Color(0xFF9AA0B0),
    textTertiary: Color(0xFF6A7080),
    accent: Color(0xFF8B94F2),
    accentHover: Color(0xFFA0A8F7),
    accentSoft: Color(0xFF23263A),
    onAccent: Color(0xFF10122A),
    success: Color(0xFF5FC79A),
    successSoft: Color(0xFF13251D),
    warning: Color(0xFFE0A24A),
    warningSoft: Color(0xFF2E2413),
    danger: Color(0xFFE4797F),
    dangerSoft: Color(0xFF2C1A1F),
    selection: Color(0x4D8B94F2),
    selectionEdge: Color(0xFF5B68ED),
    shadow: Color(0x66000000),
    overlay: Color(0x99000000),
  );

  /// Black or white — whichever reads better on [background].
  ///
  /// Used for text painted on a *solid* status fill (the delete button), which
  /// cannot assume anything: a user may set `danger` to a deep red, and the old
  /// `isDark ? canvas : white` branch would then paint dark text on dark red.
  static Color readableOn(Color background) =>
      _relativeLuminance(background) > 0.179
      ? const Color(0xFF000000)
      : const Color(0xFFFFFFFF);

  /// WCAG contrast ratio (1.0 – 21.0) between two colours.
  ///
  /// The editor needs this to warn when a pair the user assembled themselves
  /// falls under the 4.5:1 reading threshold — a warning the preset boards can
  /// never trigger, because they were authored against it.
  static double contrastRatio(Color a, Color b) {
    final double la = _relativeLuminance(a);
    final double lb = _relativeLuminance(b);
    final double hi = math.max(la, lb);
    final double lo = math.min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// WCAG relative luminance. Alpha is ignored: callers pass composited fills.
  static double _relativeLuminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

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
      Theme.of(this).extension<AppPalette>() ?? AppPalette.midnight;
}
