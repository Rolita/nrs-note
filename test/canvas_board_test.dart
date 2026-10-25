import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/core/utils/canvas_geometry.dart';
import 'package:nrs/ui/canvas/canvas_board.dart';
import 'package:nrs/ui/canvas/canvas_card.dart';
import 'package:nrs/ui/canvas/canvas_style.dart';

TextNode textNode(
  String id, {
  required double x,
  required double y,
  double width = 250,
  double height = 120,
  String text = '卡片',
  String? color,
}) => TextNode(
  id: id,
  x: x,
  y: y,
  width: width,
  height: height,
  text: text,
  color: color,
);

CanvasDocument docWith(List<CanvasNode> nodes) =>
    CanvasDocument(nodes: nodes, edges: <CanvasEdge>[]);

class Harness {
  Harness(this.state, this.doc);

  final CanvasBoardState state;

  /// 板子改的那份文档。测试直接看它，比看界面稳。
  final CanvasDocument? doc;

  double get zoom => state.debugZoom;
  Offset get offset => state.debugOffset;

  List<CanvasNode> get nodes => doc?.nodes ?? const <CanvasNode>[];
}

Future<Harness> pumpBoard(
  WidgetTester tester, {
  CanvasDocument? document,
  bool readOnly = false,
  Size size = const Size(1000, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final CanvasDocument? doc = readOnly
      ? null
      : (document ?? docWith(<CanvasNode>[]));
  final GlobalKey<CanvasBoardState> key = GlobalKey<CanvasBoardState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.dark),
      home: Scaffold(body: CanvasBoard(key: key, document: doc)),
    ),
  );
  await tester.pumpAndSettle();
  return Harness(key.currentState!, doc);
}

