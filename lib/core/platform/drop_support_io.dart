import 'dart:io';

/// 系统拖放能不能用：桌面三个平台能，测试进程不能。
///
/// 拖放走的是 `super_drag_and_drop` 的原生实现，而 `flutter test` 里没有那个
/// 原生层：区域一建起来就会抛 `MissingPluginException`（异步抛出，连 catch 都
/// 接不住）。测试进程由 `FLUTTER_TEST` 环境变量标出来，这里据此把整块区域关掉，
/// 编辑器在测试里就是普通文本字段。
bool get systemDragAndDropAvailable =>
    Platform.environment['FLUTTER_TEST'] != 'true' &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
