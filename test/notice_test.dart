import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/common/notices.dart';

void main() {
  late NoticeController notices;

  setUp(() {
    notices = NoticeController();
  });

  tearDown(() {
    notices.dispose();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          body: NoticeScope(
            controller: notices,
            child: Builder(
              builder: (BuildContext context) => Stack(
                children: <Widget>[
                  Align(
                    alignment: Alignment.topCenter,
                    child: NoticeHost(controller: notices),
                  ),
                  Positioned(
                    left: 20,
                    bottom: 20,
                    child: TextButton(
                      onPressed: () => showNotice(
                        context,
                        '保存失败',
                        kind: NoticeKind.error,
                        detail: '文件被其他程序占用',
                      ),
                      child: const Text('show'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void show(
    String message, {
    NoticeKind kind = NoticeKind.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    notices.show(
      NoticeData(
        message: message,
        kind: kind,
        actionLabel: actionLabel,
        onAction: onAction,
      ),
    );
  }

  testWidgets('a notice enters as one card and its action fires once', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    int undos = 0;
    show(
      '已移入回收站',
      kind: NoticeKind.success,
      actionLabel: '撤销',
      onAction: () => undos++,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('已移入回收站'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    expect(find.byKey(NoticeHost.cardKey), findsOneWidget);

    final Rect card = tester.getRect(find.byKey(NoticeHost.cardKey));
    // A receipt with an undo action is still one row: the pill is 32px tall.
    expect(card.height, 32);
    expect(card.width, lessThanOrEqualTo(352));
    // Content decides the width; a short receipt must not stretch to the cap.
    expect(card.width, lessThan(240));

    await tester.tap(find.text('撤销'));
    expect(undos, 1);
    await tester.pump();
    // The same undo must not run twice while the card is fading out.
    await tester.tap(find.text('撤销'), warnIfMissed: false);
    expect(undos, 1);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(NoticeHost.cardKey), findsNothing);
  });

  testWidgets('a notice without an action dismisses itself', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    show('已从磁盘重新载入');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(NoticeHost.cardKey), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(NoticeHost.cardKey), findsNothing);
  });

  testWidgets('pointing at the card pauses its countdown', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    show('已从磁盘重新载入');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(2, 2));
    await mouse.moveTo(tester.getCenter(find.byKey(NoticeHost.cardKey)));
    await tester.pump();

    // Well past the 2.4s window: hover must hold the card on screen.
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(NoticeHost.cardKey), findsOneWidget);

    await mouse.moveTo(const Offset(2, 2));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(NoticeHost.cardKey), findsNothing);
  });

  testWidgets('a second notice replaces the first instead of stacking', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    show('第一条');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    show('第二条');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('第一条'), findsNothing);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.byKey(NoticeHost.cardKey), findsOneWidget);
  });

  testWidgets('the close button dismisses the card at once', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    show('已从磁盘重新载入');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byKey(NoticeHost.cardKey), findsNothing);
  });

  testWidgets('showNotice finds the controller through the scope', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    await tester.tap(find.text('show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(find.textContaining('文件被其他程序占用'), findsOneWidget);
  });
}
