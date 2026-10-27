import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 球体外围的星空背景：离心流星（B 档）。
///
/// 设计原型是 `design/graph-cosmos.html` 的 B 档，参数一比一对齐：
/// 长曝光星轨收着（0.34），离心流星全开（1.0），掠过的环境流星七成
/// （0.7），星云压到 0.55，前景星尘关掉。
///
/// ## 与球体的耦合
///
/// 星场不能自己转。它必须跟球的相机转动**同源**，否则甩一下球，背景
/// 纹丝不动，两层空间会立刻散架。相机每次旋转都调 [advance]：
///
/// ```dart
/// _camera.rotate(pitch, yaw);
/// _cosmos.advance(pitch, yaw);          // skySpin += yaw·0.86 + pitch·0.30
/// ```
///
/// 横向拖动占 86%、纵向占 30%，是原型里试出来的比例：横向甩是主操作，
/// 纵向只给一点，星场才不会像被上下拽着走。星场再按三层视差
/// （0.16 / 0.31 / 0.52）分速度，近层拖得远、远层几乎不动。
///
/// ## 为什么星云和辉光是图片
///
/// 星云由 92 个径向渐变 + 9 个云核 + 14 条暗尘 + 380 颗微光组成。每帧
/// 重画这些渐变是纯浪费——它只随视角缓慢旋转，本身不变。预渲染成一张
/// 方图，之后只是旋转贴图。辉光精灵同理。
///
/// 预渲染走 `Picture.toImage`（异步），测试环境关掉（[allowArt] = false）：
/// 一是不需要，二是 widget 测试里没有真实光栅线程，等异步图片会把
/// `pumpAndSettle` 拖住。没有图片时星点和流星照画，只是少了星云和光晕。
///
/// ## 远景大彗星
///
/// 方案页 `design/graph-cosmos-idle.html` 的第 3 层：开场 4.5 秒来第一颗，
/// 之后 26–44 秒一颗。慢、长、小头，像隔着整个星系。尾巴没有沿用环境
/// 流星那根等宽渐变线——拉到四五百像素会读成一道划痕——改成三条沿速度
/// 方向收细的丝带，见 [_paintBigComet]。
///
/// ## 生命周期
///
/// 没有自己的 Ticker/Timer。所有状态都由 [update] 推进，而 [update] 挂在
/// 图谱已有的 Ticker 上；静止时 Ticker 停，星空也停。这一条是硬约束：
/// 自带常驻动画会让所有 `pumpAndSettle` 永远等不到头。
class CosmosField {
  CosmosField({this.allowArt = true});

  /// 是否生成星云/辉光图片。测试里传 false。
  final bool allowArt;

  /// 星云图片准备好（或被换掉）时回调。图谱用它敲一下重绘。
  VoidCallback? onArtReady;

  static const double _tau = math.pi * 2;
  static const int _seedBase = 20261027;
  static const double _nebulaMode = 0.55;
  static const double _starTrailMode = 0.34;
  static const double _ambientMode = 0.7;

  static const List<Color> _starColors = <Color>[
    Color(0xFFCFE2FF),
    Color(0xFFB2CDFA),
    Color(0xFFE8F1FF),
    Color(0xFFFFE4C4),
  ];

  static const Color _starTrailColor = Color(0xFFCFE2FF);
  static const Color _starGlowColor = Color(0xFFDAEAFF);
  static const Color _warmGlowColor = Color(0xFFFFC692);

  // ------------------------------------------------------------ 随机

  int _seed = _seedBase;

  double _rnd() {
    _seed = (_seed * 1664525 + 1013904223) & 0xFFFFFFFF;
    return _seed / 4294967296.0;
  }

  // ------------------------------------------------------------ 几何

  Size _size = Size.zero;
  double _baseR = 0;
  double _maxRad = 0;
  double _diag = 0;

  final List<_StarLayer> _layers = <_StarLayer>[];

  @visibleForTesting
  int get debugStarCount =>
      _layers.fold(0, (int sum, _StarLayer l) => sum + l.stars.length);

  /// 舞台尺寸或基准球半径变了才重建星场。
  ///
  /// [baseRadius] 是**没乘缩放**的球半径（图谱的 `_sphereRadius`）。星点
  /// 半径按它和屏幕对角线撒，画的时候再乘一个天空缩放系数，见
  /// [_paintStars]。
  void resize(Size size, double baseRadius) {
    if (_disposed) return;
    if (size.width <= 0 || size.height <= 0) return;
    final bool same =
        (size.width - _size.width).abs() < 0.01 &&
        (size.height - _size.height).abs() < 0.01 &&
        (baseRadius - _baseR).abs() < 0.01;
    if (same) return;

    _size = size;
    _baseR = baseRadius;
    _diag = math.sqrt(size.width * size.width + size.height * size.height);
    _maxRad = _diag * 0.5;

    _buildStars();

    // 星云图是方形的，尺寸跟屏幕对角线走；差十几像素不值得重做。
    if (_artDiag <= 0 || (_diag - _artDiag).abs() > 16) {
      _artDiag = _diag;
      _artDirty = true;
      // 让正在生成的那张作废，完成后会自己 dispose。
      _artToken++;
      _artPending = false;
    }
  }

