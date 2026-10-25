import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import '../../core/utils/note_graph.dart';

/// 力导向布局的常数。
///
/// 全部集中在这里，改手感就是改这张表，不散落在循环里。数值是拿 26 节点 /
/// 49 条边的小图验算出来的：包围盒约 440×533，圆间最小间隙 43.5px（无重叠），
/// 800 帧后漂移 4.1（已收敛），无 NaN。
abstract final class GraphPhysics {
  /// 下面这一组照 `design/graph-obsidian-clone.html` 的 `PHYS` 抄，
  /// 是照 Obsidian 的手感调的：链接更长更紧、斥力更弱（簇更收）、
  /// 阻尼更大（不会晃）。
  static const double repulsion = 8000;

  /// 边上弹簧的系数。
  static const double spring = 0.055;

  /// 弹簧自然长度。
  static const double restLength = 190;

  /// 向心引力。没有它，斥力会让整张图无限扩散。
  static const double gravity = 0.008;

  /// 硬碰撞时两个圆之间额外留的缝。
  ///
  /// 只有斥力的话，两个点会一直挤到「斥力 = 弹簧」为止，中间并没有一条
  /// 硬约束——度数高的节点旁边就会糊上几个几乎重叠的点。碰撞是最低保证。
  static const double collide = 7;

  /// 速度衰减。0.62 对应 Obsidian 的 `velocityDecay ≈ 0.38`。
  static const double damping = 0.62;

  /// 单帧位移上限。开场是从中心炸开的，不封顶会直接飞出去。
  static const double maxSpeed = 32;

  /// 静止阈值。低于它就把 Ticker 停掉——静止的图谱不该烧电。
  static const double restingAlpha = 0.005;
}

/// 节点半径：`3 + √度 × 1.9`。
///
/// 开平方是为了压住差异：度 0 是 3，度 9 才 8.7。线性的话一个中心节点会
/// 变成一颗球，把周围的字全盖住。
double graphNodeRadius(int degree, {double scale = 1}) =>
    (3 + math.sqrt(degree) * 1.9) * scale;

/// 一帧一帧推进的布局状态。
///
/// 坐标用 [Float64List] 平铺，不是对象数组：物理循环每帧要按边遍历几十上百次，
/// 平铺数组既没有指针追逐，也不需要为每个节点分配一个可变对象。
class GraphLayout {
  GraphLayout(int count)
    : x = Float64List(count),
      y = Float64List(count),
      vx = Float64List(count),
      vy = Float64List(count),
      radius = Float64List(count);

  /// 按图里的度数铺一张初始布局（随机撒在圆环上，不收敛）。
  factory GraphLayout.of(NoteGraph graph, {double sizeScale = 1, int seed = 1}) {
    final GraphLayout layout = GraphLayout(graph.nodes.length);
    for (final GraphNode node in graph.nodes) {
      layout.radius[node.index] = graphNodeRadius(
        node.globalDegree,
        scale: sizeScale,
      );
    }
    layout.seed(graph, seed: seed);
    return layout;
  }

  final Float64List x;
  final Float64List y;
  final Float64List vx;
  final Float64List vy;
  final Float64List radius;

  /// 弹簧自然长度。面板上的「连线距离」滑块改的就是它，所以不能直接读常量。
  double restLength = GraphPhysics.restLength;

  /// 1 = 全力运行，0 = 静止。每帧乘 0.972 衰减。
  double alpha = 0;

  int get length => x.length;

  bool get isEmpty => x.isEmpty;

  /// 随机撒点。用固定种子，所以同一个库每次打开的形状是同一个——
  /// 关掉再打开图谱，图不会莫名其妙换一副样子。
  ///
  /// 撒点半径按 `√n` 走，不是按 `n`：面积正比于节点数，半径才正比于 √n。
  /// 原来写的是 `150 + n * 9`，一千篇笔记会撒在半径 9000 的圈上，而首屏
  /// 只同步跑 120 帧——根本收不回来，看到的就是一团散沙（包围盒 15000+，
  /// 缩到画布里每个点不到 1 像素）。
  void seed(NoteGraph graph, {int seed = 1}) {
    final math.Random random = math.Random(seed);
    final int n = length;
    // 全部挤在中心附近，让力把它们炸开——这是 Obsidian 打开时那个动作。
    // 半径按 √n 走：面积正比于节点数，半径才正比于 √n。按 n 线性撒的话，
    // 一千篇会撒在半径几千的圈上，首屏那几百帧根本收不回来。
    final double r = 20 + math.sqrt(n) * 6;
    for (int i = 0; i < n; i++) {
      final double angle = (i / math.max(n, 1)) * math.pi * 2 + random.nextDouble() * .4;
      final double spread = r * (0.35 + random.nextDouble() * 0.65);
      x[i] = math.cos(angle) * spread;
      y[i] = math.sin(angle) * spread;
      vx[i] = 0;
      vy[i] = 0;
    }
  }

