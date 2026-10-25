import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/canvas_geometry.dart';

void main() {
  group('视口', () {
    test('世界 ↔ 屏幕往返不丢精度', () {
      const CanvasViewport vp = CanvasViewport(
        zoom: 1.7,
        offset: Offset(-240, 80),
      );
      const Offset world = Offset(123.5, -47.25);

      final Offset screen = vp.toScreen(world);

      expect(vp.toWorld(screen).dx, closeTo(world.dx, 1e-9));
      expect(vp.toWorld(screen).dy, closeTo(world.dy, 1e-9));
    });

    test('矩形往返也一致', () {
      const CanvasViewport vp = CanvasViewport(
        zoom: 0.6,
        offset: Offset(12, -8),
      );
      const Rect world = Rect.fromLTWH(-30, 40, 200, 120);

      final Rect back = vp.rectToWorld(vp.rectToScreen(world));

      expect(back.left, closeTo(world.left, 1e-9));
      expect(back.top, closeTo(world.top, 1e-9));
      expect(back.width, closeTo(world.width, 1e-9));
      expect(back.height, closeTo(world.height, 1e-9));
    });

    test('以光标为锚点缩放，那个点停在原地', () {
      const CanvasViewport vp = CanvasViewport(
        zoom: 1,
        offset: Offset(30, -10),
      );
      const Offset anchor = Offset(400, 300);
      final Offset worldBefore = vp.toWorld(anchor);

      final CanvasViewport zoomed = vp.zoomedAt(anchor, 2.4);

      final Offset screenAfter = zoomed.toScreen(worldBefore);
      expect(screenAfter.dx, closeTo(anchor.dx, 1e-9));
      expect(screenAfter.dy, closeTo(anchor.dy, 1e-9));
      expect(zoomed.zoom, closeTo(2.4, 1e-9));
    });

    test('缩放到上限就停住，不会越界', () {
      const CanvasViewport vp = CanvasViewport(zoom: 3, offset: Offset.zero);

      final CanvasViewport zoomed = vp.zoomedAt(Offset.zero, 10);

      expect(zoomed.zoom, CanvasViewport.maxZoom);
    });

    test('缩放到下限就停住', () {
      const CanvasViewport vp = CanvasViewport(zoom: 0.2, offset: Offset.zero);

      expect(vp.zoomedAt(Offset.zero, 0.001).zoom, CanvasViewport.minZoom);
    });

    test('已经在上限时缩放不改 offset（避免无意义的重绘）', () {
      const CanvasViewport vp = CanvasViewport(
        zoom: CanvasViewport.maxZoom,
        offset: Offset(5, 5),
      );

      final CanvasViewport zoomed = vp.zoomedAt(const Offset(100, 100), 2);

      expect(zoomed.offset, vp.offset);
    });

    test('withZoomAt 精确回到 100%', () {
      const CanvasViewport vp = CanvasViewport(
        zoom: 0.37,
        offset: Offset(-90, 40),
      );

      final CanvasViewport reset = vp.withZoomAt(const Offset(500, 400), 1);

      expect(reset.zoom, closeTo(1, 1e-9));
      expect(reset.toScreen(vp.toWorld(const Offset(500, 400))).dx,
          closeTo(500, 1e-9));
    });

    test('pannedBy 只动 offset', () {
      const CanvasViewport vp = CanvasViewport(
        zoom: 1.5,
        offset: Offset(10, 20),
      );

      final CanvasViewport moved = vp.pannedBy(const Offset(-30, 5));

      expect(moved.zoom, 1.5);
      expect(moved.offset, const Offset(-20, 25));
    });

    test('fit 把内容装进画布并居中', () {
      const Rect content = Rect.fromLTWH(0, 0, 200, 100);
      const Size stage = Size(1000, 800);

      final CanvasViewport vp = CanvasViewport.fit(content, stage);

      expect(vp.toScreen(content.center).dx, closeTo(500, 1e-6));
      expect(vp.toScreen(content.center).dy, closeTo(400, 1e-6));
      // 装得下：内容的屏幕尺寸不超过画布减去两倍留白
      expect(content.width * vp.zoom, lessThanOrEqualTo(1000 - 180 + 1e-6));
      expect(content.height * vp.zoom, lessThanOrEqualTo(800 - 180 + 1e-6));
    });

    test('fit 空内容退化成「中心对准原点」', () {
      final CanvasViewport vp = CanvasViewport.fit(Rect.zero, const Size(600, 400));

      expect(vp.zoom, 1);
      expect(vp.toScreen(Offset.zero), const Offset(300, 200));
    });

    test('fit 画布尺寸为 0 时不炸', () {
      expect(
        () => CanvasViewport.fit(
          const Rect.fromLTWH(0, 0, 10, 10),
          Size.zero,
        ),
        returnsNormally,
      );
    });
  });

  group('矩形工具', () {
    test('unionOf 包住所有矩形', () {
      final Rect u = unionOf(<Rect>[
        const Rect.fromLTWH(0, 0, 10, 10),
        const Rect.fromLTWH(50, -20, 10, 10),
      ]);

      expect(u.left, 0);
      expect(u.top, -20);
      expect(u.right, 60);
      expect(u.bottom, 10);
    });

    test('unionOf 空集合给 Rect.zero', () {
      expect(unionOf(const <Rect>[]), Rect.zero);
    });

    test('hitsRect 带容差', () {
      const Rect r = Rect.fromLTWH(0, 0, 100, 50);

      expect(hitsRect(r, const Offset(50, 25)), isTrue);
      expect(hitsRect(r, const Offset(105, 25)), isFalse);
      expect(hitsRect(r, const Offset(105, 25), tolerance: 6), isTrue);
    });
  });

  group('连线几何', () {
    test('自动选边：从右到左', () {
      const Rect a = Rect.fromLTWH(0, 0, 100, 100);
      const Rect b = Rect.fromLTWH(300, 0, 100, 100);

      expect(nearestSide(a, b.center), CanvasSide.right);
      expect(nearestSide(b, a.center), CanvasSide.left);
    });

    test('自动选边：从上到下', () {
      const Rect a = Rect.fromLTWH(0, 0, 100, 100);
      const Rect b = Rect.fromLTWH(0, 300, 100, 100);

      expect(nearestSide(a, b.center), CanvasSide.bottom);
      expect(nearestSide(b, a.center), CanvasSide.top);
    });

    test('控制点沿边的法线往外伸', () {
      const Rect r = Rect.fromLTWH(0, 0, 100, 100);

      final Offset right = controlPointOf(r, CanvasSide.right, const Offset(400, 50));
      expect(right.dx, greaterThan(r.centerRight.dx), reason: '应该往右伸');
      expect(right.dy, closeTo(r.centerRight.dy, 1e-9));

      final Offset top = controlPointOf(r, CanvasSide.top, const Offset(50, -400));
      expect(top.dy, lessThan(r.topCenter.dy));
      expect(top.dx, closeTo(r.topCenter.dx, 1e-9));
    });

    test('控制点伸出距离有上限', () {
      const Rect r = Rect.fromLTWH(0, 0, 100, 100);

      final Offset far = controlPointOf(r, CanvasSide.right, const Offset(99999, 50));

      expect(
        (far - r.centerRight).distance,
        closeTo(CanvasEdgeGeometry.maxReach, 1e-9),
      );
    });

    test('端点就是所选边的中点', () {
      const Rect a = Rect.fromLTWH(0, 0, 100, 100);
      const Rect b = Rect.fromLTWH(300, 0, 100, 100);

      final CanvasEdgeGeometry g = edgeGeometry(
        fromRect: a,
        toRect: b,
        fromSide: CanvasSide.right,
        toSide: CanvasSide.left,
      );

      expect(g.from, a.centerRight);
      expect(g.to, b.centerLeft);
    });

    test('未指定边时自动选，且曲线不穿卡片', () {
      const Rect a = Rect.fromLTWH(0, 0, 100, 100);
      const Rect b = Rect.fromLTWH(300, 0, 100, 100);

      final CanvasEdgeGeometry g = edgeGeometry(fromRect: a, toRect: b);

      expect(g.from, a.centerRight);
      expect(g.to, b.centerLeft);
      // 中点应该在两张卡片之间的空白里
      final Offset mid = g.pointAt(0.5);
      expect(mid.dx, greaterThan(100));
      expect(mid.dx, lessThan(300));
    });

    test('pointAt 两端点对齐', () {
      const CanvasEdgeGeometry g = CanvasEdgeGeometry(
        from: Offset(0, 0),
        fromControl: Offset(50, 0),
        toControl: Offset(150, 100),
        to: Offset(200, 100),
      );

      expect(g.pointAt(0), const Offset(0, 0));
      expect(g.pointAt(1), const Offset(200, 100));
    });

    test('distanceTo 在曲线上接近 0，在远处就大', () {
      const CanvasEdgeGeometry g = CanvasEdgeGeometry(
        from: Offset(0, 0),
        fromControl: Offset(50, 0),
        toControl: Offset(150, 0),
        to: Offset(200, 0),
      );

      expect(g.distanceTo(g.pointAt(0.5)), lessThan(1));
      expect(g.distanceTo(const Offset(100, 200)), greaterThan(100));
    });

    test('tangentAt 是单位向量，方向朝终点', () {
      const CanvasEdgeGeometry g = CanvasEdgeGeometry(
        from: Offset(0, 0),
        fromControl: Offset(50, 0),
        toControl: Offset(150, 0),
        to: Offset(200, 0),
      );

      final Offset t = g.tangentAt(0.5);

      expect(t.distance, closeTo(1, 1e-6));
      expect(t.dx, greaterThan(0.9));
      expect(t.dy.abs(), lessThan(0.1));
    });
  });

  group('吸附', () {
    test('网格吸附：容差内才动', () {
      expect(snapToGrid(18), 20);
      expect(snapToGrid(23), 20);
      expect(snapToGrid(30), 30, reason: '离 20 和 40 都超过 6');
      expect(snapToGrid(-2), 0);
    });

    test('网格吸附：负坐标也对称', () {
      expect(snapToGrid(-18), -20);
      expect(snapToGrid(-42), -40);
    });

    test('网格为 0 时原样返回', () {
      expect(snapToGrid(13.7, grid: 0), 13.7);
    });

    test('边缘对齐取最近的候选', () {
      expect(snapToEdge(103, <double>[100, 105]), 105);
      expect(snapToEdge(99, <double>[100]), 100);
      expect(snapToEdge(50, <double>[100]), isNull);
      expect(snapToEdge(50, const <double>[]), isNull);
    });
  });

  group('缩放卡片', () {
    const Rect start = Rect.fromLTRB(100, 100, 300, 200);

    test('右下角：右下两条边跟着走', () {
      final Rect r = resizeRect(
        start,
        ResizeHandle.bottomRight,
        const Offset(50, 30),
        minSize: 40,
      );

      expect(r, const Rect.fromLTRB(100, 100, 350, 230));
    });

    test('左上角：左上两条边跟着走', () {
      final Rect r = resizeRect(
        start,
        ResizeHandle.topLeft,
        const Offset(-20, -10),
        minSize: 40,
      );

      expect(r, const Rect.fromLTRB(80, 90, 300, 200));
    });

    test('右边中点只动右边', () {
      final Rect r = resizeRect(
        start,
        ResizeHandle.centerRight,
        const Offset(40, 999),
        minSize: 40,
      );

      expect(r, const Rect.fromLTRB(100, 100, 340, 200));
    });

    test('撞到最小尺寸时，对面的边不动', () {
      final Rect r = resizeRect(
        start,
        ResizeHandle.topLeft,
        const Offset(9999, 9999),
        minSize: 40,
      );

      expect(r.right, 300, reason: '右边缘不该被拖走');
      expect(r.bottom, 200, reason: '下边缘不该被拖走');
      expect(r.width, closeTo(40, 1e-9));
      expect(r.height, closeTo(40, 1e-9));
    });

    test('往回拖过头也不会出现负宽高', () {
      final Rect r = resizeRect(
        start,
        ResizeHandle.bottomRight,
        const Offset(-9999, -9999),
        minSize: 40,
      );

      expect(r.width, greaterThanOrEqualTo(40));
      expect(r.height, greaterThanOrEqualTo(40));
    });

    test('八个手柄的位置都落在矩形边界上', () {
      for (final ResizeHandle h in ResizeHandle.values) {
        final Offset p = h.at(start);
        final bool onEdge =
            (p.dx - start.left).abs() < 1e-9 ||
            (p.dx - start.right).abs() < 1e-9 ||
            (p.dy - start.top).abs() < 1e-9 ||
            (p.dy - start.bottom).abs() < 1e-9;
        expect(onEdge, isTrue, reason: '$h 不在边界上');
        expect(start.inflate(0.001).contains(p), isTrue, reason: '$h 跑到矩形外');
      }
    });

    test('四个角牵动两条边，四条边中点只牵动一条', () {
      const Set<ResizeHandle> corners = <ResizeHandle>{
        ResizeHandle.topLeft,
        ResizeHandle.topRight,
        ResizeHandle.bottomRight,
        ResizeHandle.bottomLeft,
      };
      for (final ResizeHandle h in ResizeHandle.values) {
        final int moved = <bool>[
          h.movesLeft,
          h.movesRight,
          h.movesTop,
          h.movesBottom,
        ].where((bool b) => b).length;
        expect(moved, corners.contains(h) ? 2 : 1, reason: '$h 牵动的边数不对');
      }
    });

    test('没有任何手柄同时牵动一对相反的边', () {
      for (final ResizeHandle h in ResizeHandle.values) {
        expect(h.movesLeft && h.movesRight, isFalse, reason: '$h 左右都动');
        expect(h.movesTop && h.movesBottom, isFalse, reason: '$h 上下都动');
      }
    });
  });

  group('边枚举', () {
    test('parse 只认四个合法值', () {
      expect(CanvasSide.parse('top'), CanvasSide.top);
      expect(CanvasSide.parse('left'), CanvasSide.left);
      expect(CanvasSide.parse('north'), isNull);
      expect(CanvasSide.parse(null), isNull);
      expect(CanvasSide.parse(3), isNull);
    });

    test('outward 是单位向量且朝外', () {
      expect(CanvasSide.top.outward, const Offset(0, -1));
      expect(CanvasSide.bottom.outward, const Offset(0, 1));
      expect(CanvasSide.left.outward, const Offset(-1, 0));
      expect(CanvasSide.right.outward, const Offset(1, 0));
      for (final CanvasSide s in CanvasSide.values) {
        expect(s.outward.distance, closeTo(1, 1e-9));
      }
    });
  });

  test('矩形相交：贴边不算相交', () {
    const Rect a = Rect.fromLTWH(0, 0, 10, 10);
    const Rect b = Rect.fromLTWH(10, 0, 10, 10);

    expect(rectsIntersect(a, b), isFalse);
    expect(rectsIntersect(a, const Rect.fromLTWH(5, 5, 10, 10)), isTrue);
  });

  test('数学常数没被写错（防止手滑改坏 maxReach）', () {
    expect(CanvasEdgeGeometry.maxReach, 96);
    expect(snapGridSize, 20);
    expect(snapGridTolerance, 6);
    expect(snapEdgeTolerance, 8);
    expect(math.max(1, 2), 2);
  });
}
