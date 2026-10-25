import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';

/// 白板的配色。
///
/// 和 `graph_style.dart` 同一个套路：把 [AppPalette] 里的一堆色解析成
/// 白板真正要用的那几个名字，画的时候不再回头看主题。
///
/// 两套主题的差别只有两处，都在这里消化掉：
///
/// * **点阵**。深色底上用亮点点、浅色底上用暗点点，靠的是 `textPrimary`
///   本来就跟着主题翻转；透明度不同（深色 8%、浅色 12%），因为浅色底
///   的对比度天生更弱，同样的 alpha 会看不见。
/// * **卡片底色**。深色主题 `surfaceRaised` 比画布亮一级（卡片浮起来），
///   浅色主题同理。所以直接取 `surfaceRaised` 就行，不用分主题写死。
class CanvasStyle {
  const CanvasStyle({
    required this.background,
    required this.gridDot,
    required this.gridDotStrong,
    required this.cardFill,
    required this.cardOutline,
    required this.cardShadow,
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

  factory CanvasStyle.of(AppPalette p) {
    final double dot = p.isDark ? 0.08 : 0.12;
    return CanvasStyle(
      background: p.canvas,
      gridDot: p.textPrimary.withValues(alpha: dot),
      // 间距翻倍时用更实一档，否则 40px 的大格看着比 20px 的小格还稀。
      gridDotStrong: p.textPrimary.withValues(alpha: dot * 1.7),
      cardFill: p.surfaceRaised,
      cardOutline: p.outline,
      cardShadow: p.shadow,
      accent: p.accent,
      accentSoft: p.accentSoft,
      selectionFill: p.accentSoft.withValues(alpha: 0.40),
      selectionOutline: p.accent.withValues(alpha: 0.70),
      edge: p.outline,
      edgeSelected: p.accent,
      edgeLabel: p.textSecondary,
      labelHalo: p.canvas,
      textPrimary: p.textPrimary,
      textSecondary: p.textSecondary,
      handle: p.accent,
      handleRing: p.surface,
      emptyHint: p.textTertiary,
    );
  }

  /// 画布底色。和左栏最深处同一级：白板是一块「凹陷的工作台」。
  final Color background;

  /// 点阵。20px 一格时用这个。
  final Color gridDot;

  /// 点阵。缩放到 200% 以上、间距翻倍时用这个。
  final Color gridDotStrong;

  final Color cardFill;
  final Color cardOutline;
  final Color cardShadow;

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

/// 点阵网格的间距（世界坐标）。
const double canvasGridSize = 20;

/// 缩到多小就彻底不画网格。
///
/// 0.35 对应屏幕上 7px 一格：再密下去就是一片灰雾，除了拖慢重绘没有用处。
const double canvasGridFadeOut = 0.35;

/// 缩到多大就把网格间距翻倍。
///
/// 200% 时 20px 已经是屏幕上 40px，不翻倍点会显得稀疏、像没对齐。
const double canvasGridCoarsen = 2.0;

/// 网格整体的透明度。
///
/// 从 [canvasGridFadeOut] 到它的 1.6 倍之间线性淡入，避免「唰一下」出现。
double canvasGridOpacity(double zoom) {
  const double start = canvasGridFadeOut;
  const double end = canvasGridFadeOut * 1.6;
  if (zoom <= start) return 0;
  if (zoom >= end) return 1;
  return (zoom - start) / (end - start);
}

/// 屏幕上实际的点阵间距（世界单位）。
///
/// 缩放到 [canvasGridCoarsen] 以上就翻倍。翻倍而不是画更多点，是因为
/// 网格的职责只是「让你看得出在拖多远」，不是刻度尺。
double canvasGridStep(double zoom) =>
    zoom >= canvasGridCoarsen ? canvasGridSize * 2 : canvasGridSize;
