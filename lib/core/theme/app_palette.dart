import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Semantic colour tokens for the whole application.
///
/// Instead of sprinkling raw hex values through the widget tree, every surface
/// and text colour is named by *role*. Every palette — built-in preset or a
/// user's custom one — implements the exact same contract, so a widget never
/// needs to know which one is active.
///
/// Five clearly separated neutral steps (canvas → sidebar → surface →
/// surfaceRaised, plus surfaceSunken below the canvas), one accent, and no
/// decorative tint anywhere else. Neighbouring steps sit at least five levels
/// apart on purpose — that gap is what lets the four shell regions separate
/// with a hairline instead of a border and a shadow fighting each other.
///
/// ⛔ **Team rule: only [AppPaletteContext.palette] and
/// `ThemePresets.resolve` decide which palette is in force.** New code must go
/// through `context.palette`; do not call [AppPalette.of] to pick a palette
/// yourself. It survives only as "the palette that has nothing to do with the
/// theme" and is used by test fixtures, which need one arbitrary light and one
/// arbitrary dark board to render against.
///
/// The accent is no longer a fixed amber. [light] and [dark] now hold the
/// *石墨素白 / Graphite* preset — the shipped default — and every other
/// preset (or a user's custom colours) arrives through the very same 25 colour
/// tokens.
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

  /// 石墨素白 / Graphite, light face: neutral paper grey, near-black accent.
  ///
  /// 默认预设。测试夹具把它当作「一个亮色板」用，不关心它具体是哪一套方案。
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFF7F7F5),
    sidebar: Color(0xFFF1F1EF),
    surface: Color(0xFFFCFCFB),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFEFEFED),
    outline: Color(0xFFDCDCD9),
    outlineSoft: Color(0xFFE9E9E6),
    rule: Color(0xFFD5D5D1),
    textPrimary: Color(0xFF1B1B1A),
    textSecondary: Color(0xFF5C5C59),
    textTertiary: Color(0xFF8C8C88),
    accent: Color(0xFF2A2A28),
    accentHover: Color(0xFF111110),
    accentSoft: Color(0xFFE9E9E6),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF2E8B62),
    successSoft: Color(0xFFE3F0E8),
    warning: Color(0xFFB06B1B),
    warningSoft: Color(0xFFF7EADA),
    danger: Color(0xFFC0392B),
    dangerSoft: Color(0xFFFAE7E4),
    selection: Color(0x282A2A28),
    selectionEdge: Color(0xFF2A2A28),
    shadow: Color(0x14000000),
    overlay: Color(0x33000000),
  );

  /// 石墨素白 / Graphite, dark face: neutral graphite ladder, near-white accent.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF151514),
    sidebar: Color(0xFF1A1A19),
    surface: Color(0xFF1F1F1E),
    surfaceRaised: Color(0xFF272726),
    surfaceSunken: Color(0xFF101010),
    outline: Color(0xFF2F2F2E),
    outlineSoft: Color(0xFF242423),
    rule: Color(0xFF3A3A38),
    textPrimary: Color(0xFFE9E9E6),
    textSecondary: Color(0xFF9E9E9A),
    textTertiary: Color(0xFF6E6E6A),
    accent: Color(0xFFEDEDEA),
    accentHover: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF2E2E2C),
    onAccent: Color(0xFF141413),
    success: Color(0xFF6FC29A),
    successSoft: Color(0xFF17281F),
    warning: Color(0xFFE0964A),
    warningSoft: Color(0xFF33240F),
    danger: Color(0xFFE5796B),
    dangerSoft: Color(0xFF2E1A17),
    selection: Color(0x38EDEDEA),
    // `ThemePresets` derives this from `accent` (lightness × 0.86) at runtime;
    // it is copied here as a literal only to keep this palette `const`.
    selectionEdge: Color(0xFFCECEC7),
    shadow: Color(0x66000000),
    overlay: Color(0x99000000),
  );

  /// The palette that has nothing to do with the current theme.
  ///
  /// ⛔ Not "the palette the app is using" — that is
  /// [AppPaletteContext.palette]. See the team rule in this file's header.
  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Reads one token by name. The 25 branches are exhaustive on purpose: adding
  /// a token makes this fail to compile until it is wired up.
  Color colorOf(AppPaletteToken token) => switch (token) {
    AppPaletteToken.canvas => canvas,
    AppPaletteToken.sidebar => sidebar,
    AppPaletteToken.surface => surface,
    AppPaletteToken.surfaceRaised => surfaceRaised,
    AppPaletteToken.surfaceSunken => surfaceSunken,
    AppPaletteToken.outline => outline,
    AppPaletteToken.outlineSoft => outlineSoft,
    AppPaletteToken.rule => rule,
    AppPaletteToken.textPrimary => textPrimary,
    AppPaletteToken.textSecondary => textSecondary,
    AppPaletteToken.textTertiary => textTertiary,
    AppPaletteToken.accent => accent,
    AppPaletteToken.accentHover => accentHover,
    AppPaletteToken.accentSoft => accentSoft,
    AppPaletteToken.onAccent => onAccent,
    AppPaletteToken.success => success,
    AppPaletteToken.successSoft => successSoft,
    AppPaletteToken.warning => warning,
    AppPaletteToken.warningSoft => warningSoft,
    AppPaletteToken.danger => danger,
    AppPaletteToken.dangerSoft => dangerSoft,
    AppPaletteToken.selection => selection,
    AppPaletteToken.selectionEdge => selectionEdge,
    AppPaletteToken.shadow => shadow,
    AppPaletteToken.overlay => overlay,
  };

  /// Returns a copy with one token replaced.
  AppPalette withToken(AppPaletteToken token, Color value) =>
      withTokens(<AppPaletteToken, Color>{token: value});

  /// Returns a copy where every token present in [values] is replaced; tokens
  /// the map leaves out keep their current colour.
  AppPalette withTokens(Map<AppPaletteToken, Color> values) {
    if (values.isEmpty) return this;
    return _rebuild(<AppPaletteToken, Color>{
      for (final AppPaletteToken t in AppPaletteToken.values)
        t: values[t] ?? colorOf(t),
    });
  }

  AppPalette _rebuild(Map<AppPaletteToken, Color> v) => AppPalette(
    brightness: brightness,
    canvas: v[AppPaletteToken.canvas]!,
    sidebar: v[AppPaletteToken.sidebar]!,
    surface: v[AppPaletteToken.surface]!,
    surfaceRaised: v[AppPaletteToken.surfaceRaised]!,
    surfaceSunken: v[AppPaletteToken.surfaceSunken]!,
    outline: v[AppPaletteToken.outline]!,
    outlineSoft: v[AppPaletteToken.outlineSoft]!,
    rule: v[AppPaletteToken.rule]!,
    textPrimary: v[AppPaletteToken.textPrimary]!,
    textSecondary: v[AppPaletteToken.textSecondary]!,
    textTertiary: v[AppPaletteToken.textTertiary]!,
    accent: v[AppPaletteToken.accent]!,
    accentHover: v[AppPaletteToken.accentHover]!,
    accentSoft: v[AppPaletteToken.accentSoft]!,
    onAccent: v[AppPaletteToken.onAccent]!,
    success: v[AppPaletteToken.success]!,
    successSoft: v[AppPaletteToken.successSoft]!,
    warning: v[AppPaletteToken.warning]!,
    warningSoft: v[AppPaletteToken.warningSoft]!,
    danger: v[AppPaletteToken.danger]!,
    dangerSoft: v[AppPaletteToken.dangerSoft]!,
    selection: v[AppPaletteToken.selection]!,
    selectionEdge: v[AppPaletteToken.selectionEdge]!,
    shadow: v[AppPaletteToken.shadow]!,
    overlay: v[AppPaletteToken.overlay]!,
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

/// What a [AppPaletteToken] is for, in the editor's own grouping language.
enum TokenGroup {
  surface('表面'),
  line('线条'),
  text('文字'),
  accent('强调'),
  status('状态'),
  overlayLayer('选区与浮层');

  const TokenGroup(this.label);

  final String label;
}

/// The 25 editable colour tokens, one per colour field of [AppPalette].
///
/// `brightness` is deliberately **not** here: it is a [Brightness], not a
/// colour, and it is chosen by the 明暗模式 axis rather than by a picker.
///
/// The enum carries what a picker needs (a Chinese [label], a [group], whether
/// the colour has a meaningful alpha), [name] doubles as the stable key of the
/// on-disk format, and tests can iterate [values]. Adding a token therefore
/// breaks the reader, the writer and the codec at compile time — which is
/// exactly the guarantee that "a new token must be handled explicitly" needs.
enum AppPaletteToken {
  canvas('画布', TokenGroup.surface),
  sidebar('侧栏', TokenGroup.surface),
  surface('内容面', TokenGroup.surface),
  surfaceRaised('浮起层', TokenGroup.surface),
  surfaceSunken('凹陷层', TokenGroup.surface),
  outline('边界线', TokenGroup.line),
  outlineSoft('弱分隔线', TokenGroup.line),
  rule('内容横线', TokenGroup.line),
  textPrimary('正文', TokenGroup.text),
  textSecondary('次级文字', TokenGroup.text),
  textTertiary('三级文字', TokenGroup.text),
  accent('强调色', TokenGroup.accent),
  accentHover('强调悬停', TokenGroup.accent),
  accentSoft('强调淡底', TokenGroup.accent),
  onAccent('强调上文字', TokenGroup.accent),
  success('成功', TokenGroup.status),
  successSoft('成功淡底', TokenGroup.status),
  warning('警告', TokenGroup.status),
  warningSoft('警告淡底', TokenGroup.status),
  danger('危险', TokenGroup.status),
  dangerSoft('危险淡底', TokenGroup.status),
  selection('文本选区', TokenGroup.overlayLayer),
  selectionEdge('选区描边', TokenGroup.overlayLayer),
  shadow('投影', TokenGroup.overlayLayer),
  overlay('遮罩', TokenGroup.overlayLayer);

  const AppPaletteToken(this.label, this.group);

  final String label;
  final TokenGroup group;

  /// Only the three translucent tokens get an alpha slider in the picker.
  bool get hasAlpha =>
      this == AppPaletteToken.selection ||
      this == AppPaletteToken.shadow ||
      this == AppPaletteToken.overlay;

  /// The 6 tokens 「简单」 shows: the colours a person can picture by name —
  /// the two background planes, the content plane, the two text weights, and
  /// the accent. A strict subset of [normal], so going up a tier never takes
  /// an option away.
  static const List<AppPaletteToken> simple = <AppPaletteToken>[
    canvas,
    sidebar,
    surface,
    textPrimary,
    textSecondary,
    accent,
  ];

  /// The 12 tokens 「普通」 shows: surface 5 + line 3 + text 3 + the accent
  /// itself — the colours that actually change how the app looks. The 6 status
  /// colours and the 4 floating-layer colours belong to 「高级」.
  static const List<AppPaletteToken> normal = <AppPaletteToken>[
    canvas,
    sidebar,
    surface,
    surfaceRaised,
    surfaceSunken,
    outline,
    outlineSoft,
    rule,
    textPrimary,
    textSecondary,
    textTertiary,
    accent,
  ];
}

/// Ergonomic access: `context.palette.accent`.
extension AppPaletteContext on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.light;
}
