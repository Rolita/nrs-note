import 'dart:math' as math;
import 'dart:typed_data';

/// 球体的姿态：一个 3×3 旋转矩阵（行主序），把世界坐标转到相机坐标。
///
/// 为什么是矩阵而不是四元数：这里只需要「左乘一个小旋转」，而投影时每个节点
/// 都要乘一次。行主序展开的三行点积是最省事的写法，四元数反而要多一次
/// 四元数→矩阵的展开。球体上没有万向节问题——矩阵累乘不会退化。
///
/// 约定：世界坐标里 `+z` 指向观察者，`+x` 向右，`+y` 向上。
/// 屏幕 y 向下，所以画的时候要取反。
class OrbCamera {
  final Float64List _m = Float64List(9);
  final Float64List _t = Float64List(9);

  OrbCamera() {
    _m[0] = 1;
    _m[4] = 1;
    _m[8] = 1;
  }

  /// 旋转矩阵的 9 个元素，行主序。投影循环直接读它，别复制。
  Float64List get matrix => _m;

  /// 相机 x 轴在世界空间里的方向。
  ///
  /// 拖拽节点时要把它在屏幕上的位移换算成球面上的切向位移，用的就是这个。
  /// 矩阵是「世界 → 相机」：`c = M·w`，所以反变换是 `w = Mᵀ·c`，
  /// 相机 x 轴在世界里就是 **Mᵀ 的第 0 列 = M 的第 0 行**（_m[0],_m[1],_m[2]）。
  /// ⛔ 取成第 0 列（_m[0],_m[3],_m[6]）等于把逆旋转用反了：相机转过之后
  /// 横向拖拽会把节点甩到反方向，手感是「节点在躲鼠标」。
  double get rightX => _m[0];
  double get rightY => _m[1];
  double get rightZ => _m[2];

  /// 相机 y 轴（屏幕上方向）在世界空间里的方向。同理取第 1 行。
  double get upX => _m[3];
  double get upY => _m[4];
  double get upZ => _m[5];

  /// 左乘一个「先绕屏幕 Y 轴转 [ay]、再绕屏幕 X 轴转 [ax]」的小旋转。
  ///
  /// 顺序固定成 Rx·Ry，和拖拽的方向感绑定：横向拖动只该绕竖轴，纵向只该绕
  /// 横轴。换成 Ry·Rx 会让斜着拖的时候球往斜方向滚，手感是错的。
  void rotate(double ax, double ay) {
    final double ca = math.cos(ax), sa = math.sin(ax);
    final double cb = math.cos(ay), sb = math.sin(ay);

    // R = Rx(ax)·Ry(ay)
    final double r0 = cb, r1 = 0, r2 = sb;
    final double r3 = sa * sb, r4 = ca, r5 = -sa * cb;
    final double r6 = -ca * sb, r7 = sa, r8 = ca * cb;

    _t[0] = r0 * _m[0] + r1 * _m[3] + r2 * _m[6];
    _t[1] = r0 * _m[1] + r1 * _m[4] + r2 * _m[7];
    _t[2] = r0 * _m[2] + r1 * _m[5] + r2 * _m[8];
    _t[3] = r3 * _m[0] + r4 * _m[3] + r5 * _m[6];
    _t[4] = r3 * _m[1] + r4 * _m[4] + r5 * _m[7];
    _t[5] = r3 * _m[2] + r4 * _m[5] + r5 * _m[8];
    _t[6] = r6 * _m[0] + r7 * _m[3] + r8 * _m[6];
    _t[7] = r6 * _m[1] + r7 * _m[4] + r8 * _m[7];
    _t[8] = r6 * _m[2] + r7 * _m[5] + r8 * _m[8];

    for (int i = 0; i < 9; i++) {
      _m[i] = _t[i];
    }
  }

  /// 求一个旋转把单位向量 `a` 转到单位向量 `b`，直接替换当前姿态。
  ///
  /// Rodrigues 公式。首次进入时用它把节点最多的那个文件夹转到正面——
  /// 否则球心可能正好落在两个文件夹之间的空隙上，第一眼是一团空的。
  void alignTo(double ax, double ay, double az, double bx, double by, double bz) {
    final double kx0 = ay * bz - az * by;
    final double ky0 = az * bx - ax * bz;
    final double kz0 = ax * by - ay * bx;
    final double s = math.sqrt(kx0 * kx0 + ky0 * ky0 + kz0 * kz0);
    final double c = ax * bx + ay * by + az * bz;

    // 已经平行（同向或反向）。反向时绕任意轴转 180° 更正确，但首次进入
    // 不可能出现，直接跳过。
    if (s < 1e-7) return;

    final double kx = kx0 / s, ky = ky0 / s, kz = kz0 / s;
    final double t1 = 1 - c;

    _m[0] = 1 - t1 * (ky * ky + kz * kz);
    _m[1] = t1 * kx * ky - s * kz;
    _m[2] = t1 * kx * kz + s * ky;
    _m[3] = t1 * kx * ky + s * kz;
    _m[4] = 1 - t1 * (kx * kx + kz * kz);
    _m[5] = t1 * ky * kz - s * kx;
    _m[6] = t1 * kx * kz - s * ky;
    _m[7] = t1 * ky * kz + s * kx;
    _m[8] = 1 - t1 * (kx * kx + ky * ky);
  }

