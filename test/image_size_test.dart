import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/image_size.dart';

/// 造一段只有头、没有像素数据的 PNG。
Uint8List pngHeader(int width, int height) {
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

Uint8List gifHeader(int width, int height) {
  final BytesBuilder b = BytesBuilder();
  b.add('GIF89a'.codeUnits);
  b.add(<int>[width & 0xFF, (width >> 8) & 0xFF]);
  b.add(<int>[height & 0xFF, (height >> 8) & 0xFF]);
  return b.toBytes();
}

Uint8List bmpHeader(int width, int height) {
  final Uint8List bytes = Uint8List(26);
  bytes[0] = 0x42; // B
  bytes[1] = 0x4D; // M
  // 宽在 18，高在 22，小端。
  bytes[18] = width & 0xFF;
  bytes[19] = (width >> 8) & 0xFF;
  bytes[22] = height & 0xFF;
  bytes[23] = (height >> 8) & 0xFF;
  return bytes;
}

/// VP8X（扩展格式）：宽高各 3 字节、减一存。
Uint8List webpHeader(int width, int height) {
  final Uint8List bytes = Uint8List(30);
  bytes.setAll(0, 'RIFF'.codeUnits);
  bytes.setAll(8, 'WEBP'.codeUnits);
  bytes.setAll(12, 'VP8X'.codeUnits);
  final int w = width - 1;
  final int h = height - 1;
  bytes[24] = w & 0xFF;
  bytes[25] = (w >> 8) & 0xFF;
  bytes[26] = (w >> 16) & 0xFF;
  bytes[27] = h & 0xFF;
  bytes[28] = (h >> 8) & 0xFF;
  bytes[29] = (h >> 16) & 0xFF;
  return bytes;
}

/// 基线 JPEG：SOI + 一个 SOF0 段。
Uint8List jpegHeader(int width, int height) {
  final BytesBuilder b = BytesBuilder();
  b.add(<int>[0xFF, 0xD8]);
  b.add(<int>[0xFF, 0xC0, 0x00, 0x11, 0x08]);
  b.add(<int>[(height >> 8) & 0xFF, height & 0xFF]);
  b.add(<int>[(width >> 8) & 0xFF, width & 0xFF]);
  b.add(<int>[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
  return b.toBytes();
}

void main() {
  group('认格式', () {
    test('PNG 从 IHDR 读，大端', () {
      expect(imageSizeFromHeader(pngHeader(1920, 1080)), (
        width: 1920,
        height: 1080,
      ));
    });

    test('GIF 从头里读，小端', () {
      expect(imageSizeFromHeader(gifHeader(320, 240)), (
        width: 320,
        height: 240,
      ));
    });

    test('BMP 从 DIB 头读', () {
      expect(imageSizeFromHeader(bmpHeader(64, 48)), (width: 64, height: 48));
    });

    test('BMP 的高是负数时取绝对值', () {
      final Uint8List bytes = bmpHeader(64, 48);
      // 自上而下存的 BMP 把高写成负的 -48 = 0xFFFFFFD0。
      bytes[22] = 0xD0;
      bytes[23] = 0xFF;
      bytes[24] = 0xFF;
      bytes[25] = 0xFF;
      expect(imageSizeFromHeader(bytes), (width: 64, height: 48));
    });

    test('WebP 的 VP8X 是减一存的，要加回来', () {
      expect(imageSizeFromHeader(webpHeader(800, 600)), (
        width: 800,
        height: 600,
      ));
    });

    test('JPEG 扫到 SOF0 才读，跳过前面的段', () {
      expect(imageSizeFromHeader(jpegHeader(1600, 900)), (
        width: 1600,
        height: 900,
      ));
    });

    test('JPEG 的 SOF 前面隔着 APP0 段也能找到', () {
      final BytesBuilder b = BytesBuilder();
      b.add(<int>[0xFF, 0xD8]);
      // APP0，长度 16（含长度本身那 2 字节）。
      b.add(<int>[0xFF, 0xE0, 0x00, 0x10]);
      b.add(List<int>.filled(14, 0));
      b.add(<int>[0xFF, 0xC0, 0x00, 0x11, 0x08]);
      b.add(<int>[0x00, 0x64, 0x01, 0x40]);
      b.add(<int>[0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]);
      expect(imageSizeFromHeader(b.toBytes()), (width: 320, height: 100));
    });
  });

  group('认不出就说认不出', () {
    test('空数据和太短的数据返回 null', () {
      expect(imageSizeFromHeader(Uint8List(0)), isNull);
      expect(imageSizeFromHeader(Uint8List(8)), isNull);
    });

    test('不是图片的字节返回 null', () {
      final Uint8List text = Uint8List.fromList('这不是一张图片'.codeUnits);
      expect(imageSizeFromHeader(text), isNull);
    });

    test('PNG 头被截断时返回 null，而不是读出一半', () {
      final Uint8List full = pngHeader(1920, 1080);
      expect(imageSizeFromHeader(full.sublist(0, 20)), isNull);
    });

    test('宽高是零的图当成认不出', () {
      expect(imageSizeFromHeader(pngHeader(0, 1080)), isNull);
      expect(imageSizeFromHeader(gifHeader(100, 0)), isNull);
    });

    test('JPEG 只有 SOI 没有 SOF 时返回 null', () {
      expect(imageSizeFromHeader(Uint8List.fromList(<int>[0xFF, 0xD8, 0, 0])),
          isNull);
    });

    test('JPEG 撞上 SOS 就停，不把压缩数据当段长', () {
      final BytesBuilder b = BytesBuilder();
      b.add(<int>[0xFF, 0xD8]);
      b.add(<int>[0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00]);
      b.add(<int>[0xFF, 0xC0, 0x00, 0x11, 0x08, 0, 1, 0, 1, 0x03]);
      b.add(List<int>.filled(16, 0));
      expect(imageSizeFromHeader(b.toBytes()), isNull);
    });
  });
}
