import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/utils/note_graph.dart';
import 'graph_physics.dart';
import 'graph_style.dart';

/// 一帧要画的所有东西。
///
/// 单独一个不可变对象，是为了让 [GraphPainter.shouldRepaint] 有个明确的比较
/// 对象，也让「画什么」和「怎么画」分开——测试可以构造它而不起一个应用。
@immutable
class GraphPaintData {
  const GraphPaintData({
    required this.graph,
    required this.layout,
    required this.radii,
    required this.lit,
    required this.focus,
    required this.currentId,
    required this.showLabels,
    required this.arrows,
    required this.style,
    required this.folderColors,
    required this.scale,
    required this.offset,
    required this.textScaler,
  });

  final NoteGraph graph;
  final GraphLayout layout;

  /// 已经乘过「节点大小」滑块的半径，按节点下标。
  final Float64List radii;

  /// 通过筛选的节点。false 的淡到 16%，不是删掉。
  final List<bool> lit;

  /// 鼠标悬停或选中的节点；`null` 表示没有焦点。
  final int? focus;

  /// 当前笔记的 id——它常驻一圈淡环。
  final String? currentId;

  final bool showLabels;
  final bool arrows;
  final GraphStyle style;
  final Map<String, Color> folderColors;

  /// 视口变换。
  final double scale;
  final Offset offset;

  final TextScaler textScaler;
}

/// 图谱画布。
///
/// 三遍画完：连线（按三种状态各拼一条 Path）→ 节点 → 标签。连线不用逐条
/// `drawLine`，是为了把 100 条线的 draw call 压成 3 次；标签用缓存好的
/// [TextPainter]，否则每帧重新排版三百个短句会直接把帧率吃掉。
class GraphPainter extends CustomPainter {
  GraphPainter({
    required this.data,
    required this.labels,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GraphPaintData data;
  final GraphLabelCache labels;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);

    canvas.save();
    canvas.translate(data.offset.dx, data.offset.dy);
    canvas.scale(data.scale);
    _paintEdges(canvas);
    _paintNodes(canvas);
    if (data.showLabels) _paintLabels(canvas);
    canvas.restore();
  }

