import 'dart:math' as math;
import 'dart:typed_data';

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
    required this.selected,
    required this.arrows,
    required this.useFolderColors,
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

  /// 通过筛选的节点。false 的淡到 10%，不是删掉。
  final List<bool> lit;

  /// 鼠标悬停或选中的节点；`null` 表示没有焦点。
  final int? focus;

  /// 真正**选中**的节点（点下去的那个）。
  ///
  /// 和 [focus] 分开：悬停只是「看」，不该把节点染成强调色；只有点下去
  /// 才换色、才画环。设计稿里 `nodeColor` 也只认 `sel`。
  final int? selected;

  final bool arrows;

  /// 按文件夹着色。关掉时全图一个灰——Obsidian 的默认就是这个。
  final bool useFolderColors;

  final GraphStyle style;
  final Map<String, Color> folderColors;

  /// 视口变换。
  final double scale;
  final Offset offset;

  final TextScaler textScaler;
}

/// 图谱画布。
///
/// 三遍画完：连线 → 节点 → 标签。没有底雾、没有簇名、没有光晕——
/// 结构视图里每多一层装饰，读者就要多问一句「这个是什么」。
class GraphPainter extends CustomPainter {
  GraphPainter({
    required this.data,
    required this.labels,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final GraphPaintData data;
  final GraphLabelCache labels;

  /// 1 个**屏幕**像素折成世界坐标。
  ///
  /// 照设计稿 `1 / s * clamp(s, 0.85, 1.6)`：线宽基本不随缩放变，但放大时
  /// 会**稍微**粗一点点。完全不变粗的话，高倍下整张图会细得像掉了几根线。
  double get hairline =>
      _clampD(data.scale, 0.85, 1.6) / math.max(data.scale, 0.01);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = data.style.canvas,
    );

    canvas.save();
    canvas.translate(data.offset.dx, data.offset.dy);
    canvas.scale(data.scale);

    _paintEdges(canvas);
    _paintNodes(canvas);
    _paintLabels(canvas);

    canvas.restore();
  }

  // ------------------------------------------------------------------ 关系

  /// 每个节点和焦点是什么关系。
  ///
  /// 一次算好：连线和节点两遍都要用，各算各的就会在「谁算邻居」上走偏。
  Set<int> get _related => <int>{
    if (data.focus != null) ...data.graph.nodes[data.focus!].neighbours,
  };

  double _edgeAlpha(GraphEdge e, Set<int> related) {
    if (!data.lit[e.a] || !data.lit[e.b]) return GraphStyle.edgeDim;
    final int? focus = data.focus;
    if (focus == null) return GraphStyle.edgeBase;
    if (e.a == focus || e.b == focus) return GraphStyle.edgeFocus;
    if (related.contains(e.a) || related.contains(e.b)) {
      return GraphStyle.edgeNear;
    }
    return GraphStyle.edgeFar;
  }

  void _paintEdges(Canvas canvas) {
    final Set<int> related = _related;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = hairline;

    // 按亮度分档攒成几条 Path：一千条边也只有五档，五次 drawPath 就完了。
    // 一条一条 drawLine 的话，大库每帧就是上千次 draw call。
    final Map<double, Path> byLevel = <double, Path>{};
    for (final GraphEdge e in data.graph.edges) {
      final double a = _edgeAlpha(e, related);
      byLevel
          .putIfAbsent(a, () => Path())
          .moveTo(data.layout.x[e.a], data.layout.y[e.a]);
      byLevel[a]!.lineTo(data.layout.x[e.b], data.layout.y[e.b]);
    }
    for (final MapEntry<double, Path> e in byLevel.entries) {
      paint.color = data.style.edgeTint.withValues(alpha: e.key);
      canvas.drawPath(e.value, paint);
    }

    _paintArrows(canvas);
  }

  /// 箭头只在**焦点的出链**上出现。
  ///
  /// 常显的话，几十条线会堆成一片三角；只在焦点出链上画，才是在回答
  /// 「这一篇引用了谁」。互相链接没有方向，不画。
  void _paintArrows(Canvas canvas) {
    final int? focus = data.focus;
    if (!data.arrows || focus == null) return;

    final Path path = Path();
    final double size = 6 / _clampD(data.scale, 0.7, 1.6);
    for (final GraphEdge e in data.graph.edges) {
      if (e.isBidirectional || e.from != focus) continue;
      if (!data.lit[e.a] || !data.lit[e.b]) continue;

      final bool forward = e.from == e.a;
      final int src = forward ? e.a : e.b;
      final int dst = forward ? e.b : e.a;
      final Offset from = Offset(data.layout.x[src], data.layout.y[src]);
      final Offset to = Offset(data.layout.x[dst], data.layout.y[dst]);

      final double dx = to.dx - from.dx;
      final double dy = to.dy - from.dy;
      final double d = math.sqrt(dx * dx + dy * dy);
      if (d < data.radii[dst] + 8) continue;
      final double ux = dx / d;
      final double uy = dy / d;
      // 箭头尖停在目标节点边缘，不插进圆里
      final double tipX = to.dx - ux * (data.radii[dst] + 2);
      final double tipY = to.dy - uy * (data.radii[dst] + 2);
      final double half = size * 0.5;
      path
        ..moveTo(tipX, tipY)
        ..lineTo(tipX - ux * size + uy * half, tipY - uy * size - ux * half)
        ..lineTo(tipX - ux * size - uy * half, tipY - uy * size + ux * half)
        ..close();
    }
    canvas.drawPath(
      path,
      Paint()..color = data.style.edgeTint.withValues(alpha: 0.55),
    );
  }