/// 滚一下。`ctrl` 为真时按住 Ctrl（= 缩放）。
Future<void> scroll(
  WidgetTester tester,
  Offset at,
  Offset delta, {
  bool ctrl = false,
  bool shift = false,
}) async {
  if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  final TestPointer pointer = TestPointer(9, PointerDeviceKind.mouse);
  pointer.hover(at);
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pump();
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

/// 世界坐标 → 屏幕坐标。测试里不手算，一律问视口。
Offset screenOf(Harness h, Offset world) => h.state.viewport.toScreen(world);

Offset centerOf(Harness h, CanvasNode node) => screenOf(h, node.rect.center);

/// 一张左上角在原点的卡片。
TextNode cardAtOrigin({String id = 'a'}) => textNode(id, x: 0, y: 0);

/// 点一下卡片，然后把双击窗口走完（不留挂起的计时器）。
Future<void> tapCard(
  WidgetTester tester,
  Harness h,
  CanvasNode node,
) async {
  await tester.tapAt(centerOf(h, node));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 双击卡片。两次点击必须落在双击窗口（300ms）之内，所以中间只推 40ms。
Future<void> doubleTapCard(
  WidgetTester tester,
  Harness h,
  CanvasNode node,
) async {
  final Offset at = centerOf(h, node);
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(at);
  await tester.pump();
}

void main() {
  group('空板', () {
    testWidgets('给一句提示，工具条显示 100%', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      expect(find.text('这块白板还是空的'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(h.zoom, 1);
    });

    testWidgets('空板的视口把原点摆在正中', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      expect(h.state.debugStage, const Size(1000, 700));
      expect(h.offset, const Offset(500, 350));
    });

    testWidgets('只读空板不说「双击新建」', (WidgetTester tester) async {
      await pumpBoard(tester, readOnly: true);

      expect(find.textContaining('双击'), findsNothing);
      expect(find.textContaining('滚轮平移'), findsOneWidget);
    });
  });

  group('打开有内容的白板', () {
    testWidgets('首帧就适应窗口，内容是居中的', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[
          textNode('a', x: 0, y: 0),
          textNode('b', x: 600, y: 400),
        ]),
      );

      // 内容包围盒 850×520，装进 1000×700 且四周留 90px：
      // min(820/850, 520/520) = 0.964…
      expect(h.zoom, closeTo(820 / 850, 1e-6));

      // 内容中心 (425, 260) 落在舞台中心 (500, 350)。
      final Offset center = h.state.viewport.toScreen(const Offset(425, 260));
      expect(center.dx, closeTo(500, 1e-6));
      expect(center.dy, closeTo(350, 1e-6));
    });

    testWidgets('有内容时不显示空板提示', (WidgetTester tester) async {
      await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[textNode('a', x: 0, y: 0)]),
      );

      expect(find.text('这块白板还是空的'), findsNothing);
    });
  });

  group('平移', () {
    testWidgets('中键拖动整块画布跟着走', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final Offset before = h.offset;

      final TestGesture g = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await g.moveBy(const Offset(60, -40));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(h.offset, before + const Offset(60, -40));
      expect(h.state.debugPanning, isFalse, reason: '松手要回到 idle');
    });

    testWidgets('空格 + 左键也能平移', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      // 先点一下让白板拿到键盘。
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      final Offset before = h.offset;

      final TestGesture g = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(-30, 25));
      await tester.pump();
      await g.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(h.offset, before + const Offset(-30, 25));
    });

    testWidgets('滚轮上下平移', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final Offset before = h.offset;

      await scroll(tester, const Offset(400, 300), const Offset(0, 100));

      // 内容跟着手指走：滚轮向下（dy > 0）内容上移。
      expect(h.offset, before + const Offset(0, -100));
    });

    testWidgets('Shift + 滚轮左右平移', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final Offset before = h.offset;

      await scroll(
        tester,
        const Offset(400, 300),
        const Offset(0, 80),
        shift: true,
      );

      expect(h.offset, before + const Offset(-80, 0));
    });
  });

  group('缩放', () {
    testWidgets('Ctrl + 滚轮以光标为锚点：光标下那一点不动', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      const Offset anchor = Offset(320, 240);
      final Offset worldBefore = h.state.viewport.toWorld(anchor);

      await scroll(tester, anchor, const Offset(0, -120), ctrl: true);

      expect(h.zoom, greaterThan(1), reason: '往上滚应该放大');
      final Offset worldAfter = h.state.viewport.toWorld(anchor);
      expect(worldAfter.dx, closeTo(worldBefore.dx, 1e-6));
      expect(worldAfter.dy, closeTo(worldBefore.dy, 1e-6));
    });

    testWidgets('滚轮缩放上下限夹住', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      for (int i = 0; i < 40; i++) {
        await scroll(tester, const Offset(500, 350), const Offset(0, -200),
            ctrl: true);
      }
      expect(h.zoom, CanvasViewport.maxZoom);

      for (int i = 0; i < 80; i++) {
        await scroll(tester, const Offset(500, 350), const Offset(0, 200),
            ctrl: true);
      }
      expect(h.zoom, CanvasViewport.minZoom);
    });

    testWidgets('加号放大、减号缩小，点百分比回 100%', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await tester.tap(find.byIcon(LucideIcons.plus).first);
      await tester.pump();
      expect(h.zoom, greaterThan(1));

      final double zoomed = h.zoom;
      await tester.tap(find.byIcon(LucideIcons.minus).first);
      await tester.pump();
      expect(h.zoom, lessThan(zoomed));

      await tester.tap(find.textContaining('%'));
      await tester.pump();
      expect(h.zoom, 1);
    });

    testWidgets('缩放时舞台中心不动', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      const Offset stageCenter = Offset(500, 350);
      final Offset world = h.state.viewport.toWorld(stageCenter);

      h.state.zoomIn();
      await tester.pump();

      final Offset after = h.state.viewport.toScreen(world);
      expect(after.dx, closeTo(stageCenter.dx, 1e-6));
      expect(after.dy, closeTo(stageCenter.dy, 1e-6));
    });

    testWidgets('适应窗口把内容装回来', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[textNode('a', x: 0, y: 0)]),
      );
      final double initial = h.zoom;

      h.state.resetZoom();
      await tester.pump();
      expect(h.zoom, 1);

      h.state.fitToContent();
      await tester.pump();
      expect(h.zoom, closeTo(initial, 1e-9));
    });
  });

  group('框选', () {
    testWidgets('空白处左键拖出一个框，松手就收掉', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      final TestGesture g = await tester.startGesture(
        const Offset(200, 200),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(120, 90));
      await tester.pump();

      final Rect? box = h.state.debugMarquee;
      expect(box, isNotNull);
      expect(box!.left, closeTo(200, 1e-6));
      expect(box.top, closeTo(200, 1e-6));
      expect(box.width, closeTo(120, 1e-6));
      expect(box.height, closeTo(90, 1e-6));

      await g.up();
      await tester.pump();
      expect(h.state.debugMarquee, isNull);
    });

    testWidgets('框选时画布不跟着平移', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final Offset before = h.offset;

      final TestGesture g = await tester.startGesture(
        const Offset(200, 200),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(120, 90));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(h.offset, before, reason: '左键拖空白是框选，不是平移');
    });

    testWidgets('框选时滚轮滚了，框还贴在内容上', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      final TestGesture g = await tester.startGesture(
        const Offset(200, 200),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(100, 100));
      await tester.pump();
      final Rect before = h.state.debugMarquee!;

      // 滚轮向下 = 内容上移 50px，框跟着内容一起走。
      await scroll(tester, const Offset(400, 300), const Offset(0, 50));
      final Rect after = h.state.debugMarquee!;

      expect(after.top, closeTo(before.top - 50, 1e-6));
      await g.up();
      await tester.pump();
    });
  });

  group('双击空白', () {
    testWidgets('新建一张卡片', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await tester.tapAt(const Offset(300, 250));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(302, 251));
      await tester.pump();

      expect(h.nodes.length, 1);
    });

    testWidgets('隔太久的两次单击不算双击', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await tester.tapAt(const Offset(300, 250));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.tapAt(const Offset(300, 250));
      await tester.pump();

      expect(h.nodes, isEmpty);
    });

    testWidgets('同一处连点三下只建一张', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await tester.tapAt(const Offset(300, 250));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(const Offset(300, 250));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(const Offset(300, 250));
      await tester.pump();

      expect(h.nodes.length, 1);
    });
  });

  group('选中', () {
    testWidgets('单击卡片选中它', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );

      await tapCard(tester, h, h.nodes.first);

      expect(h.state.debugSelection, <String>{'a'});
    });

    testWidgets('单击空白清掉选择', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      expect(h.state.debugSelection, isNotEmpty);

      await tester.tapAt(const Offset(30, 30));
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugSelection, isEmpty);
    });

    testWidgets('Ctrl + 单击加选，再点一次减选', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 400),
        ]),
      );
      final CanvasNode a = h.doc!.nodeById('a')!;
      final CanvasNode b = h.doc!.nodeById('b')!;

      await tapCard(tester, h, a);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapCard(tester, h, b);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(h.state.debugSelection, <String>{'a', 'b'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapCard(tester, h, b);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(h.state.debugSelection, <String>{'a'});
    });

    testWidgets('拖动时整组跟着走', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 400),
        ]),
      );
      final CanvasNode a = h.doc!.nodeById('a')!;
      final CanvasNode b = h.doc!.nodeById('b')!;

      await tapCard(tester, h, a);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapCard(tester, h, b);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      final double d = 20 * h.zoom;
      final TestGesture g = await tester.startGesture(
        centerOf(h, a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(d, d));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.x, closeTo(20, 1e-6));
      expect(a.y, closeTo(20, 1e-6));
      expect(b.x, closeTo(420, 1e-6), reason: '整组一起走');
      expect(b.y, closeTo(420, 1e-6));
    });
  });

  group('拖动卡片', () {
    testWidgets('跟着指针走，松手吸附网格', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      final double d = 20 * h.zoom;

      final TestGesture g = await tester.startGesture(
        centerOf(h, a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(d, d));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.x, closeTo(20, 1e-6));
      expect(a.y, closeTo(20, 1e-6));
    });

    testWidgets('按下去不动，卡片一点也不挪', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        centerOf(h, a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(2, 2));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.x, 0);
      expect(a.y, 0);
    });

    testWidgets('拖到半个格子上，松手吸附到最近的格点', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      // 世界坐标 +16：离格点 20 只有 4，在吸附容差（6）之内。
      final double d = 16 * h.zoom;

      final TestGesture g = await tester.startGesture(
        centerOf(h, a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(d, d));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.x, 20);
      expect(a.y, 20);
    });

    testWidgets('拖动只动位置，不动尺寸', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        centerOf(h, a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(20 * h.zoom, 20 * h.zoom));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.width, 250);
      expect(a.height, 120);
    });
  });

  group('缩放手柄', () {
    testWidgets('拖右下角把卡片拉大', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      await tapCard(tester, h, a);

      final Rect screen = h.state.viewport.rectToScreen(a.rect);
      final double d = 20 * h.zoom;
      final TestGesture g = await tester.startGesture(
        screen.bottomRight,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(d, d));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.width, closeTo(270, 1e-6));
      expect(a.height, closeTo(140, 1e-6));
    });

    testWidgets('拖左上角往右下，撞到最小尺寸就停', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      await tapCard(tester, h, a);

      final Rect screen = h.state.viewport.rectToScreen(a.rect);
      final TestGesture g = await tester.startGesture(
        screen.topLeft,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(9999, 9999));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.width, canvasCardMinSide);
      expect(a.height, canvasCardMinSide);
    });

    testWidgets('没选中时不出手柄，按在卡片角上是拖动', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      final Rect screen = h.state.viewport.rectToScreen(a.rect);

      final TestGesture g = await tester.startGesture(
        screen.topLeft,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(30, 30));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.width, 250, reason: '手柄只在选中时存在');
    });
  });

  group('删除', () {
    testWidgets('Delete 删掉选中的卡片，连带删掉它的边', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
        ],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(doc.nodes.map((CanvasNode n) => n.id), <String>['b']);
      expect(doc.edges, isEmpty);
      expect(h.state.debugSelection, isEmpty);
    });

    testWidgets('没有选中时 Delete 什么也不做', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin()]);
      await pumpBoard(tester, document: doc);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(doc.nodes.length, 1);
    });
  });

  group('编辑', () {
    testWidgets('双击卡片进编辑，打字写回节点', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      await doubleTapCard(tester, h, a);
      expect(h.state.debugEditing, 'a');

      await tester.enterText(find.byType(TextField), '写点东西');
      await tester.pump();

      expect((a as TextNode).text, '写点东西');
    });

    testWidgets('点空白处退出编辑', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      await doubleTapCard(tester, h, a);
      await tester.enterText(find.byType(TextField), '收工');
      await tester.pump();

      await tester.tapAt(const Offset(30, 30));
      await tester.pump();

      expect(h.state.debugEditing, isNull);
      expect((a as TextNode).text, '收工');
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('Esc 退出编辑', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      await doubleTapCard(tester, h, a);
      await tester.enterText(find.byType(TextField), '半句话');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(h.state.debugEditing, isNull);
      expect((a as TextNode).text, '半句话');
    });
  });

  group('新建', () {
    testWidgets('工具条上的加号建一张卡片，直接进编辑', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await tester.tap(find.byIcon(LucideIcons.squarePlus));
      await tester.pump();

      expect(h.nodes.length, 1);
      expect(h.state.debugEditing, h.nodes.first.id);
      expect(h.state.debugSelection, <String>{h.nodes.first.id});
    });

    testWidgets('只读板没有新建按钮', (WidgetTester tester) async {
      await pumpBoard(tester, readOnly: true);

      expect(find.byIcon(LucideIcons.squarePlus), findsNothing);
    });
  });

  group('换色', () {
    testWidgets('右键卡片选红色，存的是规范值 1', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        centerOf(h, a),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('红色'));
      await tester.pumpAndSettle();

      expect(h.state.debugColorOf('a'), '1');
    });

    testWidgets('选「无颜色」把颜色清掉', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[
          textNode('a', x: 0, y: 0, color: '4'),
        ]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        centerOf(h, a),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('无颜色'));
      await tester.pumpAndSettle();

      expect(h.state.debugColorOf('a'), isNull);
    });
  });

  group('点阵', () {
    test('缩得太小时彻底不画', () {
      expect(canvasGridOpacity(0.2), 0);
      expect(canvasGridOpacity(canvasGridFadeOut), 0);
    });

    test('从淡出线往上线性淡入', () {
      expect(canvasGridOpacity(1), 1);
      final double mid =
          canvasGridOpacity(canvasGridFadeOut * 1.3);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));
    });

    test('放大到 200% 以上间距翻倍', () {
      expect(canvasGridStep(1), canvasGridSize);
      expect(canvasGridStep(1.9), canvasGridSize);
      expect(canvasGridStep(2), canvasGridSize * 2);
      expect(canvasGridStep(3.5), canvasGridSize * 2);
    });
  });
}
