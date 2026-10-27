import 'dart:ui' show Color;

import '../../core/theme/app_palette.dart';
import '../../core/theme/table_colors.dart';
import '../../core/utils/table_model.dart' show CellColor, CellColorToken;

/// 图谱的绘制参数——从 [AppPalette] 算出来的一层薄壳。
///
/// painter 只吃这个对象，不碰 `BuildContext`：单测可以直接构造一份断言，
/// 也不用担心画的时候 palette 变了。
///
/// 配色照 `design/graph-obsidian-clone.html`：**只有一个底色、一种节点灰、
/// 一种线色**。图谱是结构视图，颜色一多，读者就开始猜「这个黄是什么意思」，
/// 而它什么也不表示。
class GraphStyle {
  GraphStyle.from(AppPalette palette)
    : canvas = const Color(0xFF1E1E1E),
      node = const Color(0xFF9D9D9D),
      edgeTint = const Color(0xFFFFFFFF),
      ring = palette.accent,
      label = const Color(0xFFDADADA),
      labelFocus = const Color(0xFFFFFFFF),
      labelHalo = const Color(0xFF1E1E1E);

  /// 画布底色。**纯色，没有渐变**：Obsidian 的图谱就是主题底色，
  /// 加一层径向渐变只会让画布看起来像个装饰品。
  final Color canvas;

  /// 节点色。没开「按文件夹着色」时全图一个灰。
  final Color node;

  /// 连线色。黑底上是白——连线靠「比底色亮一点」表达，不靠彩度。
  final Color edgeTint;

  /// 选中节点的环，以及选中节点的填充色。
  final Color ring;

  final Color label;

  /// 焦点节点的标签——纯白，压过周围所有字。
  final Color labelFocus;

  /// 标签的投影色（画布底色）。压在连线上也能读清。
  final Color labelHalo;

  /// 连线的五档亮度，照设计稿 `edgeAlpha()`。
  ///
  /// 档位之间差得很大是**故意**的：0.62 对 0.11 是五倍多，焦点那几条线
  /// 才像「通了电」。差得小的话，整张图会糊成一张均匀的网。
  static const double edgeBase = 0.11;
  static const double edgeFocus = 0.62;
  static const double edgeNear = 0.16;
  static const double edgeFar = 0.045;
  static const double edgeDim = 0.035;

  /// 分组调色板：表格高亮那六个色名，顺序固定，前六个文件夹各得一色。
  ///
  /// 这里存的是**色名**不是色值，解析交给 `groupColor`——建图发生在
  /// `initState`，那时还读不到 `Theme`。
  static const List<CellColorToken> groupTokens = <CellColorToken>[
    CellColorToken.gray,
    CellColorToken.amber,
    CellColorToken.green,
    CellColorToken.blue,
    CellColorToken.purple,
    CellColorToken.red,
  ];
}

/// 色名 → 实际颜色。
///
/// 直接复用 `tableInkColor` 那六个提亮过的色：图谱和表格因此真的是同一套
/// 颜色语言，而不是两套碰巧看着像的色值。
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