  // ------------------------------------------------------------------ 节点

  Color _nodeColor(int i) {
    if (i == data.selected) return data.style.ring;
    if (!data.useFolderColors) return data.style.node;
    return data.folderColors[data.graph.nodes[i].folder] ?? data.style.node;
  }

  /// 画出来的半径：焦点那颗放大 22%（设计稿 `targetR = r * 1.22`）。
  ///
  /// 有个**屏幕下限**：世界半径再小，画出来也不低于 [minScreenRadius] 个
  /// 屏幕像素。几百上千篇的库铺满画布后缩放会很小，不设下限的话每颗点
  /// 只剩半个像素——整张图看上去就是一层灰，而不是「很多篇笔记」。
  double _visualRadius(int i) {
    final double world = math.max(
      data.radii[i],
      minScreenRadius / math.max(data.scale, 0.01),
    );
    return world * (i == data.focus ? 1.22 : 1);
  }

  /// 节点在屏幕上的最小半径。2.2 是「还能看出是个圆」的下限。
  static const double minScreenRadius = 2.2;

  double _nodeAlpha(int i, Set<int> related) {
    if (!data.lit[i]) return 0.10;
    final int? focus = data.focus;
    if (focus == null) return 1;
    if (i == focus) return 1;
    return related.contains(i) ? 1 : 0.16;
  }

  void _paintNodes(Canvas canvas) {
    final Set<int> related = _related;
    final Paint fill = Paint();
    final Paint ring = Paint()..style = PaintingStyle.stroke;

    for (final GraphNode node in data.graph.nodes) {
      final int i = node.index;
      final double x = data.layout.x[i];
      final double y = data.layout.y[i];
      final double r = _visualRadius(i);

      fill.color = _nodeColor(i).withValues(alpha: _nodeAlpha(i, related));
      canvas.drawCircle(Offset(x, y), r, fill);

      // 环只给**选中**那一颗。悬停不加环——悬停是靠放大和标签变白说话的，
      // 再加一个圈，图上一半的节点都在闪。
      if (i == data.selected) {
        ring
          ..color = data.style.ring.withValues(alpha: 0.55)
          ..strokeWidth = 1.4 * hairline;
        canvas.drawCircle(Offset(x, y), r + 4.5 * math.max(1, data.scale) / data.scale, ring);
      }
    }
  }

  // ------------------------------------------------------------------ 标签

  /// 标签的浓度：放大到一定比例才显形，不是开关。
  ///
  /// 照设计稿 `(scale - 0.55) / 0.40`：铺满画布的缩略视图里标签根本读不出，
  /// 留着只是把画布压灰；放大到 95% 以上才全亮。中间是连续淡入，不是硬切。
  double _labelAlpha({required bool isFocus}) {
    if (isFocus) return 1;
    return _clamp((data.scale - 0.55) / 0.40);
  }

  void _paintLabels(Canvas canvas) {
    final int? focus = data.focus;
    final Set<int> related = _related;

    for (final GraphNode node in data.graph.nodes) {
      final int i = node.index;
      final bool isFocus = i == focus;
      final double a = _labelAlpha(isFocus: isFocus) * _nodeAlpha(i, related);
      if (a <= 0.02) continue;

      // 标签在节点**下方居中**：挂在右边时，长标题会横着长出去、和邻居的
      // 标签接上，整张图变成一行行字。
      //
      // 压住连线靠的是**投影**（设计稿 `shadowBlur = 4`），不是描边：
      // 描边会在每个字外面套一圈硬边，密起来像贴了一层贴纸。
      final TextPainter tp = labels.painter(
        node.title,
        color: isFocus
            ? data.style.labelFocus
            : data.style.label.withValues(alpha: a),
        shadow: a >= 0.45 ? data.style.labelHalo : null,
        scaler: data.textScaler,
        fontSize: isFocus ? AppText.ui : AppText.label,
        weight: isFocus ? FontWeight.w500 : FontWeight.w400,
      );
      // 位置用**基础**半径：焦点放大时标签不该跟着往下跳。
      final double x = data.layout.x[i] - tp.width / 2;
      final double y = data.layout.y[i] + data.radii[i] + 11 - tp.height / 2;
      tp.paint(canvas, Offset(x, y));
    }
  }

  static double _clamp(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  static double _clampD(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

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

  /// 取一段文字的 [TextPainter]。
  ///
  /// [shadow] 非空时给它加一层投影（画布底色、模糊 4）——设计稿用的是
  /// `ctx.shadowBlur = 4`，不是描边：描边会在每个字外面套一圈硬边。
  TextPainter painter(
    String text, {
    required Color color,
    required Color? shadow,
    required TextScaler scaler,
    double fontSize = AppText.caption,
    FontWeight weight = FontWeight.w400,
  }) {
    if (_scaler != scaler) {
      _scaler = scaler;
      clear();
    }
    // 颜色、字号、字重都进 key：同一个标题有「亮着」「被筛掉」两种颜色，
    // 焦点那颗又大一号，都不能共用一份。
    final String key = '$text|$color|$shadow|$fontSize|$weight';
    final TextPainter? hit = _painters[key];
    if (hit != null) return hit;

    final TextStyle style = TextStyle(
      fontSize: fontSize,
      fontWeight: weight,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      height: 1.2,
      color: color,
      shadows: shadow == null
          ? null
          : <Shadow>[Shadow(color: shadow, blurRadius: 4)],
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
