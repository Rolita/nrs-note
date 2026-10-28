import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/canvas_geometry.dart';

void main() {
  group('摄像机', () {
    const Size stage = Size(1000, 800);

    test('默认：中心对准原点、缩放 1', () {
      const CanvasCamera cam = CanvasCamera();

      expect(cam.center, Offset.zero);
      expect(cam.zoom, 1);
      expect(cam.toScreen(Offset.zero, stage), const Offset(500, 400));
      expect(cam.toWorld(const Offset(500, 400), stage), Offset.zero);
    });

    test('屏幕与世界互逆', () {
      const CanvasCamera cam = CanvasCamera(
        center: Offset(120, -40),
        zoom: 2.5,
      );
      const Offset world = Offset(33.5, 71.25);

      final Offset back = cam.toWorld(cam.toScreen(world, stage), stage);
      expect(back.dx, closeTo(world.dx, 1e-9));
      expect(back.dy, closeTo(world.dy, 1e-9));
    });

    test('rect 的两个方向也互逆', () {
      const CanvasCamera cam = CanvasCamera(center: Offset(-17, 33), zoom: 0.6);
      const Rect world = Rect.fromLTWH(10, 20, 250, 120);

      final Rect back = cam.rectToWorld(cam.rectToScreen(world, stage), stage);
      expect(back.left, closeTo(world.left, 1e-9));
      expect(back.top, closeTo(world.top, 1e-9));
      expect(back.width, closeTo(world.width, 1e-9));
      expect(back.height, closeTo(world.height, 1e-9));
    });

    test('visibleWorld 是整块画布对应的世界矩形', () {
      const CanvasCamera cam = CanvasCamera(zoom: 2, center: Offset(100, 100));
      final Rect v = cam.visibleWorld(stage);

      expect(v.width, closeTo(500, 1e-9));
      expect(v.height, closeTo(400, 1e-9));
      expect(v.center, const Offset(100, 100));
    });

    test('平移：拖动多少屏幕像素，内容就跟多少', () {
      const CanvasCamera cam = CanvasCamera(zoom: 2, center: Offset(10, 20));
      final CanvasCamera moved = cam.pannedBy(const Offset(-30, 5));

      // 世界中心反向走 delta/zoom
      expect(moved.center, const Offset(25, 17.5));
      // 同一个世界点的屏幕位置正好跟着走
      expect(
        moved.toScreen(const Offset(10, 20), stage) -
            cam.toScreen(const Offset(10, 20), stage),
        const Offset(-30, 5),
      );
    });

    test('movedTo 只改中心', () {
      const CanvasCamera cam = CanvasCamera(zoom: 1.7);
      final CanvasCamera moved = cam.movedTo(const Offset(5, 6));

      expect(moved.center, const Offset(5, 6));
      expect(moved.zoom, 1.7);
    });

    test('以光标为锚点缩放：锚点下的世界坐标不动', () {
      const CanvasCamera cam = CanvasCamera(zoom: 1);
      const Offset anchor = Offset(120, 260);
      final Offset worldBefore = cam.toWorld(anchor, stage);

      final CanvasCamera zoomed = cam.zoomedAt(anchor, 2.4, stage);

      expect(zoomed.zoom, closeTo(2.4, 1e-9));
      expect(zoomed.toWorld(anchor, stage).dx, closeTo(worldBefore.dx, 1e-9));
      expect(zoomed.toWorld(anchor, stage).dy, closeTo(worldBefore.dy, 1e-9));
    });

    test('放大没有上限', () {
      const CanvasCamera cam = CanvasCamera(zoom: 3, center: Offset.zero);

      expect(cam.zoomedAt(Offset.zero, 10, stage).zoom, closeTo(30, 1e-9));
      expect(
        cam.zoomedAt(Offset.zero, 10000, stage).zoom,
        closeTo(30000, 1e-6),
      );
    });

    test('缩小的下限只挡住 0', () {
      const CanvasCamera cam = CanvasCamera(zoom: 0.2);

      expect(
        cam.zoomedAt(Offset.zero, 1e-12, stage).zoom,
        CanvasCamera.minZoom,
      );
      expect(CanvasCamera.minZoom, greaterThan(0));
      expect(CanvasCamera.minZoom, lessThan(0.08), reason: '8% 不再是墙');
    });

    test('放到极大时锚点照样不跑', () {
      const CanvasCamera cam = CanvasCamera(zoom: 1e5, center: Offset(3, 4));
      const Offset anchor = Offset(100, 100);
      final CanvasCamera zoomed = cam.zoomedAt(anchor, 2, stage);

      expect(zoomed.zoom, closeTo(2e5, 1e-6));
      expect(
        zoomed.toWorld(anchor, stage).dx,
        closeTo(cam.toWorld(anchor, stage).dx, 1e-9),
      );
      expect(
        zoomed.toWorld(anchor, stage).dy,
        closeTo(cam.toWorld(anchor, stage).dy, 1e-9),
      );
    });

    test('withZoomAt(1) 回到 100% 且锚点不跑', () {
      const CanvasCamera cam = CanvasCamera(zoom: 2, center: Offset(50, 50));
      const Offset anchor = Offset(500, 400);

      final CanvasCamera reset = cam.withZoomAt(anchor, 1, stage);

      expect(reset.zoom, 1);
      expect(
        reset.toWorld(anchor, stage).dx,
        closeTo(cam.toWorld(anchor, stage).dx, 1e-9),
      );
      expect(
        reset.toWorld(anchor, stage).dy,
        closeTo(cam.toWorld(anchor, stage).dy, 1e-9),
      );
    });

    test('fit 把内容装进画布并居中', () {
      const Rect content = Rect.fromLTWH(0, 0, 200, 100);

      final CanvasCamera cam = CanvasCamera.fit(content, stage);

      expect(cam.toScreen(content.center, stage).dx, closeTo(500, 1e-6));
      expect(cam.toScreen(content.center, stage).dy, closeTo(400, 1e-6));
      // 装得下：内容的屏幕尺寸不超过画布减去两倍留白
      expect(content.width * cam.zoom, lessThanOrEqualTo(1000 - 180 + 1e-6));
      expect(content.height * cam.zoom, lessThanOrEqualTo(800 - 180 + 1e-6));
    });

    test('fit 空内容退化成「中心对准原点」', () {
      final CanvasCamera cam = CanvasCamera.fit(
        Rect.zero,
        const Size(600, 400),
      );

      expect(cam.zoom, 1);
      expect(
        cam.toScreen(Offset.zero, const Size(600, 400)),
        const Offset(300, 200),
      );
    });

    test('fit 画布尺寸为 0 时不炸', () {
      expect(
        () => CanvasCamera.fit(const Rect.fromLTWH(0, 0, 10, 10), Size.zero),
        returnsNormally,
      );
    });

    test('值相等（画笔 shouldRepaint 依赖它）', () {
      const CanvasCamera a = CanvasCamera(center: Offset(1, 2), zoom: 1.5);
      const CanvasCamera b = CanvasCamera(center: Offset(1, 2), zoom: 1.5);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const CanvasCamera(center: Offset(1, 2), zoom: 1.6), isFalse);
    });
  });

  group('插值', () {
    test('lerpDouble / lerpOffset', () {
      expect(lerpDouble(0, 10, 0.25), 2.5);
      expect(
        lerpOffset(Offset.zero, const Offset(10, 20), 0.5),
        const Offset(5, 10),
      );
    });

    test('easeOutCubic 两端钉住、中点快', () {
      expect(easeOutCubic(0), 0);
      expect(easeOutCubic(1), 1);
      expect(easeOutCubic(0.5), greaterThan(0.5));
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

      final Offset right = controlPointOf(
        r,
        CanvasSide.right,
        const Offset(400, 50),
      );
      expect(right.dx, greaterThan(r.centerRight.dx), reason: '应该往右伸');
      expect(right.dy, closeTo(r.centerRight.dy, 1e-9));

      final Offset top = controlPointOf(
        r,
        CanvasSide.top,
        const Offset(50, -400),
      );
      expect(top.dy, lessThan(r.topCenter.dy));
      expect(top.dx, closeTo(r.topCenter.dx, 1e-9));
    });

    test('控制点伸出距离有上限', () {
      const Rect r = Rect.fromLTWH(0, 0, 100, 100);

      final Offset far = controlPointOf(
        r,
        CanvasSide.right,
        const Offset(99999, 50),
      );

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

  test('数学常数没被写错（防止手滑改坏 maxReach / fitPadding）', () {
    expect(CanvasEdgeGeometry.maxReach, 96);
    expect(CanvasCamera.fitPadding, 90);
    expect(CanvasCamera.minZoom, 1e-6);
    expect(math.max(1, 2), 2);
  });
}
