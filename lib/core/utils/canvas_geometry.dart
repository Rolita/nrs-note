/// 白板的几何计算：摄像机、连线贝塞尔、命中测试、缩放手柄。
///
/// 全部是纯函数 / 不可变值对象，不碰 widget、不碰 `BuildContext`。
/// 白板里最容易算错的就是坐标，所以这一层单独拆出来，用单测钉死。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

/// 画布的四个边，顺序固定。
enum CanvasSide {
  top,
  right,
  bottom,
  left;

  static CanvasSide? parse(Object? raw) {
    for (final CanvasSide side in CanvasSide.values) {
      if (side.name == raw) return side;
    }
    return null;
  }

  /// 从这条边往外指的单位向量。
  Offset get outward => switch (this) {
    CanvasSide.top => const Offset(0, -1),
    CanvasSide.right => const Offset(1, 0),
    CanvasSide.bottom => const Offset(0, 1),
    CanvasSide.left => const Offset(-1, 0),
  };
}

/// 摄像机：画面中心对准哪个世界坐标、放大多少。
///
/// 只有一种变换，`screen = (world - center) * zoom + stage.center`。
/// 别的地方不要再自己算一遍——白板里「拖 A 结果 B 动了」这类 bug
/// 十有八九是有第二套坐标公式。
///
/// 和「左上角偏移」的视口相比，中心点模型的差别在缩放：以屏幕某点为锚点
/// 缩放时，只要保证那个点下面的世界坐标不动，公式是
/// `center' = anchorWorld - (anchorScreen - stageCenter) / zoom'`，
/// 不用先算 offset 再回推。
class CanvasCamera {
  const CanvasCamera({this.center = Offset.zero, this.zoom = 1});

  /// 画面正中央对准的世界坐标。
  final Offset center;

  final double zoom;

  /// 缩放的**数值下限**，不是视觉上的极限。
  ///
  /// 白板**不设缩放上限**：想放到多少倍就放到多少倍。下限只用来挡住 0 和
  /// Infinity——`1 / zoom` 到处都是（线宽、手柄、箭头都靠它折算屏幕像素），
  /// zoom 掉到 0 会算出无穷大，几何整个变 NaN。1e-6 时一个世界像素只有
  /// 百万分之一屏幕像素，任何内容都缩成一点，实际用不到比这更小。
  static const double minZoom = 1e-6;

  /// 适应窗口时四周留的空白（屏幕像素）。
  static const double fitPadding = 90;

  /// 屏幕中心。每个换算都要用，单独抽出来免得写十遍。
  static Offset stageCenter(Size stage) => stage.center(Offset.zero);

  Offset toScreen(Offset world, Size stage) =>
      (world - center) * zoom + stageCenter(stage);

  Offset toWorld(Offset screen, Size stage) =>
      (screen - stageCenter(stage)) / zoom + center;

  Rect rectToScreen(Rect world, Size stage) => Rect.fromLTWH(
    (world.left - center.dx) * zoom + stage.width / 2,
    (world.top - center.dy) * zoom + stage.height / 2,
    world.width * zoom,
    world.height * zoom,
  );

  Rect rectToWorld(Rect screen, Size stage) => Rect.fromLTWH(
    (screen.left - stage.width / 2) / zoom + center.dx,
    (screen.top - stage.height / 2) / zoom + center.dy,
    screen.width / zoom,
    screen.height / zoom,
  );

  /// 当前屏幕上能看到的世界矩形。
  Rect visibleWorld(Size stage) => rectToWorld(Offset.zero & stage, stage);

  /// 平移：拖动屏幕 [delta] 像素，内容就跟着走那么多。
  CanvasCamera pannedBy(Offset delta) =>
      CanvasCamera(center: center - delta / zoom, zoom: zoom);

  /// 直接位移到某个世界中心。
  CanvasCamera movedTo(Offset next) => CanvasCamera(center: next, zoom: zoom);

  /// 以屏幕上某一点为锚点缩放：那个点下面的世界坐标在缩放前后**停在原地**。
  CanvasCamera zoomedAt(Offset screenAnchor, double factor, Size stage) =>
      withZoomAt(screenAnchor, zoom * factor, stage);

  /// 缩放固定到某个值（`Ctrl+0` 回 100%）。
  CanvasCamera withZoomAt(Offset screenAnchor, double value, Size stage) {
    final double next = value < minZoom ? minZoom : value;
    if (next == zoom) return this;
    final Offset anchorWorld = toWorld(screenAnchor, stage);
    final Offset offsetFromCenter = screenAnchor - stageCenter(stage);
    return CanvasCamera(
      center: anchorWorld - offsetFromCenter / next,
      zoom: next,
    );
  }

