import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/utils/note_graph.dart';
import 'orb_math.dart';

/// 球面布局：每篇笔记都是单位球面上的一个点。
///
/// ## 为什么按文件夹聚簇
///
/// 球面如果均匀撒点，看起来就是一团噪点，没有任何结构可读。让**同一个顶层
/// 文件夹的笔记落在球面的同一片区域**，球上就长出了「大陆」——而且这块大陆
/// 的语义是真的：它就是那个文件夹。图例上的颜色和球上的位置于是指向同一件事。
///
/// 簇中心用斐波那契球面排布（[fibonacciSphere]），保证任意两个文件夹的大陆
/// 不会叠在一起；每个文件夹占的球面面积正比于它的篇数，所以笔记多的文件夹
/// 自然摊得更开。
class OrbLayout {
  OrbLayout(int length)
    : px = Float32List(length),
      py = Float32List(length),
      pz = Float32List(length);

  /// 单位球面上的坐标。**不是**屏幕坐标，也不是像素。
  final Float32List px;
  final Float32List py;
  final Float32List pz;

  int get length => px.length;

  bool get isEmpty => px.isEmpty;

  /// 第 [i] 个节点的方向向量。
  OrbPoint pointAt(int i) => OrbPoint(px[i], py[i], pz[i]);

  /// 把第 [i] 个节点挪到球面方向 [p] 上。
  void setPoint(int i, OrbPoint p) {
    px[i] = p.x;
    py[i] = p.y;
    pz[i] = p.z;
  }

  /// 撒点。
  ///
  /// 确定性随机（固定 seed）：同一份笔记每次打开都是同一个形状。图谱是
  /// 空间记忆的载体，每次进来都换个样子等于没有记忆。
  void seed(NoteGraph graph, {int randomSeed = 20261026}) {
    final int n = graph.nodes.length;
    if (n == 0) return;

    // 按文件夹分组。根目录 '' 排最前——和 assignFolderTokens 的顺序一致，
    // 这样图例的颜色和球上的位置能对上。
    final Map<String, List<int>> byFolder = <String, List<int>>{};
    for (final GraphNode node in graph.nodes) {
      byFolder.putIfAbsent(node.folder, () => <int>[]).add(node.index);
    }
    final List<String> folders = byFolder.keys.toList()..sort();
    final List<OrbPoint> centres = fibonacciSphere(folders.length);
    final math.Random rng = math.Random(randomSeed);

    // 一个文件夹吃掉大半本库时，「按文件夹聚簇」就没有信息量了：所有点会
    // 挤在同一片球冠里，球变成一边倒的一坨亮斑。这时退回均匀铺满——
    // 没有结构可读时，诚实一点，别用形状暗示一个不存在的分组。
    int biggest = 0;
    for (final List<int> members in byFolder.values) {
      if (members.length > biggest) biggest = members.length;
    }
    if (biggest / n > 0.6) {
      final List<OrbPoint> even = fibonacciSphere(n);
      for (int i = 0; i < n; i++) {
        setPoint(i, even[i]);
      }
      return;
    }

    for (int f = 0; f < folders.length; f++) {
      final List<int> members = byFolder[folders[f]]!;
      final OrbPoint centre = centres[f];
      final List<OrbPoint> basis = tangentBasis(centre);

      // 簇的角半径：球冠面积正比于篇数占比。占满全库的文件夹摊成整个球面，
      // 只有一两篇的文件夹缩成一个小点。
      final double share = members.length / n;
      final double theta = math.acos((1 - 2 * share).clamp(-1.0, 1.0));
      final double sigma = (theta * 0.5).clamp(0.14, 0.78);

      for (final int i in members) {
        // 球面高斯：|N(0,1)| 让点往中心挤，边缘自然稀疏。
        final double phi = _absGauss(rng) * sigma + 0.004;
        final double theta2 = rng.nextDouble() * math.pi * 2;
        final OrbPoint p = offsetOnSphere(
          centre,
          basis[0],
          basis[1],
          math.min(phi, math.pi * 0.92),
          theta2,
        );
        setPoint(i, p);
      }
    }
  }

