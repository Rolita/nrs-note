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

/// A fenced block's horizontal padding: the sheet's `pre { padding: 0 16px }`.
///
/// 卡片底色铺满正文列，代码行由按行引擎把这 16px 退进卡片内部
/// （`LineInsetResolver`）。以前没有「一行自己的内边距」这个出口，画笔只能把
/// 卡片画得比正文列宽 16px 来伪造空气；有了按行排版，卡片就能老实待在列内。
const double kCodeBlockInset = 16;

/// Corner radius of a code chip's rounded ends. Small on purpose — at this
/// height anything rounder turns a one-character span into a pill.
const double _kInlineCodeRadius = 3;

/// `#tag` 胶囊的圆角与内边距，对齐设计稿 `.tag`：
/// `padding: 1px 6px 1px 5px; border-radius: var(--r-sm)`（5px）。
///
/// 标签没有反引号那样的隐藏端帽可用，内边距只能由渲染层把底片向两侧多铺
/// 一点——多铺的部分会盖到相邻的空格上。上下那 1px 同理：底片按字号量出来
/// 之后再上下各补 [kTagPadY]，行盒高度不受影响。
const double kTagRadius = 5;
const double kTagPadX = 6;
const double kTagPadY = 1;

/// `==高亮==` 底片的圆角与左右外扩，数值取自参考项目 EPUB Reader V7
/// （`kHighlightFillRadius` / `_kHighlightFillPadX`）。
///
/// 参考项目的理由是「`TextStyle.backgroundColor` 画的是硬边直角矩形，
/// 中文正文里像把字切出来」，所以改成自绘圆角色块、左右各让 1.5px 不贴脸。
const double kHighlightRadius = 4;
const double kHighlightPadX = 1.5;

TextStyle _inlineCode(TextStyle base, AppPalette p, [Color? fill]) =>
    _inlineCodeSource(
      base,
      p,
    ).copyWith(backgroundColor: fill ?? p.surfaceSunken);

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

/// 标签胶囊里的字：12.6px / w600 / 强调色，对齐设计稿 `.tag`（正文 15px，
/// `font-size: 12.5px; font-weight: 600`）。
///
/// `height` 取设计稿正文的 1.78（`.tag` 不设自己的行高，继承 `.doc` 的
/// `line-height: 1.78`）：胶囊的内容盒因此和设计稿一样高 ≈ 22.4px，再叠上
/// [kTagPadY] 的 1px 上下内边距，整个胶囊 ≈ 24.4px——设计稿量出来是 24.25px。
/// 这个盒子比正文行盒（28px）矮，撑不破行距。
///
/// [hovered] 时用设计稿 `.tag:hover` 的前景色：`accent` → `on-accent`。
TextStyle _tagChipText(TextStyle base, AppPalette p, {bool hovered = false}) {
  final double size = (base.fontSize ?? 15).clamp(11.0, 15.0) * 0.84;
  return base.copyWith(
    fontSize: size,
    height: 1.78,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    color: hovered ? p.onAccent : p.accent,
  );
}

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

// ------------------------------------------------- 按行渲染器（line_layout）入口
//
// `line_layout` 一个源码行一个 `TextPainter`，所以它需要「这一行用什么样式」
// 和「这一行固定多高」两个答案，而不是整篇一棵 span 树。下面的公开函数就是
// 那两个答案的唯一来源：样式只在 typography.dart 里定义一次，按行排版和
// 段落排版不会各自漂移。

/// 标题行的排版样式（H1–H6）。
TextStyle liveHeadingStyle(TextStyle base, AppPalette p, int level) =>
    _headingStyle(base, p, level);

/// 围栏代码块里一行的排版样式（等宽、小一号）。
TextStyle liveCodeLineStyle(TextStyle base, AppPalette p) => _codeLine(base, p);

/// 折叠行：语法字符不落墨，但仍在文本里占着原来的偏移。
TextStyle liveCollapsedStyle(TextStyle base) => _collapsed(base);

/// 光标所在行上展开的语法字符：可见，但比正文后退一档。
TextStyle liveMarkerStyle(
  TextStyle base,
  AppPalette p, {
  bool accented = false,
}) => _markerVisible(base, p, accented: accented);

/// 只保留行高、不落墨的行（setext 下划线、表格分隔行）。
TextStyle liveInvisibleStyle(TextStyle base) => _invisible(base);

/// 有序列表序号的样式：强调色、半粗、等宽数字。
TextStyle liveNumberStyle(TextStyle base, AppPalette p) =>
    _numberStyle(base, p);

/// 已完成任务项的正文：降一档颜色并划掉。
TextStyle liveTaskDoneStyle(TextStyle base, AppPalette p) =>
    _struck(base.copyWith(color: p.textSecondary));

/// 折叠代码块的「卡片头」高度：开围栏行就是这一行。
double get liveCodeHeaderHeight => _kCodeHeaderHeight;
