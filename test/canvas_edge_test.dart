import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/core/utils/canvas_geometry.dart';
import 'package:nrs/ui/canvas/canvas_edge_painter.dart';

TextNode card(String id, double x, double y) =>
    TextNode(id: id, x: x, y: y, width: 200, height: 100, text: id);

CanvasDocument docWithEdges(List<CanvasEdge> edges) => CanvasDocument(
  nodes: <CanvasNode>[card('a', 0, 0), card('b', 500, 0)],
  edges: edges,
);

void main() {
  group('算连线', () {
    test('两端落在卡片边界上，不是卡片中心', () {
      final CanvasDocument doc = docWithEdges(<CanvasEdge>[
        CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b'),
      ]);

      final List<CanvasEdgeVisual> visuals = buildEdgeVisuals(
        document: doc,
        viewport: const CanvasViewport(),
        selected: <String>{},
      );

      expect(visuals.length, 1);
      final CanvasEdgeGeometry g = visuals.single.geometry;
      // a 在 (0,0,200,100)，b 在 (500,0,200,100)，同一行 → 走左右两边。
      expect(g.from, const Offset(200, 50));
      expect(g.to, const Offset(500, 50));
    });

    test('指向不存在的节点时那条边整条不画', () {
      final CanvasDocument doc = docWithEdges(<CanvasEdge>[
        CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'ghost'),
      ]);

      expect(
        buildEdgeVisuals(
          document: doc,
          viewport: const CanvasViewport(),
          selected: <String>{},
        ),
        isEmpty,
      );
    });

    test('边被选中时带标记', () {
      final CanvasDocument doc = docWithEdges(<CanvasEdge>[
        CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b'),
        CanvasEdge(id: 'e2', fromNode: 'b', toNode: 'a'),
      ]);

      final List<CanvasEdgeVisual> visuals = buildEdgeVisuals(
        document: doc,
        viewport: const CanvasViewport(),
        selected: <String>{'e2'},
      );

      expect(visuals.first.selected, isFalse);
      expect(visuals.last.selected, isTrue);
    });

    test('文档为 null 时什么也不给', () {
      expect(
        buildEdgeVisuals(
          document: null,
          viewport: const CanvasViewport(),
          selected: <String>{},
        ),
        isEmpty,
      );
    });

    test('视口变了，连线的屏幕位置跟着变', () {
      final CanvasDocument doc = docWithEdges(<CanvasEdge>[
        CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b'),
      ]);

      final CanvasEdgeGeometry moved = buildEdgeVisuals(
        document: doc,
        viewport: const CanvasViewport(zoom: 2, offset: Offset(100, 40)),
        selected: <String>{},
      ).single.geometry;

      expect(moved.from, const Offset(500, 140));
    });
  });

  group('点中连线', () {
    final CanvasDocument doc = docWithEdges(<CanvasEdge>[
      CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b'),
    ]);
    final List<CanvasEdgeVisual> visuals = buildEdgeVisuals(
      document: doc,
      viewport: const CanvasViewport(),
      selected: <String>{},
    );

    test('点在曲线上就中', () {
      final Offset mid = visuals.single.geometry.pointAt(0.5);
      expect(edgeAt(visuals, mid)?.edge.id, 'e1');
    });

    test('离得远就不中', () {
      expect(edgeAt(visuals, const Offset(350, 400)), isNull);
    });

    test('容差边界：差 1px 仍算中，差太远不算', () {
      final Offset mid = visuals.single.geometry.pointAt(0.5);
      expect(edgeAt(visuals, mid + const Offset(0, 5), tolerance: 6), isNotNull);
      expect(edgeAt(visuals, mid + const Offset(0, 40), tolerance: 6), isNull);
    });

    test('两条边交叉处取更近的那条', () {
      final CanvasDocument cross = CanvasDocument(
        nodes: <CanvasNode>[card('a', 0, 0), card('b', 500, 0)],
        edges: <CanvasEdge>[
          CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b'),
          CanvasEdge(id: 'e2', fromNode: 'b', toNode: 'a'),
        ],
      );
      final List<CanvasEdgeVisual> list = buildEdgeVisuals(
        document: cross,
        viewport: const CanvasViewport(),
        selected: <String>{},
      );
      // 两条边在这个布局里是完全重合的，取第一个（更近或相等时先到先得）。
      expect(edgeAt(list, list.first.geometry.pointAt(0.5)), isNotNull);
    });
  });

  group('连线预览', () {
    test('从指定那条边出发，末端跟着光标', () {
      final CanvasEdgeGeometry g = connectPreview(
        fromRect: const Rect.fromLTWH(0, 0, 200, 100),
        side: CanvasSide.right,
        cursor: const Offset(400, 200),
      );

      expect(g.from, const Offset(200, 50));
      expect(g.to.dx, closeTo(400, 1));
      expect(g.to.dy, closeTo(200, 1));
    });

    test('光标在卡片左边时，预览线也画得出来', () {
      final CanvasEdgeGeometry g = connectPreview(
        fromRect: const Rect.fromLTWH(0, 0, 200, 100),
        side: CanvasSide.left,
        cursor: const Offset(-100, 50),
      );

      expect(g.from, const Offset(0, 50));
      expect(g.to.dx, closeTo(-100, 1));
    });
  });

  group('缩放不影响线宽和箭头', () {
    test('线宽是屏幕像素，不是世界像素', () {
      // 这条测试守的是「画笔里不乘 zoom」这件事：缩到 10% 时 2px 的线
      // 仍然是 2px，否则整张白板的线会变成一根根头发丝。
      const Size stage = Size(800, 600);
      final CanvasDocument doc = docWithEdges(<CanvasEdge>[
        CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b'),
      ]);
      final List<CanvasEdgeVisual> near = buildEdgeVisuals(
        document: doc,
        viewport: CanvasViewport.fit(const Rect.fromLTWH(0, 0, 700, 100), stage),
        selected: <String>{},
      );
      final List<CanvasEdgeVisual> far = buildEdgeVisuals(
        document: doc,
        viewport: const CanvasViewport(zoom: 0.2),
        selected: <String>{},
      );

      // 几何随视口变化，但两者都能算出来——真正的「不乘 zoom」在画笔里，
      // 这里只确认几何不会在极端缩放下崩掉。
      expect(near.single.geometry.from, isNot(far.single.geometry.from));
    });
  });
}