  /// 球面松弛：把叠在一起的点推开，把有连线的点拉近一点。
  ///
  /// 只在**球面上**移动：每一步推完都重新归一化回单位球，所以「球」这个形状
  /// 不会被力导向破坏——这正是平面力导向做不到的。
  void relax(NoteGraph graph, {int iterations = 26}) {
    final int n = length;
    if (n < 2) return;

    // 球面平均间距 ≈ sqrt(4π/n)，斥力半径取它的一半多一点。
    final double meanGap = math.sqrt(4 * math.pi / n);
    final double minD = meanGap * 0.55;
    final double minD2 = minD * minD;
    final double spring = meanGap * 1.08;
    final double spring2 = spring * spring;

    for (int it = 0; it < iterations; it++) {
      // 斥力：全对全。520 个点是 13 万对，26 轮 340 万次——一次性的，
      // 几十毫秒，比每帧都算便宜得多。
      for (int i = 0; i < n; i++) {
        final double xi = px[i], yi = py[i], zi = pz[i];
        for (int j = i + 1; j < n; j++) {
          final double dx = xi - px[j];
          final double dy = yi - py[j];
          final double dz = zi - pz[j];
          final double d2 = dx * dx + dy * dy + dz * dz;
          if (d2 >= minD2 || d2 < 1e-9) continue;
          final double d = math.sqrt(d2);
          final double f = (minD - d) / d * 0.16;
          px[i] += dx * f;
          py[i] += dy * f;
          pz[i] += dz * f;
          px[j] -= dx * f;
          py[j] -= dy * f;
          pz[j] -= dz * f;
        }
      }

      // 弹簧：只对真实存在的边。
      for (final GraphEdge e in graph.edges) {
        final int i = e.a, j = e.b;
        final double dx = px[i] - px[j];
        final double dy = py[i] - py[j];
        final double dz = pz[i] - pz[j];
        final double d2 = dx * dx + dy * dy + dz * dz;
        if (d2 <= spring2 || d2 < 1e-9) continue;
        final double d = math.sqrt(d2);
        final double f = (d - spring) / d * 0.055;
        px[i] -= dx * f;
        py[i] -= dy * f;
        pz[i] -= dz * f;
        px[j] += dx * f;
        py[j] += dy * f;
        pz[j] += dz * f;
      }

      // 归回球面。
      for (int i = 0; i < n; i++) {
        final double l = math.sqrt(px[i] * px[i] + py[i] * py[i] + pz[i] * pz[i]);
        if (l < 1e-9) {
          px[i] = 0;
          py[i] = 0;
          pz[i] = 1;
          continue;
        }
        px[i] /= l;
        py[i] /= l;
        pz[i] /= l;
      }
    }
  }

  /// 从另一份布局按 [mapping] 复制位置。
  ///
  /// 局部图谱靠它继承全局的位置：切到「局部」时剩下的节点**待在原地**，
  /// 只是别的消失了。重新撒点会让整张图跳一下，读者会以为换了一张图。
  void copyFrom(OrbLayout source, List<int> mapping) {
    for (int i = 0; i < mapping.length && i < length; i++) {
      final int src = mapping[i];
      if (src < 0 || src >= source.length) continue;
      px[i] = source.px[src];
      py[i] = source.py[src];
      pz[i] = source.pz[src];
    }
  }

  /// 节点最多那一簇的平均方向。
  ///
  /// 首次进入时用它决定球的初始朝向——球心落在簇间空隙上时，第一眼是一团
  /// 空的，用户会以为图谱坏了。
  OrbPoint largestClusterCentre(NoteGraph graph) {
    if (graph.nodes.isEmpty) return const OrbPoint(0, 0, 1);
    final Map<String, int> counts = <String, int>{};
    for (final GraphNode node in graph.nodes) {
      counts[node.folder] = (counts[node.folder] ?? 0) + 1;
    }
    String biggest = '';
    int best = -1;
    counts.forEach((String folder, int count) {
      if (count > best) {
        best = count;
        biggest = folder;
      }
    });

    double sx = 0, sy = 0, sz = 0;
    for (final GraphNode node in graph.nodes) {
      if (node.folder != biggest) continue;
      sx += px[node.index];
      sy += py[node.index];
      sz += pz[node.index];
    }
    return OrbPoint(sx, sy, sz).normalized();
  }

