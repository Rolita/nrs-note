/// 从图片头字节里读宽高，只读头、不解码。
///
/// 「查看大图」要告诉用户「原图多大、现在放到百分之几」，而百分比只有知道
/// 原图宽高才算得出来（见 `image_viewer.dart` 里的 `_baseScale`）。整张解码
/// 一遍只为拿两个数字太贵——一张 4K 截图解码要几十毫秒和几十 MB 内存。
///
/// 只认笔记里会出现的五种：PNG / JPEG / GIF / BMP / WebP。认不出就返回 null，
/// 调用方把它当成「不知道多大」，不是错误。
library;

import 'dart:typed_data';

/// 宽高（像素）。读不出来返回 null。
({int width, int height})? imageSizeFromHeader(Uint8List bytes) {
  // 10 是能认出任何格式的最短长度（GIF 的头正好 10 字节）。各格式自己还会
  // 再核一次够不够读——这里的门限只负责挡掉空数据和零碎字节。
  if (bytes.length < 10) return null;
  return _png(bytes) ?? _gif(bytes) ?? _bmp(bytes) ?? _webp(bytes) ?? _jpeg(bytes);
}

int _be16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

int _be32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _le16(Uint8List b, int i) => b[i] | (b[i + 1] << 8);

int _le32(Uint8List b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

bool _tag(Uint8List b, int i, String tag) {
  if (i + tag.length > b.length) return false;
  for (int k = 0; k < tag.length; k++) {
    if (b[i + k] != tag.codeUnitAt(k)) return false;
  }
  return true;
}

/// PNG：8 字节签名之后紧跟 IHDR，宽高在 16..24，大端。
({int width, int height})? _png(Uint8List b) {
  if (b.length < 24) return null;
  if (!_tag(b, 0, '\x89PNG')) return null;
  final int w = _be32(b, 16);
  final int h = _be32(b, 20);
  return _ok(w, h);
}

/// GIF：`GIF87a` / `GIF89a`，宽高在 6..10，小端。
({int width, int height})? _gif(Uint8List b) {
  if (b.length < 10) return null;
  if (!_tag(b, 0, 'GIF8')) return null;
  return _ok(_le16(b, 6), _le16(b, 8));
}

/// BMP：`BM`，DIB 头里宽高在 18..26，小端；高为负表示自上而下，取绝对值。
({int width, int height})? _bmp(Uint8List b) {
  if (b.length < 26) return null;
  if (!_tag(b, 0, 'BM')) return null;
  final int w = _le32(b, 18);
  final int rawH = _le32(b, 22);
  // 高是**有符号** 32 位：`_le32` 读出来的是一律非负的位模式，所以超过
  // 0x7FFFFFFF 的那些要手工折回负数，再取绝对值。
  final int h = rawH > 0x7FFFFFFF ? 0x100000000 - rawH : rawH;
  return _ok(w, h);
}

/// WebP：`RIFF....WEBP` 之后是 VP8（有损）/ VP8L（无损）/ VP8X（扩展）之一。
///
/// 三种块的宽高位置各不相同，而且都是**减一存**的位域，不是直接的数字——
/// 照搬「读 4 字节当宽」会得到一串荒唐的值。
({int width, int height})? _webp(Uint8List b) {
  if (b.length < 30) return null;
  if (!_tag(b, 0, 'RIFF') || !_tag(b, 8, 'WEBP')) return null;

  if (_tag(b, 12, 'VP8 ')) {
    // 关键帧起始码 9D 01 2A 之后的 4 字节：14 位宽 + 14 位高。
    if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
    final int w = _le16(b, 26) & 0x3FFF;
    final int h = _le16(b, 28) & 0x3FFF;
    return _ok(w, h);
  }
  if (_tag(b, 12, 'VP8L')) {
    if (b[20] != 0x2F) return null;
    final int bits = _le32(b, 21);
    final int w = (bits & 0x3FFF) + 1;
    final int h = ((bits >> 14) & 0x3FFF) + 1;
    return _ok(w, h);
  }
  if (_tag(b, 12, 'VP8X')) {
    final int w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
    final int h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
    return _ok(w, h);
  }
  return null;
}

/// JPEG：从头扫段，找到 SOF0..SOF15（C4 / C8 / CC 是别的段，要跳过）。
///
/// 不能按固定偏移读：APPn / 注释段长短不一，宽高在哪完全取决于相机或
/// 截图工具写了几个段。所以只能一段一段跳。
({int width, int height})? _jpeg(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;

  int i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final int marker = b[i + 1];
    // 填充字节：FF 后面还可能跟一串 FF。
    if (marker == 0xFF) {
      i++;
      continue;
    }
    // 没有长度字段的独立标记。
    if (marker == 0xD8 || marker == 0xD9 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    final int length = _be16(b, i + 2);
    if (length < 2) return null;

    final bool isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      // 段内：精度(1) 高(2) 宽(2) 分量数(1)
      final int h = _be16(b, i + 5);
      final int w = _be16(b, i + 7);
      return _ok(w, h);
    }
    // SOS 之后是压缩数据，再扫下去会撞上随机字节，停在这里。
    if (marker == 0xDA) return null;

    i += 2 + length;
  }
  return null;
}

({int width, int height})? _ok(int width, int height) =>
    width > 0 && height > 0 ? (width: width, height: height) : null;
