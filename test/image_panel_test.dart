import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/note_images.dart';
import 'package:nrs/ui/editor/image_panel.dart';

/// 图片侧边栏：列出当前文件所有图片，点一下就跳到那一行。
void main() {
  Future<void> pumpPanel(
    WidgetTester tester,
    List<NoteImage> images,
    ValueChanged<int> onSelect,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.midnight),
        home: Scaffold(
          body: ImagePanel(
            images: images,
            onSelect: onSelect,
            // 缩略图不是这个测试的事：给 null 让它走占位，行高才稳定。
            providerFor: (_) => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('一张图一行：标题、行号、宽度都写清楚', (WidgetTester tester) async {
    final List<NoteImage> images = extractImages(
      '![一只猫](assets/a.png)\n字\n<img src="assets/b.png" width="320">',
    );
    await pumpPanel(tester, images, (_) {});

    expect(find.text('图片'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: '表头是张数');
    expect(find.text('一只猫'), findsOneWidget);
    expect(find.text('第 1 行 · 原尺寸'), findsOneWidget);
    // 没有 alt 就用文件名，宽度照抄源码。
    expect(find.text('b.png'), findsOneWidget);
    expect(find.text('第 3 行 · 宽 320'), findsOneWidget);
  });

  testWidgets('点一行跳到那一行的行首偏移', (WidgetTester tester) async {
    const String body = '开头\n![一只猫](assets/a.png)\n![狗](assets/b.png)';
    final List<NoteImage> images = extractImages(body);
    final List<int> jumped = <int>[];
    await pumpPanel(tester, images, jumped.add);

    await tester.tap(find.text('狗'));
    expect(jumped, <int>[body.indexOf('![狗]')]);

    await tester.tap(find.text('一只猫'));
    expect(jumped, <int>[body.indexOf('![狗]'), body.indexOf('![一只猫]')]);
  });

  testWidgets('没有图片时给一句说明，不是一片空白', (WidgetTester tester) async {
    await pumpPanel(tester, const <NoteImage>[], (_) {});
    expect(find.text('0'), findsOneWidget);
    expect(find.textContaining('还没有图片'), findsOneWidget);
  });

  testWidgets('远程图在说明里标出来', (WidgetTester tester) async {
    final List<NoteImage> images = extractImages(
      '<img src="https://img.test/a.png">',
    );
    await pumpPanel(tester, images, (_) {});
    expect(find.text('第 1 行 · 原尺寸 · 网络'), findsOneWidget);
  });
}
