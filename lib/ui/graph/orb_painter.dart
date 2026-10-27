import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/utils/note_graph.dart';
import 'cosmos_field.dart';
import 'orb_layout.dart';

/// 一帧的绘制输入。
///
/// 投影在 [GraphViewState] 里算好再传进来：命中测试要用同一批屏幕坐标，
/// 算两遍一定会分家。painter 只负责画，不做几何。
class OrbPaintData {
  const OrbPaintData({
    required this.graph,
    required this.layout,
    required this.screenX,
    required this.screenY,
    required this.scale,
    required this.depth,
    required this.camX,
    required this.camY,
    required this.camZ,
    required this.radii,
    required this.alphas,
    required this.order,
    required this.lit,
    required this.focus,
    required this.secondFocus,
    required this.focusFade,
    required this.useFolderColors,
    required this.folderColors,
    required this.style,
    required this.glowSprites,
    required this.edgeScale,
    required this.textScaler,
    required this.labels,
    required this.sphereRadius,
    required this.zoom,
    required this.labelZoomStart,
    required this.labelZoomFull,
    this.cosmos,
  });

  final NoteGraph graph;
  final OrbLayout layout;

  /// 投影后的屏幕坐标（逻辑像素，左上角原点）。
  final Float32List screenX;
  final Float32List screenY;

  /// 透视缩放系数，已经乘过整体缩放。
  final Float32List scale;

  /// 0 = 球的最远端，1 = 最近端。
  final Float32List depth;

  /// 相机空间的方向（单位向量），光照要用它当法线。
  final Float32List camX;
  final Float32List camY;
  final Float32List camZ;

  /// 每颗点的屏幕半径（已含「节点大小」）。
  final Float32List radii;

  /// 每颗点的最终不透明度。明暗全部走这个通道，不走颜色。
  final Float32List alphas;

  /// 从远到近排好序的节点下标。
  final List<int> order;

  /// 是否通过筛选（搜索 / 文件夹 / 孤立）。没通过就压到很淡，但不删。
  final List<bool> lit;

  /// 主高亮的那个节点。钉住时是钉住的中心，否则是鼠标悬停的那颗。
  final int? focus;

  /// 第二焦点：钉住一颗时，鼠标又悬浮到另一颗，两颗的关联圈一起显示。
  ///
  /// 和 [focus] 分开而不是合并成一个集合，是因为边的高亮要按「方向」分色，
  /// 两套连线各自从自己的中心出发画。为空表示只有一个焦点。
  final int? secondFocus;

  /// 高亮浓度 0~1。0 = 没有焦点，1 = 完全聚焦。
  ///
  /// 边上、环上、标签上的高亮都按它插值——只让节点自己淡入淡出、其他部分
  /// 硬切，看起来还是「咔」一下。
  final double focusFade;
  final bool useFolderColors;
  final Map<String, Color> folderColors;
  final OrbStyle style;

  /// 每种文件夹色一张预渲染的辉光贴图。为空表示还没准备好（第一帧）。
  final Map<Color, ui.Image> glowSprites;

  final double edgeScale;
  final TextScaler textScaler;
  final OrbLabelCache labels;

  /// 球的屏幕半径。由 State 算好传进来——命中测试用的是同一个值，两边各算
  /// 一遍迟早会差半个像素，然后「看着点上了其实没点上」。
  final double sphereRadius;

  /// 滚轮缩放倍数。
  ///
  /// [sphereRadius] 是**没乘缩放**的基准半径（投影里缩放是单独乘到每个点上
  /// 的），但外光圈画的是球的轮廓，必须跟着一起缩放——不然放大时点散开了、
  /// 圈还留在原地。
  final double zoom;

  /// 标签淡入区间，来自图谱设置。
  final double labelZoomStart;
  final double labelZoomFull;

  /// 球外的星场与流星。浅色主题传 null：那套画布是亮底的，星云压上去
  /// 会糊成脏灰，深色专属。
  final CosmosField? cosmos;
}

/// 球体图谱的配色。从 [AppPalette] 解析一次，painter 不碰 context。
class OrbStyle {
  const OrbStyle({
    required this.canvasInner,
    required this.canvasOuter,
    required this.rim,
    required this.edge,
    required this.node,
    required this.ring,
    required this.flowIn,
    required this.label,
    required this.labelFocus,
    required this.labelHalo,
  });