  /// 把 [content] 装进 [stage] 并居中。内容为空时退化成「中心对准原点」。
  static CanvasCamera fit(
    Rect content,
    Size stage, {
    double padding = fitPadding,
  }) {
    if (stage.isEmpty) return const CanvasCamera();
    if (content.width <= 0 || content.height <= 0) {
      return const CanvasCamera();
    }
    final double scale = math.min(
      (stage.width - padding * 2) / content.width,
      (stage.height - padding * 2) / content.height,
    );
    return CanvasCamera(
      center: content.center,
      zoom: scale < minZoom ? minZoom : scale,
    );
  }

  /// 值相等。
  ///
  /// 摄像机会作为画笔的输入，`shouldRepaint` 拿它和上一帧比。没有 `==`
  /// 就只能比引用，每帧都判定「变了」——静止时也重绘就是纯浪费。
  @override
  bool operator ==(Object other) =>
      other is CanvasCamera && other.center == center && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(center, zoom);

  @override
  String toString() =>
      'CanvasCamera(center: $center, zoom: ${zoom.toStringAsFixed(3)})';
}

/// 一组矩形的并集。空集合返回 [Rect.zero]。
Rect unionOf(Iterable<Rect> rects) {
  Rect? out;
  for (final Rect r in rects) {
    out = out == null ? r : out.expandToInclude(r);
  }
  return out ?? Rect.zero;
}

/// 一条边的曲线几何（**世界坐标**）。
///
/// 三次贝塞尔：两个端点各带一个控制点，控制点沿所在边的法线伸出去，
/// 所以线是「从卡片侧面长出来」的，不会从卡片正中穿过去。
class CanvasEdgeGeometry {
  const CanvasEdgeGeometry({
    required this.from,
    required this.fromControl,
    required this.toControl,
    required this.to,
  });

  final Offset from;
  final Offset fromControl;
  final Offset toControl;
  final Offset to;

  /// 控制点伸出去的最大距离。太长了曲线会绕成一团。
  static const double maxReach = 96;

  /// 曲线上的点，`t ∈ [0, 1]`。
  Offset pointAt(double t) {
    final double u = 1 - t;
    return from * (u * u * u) +
        fromControl * (3 * u * u * t) +
        toControl * (3 * u * t * t) +
        to * (t * t * t);
  }

  /// 点 [p] 到曲线的最近距离。用折线近似——24 段对 6px 的命中容差绰绰有余，
  /// 比解三次方程便宜得多。
  double distanceTo(Offset p, {int samples = 24}) {
    double best = double.infinity;
    Offset prev = from;
    for (int i = 1; i <= samples; i++) {
      final Offset next = pointAt(i / samples);
      best = math.min(best, _distanceToSegment(p, prev, next));
      prev = next;
    }
    return best;
  }

  /// 曲线在 `t` 处的切线方向（单位向量），画箭头用。
  ///
  /// 用差分而不是解析求导：三次贝塞尔的导数是二次式，写对了没收益、写错了
  /// 箭头会歪，而差分永远不会歪。
  Offset tangentAt(double t) {
    final Offset p1 = pointAt(math.max(0, t - 0.01));
    final Offset p2 = pointAt(math.min(1, t + 0.01));
    final Offset d = p2 - p1;
    final double len = d.distance;
    return len < 0.0001 ? const Offset(1, 0) : d / len;
  }
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final Offset ab = b - a;
  final double lenSq = ab.distanceSquared;
  if (lenSq < 0.0001) return (p - a).distance;
  final double t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / lenSq).clamp(
    0.0,
    1.0,
  );
  return (p - (a + ab * t)).distance;
}

/// 从矩形的某条边往外伸出的控制点。
Offset controlPointOf(Rect rect, CanvasSide side, Offset toward) {
  final Offset anchor = anchorOf(rect, side);
  final double reach = math.min(
    CanvasEdgeGeometry.maxReach,
    (toward - anchor).distance * 0.4,
  );
  return anchor + side.outward * reach;
}

/// 某条边的中点。
Offset anchorOf(Rect rect, CanvasSide side) => switch (side) {
  CanvasSide.top => rect.topCenter,
  CanvasSide.right => rect.centerRight,
  CanvasSide.bottom => rect.bottomCenter,
  CanvasSide.left => rect.centerLeft,
};

