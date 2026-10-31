/// Browser build: nothing to size, the viewport owns the layout.
Future<void> setupWindow({required double opacity}) async {}

/// Browser build: the page itself is never translucent; the desktop setting
/// only exists to keep the two entry points the same shape.
Future<void> applyWindowOpacity(double opacity) async {}
