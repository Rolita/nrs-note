/// Cell fills and text colors, resolved against the current theme.
///
/// A directive stores a **name** (`amber`) or a literal (`#RRGGBB`). Names are
/// resolved here so a filled cell stays readable when the app switches to dark
/// mode; a literal is painted exactly as written, because that is what the user
/// asked for. The one exception is text: a custom fill with no explicit text
/// color gets black or white picked from the fill's actual lightness, so the
/// cell cannot end up unreadable.
library;

import 'package:flutter/material.dart' show Color;

import '../utils/table_model.dart'
    show CellColor, CellColorToken, TableCellStyle;
import 'app_palette.dart';

/// Every dark board shares one hand-mixed fill set: each colour carries enough
/// pigment to read as a highlighter on a near-black paper, instead of the
/// palette's soft surfaces, which sank into the page (gray and red were darker
/// than the paper itself). Keeping the six values theme-independent also keeps
/// a table looking the same across the three dark presets.
const Map<CellColorToken, Color> _darkFills = <CellColorToken, Color>{
  CellColorToken.gray: Color(0xFF36383F),
  CellColorToken.amber: Color(0xFF634A12),
  CellColorToken.green: Color(0xFF235C3F),
  CellColorToken.blue: Color(0xFF1D4A73),
  CellColorToken.purple: Color(0xFF402C6B),
  CellColorToken.red: Color(0xFF632727),
};

/// The same hue lifted until it clears 4.5:1 on its own dark fill.
const Map<CellColorToken, Color> _darkInks = <CellColorToken, Color>{
  CellColorToken.gray: Color(0xFFC2C5CC),
  CellColorToken.amber: Color(0xFFF2C35C),
  CellColorToken.green: Color(0xFF6CDEA0),
  CellColorToken.blue: Color(0xFF7FC4F0),
  CellColorToken.purple: Color(0xFFC3A6ED),
  CellColorToken.red: Color(0xFFF09288),
};

/// The background a fill token paints with.
///
/// In light mode the four tokens the palette already has use its soft
/// surfaces; blue and purple are table-only and sit at the same quiet
/// saturation. Dark mode uses [_darkFills] for all six.
Color tableFillColor(AppPalette palette, CellColor color) {
  final int? custom = color.custom;
  if (custom != null) return Color(custom);
  final CellColorToken token = color.token!;
  if (palette.isDark) return _darkFills[token]!;
  return switch (token) {
    CellColorToken.gray => palette.surfaceSunken,
    CellColorToken.amber => palette.warningSoft,
    CellColorToken.green => palette.successSoft,
    CellColorToken.blue => const Color(0xFFE4EBF3),
    CellColorToken.purple => const Color(0xFFEDE7F3),
    CellColorToken.red => palette.dangerSoft,
  };
}

/// The text color a `fg` token paints with — the palette's full-strength
/// counterpart of [tableFillColor].
Color tableInkColor(AppPalette palette, CellColor color) {
  final int? custom = color.custom;
  if (custom != null) return Color(custom);
  final CellColorToken token = color.token!;
  if (palette.isDark) return _darkInks[token]!;
  return switch (token) {
    CellColorToken.gray => palette.textSecondary,
    CellColorToken.amber => palette.warning,
    CellColorToken.green => palette.success,
    CellColorToken.blue => const Color(0xFF2F6690),
    CellColorToken.purple => const Color(0xFF6B4E8E),
    CellColorToken.red => palette.danger,
  };
}

/// The cell's background, or `null` when it has none.
///
/// Alpha is preserved: `#80FFF3C4` is a translucent highlight the way it would
/// be in any other Markdown tool, not a solid block.
Color? tableCellFill(AppPalette palette, TableCellStyle style) {
  final CellColor? color = style.fill;
  return color == null ? null : tableFillColor(palette, color);
}

/// The color a cell's **normal text** should paint with.
///
/// `null` means "keep the editor's text color": an unfilled cell, or a token
/// fill whose palette already pairs with the theme's primary text. A literal
/// fill has no such pairing, so its text contrast is computed from the fill as
/// it lands on the paper.
Color? tableCellInk(AppPalette palette, TableCellStyle style) {
  final CellColor? text = style.text;
  if (text != null) return tableInkColor(palette, text);
  final CellColor? fill = style.fill;
  if (fill != null && fill.custom != null) {
    return AppPalette.readableOn(
      tableFillOver(palette, tableFillColor(palette, fill)),
    );
  }
  return null;
}

/// [fill] composited over the editor's paper — the color the user actually
/// sees, and therefore the one a text contrast or a selection wash must start
/// from.
Color tableFillOver(AppPalette palette, Color fill) =>
    Color.alphaBlend(fill, palette.surface);
