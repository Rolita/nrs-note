import 'package:flutter/material.dart' show Color;

/// `==highlight==` 底片的颜色出口。
///
/// 颜色沿用本项目自己的口径，不跟参考项目走：设计稿定的荧光金（`#D6B14A`）
/// 配深色字（`#221A05`，对比度 8.4:1）。只有这一套——应用自 2026-10-27 起
/// 固定深色，没有亮底那一档了。
abstract final class HighlightColors {
  /// 荧光金底。
  static const Color darkFill = Color(0xFFD6B14A);

  /// 荧光金底上的深色字。
  static const Color darkInk = Color(0xFF221A05);
}