  void _buildStars() {
    // 固定种子：每次 resize 星点的相对分布一致，只是按新尺寸拉开。
    _seed = _seedBase;
    _layers.clear();
    if (_baseR <= 0 || _maxRad <= 0) return;

    final double rMin = _baseR * 1.08;
    final double rMax = _maxRad * 1.06;
    // 星点撒在「圆环面积」上，不能按半径均匀——否则内圈会挤成一团。
    final double span = rMax * rMax - rMin * rMin;
    if (span <= 0) return;

    const List<_StarCfg> cfg = <_StarCfg>[
      _StarCfg(0.16, 380, 0.45, 1.25, 0.16, 0.62, 0.04),
      _StarCfg(0.31, 150, 0.65, 1.65, 0.24, 0.80, 0.10),
      _StarCfg(0.52, 40, 0.9, 2.0, 0.32, 0.88, 0.24),
    ];

    for (final _StarCfg c in cfg) {
      final _StarLayer layer = _StarLayer(c.factor);
      double sumAlpha = 0;
      double sumSize = 0;
      for (int i = 0; i < c.count; i++) {
        final _Star st = _Star(
          angle: _rnd() * _tau,
          r: math.sqrt(rMin * rMin + _rnd() * span),
          size:
              c.sizeMin +
              math.pow(_rnd(), 1.6).toDouble() * (c.sizeMax - c.sizeMin),
          alpha:
              c.aMin + math.pow(_rnd(), 1.4).toDouble() * (c.aMax - c.aMin),
          twSpeed: 0.25 + _rnd() * 1.15,
          twPhase: _rnd() * _tau,
          color: _starColors[(_rnd() * _starColors.length).floor()],
          bright: _rnd() < c.bright,
        );
        layer.stars.add(st);
        sumAlpha += st.alpha;
        sumSize += st.size;
      }
      layer.avgAlpha = layer.stars.isEmpty
          ? 0.5
          : sumAlpha / layer.stars.length;
      layer.avgSize = layer.stars.isEmpty ? 1 : sumSize / layer.stars.length;
      _layers.add(layer);
    }
  }

  // ------------------------------------------------------------ 天空耦合

  double _skySpin = 0;
  double _skyShown = 0;
  double _prevSpin = 0;
  double _skyRate = 0;
  double _trailKick = 0;
  int _trailDir = 1;
  double _clock = 0;
  double _intro = 0;

  /// 相机转了多少，星场就跟着转多少。
  ///
  /// 比例 0.86 / 0.30 见类注释。调用点在相机旋转的**同一处**，不能靠每帧
  /// 读相机矩阵反推：反推拿到的是「上一帧到这一帧」的总量，拖拽时指针
  /// 事件和帧率不同步，星场会一顿一顿地追。
  void advance(double pitch, double yaw) {
    if (_disposed) return;
    _skySpin += yaw * 0.86 + pitch * 0.30;
  }

  @visibleForTesting
  double get debugSkySpin => _skySpin;

  @visibleForTesting
  double get debugSkyShown => _skyShown;

  @visibleForTesting
  double get debugSkyRate => _skyRate;

  @visibleForTesting
  int get debugMeteorCount => _meteors.length;

  @visibleForTesting
  int get debugAmbientCount => _ambients.length;

  @visibleForTesting
  int get debugBigCount => _ambients.where((_Ambient a) => a.big).length;

  @visibleForTesting
  int get debugSparkCount => _sparks.length;

  // ------------------------------------------------------------ 流星状态

  /// 一圈绕着球心飞的流星。半径存**屏幕像素**，不存 R 的倍数：它的寿命
  /// 只有一两秒，缩放在这期间变了也无所谓；存倍数反而要在每帧乘一个
  /// 会变的半径，尾巴会被拉得忽长忽短。
  final List<_Meteor> _meteors = <_Meteor>[];
  final List<_Ambient> _ambients = <_Ambient>[];
  final List<_Spark> _sparks = <_Spark>[];

  double _spawnAcc = 0;
  double _ambientIn = 2.8;
  double _idleCometIn = 5.0;
  double _bigCometIn = 4.5;
  double _dragAcc = 0;

  /// 指针拖拽时调：攒够 96px 甩出一颗贴边流星，顺便把星轨踢起来。
  void drag(double dx, double dy, double radius) {
    if (_disposed) return;
    if (dx != 0) _trailDir = dx > 0 ? 1 : -1;
    _trailKick = math.min(
      1,
      _trailKick + dx.abs() * 0.007 + dy.abs() * 0.002,
    );
    // 按累计距离，不按单个事件：高采样率鼠标一帧能发好几个小位移，
    // 只看单次大于 13px 的话，慢慢拖永远不会掉流星。
    _dragAcc += dx.abs();
    while (_dragAcc > 96) {
      _dragAcc -= 96;
      _spawnOrbital(
        radius: radius,
        dir: dx > 0 ? 1 : -1,
        radiusFactor: 1.05 + _rnd() * 0.06,
        drift: 18 + _rnd() * 30,
        life: 0.5 + _rnd() * 0.3,
        width: 0.5 + _rnd() * 0.45,
        alpha: 0.6 + _rnd() * 0.3,
      );
    }
  }

  /// 松手时调：速度够大就沿甩动方向炸一圈流星。
  void release(double velX, double velY, double radius) {
    if (_disposed) return;
    final double mag = math.sqrt(velX * velX + velY * velY);
    if (mag < 0.02) return;
    if (mag > 0.30) {
      final int dir = velY.abs() > velX.abs()
          ? (velY > 0 ? 1 : -1)
          : (velX > 0 ? 1 : -1);
      _trailDir = dir;
      _spawnBurst(
        (mag * 0.85).clamp(0.5, 1.3).toDouble(),
        dir,
        radius,
      );
    }
    _trailKick = math.min(1, _trailKick + (mag * 0.55).clamp(0.0, 0.9));
  }

