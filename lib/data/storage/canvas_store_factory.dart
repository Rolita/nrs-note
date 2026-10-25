/// 按编译目标挑白板存储实现。
///
/// 桌面端是真 `.nrs` 文件；浏览器端退到 `localStorage`，让 Web 预览也能用。
library;

export 'canvas_store.dart';
export 'canvas_store_web.dart' if (dart.library.io) 'canvas_store_io.dart';
