import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/clipboard_image.dart';

/// The Dart half of the clipboard channel. The native half cannot run in a test
/// process, so the method channel is mocked: the point here is that both shapes
/// of reply end up as PNG bytes and that a missing/broken channel stays quiet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('nrs/clipboard');
  final List<MethodCall> calls = <MethodCall>[];

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) {
          calls.add(call);
          return handler(call);
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  test('returns PNG bytes untouched', () async {
    final Uint8List bytes = Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      1,
      2,
      3,
    ]);
    mock((MethodCall call) async => <String, Object>{'png': bytes});

    final Uint8List? result = await ClipboardImage.readPng();

    expect(result, bytes);
    expect(calls.single.method, 'readImage');
  });

  test('encodes raw RGBA as PNG', () async {
    mock(
      (MethodCall call) async => <String, Object>{
        'rgba': Uint8List.fromList(<int>[255, 0, 0, 255, 0, 255, 0, 255]),
        'width': 2,
        'height': 1,
      },
    );

    final Uint8List? png = await ClipboardImage.readPng();

    expect(png, isNotNull);
    expect(png!.sublist(0, 8), <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ], reason: 'RGBA 必须真的被编码成 PNG');
  });

  test('an unavailable plugin means no image', () async {
    expect(await ClipboardImage.readPng(), isNull);
  });

  test('a platform error is swallowed', () async {
    mock(
      (MethodCall call) async =>
          throw PlatformException(code: 'clipboard_busy'),
    );

    expect(await ClipboardImage.readPng(), isNull);
  });

  test('a null or empty reply means no image', () async {
    mock((MethodCall call) async => null);
    expect(await ClipboardImage.readPng(), isNull);

    mock((MethodCall call) async => <String, Object>{'png': Uint8List(0)});
    expect(await ClipboardImage.readPng(), isNull);
  });

  test('an RGBA reply with no dimensions is ignored', () async {
    mock(
      (MethodCall call) async => <String, Object>{
        'rgba': Uint8List.fromList(<int>[1, 2, 3, 4]),
      },
    );

    expect(await ClipboardImage.readPng(), isNull);
  });

  test('a short RGBA buffer is refused rather than scrambled', () async {
    mock(
      (MethodCall call) async => <String, Object>{
        'rgba': Uint8List.fromList(<int>[1, 2, 3]),
        'width': 2,
        'height': 2,
      },
    );

    expect(await ClipboardImage.readPng(), isNull);
  });

  test('a zero-sized bitmap is refused', () async {
    mock(
      (MethodCall call) async => <String, Object>{
        'rgba': Uint8List.fromList(<int>[1, 2, 3, 4]),
        'width': 0,
        'height': 1,
      },
    );

    expect(await ClipboardImage.readPng(), isNull);
  });
}
