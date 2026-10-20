part of '../live_markdown.dart';

// ------------------------------------------------------------------ styles

TextStyle _headingStyle(TextStyle base, AppPalette p, int level) {
  final double s = base.fontSize ?? 15;
  // The designed line box is the only lever a heading has for breathing room:
  // there is no margin between blocks here — markup characters are collapsed in
  // place, never spliced with spacer spans, or the tree would stop matching the
  // text. Airy leading therefore buys the space above and below that a margin
  // would have given, and it still snaps to a whole-pixel advance.
  // The ratios are read off the design sheet at a 15.5px body: H1 27, H2 19,
  // H3 16 — i.e. 1.74 / 1.23 / 1.03. They used to be 1.62 / 1.36 / 1.18, which
  // made the body's H2 nearly as tall as the note title and left H3 within a
  // pixel of it, so a note read as three shades of the same size.
  final (double scale, double height, double tracking) = switch (level) {
    1 => (1.74, 1.45, -0.45),
    2 => (1.23, 1.75, -0.3),
    3 => (1.03, 1.9, -0.15),
    4 => (0.99, 1.9, -0.1),
    5 => (0.95, 1.95, 0),
    _ => (0.91, 2.0, 0.1),
  };
  return base.copyWith(
    fontSize: s * scale,
    height: snapLineHeight(s * scale, height),
    letterSpacing: tracking,
    // w600, not w700: at 27px the extra weight reads as a browser's `<h1>`
    // default rather than as the design sheet's semibold.
    fontWeight: FontWeight.w600,
    color: level == 6 ? p.textTertiary : p.textPrimary,
  );
}

TextStyle _codeLine(TextStyle base, AppPalette p) {
  // 0.84 of the body size: the design sheet's `pre code` is 12.5px against a
  // 15px paragraph. Code used to be 0.94, which made a fenced block read as
  // loudly as the prose around it.
  final double s = (base.fontSize ?? 15) * 0.84;
  return base.copyWith(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: s,
    // 1.5 of air, the reference's `pre code { line-height: 1.5 }`. A fenced
    // block is the one place where rows are *not* on the body's grid: code is
    // read line by line, and body leading (1.78) made a snippet look
    // double-spaced next to the reference.
    height: snapLineHeight(s, 1.5),
    color: CodePalette.forDark(p.isDark).plain,
    letterSpacing: 0,
  );
}

/// Horizontal padding inside an inline code chip, carried by the two backticks.
const double _kInlineCodePad = 4;

/// Corner radius of a code chip's rounded ends. Small on purpose — at this
/// height anything rounder turns a one-character span into a pill.
const double _kInlineCodeRadius = 3;

TextStyle _inlineCode(TextStyle base, AppPalette p, [Color? fill]) =>
    _inlineCodeSource(base, p).copyWith(
      backgroundColor: fill ?? p.surfaceSunken,
    );

/// The code run while it is being edited: same face and size as the chip, but
/// no fill — the backticks and the plain background are what say "source".
TextStyle _inlineCodeSource(TextStyle base, AppPalette p) {
  // Same ratio as a fenced block — the sheet uses one size for both, and a
  // chip that is bigger than the code block it sits next to looks like a bug.
  final double s = (base.fontSize ?? 15) * 0.84;
  return base.copyWith(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: AppFonts.monoFallback,
    fontSize: s,
    // A line that is *only* inline code still owes the paragraph a whole-pixel
    // advance, or it shows the same seam as body text.
    height: snapLineHeight(s, base.height ?? 1.78),
    color: p.textPrimary,
  );
}

/// `surfaceSunken` with the selection wash mixed in, for a chip the live
/// selection covers while the reveal is frozen.
Color _selectedChip(AppPalette p) =>
    Color.alphaBlend(p.selection, p.surfaceSunken);

/// A content rule that has to *read* as a line: a table's header and closing
/// rules, and the outline of a checkbox.
///
/// [AppPalette.rule] is already separated from the surface; this is the step
/// above it, for the few lines that carry a boundary rather than a grid. [Color.alphaBlend]
/// rather than a fixed hex so the step keeps its relationship to the rule in
/// both themes.
Color _strongRule(AppPalette p) =>
    Color.alphaBlend(p.textTertiary.withValues(alpha: 0.55), p.rule);

TextStyle _numberStyle(TextStyle base, AppPalette p) => base.copyWith(
  color: p.accent,
  fontWeight: FontWeight.w600,
  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
);

/// A run that has been crossed out — a ticked task, an inline `~~deletion~~`.
///
/// Two things have to be true for the rule to read as a deletion rather than as
/// a scratch on the line:
///
/// * **Thickness.** `decorationThickness: 2` is a multiplier of the font's own
///   underline weight, which is a fraction of a pixel at this body size. At 1
///   the rule is a hairline that disappears between the glyph stems; at 2 it is
///   the ~2px stroke the eye reads as a struck-through word.
/// * **Colour.** The rule is painted in the colour of the text it crosses
///   (CSS `currentColor`), so a struck word looks *crossed out* instead of
///   having a separately-coloured line laid over it. A rule dimmer than its own
///   text — which is what pinning it to `textTertiary` did — reads as a smudge
///   and was the whole of "删除线不够明显".
TextStyle _struck(TextStyle base) => base.copyWith(
  decoration: TextDecoration.lineThrough,
  decorationThickness: 2,
  decorationColor: base.color,
);

TextStyle _tagText(TextStyle base, AppPalette p) =>
    base.copyWith(color: p.accent);

TextStyle _wikiText(TextStyle base, AppPalette p) => base.copyWith(
  color: p.accent,
  decoration: TextDecoration.underline,
  decorationStyle: TextDecorationStyle.dotted,
  decorationColor: p.accent.withValues(alpha: 0.45),
);

TextStyle _linkText(TextStyle base, AppPalette p) => base.copyWith(
  color: p.accent,
  decoration: TextDecoration.underline,
  decorationColor: p.accent.withValues(alpha: 0.35),
);

/// Punctuation the caret is sitting in — visible but receded.
TextStyle _markerVisible(
  TextStyle base,
  AppPalette p, {
  bool accented = false,
}) => base.copyWith(
  color: accented
      ? p.accent.withValues(alpha: 0.75)
      : p.textTertiary.withValues(alpha: 0.8),
);

/// Punctuation with nothing to reveal: zero size, zero advance.
///
/// `letterSpacing` and `wordSpacing` must be zeroed explicitly — they are *per
/// character* additions that have nothing to do with the font size, so leaving
/// the base tracking on a hidden run leaves a visible gap behind every hidden
/// `*`.
TextStyle _collapsed(TextStyle base) => base.copyWith(
  fontSize: _kHiddenFontSize,
  height: 1,
  letterSpacing: 0,
  wordSpacing: 0,
  color: Colors.transparent,
);

/// A row that is *only* syntax (a setext underline, a table divider) is painted
/// transparent instead of zero-size, so the row keeps its normal height and a
/// caret landing on it stays visible and clickable.
TextStyle _invisible(TextStyle base) =>
    base.copyWith(color: Colors.transparent);