  /// 画布底色：中心稍亮、边缘更暗的径向渐变。
  ///
  /// 不是装饰。球体边缘本来就该比中心暗，底色跟着一起收，点云才有「浮在
  /// 一个球上」的感觉；纯色底会让边缘的点看起来是贴在墙上的。
  final Color canvasInner;
  final Color canvasOuter;

  /// 球体外缘那一圈极淡的光，像大气层。alpha 很低，只负责交代边界。
  final Color rim;

  final Color edge;
  final Color node;
  final Color ring;

  /// 焦点连线上「逆着箭头」那颗粒子的颜色。
  ///
  /// 顺方向那颗用 [ring]（主题色），这颗必须**换一个色相**：只靠亮度差，
  /// 在暗背景上两颗点看起来是同一件事，方向读不出来。
  final Color flowIn;
  final Color label;
  final Color labelFocus;
  final Color labelHalo;
}

/// 标签的 TextPainter 缓存。
///
/// 键按「文字 + 字号 + 字重 + 颜色 + 描边与否」建，而不是整份 [TextStyle]
/// 的哈希：`foreground` 里的 [Paint] 是每帧新建的，按对象身份哈希会导致
/// 永远不命中——放大时上百条标签每帧都重新 layout，就是卡顿的根源。
class OrbLabelCache {
  final Map<String, TextPainter> _painters = <String, TextPainter>{};
  TextScaler _scaler = TextScaler.noScaling;

  void clear() {
    for (final TextPainter p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }

  TextPainter painter(
    String text,
    double fontSize,
    TextScaler scaler,
    TextStyle style,
  ) {
    if (scaler != _scaler) {
      clear();
      _scaler = scaler;
    }
    final Color color =
        style.foreground?.color ?? style.color ?? const Color(0xFF000000);
    final String key = '$text|$fontSize|${style.fontWeight}|'
        '${style.foreground != null}|${color.hashCode}';
    final TextPainter? hit = _painters[key];
    if (hit != null) return hit;

    final TextPainter p = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(fontSize: fontSize)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: scaler,
    )..layout();
    _painters[key] = p;
    return p;
  }
}

/// 球体图谱的画笔。
class OrbPainter extends CustomPainter {
  OrbPainter({
    required this.data,
    required this.clock,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final OrbPaintData data;

  /// 动画时钟（秒），**画的时候才读**。
  ///
  /// ⛔ 不能把它塞进 [OrbPaintData]：那份数据是 build 时建的，而重绘是靠
  /// `repaint` 通知器驱动的——一帧之内可能画好几次，但 build 一次都不做。
  /// 塞进去的话粒子时间被冻在最后一次 build 的时刻，看起来就是「没有粒子」。
  final ValueGetter<double> clock;

  // 复用 Paint：每帧新建 500 个 Paint 是没必要的开销。
  final Paint _fill = Paint()..isAntiAlias = true;
  final Paint _stroke = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke;

  /// 焦点弧环专用：圆头笔帽，和连线的平头笔分开。
  final Paint _ringStroke = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _glow = Paint()
    ..isAntiAlias = true
    ..filterQuality = FilterQuality.low
    ..blendMode = BlendMode.plus;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    _paintBackground(canvas, rect, size);

    if (data.graph.nodes.isEmpty) return;

    _paintEdges(canvas);
    _paintGlow(canvas);
    _paintNodes(canvas);
    // 流星压在节点上、标签下：它是从球面上甩出去的，盖住节点才对；
    // 标签必须永远最高，不然流星会从字上划过去。
    data.cosmos?.paintMeteors(canvas, size);
    _paintLabels(canvas, size);
  }

  // ------------------------------------------------------------------ 底

  void _paintBackground(Canvas canvas, Rect rect, Size size) {
    final Offset centre = Offset(size.width / 2, size.height / 2);
    // 外光圈要跟着缩放走：sphereRadius 是没乘缩放的基准半径（缩放是单独乘到
    // 每个点上的），轮廓却得一起放大——否则放大时点散开了、圈还留在原地。
    //
    // 透视下球的视觉轮廓约等于 1.018 倍几何半径（相机 5.4 倍距离时的切线），
    // 基本就是几何半径本身，所以直接乘 zoom 就贴合。
    final double radius = data.sphereRadius * data.zoom;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          math.max(size.width, size.height) * 0.78,
          <Color>[data.style.canvasInner, data.style.canvasOuter],
          <double>[0, 1],
        ),
    );

