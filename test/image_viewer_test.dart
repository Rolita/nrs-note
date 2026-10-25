import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/ui/editor/image_viewer.dart';

/// 一张真能解码的 PNG。1×1 太小点不中，所以按需生成。
Future<Uint8List> makePng(int width, int height) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? data = await image.toByteData(
    format: ui.ImageByteFormat.png,
  );
  image.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// 只有头、像素是垃圾的 PNG：解码会失败，但**读头拿尺寸**照常。
Uint8List fakePngHeader(int width, int height) {
  final BytesBuilder b = BytesBuilder();
  b.add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.add(<int>[0, 0, 0, 13]);
  b.add('IHDR'.codeUnits);
  b.add(<int>[
    (width >> 24) & 0xFF,
    (width >> 16) & 0xFF,
    (width >> 8) & 0xFF,
    width & 0xFF,
    (height >> 24) & 0xFF,
    (height >> 16) & 0xFF,
    (height >> 8) & 0xFF,
    height & 0xFF,
  ]);
  return b.toBytes();
}

void main() {
  late Uint8List png;
  late List<String> tempDirs;

  /// ⛔ 不能用 `pumpAndSettle`：图没解码完时 `frameBuilder` 给的是
  /// `CircularProgressIndicator`，它永远在转，settle 会一直等到超时。
  /// 固定推两帧——一帧布局、一帧让 160ms 的淡入走完。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  setUp(() async {
    png = await makePng(200, 150);
    tempDirs = <String>[];
  });

  tearDown(() {
    for (final String path in tempDirs) {
      final Directory dir = Directory(path);
      // `FileImage` 可能还攥着句柄，删不掉不是测试的问题。
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 系统临时目录，留给系统自己回收。
      }
    }
  });

  NoteImageView image({
    String source = 'assets/截图.png',
    String? alt,
    String? absolutePath,
  }) => NoteImageView(
    source: source,
    alt: alt,
    provider: MemoryImage(png),
    absolutePath: absolutePath,
  );

  Future<bool> pumpViewer(
    WidgetTester tester, {
    required List<NoteImageView> images,
    int index = 0,
    Size size = const Size(1200, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: NoteImageViewer(
          images: images,
          index: index,
          onClose: () => closed = true,
        ),
      ),
    );
    // 首帧 + LayoutBuilder 推的那一帧。
    await settle(tester);
    // 读文件头走的是真 IO，fake async 推不动它，得让真实事件循环跑一会儿，
    // 每跑一次再 pump 一帧把 setState 画出来。
    for (int i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await settle(tester);
    }
    return closed;
  }

  String percent(WidgetTester tester) {
    final Iterable<Text> texts = tester.widgetList<Text>(find.byType(Text));
    return texts
        .map((Text t) => t.data ?? '')
        .firstWhere((String s) => s.endsWith('%'));
  }

  group('基本', () {
    testWidgets('打开就显示文件名和适配档的百分比', (WidgetTester tester) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      expect(find.text('截图.png'), findsOneWidget);
      expect(percent(tester), '100%');
    });

    testWidgets('有 alt 时顶栏用 alt，不是文件名', (WidgetTester tester) async {
      await pumpViewer(
        tester,
        images: <NoteImageView>[image(alt: '首页草图')],
      );

      expect(find.text('首页草图'), findsOneWidget);
      expect(find.text('截图.png'), findsNothing);
    });

    testWidgets('一张图时不出现徽标和翻页箭头', (WidgetTester tester) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      expect(find.textContaining('/'), findsNothing);
      expect(find.byTooltip('上一张'), findsNothing);
    });
  });

  group('缩放', () {
    testWidgets('加号放大一档，减号缩回来，0 复位', (WidgetTester tester) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await settle(tester);
      expect(percent(tester), '200%');

      // 上限是 1:1 的 3 倍，第三下就顶住了。
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await settle(tester);
      expect(percent(tester), '300%');

      // 从 300% 减半是 150%，不是 200%——每一档都是除法，不是回到上一档。
      await tester.sendKeyEvent(LogicalKeyboardKey.minus);
      await settle(tester);
      expect(percent(tester), '150%');

      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await settle(tester);
      expect(percent(tester), '100%');
    });

    testWidgets('放大到上限就停住，不会越放越糊', (WidgetTester tester) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      for (int i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        await settle(tester);
      }
      // 没有原图尺寸时 1:1 = 100%，上限是它的 3 倍。
      expect(percent(tester), '300%');
    });

    testWidgets('复位在适配档是灰的，放大之后才可点', (WidgetTester tester) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      final Finder reset = find.text('复位');
      expect(reset, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await settle(tester);
      await tester.tap(reset);
      await settle(tester);
      expect(percent(tester), '100%');
    });
  });

  group('原图尺寸决定百分比', () {
    testWidgets('图比窗口大时，适配档不是 100%，双击才到 100%', (
      WidgetTester tester,
    ) async {
      final Directory dir = Directory.systemTemp.createTempSync('nrs_viewer');
      tempDirs.add(dir.path);
      final File file = File('${dir.path}/big.png');
      // 只写头：解码会失败，但尺寸读得出来——这正是这条测试要的。
      file.writeAsBytesSync(fakePngHeader(2400, 1600));

      await pumpViewer(
        tester,
        images: <NoteImageView>[image(absolutePath: file.path)],
      );

      // 顶栏副行报出原图尺寸。
      expect(find.text('2400 × 1600'), findsOneWidget);

      final String fitted = percent(tester);
      expect(fitted, isNot('100%'), reason: '适配档不该是原图大小');

      // 双击：适配 ↔ 1:1。两次点击要挨得够近才算双击——中间只推 50ms，
      // 推满 kDoubleTapTimeout 就变成两次单击了。
      final Finder picture = find.byType(Image).first;
      await tester.tap(picture);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(picture);
      await settle(tester);
      expect(percent(tester), '100%');
    });

    testWidgets('远程图没有本地路径，就不显示尺寸那一行', (
      WidgetTester tester,
    ) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      expect(find.textContaining(' × '), findsNothing);
    });
  });

  group('旋转', () {
    testWidgets('R 顺时针转 90°，转四次回到原样', (WidgetTester tester) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      RotatedBox box() => tester.widget<RotatedBox>(find.byType(RotatedBox));
      expect(box().quarterTurns, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await settle(tester);
      expect(box().quarterTurns, 1);

      for (int i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await settle(tester);
      }
      expect(box().quarterTurns, 0);
    });

    testWidgets('⇧R 逆时针：从 0 绕回 3', (WidgetTester tester) async {
      await pumpViewer(tester, images: <NoteImageView>[image()]);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);

      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        3,
      );
    });
  });

  group('翻页', () {
    testWidgets('两张图：徽标说位置，右键头翻过去再翻回来', (
      WidgetTester tester,
    ) async {
      await pumpViewer(
        tester,
        images: <NoteImageView>[
          image(source: 'assets/a.png'),
          image(source: 'assets/b.png'),
        ],
      );

      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('a.png'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('b.png'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);
    });

    testWidgets('翻页把缩放复位，不会带着 400% 跳到下一张', (
      WidgetTester tester,
    ) async {
      await pumpViewer(
        tester,
        images: <NoteImageView>[
          image(source: 'assets/a.png'),
          image(source: 'assets/b.png'),
        ],
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await settle(tester);
      expect(percent(tester), '200%');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await settle(tester);
      expect(percent(tester), '100%');
    });

    testWidgets('翻到边界就没反应，不会崩', (WidgetTester tester) async {
      await pumpViewer(
        tester,
        images: <NoteImageView>[
          image(source: 'assets/a.png'),
          image(source: 'assets/b.png'),
        ],
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(find.text('1 / 2'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(find.text('2 / 2'), findsOneWidget);
    });
  });

  group('关闭', () {
    testWidgets('Esc 关闭', (WidgetTester tester) async {
      bool closed = false;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: NoteImageViewer(
            images: <NoteImageView>[image()],
            index: 0,
            onClose: () => closed = true,
          ),
        ),
      );
      await settle(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(closed, isTrue);
    });

    testWidgets('点图片本身不关——落下去是想看细节', (WidgetTester tester) async {
      bool closed = false;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: NoteImageViewer(
            images: <NoteImageView>[image()],
            index: 0,
            onClose: () => closed = true,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byType(Image).first);
      await settle(tester);
      expect(closed, isFalse);
    });

    testWidgets('点图外的空白关闭', (WidgetTester tester) async {
      bool closed = false;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: NoteImageViewer(
            images: <NoteImageView>[image()],
            index: 0,
            onClose: () => closed = true,
          ),
        ),
      );
      await settle(tester);

      // 顶栏和底栏中间那片区域里，图只有 200×150，四角是空的。
      final Rect stage = tester.getRect(find.byType(InteractiveViewer));
      await tester.tapAt(stage.topLeft + const Offset(6, 6));
      await settle(tester);
      expect(closed, isTrue);
    });

    testWidgets('顶栏的关闭键关闭', (WidgetTester tester) async {
      bool closed = false;
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: NoteImageViewer(
            images: <NoteImageView>[image()],
            index: 0,
            onClose: () => closed = true,
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.byTooltip('关闭（Esc）'));
      await settle(tester);
      expect(closed, isTrue);
    });
  });
}
