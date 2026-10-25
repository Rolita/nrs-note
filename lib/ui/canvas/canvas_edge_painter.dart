import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/table_colors.dart';
import '../../core/utils/canvas_document.dart';
import '../../core/utils/canvas_geometry.dart';
import '../../core/utils/table_model.dart' show CellColor;
import 'canvas_style.dart';

/// 一条边画出来要的全部东西。
///
/// 几何在 build 里一次算好（屏幕坐标），画笔只负责描——画笔里再算一次，
/// 就会出现「画的位置」和「点中的位置」两套公式。
class CanvasEdgeVisual {
  const CanvasEdgeVisual({
    required this.edge,
    required this.geometry,
    required this.selected,
  });

  final CanvasEdge edge;

  /// 屏幕坐标里的三次贝塞尔。
  final CanvasEdgeGeometry geometry;

  final bool selected;
}

/// 所有连线。
///
/// 连线画在卡片**下面**：白板上的主体是内容，线是内容之间的关系。线压在
/// 卡片上会让每一张卡片看起来都被划了一道。
class CanvasEdgePainter extends CustomPainter {
  const CanvasEdgePainter({
    required this.edges,
    required this.palette,
    required this.preview,
    required this.previewColor,
    required this.labelHalo,
  });

  final List<CanvasEdgeVisual> edges;
  final AppPalette palette;

  /// 从圆点拖出来的那一条（还没落地的）。null = 没有。
  final CanvasEdgeGeometry? preview;

  final Color previewColor;

  /// 标签背后的画布色，让字压在线上也读得清。
  final Color labelHalo;

  @override
  void paint(Canvas canvas, Size size) {
    for (final CanvasEdgeVisual visual in edges) {
      _paintEdge(canvas, visual);
    }
    final CanvasEdgeGeometry? ghost = preview;
    if (ghost != null) {
      _paintCurve(
        canvas,
        ghost,
        Paint()
          ..color = previewColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
        arrow: true,
      );
    }
  }

  void _paintEdge(Canvas canvas, CanvasEdgeVisual visual) {
    final CanvasEdge edge = visual.edge;
    final CellColor? color = canvasCellColor(edge.color);
    final Color line = color == null
        ? palette.outline
        : tableInkColor(palette, color);
    final Color stroke = visual.selected ? palette.accent : line;

    _paintCurve(
      canvas,
      visual.geometry,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = visual.selected ? 2.8 : 2
        ..strokeCap = StrokeCap.round,
      arrow: edge.toIsArrow,
      arrowAtStart: edge.fromIsArrow,
    );

    // 选中时两端各点一个圆点，好看出这条线连的是哪两张卡片。
    if (visual.selected) {
      final Paint dot = Paint()..color = palette.accent;
      canvas.drawCircle(visual.geometry.from, 4, dot);
      canvas.drawCircle(visual.geometry.to, 4, dot);
    }

    final String? label = edge.label;
    if (label == null || label.trim().isEmpty) return;
    _paintLabel(canvas, visual.geometry, label.trim(), stroke);
  }

  void _paintCurve(
    Canvas canvas,
    CanvasEdgeGeometry g,
    Paint paint, {
    required bool arrow,
    bool arrowAtStart = false,
  }) {
    final Path path = Path()
      ..moveTo(g.from.dx, g.from.dy)
      ..cubicTo(
        g.fromControl.dx,
        g.fromControl.dy,
        g.toControl.dx,
        g.toControl.dy,
        g.to.dx,
        g.to.dy,
      );
    canvas.drawPath(path, paint);

    final Paint fill = Paint()..color = paint.color;
    if (arrow) _arrow(canvas, g.to, g.tangentAt(1), fill);
    if (arrowAtStart) _arrow(canvas, g.from, -g.tangentAt(0), fill);
  }

  /// 箭头：一个沿切线方向的三角。边长固定 10px——跟着缩放走的话，
  /// 缩到 30% 时箭头会变成一个小疙瘩。
  void _arrow(Canvas canvas, Offset tip, Offset direction, Paint paint) {
    final double angle = math.atan2(direction.dy, direction.dx);
    const double length = 10;
    const double spread = 0.42;
    final Path path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(
        tip.dx - length * math.cos(angle - spread),
        tip.dy - length * math.sin(angle - spread),
      )
      ..lineTo(
        tip.dx - length * math.cos(angle + spread),
        tip.dy - length * math.sin(angle + spread),
      )
      ..close();
    canvas.drawPath(path, paint);
  }

