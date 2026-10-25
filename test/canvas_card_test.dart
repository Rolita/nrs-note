import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/table_colors.dart';
import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/core/utils/table_model.dart' show CellColor, CellColorToken;
import 'package:nrs/ui/canvas/canvas_card.dart';
import 'package:nrs/ui/canvas/canvas_style.dart';

Future<void> pumpCard(
  WidgetTester tester,
  CanvasNode node, {
  double zoom = 1,
  bool selected = false,
  Size size = const Size(300, 200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(AppPalette.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: node.width,
            height: node.height,
            child: CanvasCard(node: node, zoom: zoom, selected: selected),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

TextNode text(String body, {String? color}) => TextNode(
  id: 'n1',
  x: 0,
  y: 0,
  width: 250,
  height: 120,
  text: body,
  color: color,
);

void main() {
  group('预设色', () {
    test('六个编号各自落到一个色名', () {
      expect(canvasCellColor('1')!.token, CellColorToken.red);
      expect(canvasCellColor('2')!.token, CellColorToken.amber);
      expect(canvasCellColor('3')!.token, CellColorToken.amber);
      expect(canvasCellColor('4')!.token, CellColorToken.green);
      expect(canvasCellColor('5')!.token, CellColorToken.blue);
      expect(canvasCellColor('6')!.token, CellColorToken.purple);
    });

    test('认不出来的一律当作没设色', () {
      expect(canvasCellColor(null), isNull);
      expect(canvasCellColor(''), isNull);
      expect(canvasCellColor('7'), isNull);
      expect(canvasCellColor('red'), isNull);
    });

    test('#RRGGBB 补上不透明的 alpha', () {
      final CellColor color = canvasCellColor('#FF8800')!;
      expect(color.custom, 0xFFFF8800);
    });

    test('#RRGGBBAA 的 alpha 在尾巴上，要挪到头上', () {
      final CellColor color = canvasCellColor('#FF880080')!;
      expect(color.custom, 0x80FF8800);
    });

    test('长度不对的十六进制不认', () {
      expect(canvasCellColor('#FFF'), isNull);
      expect(canvasCellColor('#FF8800FF00'), isNull);
      expect(canvasCellColor('#GGGGGG'), isNull);
    });

    test('换色菜单里没有重复的色', () {
      final List<CellColorToken> tokens = <CellColorToken>[
        for (final String? value in canvasColorChoices)
          if (value != null) canvasCellColor(value)!.token!,
      ];
      expect(tokens.toSet().length, tokens.length);
    });
  });

  group('卡片外观', () {
    testWidgets('画得出文字', (WidgetTester tester) async {
      await pumpCard(tester, text('一张卡片'));

      expect(find.text('一张卡片'), findsOneWidget);
    });

    testWidgets('空卡片给一句占位，不是一片空白', (WidgetTester tester) async {
      await pumpCard(tester, text(''));

      expect(find.text('空卡片'), findsOneWidget);
    });

    testWidgets('没设色时用浮起来的那一层', (WidgetTester tester) async {
      await pumpCard(tester, text('无颜色'));

      final BoxDecoration d =
          tester.widget<DecoratedBox>(find.byType(DecoratedBox).first).decoration
              as BoxDecoration;
      expect(d.color, AppPalette.dark.surfaceRaised);
    });

    testWidgets('设了色就用那个色的底色和墨色', (WidgetTester tester) async {
      await pumpCard(tester, text('红卡片', color: '1'));

      final BoxDecoration d =
          tester.widget<DecoratedBox>(find.byType(DecoratedBox).first).decoration
              as BoxDecoration;
      expect(
        d.color,
        tableFillColor(AppPalette.dark, const CellColor.token(CellColorToken.red)),
      );

      final Text label = tester.widget<Text>(find.text('红卡片'));
      expect(
        label.style!.color,
        tableInkColor(AppPalette.dark, const CellColor.token(CellColorToken.red)),
      );
    });

    testWidgets('选中时描边换成 accent', (WidgetTester tester) async {
      await pumpCard(tester, text('选中的'), selected: true);

      final BoxDecoration d =
          tester.widget<DecoratedBox>(find.byType(DecoratedBox).first).decoration
              as BoxDecoration;
      expect(d.border!.top.color, AppPalette.dark.accent);
      expect(d.border!.top.width, 1.5);
    });

    testWidgets('字号跟着缩放走', (WidgetTester tester) async {
      await pumpCard(tester, text('放大'), zoom: 2);

      final Text label = tester.widget<Text>(find.text('放大'));
      expect(label.style!.fontSize, 26);
    });

    testWidgets('文件卡片显示文件名而不是整条路径', (WidgetTester tester) async {
      await pumpCard(
        tester,
        FileNode(
          id: 'f1',
          x: 0,
          y: 0,
          width: 250,
          height: 120,
          file: '项目/计划.md',
        ),
      );

      expect(find.text('计划.md'), findsOneWidget);
      expect(find.text('项目/计划.md'), findsOneWidget, reason: '小字给完整路径');
    });

    testWidgets('链接卡片显示网址', (WidgetTester tester) async {
      await pumpCard(
        tester,
        LinkNode(
          id: 'l1',
          x: 0,
          y: 0,
          width: 250,
          height: 120,
          url: 'https://example.com',
        ),
      );

      expect(find.text('https://example.com'), findsOneWidget);
    });
  });
}
