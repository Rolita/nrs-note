/// Cross-platform window bootstrap.
library;

export 'window_setup_web.dart' if (dart.library.io) 'window_setup_io.dart';