  /// 把 [target] 这个方向（世界坐标，单位向量）转向观察者。
  ///
  /// 先取它在相机空间里的位置，再算「还差多少角度」，每帧只补一部分——
  /// 增量式而不是直接对齐，所以不会有中途翻转，也不需要插值四元数。
  ///
  /// 返回剩余角度（弧度），调用方据此判断要不要继续动。
  double turnToward(double tx, double ty, double tz, double fraction) {
    final double ang = math.acos(tz.clamp(-1.0, 1.0));
    if (ang < 0.004) return 0;
    final double sinT = math.sqrt(tx * tx + ty * ty);
    if (sinT < 1e-5) return 0;
    // 旋转向量 ω = (ty, -tx, 0)·(ang/sinθ)，让 |ω| 正好等于 ang。
    final double f = ang / sinT * fraction;
    rotate(ty * f, -tx * f);
    return ang;
  }
}

/// 球面上的一个点（单位向量）。
///
/// 布局层要按文件夹求「簇中心」，用这个当返回类型比三个 double 好读。
class OrbPoint {
  const OrbPoint(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double dot(OrbPoint o) => x * o.x + y * o.y + z * o.z;

  OrbPoint normalized() {
    final double l = math.sqrt(x * x + y * y + z * z);
    if (l < 1e-9) return const OrbPoint(0, 0, 1);
    return OrbPoint(x / l, y / l, z / l);
  }
}

/// 斐波那契球面撒点：`count` 个近似均匀分布的单位向量。
///
/// 簇中心用它排布，保证不会有两个文件夹的「大陆」叠在一起。等距分布的
/// 关键在黄金角 2.399963…，不是随便均分经度。
List<OrbPoint> fibonacciSphere(int count) {
  if (count <= 0) return const <OrbPoint>[];
  if (count == 1) return const <OrbPoint>[OrbPoint(0, 0, 1)];

  const double golden = 2.399963229728653;
  final List<OrbPoint> out = <OrbPoint>[];
  for (int i = 0; i < count; i++) {
    // 从 +1 走到 -1，避开两极正好落在点上的退化情况
    final double y = 1 - (i / (count - 1)) * 2;
    final double r = math.sqrt(math.max(0, 1 - y * y));
    final double th = i * golden;
    out.add(OrbPoint(math.cos(th) * r, y, math.sin(th) * r));
  }
  return out;
}

/// 以 [centre] 为轴的局部正交基，返回 `[u, v]`。
///
/// 用来把「绕中心偏移一个角度」换算成球面上的点。挑一个和中心不平行的
/// 参考向量叉乘，就能保证基不退化。
List<OrbPoint> tangentBasis(OrbPoint centre) {
  final double x = centre.x, y = centre.y, z = centre.z;
  double ax = 0, ay = 0, az = 1;
  if (z.abs() > 0.9) {
    ax = 1;
    az = 0;
  }
  double ux = y * az - z * ay;
  double uy = z * ax - x * az;
  double uz = x * ay - y * ax;
  final double ul = math.sqrt(ux * ux + uy * uy + uz * uz);
  if (ul < 1e-9) return const <OrbPoint>[OrbPoint(1, 0, 0), OrbPoint(0, 1, 0)];
  ux /= ul;
  uy /= ul;
  uz /= ul;
  // v = centre × u
  final double vx = y * uz - z * uy;
  final double vy = z * ux - x * uz;
  final double vz = x * uy - y * ux;
  return <OrbPoint>[OrbPoint(ux, uy, uz), OrbPoint(vx, vy, vz)];
}

/// 围绕 [centre] 偏 [phi] 弧度、方位角 [theta] 的球面点。
OrbPoint offsetOnSphere(OrbPoint centre, OrbPoint u, OrbPoint v, double phi, double theta) {
  final double ct = math.cos(phi), st = math.sin(phi);
  final double ca = math.cos(theta), sa = math.sin(theta);
  return OrbPoint(
    centre.x * ct + (u.x * ca + v.x * sa) * st,
    centre.y * ct + (u.y * ca + v.y * sa) * st,
    centre.z * ct + (u.z * ca + v.z * sa) * st,
  ).normalized();
}
