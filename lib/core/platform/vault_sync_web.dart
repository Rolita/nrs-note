import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Calls [onFocus] whenever the tab becomes visible again.
VoidCallback startVaultSync(VoidCallback onFocus) {
  void onVisibilityChange(web.Event event) {
    if (web.document.visibilityState == 'visible') onFocus();
  }

  final web.EventListener listener = onVisibilityChange.toJS;
  web.document.addEventListener('visibilitychange', listener);
  return () => web.document.removeEventListener('visibilitychange', listener);
}
