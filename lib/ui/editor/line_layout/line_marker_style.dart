/// 列表标记（圆点 / 序号 / 复选框 / 缩进导轨）的绘制样式。
///
/// 渲染层不认主题，也不认 `AppPalette`：它只知道「这里要一个圆点、那里要
/// 一条导轨」。宿主把颜色算好一次性交进来，主题切换时重建一个等价的值即可。
///
/// 这里的取值与 `live_markdown` 的既有实现逐项对齐（圆点 5×5、复选框
/// 15×15、边距 2/9、序号强调色半粗等宽数字），两边不会因为各写一份而漂移。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

@immutable
class LineMarkerStyle {
  const LineMarkerStyle({
    required this.bullet,
    required this.rail,
    required this.accent,
    required this.onAccent,
    required this.boxBorder,
    required this.muted,
    required this.number,
  });

  /// 无序列表的实心圆点。
  final Color bullet;

  /// 嵌套缩进导轨（一级一条竖线）。
  final Color rail;

  /// 强调色：勾选后的复选框底色。
  final Color accent;

  /// 勾的颜色（画在强调色底上）。
  final Color onAccent;

  /// 未勾选复选框的描边。
  final Color boxBorder;

  /// 已完成任务项的序号颜色（与划掉的正文同一档）。
  final Color muted;

  /// 有序列表序号的样式（`1.`），按正文样式推导后由宿主给出。
  final TextStyle number;

  @override
  bool operator ==(Object other) =>
      other is LineMarkerStyle &&
      other.bullet == bullet &&
      other.rail == rail &&
      other.accent == accent &&
      other.onAccent == onAccent &&
      other.boxBorder == boxBorder &&
      other.muted == muted &&
      other.number == number;

  @override
  int get hashCode =>
      Object.hash(bullet, rail, accent, onAccent, boxBorder, muted, number);
}