  /// 标签压在线的中点上，背后描一圈画布色。
  ///
  /// 描边而不是垫一块底板：底板会盖住线，看起来像线断了一截。
  void _paintLabel(
    Canvas canvas,
    CanvasEdgeGeometry g,
    String text,
    Color color,
  ) {
    TextPainter layout(TextStyle style) => TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 220);

    final TextPainter halo = layout(
      TextStyle(
        fontSize: AppText.caption,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = labelHalo,
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
    );
    final TextPainter fill = layout(
      TextStyle(
        fontSize: AppText.caption,
        color: color,
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
    );

    final Offset center = g.pointAt(0.5);
    final Offset origin = Offset(
      center.dx - fill.width / 2,
      center.dy - fill.height / 2,
    );
    halo.paint(canvas, origin);
    fill.paint(canvas, origin);
    halo.dispose();
    fill.dispose();
  }

  @override
  bool shouldRepaint(CanvasEdgePainter old) =>
      !identical(old.edges, edges) ||
      old.preview != preview ||
      old.palette != palette;
}

/// 悬停卡片时四条边中点浮出来的小圆点：从这里拖出连线。
class CanvasConnectDotsPainter extends CustomPainter {
  const CanvasConnectDotsPainter({
    required this.rect,
    required this.viewport,
    required this.fill,
    required this.ring,
  });

  /// 悬停卡片的矩形（世界坐标）。null = 没有悬停，不画。
  final Rect? rect;
  final CanvasViewport viewport;
  final Color fill;
  final Color ring;

  /// 圆点的半径（屏幕像素）。命中测试用的是同一个值 + 2 的容差。
  static const double dotRadius = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? world = rect;
    if (world == null) return;
    final Rect screen = viewport.rectToScreen(world);
    if (screen.width < 20 || screen.height < 20) return;

    final Paint edge = Paint()
      ..color = ring
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final Paint dot = Paint()..color = fill;
    for (final CanvasSide side in CanvasSide.values) {
      final Offset at = anchorOf(screen, side);
      canvas.drawCircle(at, dotRadius, edge);
      canvas.drawCircle(at, dotRadius - 1.5, dot);
    }
  }

  @override
  bool shouldRepaint(CanvasConnectDotsPainter old) =>
      old.rect != rect || old.viewport != viewport;
}

/// 把一组边按当前视口算成可以画的形状。
List<CanvasEdgeVisual> buildEdgeVisuals({
  required CanvasDocument? document,
  required CanvasViewport viewport,
  required Set<String> selected,
}) {
  final CanvasDocument? doc = document;
  if (doc == null) return const <CanvasEdgeVisual>[];
  final List<CanvasEdgeVisual> out = <CanvasEdgeVisual>[];
  for (final CanvasEdge edge in doc.edges) {
    final CanvasNode? from = doc.nodeById(edge.fromNode);
    final CanvasNode? to = doc.nodeById(edge.toNode);
    if (from == null || to == null) continue;
    out.add(
      CanvasEdgeVisual(
        edge: edge,
        geometry: edgeGeometry(
          fromRect: viewport.rectToScreen(from.rect),
          toRect: viewport.rectToScreen(to.rect),
          fromSide: CanvasSide.parse(edge.fromSide),
          toSide: CanvasSide.parse(edge.toSide),
        ),
        selected: selected.contains(edge.id),
      ),
    );
  }
  return out;
}

/// 点在连线上的判定：贝塞尔近似成折线后的最近距离。
CanvasEdgeVisual? edgeAt(
  List<CanvasEdgeVisual> visuals,
  Offset point, {
  double tolerance = 6,
}) {
  CanvasEdgeVisual? best;
  double bestDistance = tolerance;
  for (final CanvasEdgeVisual visual in visuals) {
    final double d = visual.geometry.distanceTo(point);
    if (d <= bestDistance) {
      bestDistance = d;
      best = visual;
    }
  }
  return best;
}

/// 画布上那条从圆点拖出来的预览线。
CanvasEdgeGeometry connectPreview({
  required Rect fromRect,
  required CanvasSide side,
  required Offset cursor,
}) => edgeGeometry(
  fromRect: fromRect,
  toRect: Rect.fromCenter(center: cursor, width: 1, height: 1),
  fromSide: side,
);
