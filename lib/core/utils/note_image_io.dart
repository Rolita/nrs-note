import 'dart:io';

import 'package:flutter/widgets.dart';

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
