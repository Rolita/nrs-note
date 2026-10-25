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

/// 光点用的时钟（秒）。
///
/// 不放进 [GraphPaintData]：那是 `build` 时拍的一张快照，而光点要**每帧**
/// 读最新值。放这里，painter 每帧现取，不用为了一个 double 重建整份数据。
class GraphClock {
  double seconds = 0;
}

/// 一个文件夹在图上的质心与半径。
class _Cluster {
  double x = 0;
  double y = 0;
  int count = 0;

  /// 离质心最远的那个成员的距离（含半径）。底雾和簇名都按它定位。
  double radius = 0;
}

/// 图谱画布。
///
/// 五遍画完：底雾 → 连线 → 节点 → 标签 → 簇名。
///
/// 连线是**逐条**画的，不是拼成一条 Path：每条边要一个「起点色 → 终点色」的
/// 线性渐变，方向就写在线里。50 条边是 50 次 drawLine，桌面端无所谓；
/// 超过 [beamGradientLimit] 条才退回拼 Path 的单色画法，否则大库会被
/// 每帧几百个 `Gradient.linear` 拖住。
class GraphPainter extends CustomPainter {
  GraphPainter({
    required this.data,
    required this.labels,
    required this.clock,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GraphPaintData data;
  final GraphLabelCache labels;
  final GraphClock clock;

  /// 超过这个边数就不逐条上渐变了。
  static const int beamGradientLimit = 400;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBackground(canvas, size);

    canvas.save();
    canvas.translate(data.offset.dx, data.offset.dy);
    canvas.scale(data.scale);

    final Map<String, _Cluster> clusters = _clusters();
    _paintMist(canvas, clusters);
    _paintEdges(canvas);
    _paintNodes(canvas);
    if (data.showLabels) _paintLabels(canvas);
    _paintClusterChips(canvas, clusters);

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

  // ------------------------------------------------------------------ 簇

  /// 每个文件夹的质心、半径、篇数。
  ///
  /// 两遍扫：先求质心，再求「离质心最远多远」。O(n)，每帧一次。
  Map<String, _Cluster> _clusters() {
    final Map<String, _Cluster> out = <String, _Cluster>{};
    for (final GraphNode n in data.graph.nodes) {
      final _Cluster c = out.putIfAbsent(n.folder, () => _Cluster());
      c.x += data.layout.x[n.index];
      c.y += data.layout.y[n.index];
      c.count++;
    }
    for (final _Cluster c in out.values) {
      c.x /= c.count;
      c.y /= c.count;
    }
    for (final GraphNode n in data.graph.nodes) {
      final _Cluster c = out[n.folder]!;
      final double dx = data.layout.x[n.index] - c.x;
      final double dy = data.layout.y[n.index] - c.y;
      final double d = math.sqrt(dx * dx + dy * dy) + data.radii[n.index];
      if (d > c.radius) c.radius = d;
    }
    return out;
  }

  /// 每个文件夹铺一团同色底雾。簇是靠这个「托」出来的，不是靠画框。
  void _paintMist(Canvas canvas, Map<String, _Cluster> clusters) {
    final Paint paint = Paint();
    for (final MapEntry<String, _Cluster> e in clusters.entries) {
      final _Cluster c = e.value;
      if (c.count < 2) continue;
      final Color base = data.folderColors[e.key] ?? data.style.node;
      final double r = c.radius + 46;
      if (r <= 1) continue;
      paint.shader = ui.Gradient.radial(
        Offset(c.x, c.y),
        r,
        <Color>[
          base.withValues(alpha: data.style.mistAlpha),
          base.withValues(alpha: data.style.mistAlpha * 0.42),
          base.withValues(alpha: 0),
        ],
        <double>[0, 0.55, 1],
      );
      canvas.drawCircle(Offset(c.x, c.y), r, paint);
    }
    paint.shader = null;
  }

  // ------------------------------------------------------------------ 连线

  Color _nodeColor(int i) =>
      data.folderColors[data.graph.nodes[i].folder] ?? data.style.node;

  void _paintEdges(Canvas canvas) {
    final NoteGraph g = data.graph;
    final int? focus = data.focus;
    final GraphNode? center = focus == null ? null : g.nodes[focus];
    final Set<int> related = <int>{
      if (center != null) ...center.neighbours,
    };

    final double width = 1 / math.max(data.scale, 0.35);
    final bool gradient = g.edges.length <= beamGradientLimit;

    // 被筛掉的边先画，而且一次画完：它们必须待在亮线**下面**，
    // 否则一条 1.4% 的灰线会横穿在焦点边上。
    final Path dim = Path();
    for (final GraphEdge e in g.edges) {
      if (data.lit[e.a] && data.lit[e.b]) continue;
      dim
        ..moveTo(data.layout.x[e.a], data.layout.y[e.a])
        ..lineTo(data.layout.x[e.b], data.layout.y[e.b]);
    }
    canvas.drawPath(
      dim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = data.style.edgeDim,
    );

    final Path flat = Path();
    final Path arrows = Path();

    final Paint beam = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width
      ..color = const Color(0xFFFFFFFF);
    final Paint glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width * 3.4
      ..color = data.style.beamGlow;

    for (final GraphEdge e in g.edges) {
      if (!data.lit[e.a] || !data.lit[e.b]) continue;

      final Offset pa = Offset(data.layout.x[e.a], data.layout.y[e.a]);
      final Offset pb = Offset(data.layout.x[e.b], data.layout.y[e.b]);

      final bool hot = center != null && (e.a == focus || e.b == focus);
      final bool near =
          center != null && (related.contains(e.a) || related.contains(e.b));

      // 方向：`from` 是正文里写链接的那一头。双向边没有方向，按 a→b 画，
      // 只是不画箭头——两个方向都成立，画哪个都是撒谎。
      final bool forward = e.from == null || e.from == e.a;
      final int src = forward ? e.a : e.b;
      final int dst = forward ? e.b : e.a;
      final Offset from = forward ? pa : pb;
      final Offset to = forward ? pb : pa;

      final double aFrom = _clamp(
        hot ? 0.72 : (near ? data.style.beamFrom * 1.5 : data.style.beamFrom),
      );
      final double aTo = _clamp(
        hot ? 0.34 : (near ? data.style.beamTo * 1.6 : data.style.beamTo),
      );

      if (hot) canvas.drawLine(from, to, glow);

      if (gradient) {
        beam.shader = ui.Gradient.linear(from, to, <Color>[
          _nodeColor(src).withValues(alpha: aFrom),
          _nodeColor(dst).withValues(alpha: aTo),
        ]);
        canvas.drawLine(from, to, beam);
      } else {
        flat
          ..moveTo(from.dx, from.dy)
          ..lineTo(to.dx, to.dy);
      }

      // 箭头只在焦点边上出现。
      //
      // 「光带」的主张是**方向不用箭头解释**——一头亮一头暗已经说清楚了，
      // 常显的箭头只会在几十条线上堆成一片三角。悬停时才补上箭头，是给
      // 「我正在看这一条」加一句确证。
      if (data.arrows && hot && !e.isBidirectional) {
        _addArrow(arrows, from, to, data.radii[dst]);
      }
    }

    beam.shader = null;

    if (!gradient) {
      canvas.drawPath(
        flat,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = data.style.edge,
      );
    }
    if (data.arrows) {
      canvas.drawPath(arrows, Paint()..color = data.style.arrow);
    }

    _paintParticles(canvas);
  }

  /// 出链上跑的光点——「光带」这个说法的由来。
  ///
  /// 只跑**出链**：入链的光点会从目标流回焦点，看着像「别人在引用我」，
  /// 方向刚好反了。双向边没有方向，不跑。
  ///
  /// 画在连线之后、节点之前，所以光点会被节点挡住一部分——那是想要的，
  /// 它看起来是从节点里钻出来的。
  void _paintParticles(Canvas canvas) {
    final int? focus = data.focus;
    if (focus == null) return;

    final Paint paint = Paint();
    for (final GraphEdge e in data.graph.edges) {
      if (e.from != focus || e.isBidirectional) continue;
      if (!data.lit[e.a] || !data.lit[e.b]) continue;

      final Offset pa = Offset(data.layout.x[e.a], data.layout.y[e.a]);
      final Offset pb = Offset(data.layout.x[e.b], data.layout.y[e.b]);
      final bool forward = e.from == e.a;
      final Offset from = forward ? pa : pb;
      final Offset to = forward ? pb : pa;

      // 相位按边算：几条线才不会同时在同一位置亮，看着像一串珠子。
      final double phase = ((e.a * 31 + e.b * 17) % 100) / 100;
      final double t = (clock.seconds / 1.5 + phase) % 1.0;
      final Offset at = Offset.lerp(from, to, t)!;

      paint.shader = ui.Gradient.radial(at, 5.5, <Color>[
        data.style.ring,
        data.style.beamGlow.withValues(alpha: 0.55),
        data.style.beamGlow.withValues(alpha: 0),
      ], <double>[0, 0.35, 1]);
      canvas.drawCircle(at, 5.5, paint);
    }
    paint.shader = null;
  }

  static double _clamp(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  /// 把箭头三角拼进同一条 Path——一百条边也只多一次 draw call。
  void _addArrow(Path path, Offset from, Offset to, double r) {
    final double dx = to.dx - from.dx;
    final double dy = to.dy - from.dy;
    final double d = math.sqrt(dx * dx + dy * dy);
    if (d < r + 8) return;
    final double ux = dx / d;
    final double uy = dy / d;
    final double tipX = to.dx - ux * (r + 2);
    final double tipY = to.dy - uy * (r + 2);
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

      fill.color = _nodeColor(i).withValues(alpha: on ? 1 : 0.16);
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

  /// 标签的浓度：枢纽写实、叶子写虚。
  ///
  /// 三百篇笔记把标签全写实，整张图会糊成一片字。度数高的节点才是读者
  /// 找路的锚点，先让它们清楚。
  double _labelAlpha(
    GraphNode node, {
    required bool isFocus,
    required bool isNear,
  }) {
    if (isFocus) return 1;

    final int? focus = data.focus;
    if (focus != null) {
      if (isNear) return 0.86;
      // 整簇是亮的，所以同文件夹的也写
      if (node.folder == data.graph.nodes[focus].folder) return 0.9;
      return 0;
    }

    if (node.globalDegree >= 3) return 1;
    if (node.globalDegree >= 1) return 0.55;
    return 0.32;
  }

  void _paintLabels(Canvas canvas) {
    final NoteGraph g = data.graph;
    final int? focus = data.focus;
    final Set<int> related = <int>{
      if (focus != null) ...g.nodes[focus].neighbours,
    };

    for (final GraphNode node in g.nodes) {
      final int i = node.index;
      final bool on = data.lit[i];
      final double alpha = _labelAlpha(
        node,
        isFocus: i == focus,
        isNear: related.contains(i),
      );
      if (alpha <= 0.02) continue;

      final double x = data.layout.x[i] + data.radii[i] + 5;
      // 描边那遍先画：压在连线上也读得清。淡掉的标签不描边，否则一圈
      // 深色描边会让「被筛掉」的字反而更抢眼。
      if (on) {
        final TextPainter halo = labels.painter(
          node.title,
          color: data.style.label,
          halo: data.style.labelHalo,
          scaler: data.textScaler,
        );
        halo.paint(canvas, Offset(x, data.layout.y[i] - halo.height / 2));
      }

      final TextPainter fill = labels.painter(
        node.title,
        color: data.style.label.withValues(alpha: on ? alpha : alpha * 0.14),
        halo: null,
        scaler: data.textScaler,
      );
      fill.paint(canvas, Offset(x, data.layout.y[i] - fill.height / 2));
    }
  }

  // ------------------------------------------------------------------ 簇名

  /// 簇名挂在**雾的正上方**，做成一个带色点的小胶囊。
  ///
  /// 不挂在「簇内最上面那个节点」上：邻簇的节点会把它顶开，名字就飘到
  /// 别人家里去了。胶囊底是必需的——簇名经常压在别人的节点上。
  void _paintClusterChips(Canvas canvas, Map<String, _Cluster> clusters) {
    if (!data.showLabels) return;

    final Paint chip = Paint()..color = data.style.chip;
    final Paint edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 / math.max(data.scale, 0.5)
      ..color = data.style.chipEdge;
    final Paint dot = Paint();

    for (final MapEntry<String, _Cluster> e in clusters.entries) {
      final _Cluster c = e.value;
      if (c.count < 2) continue;

      final String label = e.key.isEmpty ? '根目录' : e.key;
      final String text = '$label · ${c.count}';
      final TextPainter tp = labels.painter(
        text,
        color: data.style.label.withValues(alpha: 0.82),
        halo: null,
        scaler: data.textScaler,
        fontSize: AppText.caption - 0.5,
      );

      final double padX = 9;
      final double gap = 9;
      final double h = tp.height + 6;
      final double w = tp.width + padX * 2 + gap;
      final double top = c.y - c.radius - 14 - h / 2;
      final Rect rect = Rect.fromLTWH(c.x - w / 2, top, w, h);
      final RRect rrect = RRect.fromRectAndRadius(rect, Radius.circular(h / 2));

      canvas.drawRRect(rrect, chip);
      canvas.drawRRect(rrect, edge);

      final Color base = data.folderColors[e.key] ?? data.style.node;
      dot.color = base.withValues(alpha: 0.95);
      canvas.drawCircle(
        Offset(rect.left + padX, rect.center.dy),
        2.3 / math.max(data.scale, 0.5),
        dot,
      );

      tp.paint(canvas, Offset(rect.left + padX + gap, rect.center.dy - tp.height / 2));
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
    double fontSize = AppText.caption,
  }) {
    if (_scaler != scaler) {
      _scaler = scaler;
      clear();
    }
    // 颜色和字号都进 key：同一个标题有「亮着」「被筛掉」两种颜色，
    // 簇名又比节点标签小一号，都不能共用一份。
    final String key = '$text\u0000$color\u0000$halo\u0000$fontSize';
    final TextPainter? hit = _painters[key];
    if (hit != null) return hit;

    final TextStyle style = TextStyle(
      fontSize: fontSize,
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
