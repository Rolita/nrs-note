import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/table_colors.dart';
import '../../core/utils/table_model.dart' show CellColor, CellColorToken;

/// 白板的配色与刻度。
///
/// 视觉基准是 graphif：白板是**一块坐标系**（有刻度、有原点十字），
/// 卡片是**一根描边**而不是一块色块。所以这里的令牌分三组：
///
/// * **网格**：[gridMajor] 主格（带刻度数字）、[axis] 原点十字。刻意压得很淡
///   ——网格是背景的纹理，不是内容。**没有次格**：格子里不再切小格。
/// * **标尺**：贴在画布上边与左边的两条带（[canvasRulerThickness] 像素），
///   底色就是画布色，所以内容滚到它下面会被截断，像真的尺子压着纸。
/// * **卡片**：统一的中性半透明底（[cardFill]）+ 一根细描边。六种预设色
///   **不再进底色**，只染描边和文字（见 [canvasCardBorder] / [canvasCardInk]）。
class CanvasStyle {
  const CanvasStyle({
    required this.background,
    required this.gridMajor,
    required this.axis,
    required this.rulerBackground,
    required this.rulerText,
    required this.rulerTick,
    required this.rulerEdge,
    required this.cardFill,
    required this.groupOutline,
    required this.accent,
    required this.accentSoft,
    required this.selectionFill,
    required this.selectionOutline,
    required this.edge,
    required this.edgeSelected,
    required this.edgeLabel,
    required this.labelHalo,
    required this.textPrimary,
    required this.textSecondary,
    required this.handle,
    required this.handleRing,
    required this.emptyHint,
  });

  factory CanvasStyle.of(AppPalette p) => CanvasStyle(
    background: p.canvas,
    // 只有一层格线：再淡就看不见，再亮就抢内容。
    gridMajor: p.textPrimary.withValues(alpha: 0.085),
    axis: p.accent.withValues(alpha: 0.24),
    rulerBackground: p.canvas,
    rulerText: p.textTertiary,
    rulerTick: p.textPrimary.withValues(alpha: 0.16),
    rulerEdge: p.outline,
    // 卡片只比画布亮一点点：轮廓由那根描边交代，不靠色块和投影。
    cardFill: p.surfaceRaised.withValues(alpha: 0.72),
    groupOutline: p.textPrimary.withValues(alpha: 0.22),
    accent: p.accent,
    accentSoft: p.accentSoft,
    selectionFill: p.accentSoft.withValues(alpha: 0.40),
    selectionOutline: p.accent.withValues(alpha: 0.70),
    edge: p.textPrimary.withValues(alpha: 0.30),
    edgeSelected: p.accent,
    edgeLabel: p.textSecondary,
    labelHalo: p.canvas,
    textPrimary: p.textPrimary,
    textSecondary: p.textSecondary,
    handle: p.accent,
    handleRing: p.surface,
    emptyHint: p.textTertiary,
  );

  /// 画布底色。和左栏最深处同一级：白板是一块「凹陷的工作台」。
  final Color background;

  /// 主格线（标尺上写了数字的那一条）。**没有次格**——一格就是相邻两个
  /// 刻度之间的距离，格子里不再切小格。
  final Color gridMajor;

  /// 世界原点的十字（x = 0 / y = 0 两条）。
  final Color axis;

  /// 标尺带的底色。用画布色，内容滚到下面就被截断。
  final Color rulerBackground;

  /// 标尺上的刻度数字。
  final Color rulerText;

  /// 标尺上的小刻度线。
  final Color rulerTick;

  /// 标尺带内侧那根收边线。
  final Color rulerEdge;

  /// 卡片底色：中性半透明面。颜色不进这里。
  final Color cardFill;

  /// 分组框的描边。
  final Color groupOutline;

  final Color accent;
  final Color accentSoft;

  /// 框选框内部。
  final Color selectionFill;

  /// 框选框虚线。
  final Color selectionOutline;

  final Color edge;
  final Color edgeSelected;
  final Color edgeLabel;

  /// 连线标签背后的画布色描边，让字压在线上也读得清。
  final Color labelHalo;

  final Color textPrimary;
  final Color textSecondary;

  /// 缩放手柄的圆点与它的描边。
  final Color handle;
  final Color handleRing;

  /// 空板提示文字。
  final Color emptyHint;
}

// ---------------------------------------------------------------- 网格刻度

