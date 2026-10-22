import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_palette.dart';

/// The colour schemes the app ships, plus the sentinel for "the user's own".
///
/// `values` order is the order the picker shows them in, and [fallback] — the
/// default for a fresh install *and* for an existing install that upgrades from
/// the retired amber board — is deliberately first.
enum ThemePresetId {
  graphite('石墨素白', LucideIcons.penLine),
  midnight('午夜靛', LucideIcons.moonStar),
  vivid('高对比', LucideIcons.zap),
  custom('自定义', LucideIcons.slidersHorizontal);

  const ThemePresetId(this.label, this.icon);

  final String label;
  final IconData icon;

  static const ThemePresetId fallback = ThemePresetId.graphite;
}

/// One named scheme: a light face and a dark face.
@immutable
class ThemePreset {
  const ThemePreset({required this.id, required this.light, required this.dark});

  final ThemePresetId id;
  final AppPalette light;
  final AppPalette dark;

  AppPalette paletteFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// The three built-in schemes, the resolver, and the editor's starting point.
abstract final class ThemePresets {
  /// 石墨素白 reuses the hand-written constants, so [AppPalette.light] /
  /// [AppPalette.dark] *are* this preset — which is what lets the existing
  /// test fixtures keep using those two names unchanged.
  static const ThemePreset _graphite = ThemePreset(
    id: ThemePresetId.graphite,
    light: AppPalette.light,
    dark: AppPalette.dark,
  );

  static final ThemePreset _midnight = ThemePreset(
    id: ThemePresetId.midnight,
    light: _board(
      brightness: Brightness.light,
      canvas: const Color(0xFFF6F7FA),
      sidebar: const Color(0xFFEEF1F6),
      surface: const Color(0xFFFBFCFE),
      raised: const Color(0xFFFFFFFF),
      sunken: const Color(0xFFEAECF3),
      outline: const Color(0xFFD7DBE6),
      outlineSoft: const Color(0xFFE6E9F0),
      rule: const Color(0xFFCFD4E0),
      textPrimary: const Color(0xFF171A21),
      textSecondary: const Color(0xFF565D6E),
      textTertiary: const Color(0xFF8A91A2),
      accent: const Color(0xFF4A56C4),
      accentHover: const Color(0xFF3B46A8),
      accentSoft: const Color(0xFFE6E8FB),
      onAccent: const Color(0xFFFFFFFF),
      success: const Color(0xFF2E8B62),
      successSoft: const Color(0xFFE2F1E9),
      warning: const Color(0xFFB26A1A),
      warningSoft: const Color(0xFFF8EADB),
      danger: const Color(0xFFC4473F),
      dangerSoft: const Color(0xFFFBEAE8),
      selection: const Color(0x334A56C4),
    ),
    dark: _board(
      brightness: Brightness.dark,
      canvas: const Color(0xFF0E0F13),
      sidebar: const Color(0xFF131419),
      surface: const Color(0xFF17181E),
      raised: const Color(0xFF1F2027),
      sunken: const Color(0xFF0A0B0E),
      outline: const Color(0xFF2A2C36),
      outlineSoft: const Color(0xFF1E2028),
      rule: const Color(0xFF32343F),
      textPrimary: const Color(0xFFE6E8EF),
      textSecondary: const Color(0xFF9AA0B0),
      textTertiary: const Color(0xFF6A7080),
      accent: const Color(0xFF8B94F2),
      accentHover: const Color(0xFFA0A8F7),
      accentSoft: const Color(0xFF23263A),
      onAccent: const Color(0xFF10122A),
      success: const Color(0xFF5FC79A),
      successSoft: const Color(0xFF13251D),
      warning: const Color(0xFFE0A24A),
      warningSoft: const Color(0xFF2E2413),
      danger: const Color(0xFFE4797F),
      dangerSoft: const Color(0xFF2C1A1F),
      selection: const Color(0x4D8B94F2),
    ),
  );

