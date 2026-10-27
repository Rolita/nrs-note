import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/utils/note_graph.dart';

/// 一条连线上的信号光点。
///
/// 位置不在粒子身上存：每帧从两端的**屏幕坐标**重算，球在转、连线在动，
/// 光点也不会离线。这里只记「从哪到哪、走到哪儿了」。
class OrbPulse {
  OrbPulse({
    required this.a,
    required this.b,
    required this.dir,
    required this.dur,
    required this.wait,
    required this.amp,
    required this.ret,
    this.p = 0,
  });

  /// 起点 / 终点下标（属于当前这张视图）。
  final int a;
  final int b;

  /// 1 = 去程，-1 = 回程。
  final int dir;

  /// 走完整条边的秒数。短线快、长线慢，读起来才像光在赶路。
  final double dur;

  /// 出发前的等待。用来错峰：所有光点同时涌出会像一次闪烁。
  double wait;

  /// 亮度倍率。回程只有去程的三分之一。
  final double amp;

  /// 回程珠子：尾巴更短、更暗，只在抵达后回一颗小点。
  final bool ret;

  /// 0 = 在 [a]，1 = 在 [b]。
  double p;
}

/// 源节点上扩散的一圈光晕。
class OrbPulseRing {
  OrbPulseRing(this.i);

  final int i;
  double t = 0;
}

/// 信号脉冲：悬停源节点后，沿每条相邻连线送一颗光点，抵达再回一条更淡的。
///
/// 和设计稿 `design/graph-cosmos-extra.html` 的第一层一致。没有焦点时也会
/// 自发地挑一颗正面节点送两三条，让静止的球看起来在「呼吸」，而不是一张
/// 冻住的图。
class OrbPulseField {
  final List<OrbPulse> pulses = <OrbPulse>[];
  final List<OrbPulseRing> rings = <OrbPulseRing>[];

  final math.Random _rng = math.Random(20261026);

  /// 当前脉冲源。换源就立刻发一轮新的。
  int source = -1;

  /// 上一轮出发的时刻（秒）。
  double lastAt = -10;

  /// 下一次自发脉冲还有多久（秒）。
  double idleIn = 1.1;

  /// 没有光点也没有光晕——测试据此判断动画可以停表。
  bool get isIdle => pulses.isEmpty && rings.isEmpty;

  void clear() {
    pulses.clear();
    rings.clear();
    source = -1;
    idleIn = 1.1;
  }

  /// 在源节点上震一圈光晕。最多留 8 圈，旧的自然消失。
  void ring(int i) {
    rings.add(OrbPulseRing(i));
    if (rings.length > 8) rings.removeAt(0);
  }

  /// 源节点 → 每条连线一颗光点，再各回一颗更淡的。
  ///
  /// 邻居超过 14 个时按步长抽样：枢纽节点常有三十多条边，全发出去就是一团
  /// 糊住节点本身的光雾。
  void emit(
    NoteGraph graph,
    Float32List sx,
    Float32List sy,
    int idx,
    double strength,
  ) {
    if (idx < 0 || idx >= graph.nodes.length) return;
    final List<int> nb = graph.nodes[idx].neighbours;
    if (nb.isEmpty || sx.length <= idx || sy.length <= idx) return;

    final int step = math.max(1, (nb.length / 14).ceil());
    int k = 0;
    for (int i = 0; i < nb.length; i += step) {
      if (pulses.length > 44) break;
      final int j = nb[i];
      if (j >= sx.length || j >= sy.length) continue;
      final double len = math.sqrt(
        math.pow(sx[j] - sx[idx], 2) + math.pow(sy[j] - sy[idx], 2),
      );
      final double dur = (len / 430).clamp(0.26, 0.85);
      pulses.add(
        OrbPulse(
          a: idx,
          b: j,
          dir: 1,
          dur: dur,
          wait: k * 0.035,
          amp: strength,
          ret: false,
        ),
      );
      // 回程等去程抵达之后再走：先亮过去、再淡淡地收回来。
      pulses.add(
        OrbPulse(
          a: idx,
          b: j,
          dir: -1,
          dur: dur * 1.3,
          wait: dur + 0.30 + k * 0.03,
          amp: strength * 0.34,
          ret: true,
        ),
      );
      k++;
    }
  }

  /// 静止时的自发脉冲：只往五六条随机邻居送，不返回。
  void emitIdle(
    NoteGraph graph,
    Float32List sx,
    Float32List sy,
    int idx,
    double strength,
  ) {
    if (idx < 0 || idx >= graph.nodes.length) return;
    final List<int> nb = graph.nodes[idx].neighbours;
    if (nb.isEmpty || sx.length <= idx || sy.length <= idx) return;

    final int count = math.min(nb.length, 5 + _rng.nextInt(3));
    final Set<int> used = <int>{};
    int made = 0;
    for (int guard = 0; guard < 80 && made < count; guard++) {
      final int j = nb[_rng.nextInt(nb.length)];
      if (j >= sx.length || j >= sy.length || !used.add(j)) continue;
      final double len = math.sqrt(
        math.pow(sx[j] - sx[idx], 2) + math.pow(sy[j] - sy[idx], 2),
      );
      pulses.add(
        OrbPulse(
          a: idx,
          b: j,
          dir: 1,
          dur: (len / 430).clamp(0.26, 0.85),
          wait: made * 0.06,
          amp: strength,
          ret: false,
        ),
      );
      made++;
    }
  }

  /// 没有焦点时，每隔 0.65–1.5 秒挑一颗正面节点自发一次。
  ///
  /// [enabled] 关着时连计时都不走：测试环境不自转，常驻脉冲会让
  /// `pumpAndSettle` 永远等不到下一帧的尽头。
  void tickIdle(
    double dt,
    NoteGraph graph,
    Float32List sx,
    Float32List sy,
    Float32List camZ, {
    required bool enabled,
  }) {
    if (!enabled || graph.isEmpty) return;
    idleIn -= dt;
    if (idleIn > 0) return;
    idleIn = 0.65 + _rng.nextDouble() * 0.85;

    for (int k = 0; k < 10; k++) {
      final int i = _rng.nextInt(graph.nodes.length);
      if (camZ[i] > 0.2 && graph.nodes[i].neighbours.isNotEmpty) {
        emitIdle(graph, sx, sy, i, 0.62 + _rng.nextDouble() * 0.24);
        return;
      }
    }
  }

  /// 推进一步。走出两端的粒子直接删掉。
  void update(double dt) {
    for (int i = pulses.length - 1; i >= 0; i--) {
      final OrbPulse p = pulses[i];
      if (p.wait > 0) {
        p.wait -= dt;
        continue;
      }
      p.p += p.dir * dt / p.dur;
      if (p.p < 0 || p.p > 1) pulses.removeAt(i);
    }
    for (int i = rings.length - 1; i >= 0; i--) {
      final OrbPulseRing r = rings[i];
      r.t += dt;
      if (r.t > 0.8) rings.removeAt(i);
    }
  }
}
