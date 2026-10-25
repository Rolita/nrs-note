/// 白板的几何计算：视口变换、连线贝塞尔、命中测试、吸附。
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

/// 视口：世界坐标 ↔ 屏幕坐标。
///
/// 只有一种变换，`screen = world * zoom + offset`。别的地方不要再自己算一遍——
/// 白板里「拖 A 结果 B 动了」这类 bug 十有八九是有第二套坐标公式。
class CanvasViewport {
  const CanvasViewport({this.zoom = 1, this.offset = Offset.zero});

  final double zoom;
  final Offset offset;

  /// 缩放下限。再小字已经是噪点，网格也该消失了。
  static const double minZoom = 0.1;

  /// 缩放上限。再大一张卡片就占满屏，没意义。
  static const double maxZoom = 4;

  /// 适应窗口时四周留的空白。
  static const double fitPadding = 90;

  Offset toScreen(Offset world) => world * zoom + offset;

  Offset toWorld(Offset screen) => (screen - offset) / zoom;

  Rect rectToScreen(Rect world) => Rect.fromLTWH(
    world.left * zoom + offset.dx,
    world.top * zoom + offset.dy,
    world.width * zoom,
    world.height * zoom,
  );

  Rect rectToWorld(Rect screen) => Rect.fromLTWH(
    (screen.left - offset.dx) / zoom,
    (screen.top - offset.dy) / zoom,
    screen.width / zoom,
    screen.height / zoom,
  );

  CanvasViewport pannedBy(Offset delta) =>
      CanvasViewport(zoom: zoom, offset: offset + delta);

  /// 以屏幕上某一点为锚点缩放：那个点在缩放前后**停在原地**。
  CanvasViewport zoomedAt(Offset screenAnchor, double factor) {
    final double next = (zoom * factor).clamp(minZoom, maxZoom);
    if (next == zoom) return this;
    final double k = next / zoom;
    return CanvasViewport(
      zoom: next,
      offset: screenAnchor - (screenAnchor - offset) * k,
    );
  }

  /// 缩放固定到某个值（`Ctrl+0` 回 100%）。
  ///
  /// 不复用 [zoomedAt] 的乘法：`zoom * (1 / zoom)` 会给出 0.9999999999999999，
  /// 而「回到 100%」显示成 99% 是那种一眼就看得见、又很难解释的错。
  CanvasViewport withZoomAt(Offset screenAnchor, double value) {
    final double next = value.clamp(minZoom, maxZoom);
    if (next == zoom) return this;
    final double k = next / zoom;
    return CanvasViewport(
      zoom: next,
      offset: screenAnchor - (screenAnchor - offset) * k,
    );
  }

  /// 把 [content] 装进 [stage] 并居中。内容为空时退化成「中心对准原点」。
  static CanvasViewport fit(Rect content, Size stage) {
    if (stage.isEmpty) return const CanvasViewport();
    if (content.width <= 0 || content.height <= 0) {
      return CanvasViewport(offset: stage.center(Offset.zero));
    }
    final double scale = math.min(
      (stage.width - fitPadding * 2) / content.width,
      (stage.height - fitPadding * 2) / content.height,
    );
    final double zoom = scale.clamp(minZoom, maxZoom);
    return CanvasViewport(
      zoom: zoom,
      offset: stage.center(Offset.zero) - content.center * zoom,
    );
  }

  /// 值相等。
  ///
  /// 视口是画笔的输入，`shouldRepaint` 拿它和上一帧比。没有 `==` 就只能比
  /// 引用，每帧都判定「变了」——平移缩放时白画一遍无所谓，静止时也重绘就
  /// 是纯浪费。
  @override
  bool operator ==(Object other) =>
      other is CanvasViewport && other.zoom == zoom && other.offset == offset;

  @override
  int get hashCode => Object.hash(zoom, offset);

  @override
  String toString() =>
      'CanvasViewport(zoom: ${zoom.toStringAsFixed(3)}, offset: $offset)';
}

/// 一组矩形的并集。空集合返回 [Rect.zero]。
Rect unionOf(Iterable<Rect> rects) {
  Rect? out;
  for (final Rect r in rects) {
    out = out == null ? r : out.expandToInclude(r);
  }
  return out ?? Rect.zero;
}

/// 一条边的曲线几何。
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

