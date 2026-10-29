import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
  Harness(this.state, this.doc, this.key);

  final CanvasBoardState state;

  /// 板子改的那份文档。测试直接看它，比看界面稳。
  final CanvasDocument? doc;

  /// 重建同一块白板时用的 key：State、画布缓存、视口都靠它留住。
  final GlobalKey<CanvasBoardState> key;

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

/// 白板那棵树。`pumpBoard` 和「换了正文再画一遍」共用，免得两边参数漂。
Widget boardTree(
  GlobalKey<CanvasBoardState> key,
  CanvasDocument? doc, {
  List<({String path, String title})> files =
      const <({String path, String title})>[],
  Map<String, String> noteBodies = const <String, String>{},
  ValueChanged<String>? onOpenFile,
  ValueChanged<String>? onOpenLink,
  VoidCallback? onChanged,
  Future<bool> Function(String path, String body)? onEditFileBody,
  Future<Uint8List?> Function(String path)? imageBytesOf,
  Future<String?> Function(Uint8List png)? onSaveImage,
  Future<List<String>> Function(List<String> paths)? onDropImageFiles,
  Future<Uint8List?> Function()? readClipboardImage,
}) => MaterialApp(
  theme: AppTheme.build(AppPalette.midnight),
  home: Scaffold(
    body: CanvasBoard(
      key: key,
      document: doc,
      files: files,
      noteBodies: noteBodies,
      onOpenFile: onOpenFile,
      onOpenLink: onOpenLink,
      onChanged: onChanged,
      onEditFileBody: onEditFileBody,
      imageBytesOf: imageBytesOf,
      onSaveImage: onSaveImage,
      onDropImageFiles: onDropImageFiles,
      readClipboardImage: readClipboardImage,
    ),
  ),
);

Future<Harness> pumpBoard(
  WidgetTester tester, {
  CanvasDocument? document,
  bool readOnly = false,
  Size size = const Size(1000, 700),
  List<({String path, String title})> files =
      const <({String path, String title})>[],
  Map<String, String> noteBodies = const <String, String>{},
  ValueChanged<String>? onOpenFile,
  ValueChanged<String>? onOpenLink,
  VoidCallback? onChanged,
  Future<bool> Function(String path, String body)? onEditFileBody,
  Future<Uint8List?> Function(String path)? imageBytesOf,
  Future<String?> Function(Uint8List png)? onSaveImage,
  Future<List<String>> Function(List<String> paths)? onDropImageFiles,
  Future<Uint8List?> Function()? readClipboardImage,
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
    boardTree(
      key,
      doc,
      files: files,
      noteBodies: noteBodies,
      onOpenFile: onOpenFile,
      onOpenLink: onOpenLink,
      onChanged: onChanged,
      onEditFileBody: onEditFileBody,
      imageBytesOf: imageBytesOf,
      onSaveImage: onSaveImage,
      onDropImageFiles: onDropImageFiles,
      readClipboardImage: readClipboardImage,
    ),
  );
  await tester.pumpAndSettle();
  return Harness(key.currentState!, doc, key);
}

/// 文件卡片标题条的屏幕中心。收起卡整张都是标题条，展开卡只有顶上那一条。
Offset titleCenter(Harness h, String id) =>
    h.state.debugFileTitleRect(id)!.center;

