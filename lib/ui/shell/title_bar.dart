/// Cross-platform window chrome.
///
/// Desktop builds draw their own title bar (the OS caption is removed in
/// `window_setup_io.dart`); the browser build has nothing to draw, because the
/// tab is already the window frame and a page cannot move its own window.
library;

export 'title_bar_web.dart' if (dart.library.io) 'title_bar_io.dart';