/// 未指定边时自动选：`rect` 的四条边里，中点离 [toward] 最近的那条。
CanvasSide nearestSide(Rect rect, Offset toward) {
  CanvasSide best = CanvasSide.right;
  double bestDistance = double.infinity;
  for (final CanvasSide side in CanvasSide.values) {
    final double d = (anchorOf(rect, side) - toward).distanceSquared;
    if (d < bestDistance) {
      bestDistance = d;
      best = side;
    }
  }
  return best;
}

/// 算一条边的完整曲线。
CanvasEdgeGeometry edgeGeometry({
  required Rect fromRect,
  required Rect toRect,
  CanvasSide? fromSide,
  CanvasSide? toSide,
}) {
  final CanvasSide a = fromSide ?? nearestSide(fromRect, toRect.center);
  final CanvasSide b = toSide ?? nearestSide(toRect, fromRect.center);
  final Offset from = anchorOf(fromRect, a);
  final Offset to = anchorOf(toRect, b);
  return CanvasEdgeGeometry(
    from: from,
    fromControl: controlPointOf(fromRect, a, to),
    toControl: controlPointOf(toRect, b, from),
    to: to,
  );
}

/// 命中一张卡片。容差是屏幕像素，所以要除以 zoom 换到世界坐标。
bool hitsRect(Rect rect, Offset world, {double tolerance = 0}) {
  if (tolerance <= 0) return rect.contains(world);
  return rect.inflate(tolerance).contains(world);
}

/// 框选：矩形相交即命中。
bool rectsIntersect(Rect a, Rect b) => a.overlaps(b);

/// 两条线段是否相交（含端点接触）。劈砍用（§14.19）。
///
/// 用叉积判「两次转向是否相反」：两条线段相交 ⟺ 各自对另一条的两个端点
/// 分居两侧。端点落在线上算相交——刀正好从线头切过，也该算砍断。
bool segmentsCross(Offset a, Offset b, Offset c, Offset d) {
  final double d1 = _cross(c, d, a);
  final double d2 = _cross(c, d, b);
  final double d3 = _cross(a, b, c);
  final double d4 = _cross(a, b, d);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }
  // 共线 / 端点贴在另一条上的情况，退化成「点在不在线段上」。
  bool onSegment(Offset p, Offset q, Offset r) =>
      math.min(p.dx, q.dx) <= r.dx &&
      r.dx <= math.max(p.dx, q.dx) &&
      math.min(p.dy, q.dy) <= r.dy &&
      r.dy <= math.max(p.dy, q.dy);
  if (d1 == 0 && onSegment(c, d, a)) return true;
  if (d2 == 0 && onSegment(c, d, b)) return true;
  if (d3 == 0 && onSegment(a, b, c)) return true;
  if (d4 == 0 && onSegment(a, b, d)) return true;
  return false;
}

double _cross(Offset o, Offset a, Offset b) =>
    (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

/// 线段是否穿过矩形（含擦边）。劈砍判「这一刀有没有切到这张卡」。
///
/// 三种情况：端点在矩形里、线段穿过矩形的四条边、矩形整个被线段跨过。
bool segmentHitsRect(Offset a, Offset b, Rect rect) {
  if (rect.contains(a) || rect.contains(b)) return true;
  final Offset tl = rect.topLeft;
  final Offset tr = rect.topRight;
  final Offset br = rect.bottomRight;
  final Offset bl = rect.bottomLeft;
  return segmentsCross(a, b, tl, tr) ||
      segmentsCross(a, b, tr, br) ||
      segmentsCross(a, b, br, bl) ||
      segmentsCross(a, b, bl, tl);
}

/// 一条折线（刀锋）有没有切到线段 [a]–[b]。
bool polylineCrossesSegment(List<Offset> stroke, Offset a, Offset b) {
  for (int i = 0; i + 1 < stroke.length; i++) {
    if (segmentsCross(stroke[i], stroke[i + 1], a, b)) return true;
  }
  return false;
}

/// 两个数之间按 [t] 插值（摄像机动效用）。
double lerpDouble(double a, double b, double t) => a + (b - a) * t;

/// `Offset` 版本。
Offset lerpOffset(Offset a, Offset b, double t) =>
    Offset(lerpDouble(a.dx, b.dx, t), lerpDouble(a.dy, b.dy, t));

/// 缓出曲线：起手快、收尾慢。摄像机动效统一用它。
double easeOutCubic(double t) {
  final double u = (1 - t).clamp(0.0, 1.0);
  return 1 - u * u * u;
}
