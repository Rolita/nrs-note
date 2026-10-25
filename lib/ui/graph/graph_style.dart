import 'dart:ui' show Color;

import '../../core/theme/app_palette.dart';
import '../../core/theme/table_colors.dart';
import '../../core/utils/table_model.dart' show CellColor, CellColorToken;

/// 图谱的绘制参数——从 [AppPalette] 算出来的一层薄壳。
///
/// painter 只吃这个对象，不碰 `BuildContext`：单测可以直接构造一份断言，
/// 也不用担心画的时候 palette 变了。
///
/// 色相**不新增**：分组色就是表格高亮那六个色名，深色主题解析成 `_darkInks`
/// 那组提亮值，浅色主题解析成 `tableInkColor` 的浅色分支。图谱和表格因此用的是
/// 同一套颜色语言——不是「只在深色下碰巧一致」。
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
      ring = palette.textPrimary,
      label = palette.textSecondary,
      labelHalo = palette.isDark
          ? const Color(0xFF101012)
          : const Color(0xFFEFEFEC),
      node = palette.textSecondary,
      arrow = palette.textPrimary.withValues(
        alpha: palette.isDark ? 0.40 : 0.48,
      ),
      // 数值照抄设计稿：常态边的底是 10%，光带把它拆成
      // 「源 13.5% → 靶 4%」。比原来的单色 8.5% 更淡，但一头亮一头暗，
      // 方向就写在亮度里了。
      beamFrom = palette.isDark ? 0.15 : 0.20,
      beamTo = palette.isDark ? 0.045 : 0.07,
      beamGlow = palette.accent.withValues(
        alpha: palette.isDark ? 0.10 : 0.14,
      ),
      mistAlpha = palette.isDark ? 0.045 : 0.055,
      chip = (palette.isDark ? const Color(0xFF1B1B1E) : const Color(0xFFF7F7F4))
          .withValues(alpha: palette.isDark ? 0.82 : 0.88),
      chipEdge = palette.outlineSoft;

  /// 画布渐变的两端。比 `surface` 更深：正文是亮起的纸，图谱是凹陷的画布，
  /// 一眼就能分清「在看内容」和「在看结构」。
  final Color canvasTop;
  final Color canvasBottom;

  /// 被筛掉的连线，以及边太多、退回单色画法时用的那一档。
  ///
  /// 常态/邻居/焦点三档不再存颜色：它们由 [beamFrom] / [beamTo] 乘以
  /// 节点自己的分组色算出来，一条边一个渐变——见 `GraphPainter._paintEdges`。
  final Color edge;
  final Color edgeDim;

  /// 当前笔记与选中节点的环。
  final Color ring;

  final Color label;

  /// 标签的描边色（画布底色），压在连线上也能读清。
  final Color labelHalo;

  /// 没有分组时的节点色。
  final Color node;

  final Color arrow;

  /// 光带的两端透明度：起点亮、终点暗。
  ///
  /// 方向**写在线里**，不靠箭头解释——一眼就能看出谁引用了谁，
  /// 而不是只看到「这两个有关系」。
  final double beamFrom;
  final double beamTo;

  /// 焦点边垫在下面的那层柔光，像通了电。
  final Color beamGlow;

  /// 每个文件夹一团底雾的透明度。按分组色铺，把簇托出来。
  final double mistAlpha;

  /// 簇名胶囊的底色与描边。
  final Color chip;
  final Color chipEdge;

  /// 分组调色板：表格高亮那六个色名，顺序固定，前六个文件夹各得一色。
  ///
  /// 这里存的是**色名**不是色值。浅色主题下同一批色名会解析成另一组深色值
  /// （`tableInkColor` 的浅色分支），所以在浅色画布上不会糊成一片。
  static const List<CellColorToken> groupTokens = <CellColorToken>[
    CellColorToken.gray,
    CellColorToken.amber,
    CellColorToken.green,
    CellColorToken.blue,
    CellColorToken.purple,
    CellColorToken.red,
  ];
}

/// 色名 → 当前主题下的实际颜色。
///
/// 直接复用 `tableInkColor`：深色主题给 `_darkInks` 那六个提亮过的色，
/// 浅色主题给 `textSecondary / warning / success / #2F6690 / #6B4E8E / danger`。
/// 图谱和表格因此真的是同一套颜色语言，而不是只在深色下碰巧一致。
Color groupColor(AppPalette palette, CellColorToken token) =>
    tableInkColor(palette, CellColor.token(token));

/// 给一批文件夹分配色名。
///
/// 按名字排序后依次取色：顺序稳定（同一批文件夹每次都一样），而且只要文件夹
/// 不超过六个就不会撞色。空字符串（根目录）排在最前面，固定拿到灰色。
///
/// 返回色名而不是颜色，是因为建图发生在 `initState`，那时还读不到 `Theme`；
/// 颜色留到 `build` 里按当前主题解析。
Map<String, CellColorToken> assignFolderTokens(Iterable<String> folders) {
  final List<String> sorted = folders.toSet().toList()..sort();
  final Map<String, CellColorToken> out = <String, CellColorToken>{};
  for (int i = 0; i < sorted.length; i++) {
    out[sorted[i]] =
        GraphStyle.groupTokens[i % GraphStyle.groupTokens.length];
  }
  return out;
}
