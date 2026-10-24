import 'dart:ui' as ui;

import 'package:flutter/services.dart';

/// Reads a bitmap from the OS clipboard.
///
/// Windows answers with encoded PNG bytes when the source put PNG on the
/// clipboard, and with raw RGBA when it only supplied a DIB (screen clippers
/// and Paint do that). Both arrive here as PNG, which is what the vault stores.
///
/// No image, an unsupported platform, or a clipboard that another process holds
/// all mean null: paste simply does nothing.
class ClipboardImage {
  ClipboardImage._();

  static const MethodChannel _channel = MethodChannel('nrs/clipboard');

  static Future<Uint8List?> readPng() async {
    Object? reply;
    try {
      reply = await _channel.invokeMethod<Object?>('readImage');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
    if (reply is! Map) return null;

    final Object? png = reply['png'];
    if (png is Uint8List && png.isNotEmpty) return png;

    final Object? rgba = reply['rgba'];
    final Object? width = reply['width'];
    final Object? height = reply['height'];
    if (rgba is Uint8List && width is int && height is int) {
      return _encodeRgba(rgba, width, height);
    }
    return null;
  }

  static Future<Uint8List?> _encodeRgba(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    if (width <= 0 || height <= 0) return null;
    if (width * height > 40000000) return null;
    if (rgba.length < width * height * 4) return null;

    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      image = (await codec.getNextFrame()).image;
      final ByteData? png = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (png == null) return null;
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } catch (_) {
      // A malformed clipboard bitmap is not worth an error dialog over.
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }
}
