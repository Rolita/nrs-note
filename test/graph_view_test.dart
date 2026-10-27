import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/data/models/note.dart';

import 'package:nrs/ui/graph/graph_view.dart';

Note note(String id, String title, {String body = '', String folder = ''}) {
  final DateTime t = DateTime(2026, 1, 1);
  return Note(
    id: id,
    title: title,
    body: body,
    createdAt: t,
    updatedAt: t,
    folderPath: folder,
  );
}

/// A—B—C 一条链，D 挂在 A 上，E 谁都不连（孤立）。
List<Note> chain() => <Note>[
  note('a', 'A', body: '[[B]] 和 [[D]]'),
  note('b', 'B', body: '[[C]]'),
  note('c', 'C'),
  note('d', 'D', folder: '项目'),
  note('e', 'E'),
];

class Harness {
  Harness(this.view, this.opened);

  final GraphViewState view;
  final List<String> opened;
}

Future<Harness> pumpGraph(
  WidgetTester tester, {
  List<Note>? notes,
  String? currentId = 'a',
  Size size = const Size(1000, 700),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final List<String> opened = <String>[];
  final GlobalKey<GraphViewState> key = GlobalKey<GraphViewState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.midnight),
      home: Scaffold(
        body: GraphView(
          key: key,
          notes: notes ?? chain(),
          currentId: currentId,
          onOpenNote: opened.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return Harness(key.currentState!, opened);
}

/// 节点在屏幕上的位置。
Offset nodeAt(WidgetTester tester, Harness h, String id) {
  final Offset origin = tester.getTopLeft(find.byKey(h.view.debugStageKey));
  return origin + h.view.debugNodeCenter(id)!;
}

/// 点一下，然后把动画帧走完。
///
/// 画布上的按下/抬起会敲一次重绘、把 Ticker 拉起来；只 `pump()` 不推进时间，
/// 测试结束时会报 "Pending timers"。
Future<void> tapAndSettle(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 400));
}

/// 把鼠标挪到某个位置（不按键 → 发的是 `PointerHoverEvent`）。
///
/// 用完必须 `removePointer`，否则下一帧的命中测试还会把这只鼠标算进去。
Future<TestGesture> hoverAt(WidgetTester tester, Offset at) async {
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer(location: const Offset(1, 1));
  addTearDown(mouse.removePointer);
  await mouse.moveTo(at);
  await tester.pump(const Duration(milliseconds: 400));
  return mouse;
}

