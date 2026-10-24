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