/// 拖到离网格多近就吸上去。
const double snapGridSize = 20;
const double snapGridTolerance = 6;

/// 拖到离另一张卡片边缘多近就对齐。
const double snapEdgeTolerance = 8;

/// 一维吸附到网格：偏差在 [tolerance] 内才动，否则原样返回。
///
/// 拖动**过程中**不吸，松手才吸——过程中吸会让人觉得「拽不动」。
double snapToGrid(
  double value, {
  double grid = snapGridSize,
  double tolerance = snapGridTolerance,
}) {
  if (grid <= 0) return value;
  final double snapped = (value / grid).roundToDouble() * grid;
  return (snapped - value).abs() <= tolerance ? snapped : value;
}

/// 一维边缘对齐：在 [candidates] 里找一个与 [value] 差不超过
/// [snapEdgeTolerance] 的值，取最近的。没有就返回 `null`。
double? snapToEdge(double value, Iterable<double> candidates) {
  double? best;
  double bestDelta = snapEdgeTolerance;
  for (final double c in candidates) {
    final double delta = (c - value).abs();
    if (delta <= bestDelta) {
      bestDelta = delta;
      best = c;
    }
  }
  return best;
}

/// 命中一张卡片。容差是屏幕像素，所以要除以 zoom 换到世界坐标。
bool hitsRect(Rect rect, Offset world, {double tolerance = 0}) {
  if (tolerance <= 0) return rect.contains(world);
  return rect.inflate(tolerance).contains(world);
}

/// 框选：矩形相交即命中。
bool rectsIntersect(Rect a, Rect b) => a.overlaps(b);

/// 八个缩放手柄的位置（四角 + 四边中点），顺序固定，`CanvasResizeHandle` 的
/// 下标就是它的序号。
enum CanvasResizeHandle {
  topLeft,
  topCenter,
  topRight,
  centerRight,
  bottomRight,
  bottomCenter,
  bottomLeft,
  centerLeft;

  Offset at(Rect r) => switch (this) {
    CanvasResizeHandle.topLeft => r.topLeft,
    CanvasResizeHandle.topCenter => r.topCenter,
    CanvasResizeHandle.topRight => r.topRight,
    CanvasResizeHandle.centerRight => r.centerRight,
    CanvasResizeHandle.bottomRight => r.bottomRight,
    CanvasResizeHandle.bottomCenter => r.bottomCenter,
    CanvasResizeHandle.bottomLeft => r.bottomLeft,
    CanvasResizeHandle.centerLeft => r.centerLeft,
  };

  /// 这个手柄牵动哪几条边。
  bool get movesLeft =>
      this == CanvasResizeHandle.topLeft ||
      this == CanvasResizeHandle.centerLeft ||
      this == CanvasResizeHandle.bottomLeft;

  bool get movesRight =>
      this == CanvasResizeHandle.topRight ||
      this == CanvasResizeHandle.centerRight ||
      this == CanvasResizeHandle.bottomRight;

  bool get movesTop =>
      this == CanvasResizeHandle.topLeft ||
      this == CanvasResizeHandle.topCenter ||
      this == CanvasResizeHandle.topRight;

  bool get movesBottom =>
      this == CanvasResizeHandle.bottomLeft ||
      this == CanvasResizeHandle.bottomCenter ||
      this == CanvasResizeHandle.bottomRight;
}

/// 拖动某个手柄之后的新矩形。
///
/// [minSize] 是下限，撞到下限时**不动的边**保持不动——所以缩到最小之后
/// 卡片是「贴住」原来那条边，而不是整体漂移。
Rect resizeRect(
  Rect start,
  CanvasResizeHandle handle,
  Offset delta, {
  required double minSize,
}) {
  double left = start.left;
  double top = start.top;
  double right = start.right;
  double bottom = start.bottom;

  if (handle.movesLeft) left = math.min(start.left + delta.dx, right - minSize);
  if (handle.movesRight) {
    right = math.max(start.right + delta.dx, left + minSize);
  }
  if (handle.movesTop) top = math.min(start.top + delta.dy, bottom - minSize);
  if (handle.movesBottom) {
    bottom = math.max(start.bottom + delta.dy, top + minSize);
  }

  return Rect.fromLTRB(left, top, right, bottom);
}
