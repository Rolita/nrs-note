part of '../live_markdown.dart';

/// Everything the inline scanner needs besides the text itself.
class _Ctx {
  _Ctx({
    required this.p,
    required this.caretA,
    required this.caretB,
    required this.selA,
    required this.selB,
    required this.contentWidth,
    this.direction = TextDirection.ltr,
    this.textScaler = TextScaler.noScaling,
    this.plain = false,
    this.hoverA = -1,
    this.hoverB = -1,
    this.onTagTap,
    this.onWikilinkTap,
  });

  final AppPalette p;
  final int caretA;
  final int caretB;

  /// The **live** selection, which the wash follows even while [caretA]/[caretB]
  /// are frozen for a pointer gesture. A rendered chip cannot show the wash
  /// painted behind the field, so it tints itself from this instead.
  final int selA;
  final int selB;

  final double contentWidth;
  final TextDirection direction;

  /// The scale the paragraph will lay the text out at. A table column is sized
  /// from measured text, so the measurement has to be taken under the same
  /// scale the painted text will get — otherwise every column is off by the
  /// user's font-size setting.
  final TextScaler textScaler;

  /// True while laying out text that will be **repainted** by a render object
  /// (a table cell): chips need a [BuildContext] to build, so inside a cell
  /// every inline token falls back to its plain styled text instead.
  final bool plain;

  /// 指针悬停的标签区间（这一行内部偏移）。按行排版没有 widget 可以接
  /// `MouseRegion`，悬停状态由编辑器命中后传进来，只影响标签的颜色。
  final int hoverA;
  final int hoverB;
  final void Function(String tag)? onTagTap;
  final void Function(String target)? onWikilinkTap;

  /// True when the caret (or the reveal selection) overlaps `[a, b]`.
  bool touched(int a, int b) => caretA >= 0 && caretB >= a && caretA <= b;

  /// [a, b] 是否就是指针悬停的那一个标签。
  bool hovered(int a, int b) =>
      hoverA >= 0 && hoverA <= a && hoverB >= b;

  /// True when a **range** of the live selection intersects `[a, b]`.
  bool selected(int a, int b) => selA >= 0 && selB > selA && selB > a && selA < b;
}