  void _paintBackground(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    // 与设计稿一致：光源在画布上方偏外，中间偏深，四周最深。
    final Offset center = Offset(size.width * 0.5, -size.height * 0.1);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          math.max(size.width, size.height) * 1.3,
          <Color>[
            data.style.canvasTop,
            Color.lerp(data.style.canvasTop, data.style.canvasBottom, 0.6)!,
            data.style.canvasBottom,
          ],
          <double>[0, 0.62, 1],
        ),
    );
  }

  // ------------------------------------------------------------------ 连线

  void _paintEdges(Canvas canvas) {
    final NoteGraph g = data.graph;
    final int? focus = data.focus;
    final GraphNode? center = focus == null ? null : g.nodes[focus];
    final Set<int> related = <int>{
      if (center != null) ...center.neighbours,
    };

    final Path plain = Path();
    final Path lit = Path();
    final Path hot = Path();
    final Path dim = Path();
    final Path arrows = Path();

    for (final GraphEdge e in g.edges) {
      final bool ok = data.lit[e.a] && data.lit[e.b];
      final bool touchesFocus =
          center != null && (e.a == focus || e.b == focus);
      final bool touchesNeighbour =
          center != null && (related.contains(e.a) || related.contains(e.b));

      final double ax = data.layout.x[e.a];
      final double ay = data.layout.y[e.a];
      final double bx = data.layout.x[e.b];
      final double by = data.layout.y[e.b];

      if (!ok) {
        dim
          ..moveTo(ax, ay)
          ..lineTo(bx, by);
        continue;
      }
      if (touchesFocus) {
        hot
          ..moveTo(ax, ay)
          ..lineTo(bx, by);
      } else if (center != null && touchesNeighbour) {
        lit
          ..moveTo(ax, ay)
          ..lineTo(bx, by);
      } else {
        plain
          ..moveTo(ax, ay)
          ..lineTo(bx, by);
      }

      if (data.arrows && (center == null || touchesFocus || touchesNeighbour)) {
        _addArrow(arrows, ax, ay, bx, by, data.radii[e.b]);
      }
    }

    final double width = 1 / math.max(data.scale, 0.35);
    canvas
      ..drawPath(
        dim,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = data.style.edgeDim,
      )
      ..drawPath(
        plain,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = data.style.edge,
      )
      ..drawPath(
        lit,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = data.style.edgeLit,
      )
      ..drawPath(
        hot,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 1.4
          ..color = data.style.edgeFocus,
      );
    if (data.arrows) {
      canvas.drawPath(arrows, Paint()..color = data.style.arrow);
    }
  }

  /// 把箭头三角拼进同一条 Path——一百条边也只多一次 draw call。
  void _addArrow(Path path, double ax, double ay, double bx, double by, double r) {
    final double dx = bx - ax;
    final double dy = by - ay;
    final double d = math.sqrt(dx * dx + dy * dy);
    if (d < r + 8) return;
    final double ux = dx / d;
    final double uy = dy / d;
    final double tipX = bx - ux * (r + 2);
    final double tipY = by - uy * (r + 2);
    const double length = 6;
    const double half = 2.6;
    final double baseX = tipX - ux * length;
    final double baseY = tipY - uy * length;
    path
      ..moveTo(tipX, tipY)
      ..lineTo(baseX - uy * half, baseY + ux * half)
      ..lineTo(baseX + uy * half, baseY - ux * half)
      ..close();
  }

  // ------------------------------------------------------------------ 节点

  void _paintNodes(Canvas canvas) {
    final NoteGraph g = data.graph;
    final int? focus = data.focus;
    final Paint fill = Paint();
    final Paint ring = Paint()..style = PaintingStyle.stroke;

    for (final GraphNode node in g.nodes) {
      final int i = node.index;
      final double x = data.layout.x[i];
      final double y = data.layout.y[i];
      final double r = data.radii[i];
      final bool on = data.lit[i];
      final bool isFocus = i == focus;
      final bool isNeighbour =
          focus != null && g.nodes[focus].neighbours.contains(i);

      fill.color = (data.folderColors[node.folder] ?? data.style.node)
          .withValues(alpha: on ? 1 : 0.16);
      canvas.drawCircle(Offset(x, y), r, fill);

      final bool isCurrent = node.id == data.currentId;
      if (isCurrent || isFocus || isNeighbour) {
        final double alpha = isFocus ? 0.95 : (isCurrent ? 0.55 : 0.32);
        ring
          ..color = data.style.ring.withValues(alpha: alpha)
          ..strokeWidth = (isFocus ? 1.8 : 1.2) / math.max(data.scale, 0.5);
        canvas.drawCircle(Offset(x, y), r + 3.5, ring);
      }
    }
  }

  // ------------------------------------------------------------------ 标签

  void _paintLabels(Canvas canvas) {
    final NoteGraph g = data.graph;
    for (final GraphNode node in g.nodes) {
      final int i = node.index;
      final bool on = data.lit[i];
      final TextPainter fill = labels.painter(
        node.title,
        color: data.style.label.withValues(alpha: on ? 1 : 0.14),
        halo: null,
        scaler: data.textScaler,
      );

      final double x = data.layout.x[i] + data.radii[i] + 5;
      final double y = data.layout.y[i] - fill.height / 2;
      if (on) {
        labels
            .painter(
              node.title,
              color: data.style.label,
              halo: data.style.labelHalo,
              scaler: data.textScaler,
            )
            .paint(canvas, Offset(x, y));
      }
      fill.paint(canvas, Offset(x, y));
    }
  }

  @override
  bool shouldRepaint(GraphPainter old) =>
      !identical(old.data, data) || old.labels != labels;
}

/// 标签的排版缓存。
///
/// 一帧里每个可见节点都要一段文字。三百个节点每帧重新 layout 一遍，光是
/// 断行就把 16ms 用光了——所以按文字缓存，只在字号/缩放变化时整体失效。
class GraphLabelCache {
  final Map<String, TextPainter> _painters = <String, TextPainter>{};
  TextScaler? _scaler;

  int get length => _painters.length;

  void clear() => _painters.clear();

  /// 取一段文字的 [TextPainter]。[halo] 非空时返回带描边的那一份
  /// （先画描边、再画填充，压在连线上也读得清）。
  TextPainter painter(
    String text, {
    required Color color,
    required Color? halo,
    required TextScaler scaler,
  }) {
    if (_scaler != scaler) {
      _scaler = scaler;
      clear();
    }
    // 颜色进 key：同一个标题有「亮着」和「被筛掉」两种颜色，不能共用一份。
    final String key = '$text\u0000$color\u0000$halo';
    final TextPainter? hit = _painters[key];
    if (hit != null) return hit;

    final TextStyle style = TextStyle(
      fontSize: AppText.caption,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      height: 1.2,
      color: halo == null ? color : null,
      foreground: halo == null
          ? null
          : (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.6
              ..strokeJoin = StrokeJoin.round
              ..color = halo),
    );
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    _painters[key] = painter;
    return painter;
  }
}
