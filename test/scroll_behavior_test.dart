import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/app.dart';

/// On a desktop a held left button means *select*, never *scroll*. Dragging the
/// empty strip to the right of the text column used to drag the whole page up
/// and down — that is the touch convention (APK), and it is why `mouse` is kept
/// out of [NrsScrollBehavior.dragDevices].
///
/// The harness mirrors the editor: a **full-width** scroll view whose content is
/// a narrow centred column. A narrow scroll view would shrink-wrap its child and
/// the margin would fall outside it, so the gesture would never be tested at all
/// (measured: `size=Size(200, 600)` — the drag silently missed the scrollable).
void main() {
  const Size viewSize = Size(800, 600);
  const Offset margin = Offset(650, 300); // right of the 200px column

  Future<ScrollController> pumpDocument(
    WidgetTester tester, {
    ScrollBehavior? behavior = const NrsScrollBehavior(),
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: behavior,
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Center(
                    child: SizedBox(width: 200, height: 4000),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('a held left button in the margin is not a scroll gesture', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = await pumpDocument(tester);
    final TestGesture gesture = await tester.startGesture(
      margin,
      kind: PointerDeviceKind.mouse,
    );
    for (int i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      0,
      reason: '鼠标按住右边空白处往下拖，页面上不该滚 —— 那是触摸屏的手势',
    );
  });

  testWidgets('a finger on that same spot still scrolls', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = await pumpDocument(tester);
    await tester.dragFrom(margin, const Offset(0, -240));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      greaterThan(0),
      reason: '触摸屏/手写笔仍然要能拖拽滚动，别把这条一起禁掉',
    );
  });

  testWidgets('the wheel still scrolls', (WidgetTester tester) async {
    final ScrollController controller = await pumpDocument(tester);
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byType(SingleChildScrollView))),
    );
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();

    expect(
      controller.offset,
      greaterThan(0),
      reason: '滚轮是桌面唯一的滚动方式，必须留着',
    );
  });

  testWidgets('the device list itself is the rule', (WidgetTester tester) async {
    // The widget-level test above can pass for the wrong reason (a recognizer
    // that never ran), so the list is pinned too.
    const NrsScrollBehavior behavior = NrsScrollBehavior();
    expect(behavior.dragDevices, isNot(contains(PointerDeviceKind.mouse)));
    expect(behavior.dragDevices, contains(PointerDeviceKind.touch));
  });
}