  static final ThemePreset _vivid = ThemePreset(
    id: ThemePresetId.vivid,
    light: _board(
      brightness: Brightness.light,
      canvas: const Color(0xFFFAFAFA),
      sidebar: const Color(0xFFF4F4F5),
      surface: const Color(0xFFFFFFFF),
      raised: const Color(0xFFFFFFFF),
      sunken: const Color(0xFFF0F0F1),
      outline: const Color(0xFFDFDFE2),
      outlineSoft: const Color(0xFFEDEDEE),
      rule: const Color(0xFFD7D7DA),
      textPrimary: const Color(0xFF09090B),
      textSecondary: const Color(0xFF52525B),
      textTertiary: const Color(0xFF8A8A93),
      accent: const Color(0xFF0D9488),
      accentHover: const Color(0xFF0F766E),
      accentSoft: const Color(0xFFD9F2EF),
      onAccent: const Color(0xFFFFFFFF),
      success: const Color(0xFF059669),
      successSoft: const Color(0xFFDFF3EA),
      warning: const Color(0xFFB45309),
      warningSoft: const Color(0xFFFDEBD3),
      danger: const Color(0xFFDC2626),
      dangerSoft: const Color(0xFFFDE7E7),
      selection: const Color(0x330D9488),
    ),
    dark: _board(
      brightness: Brightness.dark,
      canvas: const Color(0xFF09090B),
      sidebar: const Color(0xFF0E0E11),
      surface: const Color(0xFF121215),
      raised: const Color(0xFF1A1A1E),
      sunken: const Color(0xFF050506),
      outline: const Color(0xFF26262B),
      outlineSoft: const Color(0xFF1B1B1F),
      rule: const Color(0xFF2E2E34),
      textPrimary: const Color(0xFFFAFAFA),
      textSecondary: const Color(0xFFA1A1AA),
      textTertiary: const Color(0xFF63636B),
      accent: const Color(0xFF2DD4BF),
      accentHover: const Color(0xFF5EEAD4),
      accentSoft: const Color(0xFF10302C),
      onAccent: const Color(0xFF04211D),
      success: const Color(0xFF34D399),
      successSoft: const Color(0xFF10281F),
      warning: const Color(0xFFFBBF24),
      warningSoft: const Color(0xFF30240D),
      danger: const Color(0xFFF87171),
      dangerSoft: const Color(0xFF301618),
      selection: const Color(0x3D2DD4BF),
    ),
  );

  /// The three real schemes, in picker order.
  ///
  /// [ThemePresetId.custom] is **not** in here — it is a sentinel meaning "use
  /// the user's overlay", not a scheme of its own.
  static final List<ThemePreset> builtIn = <ThemePreset>[
    _graphite,
    _midnight,
    _vivid,
  ];

  /// Looks a preset up by id. Anything unknown, and [ThemePresetId.custom],
  /// falls back to 石墨素白.
  static ThemePreset of(ThemePresetId id) {
    for (final ThemePreset p in builtIn) {
      if (p.id == id) return p;
    }
    return _graphite;
  }

  /// The palette actually in force: the custom overlay when the preset is
  /// [ThemePresetId.custom] *and* an overlay exists, the built-in board
  /// otherwise. A `vivid` selection is never overridden by a stale custom layer.
  static AppPalette resolve({
    required ThemePresetId preset,
    required CustomPalette? custom,
    required Brightness brightness,
  }) {
    if (preset == ThemePresetId.custom && custom != null) {
      return custom.paletteFor(brightness);
    }
    return of(preset).paletteFor(brightness);
  }

  /// Where the editor starts: a full copy of [from]'s two boards, so seeding
  /// from a scheme and touching nothing changes nothing on screen.
  static CustomPalette seed(ThemePresetId from) {
    final ThemePreset p = of(from);
    return CustomPalette(light: p.light, dark: p.dark);
  }
}

/// Assembles a palette from the 22 variables a preview board carries, deriving
/// the three that are never authored by hand.
AppPalette _board({
  required Brightness brightness,
  required Color canvas,
  required Color sidebar,
  required Color surface,
  required Color raised,
  required Color sunken,
  required Color outline,
  required Color outlineSoft,
  required Color rule,
  required Color textPrimary,
  required Color textSecondary,
  required Color textTertiary,
  required Color accent,
  required Color accentHover,
  required Color accentSoft,
  required Color onAccent,
  required Color success,
  required Color successSoft,
  required Color warning,
  required Color warningSoft,
  required Color danger,
  required Color dangerSoft,
  required Color selection,
}) => AppPalette(
  brightness: brightness,
  canvas: canvas,
  sidebar: sidebar,
  surface: surface,
  surfaceRaised: raised,
  surfaceSunken: sunken,
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
  selectionEdge: selectionEdgeFor(accent, brightness),
  shadow: shadowFor(brightness),
  overlay: overlayFor(brightness),
);

/// The 1px edge around a selected block.
///
/// On a light board it is the accent itself. On a dark board an `accent` line
/// at 1px reads as a glow rather than an edge, so it is stepped down to 86% of
/// the accent's lightness — the same move the retired amber board made.
Color selectionEdgeFor(Color accent, Brightness brightness) {
  if (brightness != Brightness.dark) return accent;
  final HSLColor hsl = HSLColor.fromColor(accent);
  return hsl.withLightness((hsl.lightness * 0.86).clamp(0.0, 1.0)).toColor();
}

/// Ambient shadow, already alpha-composited.
Color shadowFor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0x66000000)
    : const Color(0x14000000);

