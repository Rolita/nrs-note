/// Cell fills and text colors.
///
/// A directive stores a **name** (`amber`) or a literal (`#RRGGBB`). Names are
/// resolved here against the one dark board the app ships; a literal is painted
/// exactly as written, because that is what the user asked for. The one
/// exception is text: a custom fill with no explicit text color gets black or
/// white picked from the fill's actual lightness, so the cell cannot end up
/// unreadable.
library;

import 'package:flutter/material.dart' show Color;

import '../utils/table_model.dart'
    show CellColor, CellColorToken, TableCellStyle;
import 'app_palette.dart';

/// One hand-mixed fill set: each colour carries enough pigment to read as a
/// highlighter on a near-black paper, instead of the palette's soft surfaces,
/// which sank into the page (gray and red were darker than the paper itself).
/// These six values stay independent of the palette on purpose.
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
Color tableFillColor(AppPalette palette, CellColor color) {
  final int? custom = color.custom;
  if (custom != null) return Color(custom);
  return _darkFills[color.token!]!;
}

/// The text color a `fg` token paints with — the lifted counterpart of
/// [tableFillColor], the same hue nudged until it clears 4.5:1 on its fill.
Color tableInkColor(AppPalette palette, CellColor color) {
  final int? custom = color.custom;
  if (custom != null) return Color(custom);
  return _darkInks[color.token!]!;
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
