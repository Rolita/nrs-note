import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/core/utils/canvas_geometry.dart';
import 'package:nrs/ui/canvas/canvas_board.dart';
import 'package:nrs/ui/canvas/canvas_painter.dart';
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

  CanvasCamera get camera => state.debugCamera;
  Size get stage => state.debugStage;
  double get zoom => state.debugZoom;
  Offset get center => state.debugCenter;

  /// 世界坐标 → 屏幕坐标。
  Offset screenOf(Offset world) => camera.toScreen(world, stage);

  Rect screenRect(Rect world) => camera.rectToScreen(world, stage);

  Offset centerOf(CanvasNode node) => screenOf(node.rect.center);

  List<CanvasNode> get nodes => doc?.nodes ?? const <CanvasNode>[];
}

Future<Harness> pumpBoard(
  WidgetTester tester, {
  CanvasDocument? document,
  bool readOnly = false,
  Size size = const Size(1000, 700),
  List<({String path, String title})> files =
      const <({String path, String title})>[],
  ValueChanged<String>? onOpenFile,
  ValueChanged<String>? onOpenLink,
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
      theme: AppTheme.build(AppPalette.midnight),
      home: Scaffold(
        body: CanvasBoard(
          key: key,
          document: doc,
          files: files,
          onOpenFile: onOpenFile,
          onOpenLink: onOpenLink,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return Harness(key.currentState!, doc);
}

/// 滚一下滚轮（= 缩放）。dy 为负是往上滚。
Future<void> scroll(WidgetTester tester, Offset at, Offset delta) async {
  final TestPointer pointer = TestPointer(9, PointerDeviceKind.mouse);
  pointer.hover(at);
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pump();
}

/// 一张左上角在原点的卡片。
TextNode cardAtOrigin({String id = 'a'}) => textNode(id, x: 0, y: 0);

/// 点一下卡片，然后把双击窗口走完（不留挂起的计时器）。
Future<void> tapCard(WidgetTester tester, Harness h, CanvasNode node) async {
  await tester.tapAt(h.centerOf(node));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 双击卡片。两次点击必须落在双击窗口（300ms）之内，所以中间只推 40ms。
Future<void> doubleTapCard(
  WidgetTester tester,
  Harness h,
  CanvasNode node,
) async {
  final Offset at = h.centerOf(node);
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(at);
  await tester.pump();
}

/// 悬停到某一点（鼠标指针移到那里，不按下）。
Future<void> hoverAt(WidgetTester tester, Offset at) async {
  final TestPointer pointer = TestPointer(9, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.pump();
}

/// 让白板拿到键盘，并把双击窗口走完。
Future<void> focusBoard(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 300));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 敲一下键（按下 + 抬起 + 等动画走完）。
Future<void> pressKey(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pumpAndSettle();
}

/// 按住 Ctrl 敲一下键。
///
/// 必须真的把 Ctrl 按下去：白板判断的是 `HardwareKeyboard.isControlPressed`，
/// 直接发 `key` 不管用。
Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// 直接把键盘焦点交给白板。
///
/// 不能靠「点一下空白」来要焦点——卡片在屏幕上的位置跟着摄像机走，测试里
/// 很难保证点中的地方真是空白。外壳切到白板视图时调的就是这个方法。
Future<void> grabKeyboard(WidgetTester tester, Harness h) async {
  h.state.requestFocus();
  await tester.pump();
}

void main() {
  group('空板', () {
    testWidgets('给一句提示，右下角不再有工具条', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      expect(h.state.debugEmptyHint, isNotNull);
      expect(h.state.debugEmptyHint!.$1, '这块白板还是空的');
      expect(h.zoom, 1);
      // 整颗工具条都移掉了：百分比、适应窗口、新建、加减全都不在。
      expect(find.textContaining('%'), findsNothing);
      expect(find.byIcon(LucideIcons.plus), findsNothing);
      expect(find.byIcon(LucideIcons.minus), findsNothing);
      expect(find.byIcon(LucideIcons.maximize), findsNothing);
      expect(find.byIcon(LucideIcons.squarePlus), findsNothing);
    });

    testWidgets('空板把世界原点摆在画面正中', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      expect(h.stage, const Size(1000, 700));
      expect(h.center, Offset.zero);
      expect(h.screenOf(Offset.zero), const Offset(500, 350));
    });

    testWidgets('只读空板不说「双击新建」', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester, readOnly: true);

      expect(h.state.debugEmptyHint!.$2.contains('双击'), isFalse);
      expect(h.state.debugEmptyHint!.$2.contains('滚轮'), isTrue);
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
      final Offset center = h.screenOf(const Offset(425, 260));
      expect(center.dx, closeTo(500, 1e-6));
      expect(center.dy, closeTo(350, 1e-6));
    });

    testWidgets('有内容时不给空板提示', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[textNode('a', x: 0, y: 0)]),
      );

      expect(h.state.debugEmptyHint, isNull);
    });
  });

  group('平移', () {
    testWidgets('中键拖动整块画布跟着走', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final Offset before = h.center;

      final TestGesture g = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await g.moveBy(const Offset(60, -40));
      await tester.pump();
      await g.up();
      await tester.pump();

      // 拖 60,-40 屏幕像素 = 摄像机中心反向走 60,-40（zoom = 1）。
      expect(h.center, before + const Offset(-60, 40));
      expect(h.state.debugPanning, isFalse, reason: '松手要回到 idle');
    });

    testWidgets('空格 + 左键也能平移', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      await focusBoard(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      final Offset before = h.center;

      final TestGesture g = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(-30, 25));
      await tester.pump();
      await g.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(h.center, before + const Offset(30, -25));
    });

    testWidgets('滚轮往上放大、往下缩小', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await scroll(tester, const Offset(400, 300), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(h.zoom, greaterThan(1), reason: '往上滚 = 放大');

      final double zoomedIn = h.zoom;
      await scroll(tester, const Offset(400, 300), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(h.zoom, lessThan(zoomedIn), reason: '往下滚 = 缩小');
    });

    testWidgets('按住 W 摄像机往上看，松手惯性滑停', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      await focusBoard(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyW);
      await tester.pump(const Duration(milliseconds: 16));
      final double first = h.center.dy;
      expect(first, lessThan(0), reason: 'W 把视线往上推');

      await tester.pump(const Duration(milliseconds: 120));
      expect(h.center.dy, lessThan(first));

      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyW);
      await tester.pumpAndSettle();
      expect(h.state.debugTicking, isFalse, reason: '停下来就别再跑计时器');
    });
  });

  group('缩放', () {
    testWidgets('滚轮缩放以光标为锚点：光标下那一点不动', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      const Offset anchor = Offset(320, 240);
      final Offset worldBefore = h.camera.toWorld(anchor, h.stage);

      await scroll(tester, anchor, const Offset(0, -120));
      await tester.pumpAndSettle();

      expect(h.zoom, greaterThan(1), reason: '往上滚应该放大');
      final Offset worldAfter = h.camera.toWorld(anchor, h.stage);
      expect(worldAfter.dx, closeTo(worldBefore.dx, 1e-6));
      expect(worldAfter.dy, closeTo(worldBefore.dy, 1e-6));
    });

    testWidgets('滚轮缩放没有上限', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      for (int i = 0; i < 20; i++) {
        await scroll(tester, const Offset(500, 350), const Offset(0, -100));
      }
      await tester.pumpAndSettle();

      expect(h.zoom, greaterThan(8), reason: '原来 800% 就封顶了');
      expect(h.zoom, greaterThan(100), reason: '连放 20 格应该远不止 800%');
      expect(h.state.debugTargetZoom, h.zoom);
    });

    testWidgets('往下滚能一直缩，只挡住 0', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      for (int i = 0; i < 120; i++) {
        await scroll(tester, const Offset(500, 350), const Offset(0, 200));
      }
      await tester.pumpAndSettle();

      expect(h.zoom, lessThan(0.08), reason: '原来 8% 就到底了');
      expect(h.zoom, greaterThan(0), reason: '下限只挡 0，不能变成 0');
      expect(h.state.debugTargetZoom, h.zoom);
    });

    testWidgets('zoomIn / zoomOut 一步 1.25 倍', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      h.state.zoomIn();
      await tester.pumpAndSettle();
      expect(h.zoom, closeTo(1.25, 1e-3));

      h.state.zoomOut();
      await tester.pumpAndSettle();
      expect(h.zoom, closeTo(1, 1e-3));
    });

    testWidgets('缩放时舞台中心不动', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      const Offset stageCenter = Offset(500, 350);
      final Offset world = h.camera.toWorld(stageCenter, h.stage);

      h.state.zoomIn();
      await tester.pumpAndSettle();

      final Offset after = h.camera.toScreen(world, h.stage);
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
      await tester.pumpAndSettle();
      expect(h.zoom, closeTo(1, 1e-3));

      h.state.fitToContent();
      await tester.pumpAndSettle();
      expect(h.zoom, closeTo(initial, 1e-3));
    });

    testWidgets('Ctrl+0 回到 100%', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      await focusBoard(tester);

      await scroll(tester, const Offset(500, 350), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(h.zoom, greaterThan(1));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(h.zoom, closeTo(1, 1e-3));
    });
  });

  group('视野', () {
    testWidgets('] 放大、[ 缩小，锚点是画面中心', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      await focusBoard(tester);
      final Offset before = h.center;

      await pressKey(tester, LogicalKeyboardKey.bracketRight);
      expect(h.zoom, closeTo(1.25, 1e-3));
      expect(h.center, before, reason: '以画面中心为锚点，中心不该动');

      await pressKey(tester, LogicalKeyboardKey.bracketLeft);
      expect(h.zoom, closeTo(1, 1e-3));
      expect(h.center, before);
    });

    testWidgets('PageUp / PageDown 上下翻一屏，Home / End 左右翻', (
      WidgetTester tester,
    ) async {
      final Harness h = await pumpBoard(tester);
      await focusBoard(tester);
      final Offset before = h.center;

      await pressKey(tester, LogicalKeyboardKey.pageUp);
      expect(
        h.center.dy,
        closeTo(before.dy - h.stage.height * canvasPagePanRatio, 1e-6),
      );
      expect(h.center.dx, closeTo(before.dx, 1e-6));

      await pressKey(tester, LogicalKeyboardKey.pageDown);
      expect(h.center.dy, closeTo(before.dy, 1e-6));

      await pressKey(tester, LogicalKeyboardKey.home);
      expect(
        h.center.dx,
        closeTo(before.dx - h.stage.width * canvasPagePanRatio, 1e-6),
      );

      await pressKey(tester, LogicalKeyboardKey.end);
      expect(h.center.dx, closeTo(before.dx, 1e-6));
    });

    testWidgets('F 没选中就适应全部内容', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[
          textNode('a', x: 0, y: 0),
          textNode('b', x: 3000, y: 2000),
        ]),
      );
      await focusBoard(tester);
      final double fitted = h.zoom;

      await pressKey(tester, LogicalKeyboardKey.bracketRight);
      expect(h.zoom, greaterThan(fitted));

      await pressKey(tester, LogicalKeyboardKey.keyF);
      expect(h.zoom, closeTo(fitted, 1e-6));
    });

    testWidgets('F 有选中就只框住选中那一块', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        textNode('a', x: 0, y: 0),
        textNode('b', x: 3000, y: 2000),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final double allZoom = h.zoom;

      await tester.tapAt(h.screenOf(doc.nodeById('a')!.rect.center));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'a'});

      await pressKey(tester, LogicalKeyboardKey.keyF);

      expect(h.zoom, greaterThan(allZoom), reason: '只看一小块，应该更近');
      final Rect visible = h.state.debugVisibleWorld;
      expect(visible.contains(doc.nodeById('a')!.rect.center), isTrue);
      expect(visible.contains(doc.nodeById('b')!.rect.center), isFalse);
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

      // 框是**世界**坐标：屏幕 (200,200) 对应世界 (-300,-150)。
      final Rect? box = h.state.debugMarquee;
      expect(box, isNotNull);
      expect(box!.left, closeTo(-300, 1e-6));
      expect(box.top, closeTo(-150, 1e-6));
      expect(box.width, closeTo(120, 1e-6));
      expect(box.height, closeTo(90, 1e-6));

      await g.up();
      await tester.pump();
      expect(h.state.debugMarquee, isNull);
    });

    testWidgets('框选时画布不跟着平移', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final Offset before = h.center;

      final TestGesture g = await tester.startGesture(
        const Offset(200, 200),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(120, 90));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(h.center, before, reason: '左键拖空白是框选，不是平移');
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
      final Offset screenBefore = h.screenOf(before.topLeft);

      // 框选途中缩一下滚轮：内容在屏幕上放大位移了，但框存的是**世界**坐标，
      // 所以世界矩形一个数都不变，只是被换算到了新的屏幕位置。
      await scroll(tester, const Offset(400, 300), const Offset(0, -120));
      await tester.pumpAndSettle();
      final Rect after = h.state.debugMarquee!;

      expect(after, before);
      expect(
        (h.screenOf(after.topLeft) - screenBefore).distance,
        greaterThan(1),
        reason: '屏幕上应该跟着内容动了',
      );
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

    testWidgets('拖动时多选整组跟着走', (WidgetTester tester) async {
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
        h.centerOf(a),
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
    testWidgets('跟着指针走，坐标是自由浮点不吸附', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      // 世界坐标 +16：以前会被吸附到格点 20，现在应该停在 16。
      final double d = 16 * h.zoom;

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(d, d));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.x, closeTo(16, 1e-6));
      expect(a.y, closeTo(16, 1e-6));
    });

    testWidgets('按下去不动，卡片一点也不挪', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(2, 2));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.x, 0);
      expect(a.y, 0);
    });

    testWidgets('拖动只动位置，不动尺寸', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(20 * h.zoom, 20 * h.zoom));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.width, 250);
      expect(a.height, 120);
    });

    testWidgets('缩小之后的拖动仍然按世界坐标算', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      final double before = h.zoom;

      // 屏幕挪 30px，世界位移应该是 30 / zoom。
      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.x, closeTo(30 / before, 1e-6));
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

      final Rect screen = h.screenRect(a.rect);
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

      final Rect screen = h.screenRect(a.rect);
      final TestGesture g = await tester.startGesture(
        screen.topLeft,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(9999, 9999));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.width, canvasMinSize);
      expect(a.height, canvasMinSize);
    });

    testWidgets('没选中时不出手柄，按在卡片角上是拖动', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      final Rect screen = h.screenRect(a.rect);

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

    testWidgets('编辑框跟着摄像机走：缩小后盖在卡片上', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[textNode('a', x: 0, y: 0)]),
      );
      await doubleTapCard(tester, h, h.nodes.first);

      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.style!.fontSize, closeTo(AppText.ui * h.zoom, 1e-6));
    });
  });

  group('新建', () {
    testWidgets('双击空白建一张卡片，直接进编辑', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await tester.tapAt(const Offset(500, 350));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(500, 350));
      await tester.pump();

      expect(h.nodes.length, 1);
      expect(h.state.debugEditing, h.nodes.first.id);
      expect(h.state.debugSelection, <String>{h.nodes.first.id});
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('只读板双击空白不出卡片', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester, readOnly: true);

      await tester.tapAt(const Offset(500, 350));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(500, 350));
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.doc, isNull);
      expect(h.state.debugEditing, isNull);
    });

    testWidgets('新卡片落在视口正中', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pump();

      final CanvasNode a = h.nodes.single;
      expect(a.rect.center.dx, closeTo(h.center.dx, 1e-6));
      expect(a.rect.center.dy, closeTo(h.center.dy, 1e-6));
    });

    testWidgets('新卡片的宽度就是那三个点的宽度', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pump();

      final CanvasNode a = h.nodes.single;
      // 宽度没有自己的常量：量一下那三个点，加上两边内边距，就是这个宽。
      final TextPainter dots = TextPainter(
        text: TextSpan(text: canvasEmptyDots, style: canvasEmptyDotsStyle()),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

      expect(
        a.width,
        closeTo(dots.width + canvasCardPadding * 2 + canvasTextFitSlack, 0.01),
        reason: '刚好装下三个点（外加那 1px 余量），不多给',
      );
      dots.dispose();
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('新卡片的高度就是一行正文，和打完一行字的卡片一样高', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pump();

      final CanvasNode a = h.nodes.single;
      final double emptyWidth = a.width;
      final double emptyHeight = a.height;

      await tester.enterText(find.byType(TextField), 'rtrty');
      await tester.pumpAndSettle();

      expect(a.height, closeTo(emptyHeight, 1e-6), reason: '一行字不该把卡片撑高');
      expect(a.width, greaterThan(emptyWidth), reason: '宽度跟着文字长，不是固定宽');
      await tester.pump(const Duration(milliseconds: 400));
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
        h.centerOf(a),
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
        document: docWith(<CanvasNode>[textNode('a', x: 0, y: 0, color: '4')]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
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

  group('连线', () {
    CanvasDocument twoCards({String? fromSide}) => CanvasDocument(
      nodes: <CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ],
      edges: <CanvasEdge>[
        if (fromSide != null)
          CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b', fromSide: fromSide),
      ],
    );

    /// 一条边的曲线中点（屏幕坐标）。曲线在世界坐标里算，再换算到屏幕。
    Offset edgeMidpoint(
      Harness h,
      CanvasNode a,
      CanvasNode b, {
      CanvasSide? fromSide,
    }) {
      final CanvasEdgeGeometry g = edgeGeometry(
        fromRect: a.rect,
        toRect: b.rect,
        fromSide: fromSide,
      );
      return h.screenOf(g.pointAt(0.5));
    }

    testWidgets('从圆点拖到另一张卡片，建一条边', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      final Offset dot = anchorOf(h.screenRect(a.rect), CanvasSide.right);
      await hoverAt(tester, dot);

      final TestGesture g = await tester.startGesture(
        dot,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(h.centerOf(b));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(doc.edges.length, 1);
      expect(doc.edges.single.fromNode, 'a');
      expect(doc.edges.single.toNode, 'b');
      expect(doc.edges.single.fromSide, 'right');
      expect(h.state.debugSelection, <String>{doc.edges.single.id});
    });

    testWidgets('松手在空白处，不建边', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      final Offset dot = anchorOf(h.screenRect(a.rect), CanvasSide.right);
      await hoverAt(tester, dot);

      final TestGesture g = await tester.startGesture(
        dot,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(const Offset(60, 60));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(doc.edges, isEmpty);
    });

    testWidgets('松手回到自己身上，不建自环', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      final Offset dot = anchorOf(h.screenRect(a.rect), CanvasSide.right);
      await hoverAt(tester, dot);

      final TestGesture g = await tester.startGesture(
        dot,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(h.centerOf(a));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(doc.edges, isEmpty);
    });

    testWidgets('没悬停就没有圆点可拖，按在卡片边上是拖动', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      final Offset dot = anchorOf(h.screenRect(a.rect), CanvasSide.right);
      // 往卡片里挪 6px 再按：卡片边界上本来就不算「在卡片里」。
      final TestGesture g = await tester.startGesture(
        dot - const Offset(6, 0),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(const Offset(60, 60));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(doc.edges, isEmpty);
      expect(a.x, isNot(0), reason: '这一下应该是拖动卡片');
    });

    testWidgets('单击连线选中它', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards(fromSide: 'right');
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      await tester.tapAt(edgeMidpoint(h, a, b, fromSide: CanvasSide.right));
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugSelection, <String>{'e1'});
    });

    testWidgets('双击连线编辑标签，Esc 收下', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards(fromSide: 'right');
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;
      final Offset mid = edgeMidpoint(h, a, b, fromSide: CanvasSide.right);

      await tester.tapAt(mid);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(mid);
      await tester.pump();

      expect(h.state.debugEditingEdge, 'e1');

      await tester.enterText(find.byType(TextField), '依赖');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(h.state.debugEditingEdge, isNull);
      expect(doc.edges.single.label, '依赖');
    });

    testWidgets('标签留空就存 null，不是空字符串', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards(fromSide: 'right');
      doc.edges.single.label = '旧标签';
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      final Offset mid = edgeMidpoint(h, a, b, fromSide: CanvasSide.right);
      await tester.tapAt(mid);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(mid);
      await tester.pump();

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(doc.edges.single.label, isNull);
    });

    testWidgets('选中连线按 Delete 只删线，不删卡片', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards(fromSide: 'right');
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      await tester.tapAt(edgeMidpoint(h, a, b, fromSide: CanvasSide.right));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.delete);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(doc.edges, isEmpty);
      expect(doc.nodes.length, 2);
    });
  });

  group('文件卡片', () {
    testWidgets('双击文件卡片打开那篇笔记，不进编辑', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          FileNode(
            id: 'f1',
            x: 0,
            y: 0,
            width: 250,
            height: 100,
            file: '笔记/甲.md',
          ),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        onOpenFile: opened.add,
      );

      await doubleTapCard(tester, h, doc.nodes.first);

      expect(opened, <String>['笔记/甲.md']);
      expect(h.state.debugEditing, isNull);
    });

    testWidgets('双击链接卡片打开网址', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          LinkNode(
            id: 'l1',
            x: 0,
            y: 0,
            width: 250,
            height: 100,
            url: 'https://example.com',
          ),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        onOpenLink: opened.add,
      );

      await doubleTapCard(tester, h, doc.nodes.first);

      expect(opened, <String>['https://example.com']);
    });

    testWidgets('挑一篇笔记放到白板上', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        files: const <({String path, String title})>[
          (path: 'a.md', title: '甲'),
          (path: 'b.md', title: '乙'),
        ],
      );

      unawaited(h.state.createFileCard());
      await tester.pumpAndSettle();
      await tester.tap(find.text('乙'));
      await tester.pumpAndSettle();

      expect(h.nodes.length, 1);
      expect((h.nodes.first as FileNode).file, 'b.md');
    });
  });

  group('分组', () {
    testWidgets('新建的分组压在最底下', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );

      unawaited(h.state.createGroupCard());
      await tester.pumpAndSettle();

      expect(h.nodes.length, 2);
      expect(h.nodes.first, isA<GroupNode>(), reason: '分组是底板，排在最前面');
      expect(h.nodes.last.id, 'a');
    });

    testWidgets('拖分组把它框住的卡片一起带走', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(
            id: 'g',
            x: -40,
            y: -40,
            width: 400,
            height: 300,
            label: '一组',
          ),
          cardAtOrigin(id: 'inside'),
          textNode('outside', x: 600, y: 0),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode group = doc.nodeById('g')!;
      final CanvasNode inside = doc.nodeById('inside')!;
      final CanvasNode outside = doc.nodeById('outside')!;

      // 点分组框的空白角落（避开里面的卡片）。
      final Offset grab = h.screenOf(Offset(group.x + 10, group.y + 10));
      final TestGesture g = await tester.startGesture(
        grab,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(20 * h.zoom, 20 * h.zoom));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(group.x, closeTo(-20, 1e-6));
      expect(inside.x, closeTo(20, 1e-6), reason: '框里的卡片跟着走');
      expect(outside.x, 600, reason: '框外的卡片不动');
    });

    testWidgets('嵌套分组一起被带走', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(id: 'outer', x: -100, y: -100, width: 800, height: 600),
          GroupNode(id: 'inner', x: -40, y: -40, width: 400, height: 300),
          cardAtOrigin(id: 'card'),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode outer = doc.nodeById('outer')!;
      final CanvasNode inner = doc.nodeById('inner')!;
      final CanvasNode card = doc.nodeById('card')!;

      final Offset grab = h.screenOf(const Offset(-90, -90));
      final TestGesture g = await tester.startGesture(
        grab,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(10 * h.zoom, 0));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(outer.x, closeTo(-90, 1e-6));
      expect(inner.x, closeTo(-30, 1e-6));
      expect(card.x, closeTo(10, 1e-6));
    });

    testWidgets('双击分组改标签', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '旧名字'),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(tester, document: doc);

      await doubleTapCard(tester, h, doc.nodes.first);
      expect(h.state.debugEditing, 'g');

      await tester.enterText(find.byType(TextField), '新名字');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect((doc.nodes.first as GroupNode).label, '新名字');
    });
  });

  group('撤销重做', () {
    testWidgets('新建一张卡片能撤掉，也能再走回来', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      h.state.createCard();
      await tester.pump();
      expect(h.nodes.length, 1);

      h.state.undo();
      await tester.pump();
      expect(h.nodes, isEmpty);

      h.state.redo();
      await tester.pump();
      expect(h.nodes.length, 1);
    });

    testWidgets('拖动一步只占一格撤销', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(20 * h.zoom, 20 * h.zoom));
      await tester.pump();
      await g.moveBy(Offset(20 * h.zoom, 0));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(a.x, closeTo(40, 1e-6));

      h.state.undo();
      await tester.pump();
      // 撤销是「把快照装回来」，节点对象会换一批——所以要看文档里的那张，
      // 不能看手上这个旧引用。
      expect(h.nodes.first.x, 0, reason: '一步撤回整段拖动');
    });

    testWidgets('删除也能撤回来，边一起回来', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
        ],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      h.state.deleteSelection();
      await tester.pump();
      expect(doc.nodes.length, 1);
      expect(doc.edges, isEmpty);

      h.state.undo();
      await tester.pump();
      expect(doc.nodes.length, 2);
      expect(doc.edges.length, 1);
    });

    testWidgets('撤销之后重做栈被新动作作废', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      h.state.createCard();
      await tester.pump();
      h.state.undo();
      await tester.pump();
      expect(h.state.canRedo, isTrue);

      h.state.createCard();
      await tester.pump();
      expect(h.state.canRedo, isFalse);
    });
  });

  group('框选与全选', () {
    testWidgets('框住两张卡片就选中两张', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
        textNode('c', x: 2000, y: 2000),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      final Offset from = h.screenOf(const Offset(-50, -50));
      final Offset to = h.screenOf(const Offset(500, 120));
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(h.state.debugSelection, <String>{'a', 'b'});
    });

    testWidgets('碰一下边就算选中，不用完全框住', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);

      // 只框到卡片右下角的一小块。
      final Offset from = h.screenOf(const Offset(200, 80));
      final Offset to = h.screenOf(const Offset(260, 140));
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(h.state.debugSelection, <String>{'a'});
    });

    testWidgets('Ctrl+A 全选，Esc 清空', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodes.first);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(h.state.debugSelection, <String>{'a', 'b'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(h.state.debugSelection, isEmpty);
    });
  });

  group('复制粘贴', () {
    testWidgets('Ctrl+D 原地复制一份，错开 20', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodes.first);

      h.state.duplicateSelection();
      await tester.pump();

      expect(doc.nodes.length, 2);
      expect(doc.nodes.last.id, isNot('a'), reason: 'id 必须重新发');
      expect(doc.nodes.last.x, 20);
      expect(doc.nodes.last.y, 20);
      expect(h.state.debugSelection, <String>{doc.nodes.last.id});
    });

    testWidgets('复制只带走两端都在选区里的边', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
          textNode('c', x: 800, y: 0),
        ],
        edges: <CanvasEdge>[
          CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b'),
          CanvasEdge(id: 'e2', fromNode: 'b', toNode: 'c'),
        ],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapCard(tester, h, doc.nodeById('b')!);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      h.state.copySelection();
      h.state.pasteClipboard();
      await tester.pump();

      expect(doc.nodes.length, 5);
      expect(doc.edges.length, 3, reason: '只复制 a—b，b—c 的一端在选区外');
    });

    testWidgets('没有复制过就粘贴，什么也不发生', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin()]);
      final Harness h = await pumpBoard(tester, document: doc);

      h.state.pasteClipboard();
      await tester.pump();

      expect(doc.nodes.length, 1);
    });

    testWidgets('粘贴出来的边指向新的卡片，不是原来那张', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
        ],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      h.state.selectAll();
      h.state.copySelection();
      h.state.pasteClipboard();
      await tester.pump();

      final Set<String> pasted = h.state.debugSelection;
      final CanvasEdge copy = doc.edges.last;
      expect(pasted.contains(copy.fromNode), isTrue);
      expect(pasted.contains(copy.toNode), isTrue);
      expect(copy.id, isNot('e1'));
    });
  });

  group('方向键微调', () {
    testWidgets('一次 1px，Shift 一次 10px', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin()]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodes.first;
      await tapCard(tester, h, a);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(a.x, 1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(a.y, 10);
    });
  });

  group('摄像机与内容', () {
    testWidgets('适应窗口包住所有内容，包括很远的那张', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'near'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      doc.nodes.add(textNode('far', x: 4000, y: 3000));
      h.state.fitToContent();
      await tester.pumpAndSettle();

      final Rect visible = h.state.debugVisibleWorld;
      expect(visible.contains(doc.nodeById('near')!.rect.center), isTrue);
      expect(visible.contains(doc.nodeById('far')!.rect.center), isTrue);
      expect(h.zoom, lessThan(1), reason: '内容很大，只能缩小才装得下');
    });

    testWidgets('可见世界矩形和缩放对得上', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      h.state.zoomIn();
      await tester.pumpAndSettle();

      final Rect visible = h.state.debugVisibleWorld;
      expect(visible.width, closeTo(1000 / h.zoom, 1e-6));
      expect(visible.height, closeTo(700 / h.zoom, 1e-6));
      expect(visible.center, h.center);
    });
  });

  group('坐标网格', () {
    test('100% 时主格 100', () {
      expect(canvasGridMajorStep(1), 100);
    });

    test('任何缩放下主格的屏幕步长都落在 [64, 640) 里', () {
      for (final double zoom in <double>[0.08, 0.2, 0.25, 0.5, 1, 2, 4, 8]) {
        final double screen = canvasGridMajorStep(zoom) * zoom;
        expect(
          screen,
          greaterThanOrEqualTo(canvasGridMinScreenStep),
          reason: 'zoom=$zoom 太密',
        );
        expect(screen, lessThan(640), reason: 'zoom=$zoom 太稀');
      }
    });

    test('放大只会让步长变小或不变', () {
      double last = double.infinity;
      for (final double zoom in <double>[0.08, 0.25, 0.5, 1, 2, 4, 8]) {
        final double step = canvasGridMajorStep(zoom);
        expect(step, lessThanOrEqualTo(last), reason: 'zoom=$zoom 反而变大了');
        last = step;
      }
    });

    test('网格线从世界原点开始排，负坐标不漏', () {
      expect(canvasGridLineOffsets(50, 100, 250), <double>[50, 150, 250]);
      expect(canvasGridLineOffsets(-30, 100, 200), <double>[70, 170]);
      expect(canvasGridLineOffsets(0, 100, 0), isEmpty);
      expect(canvasGridLineOffsets(0, 0.5, 100), isEmpty, reason: '不足 1px 不画');
    });

    test('刻度数字是整数，浮点噪声不外泄', () {
      expect(canvasRulerLabel(0), '0');
      expect(canvasRulerLabel(-300), '-300');
      expect(canvasRulerLabel(99.99999999999999), '100');
    });
  });

  group('搜索节点', () {
    testWidgets('Ctrl+F 开搜索框，输入就选中并跳到第一张命中的卡片', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        textNode('a', x: 0, y: 0, text: '苹果'),
        textNode('b', x: 900, y: 0, text: '香蕉'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      await grabKeyboard(tester, h);
      await pressCtrl(tester, LogicalKeyboardKey.keyF);
      expect(h.state.debugSearchOpen, isTrue);

      await tester.enterText(find.byType(TextField), '香蕉');
      await tester.pumpAndSettle();

      expect(h.state.debugSearchHits, <String>['b']);
      expect(h.state.debugSelection, <String>{'b'});
      expect(h.center, doc.nodeById('b')!.rect.center, reason: '镜头移过去了');
    });

    testWidgets('Enter 在命中之间轮换，Shift+Enter 往回', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        textNode('a', x: 0, y: 0, text: 'todo'),
        textNode('b', x: 600, y: 0, text: 'todo'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      await grabKeyboard(tester, h);
      await pressCtrl(tester, LogicalKeyboardKey.keyF);
      await tester.enterText(find.byType(TextField), 'todo');
      await tester.pumpAndSettle();
      expect(h.state.debugSearchHits, <String>['a', 'b']);
      expect(h.state.debugSelection, <String>{'a'});

      await pressKey(tester, LogicalKeyboardKey.enter);
      expect(h.state.debugSelection, <String>{'b'}, reason: '下一个');

      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await pressKey(tester, LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(h.state.debugSelection, <String>{'a'}, reason: '往回一个');
    });

    testWidgets('Esc 关掉搜索框', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );

      await grabKeyboard(tester, h);
      await pressCtrl(tester, LogicalKeyboardKey.keyF);
      expect(h.state.debugSearchOpen, isTrue);

      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(h.state.debugSearchOpen, isFalse);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('搜不到时选中不动，也不报错', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);

      await pressCtrl(tester, LogicalKeyboardKey.keyF);
      await tester.enterText(find.byType(TextField), '不存在的字');
      await tester.pumpAndSettle();

      expect(h.state.debugSearchHits, isEmpty);
      expect(h.state.debugSelection, <String>{'a'});
    });
  });

  group('详细信息面板', () {
    testWidgets('Ctrl+Enter 打开，Esc 关掉', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      expect(h.state.debugDetails, isNull);

      await pressCtrl(tester, LogicalKeyboardKey.enter);
      expect(h.state.debugDetails, 'a');

      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(h.state.debugDetails, isNull);
    });

    testWidgets('点选中卡片右上角的小图标也能打开', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);

      final Offset icon = canvasDetailsIconRect(
        h.screenRect(h.nodes.first.rect),
      ).center;
      await tester.tapAt(icon);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugDetails, 'a');
    });

    testWidgets('没选中就没有小图标可点', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );

      final Offset icon = canvasDetailsIconRect(
        h.screenRect(h.nodes.first.rect),
      ).center;
      await tester.tapAt(icon);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugDetails, isNull);
    });

    testWidgets('面板里改宽度写回节点', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      await pressCtrl(tester, LogicalKeyboardKey.enter);

      // 宽 / 高 两个数字框里，只有「宽」显示 250（默认卡片是 250×120）。
      await tester.enterText(find.widgetWithText(TextField, '250'), '320');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(h.nodes.first.width, 320);
      expect(h.nodes.first.height, 120, reason: '改宽不该顺手动高');
    });

    testWidgets('拖右下角把面板拉大', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      await pressCtrl(tester, LogicalKeyboardKey.enter);

      final Size before = h.state.debugDetailsSize;
      final Rect panel = h.state.debugDetailsRect;
      await tester.dragFrom(
        panel.bottomRight - const Offset(8, 8),
        const Offset(60, 40),
      );
      await tester.pumpAndSettle();

      expect(h.state.debugDetailsSize.width, greaterThan(before.width));
      expect(h.state.debugDetailsSize.height, greaterThan(before.height));
      expect(panel.topLeft, h.state.debugDetailsRect.topLeft, reason: '左上角不动');
    });

    testWidgets('面板开着时点里面的输入框，不会把面板关掉', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      await pressCtrl(tester, LogicalKeyboardKey.enter);

      await tester.tapAt(h.state.debugDetailsRect.center);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugDetails, 'a');
      expect(h.state.debugSelection, <String>{'a'}, reason: '选中也没被清掉');
    });
  });

  group('键盘改尺寸', () {
    testWidgets('Ctrl+= 放大的是字，卡片跟着字变大，中心不动', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        textNode('a', x: 0, y: 0, width: 200, height: 100),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodes.first;
      final Offset before = a.rect.center;
      await tapCard(tester, h, a);

      await pressCtrl(tester, LogicalKeyboardKey.equal);
      expect(a.scale, closeTo(canvasResizeStep, 1e-9), reason: '放大的是字号倍率');
      final double once = a.width;
      expect(once, greaterThan(canvasMinSize));

      await pressCtrl(tester, LogicalKeyboardKey.equal);
      expect(a.scale, closeTo(canvasResizeStep * canvasResizeStep, 1e-9));
      expect(a.width, greaterThan(once), reason: '字又大了，卡片还得跟着长');

      // 放大缩小都锚在中心，卡片不会一边长一边往右下角跑。
      expect(a.rect.center.dx, closeTo(before.dx, 0.001));
      expect(a.rect.center.dy, closeTo(before.dy, 0.001));

      await pressCtrl(tester, LogicalKeyboardKey.minus);
      expect(a.width, closeTo(once, 0.01), reason: '缩回来尺寸也回到刚才那个');
      expect(a.rect.center.dx, closeTo(before.dx, 0.001));
    });

    testWidgets('一直缩：字越缩越小，卡片跟着小，但不会变成 0', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        textNode('a', x: 0, y: 0, width: 60, height: 60),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodes.first);

      double lastScale = doc.nodes.first.scale;
      double lastWidth = doc.nodes.first.width;
      for (int i = 0; i < 20; i++) {
        await pressCtrl(tester, LogicalKeyboardKey.minus);
        final double nowScale = doc.nodes.first.scale;
        final double nowWidth = doc.nodes.first.width;
        expect(nowScale, lessThan(lastScale), reason: '没有下限，按一下就小一点');
        expect(nowWidth, lessThan(lastWidth), reason: '字小了卡片跟着小');
        lastScale = nowScale;
        lastWidth = nowWidth;
      }

      expect(lastScale, greaterThan(0), reason: '0 会让字彻底消失且乘不回来');
      expect(
        lastWidth,
        lessThan(canvasMinSize),
        reason: '贴合没有 40px 的底——那就是「宽度是固定的」',
      );
    });

    testWidgets('编辑时也能调字号：Ctrl+- 不会被键盘闸挡住', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pump();
      final CanvasNode a = h.nodes.single;
      final double before = a.width;

      // 键盘此时在输入框里，但 Ctrl 组合键不会打字，必须照样生效。
      await pressCtrl(tester, LogicalKeyboardKey.minus);

      expect(a.scale, lessThan(1));
      expect(a.width, lessThan(before), reason: '字小了，卡片当场跟着小');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('文件卡片没有字可放大，调整大小改的还是框', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(id: 'f', x: 0, y: 0, width: 200, height: 100, file: 'a/b.md'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode f = doc.nodes.first;
      await tapCard(tester, h, f);

      await pressCtrl(tester, LogicalKeyboardKey.equal);
      expect(f.width, closeTo(200 * canvasResizeStep, 0.001));
      expect(f.height, closeTo(100 * canvasResizeStep, 0.001));
      expect(f.scale, 1, reason: '引用卡片没有「文字即内容」这回事');
    });
  });

  group('就地编辑', () {
    testWidgets('编辑时输入框的可排宽度和画笔一样，不会多折一行', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pump();

      // 打满一行：卡片宽度刚好等于这行字的宽度，一个像素的余量都没有。
      // 这是最容易露馅的位置——`RenderEditable` 会先扣掉 `cursorWidth + 1`
      // 给光标让位（`editable.dart` 的 `_caretMargin`），扣完之后少 2.6px，
      // 最后一个字就被挤到第二行去了。
      await tester.enterText(find.byType(TextField), '十个字十个字十个字十');
      await tester.pumpAndSettle();

      // `find.byType(EditableText)` 拿到的是它外层那个
      // `_RenderCompositionCallback`，不是排版用的 `RenderEditable`，所以
      // 直接从渲染树里捞。
      final RenderEditable editable = tester.allRenderObjects
          .whereType<RenderEditable>()
          .single;
      final double oneLine = AppText.ui * 1.6;
      expect(
        editable.size.height,
        closeTo(oneLine, 1),
        reason: '输入框里也是一行，不能比画笔多折一行',
      );

      final CanvasNode a = h.nodes.single;
      expect(
        a.height,
        closeTo(oneLine + canvasCardPadding * 2, 1),
        reason: '卡片也只该有一行高',
      );
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('新建之后输入框直接拿到焦点，不用再点一下', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      await tester.tapAt(const Offset(500, 350));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(const Offset(500, 350));
      await tester.pumpAndSettle();

      final EditableText editable = tester.widget<EditableText>(
        find.byType(EditableText),
      );
      expect(editable.focusNode.hasFocus, isTrue, reason: '随时可以输入');
      expect(h.state.debugEditing, h.nodes.single.id);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('进编辑就全选，一打字就把旧内容换掉', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await doubleTapCard(tester, h, h.nodes.first);

      final EditableText editable = tester.widget<EditableText>(
        find.byType(EditableText),
      );
      expect(editable.controller.selection.baseOffset, 0);
      expect(editable.controller.selection.extentOffset, '卡片'.length);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('空卡片编辑时画「•••」，不写「输入文字」', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pumpAndSettle();

      // 占位由画笔负责（`_paintEmptyDots`），输入框不该再挂一个 hint——
      // 两边各画一份，字号和位置一定会差一点点。
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.hintText, isNull);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('编辑框没有底色和描边：卡片本身就是那个框', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await doubleTapCard(tester, h, h.nodes.first);

      // 全局 inputDecorationTheme 是 filled + 描边（给表单用的）。它漏进来
      // 的话，画布上会冒出一个带底色和边框的「节点面板」。
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.filled, isFalse);
      expect(field.decoration!.border, InputBorder.none);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('打字之后卡片贴合文字，下面不留一块空白', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      expect(a.height, 120);

      await doubleTapCard(tester, h, a);
      await tester.enterText(find.byType(TextField), '一行字');
      await tester.pumpAndSettle();

      expect(a.height, lessThan(120), reason: '高度贴着文字');
      expect(a.rect.center.dx, closeTo(125, 0.001), reason: '贴尺寸不挪位置');
    });

    testWidgets('宽度双向跟着文字：字多了变宽，删光了缩回三个点的宽度', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pump();
      final CanvasNode a = h.nodes.single;
      final double emptyWidth = a.width;

      await tester.enterText(find.byType(TextField), '一段挺长的文字内容');
      await tester.pumpAndSettle();
      final double wideWidth = a.width;
      expect(wideWidth, greaterThan(emptyWidth), reason: '字多了就变宽');

      await tester.enterText(find.byType(TextField), '短');
      await tester.pumpAndSettle();
      expect(a.width, lessThan(wideWidth), reason: '删掉字就缩回来，不留一块空');

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(a.width, closeTo(emptyWidth, 0.01), reason: '删光了回到三个点的宽度');
      await tester.pump(const Duration(milliseconds: 400));
    });
  });

  group('编辑时快捷键让路', () {
    testWidgets('打 f 不会触发「适应窗口」', (WidgetTester tester) async {
      // 两张离得很远的卡：适应全部和只框住一张，缩放差得远，断言才咬得住。
      final CanvasDocument doc = docWith(<CanvasNode>[
        textNode('a', x: 0, y: 0, text: '卡片'),
        textNode('b', x: 1200, y: 800, text: '另一张'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await doubleTapCard(tester, h, doc.nodeById('a')!);
      expect(h.state.debugEditing, 'a');

      final double zoom = h.zoom;
      final Offset center = h.center;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();

      expect(h.zoom, zoom, reason: 'f 是字，不是快捷键');
      expect(h.center, center);
      expect(h.state.debugEditing, 'a', reason: '还在编辑');
    });

    testWidgets('打空格不会进抓手模式', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await doubleTapCard(tester, h, h.nodes.first);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(h.state.debugSpaceHeld, isFalse);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('Delete 只删字，不删卡片', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await doubleTapCard(tester, h, h.nodes.first);

      await pressKey(tester, LogicalKeyboardKey.delete);

      expect(h.nodes.length, 1);
      expect(h.state.debugEditing, 'a');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('点编辑框里面不会把编辑提交掉', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await doubleTapCard(tester, h, h.nodes.first);

      await tester.tapAt(h.centerOf(h.nodes.first));
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugEditing, 'a', reason: '只是换个光标位置');
    });
  });

  group('Enter 进编辑', () {
    testWidgets('选中一张卡片按 Enter 就地改文字', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      expect(h.state.debugEditing, isNull);

      await pressKey(tester, LogicalKeyboardKey.enter);
      expect(h.state.debugEditing, 'a');
    });

    testWidgets('没选中时 Enter 什么也不做', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await grabKeyboard(tester, h);

      await pressKey(tester, LogicalKeyboardKey.enter);
      expect(h.state.debugEditing, isNull);
    });

    testWidgets('分组标题是单行，Enter 直接收下', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '分组'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await doubleTapCard(tester, h, doc.nodes.first);
      expect(h.state.debugEditing, 'g');

      await tester.enterText(find.byType(TextField), '新名字');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(h.state.debugEditing, isNull);
      expect((doc.nodes.first as GroupNode).label, '新名字');
    });
  });
}