    // 星空垫在底色上、大气层下。暗角也跟着它画，所以必须在大气层之前。
    data.cosmos?.paintSky(canvas, size, radius: radius);

    // 大气层：一比一照 `design/graph-drag-variants.html`。
    //
    // 原型是「内半径 0.965R → 外半径 1.075R」的环形渐变：内缘透明，
    // 0.40 处 10%，0.75 处 3%，外缘淡出。窄环只贴着轮廓外侧走；
    // 旧版从 0.86R 就开始发亮，等于把最外圈节点也罩进光里，看起来粗一圈。
    //
    // Dart 的 radial 没有内半径，用同一外径 + 折算后的 stop 复刻：
    // 0.965/1.075 = 0.8977，1.009/1.075 = 0.9386，1.0475/1.075 = 0.9744。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          radius * 1.075,
          <Color>[
            data.style.rim.withValues(alpha: 0),
            data.style.rim.withValues(alpha: 0),
            data.style.rim,
            data.style.rim.withValues(alpha: data.style.rim.a * 0.30),
            data.style.rim.withValues(alpha: 0),
          ],
          <double>[0, 0.8977, 0.9386, 0.9744, 1],
        ),
    );
  }

  // ------------------------------------------------------------------ 边

  void _paintEdges(Canvas canvas) {
    final NoteGraph graph = data.graph;
    final int? focus = data.focus;
    final int? second = data.secondFocus;

    // 按 alpha 分 12 桶，每桶一条 Path 一次 drawPath。
    // 逐条 drawLine 是 900 次原生调用，分桶之后是 12 次。
    const int buckets = 12;
    final List<Path> paths = List<Path>.generate(buckets, (_) => Path());
    final List<int> counts = List<int>.filled(buckets, 0);

    // 两个焦点的关联圈取并集：钉住 1 时悬浮 2，1 和 2 的邻居都要亮着。
    final Set<int>? related = focus == null
        ? null
        : <int>{
            ...graph.nodes[focus].neighbours,
            if (second != null) ...graph.nodes[second].neighbours,
          };
    final double f = data.focusFade;

    for (final GraphEdge e in graph.edges) {
      final int a = e.a, b = e.b;
      if (!data.lit[a] || !data.lit[b]) continue;

      final double d = (data.depth[a] + data.depth[b]) * 0.5;
      final double calm = 0.060 + 0.42 * d * d * d;
      double alpha = calm;
      if (focus != null && f > 0) {
        double target;
        if (a == focus || b == focus || a == second || b == second) {
          // 焦点那几条线换成主题色的弧（见 [_paintFocusEdges]），这条白的
          // 让位：同时画会变成「彩色弧压在白光上」。
          target = 0;
        } else if (related!.contains(a) || related.contains(b)) {
          target = 0.055 + 0.16 * d * d;
        } else {
          target = 0.026 + 0.100 * d * d;
        }
        // 和节点一起插值：边有 900 条，硬切是最显眼的那一下。
        alpha = calm + (target - calm) * f;
      }
      if (alpha < 0.006) continue;

      int bucket = (alpha * buckets).floor();
      if (bucket >= buckets) bucket = buckets - 1;
      if (bucket < 0) bucket = 0;
      paths[bucket].moveTo(data.screenX[a], data.screenY[a]);
      paths[bucket].lineTo(data.screenX[b], data.screenY[b]);
      counts[bucket]++;
    }

    _stroke
      ..strokeWidth = 1 * data.edgeScale
      ..strokeCap = StrokeCap.round
      ..color = data.style.edge;

    for (int i = 0; i < buckets; i++) {
      if (counts[i] == 0) continue;
      _stroke.color = data.style.edge.withValues(alpha: (i + 0.55) / buckets);
      canvas.drawPath(paths[i], _stroke);
    }

    // 焦点节点的连线单独画：主题色的弧 + 箭头 + 沿出链流动的粒子。
    if (focus != null && f > 0.02 && related != null && related.isNotEmpty) {
      _paintFocusEdges(canvas, focus, f);
      // 第二焦点和主焦点相连的那条边已经画过了，跳过，免得两种方向色叠在一起。
      if (second != null) {
        _paintFocusEdges(canvas, second, f, skip: focus);
      }
    }
  }

  /// 焦点节点的连线：带方向的弧、箭头、一个方向一颗粒子。
  ///
  /// 照 `design/graph-obsidian-variants.html` 的「流向」方案，但颜色按
  /// **这条边相对焦点的方向**分，而不是按粒子：
  ///
  /// * **出链**（焦点 → 邻居）一个颜色，**入链**（邻居 → 焦点）另一个颜色。
  ///   这是「谁引用谁」最直接的读法：同色的边指向同一个方向。
  /// * 弧是二次贝塞尔，弧度只有 ±6px，**由这条边的两个 id 哈希决定**——
  ///   同一条边永远同一个弯，不随帧抖；不是所有边统一朝一侧（那样会围成
  ///   一个风车，看起来像装饰）。
  /// * 箭头是**实心三角**，箭尖停在节点边缘外 2px，方向取曲线在终点处的切线。
  /// * 粒子每边只有一颗，**朝着这条边真正的方向走**——不是两颗对开。
  /// * 互链（双向）没有方向：中性色、无箭头、无粒子。
  ///
  /// 逐条画而不是合成一条 Path：只有焦点那几条（最多十几条），但每条都要
  /// 按两端深度单独压暗——背面的邻居要是也画得一样亮，弧线会「穿」过球体，
  /// 立体感立刻塌掉。
  void _paintFocusEdges(Canvas canvas, int focus, double f, {int? skip}) {
    final Color accent = data.style.ring;
    final Color neutral = data.style.edge;
    final Color flowIn = data.style.flowIn;
    final Offset p0 = Offset(data.screenX[focus], data.screenY[focus]);

    for (final GraphEdge e in data.graph.edges) {
      if (e.a != focus && e.b != focus) continue;
      if (skip != null && (e.a == skip || e.b == skip)) continue;
      if (!data.lit[e.a] || !data.lit[e.b]) continue;
      final int other = e.a == focus ? e.b : e.a;
      final Offset p2 = Offset(data.screenX[other], data.screenY[other]);
      final double dx = p2.dx - p0.dx;
      final double dy = p2.dy - p0.dy;
      final double len = math.sqrt(dx * dx + dy * dy);
      if (len < 10) continue;

      final double dep = (data.depth[e.a] + data.depth[e.b]) * 0.5;
      final double k = (0.35 + 0.65 * dep) * f;

      final bool twoWay = e.isBidirectional;
      final bool out = !twoWay && e.from == focus;
      // 出链 / 入链 / 互链，三种颜色。
      final Color tint = twoWay ? neutral : (out ? accent : flowIn);

      // 弧度：±6px，由两端 id 哈希。同一条边永远同一个弯。
      final double bend =
          (_hash('${data.graph.nodes[e.a].id}>${data.graph.nodes[e.b].id}') %
              13) -
          6;
      final Offset c = Offset(
        (p0.dx + p2.dx) / 2 - dy / len * bend,
        (p0.dy + p2.dy) / 2 + dx / len * bend,
      );

      _stroke
        ..strokeWidth = 1.4 * data.edgeScale
        ..strokeCap = StrokeCap.round
        ..color = tint.withValues(alpha: (twoWay ? 0.5 : 0.72) * k);
      canvas.drawPath(
        Path()
          ..moveTo(p0.dx, p0.dy)
          ..quadraticBezierTo(c.dx, c.dy, p2.dx, p2.dy),
        _stroke,
      );

      // 箭头：双向链接没有「谁引用谁」，不画。
      if (!twoWay) {
        // 尖端方向（箭头指向）与尖端位置。终点是 `e.to`，被指向的那一头。
        double ax, ay;
        Offset tip;
        if (e.to == focus) {
          // 入链：曲线从 p0 出发，箭头却指向 p0，方向与曲线走向相反。
          final double vx = c.dx - p0.dx, vy = c.dy - p0.dy;
          final double vl = math.sqrt(vx * vx + vy * vy);
          if (vl < 1e-6) continue;
          ax = -vx / vl;
          ay = -vy / vl;
          final double back = data.radii[focus] + 2;
          tip = Offset(p0.dx - ax * back, p0.dy - ay * back);
        } else {
          final double vx = p2.dx - c.dx, vy = p2.dy - c.dy;
          final double vl = math.sqrt(vx * vx + vy * vy);
          if (vl < 1e-6) continue;
          ax = vx / vl;
          ay = vy / vl;
          final double back = data.radii[other] + 2;
          tip = Offset(p2.dx - ax * back, p2.dy - ay * back);
        }
        const double size = 6;
        final double px = -ay, py = ax;
        _fill.color = tint.withValues(alpha: math.min(0.85, 1.2 * k));
        canvas.drawPath(
          Path()
            ..moveTo(tip.dx, tip.dy)
            ..lineTo(
              tip.dx - ax * size + px * size * 0.5,
              tip.dy - ay * size + py * size * 0.5,
            )
            ..lineTo(
              tip.dx - ax * size - px * size * 0.5,
              tip.dy - ay * size - py * size * 0.5,
            )
            ..close(),
          _fill,
        );

        // 粒子：一颗，朝这条边真正的方向走。出链往外，入链往里。
        if (k > 0.2) {
          final double phase =
              (_hash(
                        '${data.graph.nodes[e.b].id}<${data.graph.nodes[e.a].id}',
                      ) %
                      1000) /
                  1000;
          final double t = (clock() / 1.4 + phase) % 1.0;
          _fill.color = tint.withValues(alpha: 0.95 * k);
          canvas.drawCircle(_quad(p0, c, p2, out ? t : 1 - t), 1.7, _fill);
        }
      }
    }
  }

  /// FNV-1a。只用来给「这条边弯多少」「粒子什么时候出发」取一个稳定的数。
  static int _hash(String s) {
    int h = 2166136261;
    for (int i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return h;
  }

  /// 二次贝塞尔上的一点。
  static Offset _quad(Offset p0, Offset c, Offset p2, double u) {
    final double w = 1 - u;
    return Offset(
      w * w * p0.dx + 2 * w * u * c.dx + u * u * p2.dx,
      w * w * p0.dy + 2 * w * u * c.dy + u * u * p2.dy,
    );
  }

  // ------------------------------------------------------------------ 节点

  void _paintGlow(Canvas canvas) {
    if (data.glowSprites.isEmpty) return;

    final int? focus = data.focus;
    final int? second = data.secondFocus;
    for (final int i in data.order) {
      final double a = data.alphas[i];
      if (a < 0.20) continue;
      final ui.Image? sprite = data.glowSprites[_nodeColor(i)];
      if (sprite == null) continue;

      // 辉光按深度强衰减。球体边缘的点被投影压得很密，若也发光就会叠成
      // 一圈过曝的「项链」，比中心还亮。
      final double dk = math.pow(data.depth[i], 1.7).toDouble();
      final double r = data.radii[i] *
          (i == focus || i == second ? 4.6 + 2.4 * data.focusFade : 4.6);
      final double alpha = math.min(0.85, a * 0.46 * dk);
      if (alpha <= 0.004) continue;

      _glow.color = const Color(0xFFFFFFFF).withValues(alpha: alpha);
      canvas.drawImageRect(
        sprite,
        Rect.fromLTWH(0, 0, sprite.width.toDouble(), sprite.height.toDouble()),
        Rect.fromCircle(center: Offset(data.screenX[i], data.screenY[i]), radius: r),
        _glow,
      );
    }
  }

  void _paintNodes(Canvas canvas) {
    final int? focus = data.focus;
    final int? second = data.secondFocus;

    for (final int i in data.order) {
      final double a = data.alphas[i];
      if (a <= 0.01) continue;

      _fill.color = _nodeColor(i).withValues(alpha: a);
      canvas.drawCircle(
        Offset(data.screenX[i], data.screenY[i]),
        data.radii[i],
        _fill,
      );

      if (i == focus || i == second) {
        // 两段 124° 圆弧留在左右：上下让给标签和连线，不再是一整圈
        // 浮在节点外面的硬边。圆头和 55% 透明度让它像取景框，而不是
        // 一个高亮圆圈。
        final double fade = data.focusFade;
        if (fade > 0.01) {
          final Rect arc = Rect.fromCircle(
            center: Offset(data.screenX[i], data.screenY[i]),
            radius: data.radii[i] + 5.5,
          );
          _ringStroke
            ..strokeWidth = 1.5
            ..color = data.style.ring.withValues(alpha: 0.55 * fade);
          const double span = 124 * math.pi / 180;
          canvas.drawArc(arc, -62 * math.pi / 180, span, false, _ringStroke);
          canvas.drawArc(arc, 118 * math.pi / 180, span, false, _ringStroke);
        }
      }
    }
  }

  Color _nodeColor(int i) {
    if (!data.useFolderColors) return data.style.node;
    final String folder = data.graph.nodes[i].folder;
    return data.folderColors[folder] ?? data.style.node;
  }

  // ------------------------------------------------------------------ 标签

  void _paintLabels(Canvas canvas, Size size) {
    final int? focus = data.focus;
    final List<({int index, double size, double alpha, int mode})> shown =
        <({int index, double size, double alpha, int mode})>[];
    // 静止标签共用同一套透明度，淡入时整批套一个图层。这样 TextPainter
    // 只按固定颜色建键，缩放时不会每帧重建、重排上百条文字。
    bool batched = false;
    double batchAlpha = 0;
    // 完全显示时的不透明度。颜色直接按它烘焙进 TextStyle，图层只在淡入
    // 过程中用一下；静止时不再每帧开一整张离屏图层。
    const double maxBatchAlpha = 0.58;

    // 0 = 节点上方居中，1 = 左侧，2 = 右侧
    //
    // 两套标签是两批不同的点，没法逐字插值，所以等淡入过半再换：那会儿
    // 整张图已经压到一半，换标签看不出跳。
    if (focus != null && data.focusFade >= 0.5) {
      final double f = data.focusFade;
      final int? second = data.secondFocus;
      // 先把两个中心都按主标签放进去，再补各自的邻居：这样第二焦点即使
      // 本身就是主焦点的邻居，也不会被降成邻居字号。
      final List<int> centres = <int>[focus, ?second];
      final Set<int> seen = centres.toSet();
      for (final int c in centres) {
        shown.add((index: c, size: 13, alpha: 0.95 * f, mode: 0));
      }
      // 一个焦点的邻居可能很多（日记这类枢纽常有二三十条边）。原先只贴
      // 前 12 个邻居，剩下的连线都在、就是没有名字——看起来像「标签丢了」。
      // 文字有缓存，多排十几条不贵；这里留 72 条的总上限，防止超大枢纽
      // 一次性排上百条。
      const int maxFocusLabels = 72;
      for (final int c in centres) {
        if (shown.length >= maxFocusLabels) break;
        final List<int> nb = data.graph.nodes[c].neighbours;
        final double fx = data.screenX[c];
        for (final int j in nb) {
          if (shown.length >= maxFocusLabels) break;
          if (!data.lit[j] || !seen.add(j)) continue;
          shown.add((
            index: j,
            size: 12,
            alpha: 0.62 * f,
            mode: data.screenX[j] >= fx ? 2 : 1,
          ));
        }
      }
    } else {
      // 静止时按**缩放级别**决定显隐，和节点连了多少边无关。
      //
      // 缩小时每个字都会糊成一个噪点，所以整片标签随缩放一起淡出；放大到
      // 一定程度才逐颗浮现。透明度做平滑过渡，避免在阈值附近来回闪。
      // 放大后节点间距被拉开，能同时容纳的标签自然变多——这就是 Obsidian
      // 图谱那种「越放大看到的字越多」的效果。
      // 阈值来自图谱设置。两个值被拖反时留一点最小跨度兜底，别让淡入反向。
      final double zoomStart = data.labelZoomStart;
      final double zoomFull = math.max(data.labelZoomFull, zoomStart + 0.02);
      final double t = ((data.zoom - zoomStart) / (zoomFull - zoomStart))
          .clamp(0.0, 1.0);
      final double alpha = maxBatchAlpha * t * t * (3 - 2 * t);
      if (alpha > 0.01) {
        batched = true;
        batchAlpha = alpha;

        // 从近到远挑：近处的点先占位，远处的字让开，避免背面标签透上来。
        // 还要互相离得够远，否则密集处会叠成一团白雾。
        const double minGap = 64;
        // 硬上限：文字绘制不便宜，即便视口还有空间也不一次画上百条。
        const int maxLabels = 120;
        final List<int> picked = <int>[];
        for (int k = data.order.length - 1; k >= 0; k--) {
          if (picked.length >= maxLabels) break;
          final int i = data.order[k];
          if (!data.lit[i] || data.depth[i] <= 0.58) continue;
          // 画布外的标签看不见，先剔掉——放大后这类点占大多数。
          final double sx = data.screenX[i];
          final double sy = data.screenY[i];
          if (sx < -40 ||
              sx > size.width + 40 ||
              sy < -40 ||
              sy > size.height + 40) {
            continue;
          }
          bool crowded = false;
          for (final int other in picked) {
            final double dx = data.screenX[i] - data.screenX[other];
            final double dy = data.screenY[i] - data.screenY[other];
            if (dx * dx + dy * dy < minGap * minGap) {
              crowded = true;
              break;
            }
          }
          if (crowded) continue;
          picked.add(i);
        }
        for (final int i in picked) {
          shown.add((index: i, size: 11.5, alpha: alpha, mode: 0));
        }
      }
    }

    if (shown.isEmpty) return;

    final bool layered = batched && batchAlpha < maxBatchAlpha - 0.001;
    if (layered) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()
          ..color = Color.fromRGBO(
            255,
            255,
            255,
            (batchAlpha / maxBatchAlpha).clamp(0.0, 1.0),
          ),
      );
    }

    for (final ({int index, double size, double alpha, int mode}) item in shown) {
      final int i = item.index;
      final double r = math.max(data.radii[i], 1.6);
      final double x = data.screenX[i];
      final double y = data.screenY[i];

      double lx;
      double ly;
      TextAlign align;
      switch (item.mode) {
        case 1:
          align = TextAlign.right;
          lx = x - r - 9;
          ly = y;
        case 2:
          align = TextAlign.left;
          lx = x + r + 9;
          ly = y;
        default:
          align = TextAlign.center;
          lx = x;
          ly = y - r - 18;
          // 顶上放不下就翻到下面，不然贴边的标签会被裁掉。
          if (ly < 16) ly = y + r + 18;
      }

      final String title = data.graph.nodes[i].title;

      // 先用画布底色描一圈再填字：任何背景上都能读，又没有「标签底板」的
      // 块状感。这就是 canvas 版 strokeText 的等价做法——TextStyle 的
      // foreground 和 color 互斥，所以描边那遍要单独建一份样式。
      //
      // 批量那批把固定透明度烘进颜色，淡入阶段再整体乘一层图层；逐条
      // 那批（焦点附近十几条）各自带 alpha。
      final Color haloColor = batched
          ? data.style.labelHalo.withValues(alpha: maxBatchAlpha * 0.92)
          : data.style.labelHalo.withValues(alpha: item.alpha * 0.92);
      final Color fillBase =
          item.mode == 0 ? data.style.labelFocus : data.style.label;
      final Color fillColor = batched
          ? fillBase.withValues(alpha: maxBatchAlpha)
          : fillBase.withValues(alpha: item.alpha);

      final TextPainter halo = data.labels.painter(
        title,
        item.size,
        data.textScaler,
        TextStyle(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.2
            ..strokeJoin = StrokeJoin.round
            ..color = haloColor,
          fontWeight: FontWeight.w500,
        ),
      );
      final TextPainter fill = data.labels.painter(
        title,
        item.size,
        data.textScaler,
        TextStyle(color: fillColor, fontWeight: FontWeight.w500),
      );

      final double dx = switch (align) {
        TextAlign.right => lx - fill.width,
        TextAlign.left => lx,
        _ => lx - fill.width / 2,
      };
      final double dy = ly - fill.height / 2;

      halo.paint(canvas, Offset(dx, dy));
      fill.paint(canvas, Offset(dx, dy));
    }

    if (layered) canvas.restore();
  }

  @override
  bool shouldRepaint(OrbPainter oldDelegate) => true;
}