/// 主格步长的候选阶梯（世界单位）。
///
/// 只走 1 / 2 / 5 三个系数，标尺上的数字才会是 100、200、500 这种整数，
/// 不会出现 137 这种读不出量级的刻度。
const List<double> canvasGridLadder = <double>[
  10,
  20,
  50,
  100,
  200,
  500,
  1000,
  2000,
  5000,
  10000,
  20000,
  50000,
  100000,
  200000,
  500000,
  1000000,
  2000000,
  5000000,
  10000000,
];

/// 主格在屏幕上的最小步长。低于它就把阶梯往上跳一档。
///
/// 64px 是「一眼能数清格子」的下限；再密下去网格就从纹理变成灰雾了。
const double canvasGridMinScreenStep = 64;

/// 主格（写数字的那一层）的世界步长。
///
/// 跟着缩放走阶梯，而不是把同一套间距画得越来越密：缩小时 100 → 200 →
/// 500，放大时 100 → 50 → 20。所以**任何缩放下刻度都是整数**，
/// 也不会出现「缩到 8% 要点上百万个点」这种事。
double canvasGridMajorStep(double zoom) {
  final double z = zoom > 0 ? zoom : 1;
  for (final double step in canvasGridLadder) {
    if (step * z >= canvasGridMinScreenStep) return step;
  }
  return canvasGridLadder.last;
}

/// 上边标尺带的高度（屏幕像素，不跟着缩放变）。
///
/// 数字是「刻在线中间」的，所以这一条只放得下一行字。
const double canvasRulerThickness = 20;

/// 左边标尺带的宽度。
///
/// 比上边那条宽：左边的数字要靠右对齐摆进带子里，而 `-2000` 这种五位数
/// 在 10px 字号下要 26px，20px 的带子装不下，字就会跑到画布上。
const double canvasRulerSideWidth = 32;

/// 标尺上写什么。
///
/// 阶梯里的步长都是整数，所以绝大多数时候就是整数的字符串；留一位小数
/// 只是为了防止以后有人把阶梯改成 2.5 这类值。判整数带 1e-6 的容差——
/// `k * major` 在 k 很大时会算出 `999.9999999999999` 这种值。
String canvasRulerLabel(double value) {
  final double rounded = value.roundToDouble();
  if ((value - rounded).abs() < 1e-6) return rounded.round().toString();
  return value.toStringAsFixed(1);
}

// ------------------------------------------------------------------ 空卡片

/// 空文字卡片正中的那三个点。
///
/// **这三个点就是这张卡的内容**，不是装饰。所以它的宽度要拿来量：
/// 空卡片的宽 = 这串点的宽 + 两边内边距，和「打完字就贴合文字」是同一套
/// 算法，只不过现在的内容恰好是三个点。量别的东西（比如量一个空格）都会
/// 让卡片和点之间空出一块。
const String canvasEmptyDots = '•••';

/// 那三个点的排版。画笔和尺寸拟合**必须共用这一份**，否则量出来的宽度和
/// 画出来的宽度差一点点，右边就会多一条空。
///
/// `height: 1` 是刻意的：点是小圆点，不需要正文那 1.6 的行高撑着；卡片
/// 本身的高度另按一行正文算（见 `_fitTextNode`），所以两者互不影响。
///
/// [scale] 是节点的字号倍率，字距也要跟着放大，否则大卡片上的三个点会挤成
/// 一小撮。
TextStyle canvasEmptyDotsStyle({Color? color, double scale = 1}) => TextStyle(
  fontSize: AppText.ui * scale,
  height: 1,
  letterSpacing: 1 * scale,
  color: color,
  fontFamily: AppFonts.ui,
  fontFamilyFallback: AppFonts.uiFallback,
);

// ------------------------------------------------------------------ 浮层

/// 详细信息面板右下角那个拖拽握把的边长（屏幕像素）。
const double canvasDetailsGripSide = 18;

/// 面板能被拖到的尺寸范围。
///
/// 下限刚好放得下一列输入框，再窄标签就要换行；上限只是防止把面板拖成整块
/// 屏幕——它是个子窗口，不是主界面。
const double canvasDetailsMinWidth = 240;
const double canvasDetailsMaxWidth = 620;
const double canvasDetailsMinHeight = 220;
const double canvasDetailsMaxHeight = 720;

/// `Ctrl+=` / `Ctrl+-` 按一下，字号乘多少。
///
/// 1.25 是「按三下看得见、按四下翻倍」的节奏。1.1 太钝了——按半天看不出
/// 变化，用户会以为快捷键没生效。
const double canvasResizeStep = 1.25;