  /// 每一帧推一次。挂在图谱的 Ticker 上，静止时不会被调用。
  ///
  /// [velX] 是相机的俯仰角速度（纵向拖），[velY] 是偏航角速度（横向拖），
  /// 和图谱的字段同义。[dragging] 为真时不按惯性撒流星——拖拽中的方向
  /// 由 [drag] 负责，否则两种方向会打架。
  void update(
    double dt, {
    required double velX,
    required double velY,
    required bool dragging,
    required double radius,
  }) {
    if (_disposed || dt <= 0) return;

    _clock += dt;
    _intro = math.min(1, _intro + dt / 1.1);

    final double raw = (_skySpin - _prevSpin) / math.max(dt, 0.0001);
    _prevSpin = _skySpin;
    _skyRate += (raw - _skyRate) * (1 - math.exp(-dt * 8));
    _skyRate = _skyRate.clamp(-2.6, 2.6);
    _skyShown += (_skySpin - _skyShown) * (1 - math.exp(-dt * 15));

    _trailKick *= math.exp(-dt * 3.1);
    if (_trailKick < 0.002) _trailKick = 0;

    if (velY.abs() > 0.22) _trailDir = velY > 0 ? 1 : -1;

    if (!dragging) {
      final double w = velY.abs() + velX.abs() * 0.5;
      if (w > 0.42) {
        _spawnAcc += dt * w * 10;
        while (_spawnAcc >= 1) {
          _spawnAcc -= 1;
          _spawnOrbital(
            radius: radius,
            dir: velY < 0 ? -1 : 1,
            radiusFactor: 1.18 + _rnd() * 0.95,
            drift: -4 + _rnd() * 26,
            life: 0.9 + _rnd() * 0.55,
            width: 0.6 + _rnd() * 0.75,
            alpha: 0.45 + _rnd() * 0.4,
          );
        }
      } else {
        _spawnAcc = 0;
      }
    } else {
      _spawnAcc = 0;
    }

    // 静止时也有东西看：偶发一颗慢速彗星，以及从画布外掠过的环境流星。
    _idleCometIn -= dt;
    if (_idleCometIn <= 0) {
      _idleCometIn = 8 + _rnd() * 9;
      _spawnOrbital(
        radius: radius,
        dir: _rnd() < 0.5 ? -1 : 1,
        slow: true,
        life: 2.5 + _rnd() * 0.7,
        width: 0.55,
        alpha: 0.55,
        drift: 0.6,
        warm: false,
      );
    }

    _ambientIn -= dt;
    if (_ambientIn <= 0) {
      _ambientIn = (2.8 + _rnd() * 4.6) / _ambientMode;
      _spawnAmbient(radius);
    }

    // 远景大彗星不看拖拽：它远得跟球的惯性无关，安静地慢慢横穿。
    _bigCometIn -= dt;
    if (_bigCometIn <= 0) {
      _bigCometIn = 26 + _rnd() * 18;
      _spawnAmbient(radius, big: true);
    }

    _stepMeteors(dt);
    _stepAmbients(dt);
    _stepSparks(dt);
  }

  void _stepMeteors(double dt) {
    final double cx = _size.width / 2;
    final double cy = _size.height / 2;
    for (int i = _meteors.length - 1; i >= 0; i--) {
      final _Meteor m = _meteors[i];
      m.t += dt;
      m.theta += m.spin * dt;
      m.radius += m.drift * dt;
      m.sparkAcc += dt * 9;
      if (m.sparkAcc >= 1) {
        m.sparkAcc -= 1;
        final double hx = cx + math.cos(m.theta) * m.radius;
        final double hy = cy + math.sin(m.theta) * m.radius;
        final double outward = (_rnd() - 0.5) * 30;
        final double tx = -math.sin(m.theta) * m.spin;
        final double ty = math.cos(m.theta) * m.spin;
        _spawnSpark(
          hx,
          hy,
          math.cos(m.theta) * outward + tx * 18,
          math.sin(m.theta) * outward + ty * 18,
          m.warm,
          0.5 * m.alpha,
        );
      }
      if (m.t >= m.life) _meteors.removeAt(i);
    }
  }

  void _stepAmbients(double dt) {
    for (int i = _ambients.length - 1; i >= 0; i--) {
      final _Ambient a = _ambients[i];
      a.t += dt;
      a.x += a.vx * dt;
      a.y += a.vy * dt;
      if (a.t >= a.life) _ambients.removeAt(i);
    }
  }

  void _stepSparks(double dt) {
    for (int i = _sparks.length - 1; i >= 0; i--) {
      final _Spark s = _sparks[i];
      s.t += dt;
      s.x += s.vx * dt;
      s.y += s.vy * dt;
      final double damp = math.exp(-dt * 2.4);
      s.vx *= damp;
      s.vy *= damp;
      if (s.t >= s.life) _sparks.removeAt(i);
    }
  }

  void _spawnOrbital({
    required double radius,
    int dir = 1,
    bool slow = false,
    double? theta,
    double? radiusFactor,
    double? drift,
    double? life,
    double? width,
    bool? warm,
    double alpha = 1,
  }) {
    final double r = radius > 0 ? radius : 1;
    _meteors.add(
      _Meteor(
        theta: theta ?? _rnd() * _tau,
        radius:
            r *
            (radiusFactor ??
                (slow ? 1.13 + _rnd() * 0.06 : 1.085 + _rnd() * 0.15)),
        spin: dir * (slow ? 0.24 : (0.48 + _rnd() * 0.85)),
        drift: drift ?? (slow ? 1.0 : 10 + _rnd() * 34),
        life: life ?? (0.9 + _rnd() * 0.55),
        width: width ?? (0.8 + _rnd() * 1.0),
        alpha: alpha,
        warm: warm ?? (_rnd() < 0.11),
      ),
    );
    if (_meteors.length > 90) _meteors.removeAt(0);
  }

