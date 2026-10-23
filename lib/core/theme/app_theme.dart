import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'app_tokens.dart';

/// Builds the [ThemeData] for a given [AppPalette].
///
/// The app deliberately keeps Flutter's default component shapes almost
/// untouched and instead drives everything through semantic colour tokens plus
/// a hand-tuned type scale — that is what gives NRS its calm, editorial feel.
abstract final class AppTheme {
  static ThemeData build(AppPalette p) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: p.accent,
          brightness: p.brightness,
        ).copyWith(
          // Every slot below is set explicitly. `fromSeed` derives a *whole*
          // tonal palette from the seed, so any slot left unset leaks a colour
          // derived from the user's accent — a "vivid teal" accent used to tint
          // `secondary`, `surfaceVariant` and dropdown menus into hues that
          // belong to no preset. Mapping each slot to a semantic token keeps the
          // chrome neutral no matter what the accent is.
          primary: p.accent,
          onPrimary: p.onAccent,
          primaryContainer: p.accentSoft,
          onPrimaryContainer: p.textPrimary,
          secondary: p.textSecondary,
          onSecondary: p.surfaceRaised,
          secondaryContainer: p.surfaceSunken,
          onSecondaryContainer: p.textPrimary,
          tertiary: p.accentHover,
          onTertiary: p.onAccent,
          tertiaryContainer: p.accentSoft,
          onTertiaryContainer: p.textPrimary,
          error: p.danger,
          onError: p.onAccent,
          errorContainer: p.dangerSoft,
          onErrorContainer: p.textPrimary,
          surface: p.surface,
          onSurface: p.textPrimary,
          surfaceContainerLowest: p.surface,
          surfaceContainerLow: p.surface,
          surfaceContainer: p.surfaceRaised,
          surfaceContainerHigh: p.surfaceRaised,
          surfaceContainerHighest: p.surfaceRaised,
          onSurfaceVariant: p.textSecondary,
          inverseSurface: p.textPrimary,
          onInverseSurface: p.surface,
          inversePrimary: p.accentSoft,
          outline: p.outline,
          outlineVariant: p.outlineSoft,
          shadow: p.shadow,
          // Material's own scrim is opaque black in both brightnesses; the app
          // passes `p.overlay` explicitly wherever it opens a dialog, so this is
          // only a backstop for a component that reaches for the scheme.
          scrim: const Color(0xFF000000),
          // Elevation must never tint a surface: the shell separates its panels
          // with hairlines, and a tinted panel would break that.
          surfaceTint: Colors.transparent,
        );

    final TextTheme text = _textTheme(p);

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.canvas,
      canvasColor: p.surface,
      textTheme: text,
      primaryTextTheme: text,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      extensions: <ThemeExtension<dynamic>>[p],
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      visualDensity: VisualDensity.standard,
      dividerTheme: DividerThemeData(
        color: p.outlineSoft,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: p.textSecondary, size: 18),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) => s.contains(WidgetState.hovered)
              ? p.textTertiary.withValues(alpha: 0.7)
              : p.outline,
        ),
        trackColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        trackBorderColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        crossAxisMargin: 2,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 420),
        textStyle: TextStyle(
          fontSize: 12,
          height: 1.3,
          color: p.brightness == Brightness.dark ? p.canvas : p.surfaceRaised,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.sm,
          vertical: AppSpace.xs + 1,
        ),
        decoration: BoxDecoration(
          color: p.textPrimary.withValues(alpha: p.isDark ? 0.94 : 0.92),
          borderRadius: AppRadius.smAll,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: p.shadow,
        menuPadding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
          side: BorderSide(color: p.outline),
        ),
        textStyle: TextStyle(fontSize: AppText.ui, color: p.textPrimary),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(p.surfaceRaised),
          surfaceTintColor: const WidgetStatePropertyAll<Color>(
            Colors.transparent,
          ),
          elevation: const WidgetStatePropertyAll<double>(12),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: AppRadius.mdAll,
              side: BorderSide(color: p.outline),
            ),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surfaceRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 14,
        shadowColor: p.shadow,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.xlAll),
        titleTextStyle: TextStyle(
          fontSize: AppText.display,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
          color: p.textPrimary,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
        contentTextStyle: TextStyle(
          fontSize: AppText.body,
          height: 1.5,
          color: p.textSecondary,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        isDense: true,
        filled: true,
        fillColor: p.surfaceRaised,
        hintStyle: TextStyle(fontSize: AppText.ui, color: p.textTertiary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpace.sm + 2,
          vertical: AppSpace.xs + 2,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.smAll,
          borderSide: BorderSide(color: p.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.smAll,
          borderSide: BorderSide(color: p.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.smAll,
          borderSide: BorderSide(color: p.accent, width: 1.4),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        side: BorderSide(color: p.outline, width: 1.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        fillColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) =>
              s.contains(WidgetState.selected) ? p.accent : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll<Color>(p.onAccent),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) =>
              s.contains(WidgetState.selected) ? p.onAccent : p.surfaceRaised,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) =>
              s.contains(WidgetState.selected) ? p.accent : p.surfaceSunken,
        ),
        trackOutlineColor: WidgetStatePropertyAll<Color>(p.outline),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.accent,
        inactiveTrackColor: p.surfaceSunken,
        thumbColor: p.accent,
        overlayColor: p.accent.withValues(alpha: 0.12),
        trackHeight: 3,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.surfaceSunken,
        circularTrackColor: p.surfaceSunken,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.selection,
        selectionHandleColor: p.accent,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          textStyle: TextStyle(
            fontSize: AppText.ui,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smAll),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.sm + 2,
            vertical: AppSpace.xs,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.onAccent,
          textStyle: TextStyle(
            fontSize: AppText.ui,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smAll),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.sm,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.textPrimary,
          side: BorderSide(color: p.outline),
          textStyle: TextStyle(
            fontSize: AppText.ui,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.smAll),
        ),
      ),
    );
  }

  static TextTheme _textTheme(AppPalette p) {
    TextStyle s(
      double size,
      FontWeight weight, {
      double height = 1.35,
      double tracking = 0,
      Color? color,
    }) => TextStyle(
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: tracking,
      color: color ?? p.textPrimary,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );

    return TextTheme(
      displayLarge: s(34, FontWeight.w600, height: 1.14, tracking: -0.9),
      displayMedium: s(28, FontWeight.w600, height: 1.18, tracking: -0.7),
      displaySmall: s(23, FontWeight.w600, height: 1.22, tracking: -0.5),
      headlineMedium: s(20, FontWeight.w600, height: 1.28, tracking: -0.35),
      headlineSmall: s(17.5, FontWeight.w600, height: 1.3, tracking: -0.2),
      titleLarge: s(16, FontWeight.w600, height: 1.32, tracking: -0.2),
      titleMedium: s(14.5, FontWeight.w600, height: 1.34, tracking: -0.1),
      titleSmall: s(13, FontWeight.w600, height: 1.34),
      bodyLarge: s(15, FontWeight.w400, height: 1.55),
      bodyMedium: s(13.5, FontWeight.w400, height: 1.55),
      bodySmall: s(12.5, FontWeight.w400, height: 1.5, color: p.textSecondary),
      labelLarge: s(13, FontWeight.w600, height: 1.2),
      labelMedium: s(12, FontWeight.w500, height: 1.2, color: p.textSecondary),
      labelSmall: s(
        11,
        FontWeight.w600,
        height: 1.2,
        tracking: 0.3,
        color: p.textTertiary,
      ),
    );
  }
}