  /// 把一个节点沿球面挪动屏幕上的 [dx], [dy] 像素。
  ///
  /// 做法是「在切平面上走一步，再投影回球面」：先按相机朝向把屏幕位移换成
  /// 世界空间里的切向位移，加上去之后归一化。这样节点永远贴着球面，不会
  /// 被拖进球里或者飞出球外。
  ///
  /// [dx] / [dy] 传的是「节点当前位置到光标」的误差，不是这一帧的增量——
  /// 见 `GraphViewState._applyDrag`。
  void dragNode(int i, OrbCamera camera, double dx, double dy, double worldPerPixel) {
    // 一步跨太远时会走样：切向走完再归一化，走的是**弦**不是弧，误差被放大
    // 成一段更长的弧，节点就冲过头了。按 22px 分段，快拖和慢拖的手感一致。
    final double span = math.max(dx.abs(), dy.abs());
    final int steps = span <= 22 ? 1 : math.min(18, (span / 22).ceil());
    final double per = worldPerPixel / steps;

    final double wx = (camera.rightX * dx - camera.upX * dy) * per;
    final double wy = (camera.rightY * dx - camera.upY * dy) * per;
    final double wz = (camera.rightZ * dx - camera.upZ * dy) * per;

    double x = px[i], y = py[i], z = pz[i];
    for (int s = 0; s < steps; s++) {
      x += wx;
      y += wy;
      z += wz;
      final double l = math.sqrt(x * x + y * y + z * z);
      if (l < 1e-9) {
        x = 0;
        y = 0;
        z = 1;
        break;
      }
      x /= l;
      y /= l;
      z /= l;
    }
    px[i] = x;
    py[i] = y;
    pz[i] = z;
  }

  /// 从 [from] 转到 [to] 的那个旋转，作用在 [v] 上。
  ///
  /// 三个都是单位方向。轴取叉积、角取夹角，用 Rodrigues 公式转过去——转的
  /// 是绕球心的轴，所以转完还在球面上，彼此的相对位置也一分不差。
  static OrbPoint rotateBetween(OrbPoint from, OrbPoint to, OrbPoint v) {
    final double ax = from.y * to.z - from.z * to.y;
    final double ay = from.z * to.x - from.x * to.z;
    final double az = from.x * to.y - from.y * to.x;
    final double sin = math.sqrt(ax * ax + ay * ay + az * az);
    // 没挪过（或者正好转到对面，轴退化）就没什么可转的。
    if (sin < 1e-9) return v;
    final double cos = (from.x * to.x + from.y * to.y + from.z * to.z).clamp(
      -1.0,
      1.0,
    );
    final double kx = ax / sin, ky = ay / sin, kz = az / sin;
    final double dot = kx * v.x + ky * v.y + kz * v.z;
    final double omc = 1 - cos;
    return OrbPoint(
      v.x * cos + (ky * v.z - kz * v.y) * sin + kx * dot * omc,
      v.y * cos + (kz * v.x - kx * v.z) * sin + ky * dot * omc,
      v.z * cos + (kx * v.y - ky * v.x) * sin + kz * dot * omc,
    );
  }

  /// 把第 [i] 个点沿球面朝 [target] 挪 [ease]（0..1），挪完重新归一化。
  void easeToward(int i, OrbPoint target, double ease) {
    double x = px[i] + (target.x - px[i]) * ease;
    double y = py[i] + (target.y - py[i]) * ease;
    double z = pz[i] + (target.z - pz[i]) * ease;
    final double l = math.sqrt(x * x + y * y + z * z);
    if (l < 1e-9) return;
    px[i] = x / l;
    py[i] = y / l;
    pz[i] = z / l;
  }

  static double _absGauss(math.Random rng) {
    // Box-Muller，取绝对值：只关心「离中心多远」，方位角另外均匀取。
    final double u = 1 - rng.nextDouble();
    final double v = rng.nextDouble();
    return (math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v)).abs();
  }
}
