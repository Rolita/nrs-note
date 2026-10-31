import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Semantic colour tokens for the whole application.
///
/// Instead of sprinkling raw hex values through the widget tree, every surface
/// and text colour is named by *role*. There is exactly **one** board — 石墨,
/// dark — so a widget never needs to know which palette is active.
///
/// Five neutral steps: [surfaceSunken] below everything, [canvas] for the
/// window, [surface] for paper, [sidebar] for the two side columns and the top
/// band, and [surfaceRaised] for anything that floats above the paper. The
/// paper is the *darkest* of the working faces on purpose: long reading should
/// land on the text, not on the frame around it.
///
/// The accent is spent only inside the note body — search hits, quote bars,
/// list dots. Chrome marks selection with the neutral [rowSelected] wash and
/// never borrows the accent for text, underlines or bars.
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
    required this.rowSelected,
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

  /// Window background, behind every panel, and the recessed gap between two
  /// split editors.
  final Color canvas;

  /// The switchable sidebar, the outline column, and the 40px band that runs
  /// along the top of every pane.
  ///
  /// One step *above* [surface]: the chrome is allowed to be the lighter face,
  /// while the paper under the text sinks to the darkest working step.
  final Color sidebar;

  /// Main content surface: the paper under the editor, and every dialog that
  /// reads as a sheet of paper.
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

  /// The note body's own colour: search hits, quote bars, list dots, the
  /// selected table block. Not a chrome colour any more.
  final Color accent;

  final Color accentHover;

  /// The highlighter wash reserved for the note body. Chrome never fills a
  /// selected row with it — see [rowSelected].
  final Color accentSoft;

  /// The neutral fill behind a selected tab, rail button, list row or outline
  /// row. One step above [surfaceRaised] (hover), so "here" reads as a slightly
  /// brighter square of the same grey rather than a borrowed tint.
  final Color rowSelected;

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

  /// 石墨 — the only board the app ships.
  ///
  /// 纸面沉到 `#151516`（工作面里最暗的一档），侧栏和顶带抬到 `#1E1F21`，
  /// 画布 `#0F0F10`，浮层 `#28292C`；强调色仍是一支偏紫的靛蓝 `#8B94F2`，
  /// 但只在正文里出现。外壳的选中用中性 [rowSelected] `#34353A`。
  ///
  /// [selectionEdge] 是 [accent] 降一档亮度（×0.86）的结果：1px 的强调色
  /// 在深色板上读起来是发光而不是描边，压暗一点才收得住。
  static const AppPalette midnight = AppPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF0F0F10),
    sidebar: Color(0xFF1E1F21),
    surface: Color(0xFF151516),
    surfaceRaised: Color(0xFF28292C),
    surfaceSunken: Color(0xFF0B0B0C),
    outline: Color(0xFF343438),
    outlineSoft: Color(0xFF232326),
    rule: Color(0xFF343438),
    textPrimary: Color(0xFFECEDEF),
    textSecondary: Color(0xFFA8AAAF),
    textTertiary: Color(0xFF7D7F85),
    accent: Color(0xFF8B94F2),
    accentHover: Color(0xFFA0A8F7),
    accentSoft: Color(0xFF2C2D42),
    rowSelected: Color(0xFF34353A),
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

  /// 壁纸外观用的一版：把「成片的地」压到 [opacity]，露出垫在下面的图。
  ///
  /// 只动大块面层（侧栏、纸面、浮层、选中底、柔光底）；[canvas]、文字、
  /// 图标、描边和内容线保持实色——设计稿里文字是不透明的，画布还要给
  /// 白板 / 图片 / 空分格当实底。
  ///
  /// 这不是第二块色板：仍然是同一块石墨，只是叠了一层透明。切回默认外观
  /// 时直接用 [midnight] 就行。
  AppPalette backdrop(double opacity) {
    Color veil(Color c) => c.withValues(alpha: c.a * opacity);
    return AppPalette(
      brightness: brightness,
      canvas: canvas,
      sidebar: veil(sidebar),
      surface: veil(surface),
      surfaceRaised: veil(surfaceRaised),
      surfaceSunken: veil(surfaceSunken),
      outline: outline,
      outlineSoft: outlineSoft,
      rule: rule,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textTertiary: textTertiary,
      accent: accent,
      accentHover: accentHover,
      accentSoft: veil(accentSoft),
      rowSelected: veil(rowSelected),
      onAccent: onAccent,
      success: success,
      successSoft: veil(successSoft),
      warning: warning,
      warningSoft: veil(warningSoft),
      danger: danger,
      dangerSoft: veil(dangerSoft),
      selection: selection,
      selectionEdge: selectionEdge,
      shadow: shadow,
      overlay: overlay,
    );
  }

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
    double channel(double v) => v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
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
    rowSelected: rowSelected,
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
      rowSelected: mix(rowSelected, other.rowSelected),
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
