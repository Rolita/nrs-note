import 'package:flutter/material.dart' show Color, TextStyle;

import 'app_palette.dart';

/// `==highlight==` 底片的颜色出口。
///
/// 颜色沿用本项目自己的口径，不跟参考项目走：亮底取主题的 [AppPalette.warningSoft]，
/// 暗底用设计稿定的荧光金（`#D6B14A`）配深色字（`#221A05`，对比度 8.4:1）。
abstract final class HighlightColors {
  /// 暗色高亮的荧光金底。
  static const Color darkFill = Color(0xFFD6B14A);

  /// 荧光金底上的深色字。
  static const Color darkInk = Color(0xFF221A05);

  /// 底片色。
  static Color band(AppPalette palette) =>
      palette.isDark ? darkFill : palette.warningSoft;

  /// 高亮里的字色：荧光金底上必须转深色，否则亮字落在亮金上读不出来。
  static TextStyle inkOn(AppPalette palette, TextStyle style) =>
      palette.isDark ? style.copyWith(color: darkInk) : style;
}