void main() {
  group('打开就有一张图', () {
    testWidgets('节点、边、孤立数都从双链算出来', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      expect(h.view.debugNodeCount, 5);
      // A—B、A—D、B—C 三条；E 谁都不连。
      expect(h.view.debugEdgeCount, 3);
      expect(h.view.debugLitCount, 5);
      expect(find.text('图谱设置'), findsOneWidget);
    });

    testWidgets('空库给一句提示，不是一张空白画布', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester, notes: <Note>[]);

      expect(h.view.debugNodeCount, 0);
      expect(find.textContaining('还没有笔记'), findsOneWidget);
    });
  });

  group('悬停高亮，单击打开', () {
    testWidgets('鼠标停在节点上就高亮，不用点', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      expect(h.view.debugHover, isNull);
      await hoverAt(tester, nodeAt(tester, h, 'c'));

      expect(h.view.debugHover, isNotNull);
      expect(h.opened, isEmpty, reason: '悬停不该打开任何东西');
    });

    testWidgets('单击节点直接打开那篇笔记', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await tapAndSettle(tester, nodeAt(tester, h, 'c'));

      expect(h.opened, <String>['c']);
    });

    testWidgets('拖动节点只挪位置，不打开', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      final TestGesture drag = await tester.startGesture(
        nodeAt(tester, h, 'c'),
      );
      await drag.moveBy(const Offset(26, 14));
      await drag.moveBy(const Offset(26, 14));
      await drag.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.opened, isEmpty);
    });

    testWidgets('悬浮的节点钉在原地，别的一点照转', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await hoverAt(tester, nodeAt(tester, h, 'c'));
      final Offset before = h.view.debugNodeCenter('c')!;
      final Offset otherBefore = h.view.debugNodeCenter('b')!;

      // 球转了，但 c 被钉住。
      h.view.debugSpin(0.12, 0.26);

      expect(h.view.debugNodeCenter('c'), before, reason: '钉住的点不该跟着转');
      expect(
        h.view.debugNodeCenter('b'),
        isNot(otherBefore),
        reason: '其他的点要继续漂',
      );
    });

    testWidgets('其他节点是渐变压暗的，不是一下就黑', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      // d 连的是 a，和 c 没关系：悬停 c 时它属于「其余节点」。
      final double calm = h.view.debugAlphaOf('d')!;

      await hoverAt(tester, nodeAt(tester, h, 'c'));
      final double mid = h.view.debugAlphaOf('d')!;
      await tester.pumpAndSettle();
      final double dim = h.view.debugAlphaOf('d')!;

      expect(mid, lessThan(calm), reason: '已经开始暗了');
      expect(mid, greaterThan(dim), reason: '但还没暗到底——中间得有一帧');
      expect(dim, closeTo(calm * 0.55, 0.02), reason: '终点是 0.55 倍');
    });

    testWidgets('点空白取消高亮', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await hoverAt(tester, nodeAt(tester, h, 'c'));
      expect(h.view.debugHover, isNotNull);

      final Offset empty =
          tester.getTopLeft(find.byKey(h.view.debugStageKey)) +
          const Offset(500, 16);
      await tapAndSettle(tester, empty);
      expect(h.view.debugHover, isNull);
      expect(h.opened, isEmpty, reason: '点空白不该打开任何笔记');
    });
  });

  group('右键钉住这一片，其余照转', () {
    Future<void> rightClickAt(WidgetTester tester, Offset at) async {
      final TestGesture mouse = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      // 鼠标设备要摘掉，否则后面的 hoverAt 新建一只鼠标会撞上 MouseTracker 的断言。
      await mouse.removePointer();
      await tester.pumpAndSettle();
    }

    testWidgets('右键节点：它和邻居停在原地，其余继续漂', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await rightClickAt(tester, nodeAt(tester, h, 'a'));

      // A 自己 + 它的两个邻居 B、D。
      expect(h.view.debugPinnedCount, 3);
      expect(h.opened, isEmpty, reason: '右键不该打开笔记');

      final Offset beforeA = h.view.debugNodeCenter('a')!;
      final Offset beforeB = h.view.debugNodeCenter('b')!;
      final Offset beforeC = h.view.debugNodeCenter('c')!;

      h.view.debugSpin(0.12, 0.26);

      expect(h.view.debugNodeCenter('a'), beforeA, reason: '被钉住的点不该跟着转');
      expect(h.view.debugNodeCenter('b'), beforeB, reason: '邻居也要一起钉住');
      expect(
        h.view.debugNodeCenter('c'),
        isNot(beforeC),
        reason: '不在这片里的点要继续漂',
      );
    });

    testWidgets('钉住后鼠标移开，焦点和关联节点的高亮还留着', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);
      // c 和 a 没关系：它暗不暗，直接说明焦点还在不在。
      final double calmC = h.view.debugAlphaOf('c')!;

      await rightClickAt(tester, nodeAt(tester, h, 'a'));
      final Offset empty =
          tester.getTopLeft(find.byKey(h.view.debugStageKey)) +
          const Offset(500, 16);
      await hoverAt(tester, empty);
      await tester.pumpAndSettle();

      expect(h.view.debugHover, isNull, reason: '鼠标确实已经离开所有节点');
      expect(h.view.debugFocus, isNotNull, reason: '焦点留在被钉住的那颗上');
      expect(
        h.view.debugAlphaOf('c'),
        closeTo(calmC * 0.55, 0.02),
        reason: '没有焦点的话 c 会回到原亮度',
      );
    });

    testWidgets('钉住后悬浮别的节点，两圈关联同时亮', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await rightClickAt(tester, nodeAt(tester, h, 'a'));
      final Offset pinnedA = h.view.debugNodeCenter('a')!;
      // d 是 a 的另一颗邻居。悬浮 c 之后它必须还亮着。
      final double litD = h.view.debugAlphaOf('d')!;

      // c 和 a 没有直连：悬浮它应该叠出第二圈，而不是把 a 那圈顶掉。
      await hoverAt(tester, nodeAt(tester, h, 'c'));
      await tester.pumpAndSettle();

      expect(h.view.debugHover, isNotNull, reason: '鼠标确实停在 c 上');
      expect(
        h.view.debugFocus,
        isNot(h.view.debugHover),
        reason: '主焦点仍是钉住的 a',
      );
      expect(
        h.view.debugSecondFocus,
        h.view.debugHover,
        reason: '悬浮的 c 成为第二焦点',
      );
      expect(
        h.view.debugAlphaOf('c'),
        closeTo(1, 0.02),
        reason: '第二焦点也按主焦点提亮',
      );
      expect(
        h.view.debugAlphaOf('d'),
        closeTo(litD, 0.02),
        reason: 'a 的关联节点没有被 c 的焦点压暗',
      );

      h.view.debugSpin(0.12, 0.26);
      expect(
        h.view.debugNodeCenter('a'),
        pinnedA,
        reason: '悬浮别的节点不该松开原来钉住的那颗',
      );
    });

    testWidgets('再右键一次松开，点停在原地不弹回', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await rightClickAt(tester, nodeAt(tester, h, 'a'));
      h.view.debugSpin(0.30, 0.40);
      final Offset frozen = h.view.debugNodeCenter('a')!;

      // 钉住的点还在原处，右键它（位置就是冻住的那个坐标）就能松开。
      await rightClickAt(tester, frozen);

      expect(h.view.debugHoldOn, isFalse);
      expect(h.view.debugPinnedCount, 0);
      expect(
        (h.view.debugNodeCenter('a')! - frozen).distance,
        lessThan(0.5),
        reason: '松开之后停在原地，不再回到球面上原来的位置',
      );
    });

    testWidgets('右键钉住片里的关联节点，钉住换成新的那颗', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await rightClickAt(tester, nodeAt(tester, h, 'a'));
      expect(h.view.debugPinnedCount, 3, reason: 'a 自己和 b、d');

      // b 是 a 的邻居。右键 b 不是松开，而是换钉成 b + 它的邻居 a、c。
      await rightClickAt(tester, nodeAt(tester, h, 'b'));
      expect(h.view.debugPinnedCount, 3);
      expect(h.view.debugHoldOn, isTrue);
      expect(
        h.view.debugAlphaOf('b'),
        closeTo(1, 0.02),
        reason: '焦点落在新钉住的 b 上',
      );

      final Offset beforeA = h.view.debugNodeCenter('a')!;
      final Offset beforeC = h.view.debugNodeCenter('c')!;
      final Offset beforeD = h.view.debugNodeCenter('d')!;

      h.view.debugSpin(0.12, 0.26);

      expect(
        h.view.debugNodeCenter('a'),
        beforeA,
        reason: 'a 也是 b 的邻居，继续钉住',
      );
      expect(
        h.view.debugNodeCenter('c'),
        beforeC,
        reason: 'c 进入新的钉住组，停在原地',
      );
      expect(
        h.view.debugNodeCenter('d'),
        isNot(beforeD),
        reason: 'd 只属于上一组，已经松开并继续漂',
      );
    });

    testWidgets('右键空白处也能松开', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await rightClickAt(tester, nodeAt(tester, h, 'a'));
      expect(h.view.debugPinnedCount, 3);

      final Offset empty =
          tester.getTopLeft(find.byKey(h.view.debugStageKey)) +
          const Offset(500, 16);
      await rightClickAt(tester, empty);

      expect(h.view.debugHoldOn, isFalse);
      expect(h.view.debugPinnedCount, 0);
      expect(h.opened, isEmpty);
    });
  });

  group('拖拽：贴着球面滑，顺手拨开邻居', () {
    testWidgets('拖拽时关联节点被拉近，松手后保持收拢', (
      WidgetTester tester,
    ) async {
      final Harness h = await pumpGraph(tester);

      final Offset start = nodeAt(tester, h, 'a');
      final Offset toCentre =
          tester.getRect(find.byKey(h.view.debugStageKey)).center - start;
      final Offset dir = toCentre.distance < 1e-3
          ? const Offset(1, 0)
          : toCentre / toCentre.distance;

      double angleBetween(String x, String y) {
        final a = h.view.debugWorldOf(x);
        final b = h.view.debugWorldOf(y);
        return math.acos(
          (a.x * b.x + a.y * b.y + a.z * b.z).clamp(-1.0, 1.0),
        );
      }

      final double angleBefore = angleBetween('a', 'b');
      final Offset bBefore = h.view.debugNodeCenter('b')!;
      final ({double x, double y, double z}) eBefore = h.view.debugWorldOf('e');

      // 往球心方向拖：不会拖出轮廓，[_autoTurn] 不介入，世界坐标的变化只来自
      // 这次拖拽本身。
      final TestGesture drag = await tester.startGesture(start);
      await drag.moveBy(dir * 36);
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        (h.view.debugNodeCenter('b')! - bBefore).distance,
        greaterThan(8),
        reason: 'B 是 A 的邻居，得被牵着一起走',
      );
      final double angleDuring = angleBetween('a', 'b');
      expect(
        angleDuring,
        lessThan(angleBefore - 0.005),
        reason: '拖拽期间关联节点被收向被拖节点，A–B 的球面距离变短',
      );
      expect(
        angleDuring,
        greaterThanOrEqualTo(math.min(angleBefore, 0.16) - 1e-3),
        reason: '收拢有下限：B 不能挤到 A 身上',
      );
      final ({double x, double y, double z}) eAfter = h.view.debugWorldOf('e');
      expect(
        (eAfter.x - eBefore.x).abs() +
            (eAfter.y - eBefore.y).abs() +
            (eAfter.z - eBefore.z).abs(),
        lessThan(1e-6),
        reason: '不相干的点留在原处',
      );

      await drag.up();
      await tester.pumpAndSettle();
      final double angleAfter = angleBetween('a', 'b');
      expect(
        angleAfter,
        lessThan(angleBefore - 0.005),
        reason: '松手后保持收拢，不恢复原来的球面距离',
      );
      expect(
        angleAfter,
        greaterThanOrEqualTo(math.min(angleBefore, 0.16) - 1e-3),
        reason: '收拢有下限',
      );
    });

    testWidgets('拖完之后节点就停在光标下', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      // 球是斜着的（进场时会转向最大的一簇），所以「屏幕位移 → 球面切向」
      // 这一步的基向量取错方向，节点就会朝鼠标的反面跑。这条守着它。
      final Offset start = nodeAt(tester, h, 'c');
      const Offset move = Offset(60, -40);

      final TestGesture drag = await tester.startGesture(start);
      await drag.moveBy(move);
      await tester.pump(const Duration(milliseconds: 60));

      expect(
        (nodeAt(tester, h, 'c') - (start + move)).distance,
        lessThan(3),
        reason: '节点该跟着光标走，不能反过来',
      );

      await drag.up();
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('旁边的节点会被拨开，松手弹回原位', (WidgetTester tester) async {
      // 5 个点的球上邻居本来就离得远，没什么可拨的。要一张够密的图。
      final List<Note> many = <Note>[
        for (int i = 0; i < 60; i++)
          note('n$i', 'N$i', body: '[[n${(i + 1) % 60}]] [[n${(i + 9) % 60}]]'),
      ];
      final Harness h = await pumpGraph(tester, notes: many, currentId: 'n0');

      // `debugNodeCenter` 是画布内坐标，手势要的是全局坐标。
      final Offset origin = tester.getTopLeft(
        find.byKey(h.view.debugStageKey),
      );
      final Size stage = tester.getSize(find.byKey(h.view.debugStageKey));
      final Offset centre = Offset(stage.width / 2, stage.height / 2);

      // 取最靠中间的那颗当拖拽对象，再取**球面上**离它最近的一颗当邻居。
      // 不能按屏幕距离挑：边缘被透视压得很密，屏幕上挨着的两颗在球上可能
      // 隔着半张大陆。
      String pivot = 'n0';
      Offset pivotAt = Offset.zero;
      ({double x, double y, double z}) pivotWorld = (x: 0, y: 0, z: 0);
      double best = double.infinity;
      for (final Note n in many) {
        final Offset? at = h.view.debugNodeCenter(n.id);
        if (at == null) continue;
        final double d = (at - centre).distance;
        if (d < best) {
          best = d;
          pivot = n.id;
          pivotAt = at;
          pivotWorld = h.view.debugWorldOf(n.id);
        }
      }
      String mate = pivot;
      double mateD = double.infinity;
      for (final Note n in many) {
        if (n.id == pivot) continue;
        final ({double x, double y, double z}) w = h.view.debugWorldOf(n.id);
        final double dx = w.x - pivotWorld.x;
        final double dy = w.y - pivotWorld.y;
        final double dz = w.z - pivotWorld.z;
        final double d = dx * dx + dy * dy + dz * dz;
        if (d < mateD) {
          mateD = d;
          mate = n.id;
        }
      }
      mateD = math.sqrt(mateD);
      expect(mateD, lessThan(0.6), reason: '找的这颗得真的在推开范围里');

      final Offset mateBefore = h.view.debugNodeCenter(mate)!;
      // 沿着「跟邻居连线垂直」的方向拖：
      //   * 拖拽距离变了，但它和邻居在球上的距离几乎不变，不会一拖就滑出
      //     推开范围（那会让断言变成在测别的东西）；
      //   * 这个方向是绕球心的切线，离球心还是原来那么远，不会触发「拖到
      //     边缘球自转」——那条是另一组用例。
      final Offset toMate = mateBefore - pivotAt;
      final Offset inward = centre - pivotAt;
      Offset dir = Offset(-toMate.dy, toMate.dx);
      if (dir.distance < 1e-3) dir = const Offset(1, 0);
      dir = dir / dir.distance;
      if (dir.dx * inward.dx + dir.dy * inward.dy < 0) dir = -dir;

      final TestGesture drag = await tester.startGesture(origin + pivotAt);
      await drag.moveBy(dir * 44);
      // 推开是 90ms 铺开的，得走够帧数才到满。
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(
        (h.view.debugNodeCenter(mate)! - mateBefore).distance,
        greaterThan(4),
        reason: '被拖的节点旁边该让出一个洞',
      );

      await drag.up();
      await tester.pumpAndSettle();
      expect(
        (h.view.debugNodeCenter(mate)! - mateBefore).distance,
        lessThan(0.5),
        reason: '松手之后邻居要回到原来的位置',
      );
    });

    testWidgets('拖出轮廓之后球自己转，把节点带到球的另一侧', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      // 屏幕半径上限约 1.02R（R = 700 × 0.30 = 210），所以光标停在 280px
      // 处时节点根本够不着——不转球的话它只会卡在轮廓上，世界坐标一动不动。
      final Offset start = nodeAt(tester, h, 'c');
      final ({double x, double y, double z}) before = h.view.debugWorldOf('c');

      final TestGesture drag = await tester.startGesture(start);
      await drag.moveTo(start + const Offset(280, 0));
      await tester.pump(const Duration(milliseconds: 300));

      final ({double x, double y, double z}) after = h.view.debugWorldOf('c');
      final double moved = <double>[
        after.x - before.x,
        after.y - before.y,
        after.z - before.z,
      ].map((double v) => v * v).reduce((double a, double b) => a + b);
      expect(
        moved,
        greaterThan(0.04),
        reason: '拖到轮廓外，球该在指下滚起来，节点要绕到球的另一侧',
      );

      await drag.up();
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('拖拽只挪位置，不算单击', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      final Offset start = nodeAt(tester, h, 'c');
      final TestGesture drag = await tester.startGesture(start);
      // 慢慢挪：每一帧都不到 1 像素，按「单帧增量」判断就会被当成单击。
      for (int i = 0; i < 10; i++) {
        await drag.moveBy(const Offset(1.2, 0.8));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await drag.up();
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.opened, isEmpty, reason: '挪了 14 像素就不是单击了');
    });
  });

  group('局部图谱与深度', () {
    testWidgets('切到局部只剩中心与直接邻居', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);
      expect(h.view.debugNodeCount, 5);

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('局部'));
      await tester.pumpAndSettle();

      // A 的邻居是 B 和 D；C、E 都不在。
      expect(h.view.debugNodeCount, 3);
      expect(h.view.debugEdgeCount, 2);
    });

    testWidgets('深度滑块拉到底，子图跟着扩大', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('局部'));
      await tester.pumpAndSettle();
      expect(h.view.debugNodeCount, 3);
      expect(h.view.debugSettings.depth, 1);

      // 点滑块最右端 = 拖到底 = 4 跳。
      final Finder slider = find.byType(Slider).first;
      final Rect rect = tester.getRect(slider);
      await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
      await tester.pumpAndSettle();

      expect(h.view.debugSettings.depth, 4);
      // 4 跳足够走完整张连通图：A B C D，E 仍然连不上。
      expect(h.view.debugNodeCount, 4);
    });

    testWidgets('没有选中笔记时局部图谱是空态，不是崩溃', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester, currentId: null);

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('局部'));
      await tester.pumpAndSettle();

      expect(h.view.debugNodeCount, 0);
      expect(find.textContaining('没有选中的笔记'), findsOneWidget);
    });
  });

  group('筛选', () {
    testWidgets('标签是自动的：面板里不再有「显示标签」开关', (
      WidgetTester tester,
    ) async {
      await pumpGraph(tester);
      // 放大才显示、缩小就收掉——没有第二种状态，就不该留一个开关让人去关。
      expect(find.text('显示标签'), findsNothing);
    });

    testWidgets('关掉孤立笔记，孤立节点真的消失并重排', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);
      expect(h.view.debugNodeCount, 5);

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('孤立笔记'));
      await tester.pumpAndSettle();

      expect(h.view.debugNodeCount, 4);
      expect(h.view.debugEdgeCount, 3);
    });

    testWidgets('搜索只让命中的亮着，不删节点', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'c');
      await tester.pumpAndSettle();

      expect(h.view.debugLitCount, 1);
      expect(h.view.debugNodeCount, 5);
    });

    testWidgets('点图例筛一个文件夹，再点取消', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      // 图例默认收起，先点标题展开。
      await tester.tap(find.text('分组 · 文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('项目'), findsOneWidget);

      await tester.tap(find.text('项目'));
      await tester.pumpAndSettle();
      expect(h.view.debugSettings.folder, '项目');
      expect(h.view.debugLitCount, 1);

      await tester.tap(find.text('项目'));
      await tester.pumpAndSettle();
      expect(h.view.debugSettings.folder, isNull);
      expect(h.view.debugLitCount, 5);
    });
  });

  group('视图操作', () {
    testWidgets('滚轮缩放，百分比跟着变', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);
      final Offset before = h.view.debugNodeCenter('a')!;

      final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
      final Offset centre =
          tester.getCenter(find.byKey(h.view.debugStageKey));
      pointer.hover(centre);
      await tester.sendEventToBinding(
        pointer.scroll(const Offset(0, -240)),
      );
      await tester.pumpAndSettle();

      expect(h.view.debugNodeCenter('a'), isNot(before));
    });

    testWidgets('图谱设置默认收起，点标题展开再收起', (
      WidgetTester tester,
    ) async {
      await pumpGraph(tester);
      expect(find.text('孤立笔记'), findsNothing, reason: '默认收起');

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();
      expect(find.text('孤立笔记'), findsOneWidget, reason: '点标题展开');

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();
      expect(find.text('孤立笔记'), findsNothing, reason: '再点收起');
      expect(find.text('图谱设置'), findsOneWidget);
    });
  });

  group('信号脉冲', () {
    testWidgets('悬停节点时沿连线送光点，移开后自然消散', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);
      final Offset empty =
          tester.getTopLeft(find.byKey(h.view.debugStageKey)) +
          const Offset(500, 16);

      expect(
        h.view.debugPulseCount,
        0,
        reason: '测试环境不自转，静止时不该有自发脉冲',
      );

      final TestGesture mouse = await hoverAt(tester, nodeAt(tester, h, 'a'));
      expect(h.view.debugPulseCount, greaterThan(0), reason: 'A 有两条连线');
      expect(h.view.debugPulseRingCount, greaterThan(0), reason: '源节点先震一圈');

      await mouse.moveTo(empty);
      await tester.pumpAndSettle();
      expect(h.view.debugPulseCount, 0, reason: '光点走完就结束，不留残影');
      expect(h.view.debugPulseRingCount, 0);
    });

    testWidgets('右键钉住的中心也一直供能，鼠标移开不熄', (
      WidgetTester tester,
    ) async {
      final Harness h = await pumpGraph(tester);

      final TestGesture mouse = await tester.startGesture(
        nodeAt(tester, h, 'a'),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await mouse.removePointer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        h.view.debugPulseCount,
        greaterThan(0),
        reason: '钉住的 a 是焦点，脉冲从它出发，不依赖鼠标还停在那儿',
      );

      await tester.pumpAndSettle();
      expect(h.view.debugPulseCount, 0, reason: '这一轮走完就收，不常驻');
    });
  });
}