  /// 甩出去的一圈：贴边的短火星交代「从球上出来」，外围的长流星负责气势。
  ///
  /// 外围半径刻意拉到 1.35–2.25R：贴着轮廓走的流星会被读成「第二圈
  ///  Atmosphere」，原型里踩过这个坑。
  void _spawnBurst(double power, int dir, double radius) {
    final int closeCount = (4 + power * 3).round().clamp(4, 8);
    for (int k = 0; k < closeCount; k++) {
      _spawnOrbital(
        radius: radius,
        theta: _rnd() * _tau,
        dir: dir,
        radiusFactor: 1.055 + _rnd() * 0.07,
        drift: 16 + _rnd() * 34,
        life: 0.55 + _rnd() * 0.35,
        width: 0.55 + _rnd() * 0.5,
        alpha: 0.7 + _rnd() * 0.3,
        warm: _rnd() < 0.10,
      );
    }

    final int outerCount = (5 + power * 6).round().clamp(5, 12);
    for (int j = 0; j < outerCount; j++) {
      _spawnOrbital(
        radius: radius,
        theta: _rnd() * _tau,
        dir: dir,
        radiusFactor: 1.35 + _rnd() * 0.90,
        drift: -8 + _rnd() * 32,
        life: 1.0 + _rnd() * 0.8,
        width: 0.65 + _rnd() * 0.9,
        alpha: 0.5 + _rnd() * 0.45,
        warm: _rnd() < 0.12,
      );
    }

    _trailKick = math.min(1, _trailKick + 0.55 + power * 0.35);
  }

  /// 环境流星：从画布外斜穿而过。`big` 是远景大彗星——起得更远、慢四倍、
  /// 尾巴四倍长，头却更小更淡。
  void _spawnAmbient(double radius, {bool big = false}) {
    final double a = _rnd() * _tau;
    final double dist =
        radius * (big ? 1.45 + _rnd() * 0.75 : 1.35 + _rnd() * 0.85);
    final int dir = _rnd() < 0.5 ? 1 : -1;
    final double speed = big ? 165 + _rnd() * 75 : 480 + _rnd() * 320;
    final double ux = -math.sin(a) * dir;
    final double uy = math.cos(a) * dir;
    final double back = math.max(_size.width, _size.height) *
        (big ? 0.25 + _rnd() * 0.10 : 0.35 + _rnd() * 0.10);
    final double cx = _size.width / 2;
    final double cy = _size.height / 2;

    _ambients.add(
      _Ambient(
        x: cx + math.cos(a) * dist - ux * back,
        y: cy + math.sin(a) * dist - uy * back,
        vx: ux * speed,
        vy: uy * speed,
        life: big ? 4.8 + _rnd() * 1.2 : 1.7 + _rnd() * 0.9,
        len: big ? 450 + _rnd() * 220 : 110 + _rnd() * 160,
        width: big ? 1.8 + _rnd() * 0.9 : 0.8 + _rnd() * 0.9,
        alpha: big ? 0.46 + _rnd() * 0.12 : 0.45 + _rnd() * 0.4,
        warm: _rnd() < (big ? 0.25 : 0.10),
        big: big,
      ),
    );
    if (_ambients.length > (big ? 10 : 8)) _ambients.removeAt(0);
  }

  void _spawnSpark(
    double x,
    double y,
    double vx,
    double vy,
    bool warm,
    double alpha,
  ) {
    if (_sparks.length > 150) return;
    _sparks.add(
      _Spark(
        x: x,
        y: y,
        vx: vx + (_rnd() * 2 - 1) * 24,
        vy: vy + (_rnd() * 2 - 1) * 24,
        life: 0.28 + _rnd() * 0.5,
        size: 0.5 + _rnd() * 1.1,
        alpha: alpha,
        warm: warm,
      ),
    );
  }

  // ------------------------------------------------------------ 预渲染

  _CosmosArt? _art;
  bool _artDirty = true;
  bool _artPending = false;
  int _artToken = 0;
  double _artDiag = 0;
  bool _disposed = false;

  bool get _artReady => _art != null;

  /// 生成星云和两张辉光精灵。只在有真实光栅线程的环境里调用。
  void ensureArt() {
    if (!allowArt || _disposed || !_artDirty || _artPending) return;
    if (_size.width <= 0 || _size.height <= 0) return;
    _artPending = true;
    final int token = ++_artToken;
    _makeArt().then((_CosmosArt? art) {
      if (art == null) {
        if (token == _artToken) _artPending = false;
        return;
      }
      if (_disposed || token != _artToken) {
        art.dispose();
        return;
      }
      _art?.dispose();
      _art = art;
      _artPending = false;
      _artDirty = false;
      onArtReady?.call();
    });
  }

  Future<_CosmosArt?> _makeArt() async {
    final double diag = _diag;
    if (diag <= 0) return null;
    // 1600 封顶：再大也只是把一张柔和的雾拉伸得更细，内存却翻倍。
    final int px = math.min(1600, math.max(320, (diag * 1.12).ceil()));
    ui.Image? nebula;
    ui.Image? starGlow;
    ui.Image? warmGlow;
    try {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas canvas = Canvas(rec);
      _paintNebulaArt(canvas, px.toDouble());
      final ui.Picture pic = rec.endRecording();
      nebula = await pic.toImage(px, px);
      pic.dispose();
      starGlow = await _makeGlowSprite(_starGlowColor);
      warmGlow = await _makeGlowSprite(_warmGlowColor);
      return _CosmosArt(nebula, starGlow, warmGlow);
    } catch (_) {
      nebula?.dispose();
      starGlow?.dispose();
      warmGlow?.dispose();
      return null;
    }
  }

