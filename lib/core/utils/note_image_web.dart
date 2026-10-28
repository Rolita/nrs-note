import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// The browser build has no file system to resolve vault paths against, so
/// only remote references can be drawn there.
ImageProvider? imageProviderFor(String? absolutePath, String source) {
  final String lower = source.trimLeft().toLowerCase();
  if (lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:')) {
    return NetworkImage(source);
  }
  return null;
}

/// 浏览器端没有文件系统，读不出库内图片的字节。
///
/// 白板上的图片卡在 Web 上会停在「图标 + 文件名」的样子——不是坏了，是那份
/// 字节在浏览器里根本不存在。桌面端才是白板的主场。
Future<Uint8List?> imageBytesAt(String absolutePath) async => null;

/// 浏览器端拿不到本地路径，也就没有尺寸可读。
///
/// 「查看大图」拿到 null 时百分比退回「相对适配」的倍数——不知道原图多大，
/// 这是唯一诚实的说法。
Future<({int width, int height})?> imageSizeAt(String absolutePath) async =>
    null;
