import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/canvas/canvas_pickers.dart';

Future<void> pumpPicker(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.dark),
      home: Scaffold(body: Builder(builder: (_) => child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('整理网址', () {
    test('不带协议就补 https', () {
      expect(normalizeCanvasUrl('example.com'), 'https://example.com');
      expect(
        normalizeCanvasUrl('  example.com/a?b=1  '),
        'https://example.com/a?b=1',
      );
    });

    test('已经带协议的照原样', () {
      expect(normalizeCanvasUrl('https://a.b/c'), 'https://a.b/c');
      expect(normalizeCanvasUrl('http://a.b'), 'http://a.b');
    });

    test('只认 http 和 https', () {
      expect(normalizeCanvasUrl('javascript:alert(1)'), '');
      expect(normalizeCanvasUrl('file:///c:/windows'), '');
      expect(normalizeCanvasUrl('ftp://a.b'), '');
    });

    test('空白输入什么都不返回', () {
      expect(normalizeCanvasUrl(''), '');
      expect(normalizeCanvasUrl('   '), '');
    });
  });

  group('挑笔记', () {
    testWidgets('列出全部笔记', (WidgetTester tester) async {
      String? picked;
      await pumpPicker(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              picked = await showCanvasFilePicker(
                context,
                files: const <({String path, String title})>[
                  (path: 'a.md', title: '甲'),
                  (path: 'b/c.md', title: '乙'),
                ],
              );
            },
            child: const Text('open'),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('甲'), findsOneWidget);
      expect(find.text('乙'), findsOneWidget);
      expect(find.text('b/c.md'), findsOneWidget);

      await tester.tap(find.text('乙'));
      await tester.pumpAndSettle();
      expect(picked, 'b/c.md');
    });

    testWidgets('搜索框按标题和路径过滤', (WidgetTester tester) async {
      await pumpPicker(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showCanvasFilePicker(
              context,
              files: const <({String path, String title})>[
                (path: 'notes/a.md', title: '甲'),
                (path: 'other/b.md', title: '乙'),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'other');
      await tester.pumpAndSettle();

      expect(find.text('乙'), findsOneWidget);
      expect(find.text('甲'), findsNothing);
    });

    testWidgets('一篇都没有时说清楚', (WidgetTester tester) async {
      await pumpPicker(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => showCanvasFilePicker(
              context,
              files: const <({String path, String title})>[],
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('库里还没有笔记'), findsOneWidget);
    });
  });

  group('填网址', () {
    testWidgets('填完返回整理过的地址', (WidgetTester tester) async {
      String? url;
      await pumpPicker(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              url = await showCanvasLinkDialog(context);
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'example.com');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(url, 'https://example.com');
    });

    testWidgets('Esc 取消，什么也不返回', (WidgetTester tester) async {
      bool? returned;
      await pumpPicker(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              final String? url = await showCanvasLinkDialog(context);
              returned = url == null;
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'example.com');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(returned, isTrue);
    });
  });
}