  static Future<ui.Image> _makeGlowSprite(Color color) async {
    const double s = 64;
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final Canvas canvas = Canvas(rec);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, s, s),
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(s / 2, s / 2),
          s / 2,
          <Color>[
            color.withValues(alpha: 1),
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.045),
            color.withValues(alpha: 0),
          ],
          <double>[0, 0.16, 0.38, 0.66, 1],
        ),
    );
    final ui.Picture pic = rec.endRecording();
    final ui.Image img = await pic.toImage(64, 64);
    pic.dispose();
    return img;
  }

  /// 星云底图：一条斜着的云带，带几处亮核、几条暗尘和细碎微光。
  ///
  /// 和星场的随机数是分开的（固定种子 7717），否则改星星数量会把星云
  /// 整个换一张脸。
  static void _paintNebulaArt(Canvas canvas, double s) {
    final double mid = s / 2;
    const double axis = -0.42;
    final double ax = math.cos(axis), ay = math.sin(axis);
    final double px = -ay, py = ax;

    int seed = 7717;
    double rnd() {
      seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
      return seed / 4294967296.0;
    }

    double gauss() {
      double u = 0, v = 0;
      while (u == 0) {
        u = rnd();
      }
      while (v == 0) {
        v = rnd();
      }
      return math.sqrt(-2 * math.log(u)) * math.cos(_tau * v);
    }

    const List<List<int>> palette = <List<int>>[
      <int>[74, 108, 196],
      <int>[52, 142, 168],
      <int>[112, 78, 178],
      <int>[70, 110, 190],
      <int>[46, 126, 154],
      <int>[96, 70, 168],
      <int>[180, 136, 104],
    ];

    for (int i = 0; i < 92; i++) {
      final double along = (rnd() * 2 - 1) * s * 0.40;
      final double perp = gauss() * s * (0.055 + rnd() * 0.055);
      final double x = mid + ax * along + px * perp;
      final double y = mid + ay * along + py * perp;
      final double rad = s * (0.035 + math.pow(rnd(), 1.8).toDouble() * 0.13);
      final List<int> col = palette[(rnd() * palette.length).floor()];
      final double alpha = 0.032 + rnd() * 0.052;
      final Color c = Color.fromARGB(255, col[0], col[1], col[2]);
      canvas.drawRect(
        Rect.fromLTWH(x - rad, y - rad, rad * 2, rad * 2),
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(
            Offset(x, y),
            rad,
            <Color>[
              c.withValues(alpha: alpha),
              c.withValues(alpha: alpha * 0.55),
              c.withValues(alpha: 0),
            ],
            <double>[0, 0.45, 1],
          ),
      );
    }

    // 亮核：让云带有落点，不是一条均匀的带子。
    for (int n = 0; n < 9; n++) {
      final double na = (rnd() * 2 - 1) * s * 0.30;
      final double np = gauss() * s * 0.04;
      final double nx = mid + ax * na + px * np;
      final double ny = mid + ay * na + py * np;
      final double nr = s * (0.022 + rnd() * 0.04);
      final List<int> col = palette[(rnd() * 3).floor()];
      final double alpha = 0.052 + rnd() * 0.058;
      final Color c = Color.fromARGB(255, col[0], col[1], col[2]);
      canvas.drawRect(
        Rect.fromLTWH(nx - nr, ny - nr, nr * 2, nr * 2),
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(
            Offset(nx, ny),
            nr,
            <Color>[c.withValues(alpha: alpha), c.withValues(alpha: 0)],
            <double>[0, 1],
          ),
      );
    }

    // 暗尘：挖掉几条低透明度，星云才不是一团均匀的雾。
    for (int k = 0; k < 14; k++) {
      final double la = (rnd() * 2 - 1) * s * 0.22;
      final double lp = gauss() * s * 0.03;
      final double lx = mid + ax * la + px * lp;
      final double ly = mid + ay * la + py * lp;
      final double lr = s * (0.025 + rnd() * 0.06);
      canvas.drawRect(
        Rect.fromLTWH(lx - lr, ly - lr, lr * 2, lr * 2),
        Paint()
          ..blendMode = BlendMode.dstOut
          ..shader = ui.Gradient.radial(
            Offset(lx, ly),
            lr,
            const <Color>[
              Color.fromRGBO(0, 0, 0, 0.18),
              Color.fromRGBO(0, 0, 0, 0),
            ],
            <double>[0, 1],
          ),
      );
    }

    // 细碎微光：放大时星云里也不至于空。
    final Paint dust = Paint()
      ..blendMode = BlendMode.plus
      ..color = const Color(0xFFC4DAFF);
    for (int q = 0; q < 380; q++) {
      final double along = (rnd() * 2 - 1) * s * 0.44;
      final double perp = gauss() * s * 0.085;
      final double x = mid + ax * along + px * perp;
      final double y = mid + ay * along + py * perp;
      dust.color = const Color(0xFFC4DAFF).withValues(
        alpha: 0.018 + rnd() * 0.05,
      );
      canvas.drawCircle(Offset(x, y), 0.5 + rnd() * 0.8, dust);
    }
  }

  void dispose() {
    _disposed = true;
    _artToken++;
    _art?.dispose();
    _art = null;
    onArtReady = null;
  }

  // ------------------------------------------------------------ 绘制

  final Paint _starFill = Paint()
    ..isAntiAlias = true
    ..blendMode = BlendMode.plus;
  final Paint _starStroke = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..blendMode = BlendMode.plus;
  final Paint _image = Paint()
    ..isAntiAlias = true
    ..filterQuality = FilterQuality.low
    ..blendMode = BlendMode.plus;
  final Paint _meteorFill = Paint()
    ..isAntiAlias = true
    ..blendMode = BlendMode.plus;
  final Paint _meteorStroke = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..blendMode = BlendMode.plus;

  /// 星云、星场、环境流星、暗角。画在画布渐变之上、大气层之下。
  void paintSky(Canvas canvas, Size size, {required double radius}) {
    if (_disposed) return;
    final double fade = _introEase;
    if (fade <= 0.002) return;
    final Offset centre = Offset(size.width / 2, size.height / 2);
    _paintNebula(canvas, centre, fade);
    _paintStars(canvas, centre, size, radius, fade);
    _paintAmbient(canvas, fade);
    _paintVignette(canvas, size, centre, radius, fade);
  }

  double get _introEase {
    final double t = _intro;
    return 1 - math.pow(1 - t, 3).toDouble();
  }

  void _paintNebula(Canvas canvas, Offset centre, double fade) {
    final _CosmosArt? art = _art;
    if (art == null) return;
    final double s = _diag * 1.12;
    if (s <= 0) return;
    _image.color = const Color(0xFFFFFFFF).withValues(
      alpha: fade * 0.95 * _nebulaMode,
    );
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.rotate(_skyShown * 0.026 - 0.06);
    canvas.drawImageRect(
      art.nebula,
      Rect.fromLTWH(
        0,
        0,
        art.nebula.width.toDouble(),
        art.nebula.height.toDouble(),
      ),
      Rect.fromCenter(center: Offset.zero, width: s, height: s),
      _image,
    );
    canvas.restore();
  }

  void _paintStars(
    Canvas canvas,
    Offset centre,
    Size size,
    double radius,
    double fade,
  ) {
    if (_layers.isEmpty || _baseR <= 0) return;

    // 星空缩放：100% 时和球同倍；缩小时至少保留 0.75，别让星星全缩到
    // 球边上，四周空成一块黑。星星永远不画进球轮廓以内（半径 < 1.02R）。
    final double skyScale = math.max(radius / _baseR, 0.75);
    final double kick =
        _skyRate.abs() * 1.15 + _trailKick * 1.5;
    final bool glow = _artReady;

    for (final _StarLayer layer in _layers) {
      final double offset = _skyShown * layer.factor;
      final double layerRate = kick * layer.factor;
      final double trail =
          ((layerRate - 0.042) * 0.90).clamp(0.0, 0.30) * _starTrailMode;
      final double trailAlpha =
          ((layerRate - 0.038) * 3.0).clamp(0.0, 0.70) * _starTrailMode;
      final double dotDim = 1 - 0.22 * (layerRate * 1.2).clamp(0.0, 1.0);

      if (trail > 0.0012 && trailAlpha > 0.005) {
        _starStroke
          ..strokeWidth = math.max(0.5, layer.avgSize * 0.82)
          ..color = _starTrailColor.withValues(
            alpha: math.min(0.8, layer.avgAlpha * trailAlpha * fade),
          );
        // 拖尾用三层各一条 Path：逐星 stroke 会多出上百次原生调用，
        // 而同层的透明度本来就近，合成一条看不出差别。
        final Path path = Path();
        for (final _Star st in layer.stars) {
          final double a = st.angle + offset;
          final double r = st.r * skyScale;
          // 1.08R 是星场的内边界，也是大气层外缘（1.075R）之外一点。
          // 缩小时星场不能跟着缩进球里，画在光晕上会像脏点。
          if (r < radius * 1.08) continue;
          final double x = centre.dx + math.cos(a) * r;
          final double y = centre.dy + math.sin(a) * r;
          if (x < -30 ||
              x > size.width + 30 ||
              y < -30 ||
              y > size.height + 30) {
            continue;
          }
          path.addArc(
            Rect.fromCircle(center: centre, radius: r),
            _trailDir >= 0 ? a - trail : a,
            trail,
          );
        }
        canvas.drawPath(path, _starStroke);
      }

      for (final _Star st in layer.stars) {
        final double a = st.angle + offset;
        final double r = st.r * skyScale;
        if (r < radius * 1.08) continue;
        final double x = centre.dx + math.cos(a) * r;
        final double y = centre.dy + math.sin(a) * r;
        if (x < -30 ||
            x > size.width + 30 ||
            y < -30 ||
            y > size.height + 30) {
          continue;
        }

        final double tw =
            0.74 + 0.26 * math.sin(_clock * st.twSpeed + st.twPhase);
        final double alpha = st.alpha * tw * fade;
        _starFill.color = st.color.withValues(
          alpha: math.min(0.92, alpha * dotDim),
        );
        if (st.size < 1.15) {
          canvas.drawRect(
            Rect.fromLTWH(
              x - st.size / 2,
              y - st.size / 2,
              st.size,
              st.size,
            ),
            _starFill,
          );
        } else {
          canvas.drawCircle(Offset(x, y), st.size * 0.62, _starFill);
        }

        if (st.bright && glow) {
          final _CosmosArt art = _art!;
          final double gr = st.size * 8.5;
          _image.color = const Color(0xFFFFFFFF).withValues(
            alpha: math.min(0.6, alpha * 0.5),
          );
          canvas.drawImageRect(
            art.starGlow,
            Rect.fromLTWH(
              0,
              0,
              art.starGlow.width.toDouble(),
              art.starGlow.height.toDouble(),
            ),
            Rect.fromCenter(center: Offset(x, y), width: gr * 2, height: gr * 2),
            _image,
          );
        }
      }
    }
  }

  void _paintAmbient(Canvas canvas, double fade) {
    if (_ambients.isEmpty) return;
    final _CosmosArt? art = _art;
    for (final _Ambient m in _ambients) {
      final double env =
          _smooth(0, 0.1, m.t) * (1 - _smooth(m.life * 0.7, m.life, m.t));
      if (env <= 0.002) continue;
      final double v = math.sqrt(m.vx * m.vx + m.vy * m.vy);
      final double inv = v <= 1e-6 ? 0 : 1 / v;
      final double ux = m.vx * inv;
      final double uy = m.vy * inv;
      final double tx = m.x - ux * m.len;
      final double ty = m.y - uy * m.len;
      final Color core = m.warm
          ? const Color(0xFFFFE2B6)
          : const Color(0xFFCAE2FF);

      if (m.big) {
        _paintBigComet(canvas, m, core, ux, uy, env, fade);
        continue;
      }

      canvas.drawLine(
        Offset(m.x, m.y),
        Offset(tx, ty),
        Paint()
          ..isAntiAlias = true
          ..blendMode = BlendMode.plus
          ..strokeCap = StrokeCap.round
          ..strokeWidth = m.width
          ..shader = ui.Gradient.linear(
            Offset(m.x, m.y),
            Offset(tx, ty),
            <Color>[
              core.withValues(alpha: 0.72 * env * m.alpha * fade),
              core.withValues(alpha: 0.22 * env * m.alpha * fade),
              core.withValues(alpha: 0),
            ],
            <double>[0, 0.35, 1],
          ),
      );

      if (art != null) {
        final double gr = 7 + m.width * 4;
        _image.color = const Color(0xFFFFFFFF).withValues(
          alpha: 0.38 * env * m.alpha * fade,
        );
        canvas.drawImageRect(
          art.starGlow,
          Rect.fromLTWH(
            0,
            0,
            art.starGlow.width.toDouble(),
            art.starGlow.height.toDouble(),
          ),
          Rect.fromCenter(center: Offset(m.x, m.y), width: gr * 2, height: gr * 2),
          _image,
        );
      }
    }
  }

  /// 大彗星的尾巴。原型是一根等宽渐变线，拉到四五百像素长会读成一道
  /// 划痕：头尾一样粗，末端一刀切。这里拆成三条沿速度方向收细的丝带——
  /// 宽柔光 / 窄柔光 / 芯线，宽度按 s^0.8 收到零，纵向五段淡出（18% 处
  /// 五成、42% 处两成半、72% 处不足一成）：轮廓和亮度同时消失，尾端和
  /// 两侧都不会有硬边，尾巴中段也没有三段渐变的亮度拐点。
  void _paintBigComet(
    Canvas canvas,
    _Ambient m,
    Color core,
    double ux,
    double uy,
    double env,
    double fade,
  ) {
    final double a0 = env * m.alpha * fade;
    final double px = -uy;
    final double py = ux;
    final double len = m.len;
    final Offset head = Offset(m.x, m.y);
    final Offset tip = Offset(m.x - ux * len, m.y - uy * len);

    void ribbon(double headW, double tipW, double headA) {
      const int steps = 10;
      double halfAt(double s) =>
          (headW + (tipW - headW) * math.pow(s, 0.8).toDouble()) * 0.5;

      final Path path = Path();
      for (int i = 0; i <= steps; i++) {
        final double s = i / steps;
        final double o = halfAt(s);
        final double x = m.x - ux * len * s;
        final double y = m.y - uy * len * s;
        if (i == 0) {
          path.moveTo(x + px * o, y + py * o);
        } else {
          path.lineTo(x + px * o, y + py * o);
        }
      }
      for (int i = steps; i >= 0; i--) {
        final double s = i / steps;
        final double o = halfAt(s);
        path.lineTo(m.x - ux * len * s - px * o, m.y - uy * len * s - py * o);
      }
      path.close();

      canvas.drawPath(
        path,
        Paint()
          ..isAntiAlias = true
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.linear(
            head,
            tip,
            <Color>[
              core.withValues(alpha: headA * a0),
              core.withValues(alpha: headA * 0.50 * a0),
              core.withValues(alpha: headA * 0.24 * a0),
              core.withValues(alpha: headA * 0.08 * a0),
              core.withValues(alpha: 0),
            ],
            <double>[0, 0.18, 0.42, 0.72, 1],
          ),
      );
    }

    ribbon(m.width * 5.5, 0, 0.075);
    ribbon(m.width * 2.4, m.width * 0.1, 0.16);
    ribbon(m.width, m.width * 0.06, 0.72);

    final _CosmosArt? art = _art;
    if (art != null) {
      final double gr = 16 + m.width * 8;
      _image.color = const Color(0xFFFFFFFF).withValues(alpha: 0.62 * a0);
      canvas.drawImageRect(
        art.starGlow,
        Rect.fromLTWH(
          0,
          0,
          art.starGlow.width.toDouble(),
          art.starGlow.height.toDouble(),
        ),
        Rect.fromCenter(center: head, width: gr * 2, height: gr * 2),
        _image,
      );
    }
    _meteorFill.color = core.withValues(alpha: 0.7 * a0);
    canvas.drawCircle(head, 1.8 + m.width * 0.6, _meteorFill);
  }

  void _paintVignette(
    Canvas canvas,
    Size size,
    Offset centre,
    double radius,
    double fade,
  ) {
    final double outer = _maxRad * 1.02;
    final double inner = radius * 0.55;
    if (outer <= 0 || outer <= inner + 1) return;
    // 原型是「内半径 0.55R、外半径 1.02 maxRad」的环形渐变；Flutter 的
    // radial 没有内半径，把内圈折算成前几个 stop。
    final double prefix = inner / outer;
    final Color base = const Color(0xFF020408);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          centre,
          outer,
          <Color>[
            base.withValues(alpha: 0),
            base.withValues(alpha: 0),
            base.withValues(alpha: 0.06 * fade),
            base.withValues(alpha: 0.24 * fade),
            base.withValues(alpha: 0.46 * fade),
          ],
          <double>[
            0,
            prefix,
            prefix + 0.55 * (1 - prefix),
            prefix + 0.82 * (1 - prefix),
            1,
          ],
        ),
    );
  }

  /// 绕球的流星和火星。画在节点之后、标签之前：流星从球面甩出去，
  /// 压在节点上才像「从球上出来」，而标签必须永远最后画。
  void paintMeteors(Canvas canvas, Size size) {
    if (_disposed) return;
    if (_meteors.isEmpty && _sparks.isEmpty) return;
    final double fade = _introEase;
    if (fade <= 0.002) return;

    final Offset centre = Offset(size.width / 2, size.height / 2);
    for (final _Meteor m in _meteors) {
      final double env =
          _smooth(0, 0.09, m.t) *
          (1 - _smooth(m.life * 0.68, m.life, m.t));
      if (env <= 0.003) continue;

      final double grow = _smooth(0, 0.16, m.t);
      final double tailTime =
          (m.spin.abs() * 0.75).clamp(0.08, 0.80) * grow;
      const int steps = 14;
      for (int k = 0; k <= steps; k++) {
        final double age = tailTime * (k / steps);
        final double th = m.theta - m.spin * age;
        final double rad = m.radius - m.drift * age;
        _pts[k * 2] = centre.dx + math.cos(th) * rad;
        _pts[k * 2 + 1] = centre.dy + math.sin(th) * rad;
      }

      final double hx = _pts[0];
      final double hy = _pts[1];
      final Color glow = m.warm
          ? const Color(0xFFFFB26E)
          : const Color(0xFF7EB4FF);
      final Color core = m.warm
          ? const Color(0xFFFFECCA)
          : const Color(0xFFEAF5FF);
      final double a = env * m.alpha * fade;
      final _CosmosArt? art = _art;

      // 外层宽光：让整条尾巴从背景里浮出来，而不是一根等宽的光管。
      _meteorStroke
        ..strokeWidth = m.width * 5.0
        ..color = glow.withValues(alpha: 0.055 * a);
      canvas.drawPath(_meteorPath(0, steps), _meteorStroke);

      // 尾巴分 6 段收细、变淡。
      const int chunks = 6;
      for (int c = 0; c < chunks; c++) {
        final int s0 = (c * steps) ~/ chunks;
        final int s1 = math.min(steps, ((c + 1) * steps) ~/ chunks + 1);
        final double fall = 1 - c / chunks;
        _meteorStroke
          ..strokeWidth = math.max(0.45, m.width * (0.3 + 1.8 * fall))
          ..color = (c < 2 ? core : glow).withValues(
            alpha: 0.62 * math.pow(fall, 1.7).toDouble() * a,
          );
        canvas.drawPath(_meteorPath(s0, s1), _meteorStroke);
      }

      // 头部：光晕 + 实心白核，甩出去的方向一眼能读出来。
      if (art != null) {
        final double hr = 9 + m.width * 6;
        final ui.Image sprite = m.warm ? art.warmGlow : art.starGlow;
        _image.color = const Color(0xFFFFFFFF).withValues(alpha: 0.55 * a);
        canvas.drawImageRect(
          sprite,
          Rect.fromLTWH(
            0,
            0,
            sprite.width.toDouble(),
            sprite.height.toDouble(),
          ),
          Rect.fromCenter(center: Offset(hx, hy), width: hr * 2, height: hr * 2),
          _image,
        );
      }
      _meteorFill.color = core.withValues(alpha: 0.35 * a);
      canvas.drawCircle(
        Offset(hx, hy),
        math.max(2.2, m.width * 2.2),
        _meteorFill,
      );
      _meteorFill.color = (m.warm
              ? const Color(0xFFFFFAF0)
              : const Color(0xFFFFFFFF))
          .withValues(alpha: 0.95 * a);
      canvas.drawCircle(
        Offset(hx, hy),
        math.max(1.0, m.width * 0.95),
        _meteorFill,
      );
    }

    for (final _Spark sp in _sparks) {
      final double se = 1 - sp.t / sp.life;
      if (se <= 0) continue;
      _meteorFill.color = (sp.warm
              ? const Color(0xFFFFD9A8)
              : const Color(0xFFD6E7FF))
          .withValues(alpha: se * se * sp.alpha * fade);
      canvas.drawCircle(Offset(sp.x, sp.y), sp.size, _meteorFill);
    }
  }

  Path _meteorPath(int from, int to) {
    final Path path = Path()..moveTo(_pts[from * 2], _pts[from * 2 + 1]);
    for (int k = from + 1; k <= to; k++) {
      path.lineTo(_pts[k * 2], _pts[k * 2 + 1]);
    }
    return path;
  }

  static double _smooth(double a, double b, double v) {
    final double t = ((v - a) / (b - a)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  final Float64List _pts = Float64List(30);
}

// ---------------------------------------------------------------- 数据

class _StarCfg {
  const _StarCfg(
    this.factor,
    this.count,
    this.sizeMin,
    this.sizeMax,
    this.aMin,
    this.aMax,
    this.bright,
  );

  final double factor;
  final int count;
  final double sizeMin;
  final double sizeMax;
  final double aMin;
  final double aMax;
  final double bright;
}

class _StarLayer {
  _StarLayer(this.factor);

  final double factor;
  final List<_Star> stars = <_Star>[];
  double avgAlpha = 0.5;
  double avgSize = 1;
}

class _Star {
  const _Star({
    required this.angle,
    required this.r,
    required this.size,
    required this.alpha,
    required this.twSpeed,
    required this.twPhase,
    required this.color,
    required this.bright,
  });

  final double angle;
  final double r;
  final double size;
  final double alpha;
  final double twSpeed;
  final double twPhase;
  final Color color;
  final bool bright;
}

class _Meteor {
  _Meteor({
    required this.theta,
    required this.radius,
    required this.spin,
    required this.drift,
    required this.life,
    required this.width,
    required this.alpha,
    required this.warm,
  });

  double theta;
  double radius;
  final double spin;
  final double drift;
  final double life;
  final double width;
  final double alpha;
  final bool warm;
  double t = 0;
  double sparkAcc = 0;
}

class _Ambient {
  _Ambient({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.len,
    required this.width,
    required this.alpha,
    required this.warm,
    required this.big,
  });

  double x;
  double y;
  final double vx;
  final double vy;
  final double life;
  final double len;
  final double width;
  final double alpha;
  final bool warm;
  final bool big;
  double t = 0;
}

class _Spark {
  _Spark({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.size,
    required this.alpha,
    required this.warm,
  });

  double x;
  double y;
  double vx;
  double vy;
  final double life;
  final double size;
  final double alpha;
  final bool warm;
  double t = 0;
}

class _CosmosArt {
  const _CosmosArt(this.nebula, this.starGlow, this.warmGlow);

  final ui.Image nebula;
  final ui.Image starGlow;
  final ui.Image warmGlow;

  void dispose() {
    nebula.dispose();
    starGlow.dispose();
    warmGlow.dispose();
  }
}