/// 单击标题条（展开 / 收起）。点完把双击窗口走完，下一次点击不会被认成双击。
Future<void> clickTitle(WidgetTester tester, Harness h, String id) async {
  await tester.tapAt(titleCenter(h, id));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 双击展开卡的正文区（进就地编辑）。
Future<void> doubleTapBody(
  WidgetTester tester,
  Harness h,
  CanvasNode node,
) async {
  final double titleBottom =
      node.y + canvasCardPadding + canvasFileHeaderHeight;
  final Offset at = h.screenOf(
    Offset(
      node.x + node.width / 2,
      titleBottom + (node.y + node.height - titleBottom) / 2,
    ),
  );
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(at);
  await tester.pump();
}

/// 用新的笔记正文把同一块白板再画一遍。
///
/// 笔记改了之后外壳就是这么做的：重建，把新的 `noteBodies` 传下去。State
/// 不换（key 一样），所以排版缓存也还在——正好验「内容变了要重排」。
Future<void> repumpWithBodies(
  WidgetTester tester,
  Harness h,
  Map<String, String> bodies,
) async {
  await tester.pumpWidget(boardTree(h.key, h.doc, noteBodies: bodies));
  await tester.pump();
}

/// 滚一下滚轮（= 缩放）。dy 为负是往上滚。
Future<void> scroll(WidgetTester tester, Offset at, Offset delta) async {
  final TestPointer pointer = TestPointer(9, PointerDeviceKind.mouse);
  pointer.hover(at);
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pump();
}

/// 现画一张 PNG（w×h 纯色）。给「图片卡片」那组用：解码走的是真的
/// `instantiateImageCodec`，喂假字节只会得到「打不开」。
Future<Uint8List> makePng(WidgetTester tester, int w, int h) async {
  final Uint8List? bytes = await tester.runAsync(() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFF3366CC),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(w, h);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// 让解码（真异步）跑完，再把结果画出来。
Future<void> settleImageDecode(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
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

/// 双击**指定屏幕点**两次（自定义落点的双击）。
Future<void> doubleTapAt(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 40));
  await tester.tapAt(at);
  await tester.pump();
}

/// 双击分组**标题条**（改组名）。组内空白双击是建卡，不能混用。
Future<void> doubleTapGroupTitle(
  WidgetTester tester,
  Harness h,
  String id,
) async {
  await doubleTapAt(tester, h.state.debugGroupTitleRect(id)!.center);
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

/// 按住 Ctrl + Shift 敲一下键（`Ctrl+Shift+G` 转框用）。
Future<void> pressCtrlShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
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

  group('尺寸固定', () {
    testWidgets('卡片没有缩放手柄：选中的卡片拖角也是移动，不改宽高', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      final CanvasNode a = h.nodes.first;
      await tapCard(tester, h, a);

      final Rect screen = h.screenRect(a.rect);
      final TestGesture g = await tester.startGesture(
        screen.bottomRight - const Offset(1, 1),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(20, 20));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(a.width, 250, reason: '四角和四边都没有手柄，拖不出新尺寸');
      expect(a.height, 120);
      expect(a.x, greaterThan(0), reason: '这一下应该是拖动卡片');
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

    testWidgets('卡片边上没有连线圆点：按在边上就是拖动卡片', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      final Offset edge = anchorOf(h.screenRect(a.rect), CanvasSide.right);
      await hoverAt(tester, edge);
      // 往卡片里挪 6px 再按：卡片边界上本来就不算「在卡片里」。
      final TestGesture g = await tester.startGesture(
        edge - const Offset(6, 0),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(const Offset(60, 60));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(doc.edges, isEmpty, reason: '圆点已移除，边上拖不出连线');
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

    testWidgets('选中连线按 Enter 就能写标签；清空提交 = 删标签', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = twoCards(fromSide: 'right');
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      await tester.tapAt(edgeMidpoint(h, a, b, fromSide: CanvasSide.right));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'e1'});

      await pressKey(tester, LogicalKeyboardKey.enter);
      expect(h.state.debugEditingEdge, 'e1');

      await tester.enterText(find.byType(TextField).last, '依赖');
      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(doc.edges.single.label, '依赖');

      // 再来一遍：清空提交 = 删掉标签。
      await pressKey(tester, LogicalKeyboardKey.enter);
      await tester.enterText(find.byType(TextField).last, '');
      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(doc.edges.single.label, isNull);
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

    testWidgets('双击分组标题条改标签', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '旧名字'),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(tester, document: doc);

      await doubleTapGroupTitle(tester, h, 'g');
      expect(h.state.debugEditing, 'g');

      await tester.enterText(find.byType(TextField), '新名字');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect((doc.nodes.first as GroupNode).label, '新名字');
    });
  });

  group('Section 框（§14.24）', () {
    /// 框选 a、b 两张卡（0..250 与 400..650）。
    Future<void> selectAB(WidgetTester tester, Harness h) async {
      final TestGesture g = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await g.up();
      await tester.pump();
    }

    /// [box] 是否整个包住 [inner]（含边贴边）。
    bool wraps(Rect box, Rect inner) =>
        box.contains(inner.topLeft) &&
        box.contains(inner.topRight) &&
        box.contains(inner.bottomLeft) &&
        box.contains(inner.bottomRight);

    testWidgets('Ctrl+G 把选中的卡打包成一个组', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await selectAB(tester, h);
      expect(h.state.debugSelection, <String>{'a', 'b'});

      await pressCtrl(tester, LogicalKeyboardKey.keyG);

      expect(doc.nodes, hasLength(3));
      final CanvasNode group = doc.nodes.first;
      expect(group, isA<GroupNode>(), reason: '新组压在最底下');
      expect((group as GroupNode).label, '分组');
      expect(
        wraps(group.rect, doc.nodeById('a')!.rect),
        isTrue,
        reason: '组框装下 a',
      );
      expect(wraps(group.rect, doc.nodeById('b')!.rect), isTrue);
      expect(h.state.debugSelection, <String>{group.id}, reason: '打完包选中组');

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(doc.nodes, hasLength(2), reason: '打包是一步撤销');
    });

    testWidgets('Ctrl+G 没选够两张时不动', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      await pressCtrl(tester, LogicalKeyboardKey.keyG);

      expect(doc.nodes, hasLength(1), reason: '单张走 Ctrl+Shift+G');
    });

    testWidgets('Ctrl+Shift+G 把选中的一张直接转成框', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      await pressCtrlShift(tester, LogicalKeyboardKey.keyG);

      expect(doc.nodes, hasLength(2));
      final CanvasNode group = doc.nodes.first;
      expect(group, isA<GroupNode>());
      expect(wraps(group.rect, doc.nodeById('a')!.rect), isTrue);
      expect(h.state.debugSelection, <String>{group.id});

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(doc.nodes, hasLength(1));
    });

    testWidgets('多选后右键选中卡：菜单里有「打包成框」', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await selectAB(tester, h);

      final TestGesture g = await tester.startGesture(
        h.centerOf(doc.nodeById('a')!),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('打包成框'), findsOneWidget);

      await tester.tap(find.text('打包成框'));
      await tester.pumpAndSettle();

      expect(doc.nodes, hasLength(3));
      expect(doc.nodes.first, isA<GroupNode>());
      expect(h.state.debugSelection, <String>{doc.nodes.first.id});
    });

    testWidgets('双击组内空白：在组里建卡，组名不动', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '框'),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(tester, document: doc);

      // 组内空白（避开标题条和边缘）。
      await doubleTapAt(tester, h.screenOf(const Offset(200, 150)));

      expect(doc.nodes, hasLength(2), reason: '组里建出一张卡');
      final TextNode card = doc.nodes.last as TextNode;
      expect(card.rect.center.dx, closeTo(200, 0.5));
      expect(card.rect.center.dy, closeTo(150, 0.5));
      expect((doc.nodes.first as GroupNode).label, '框', reason: '没进改名');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('Alt+点组：选中的卡跳进去，组强行撑开，一步撤销', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '框'),
          textNode('a', x: 600, y: 0),
          textNode('b', x: 600, y: 200),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tapCard(tester, h, doc.nodeById('b')!);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(h.state.debugSelection, <String>{'a', 'b'});

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tapAt(h.centerOf(doc.nodeById('g')!));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 400));

      final GroupNode g = doc.nodeById('g') as GroupNode;
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;
      expect(g.rect.contains(a.rect.center), isTrue, reason: 'a 跳进组里');
      expect(g.rect.contains(b.rect.center), isTrue);
      expect(b.x - a.x, closeTo(0, 1e-6), reason: '相对排布不动');
      expect(b.y - a.y, closeTo(200, 1e-6), reason: '相对排布不动');

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      // 撤销换一批节点对象：看文档里现取的那张，别拿旧引用。
      final CanvasNode a2 = doc.nodeById('a')!;
      final CanvasNode b2 = doc.nodeById('b')!;
      final GroupNode g2 = doc.nodeById('g') as GroupNode;
      expect(a2.x, 600, reason: '跳跃是一步撤销');
      expect(b2.y, 200);
      expect(g2.x, 0);
      expect(g2.y, 0);
      expect(g2.width, 400);
      expect(g2.height, 300);
    });

    testWidgets('Alt+点普通卡：不跳，照常单选', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 600, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tapAt(h.centerOf(doc.nodeById('b')!));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugSelection, <String>{'b'});
      expect(doc.nodeById('a')!.x, 0, reason: '没发生跳跃');
      expect(doc.nodes, hasLength(2));
    });
  });

  group('打包的组自动包裹（§14.25）', () {
    /// 打包 a、b 两张卡，返回组。
    Future<GroupNode> packAB(WidgetTester tester, Harness h) async {
      final CanvasDocument doc = h.doc!;
      final TestGesture g = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await g.up();
      await tester.pump();
      await pressCtrl(tester, LogicalKeyboardKey.keyG);
      return doc.nodes.first as GroupNode;
    }

    /// 把 [node] 拖动 [worldDelta]（世界单位）。按住 Alt 就是逃逸拖拽。
    Future<void> dragNode(
      WidgetTester tester,
      Harness h,
      CanvasNode node,
      Offset worldDelta, {
      bool alt = false,
    }) async {
      if (alt) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      }
      final TestGesture g = await tester.startGesture(
        h.centerOf(node),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(Offset(worldDelta.dx * h.zoom, worldDelta.dy * h.zoom));
      await tester.pump();
      await g.up();
      await tester.pump();
      if (alt) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    bool wraps(Rect box, Rect inner) =>
        box.contains(inner.topLeft) &&
        box.contains(inner.topRight) &&
        box.contains(inner.bottomLeft) &&
        box.contains(inner.bottomRight);

    testWidgets('拖成员：组跟着走、宽高变化、始终包裹', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final GroupNode group = await packAB(tester, h);
      final double right0 = group.rect.right;

      // a 往右拖 700（越过 b 的右缘 650）：组的右缘跟着 a 走，仍然包住
      // a 和 b（左缘也收进来，框是「紧贴包裹」，始终只要成员包围盒 +
      // 内边距那么大）。
      await dragNode(tester, h, doc.nodeById('a')!, const Offset(700, 0));

      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;
      final GroupNode group2 = doc.nodes.first as GroupNode;
      expect(a.x, closeTo(700, 1e-6));
      expect(group2.rect.contains(a.rect.center), isTrue, reason: '组跟着 a 走');
      expect(wraps(group2.rect, a.rect), isTrue, reason: '始终包裹 a');
      expect(wraps(group2.rect, b.rect), isTrue, reason: '始终包裹 b');
      // 右缘由**最右边那个成员**决定：a 移到 b 的右边之后，右缘跟着 a。
      expect(
        group2.rect.right,
        closeTo(
          math.max(a.rect.right, b.rect.right) + canvasGroupPadding,
          0.01,
        ),
        reason: '右缘贴着最右的成员走',
      );
      expect(group2.rect.right, greaterThan(right0));

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(doc.nodeById('a')!.x, 0, reason: '一步撤销，位置回来');
      final GroupNode g2 = doc.nodes.first as GroupNode;
      expect(g2.rect.right, closeTo(right0, 0.01), reason: '组框也回来');
    });

    testWidgets('Alt+拖拽才能离开：框不追，中心出框就脱离，框缩回去', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final GroupNode group = await packAB(tester, h);

      // Alt + 把 a 拖到很远的右边：框不追，a 出框脱离。
      await dragNode(
        tester,
        h,
        doc.nodeById('a')!,
        const Offset(800, 0),
        alt: true,
      );

      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;
      expect(a.x, closeTo(800, 1e-6));
      expect(group.rect.contains(a.rect.center), isFalse, reason: 'a 离开了组');
      expect(group.rect.contains(b.rect.center), isTrue, reason: '框缩回去包住 b');
      expect(group.rect.contains(a.rect.topLeft), isFalse);

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(doc.nodeById('a')!.x, 0, reason: '一步撤销');
    });

    testWidgets('Alt+只在组内挪：不算脱离，框重新包住它', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await packAB(tester, h);

      // Alt 只是「允许离开」，不是「立刻离开」：在框内挪一点，松手后
      // 中心还在框里 → 仍是成员，框重新包住它。
      await dragNode(
        tester,
        h,
        doc.nodeById('a')!,
        const Offset(30, 0),
        alt: true,
      );

      final CanvasNode a = doc.nodeById('a')!;
      expect(a.x, closeTo(30, 1e-6));
      // 撤销会把节点换成新对象，所以这里按 id 取当前的组。
      final GroupNode g = doc.nodes.first as GroupNode;
      expect(g.rect.contains(a.rect.center), isTrue, reason: '没拖出去就不算脱离');
      expect(wraps(g.rect, a.rect), isTrue, reason: '框重新包住 a');
      expect(wraps(g.rect, doc.nodeById('b')!.rect), isTrue);
    });

    testWidgets('手动「新建分组」的框是固定的，不自动包裹', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '框'),
          textNode('a', x: 600, y: 0),
        ],
        edges: <CanvasEdge>[],
      );
      final Harness h = await pumpBoard(tester, document: doc);

      // 把 a 拖进组中心再拖出来：组框一动不动。
      await dragNode(tester, h, doc.nodeById('a')!, const Offset(-500, 100));
      await dragNode(tester, h, doc.nodeById('a')!, const Offset(500, -100));

      final GroupNode g = doc.nodeById('g') as GroupNode;
      expect(g.x, 0);
      expect(g.y, 0);
      expect(g.width, 400);
      expect(g.height, 300);
      expect(doc.nodeById('a')!.x, closeTo(600, 1e-6));
    });

    testWidgets('拖框外的卡进框里：途中、松手，框都不动（§14.29 / §14.35）', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
        // 组外的一张卡，等下拖进组框正中间。
        textNode('outside', x: 100, y: 600),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final GroupNode group = await packAB(tester, h);
      final Rect before = group.rect;

      final CanvasNode outside = doc.nodeById('outside')!;
      final TestGesture g = await tester.startGesture(
        h.centerOf(outside),
        kind: PointerDeviceKind.mouse,
      );
      // 拖进框正中间，但**先别松手**。
      await g.moveBy(Offset(0, -550 * h.zoom));
      await tester.pump();

      expect(group.rect, before, reason: '拖动途中框不该追框外的节点（§14.29）');

      await g.up();
      await tester.pump();

      expect(
        group.rect.contains(outside.rect.center),
        isTrue,
        reason: '它现在确实躺在框里（几何上）',
      );
      expect(
        group.rect,
        before,
        reason: '松手也不认领：进组走 Alt 跳跃移入（§14.35）',
      );
    });

    testWidgets('删除成员：框缩回去包住剩下的', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final GroupNode group = await packAB(tester, h);
      final double w0 = group.width;

      await tapCard(tester, h, doc.nodeById('b')!);
      await pressKey(tester, LogicalKeyboardKey.delete);

      expect(doc.nodes, hasLength(2), reason: '组 + 剩下的 a');
      final GroupNode g2 = doc.nodes.first as GroupNode;
      expect(g2.rect.contains(doc.nodeById('a')!.rect.center), isTrue);
      expect(g2.width, lessThan(w0), reason: '框缩回去');
    });
  });

  group('组名撑满组框（§14.28）', () {
    /// 一步 1.25 倍地缩放，直到 [done] 成立。
    ///
    /// 两个坑都在这儿堵上：① `zoomOut()` 只是设目标值 + 起 ticker，`h.zoom`
    /// 要 pump 过才变，不 pump 的 while 会永远不前进（把测试进程烧死）；
    /// ② 步数封顶，判定写错时测试是**失败**而不是挂死。
    Future<void> zoomUntil(
      WidgetTester tester,
      Harness h,
      bool Function(double zoom) done, {
      bool inward = false,
    }) async {
      for (int i = 0; i < 40 && !done(h.zoom); i++) {
        if (inward) {
          h.state.zoomIn();
        } else {
          h.state.zoomOut();
        }
        await tester.pumpAndSettle();
      }
    }

    /// 判定是纯函数，直接验：同一个缩放级别下，**框小的组已经显示名字、
    /// 框大的组照常**——判定只看各组自己的框在屏幕上有多宽，跟 zoom 数值
    /// 无关。
    test('框小的组先换，大组照常；每个分组独立', () {
      final GroupNode small = GroupNode(
        id: 'small',
        x: 0,
        y: 0,
        width: 400,
        height: 300,
        label: '小组',
      );
      final GroupNode big = GroupNode(
        id: 'big',
        x: 0,
        y: 0,
        width: 1200,
        height: 900,
        label: '大组',
      );

      expect(groupLabelNeedsFit(small, 1), isFalse, reason: 'zoom 1 框还够宽');
      expect(groupLabelNeedsFit(big, 1), isFalse);

      // 缩到小组触发为止：这时大组的框在屏幕上仍然很宽，照常显示。
      double zoom = 1;
      while (!groupLabelNeedsFit(small, zoom)) {
        zoom /= 1.25;
      }
      expect(groupLabelNeedsFit(small, zoom), isTrue);
      expect(
        groupLabelNeedsFit(big, zoom),
        isFalse,
        reason: '同一个缩放级别：小组显示名字，大组还是正常的框',
      );

      // 大组也要缩到同一条线以下才换——这就是「每个分组独立」。
      while (!groupLabelNeedsFit(big, zoom)) {
        zoom /= 1.25;
      }
      expect(groupLabelNeedsFit(big, zoom), isTrue);
    });

    testWidgets('换撑满画法不影响命中：组内成员照常点到', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(
          id: 'g',
          x: -40,
          y: -40,
          width: 400,
          height: 300,
          label: '创建框',
        ),
        cardAtOrigin(id: 'inside'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final GroupNode group = doc.nodes.first as GroupNode;

      await zoomUntil(
        tester,
        h,
        (double zoom) => groupLabelNeedsFit(group, zoom),
      );
      expect(groupLabelNeedsFit(group, h.zoom), isTrue);

      await tapCard(tester, h, doc.nodeById('inside')!);
      expect(
        h.state.debugSelection,
        <String>{'inside'},
        reason: '只有组名换了画法，框和成员照常参与命中',
      );
    });

    testWidgets('放大回阈值之上，判定自动退回', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '框'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final GroupNode group = doc.nodes.first as GroupNode;

      await zoomUntil(
        tester,
        h,
        (double zoom) => groupLabelNeedsFit(group, zoom),
      );
      expect(groupLabelNeedsFit(group, h.zoom), isTrue, reason: '先缩到触发');
      await zoomUntil(
        tester,
        h,
        (double zoom) => !groupLabelNeedsFit(group, zoom),
        inward: true,
      );
      expect(groupLabelNeedsFit(group, h.zoom), isFalse);
    });
  });

  group('分组也能被拖进分组（§14.34）', () {
    bool wraps(Rect box, Rect inner) =>
        box.contains(inner.topLeft) &&
        box.contains(inner.topRight) &&
        box.contains(inner.bottomLeft) &&
        box.contains(inner.bottomRight);

    /// 大组在左、小组在右，各装一张卡。
    (CanvasDocument, GroupNode, GroupNode) twoGroups() {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(
          id: 'g2',
          x: 0,
          y: 0,
          width: 600,
          height: 400,
          label: '大组',
          autoFit: true,
        ),
        GroupNode(
          id: 'g1',
          x: 900,
          y: 0,
          width: 400,
          height: 300,
          label: '小组',
          autoFit: true,
        ),
        textNode('a', x: 20, y: 60),
        textNode('b', x: 920, y: 60),
      ]);
      return (
        doc,
        doc.nodeById('g2') as GroupNode,
        doc.nodeById('g1') as GroupNode,
      );
    }

    /// 抓**标题条**那一条空白：组是紧贴成员贴出来的，右下角往往正好压在
    /// 卡片上，抓住卡片就变成拖卡片了。
    Future<void> dragGroup(
      WidgetTester tester,
      Harness h,
      GroupNode group,
      Offset to, {
      bool alt = false,
    }) async {
      if (alt) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        // 按完要 pump 一帧，`isAltPressed` 才会在后面的拖动里生效。
        await tester.pump();
      }
      // 抓框的左上角内侧：紧贴成员贴出来的组，标题条也常常被卡片压住，
      // 只有边框这一圈一定是空白。
      final Offset grab = h.screenOf(group.rect.topLeft + const Offset(3, 3));
      final TestGesture g = await tester.startGesture(
        grab,
        kind: PointerDeviceKind.mouse,
      );
      final Offset delta = to - group.rect.center;
      await g.moveBy(Offset(delta.dx * h.zoom, delta.dy * h.zoom));
      await tester.pump();
      await g.up();
      await tester.pump();
      if (alt) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    testWidgets('Alt 点组内空白把小组移进大组；不按 Alt 拖不出来', (
      WidgetTester tester,
    ) async {
      final (CanvasDocument doc, GroupNode g2, GroupNode g1) = twoGroups();
      final Harness h = await pumpBoard(tester, document: doc);
      // 先缩小一档：拖动要跨很大一段世界距离，指针得一直落在窗口里，
      // 出了窗口的 move 事件画布收不到（拖到一半就断了）。
      h.state.zoomOut();
      await tester.pumpAndSettle();
      expect(g2.rect.contains(g1.rect.center), isFalse);

      // 进组的正规方式（§14.24 / §14.35）：选中小组，按住 Alt 点大组内部
      // 空白 → 小组跳进来。拖进去松手是**不认领**的（另有用例）。
      expect(
        g2.rect.contains(g1.rect.center),
        isFalse,
        reason: '一开始小组在大组外面',
      );

      await tester.tapAt(h.screenOf(g1.rect.topLeft + const Offset(20, 10)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'g1'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      await tester.tapAt(h.screenOf(const Offset(300, 250)));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(
        g2.rect.contains(g1.rect.center),
        isTrue,
        reason: 'Alt 点组内空白：小组跳进大组',
      );
      expect(wraps(g2.rect, g1.rect), isTrue, reason: '大组撑到装下小组');

      // 不带 Alt 往外拖：大组跟着长，小组还在里面。
      await dragGroup(tester, h, g1, const Offset(1100, 200));
      expect(
        g2.rect.contains(g1.rect.center),
        isTrue,
        reason: '没有 Alt 就出不去（框追着它长大）',
      );

      // TODO(白板3.1)：这一条还没验完——Alt 把「小组」从大组里拖出来时，
      // 测试里抓不到小组的空白点（组是紧贴成员贴出来的，抓到的往往是卡片），
      // 断言先去掉，别让它假绿。节点级的 Alt 出组已经有用例覆盖（§14.33）。
    });

    testWidgets('Alt 拖整个分组：框里的卡片、嵌套的子分组全都跟着走', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(
          id: 'outer',
          x: -40,
          y: -60,
          width: 900,
          height: 600,
          label: '大组',
          autoFit: true,
        ),
        GroupNode(
          id: 'inner',
          x: 0,
          y: 0,
          width: 600,
          height: 400,
          label: '小组',
          autoFit: true,
        ),
        textNode('b', x: 20, y: 60),
        textNode('c', x: 320, y: 60),
        // 只属于大组、不在小组里。
        textNode('a', x: 700, y: 60),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      h.state.zoomOut();
      await tester.pumpAndSettle();

      final GroupNode inner = doc.nodeById('inner') as GroupNode;
      final CanvasNode b = doc.nodeById('b')!;
      final CanvasNode c = doc.nodeById('c')!;
      final CanvasNode a = doc.nodeById('a')!;
      final double ax = a.x;
      final double bx = b.x;
      final double cx = c.x;

      await dragGroup(
        tester,
        h,
        inner,
        inner.rect.center + const Offset(260, 0),
        alt: true,
      );

      expect(b.x, closeTo(bx + 260, 1), reason: '组里的卡跟着走');
      expect(c.x, closeTo(cx + 260, 1), reason: '组里的卡跟着走');
      expect(a.x, closeTo(ax, 1), reason: '组外的卡不动');
      // 框重新贴合之后仍然包着这两张卡（它跟着一起走，不是原地缩回去）。
      expect(wraps(inner.rect, b.rect), isTrue, reason: '框跟着走：${inner.rect}');
      expect(wraps(inner.rect, c.rect), isTrue);
    });
  });

  group('拖进分组：落点决定归属（§14.33 / §14.35）', () {
    bool wraps(Rect box, Rect inner) =>
        box.contains(inner.topLeft) &&
        box.contains(inner.topRight) &&
        box.contains(inner.bottomLeft) &&
        box.contains(inner.bottomRight);

    /// 把 [node] 的**中心**拖到世界坐标 [to]。按住 [alt] 就是「允许离开」。
    Future<void> dragCenterTo(
      WidgetTester tester,
      Harness h,
      CanvasNode node,
      Offset to, {
      bool alt = false,
    }) async {
      if (alt) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
      }
      final TestGesture g = await tester.startGesture(
        h.centerOf(node),
        kind: PointerDeviceKind.mouse,
      );
      final Offset delta = to - node.rect.center;
      await g.moveBy(Offset(delta.dx * h.zoom, delta.dy * h.zoom));
      await tester.pump();
      await g.up();
      await tester.pump();
      if (alt) {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    /// 大组包着小组；b 属于小组，a 只属于大组。
    (CanvasDocument, GroupNode, GroupNode) nested() {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(
          id: 'outer',
          x: -40,
          y: -60,
          width: 900,
          height: 600,
          label: '大组',
          autoFit: true,
        ),
        GroupNode(
          id: 'inner',
          x: 0,
          y: 0,
          width: 600,
          height: 400,
          label: '小组',
          autoFit: true,
        ),
        textNode('b', x: 20, y: 60),
        textNode('a', x: 700, y: 60),
        // 只属于大组的第二张：大组因此一直够宽，卡从小组 Alt 拖出来之后
        // 还能落在大组里。
        textNode('d', x: 700, y: 300),
      ]);
      return (
        doc,
        doc.nodeById('outer') as GroupNode,
        doc.nodeById('inner') as GroupNode,
      );
    }

    testWidgets('拖到框里的卡不认领：松手不改框，再拖走也不需要 Alt（§14.35）', (
      WidgetTester tester,
    ) async {
      final (CanvasDocument doc, _, GroupNode inner) = nested();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final Rect before = inner.rect;

      // a 从大组拖进小组的地盘，松手：不算成员（框收紧到只剩老成员 b）。
      await dragCenterTo(tester, h, a, const Offset(300, 200));
      expect(
        inner.rect.contains(a.rect.center),
        isFalse,
        reason: '拖进去不算数：框没把它认领进来（§14.35）',
      );
      final Rect afterDrop = inner.rect;

      // 再拖出来：它本来就不是成员，不需要 Alt。
      await dragCenterTo(tester, h, a, const Offset(1200, 400));
      expect(inner.rect.contains(a.rect.center), isFalse);
      expect(inner.rect, afterDrop, reason: '来回拖，框都不动');
      expect(before.width, greaterThan(0));
    });

    testWidgets('进组之后（Alt 跳跃移入）：不按 Alt 拖不出来，按 Alt 才出得来', (
      WidgetTester tester,
    ) async {
      final (CanvasDocument doc, _, GroupNode inner) = nested();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      // 进组的正规方式（§14.24）：选中 a，按住 Alt 点小组内部空白 → 跳进来。
      await tapCard(tester, h, a);
      expect(h.state.debugSelection, <String>{'a'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      await tester.tapAt(h.screenOf(const Offset(300, 200)));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(
        wraps(inner.rect, a.rect),
        isTrue,
        reason: '跳跃移入：a 进了小组，框撑到装下它',
      );

      // 不按 Alt 是拖不出去的（见下一条用例）；这里直接验 Alt 出组：
      // 要真的拖到小组的框外，才谈得上「离开」。
      await dragCenterTo(tester, h, a, const Offset(600, 250), alt: true);
      expect(wraps(inner.rect, a.rect), isFalse, reason: 'Alt 才出得来');
      expect(
        doc.nodeById('outer')!.rect.contains(a.rect.center),
        isTrue,
        reason: '还在大组里',
      );
    });

    testWidgets('不按 Alt：小组里的卡拖不出去，框跟着它长', (WidgetTester tester) async {
      final (CanvasDocument doc, _, GroupNode inner) = nested();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode b = doc.nodeById('b')!;

      await dragCenterTo(tester, h, b, const Offset(800, 300));

      expect(
        inner.rect.contains(b.rect.center),
        isTrue,
        reason: '没有 Alt，它还在小组里（框追着它长大）inner=${inner.rect} b=${b.rect}',
      );
      expect(wraps(inner.rect, b.rect), isTrue);
    });

    testWidgets('按住 Alt：从小拖出去，落回大组里', (WidgetTester tester) async {
      final (CanvasDocument doc, GroupNode outer, GroupNode inner) = nested();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode b = doc.nodeById('b')!;

      await dragCenterTo(tester, h, b, const Offset(800, 300), alt: true);

      expect(
        inner.rect.contains(b.rect.center),
        isFalse,
        reason: 'Alt 才出得来',
      );
      expect(
        outer.rect.contains(b.rect.center),
        isTrue,
        reason: '还在大组里，属于大组',
      );
      expect(wraps(outer.rect, b.rect), isTrue);
    });
  });

  group('分组不是节点（§14.30）', () {
    /// 右键从 [from] 划过 [to]。
    Future<void> slash(WidgetTester tester, Offset from, Offset to) async {
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      for (int i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 6)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('组里右键拖动 = 劈砍：砍掉框里的卡片，不拉线、框还在', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: -40, y: -40, width: 400, height: 300, label: '框'),
        cardAtOrigin(id: 'a'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      // 起手点在组框内、卡片的上面那条空白（标题区），往下划穿卡片。
      await slash(
        tester,
        h.screenOf(const Offset(100, -20)),
        h.screenOf(const Offset(100, 200)),
      );

      expect(doc.nodeById('a'), isNull, reason: '框里的卡片被砍掉');
      expect(doc.nodeById('g'), isNotNull, reason: '框本身不挨刀');
      expect(doc.nodes, hasLength(1), reason: '没走「从组拉线出去新建卡片」那条路');
      expect(doc.edges, isEmpty);
    });

    testWidgets('嵌套分组：点内层选中内层，点外层空白选中外层', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'outer', x: -100, y: -100, width: 800, height: 600),
        GroupNode(id: 'inner', x: -40, y: -40, width: 400, height: 300),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      await tester.tapAt(h.screenOf(const Offset(150, 100)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        h.state.debugSelection,
        <String>{'inner'},
        reason: '点内层就是内层，外框让路',
      );

      await tester.tapAt(h.screenOf(const Offset(600, 400)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'outer'});
    });

    testWidgets('拖内层分组：内层和它的成员一起走，外框一动不动', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'outer', x: -100, y: -100, width: 800, height: 600),
        GroupNode(id: 'inner', x: -40, y: -40, width: 400, height: 300),
        cardAtOrigin(id: 'a'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final GroupNode outer = doc.nodeById('outer') as GroupNode;
      final GroupNode inner = doc.nodeById('inner') as GroupNode;
      final Rect outerBefore = outer.rect;

      final TestGesture g = await tester.startGesture(
        h.screenOf(const Offset(300, 240)),
        kind: PointerDeviceKind.mouse,
      );
      // 屏幕位移要乘 zoom 才是世界位移（板子打开时会自动适应窗口）。
      await g.moveBy(Offset(100 * h.zoom, 100 * h.zoom));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(inner.x, closeTo(60, 1e-6), reason: '内层跟着指针走');
      expect(doc.nodeById('a')!.x, closeTo(100, 1e-6), reason: '组里的卡片一起走');
      expect(outer.rect, outerBefore, reason: '外层的框不属于这次拖动');
    });

    testWidgets('从卡片右键拖到分组框上松手：不建连线、也不掉出新卡', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: 400, y: 0, width: 400, height: 300, label: '框'),
        cardAtOrigin(id: 'a'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      final TestGesture g = await tester.startGesture(
        h.centerOf(doc.nodeById('a')!),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(h.screenOf(const Offset(600, 150)));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.edges, isEmpty, reason: '分组不能成为连线目标');
      expect(doc.nodes, hasLength(2), reason: '也没有在组里掉出一张新卡');
    });

    testWidgets('刀穿过组框边：分组被砍掉，框里的卡片留着', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: -40, y: -40, width: 400, height: 300, label: '框'),
        cardAtOrigin(id: 'a'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      // 从框外横穿整个组：两头都在框外，中途穿过左右两条边。走 y=200 这条
      // 线（卡片在 0..120），别顺路把卡片也砍了。起止点都要落在窗口内，
      // 手势才不会掉在画布外面。
      await slash(tester, h.screenOf(const Offset(-70, 200)), h.screenOf(const Offset(400, 200)));

      expect(doc.nodeById('g'), isNull, reason: '分组可以被刀砍掉');
      expect(doc.nodeById('a'), isNotNull, reason: '砍框不连坐框里的卡片');
    });

    testWidgets('先选中分组、再右键卡片：不会从分组连过去', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: -40, y: -40, width: 400, height: 300, label: '框'),
        cardAtOrigin(id: 'a'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      // 点框里的空白，选中这个分组。
      await tester.tapAt(h.screenOf(const Offset(300, 220)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'g'});

      // 再右键那张卡片：走的是「选中集 → 目标」这条路。
      await tester.tapAt(
        h.centerOf(doc.nodeById('a')!),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.edges, isEmpty, reason: '选中集里的分组不能当源头');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });

    testWidgets('选中分组按 Tab：不生节点、不建边', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: 0, y: 0, width: 400, height: 300, label: '框'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      await tester.tapAt(h.screenOf(const Offset(200, 150)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'g'});

      await pressKey(tester, LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(doc.nodes, hasLength(1), reason: 'Tab 不该从分组生出节点');
      expect(doc.edges, isEmpty, reason: '更不该从分组拉出边');
    });

    testWidgets('老文件里连到分组的边：打开白板就清掉', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          GroupNode(id: 'g', x: 400, y: 0, width: 400, height: 300, label: '框'),
          cardAtOrigin(id: 'a'),
        ],
        // 以前能连上分组时写进文件的边。
        edges: <CanvasEdge>[CanvasEdge(id: 'bad', fromNode: 'a', toNode: 'g')],
      );
      await pumpBoard(tester, document: doc);
      await tester.pumpAndSettle();

      expect(doc.edges, isEmpty, reason: '分组不参与连线，这种边不该存在');
      expect(doc.nodes, hasLength(2), reason: '只清边，节点一个不动');
    });

    testWidgets('右键点分组：弹它自己的菜单，不会把选中的卡连到分组上', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        GroupNode(id: 'g', x: 400, y: 0, width: 400, height: 300, label: '框'),
        cardAtOrigin(id: 'a'),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      await tapCard(tester, h, doc.nodeById('a')!);
      expect(h.state.debugSelection, <String>{'a'});

      await tester.tapAt(
        h.screenOf(const Offset(700, 250)),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.edges, isEmpty, reason: '分组不是节点，连不过去');
      expect(h.state.debugSelection, <String>{'g'}, reason: '右键落在框上就选它');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
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

  group('连线创建（右键）', () {
    CanvasDocument twoCards() => docWith(<CanvasNode>[
      cardAtOrigin(id: 'a'), // 0..250 × 0..120
      textNode('b', x: 400, y: 0), // 400..650 × 0..120
    ]);

    /// 右键从 [from] 拖到 [to]（分几步走，途中有 move 事件）。
    Future<void> rightDrag(WidgetTester tester, Offset from, Offset to) async {
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      for (int i = 1; i <= 6; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 6)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('从卡片拖到另一张：边建出来，端点按鼠标轨迹定', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      // 从 a 拖到 b 的**左边缘**：从 a 的右边出去、进 b 的左边。
      await rightDrag(
        tester,
        h.centerOf(a),
        h.screenOf(Offset(b.rect.left + 12, b.rect.center.dy)),
      );

      expect(doc.edges, hasLength(1));
      final CanvasEdge edge = doc.edges.single;
      expect(edge.fromNode, 'a');
      expect(edge.toNode, 'b');
      expect(edge.fromSide, 'right', reason: '从 a 的右边出去');
      expect(edge.toSide, 'left', reason: '指针压在 b 的左边缘上');
      expect(h.state.debugSelection, <String>{edge.id});
    });

    testWidgets('拖到空白处松手：在松手处新建一张卡并连上，端点走自动', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      // a 的下方（a 占 y 0..120），空白处。
      const Offset blank = Offset(125, 150);
      await rightDrag(tester, h.centerOf(a), h.screenOf(blank));

      expect(doc.nodes, hasLength(2), reason: '拖到空白 = 再加一张卡');
      final CanvasNode card = doc.nodes.last;
      expect(card.rect.center.dx, closeTo(blank.dx, 0.5));
      expect(card.rect.center.dy, closeTo(blank.dy, 0.5));

      expect(doc.edges, hasLength(1));
      final CanvasEdge edge = doc.edges.single;
      expect(edge.fromNode, 'a');
      expect(edge.toNode, card.id);
      expect(edge.fromSide, isNull, reason: '中心发出');
      expect(edge.toSide, isNull, reason: '中心接收');
    });

    testWidgets('选中一张后右键另一张：直接建中心到中心的线，不弹菜单', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      await tapCard(tester, h, a);
      expect(h.state.debugSelection, <String>{'a'});

      final TestGesture g = await tester.startGesture(
        h.centerOf(b),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();

      expect(doc.edges, hasLength(1));
      final CanvasEdge edge = doc.edges.single;
      expect(edge.fromNode, 'a', reason: '从选中的那张出发');
      expect(edge.toNode, 'b');
      expect(edge.fromSide, isNull);
      expect(edge.toSide, isNull);
      expect(find.text('红色'), findsNothing, reason: '这一下是建连线，不是弹菜单');
      expect(h.state.debugSelection, <String>{edge.id});
    });

    testWidgets('选中一张后右键它自己：还是弹菜单', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      await tapCard(tester, h, a);
      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();

      expect(doc.edges, isEmpty);
      expect(find.text('红色'), findsOneWidget, reason: '点的是选中自己 = 菜单');
    });

    testWidgets('拖回自己身上松手：不建边也不新建卡', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(h.centerOf(a) + const Offset(80, 80));
      await tester.pump();
      await g.moveTo(h.centerOf(a));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.edges, isEmpty);
      expect(doc.nodes, hasLength(1), reason: '松手在自己身上是反悔，不是空白落卡');
    });

    testWidgets('同向的边已经有了：不叠第二条，改成选中那条', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
        ],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      await rightDrag(tester, h.centerOf(a), h.centerOf(b));

      expect(doc.edges, hasLength(1), reason: '两条完全重合的线谁也点不中');
      expect(h.state.debugSelection, <String>{'e1'});
    });

    testWidgets('拉到一半按 Esc：这条线作废', (WidgetTester tester) async {
      final CanvasDocument doc = twoCards();
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(h.centerOf(b));
      await tester.pump();
      expect(h.state.debugConnecting, isTrue);
      expect(h.state.debugConnectTarget, 'b');

      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(h.state.debugConnecting, isFalse);

      await g.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.edges, isEmpty);
      expect(doc.nodes, hasLength(2));
    });

    testWidgets('多连一：选中几张，从其中一张拖到目标，每张都连过去', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
        textNode('c', x: 800, y: 0),
        textNode('d', x: 400, y: 400),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode b = doc.nodeById('b')!;
      final CanvasNode d = doc.nodeById('d')!;

      // 框选 a、b（多连一的「多个」）。
      final TestGesture marquee = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await marquee.up();
      await tester.pump();
      expect(h.state.debugSelection, <String>{'a', 'b'});

      // 从其中任意一张（b）开始右键拖到 d。
      final TestGesture g = await tester.startGesture(
        h.centerOf(b),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(h.centerOf(d));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.edges, hasLength(2), reason: 'a 和 b 各连一条到 d');
      expect(
        <String>{
          for (final CanvasEdge edge in doc.edges) '${edge.fromNode}->${edge.toNode}',
        },
        <String>{'a->d', 'b->d'},
      );
      expect(h.state.debugSelection, <String>{
        for (final CanvasEdge edge in doc.edges) edge.id,
      }, reason: '建出来的那束边全部进选中');
    });

    testWidgets('多连一整批只记一步撤销', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
        textNode('d', x: 400, y: 400),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode b = doc.nodeById('b')!;
      final CanvasNode d = doc.nodeById('d')!;

      final TestGesture marquee = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await marquee.up();
      await tester.pump();

      final TestGesture g = await tester.startGesture(
        h.centerOf(b),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(h.centerOf(d));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(doc.edges, hasLength(2));

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(doc.edges, isEmpty, reason: '一批一条撤销，不会退到只剩一条');
    });

    testWidgets('多连一里已经连过的那张不会叠第二条', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
          textNode('d', x: 400, y: 400),
        ],
        edges: <CanvasEdge>[CanvasEdge(id: 'e0', fromNode: 'a', toNode: 'd')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode b = doc.nodeById('b')!;
      final CanvasNode d = doc.nodeById('d')!;

      final TestGesture marquee = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await marquee.up();
      await tester.pump();

      final TestGesture g = await tester.startGesture(
        h.centerOf(b),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(h.centerOf(d));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.edges, hasLength(2), reason: 'a→d 已存在，只新建 b→d');
      expect(
        doc.edges.map((CanvasEdge edge) => edge.id),
        containsAll(<String>['e0']),
      );
      expect(h.state.debugSelection, <String>{'e0', doc.edges.last.id});
    });

    testWidgets('多连一拖到空白：松手处新建一张卡，所有选中的都连到它', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode b = doc.nodeById('b')!;

      final TestGesture marquee = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await marquee.up();
      await tester.pump();

      final TestGesture g = await tester.startGesture(
        h.centerOf(b),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(h.screenOf(const Offset(125, 400)));
      await tester.pump();
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.nodes, hasLength(3), reason: '空白处只新建**一张**卡');
      final CanvasNode card = doc.nodes.last;
      expect(doc.edges, hasLength(2));
      expect(
        <String>{
          for (final CanvasEdge edge in doc.edges) '${edge.fromNode}->${edge.toNode}',
        },
        <String>{'a->${card.id}', 'b->${card.id}'},
      );
      expect(
        <String?>[
          for (final CanvasEdge edge in doc.edges) ...<String?>[edge.fromSide, edge.toSide],
        ],
        everyElement(isNull),
        reason: '中心发出 / 中心接收',
      );
    });

    testWidgets('多选后直接右键目标：不用拖，每一张都连过去', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
        textNode('d', x: 400, y: 400),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode d = doc.nodeById('d')!;

      final TestGesture marquee = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await marquee.up();
      await tester.pump();
      expect(h.state.debugSelection, <String>{'a', 'b'});

      // 只按一下右键（不拖），点在 d 上。
      final TestGesture g = await tester.startGesture(
        h.centerOf(d),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();

      expect(
        <String>{
          for (final CanvasEdge edge in doc.edges) '${edge.fromNode}->${edge.toNode}',
        },
        <String>{'a->d', 'b->d'},
      );
      expect(find.text('红色'), findsNothing, reason: '这一下是建连线，不是弹菜单');
      expect(h.state.debugSelection, <String>{
        for (final CanvasEdge edge in doc.edges) edge.id,
      });
    });

    testWidgets('多选后右键**选中的那张**：还是菜单，不是连线', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      final TestGesture marquee = await tester.startGesture(
        h.screenOf(const Offset(-30, -30)),
        kind: PointerDeviceKind.mouse,
      );
      await marquee.moveTo(h.screenOf(const Offset(700, 130)));
      await tester.pump();
      await marquee.up();
      await tester.pump();
      expect(h.state.debugSelection, <String>{'a', 'b'});

      final TestGesture g = await tester.startGesture(
        h.centerOf(a),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pumpAndSettle();

      expect(doc.edges, isEmpty, reason: '点在选中集里 = 弹菜单，不该连给自己人');
      expect(find.text('红色'), findsOneWidget);
      expect(b.x, 400);
    });

    testWidgets('Ctrl+T 反转选中边：方向、端点、箭头整体对调，再按一次复原', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
        ],
        edges: <CanvasEdge>[
          CanvasEdge(
            id: 'e1',
            fromNode: 'a',
            toNode: 'b',
            fromSide: 'right',
            toSide: 'left',
            toEnd: 'arrow',
          ),
        ],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      // 连线组里那个 edgeMidpoint 是组内局部函数，这里自己算一次中点。
      final CanvasEdgeGeometry mid = edgeGeometry(
        fromRect: a.rect,
        toRect: b.rect,
        fromSide: CanvasSide.right,
      );
      await tester.tapAt(h.screenOf(mid.pointAt(0.5)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'e1'});

      await pressCtrl(tester, LogicalKeyboardKey.keyT);
      CanvasEdge edge = doc.edges.single;
      expect(edge.fromNode, 'b');
      expect(edge.toNode, 'a');
      expect(edge.fromSide, 'left', reason: '端点跟着方向一起换');
      expect(edge.toSide, 'right');
      expect(edge.toEnd, 'arrow', reason: '箭头跟着「终点」槽位走，反转后画在 a 的头上');
      expect(edge.fromEnd, isNull);

      await pressCtrl(tester, LogicalKeyboardKey.keyT);
      edge = doc.edges.single;
      expect(edge.fromNode, 'a', reason: '再按一次就回来');
      expect(edge.toNode, 'b');
    });
  });

  group('劈砍（右键从空白划刀）', () {
    /// 右键从 [from] 划过 [to]（分几步走，刀锋是一条折线）。
    Future<void> slash(
      WidgetTester tester,
      Offset from,
      Offset to, {
      int steps = 6,
    }) async {
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      for (int i = 1; i <= steps; i++) {
        await g.moveTo(Offset.lerp(from, to, i / steps)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('一刀划过连线：砍断那条线，两头的卡片留着', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
        ],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;
      final Offset mid = h.screenOf(
        edgeGeometry(fromRect: a.rect, toRect: b.rect).pointAt(0.5),
      );

      // 竖着切一刀，正好压在这条线的中点上。
      await slash(tester, mid + const Offset(0, -80), mid + const Offset(0, 80));

      expect(doc.edges, isEmpty, reason: '线被砍断');
      expect(doc.nodes, hasLength(2), reason: '节点没被碰到');
    });

    testWidgets('一刀划过卡片：砍断节点，连带它身上的边', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          cardAtOrigin(id: 'a'),
          textNode('b', x: 400, y: 0),
        ],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      // 只横穿 a 自己（右边界停在 a 里侧），别顺路把 b 也砍了。
      await slash(
        tester,
        h.screenOf(Offset(a.rect.left - 40, a.rect.center.dy)),
        h.screenOf(Offset(a.rect.right - 20, a.rect.center.dy)),
      );

      expect(doc.nodes.map((CanvasNode n) => n.id), <String>['b']);
      expect(doc.edges, isEmpty, reason: '一边被砍掉，那条线也留不住');
    });

    testWidgets('一刀只碰到边角不进屋：卡片还在', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      // 从卡片上方划过去，离顶边还有一段距离。
      await slash(
        tester,
        h.screenOf(Offset(-40, a.rect.top - 60)),
        h.screenOf(Offset(400, a.rect.top - 60)),
      );

      expect(doc.nodes, hasLength(1));
    });

    testWidgets('划一刀只记一步撤销', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
        textNode('c', x: 800, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      await slash(
        tester,
        h.screenOf(Offset(a.rect.left - 40, a.rect.center.dy)),
        h.screenOf(Offset(900, a.rect.center.dy)),
      );
      expect(doc.nodes.length, lessThan(3));

      await pressCtrl(tester, LogicalKeyboardKey.keyZ);
      expect(doc.nodes, hasLength(3), reason: '一刀一条撤销，全部回来');
    });

    testWidgets('从卡片起手是拉线，不是劈砍', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;

      await slash(
        tester,
        h.centerOf(a),
        h.centerOf(b),
        steps: 6,
      );

      expect(doc.nodes, hasLength(2), reason: '右键从卡片起手是建连线');
      expect(doc.edges, hasLength(1));
    });

    testWidgets('划到一半按 Esc：什么都不砍', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;

      // 从卡片**上方**的空白起手（必须落在窗口内，§16.3 第 16 条），
      // 往下划进卡片——起手在空白才是劈砍，在卡上是拉线。
      final TestGesture g = await tester.startGesture(
        h.screenOf(Offset(a.rect.center.dx, a.rect.top - 30)),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await g.moveTo(
        h.screenOf(Offset(a.rect.center.dx, a.rect.center.dy)),
      );
      await tester.pump();
      expect(h.state.debugSlashing, isTrue);
      expect(h.state.debugSlashNodes, contains('a'));

      await pressKey(tester, LogicalKeyboardKey.escape);
      expect(h.state.debugSlashing, isFalse);
      await g.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(doc.nodes, hasLength(1), reason: 'Esc 之后这一刀作废');
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

    testWidgets('向左框选 = 完全覆盖：碰到但不全在框里的不选', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'), // 0..250，框外
        textNode('d', x: 300, y: 0), // 300..550，框骑在它身上
        textNode('b', x: 600, y: 0), // 600..850，整个在框里
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      // 从右往左拖：框 = (320..900, -40..240)。d 碰到框但左半截在外面，
      // b 整个在框里。
      final Offset from = h.screenOf(const Offset(900, -40));
      final Offset to = h.screenOf(const Offset(320, 240));
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(h.state.debugSelection, <String>{'b'});
    });

    testWidgets('向右框选 = 碰撞：同一批卡片，骑在框上的也选中', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('d', x: 300, y: 0),
        textNode('b', x: 600, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      // 同一个框反着拖：向右 = 碰到就算。
      final Offset from = h.screenOf(const Offset(320, -40));
      final Offset to = h.screenOf(const Offset(900, 240));
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(h.state.debugSelection, <String>{'d', 'b'});
    });

    testWidgets('Shift 框选 = 加选：旧的保留', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 600, y: 0),
        textNode('c', x: 2000, y: 2000),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final Offset from = h.screenOf(const Offset(-20, -40));
      final Offset to = h.screenOf(const Offset(900, 240));
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(h.state.debugSelection, <String>{'a', 'b'});
    });

    testWidgets('Ctrl 框选 = 反选：框里的已选取消、未选选中', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 600, y: 0),
        textNode('c', x: 2000, y: 2000),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      final Offset from = h.screenOf(const Offset(-20, -40));
      final Offset to = h.screenOf(const Offset(900, 240));
      final TestGesture g = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await g.moveTo(to);
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // a 被框住 → 取消；b 在框里但没选 → 选中；c 在框外 → 不动。
      expect(h.state.debugSelection, <String>{'b'});
    });

    testWidgets('Shift 点击 = 从上次点的那张撑框，范围里的全选', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'), // 0..250
        textNode('b', x: 400, y: 0), // 400..650
        textNode('m', x: 800, y: 0), // 800..1050
        textNode('c', x: 2000, y: 2000),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      // 先点左上角的 a，再 Shift 点右下角的 m。
      await tapCard(tester, h, doc.nodeById('a')!);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(h.centerOf(doc.nodeById('m')!));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugSelection, <String>{'a', 'b', 'm'});

      // 锚点不动：Shift 再点中间那张，框收回 a→b，m 出局。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(h.centerOf(doc.nodeById('b')!));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugSelection, <String>{'a', 'b'});
    });

    testWidgets('Shift 点击没有锚点时退化成单选', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(h.centerOf(doc.nodeById('b')!));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.state.debugSelection, <String>{'b'});
    });

    testWidgets('不按键点已选中的卡片不清别人：多选还能整组拖', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        cardAtOrigin(id: 'a'),
        textNode('b', x: 400, y: 0),
        textNode('c', x: 2000, y: 2000),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      await tapCard(tester, h, doc.nodeById('a')!);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(h.centerOf(doc.nodeById('b')!));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'a', 'b'});

      // 点已选中的 a：选中保持，锚点却换成 a（范围选择从这重新出发）。
      await tapCard(tester, h, doc.nodeById('a')!);
      expect(h.state.debugSelection, <String>{'a', 'b'});

      // 点没选中的 c：回到单选。
      await tapCard(tester, h, doc.nodeById('c')!);
      expect(h.state.debugSelection, <String>{'c'});
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

    test('坐标数字是整数，浮点噪声不外泄', () {
      expect(canvasCoordinateLabel(0), '0');
      expect(canvasCoordinateLabel(-300), '-300');
      expect(canvasCoordinateLabel(99.99999999999999), '100');
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

    testWidgets('文件卡片没有可调的框：Ctrl+= 不会改宽高', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        // 展开着：点卡片正文只选中，不会把这张卡收起来。
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 200,
          height: 100,
          file: 'a/b.md',
          expanded: true,
        ),
      ]);
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        noteBodies: const <String, String>{'a/b.md': '一行正文'},
      );
      final CanvasNode f = doc.nodes.first;
      await tapCard(tester, h, f);
      final double width = f.width;
      final double height = f.height;

      await pressCtrl(tester, LogicalKeyboardKey.equal);

      expect(f.width, width, reason: '宽高只由笔记内容决定');
      expect(f.height, height);
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
      // 双击标题条才是改组名；组内空白双击是建卡（§14.24）。
      await doubleTapGroupTitle(tester, h, 'g');
      expect(h.state.debugEditing, 'g');

      await tester.enterText(find.byType(TextField), '新名字');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(h.state.debugEditing, isNull);
      expect((doc.nodes.first as GroupNode).label, '新名字');
    });
  });

  group('Tab 右生节点', () {
    testWidgets('选中一张卡按 Tab：右边生成新卡并连上一条边', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      final CanvasNode a = h.nodes.first;

      await pressKey(tester, LogicalKeyboardKey.tab);

      expect(h.nodes.length, 2, reason: '多出一张新卡');
      expect(h.doc!.edges.length, 1, reason: '多出一条边');
      final CanvasNode b = h.nodes.last;
      expect(h.doc!.edges.single.fromNode, a.id, reason: '边从选中卡出发');
      expect(h.doc!.edges.single.toNode, b.id, reason: '边指向新卡');
      expect(b.rect.left, greaterThanOrEqualTo(a.rect.right), reason: '新卡在右边');
      expect(b.rect.center.dy, closeTo(a.rect.center.dy, 0.5), reason: '垂直居中对齐');
    });

    testWidgets('Tab 之后新卡被选中并直接进编辑态', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);

      await pressKey(tester, LogicalKeyboardKey.tab);

      final String newId = h.state.debugSelection.single;
      expect(newId, isNot('a'), reason: '选中的是新卡，不再是原来那张');
      expect(h.state.debugEditing, newId, reason: '接着打字就是在写新卡');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('Tab 一步撤销：卡和边一起消失，选中回到原卡', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);

      await pressKey(tester, LogicalKeyboardKey.tab);
      expect(h.nodes.length, 2);
      // 退出编辑态再撤销，避免编辑提交搅进来。
      await pressKey(tester, LogicalKeyboardKey.escape);
      h.state.undo();

      expect(h.nodes.length, 1);
      expect(h.doc!.edges, isEmpty);
    });

    testWidgets('没选中时 Tab 什么也不做', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await grabKeyboard(tester, h);

      await pressKey(tester, LogicalKeyboardKey.tab);

      expect(h.nodes.length, 1);
      expect(h.doc!.edges, isEmpty);
      expect(h.state.debugEditing, isNull);
    });

    testWidgets('同一张卡连按 Tab：孩子们从上往下排，不叠在一起', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);

      // 连生三个孩子：每次 Tab 后退出编辑态、重新选中源头那张。
      for (int i = 0; i < 3; i++) {
        await pressKey(tester, LogicalKeyboardKey.tab);
        await pressKey(tester, LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 400));
        await tapCard(tester, h, h.nodes.first);
      }
      await pressKey(tester, LogicalKeyboardKey.escape);

      expect(h.nodes.length, 4, reason: '源头 + 三个孩子');
      expect(h.doc!.edges.length, 3);
      final CanvasNode a = h.nodes[0];
      final CanvasNode c1 = h.nodes[1];
      final CanvasNode c2 = h.nodes[2];
      final CanvasNode c3 = h.nodes[3];
      expect(c1.rect.center.dy, closeTo(a.rect.center.dy, 0.5), reason: '第一个孩子垂直居中');
      expect(c2.rect.top, greaterThanOrEqualTo(c1.rect.bottom), reason: '第二个排在第一个下面');
      expect(c3.rect.top, greaterThanOrEqualTo(c2.rect.bottom), reason: '第三个排在第二个下面');
      expect(c2.rect.left, closeTo(c1.rect.left, 0.5), reason: '同一列');
      expect(c3.rect.left, closeTo(c1.rect.left, 0.5), reason: '同一列');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('被挪走的孩子不算数：它已经不在右侧了，新孩子从原位重新排', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[cardAtOrigin(), textNode('b', x: 400, y: 0)],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;
      // b 被挪到左边去了：它不再算「右侧的孩子」，不该把新孩子顶到很远的下面。
      b.x = -600;
      await tester.pump();
      await tapCard(tester, h, a);

      await pressKey(tester, LogicalKeyboardKey.tab);
      await pressKey(tester, LogicalKeyboardKey.escape);

      expect(h.nodes.length, 3);
      final CanvasNode c = h.nodes.last;
      expect(c.rect.center.dy, closeTo(a.rect.center.dy, 0.5), reason: '右侧没有孩子，新孩子垂直居中');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('选中的是边时 Tab 什么也不做', (WidgetTester tester) async {
      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[cardAtOrigin(), textNode('b', x: 400, y: 0)],
        edges: <CanvasEdge>[CanvasEdge(id: 'e1', fromNode: 'a', toNode: 'b')],
      );
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode a = doc.nodeById('a')!;
      final CanvasNode b = doc.nodeById('b')!;
      final CanvasEdgeGeometry g = edgeGeometry(fromRect: a.rect, toRect: b.rect);
      await tester.tapAt(h.screenOf(g.pointAt(0.5)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.state.debugSelection, <String>{'e1'});
      final int nodeCount = h.nodes.length;

      await pressKey(tester, LogicalKeyboardKey.tab);

      expect(h.nodes.length, nodeCount, reason: '边的 Tab 不是生孩子的键');
      expect(h.state.debugEditing, isNull);
    });

    testWidgets('编辑状态下按 Tab：先收下正在打的字，再往右生一个节点', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        document: docWith(<CanvasNode>[cardAtOrigin()]),
      );
      await tapCard(tester, h, h.nodes.first);
      await pressKey(tester, LogicalKeyboardKey.enter);
      await tester.enterText(find.byType(TextField), '父节点');
      await tester.pumpAndSettle();
      expect(h.state.debugEditing, 'a');

      await pressKey(tester, LogicalKeyboardKey.tab);

      expect(h.nodes.length, 2, reason: '编辑态也生孩子');
      expect((h.nodes.first as TextNode).text, '父节点', reason: '打的字收下了');
      final CanvasNode b = h.nodes.last;
      expect(h.doc!.edges.single.fromNode, 'a', reason: '边从正在编辑的那张出发');
      expect(h.doc!.edges.single.toNode, b.id);
      expect(h.state.debugEditing, b.id, reason: '新卡直接进编辑态，接着打');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('编辑笔记正文时 Tab 不生节点，也不把编辑打断', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 240,
          height: 200,
          file: '甲.md',
          expanded: true,
        ),
      ]);
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        noteBodies: const <String, String>{'甲.md': '旧正文'},
      );
      await doubleTapBody(tester, h, doc.nodes.single as FileNode);
      expect(h.state.debugEditingFileBody, isTrue);

      await pressKey(tester, LogicalKeyboardKey.tab);

      expect(h.nodes.length, 1, reason: '正文里 Tab 不该长出卡片');
      expect(h.doc!.edges, isEmpty);
      expect(h.state.debugEditing, 'f', reason: '还在编辑正文');
      expect(h.state.debugEditingFileBody, isTrue);
    });
  });

  group('markdown 卡片与引用', () {
    testWidgets('编辑时按源码贴合，退出编辑按渲染后的样子重贴', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.createCard();
      await tester.pump();

      final TextNode card = h.nodes.single as TextNode;
      await tester.enterText(find.byType(TextField), '# 标题');
      await tester.pumpAndSettle();
      final double whileEditing = card.width;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // 源码里那两个井号渲染后不见了，标题又只有两个字：卡片比编辑时窄。
      expect(card.width, lessThan(whileEditing), reason: '标记不占地方，渲染后要缩回来');
      expect(card.text, '# 标题', reason: '存的是源码，不是渲染结果');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('标题渲染后比同字数的正文更大：卡片跟着变高', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);

      h.state.createCard();
      await tester.pump();
      await tester.enterText(find.byType(TextField), '标题');
      await tester.pumpAndSettle();
      final CanvasNode plain = h.nodes.single;
      final double plainHeight = plain.height;
      final double plainWidth = plain.width;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      h.state.createCard();
      await tester.pump();
      await tester.enterText(find.byType(TextField), '# 标题');
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      final CanvasNode heading = h.nodes.last;
      expect(heading.height, greaterThan(plainHeight), reason: '标题字号大，行高也高');
      expect(heading.width, greaterThan(plainWidth), reason: '字大了，卡片就宽了');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('打开白板时，装不下渲染结果的卡片会重贴；装得下的原样不动', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        // 太小：装不下一行标题。
        textNode('small', x: 0, y: 0, width: 40, height: 30, text: '# 一个标题'),
        // 很大：内容装得下，用户拖宽过的尺寸要留着。
        textNode('big', x: 400, y: 0, width: 900, height: 400, text: '短句'),
      ]);
      await pumpBoard(tester, document: doc);

      final CanvasNode small = doc.nodes[0];
      final CanvasNode big = doc.nodes[1];
      expect(small.width, greaterThan(40), reason: '标题装不下，宽度要长出来');
      expect(small.height, greaterThan(30), reason: '标题装不下，高度要长出来');
      expect(big.width, 900, reason: '框比内容大就原样留着');
      expect(big.height, 400, reason: '框比内容大就原样留着');
    });

    testWidgets('拖进来的 .md 落成引用卡片：指向那篇笔记，不复制正文', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      h.state.addFileCards(<String>['笔记/甲.md', '乙.md']);
      await tester.pump();

      expect(h.nodes.length, 2, reason: '一份文件一张卡片');
      expect(h.nodes[0], isA<FileNode>());
      expect((h.nodes[0] as FileNode).file, '笔记/甲.md');
      expect((h.nodes[1] as FileNode).file, '乙.md');
      expect(
        h.nodes.whereType<TextNode>(),
        isEmpty,
        reason: '引用不是拷贝：不该多出一张装着正文的文字卡片',
      );
      expect(
        h.nodes[0].rect.overlaps(h.nodes[1].rect),
        isFalse,
        reason: '几张卡片不能叠成一摞',
      );
      expect(h.state.debugSelection.length, 2, reason: '拖进来的卡片要选中');
      expect(
        h.nodes.every((CanvasNode n) => !(n as FileNode).expanded),
        isTrue,
        reason: '新落的卡片是收起的：一行文件名，不铺开正文',
      );
    });

    testWidgets('收起的卡片就是一行文件名：不画正文，也不占默认那么大', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        noteBodies: <String, String>{'甲.md': '# 标题\n${'正文一行\n' * 20}'},
      );
      final FileNode card = h.state.addFileCards(<String>['甲.md']).single;
      await tester.pump();

      expect(h.state.debugFileBody(card.id), isNull);
      expect(
        card.height,
        closeTo(canvasFileTitleHeight + canvasCardPadding * 2, 0.01),
        reason: '高 = 一行标题 + 内边距',
      );
      expect(
        card.width,
        lessThan(canvasDefaultWidth),
        reason: '只有一行文件名，不用铺满默认宽度',
      );
    });

    testWidgets('点标题展开：正文画出来，卡片从左上角长下去', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        noteBodies: <String, String>{'甲.md': '# 会议记录\n第一行\n第二行'},
      );
      final FileNode card = h.state.addFileCards(<String>['甲.md']).single;
      await tester.pump();
      final Offset corner = Offset(card.x, card.y);
      final double collapsedHeight = card.height;

      await clickTitle(tester, h, card.id);

      expect(h.state.debugFileExpanded(card.id), isTrue);
      final String? painted = h.state.debugFileBody(card.id);
      expect(painted, contains('会议记录'));
      expect(painted, contains('第二行'));
      expect(painted, isNot(contains('#')), reason: '画出来的是渲染后的正文');
      expect(card.height, greaterThan(collapsedHeight));
      expect(Offset(card.x, card.y), corner, reason: '左上角钉住，标题不跑');

      await clickTitle(tester, h, card.id);

      expect(h.state.debugFileExpanded(card.id), isFalse);
      expect(h.state.debugFileBody(card.id), isNull);
      expect(card.height, closeTo(collapsedHeight, 0.01));
      expect(Offset(card.x, card.y), corner, reason: '收起来也从左上角缩回去');
    });

    testWidgets('展开后按笔记正文贴尺寸：正文多长卡片就多高，没有上限', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        noteBodies: <String, String>{'甲.md': '# 标题\n${'正文一行\n' * 200}'},
      );
      final FileNode card = h.state.addFileCards(<String>['甲.md']).single;
      await tester.pump();

      await clickTitle(tester, h, card.id);

      expect(card.height, greaterThan(100), reason: '默认那个 100 高的框装不下正文');
      expect(
        card.height,
        greaterThan(200 * AppText.ui),
        reason: '两百行全部排出来——高度没有上限，内容全部显示',
      );
      expect(card.width, lessThanOrEqualTo(canvasTextMaxWidth));
      expect(h.state.debugFileBody(card.id), contains('正文一行'));
    });

    testWidgets('拖着标题移动不会切换展开状态', (WidgetTester tester) async {
      final Harness h = await pumpBoard(
        tester,
        noteBodies: <String, String>{'甲.md': '正文'},
      );
      final FileNode card = h.state.addFileCards(<String>['甲.md']).single;
      await tester.pump();
      final Offset before = Offset(card.x, card.y);

      final TestGesture g = await tester.startGesture(
        titleCenter(h, card.id),
        kind: PointerDeviceKind.mouse,
      );
      // 16 世界单位：过了 3px 死区，算移动，不算点击。
      await g.moveBy(Offset(16 * h.zoom, 0));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(card.x, closeTo(before.dx + 16, 0.01));
      expect(card.expanded, isFalse, reason: '拖走卡片不能顺手把它收起来');
    });

    testWidgets('Ctrl + 单击标题不切换', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final FileNode card = h.state.addFileCards(<String>['甲.md']).single;
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(titleCenter(h, card.id));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));

      expect(card.expanded, isFalse);
    });

    testWidgets('双击标题条打开那篇笔记', (WidgetTester tester) async {
      final List<String> opened = <String>[];
      final Harness h = await pumpBoard(
        tester,
        noteBodies: <String, String>{'甲.md': '正文'},
        onOpenFile: opened.add,
      );
      final FileNode card = h.state.addFileCards(<String>['甲.md']).single;
      await tester.pump();

      final Offset at = titleCenter(h, card.id);
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(at);
      await tester.pump();

      expect(opened, <String>['甲.md']);
      expect(h.state.debugEditing, isNull);
      expect(card.expanded, isTrue, reason: '单击在松手时先展开；打开笔记会切走视图，回来时卡片是展开的');
    });

    testWidgets('双击正文进编辑，提交把源码交给 onEditFileBody', (WidgetTester tester) async {
      final List<({String path, String body})> writes =
          <({String path, String body})>[];
      int boardChanges = 0;
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 240,
          height: 200,
          file: '甲.md',
          expanded: true,
        ),
      ]);
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        noteBodies: const <String, String>{'甲.md': '旧正文'},
        onChanged: () => boardChanges++,
        onEditFileBody: (String path, String body) async {
          writes.add((path: path, body: body));
          return true;
        },
      );
      final FileNode card = doc.nodes.single as FileNode;

      await doubleTapBody(tester, h, card);

      expect(h.state.debugEditing, 'f');
      expect(h.state.debugEditingFileBody, isTrue);
      expect(h.state.debugFileBody('f'), isNull, reason: '编辑中由输入框显示，画笔不再叠一层');
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '改完的正文');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(h.state.debugEditing, isNull);
      expect(h.state.debugEditingFileBody, isFalse);
      expect(writes, <({String path, String body})>[
        (path: '甲.md', body: '改完的正文'),
      ]);
      expect(boardChanges, 0, reason: '正文在 .md 里，改它不该标白板脏');
      expect(card.expanded, isTrue, reason: '退出编辑还是展开着');
    });

    testWidgets('展开的引用卡片画的是那篇笔记的正文', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 300,
          height: 200,
          file: '甲.md',
          expanded: true,
        ),
      ]);
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        noteBodies: const <String, String>{'甲.md': '# 会议记录\n第一行\n第二行'},
      );

      final String? painted = h.state.debugFileBody('f');
      expect(painted, contains('会议记录'));
      expect(painted, contains('第二行'));
      expect(painted, isNot(contains('#')), reason: '画出来的是渲染后的正文');
    });

    testWidgets('笔记改了，展开卡上的正文跟着改，卡片跟着长高', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 300,
          height: 200,
          file: '甲.md',
          expanded: true,
        ),
      ]);
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        noteBodies: const <String, String>{'甲.md': '改之前'},
      );
      expect(h.state.debugFileBody('f'), '改之前');
      final double firstHeight = doc.nodes.single.rect.height;

      await repumpWithBodies(tester, h, <String, String>{
        '甲.md': '改之后\n${'又一行\n' * 20}',
      });

      expect(
        h.state.debugFileBody('f'),
        contains('改之后'),
        reason: '引用是活的：笔记改了，卡片下一帧就是新的',
      );
      expect(
        doc.nodes.single.rect.height,
        greaterThan(firstHeight),
        reason: '正文长了窗口就得长，多出来的字不能被裁掉',
      );
    });

    testWidgets('笔记不在了：展开卡上没有正文，只剩标题', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 300,
          height: 120,
          file: '旧/甲.md',
          expanded: true,
        ),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);

      expect(h.state.debugFileBody('f'), isNull);
    });

    testWidgets('拖进来的卡片：松手的那个点就是它的左上角', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final Offset at = h.center + const Offset(120, -80);
      h.state.addFileCards(<String>['甲.md'], at: at);
      await tester.pump();

      final CanvasNode card = h.nodes.single;
      expect(card.rect.left, closeTo(at.dx, 0.01));
      expect(card.rect.top, closeTo(at.dy, 0.01));
    });

    testWidgets('库外文件刚导入：正文晚一步到，收起的卡片不挪不改', (WidgetTester tester) async {
      // 收起卡只量文件名，不需要等正文；正文晚到（甚至一直不到）都不该动它。
      final Harness h = await pumpBoard(tester);
      final FileNode card = h.state.addFileCards(<String>['新导入.md']).single;
      await tester.pump();
      final Rect before = card.rect;

      await repumpWithBodies(tester, h, <String, String>{
        '新导入.md': '# 会议记录\n${'正文一行\n' * 40}',
      });

      expect(card.rect, before);
      expect(card.expanded, isFalse);
      expect(h.state.debugFileBody(card.id), isNull);
    });

    testWidgets('正文一直不到：收起卡还是一行，展开后是兜底框，不崩', (WidgetTester tester) async {
      final Harness h = await pumpBoard(tester);
      final FileNode card = h.state.addFileCards(<String>['查无此篇.md']).single;
      await tester.pump();
      expect(
        card.height,
        closeTo(canvasFileTitleHeight + canvasCardPadding * 2, 0.01),
      );

      await clickTitle(tester, h, card.id);

      expect(card.expanded, isTrue);
      expect(card.width, canvasDefaultWidth);
      expect(card.height, 100);
      expect(h.state.debugFileBody(card.id), isNull);
    });

    testWidgets('文件列表拖过来：松手的地方就是左上角，落成收起卡并选中', (
      WidgetTester tester,
    ) async {
      final Harness h = await pumpBoard(tester);
      const Offset pointer = Offset(320, 240);

      h.state.addReferencedNotesFromGlobal(<String>['甲.md'], pointer);
      await tester.pump();

      final FileNode card = h.nodes.single as FileNode;
      final Offset world = h.camera.toWorld(pointer, h.stage);
      expect(card.rect.left, closeTo(world.dx, 0.01));
      expect(card.rect.top, closeTo(world.dy, 0.01));
      expect(card.expanded, isFalse);
      expect(h.state.debugSelection, <String>{card.id});
    });

    testWidgets('图片也是引用：卡片存的是库内路径，点标题不会「展开」', (
      WidgetTester tester,
    ) async {
      final Harness h = await pumpBoard(tester);
      const Offset pointer = Offset(320, 240);

      h.state.addReferencedNotesFromGlobal(<String>['assets/截屏.png'], pointer);
      await tester.pump();

      final FileNode card = h.nodes.single as FileNode;
      expect(card.file, 'assets/截屏.png', reason: '存路径，不拷贝字节');
      expect(card.expanded, isFalse);

      // 图片没有正文可展开：点标题条不该把它变成一个空框。
      final Rect before = card.rect;
      await clickTitle(tester, h, card.id);
      expect(card.expanded, isFalse);
      expect(card.rect, before);
    });

    testWidgets('图片卡片把图画出来，尺寸按原图比例', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 320,
          height: 200,
          file: 'assets/宽图.png',
        ),
      ]);
      final Uint8List png = await makePng(tester, 40, 20); // 2:1

      final Harness h = await pumpBoard(
        tester,
        document: doc,
        imageBytesOf: (String path) async => png,
      );
      await settleImageDecode(tester);

      expect(h.state.debugImageLoaded('assets/宽图.png'), isTrue);
      final FileNode card = h.nodes.single as FileNode;
      expect(card.width, closeTo(canvasImageCardSide, 0.5), reason: '长边 320');
      expect(card.height, closeTo(canvasImageCardSide / 2, 0.5), reason: '2:1');
    });

    testWidgets('拖图片右下角改大小，保持原图比例', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 320,
          height: 160,
          file: 'assets/宽图.png',
        ),
      ]);
      final Uint8List png = await makePng(tester, 40, 20); // 2:1
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        imageBytesOf: (String path) async => png,
      );
      await settleImageDecode(tester);

      final CanvasNode card = h.nodes.single;
      expect(card.width, closeTo(320, 0.5));

      // 先选中（手柄只画在选中的卡片上）。
      await tapCard(tester, h, card);
      expect(h.state.debugSelection, <String>{'f'});

      // 按在右下角，往右下拖半个卡片。
      final Offset corner = h.screenRect(card.rect).bottomRight;
      final TestGesture g = await tester.startGesture(
        corner,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await g.moveTo(corner + const Offset(160, 80));
      // **还没 pump**：改完尺寸必须已经排上一帧。文档是原地改的、画笔
      // `shouldRepaint` 恒为 true，漏了 setState 就没有任何东西会让它重画
      // ——那正是「拖的时候不动、松手才跳一下」的成因。
      expect(
        tester.binding.hasScheduledFrame,
        isTrue,
        reason: '拖动途中要立刻排一帧，不能等松手才重画',
      );
      await tester.pump();
      expect(h.state.debugResizingImage, isTrue);
      expect(
        card.width,
        greaterThan(320),
        reason: '拖动途中就要跟着变，不能等松手',
      );
      await g.up();
      await tester.pump();

      expect(card.width, greaterThan(320), reason: '拖右下角应该变大');
      expect(
        card.width / card.height,
        closeTo(2, 0.01),
        reason: '宽高比必须还是原图的 2:1，不能拉变形',
      );
      // 左上角钉死，不能整张卡跟着跑。
      expect(card.x, closeTo(0, 0.01));
      expect(card.y, closeTo(0, 0.01));
    });

    testWidgets('非图片卡片右下角没有手柄：拖那一下仍然是移动整张卡', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 250,
          height: 120,
          file: '笔记/甲.md',
        ),
      ]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode card = h.nodes.single;
      await tapCard(tester, h, card);
      final Rect before = card.rect;

      final Offset corner = h.screenRect(card.rect).bottomRight;
      final TestGesture g = await tester.startGesture(
        corner - const Offset(4, 4),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await g.moveTo(corner + const Offset(60, 40));
      await tester.pump();
      expect(h.state.debugResizingImage, isFalse, reason: '笔记卡片没有手柄');
      await g.up();
      await tester.pump();

      expect(card.width, before.width);
      expect(card.height, before.height);
    });

    testWidgets('悬浮在图片上 Ctrl+滚轮：改图的大小，画布不缩放', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 320,
          height: 160,
          file: 'assets/宽图.png',
        ),
      ]);
      final Uint8List png = await makePng(tester, 40, 20);
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        imageBytesOf: (String path) async => png,
      );
      await settleImageDecode(tester);
      final CanvasNode card = h.nodes.single;
      final double zoomBefore = h.zoom;
      final double widthBefore = card.width;

      // Ctrl 按着，滚轮往上（放大）。
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await scroll(tester, h.centerOf(card), const Offset(0, -120));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      // 把「一阵」窗口走完，别给下一条用例留个挂着的定时器。
      await tester.pump(const Duration(milliseconds: 800));

      expect(h.zoom, zoomBefore, reason: 'Ctrl+滚轮压在图上时画布不缩放');
      expect(card.width, greaterThan(widthBefore), reason: '图变大了');
      expect(
        card.width / card.height,
        closeTo(2, 0.01),
        reason: '等比缩放，不拉变形',
      );
    });

    testWidgets('悬浮在文字卡上 Ctrl+滚轮：还是缩放画布', (WidgetTester tester) async {
      final CanvasDocument doc = docWith(<CanvasNode>[cardAtOrigin(id: 'a')]);
      final Harness h = await pumpBoard(tester, document: doc);
      final CanvasNode card = h.nodes.single;
      final double zoomBefore = h.zoom;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await scroll(tester, h.centerOf(card), const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(h.zoom, greaterThan(zoomBefore), reason: '文字卡没有「改大小」这回事');
      expect(card.width, 250);
    });

    testWidgets('粘贴图片：先存进库里，再落成引用它的卡片', (
      WidgetTester tester,
    ) async {
      final Uint8List png = await makePng(tester, 8, 8);
      final Harness h = await pumpBoard(
        tester,
        imageBytesOf: (String path) async => null,
        onSaveImage: (Uint8List bytes) async => 'assets/粘的图.png',
        // 假剪贴板：真读剪贴板要原生插件，测试进程里没有。
        readClipboardImage: () async => png,
      );

      await h.state.pasteImageFromClipboard();
      await tester.pump();

      final FileNode card = h.nodes.single as FileNode;
      expect(card.file, 'assets/粘的图.png', reason: '卡片只存库内路径');
    });

    testWidgets('图片读不出来：卡片退回「图标 + 文件名」，不崩', (
      WidgetTester tester,
    ) async {
      final CanvasDocument doc = docWith(<CanvasNode>[
        FileNode(
          id: 'f',
          x: 0,
          y: 0,
          width: 320,
          height: 200,
          file: 'assets/没有这张.png',
        ),
      ]);
      final Harness h = await pumpBoard(
        tester,
        document: doc,
        imageBytesOf: (String path) async => null,
      );
      await settleImageDecode(tester);

      expect(h.state.debugImageLoaded('assets/没有这张.png'), isFalse);
      expect((h.nodes.single as FileNode).width, canvasImageCardSide);
    });

    testWidgets('一次拖几份：第一张的左上角在松手处，往下一张一张排', (
      WidgetTester tester,
    ) async {
      final Harness h = await pumpBoard(tester);
      const Offset pointer = Offset(320, 240);

      h.state.addReferencedNotesFromGlobal(<String>['甲.md', '乙.md'], pointer);
      await tester.pump();

      final Offset world = h.camera.toWorld(pointer, h.stage);
      expect((h.nodes[0] as FileNode).rect.left, closeTo(world.dx, 0.01));
      expect((h.nodes[0] as FileNode).rect.top, closeTo(world.dy, 0.01));
      expect(
        (h.nodes[1] as FileNode).rect.top,
        greaterThan((h.nodes[0] as FileNode).rect.bottom),
        reason: '第二张排在下面，不叠在第一张上',
      );
      expect(
        (h.nodes[1] as FileNode).rect.left,
        closeTo(world.dx, 0.01),
        reason: '整摞左对齐',
      );
    });
  });
}
