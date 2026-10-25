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
    required this.selected,
    required this.showLabels,
    required this.arrows,
    required this.style,
    required this.folderColors,
    required this.scale,
    required this.offset,
    required this.labelFade,
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

  /// 真正**选中**的节点（点下去的那个）。
  ///
  /// 和 [focus] 分开：悬停只是「看」，不该把节点染成强调色；只有点下去
  /// 才换色。设计稿里 `nodeColor` 也只认 `sel`。
  final int? selected;

  final bool showLabels;
  final bool arrows;
  final GraphStyle style;
  final Map<String, Color> folderColors;

  /// 视口变换。
  final double scale;
  final Offset offset;

  /// 标签的缩放淡出系数，0..1，由视图按「当前缩放 ÷ 铺满画布时的缩放」算好。
  ///
  /// 不直接拿 [scale] 去算：设计稿的 `view.s` 是相对量（初始就是 1），而
  /// 我们的 [scale] 是绝对量——世界坐标多大、画布多大都会影响它。同一张图
  /// 换个窗口尺寸，绝对 scale 就变了，直接拿它当门槛会出现「窗口一小标签
  /// 全没了」。
  final double labelFade;

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

  /// 1 个**屏幕**像素折成世界坐标。
  ///
  /// 照设计稿 `1 / s * clamp(s, 0.9, 1.7)`：线宽基本不随缩放变，但放大时
  /// 会**稍微**粗一点点。完全不变粗的话，高倍下整张图会细得像掉了几根线；
  /// 按 s 线性变粗又会一放大就糊。
  double get hairline => _clampD(data.scale, 0.9, 1.7) / math.max(data.scale, 0.01);

  /// 每条边的「基础亮度」。数值照抄设计稿 `EDGE.beam`。
  ///
  /// 三档不是三个独立常数：[edgeFocus] / [edgeBase] 就是设计稿里的 6 倍，
  /// 画的时候统一按这个倍数去乘 [GraphStyle.beamFrom] / [GraphStyle.beamTo]，
  /// 这样「常态多亮、焦点多亮」只有一处定义，不会两处走偏。
  static const double edgeBase = 0.100;
  static const double edgeSame = 0.150;
  static const double edgeNear = 0.150;
  static const double edgeFocus = 0.60;
  static const double edgeDimmed = 0.032;

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
    // 照设计稿：光在画布正中偏上一点点，一圈柔和地暗下去。
    // 原来光源在画布外上方，上半张明显更亮，看着像被台灯照着。
    final Offset center = Offset(size.width * 0.5, size.height * 0.42);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          math.max(size.width, size.height) * 0.76,
          <Color>[
            data.style.canvasTop,
            Color.lerp(data.style.canvasTop, data.style.canvasBottom, 0.45)!,
            data.style.canvasBottom,
          ],
          <double>[0, 0.55, 1],
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
      final double r = c.radius + 26;
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

  /// 光带的颜色：只认文件夹色。选中节点染成强调色，但线不该跟着变紫。
  Color _beamColor(int i) =>
      data.folderColors[data.graph.nodes[i].folder] ?? data.style.node;

  /// 节点填充色。选中那颗染成强调色，和设计稿一致。
  Color _nodeColor(int i) =>
      i == data.selected ? data.style.ring : _beamColor(i);

  /// 画出来的半径：焦点那颗放大 22%（设计稿 `targetR = r * 1.22`）。
  double _visualRadius(int i) =>
      data.radii[i] * (i == data.focus ? 1.22 : 1);

  /// 节点浓度，照设计稿 `nodeAlpha()`。
  ///
  /// 有焦点时，**不在焦点簇里、也不是邻居**的节点退到 14%。这不是装饰：
  /// 光带画的是「谁引用谁」，不把无关节点压下去，几十条同亮度的线会互相
  /// 打平，焦点那几条反而看不出特别。
  double _nodeAlpha(int i, int? focus, String focusFolder, Set<int> related) {
    if (!data.lit[i]) return 0.10;
    if (focus == null) return 1;
    if (i == focus) return 1;
    if (data.graph.nodes[i].folder == focusFolder) return 1;
    return related.contains(i) ? 0.95 : 0.14;
  }

  /// 一条边的亮度档位，完全照设计稿 `edgeAlpha()` 的分支顺序。
  ///
  /// 顺序有意义：**先看焦点边，再看同簇，最后才看邻居**。同簇的边在悬停
  /// 时整片亮起来，是「簇」这个组织方式唯一能被眼睛直接看到的地方；只按
  /// 邻接关系算的话，簇里没连线的边会原地不动，簇就散了。
  double _edgeLevel(GraphEdge e, int? focus, String focusFolder, Set<int> related) {
    if (focus == null) return edgeBase;
    if (e.a == focus || e.b == focus) return edgeFocus;
    final bool aSame = data.graph.nodes[e.a].folder == focusFolder;
    final bool bSame = data.graph.nodes[e.b].folder == focusFolder;
    if (aSame && bSame) return edgeSame * 1.1;
    if (aSame || bSame) return edgeNear;
    if (related.contains(e.a) || related.contains(e.b)) return edgeNear;
    return edgeDimmed;
  }

  void _paintEdges(Canvas canvas) {
    final NoteGraph g = data.graph;
    final int? focus = data.focus;
    final String focusFolder = focus == null ? '' : g.nodes[focus].folder;
    final Set<int> related = <int>{
      if (focus != null) ...g.nodes[focus].neighbours,
    };

    // 设计稿的常态线宽是 0.9 个屏幕像素，不是 1。
    final double width = 0.9 * hairline;
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
    // 箭头按**颜色**分组：设计稿里光带的箭头跟着靶节点走分组色，
    // 一色一条 Path，四五个文件夹也只多四五次 draw call。
    final Map<Color, Path> arrows = <Color, Path>{};

    final Paint beam = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width
      ..color = const Color(0xFFFFFFFF);
    final Paint glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3.4 * hairline
      ..color = data.style.beamGlow;

    // 箭头大小按屏幕像素定，缩放时不变形（设计稿 `7 / clamp(s, .7, 1.6)`）
    final double arrowSize = 7 / _clampD(data.scale, 0.7, 1.6);

    for (final GraphEdge e in g.edges) {
      if (!data.lit[e.a] || !data.lit[e.b]) continue;

      final Offset pa = Offset(data.layout.x[e.a], data.layout.y[e.a]);
      final Offset pb = Offset(data.layout.x[e.b], data.layout.y[e.b]);

      final double level = _edgeLevel(e, focus, focusFolder, related);
      final bool hot = level >= edgeFocus;

      // 方向：`from` 是正文里写链接的那一头。双向边没有方向，按 a→b 画，
      // 只是不画箭头——两个方向都成立，画哪个都是撒谎。
      final bool forward = e.from == null || e.from == e.a;
      final int src = forward ? e.a : e.b;
      final int dst = forward ? e.b : e.a;
      final Offset from = forward ? pa : pb;
      final Offset to = forward ? pb : pa;

      // 设计稿：`from = min(1, a * 1.35)`、`to = min(1, a * 0.40)`。
      // 档位只改 `a`，两头亮度的比例是固定的——方向感来自这个比例，
      // 不能随档位变。
      final double k = level / edgeBase;
      final double aFrom = _clamp(data.style.beamFrom * k);
      final double aTo = _clamp(data.style.beamTo * k);

      if (hot) canvas.drawLine(from, to, glow);

      if (gradient) {
        beam.shader = ui.Gradient.linear(from, to, <Color>[
          _beamColor(src).withValues(alpha: aFrom),
          _beamColor(dst).withValues(alpha: aTo),
        ]);
        canvas.drawLine(from, to, beam);
      } else {
        flat
          ..moveTo(from.dx, from.dy)
          ..lineTo(to.dx, to.dy);
      }

      // 箭头常显（用户点名喜欢这个），互相链接的不画——双向的箭头会撒谎。
      //
      // 亮度从 0.22 起底、跟着边往上走：淡边上的箭头如果按边亮度画，
      // 等于没画；常显的箭头必须有个下限。
      if (data.arrows && !e.isBidirectional && level > 0.06) {
        final Color tint = _beamColor(dst)
            .withValues(alpha: math.min(0.72, 0.22 + level * 1.5));
        _addArrow(
          arrows.putIfAbsent(tint, () => Path()),
          from,
          to,
          _visualRadius(dst),
          arrowSize,
        );
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
    for (final MapEntry<Color, Path> a in arrows.entries) {
      canvas.drawPath(a.value, Paint()..color = a.key);
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
        // 白心 + 紫晕：设计稿是 `rgba(255,255,255,.95)` → 强调紫 50% → 透明。
        // 全用强调紫的话，光点在深色画布上会偏灰，不像「光」。
        const Color(0xFFFFFFFF).withValues(alpha: 0.95),
        data.style.ring.withValues(alpha: 0.50),
        data.style.ring.withValues(alpha: 0),
      ], <double>[0, 0.35, 1]);
      canvas.drawCircle(at, 5.5, paint);
    }
    paint.shader = null;
  }

  static double _clamp(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  static double _clampD(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);

  /// 把箭头三角拼进同一条 Path——同色的几十个三角也只多一次 draw call。
  ///
  /// [size] 是**世界坐标**下的边长，由调用方按当前缩放折好（设计稿的箭头
  /// 是屏幕尺寸恒定的，放大不该变成一片大三角）。
  void _addArrow(
    Path path,
    Offset from,
    Offset to,
    double r,
    double size,
  ) {
    final double dx = to.dx - from.dx;
    final double dy = to.dy - from.dy;
    final double d = math.sqrt(dx * dx + dy * dy);
    if (d < r + 8) return;
    final double ux = dx / d;
    final double uy = dy / d;
    final double tipX = to.dx - ux * (r + 2);
    final double tipY = to.dy - uy * (r + 2);
    final double half = size * 0.5;
    path
      ..moveTo(tipX, tipY)
      ..lineTo(tipX - ux * size + uy * half, tipY - uy * size - ux * half)
      ..lineTo(tipX - ux * size - uy * half, tipY - uy * size + ux * half)
      ..close();
  }

  // ------------------------------------------------------------------ 节点

  void _paintNodes(Canvas canvas) {
    final NoteGraph g = data.graph;
    final int? focus = data.focus;
    final String focusFolder = focus == null ? '' : g.nodes[focus].folder;
    final Set<int> related = <int>{
      if (focus != null) ...g.nodes[focus].neighbours,
    };
    final Paint fill = Paint();
    final Paint ring = Paint()..style = PaintingStyle.stroke;

    for (final GraphNode node in g.nodes) {
      final int i = node.index;
      final double x = data.layout.x[i];
      final double y = data.layout.y[i];
      final double r = _visualRadius(i);
      final double alpha = _nodeAlpha(i, focus, focusFolder, related);
      final bool isFocus = i == focus;

      fill.color = _nodeColor(i).withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), r, fill);

      // 只有**一个**环，套在焦点节点上。
      //
      // 邻居也画、当前笔记也画，悬停一个枢纽会同时亮起好几个圈，整张图
      // 变成靶盘。设计稿里邻居是靠**变亮**说话的，不是靠加圈。
      if (isFocus) {
        ring
          ..color = data.style.ring.withValues(
            alpha: i == data.selected ? 0.62 : 0.40,
          )
          ..strokeWidth = 1.4 * hairline;
        // 环离圆边至少 4.5 个**屏幕**像素：缩小时不能缩到贴着圆
        final double gap = 4.5 * math.max(1, data.scale) / data.scale;
        canvas.drawCircle(Offset(x, y), r + gap, ring);
      }
    }
  }

  // ------------------------------------------------------------------ 标签

  /// 标签的浓度：枢纽写实、叶子写虚，缩得太小就整片收掉。
  ///
  /// 三百篇笔记把标签全写实，整张图会糊成一片字。度数高的节点才是读者
  /// 找路的锚点，先让它们清楚。
  ///
  /// 那个 `t` 是设计稿里的**缩放门槛**：`(相对缩放 - 0.55) / 0.40`。缩到
  /// 铺满画布时的 55% 以下，标签全是不可读的碎点，留着只会把画布压灰；
  /// 放大到 95% 以上才全亮。没有它，缩略视图就是一层噪声。
  double _labelAlpha(
    GraphNode node, {
    required bool isFocus,
    required bool isNear,
    required String focusFolder,
  }) {
    if (isFocus) return 1;

    final int? focus = data.focus;
    if (focus != null) {
      if (node.folder == focusFolder) return 0.92;
      return isNear ? 0.86 : 0;
    }

    final double w = node.globalDegree >= 3
        ? 1
        : (node.globalDegree >= 1 ? 0.55 : 0.32);
    return data.labelFade * w;
  }

  void _paintLabels(Canvas canvas) {
    final NoteGraph g = data.graph;
    final int? focus = data.focus;
    final String focusFolder = focus == null ? '' : g.nodes[focus].folder;
    final Set<int> related = <int>{
      if (focus != null) ...g.nodes[focus].neighbours,
    };

    for (final GraphNode node in g.nodes) {
      final int i = node.index;
      final double alpha = _labelAlpha(
        node,
        isFocus: i == focus,
        isNear: related.contains(i),
        focusFolder: focusFolder,
      );
      // 节点被压暗时标签跟着压：整簇都退下去了，字还亮着就露馅了。
      final double va = _nodeAlpha(i, focus, focusFolder, related);
      final double a = alpha * (va < 0.5 ? va : 1);
      if (a <= 0.02) continue;

      // 标签在节点**下方居中**，和设计稿一致。
      //
      // 挂在右边时，长标题会横着长出去、和邻居的标签接上，整张图变成一行行
      // 字；挂下方居中的话，字始终跟着自己那颗点走，缩小时也不会串行。
      //
      // 压住连线靠的是**投影**（设计稿 `shadowBlur = 4`），不是描边：
      // 描边会在每个字外面套一圈硬边，密起来像贴了一层贴纸。
      final bool isFocus = i == focus;
      final TextPainter tp = labels.painter(
        node.title,
        color: isFocus ? data.style.labelFocus : data.style.label.withValues(alpha: a),
        // 投影只在字真能读的时候加。设计稿是无条件 `shadowBlur = 4`，
        // 但那会让 10% 的淡标签底下垫一块很实的黑影，像一层脏点。
        shadow: a >= 0.45 ? data.style.labelHalo : null,
        scaler: data.textScaler,
        fontSize: isFocus ? AppText.ui : AppText.label,
        weight: isFocus ? FontWeight.w500 : FontWeight.w400,
      );
      final double x = data.layout.x[i] - tp.width / 2;
      final double y = data.layout.y[i] + _visualRadius(i) + 11 - tp.height / 2;
      tp.paint(canvas, Offset(x, y));
    }
  }

  // ------------------------------------------------------------------ 簇名

  /// 簇名挂在**雾的正上方**，做成一个带色边的小胶囊。
  ///
  /// 不挂在「簇内最上面那个节点」上：邻簇的节点会把它顶开，名字就飘到
  /// 别人家里去了。胶囊底是必需的——簇名经常压在别人的节点上。
  ///
  /// 描边用**这个簇自己的分组色**（30%），所以即使底是画布色，也能一眼
  /// 看出这行字属于哪个色团。
  void _paintClusterChips(Canvas canvas, Map<String, _Cluster> clusters) {
    if (!data.showLabels) return;

    final Paint chip = Paint()..color = data.style.chip;
    final Paint edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hairline;

    for (final MapEntry<String, _Cluster> e in clusters.entries) {
      final _Cluster c = e.value;
      if (c.count < 2) continue;

      final String label = e.key.isEmpty ? '根目录' : e.key;
      final String text = '$label · ${c.count}';
      final TextPainter tp = labels.painter(
        text,
        color: data.style.label.withValues(alpha: 0.82),
        shadow: null,
        scaler: data.textScaler,
        fontSize: AppText.caption - 0.5,
      );

      const double padX = 9;
      final double h = tp.height + 2.5;
      final double w = tp.width + padX * 2;
      final double top = c.y - c.radius - 14 - h / 2;
      final Rect rect = Rect.fromLTWH(c.x - w / 2, top, w, h);
      final RRect rrect = RRect.fromRectAndRadius(rect, Radius.circular(h / 2));

      canvas.drawRRect(rrect, chip);
      edge.color = (data.folderColors[e.key] ?? data.style.node)
          .withValues(alpha: 0.30);
      canvas.drawRRect(rrect, edge);

      tp.paint(canvas, Offset(rect.left + padX, rect.center.dy - tp.height / 2));
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