/// Dialog scrim.
Color overlayFor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0x99000000)
    : const Color(0x33000000);

/// A user-authored board: both faces, 25 absolute colours each.
///
/// Both faces are stored in full rather than as a diff against a preset, so the
/// object is self-contained — it does not need to remember which scheme it was
/// seeded from, and reordering or retiring a preset can never shift it.
@immutable
class CustomPalette {
  CustomPalette({required this.light, required this.dark})
    : raw = _encode(light, dark);

  final AppPalette light;
  final AppPalette dark;

  /// The canonical JSON for this board. Doubles as the `ThemeData` memo key and
  /// as the dirty check, so it must always agree with [light] / [dark].
  final String raw;

  AppPalette paletteFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// Replaces one token on one face.
  CustomPalette withToken(
    Brightness brightness,
    AppPaletteToken token,
    Color value,
  ) => withTokens(brightness, <AppPaletteToken, Color>{token: value});

  /// Replaces every token present in [values] on one face.
  CustomPalette withTokens(
    Brightness brightness,
    Map<AppPaletteToken, Color> values,
  ) {
    if (values.isEmpty) return this;
    final AppPalette next = paletteFor(brightness).withTokens(values);
    return CustomPalette(
      light: brightness == Brightness.dark ? light : next,
      dark: brightness == Brightness.dark ? next : dark,
    );
  }

  /// Reads a board back from [raw]; returns null when it is missing, empty or
  /// does not parse.
  ///
  /// Forward-compatible on purpose: token keys that were unknown are ignored,
  /// and token keys that are absent fall back to 石墨素白's value, so a board
  /// written by an older build still loads after a token is added. `"v"` is the
  /// migration hook for the day a token's *meaning* changes.
  static CustomPalette? decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (parsed is! Map) return null;

    final Object? lightRaw = parsed['light'];
    final Object? darkRaw = parsed['dark'];
    if (lightRaw is! Map || darkRaw is! Map) return null;

    final ThemePreset base = ThemePresets.of(ThemePresetId.fallback);
    return CustomPalette(
      light: _merge(base.light, lightRaw),
      dark: _merge(base.dark, darkRaw),
    );
  }

  static AppPalette _merge(AppPalette base, Map<dynamic, dynamic> values) {
    final Map<AppPaletteToken, Color> parsed = <AppPaletteToken, Color>{};
    for (final AppPaletteToken token in AppPaletteToken.values) {
      final Color? c = _parseHex(values[token.name]);
      if (c != null) parsed[token] = c;
    }
    return base.withTokens(parsed);
  }

  static String _encode(AppPalette light, AppPalette dark) {
    Map<String, String> face(AppPalette p) => <String, String>{
      for (final AppPaletteToken t in AppPaletteToken.values)
        t.name: _hex(p.colorOf(t)),
    };
    return jsonEncode(<String, Object?>{
      'v': 1,
      'light': face(light),
      'dark': face(dark),
    });
  }

  static String _hex(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0');

  static Color? _parseHex(Object? value) {
    if (value is! String) return null;
    final int? n = int.tryParse(value.trim(), radix: 16);
    if (n == null) return null;
    // Six digits mean an opaque colour: no alpha byte was written.
    return value.trim().length <= 6 ? Color(0xFF000000 | n) : Color(n);
  }
}
