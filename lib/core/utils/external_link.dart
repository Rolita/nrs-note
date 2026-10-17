/// Cross-platform "open this link in the default browser" helper.
library;

export 'external_link_web.dart' if (dart.library.io) 'external_link_io.dart';