/// 贴合文字时，宽度额外留的余量（世界像素）。
///
/// 不留的话，卡片宽度会**正好等于**文字宽度——也就是正好落在折行的临界点上。
/// 这时任何一个亚像素的差（字形步进的浮点累加、输入框那边少排 2.6px 的光标
/// 余量）都会让最后一行多折一次，于是「不编辑时一行、一编辑变两行」。
/// 1px 看不出来，但足够把临界点推开。
const double canvasTextFitSlack = 1;

/// 按 [step] 排出落在 `[0, extent]` 里的网格线的屏幕坐标。
///
/// [origin] 是**世界原点**在屏幕上的位置（x 或 y 分量）。Dart 的 `%` 对正
/// 除数恒返回非负数，所以负坐标平移过来也不会漏掉第一条线。
List<double> canvasGridLineOffsets(double origin, double step, double extent) {
  final List<double> out = <double>[];
  // 屏幕步长小于 1px 时画出来就是一整片实心，直接不画。
  if (step < 1 || extent <= 0) return out;
  double at = origin % step;
  while (at <= extent) {
    out.add(at);
    at += step;
  }
  return out;
}

// ------------------------------------------------------------------ 卡片配色

/// JSON Canvas 的预设色 → 项目色名。
///
/// 规范**故意不定义**这六个值具体是什么色，只规定了编号；所以这张表是
/// 我们自己定的。`"3"` 是黄、`"5"` 是青，这两条最容易记错。
///
/// `"2"`（橙）和 `"3"`（黄）都落到 `amber`：项目只有六个色名，没有独立的
/// 橙和黄。**存的是规范值**，所以读回来还是原来那个，信息没丢。
const Map<String, CellColorToken> _presetTokens = <String, CellColorToken>{
  '1': CellColorToken.red,
  '2': CellColorToken.amber,
  '3': CellColorToken.amber,
  '4': CellColorToken.green,
  '5': CellColorToken.blue,
  '6': CellColorToken.purple,
};

/// 换色菜单里的六颗色。第一颗是「不设色」。
///
/// 故意不放 `"3"`：它和 `"2"` 在界面上是同一个色，摆两个一模一样的圆点
/// 只会让人以为点错了。别人文件里写的 `"3"` 照样能读、能显示、能存回去。
const List<String?> canvasColorChoices = <String?>[
  null,
  '1',
  '2',
  '4',
  '5',
  '6',
];

/// 把节点上的 `color` 字段解析成可以画的颜色。
///
/// 认两种写法：`"1"`–`"6"` 的预设编号，和 `#RRGGBB` / `#RRGGBBAA` 的字面值。
/// 认不出来就返回 null（= 默认色），不让一个手滑的颜色把整张卡片画没。
CellColor? canvasCellColor(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  if (!raw.startsWith('#')) {
    final CellColorToken? token = _presetTokens[raw];
    return token == null ? null : CellColor.token(token);
  }
  final String hex = raw.substring(1);
  if (hex.length != 6 && hex.length != 8) return null;
  final int? value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  // 规范写的是 #RRGGBBAA，Flutter 要的是 0xAARRGGBB：把尾巴挪到头上。
  final int argb = hex.length == 6
      ? 0xFF000000 | value
      : ((value & 0xFF) << 24) | (value >> 8);
  return CellColor.custom(argb);
}

/// 卡片文字色：设了色就用那个色的墨，没设就是正文色。
Color canvasCardInk(AppPalette p, CellColor? color) =>
    color == null ? p.textPrimary : tableInkColor(p, color);

/// 卡片描边：没设色是一根淡白线（graphif 那种「纸边」），设了色就是那个色。
///
/// 颜色只在这里和文字上出现——底色永远是 [CanvasStyle.cardFill]，
/// 所以一屏摆二十张卡片也不会变成一块调色盘。
Color canvasCardBorder(AppPalette p, CellColor? color) => color == null
    ? p.textPrimary.withValues(alpha: 0.30)
    : tableInkColor(p, color).withValues(alpha: 0.80);

/// 分组标题色。分组没有底色，标题就是它的「脸」。
Color canvasGroupInk(AppPalette p) => p.textPrimary.withValues(alpha: 0.90);

/// 换色菜单里的色块：这里要的是**实心**的色，和卡片身上的半透明底无关。
Color canvasSwatchFill(AppPalette p, CellColor? color) =>
    color == null ? p.surfaceRaised : tableFillColor(p, color);