  /// 同步跑 [ticks] 帧。
  ///
  /// 首屏用它：先收敛到稳定布局再画第一帧，所以打开图谱看到的是最终形状，
  /// 而不是「先炸开再收拢」。
  void settle(NoteGraph graph, int ticks) {
    for (int i = 0; i < ticks; i++) {
      step(graph, 1);
    }
  }

  /// 推进一帧。[alpha] 是力的总开关。
  void step(NoteGraph graph, double alpha) {
    final int n = length;
    if (n == 0) return;

    // 1. 两两斥力
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        double dx = x[j] - x[i];
        double dy = y[j] - y[i];
        double d2 = dx * dx + dy * dy;
        if (d2 < 0.01) {
          // 两点重合。用下标造一个确定的方向，不摇随机数——否则布局不可复现，
          // 测试也没法断言。
          dx = (i - j) * 0.01 + 0.01;
          dy = 0.01;
          d2 = dx * dx + dy * dy;
        }
        final double d = math.sqrt(d2);
        final double f = GraphPhysics.repulsion / d2 * alpha;
        final double ux = dx / d;
        final double uy = dy / d;
        vx[i] -= ux * f;
        vy[i] -= uy * f;
        vx[j] += ux * f;
        vy[j] += uy * f;

        // 硬碰撞：挤得比「两个半径 + 缝」还近就推开。斥力在近距离虽然也
        // 很猛，但它是和弹簧、向心一起求平衡的，没有「绝不允许重叠」这条
        // 硬线——高节点的周围就会糊上一圈几乎重合的点。
        final double min = radius[i] + radius[j] + GraphPhysics.collide;
        if (d < min) {
          final double push = (min - d) * 0.5;
          vx[i] -= ux * push;
          vy[i] -= uy * push;
          vx[j] += ux * push;
          vy[j] += uy * push;
        }
      }
    }

    // 2. 边上弹簧
    for (final GraphEdge e in graph.edges) {
      final double dx = x[e.b] - x[e.a];
      final double dy = y[e.b] - y[e.a];
      final double d = math.sqrt(dx * dx + dy * dy);
      if (d < 0.0001) continue;
      final double f = (d - restLength) * GraphPhysics.spring * alpha;
      final double ux = dx / d;
      final double uy = dy / d;
      vx[e.a] += ux * f;
      vy[e.a] += uy * f;
      vx[e.b] -= ux * f;
      vy[e.b] -= uy * f;
    }

    // 3. 向心引力 + 积分
    for (int i = 0; i < n; i++) {
      vx[i] -= x[i] * GraphPhysics.gravity * alpha;
      vy[i] -= y[i] * GraphPhysics.gravity * alpha;
      vx[i] *= GraphPhysics.damping;
      vy[i] *= GraphPhysics.damping;
      final double speed = math.sqrt(vx[i] * vx[i] + vy[i] * vy[i]);
      if (speed > GraphPhysics.maxSpeed) {
        final double k = GraphPhysics.maxSpeed / speed;
        vx[i] *= k;
        vy[i] *= k;
      }
      x[i] += vx[i];
      y[i] += vy[i];
    }
  }

  /// 所有节点的包围盒（含半径）。适应窗口时用它。
  Rect bounds() {
    if (isEmpty) return Rect.zero;
    double x0 = double.infinity;
    double y0 = double.infinity;
    double x1 = double.negativeInfinity;
    double y1 = double.negativeInfinity;
    for (int i = 0; i < length; i++) {
      final double r = radius[i];
      if (x[i] - r < x0) x0 = x[i] - r;
      if (y[i] - r < y0) y0 = y[i] - r;
      if (x[i] + r > x1) x1 = x[i] + r;
      if (y[i] + r > y1) y1 = y[i] + r;
    }
    return Rect.fromLTRB(x0, y0, x1, y1);
  }

  /// 圆心与半径都按 [scale] 缩放后拷贝一份，给绘制层用。
  ///
  /// 不直接改 [radius]：滑块回调每动一格就重算，改原值会把「原始半径」丢掉。
  Float64List scaledRadii(double scale) {
    final Float64List out = Float64List(length);
    for (int i = 0; i < length; i++) {
      out[i] = radius[i] * scale;
    }
    return out;
  }
}

/// 首屏收敛多少帧。
///
/// 小图多跑几帧图更好看，大图必须让步：这一步是**同步**跑的，跑太久就是
/// 一帧卡住。26 篇约 16ms（一帧的量），300 篇约 260 帧（约 40ms）。
int settleTicksFor(int nodeCount) {
  if (nodeCount <= 120) return 700;
  if (nodeCount <= 300) return 260;
  return 120;
}
