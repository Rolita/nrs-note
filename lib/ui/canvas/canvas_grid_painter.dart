import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/utils/canvas_geometry.dart';
import 'canvas_style.dart';

/// 画布的点阵。
///
/// 为什么是点阵而不是方格线：白板上的内容是卡片和连线，方格线会和它们抢
/// 注意力；点阵退到背景里，只在拖动时提供「走了多远」的参照。
///
/// 点是在**屏幕坐标**里算的：把世界坐标的格点乘上 zoom 加上 offset，再只取
/// 落在视口里的那些。反过来（先按世界坐标铺满再整体变换）会画出屏幕外的
/// 几十万个点，缩放越小越慢。
class CanvasGridPainter extends CustomPainter {
  const CanvasGridPainter({required this.viewport, required this.style});

  final CanvasViewport viewport;
  final CanvasStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final double opacity = canvasGridOpacity(viewport.zoom);
    if (opacity <= 0) return;

    final double step = canvasGridStep(viewport.zoom);
    final double screenStep = step * viewport.zoom;
    // 一个点都不到 4px 一格时画出来只是噪点，不如不画。
    if (screenStep < 4) return;

    // Dart 的 `%` 对正除数返回非负值，负的 offset 也能拿到正确的起点。
    final double startX = viewport.offset.dx % screenStep;
    final double startY = viewport.offset.dy % screenStep;

    final Color dot = step == canvasGridSize
        ? style.gridDot
        : style.gridDotStrong;
    final Paint paint = Paint()
      ..color = dot.withValues(alpha: dot.a * opacity)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;

    final List<Offset> points = <Offset>[];
    for (double x = startX; x <= size.width; x += screenStep) {
      for (double y = startY; y <= size.height; y += screenStep) {
        points.add(Offset(x, y));
      }
    }
    if (points.isEmpty) return;
    canvas.drawPoints(ui.PointMode.points, points, paint);
  }

  @override
  bool shouldRepaint(CanvasGridPainter old) =>
      old.viewport != viewport || old.style != style;
}

/// 框选框：1px 虚线 + 一层很淡的填充。
///
/// 单独一个 painter，是为了让拖框时只重绘这一层——网格那一层几百上千个点
/// 不该跟着每帧重算。
class CanvasMarqueePainter extends CustomPainter {
  const CanvasMarqueePainter({required this.rect, required this.style});

  /// 屏幕坐标里的框。null 表示没在框选。
  final Rect? rect;
  final CanvasStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? r = rect;
    if (r == null || r.width < 1 || r.height < 1) return;

    canvas.drawRect(r, Paint()..color = style.selectionFill);

    final Paint stroke = Paint()
      ..color = style.selectionOutline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // 手写虚线：4px 实 3px 空。`dashPath` 在 dash 里，为一条虚线引一个包
    // 不值当。
    const double dash = 4;
    const double gap = 3;
    for (final (Offset a, Offset b) in <(Offset, Offset)>[
      (r.topLeft, r.topRight),
      (r.topRight, r.bottomRight),
      (r.bottomRight, r.bottomLeft),
      (r.bottomLeft, r.topLeft),
    ]) {
      final double length = (b - a).distance;
      if (length <= 0) continue;
      final Offset unit = (b - a) / length;
      for (double t = 0; t < length; t += dash + gap) {
        final double end = (t + dash).clamp(0, length);
        canvas.drawLine(a + unit * t, a + unit * end, stroke);
      }
    }
  }

  @override
  bool shouldRepaint(CanvasMarqueePainter old) =>
      old.rect != rect || old.style != style;
}
