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
      theme: AppTheme.build(AppPalette.dark),
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

/// 点一下，然后把双击判定那 40ms 走完。
///
/// 画布上挂着 [DoubleTapGestureRecognizer]，每次按下都会留一个 40ms 的
/// 计时器；只 `pump()` 不推进时间，测试结束时会报 "Pending timers"。
Future<void> tapAndSettle(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 400));
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

    testWidgets('没有任何双链时说清楚怎么连', (WidgetTester tester) async {
      await pumpGraph(
        tester,
        notes: <Note>[note('a', 'A'), note('b', 'B')],
      );

      expect(find.textContaining('还没有双链'), findsOneWidget);
    });
  });

  group('单击选中，双击跳转', () {
    testWidgets('单击节点只选中，不跳转', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await tapAndSettle(tester, nodeAt(tester, h, 'c'));

      expect(h.view.debugSelected, isNotNull);
      expect(h.view.debugNodeCount, 5, reason: '选中不该改变图');
      expect(h.opened, isEmpty);
    });

    testWidgets('双击节点打开那篇笔记', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      final Offset target = nodeAt(tester, h, 'c');
      await tester.tapAt(target);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tapAt(target);
      await tester.pumpAndSettle();

      expect(h.opened, <String>['c']);
    });

    testWidgets('点空白取消选中', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await tapAndSettle(tester, nodeAt(tester, h, 'c'));
      expect(h.view.debugSelected, isNotNull);

      await tapAndSettle(
        tester,
        tester.getTopLeft(find.byKey(h.view.debugStageKey)) +
            const Offset(12, 12),
      );
      expect(h.view.debugSelected, isNull);
    });
  });

  group('局部图谱与深度', () {
    testWidgets('切到局部只剩中心与直接邻居', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);
      expect(h.view.debugNodeCount, 5);

      await tester.tap(find.text('局部'));
      await tester.pumpAndSettle();

      // A 的邻居是 B 和 D；C、E 都不在。
      expect(h.view.debugNodeCount, 3);
      expect(h.view.debugEdgeCount, 2);
    });

    testWidgets('深度滑块拉到底，子图跟着扩大', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

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

      await tester.tap(find.text('孤立笔记'));
      await tester.pumpAndSettle();

      expect(h.view.debugNodeCount, 4);
      expect(h.view.debugEdgeCount, 3);
    });

    testWidgets('搜索只让命中的亮着，不删节点', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

      await tester.enterText(find.byType(TextField).first, 'c');
      await tester.pumpAndSettle();

      expect(h.view.debugLitCount, 1);
      expect(h.view.debugNodeCount, 5);
    });

    testWidgets('点图例筛一个文件夹，再点取消', (WidgetTester tester) async {
      final Harness h = await pumpGraph(tester);

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

    testWidgets('面板可以整块收起', (WidgetTester tester) async {
      await pumpGraph(tester);
      expect(find.text('孤立笔记'), findsOneWidget);

      await tester.tap(find.text('图谱设置'));
      await tester.pumpAndSettle();

      expect(find.text('孤立笔记'), findsNothing);
      expect(find.text('图谱设置'), findsOneWidget);
    });
  });
}
