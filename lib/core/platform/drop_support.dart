/// 系统拖放（把浏览器里的链接拖进窗口）能不能用。
library;

export 'drop_support_web.dart' if (dart.library.io) 'drop_support_io.dart';
