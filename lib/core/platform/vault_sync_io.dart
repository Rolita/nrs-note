import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Calls [onFocus] whenever the desktop window regains focus.
///
/// Window focus rather than Flutter's lifecycle: on Windows the two do not line
/// up reliably, and clicking back into the app is exactly when an edit made in
/// another program needs to be noticed.
VoidCallback startVaultSync(VoidCallback onFocus) {
  final _WindowFocusListener listener = _WindowFocusListener(onFocus);
  windowManager.addListener(listener);
  return () => windowManager.removeListener(listener);
}

class _WindowFocusListener extends WindowListener {
  _WindowFocusListener(this.onFocus);

  final VoidCallback onFocus;

  @override
  void onWindowFocus() => onFocus();
}
