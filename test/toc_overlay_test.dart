import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/toc_overlay.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: AppTheme.build(AppPalette.midnight),
    home: Scaffold(
      body: Center(child: SizedBox(width: 800, height: 600, child: child)),
    ),
  );
}

Widget _toc(String body, {ValueChanged<int>? onSelect, int currentLine = 0}) {
  return _host(
    TocOverlay(
      body: body,
      currentLine: currentLine,
      onSelect: onSelect ?? (_) {},
    ),
  );
}

/// 把鼠标放到刻度列上。刻度距右缘 16–44（短横本身在 22–30）。
Future<TestGesture> _hoverTicks(WidgetTester tester) async {
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer();
  addTearDown(mouse.removePointer);
  final Rect rect = tester.getRect(find.byType(TocOverlay));
  await mouse.moveTo(Offset(rect.right - 26, rect.center.dy));
  await tester.pump();
  return mouse;
}

void main() {
  testWidgets('一个标题都没有时整列收起：不画刻度，也不建列表', (WidgetTester tester) async {
    await tester.pumpWidget(_toc('只有正文，没有标题。'));
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(TocOverlay), findsOneWidget);
  });

  testWidgets('极窄的格子把刻度让给正文', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.midnight),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 150,
              height: 600,
              child: TocOverlay(
                body: '# Alpha',
                currentLine: 0,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('悬停刻度向左展开目录卡，点一行交出行号', (WidgetTester tester) async {
    int? picked;
    await tester.pumpWidget(
      _toc(
        '# Alpha\n\n## Beta\n\n### Gamma\ntext',
        onSelect: (int l) => picked = l,
      ),
    );

    // 卡片收起时虽然已经把行建好了，但点不到。
    await tester.tap(find.text('Beta'), warnIfMissed: false);
    expect(picked, isNull);

    await _hoverTicks(tester);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Beta'));
    expect(picked, 2);
  });

  testWidgets('指针从刻度移进卡片不会把卡关掉，离开才收', (WidgetTester tester) async {
    int? picked;
    await tester.pumpWidget(
      _toc('# Alpha\n\n## Beta', onSelect: (int l) => picked = l),
    );
    final TestGesture mouse = await _hoverTicks(tester);
    await tester.pump(const Duration(milliseconds: 200));

    final Rect rect = tester.getRect(find.byType(TocOverlay));
    // 卡片的左半边，已经离开刻度列：悬停桥要把它接住。
    await mouse.moveTo(Offset(rect.right - 250, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Beta'));
    expect(picked, 2);

    // 真正离开卡片 160ms 之后，不可见的行不该再接点击。
    picked = null;
    await mouse.moveTo(Offset(rect.left + 10, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Beta'), warnIfMissed: false);
    expect(picked, isNull);
  });

  testWidgets('正文变了先不扫，停手 180ms 后才更新刻度', (WidgetTester tester) async {
    await tester.pumpWidget(_toc('# Alpha'));
    expect(find.text('Beta'), findsNothing);

    await tester.pumpWidget(_toc('# Alpha\n\n## Beta'));
    expect(find.text('Beta'), findsNothing);

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('卡片开着时正文一变就补扫，不等防抖', (WidgetTester tester) async {
    await tester.pumpWidget(_toc('# Alpha\n\n## Beta'));
    await _hoverTicks(tester);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.pumpWidget(_toc('# Alpha\n\n## Beta\n\n## Gamma'));
    expect(find.text('Gamma'), findsOneWidget);
  });
}
