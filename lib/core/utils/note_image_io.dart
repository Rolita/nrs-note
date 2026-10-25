import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'image_size.dart';

bool _isRemote(String source) {
  final String lower = source.trimLeft().toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:');
}

/// An [ImageProvider] for a note image, or null when it cannot be shown.
///
/// [absolutePath] is the vault-resolved location of a relative reference;
/// [source] is the reference exactly as written in the note.
ImageProvider? imageProviderFor(String? absolutePath, String source) {
  if (_isRemote(source)) return NetworkImage(source);
  if (absolutePath == null) return null;
  return FileImage(File(absolutePath));
}

/// 只读图片头，拿原图宽高。
///
/// 「查看大图」用它算「原图 1:1 是百分之几」——整张解码一遍只为两个数字太贵
/// （一张 4K 截图要几十毫秒和几十 MB）。读不出来返回 null，不是错误。
///
/// 64KB 足够覆盖所有格式的头：JPEG 的 SOF 段最靠后的情况也在 EXIF 之后，
/// 而 EXIF 缩略图最多几十 KB；再大的只能算畸形文件。
Future<({int width, int height})?> imageSizeAt(String absolutePath) async {
  RandomAccessFile? file;
  try {
    file = await File(absolutePath).open();
    final Uint8List head = await file.read(65536);
    return imageSizeFromHeader(head);
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}
