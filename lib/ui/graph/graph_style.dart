import 'dart:ui' show Color;

import '../../core/theme/app_palette.dart';

/// 图谱的绘制参数——从 [AppPalette] 算出来的一层薄壳。
///
/// painter 只吃这个对象，不碰 `BuildContext`：单测可以直接构造一份断言，
/// 也不用担心画的时候 palette 变了。
///
/// 色相**不新增**：分组色就是表格高亮那六色（`table_colors.dart` 的
/// `_darkInks`），所以图谱和表格用的是同一套颜色语言。
class GraphStyle {
  GraphStyle.from(AppPalette palette)
    : canvasTop = palette.isDark
          ? const Color(0xFF1D1D20)
          : const Color(0xFFF4F4F2),
      canvasBottom = palette.isDark
          ? const Color(0xFF101012)
          : const Color(0xFFEAEAE7),
      edge = palette.textPrimary.withValues(
        alpha: palette.isDark ? 0.085 : 0.16,
      ),
      edgeDim = palette.textPrimary.withValues(
        alpha: palette.isDark ? 0.014 : 0.03,
      ),
      edgeLit = palette.textPrimary.withValues(
        alpha: palette.isDark ? 0.34 : 0.42,
      ),
      edgeFocus = palette.textPrimary.withValues(
        alpha: palette.isDark ? 0.62 : 0.68,
      ),
      ring = palette.textPrimary,
      label = palette.textSecondary,
      labelHalo = palette.isDark
          ? const Color(0xFF101012)
          : const Color(0xFFEFEFEC),
      node = palette.textSecondary,
      arrow = palette.textPrimary.withValues(
        alpha: palette.isDark ? 0.28 : 0.36,
      );

  /// 画布渐变的两端。比 `surface` 更深：正文是亮起的纸，图谱是凹陷的画布，
  /// 一眼就能分清「在看内容」和「在看结构」。
  final Color canvasTop;
  final Color canvasBottom;

  /// 连线：常态 / 邻居 / 焦点 / 被筛掉。
  final Color edge;
  final Color edgeLit;
  final Color edgeFocus;
  final Color edgeDim;

  /// 当前笔记与选中节点的环。
  final Color ring;

  final Color label;

  /// 标签的描边色（画布底色），压在连线上也能读清。
  final Color labelHalo;

  /// 没有分组时的节点色。
  final Color node;

  final Color arrow;

  /// 分组调色板。顺序固定，前六个文件夹各得一色。
  static const List<Color> groupPalette = <Color>[
    Color(0xFFC2C5CC), // 灰
    Color(0xFFF2C35C), // 琥珀
    Color(0xFF6CDEA0), // 绿
    Color(0xFF7FC4F0), // 蓝
    Color(0xFFC3A6ED), // 紫
    Color(0xFFF09288), // 红
  ];
}

/// 给一批文件夹分配颜色。
///
/// 按名字排序后依次取色：顺序稳定（同一批文件夹每次都一样），而且只要文件夹
/// 不超过六个就不会撞色。空字符串（根目录）排在最前面，固定拿到灰色。
Map<String, Color> assignFolderColors(Iterable<String> folders) {
  final List<String> sorted = folders.toSet().toList()..sort();
  final Map<String, Color> out = <String, Color>{};
  for (int i = 0; i < sorted.length; i++) {
    out[sorted[i]] = GraphStyle.groupPalette[i % GraphStyle.groupPalette.length];
  }
  return out;
}
