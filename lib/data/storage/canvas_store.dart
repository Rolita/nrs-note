/// 白板文件的存取接口。
///
/// 白板存成 `.nrs`（内容是 JSON Canvas 1.0），和笔记一样是 vault 里的
/// **普通文件**：可以在任意文件夹，可以用别的编辑器打开，可以拷走。
///
/// 之所以不复用 [NoteStore]：那个接口的每个方法都假设「对象是一篇笔记」
/// （`save(Note)`、`delete(Note)`、`historyOf(Note)`）。白板不参与标签、
/// 大纲、关系图谱、回收站版本这些索引，硬塞进去只会让两边都变脏。
library;

import 'note_store.dart' show TrashEntry;

/// 一块白板在磁盘上的身份。
class CanvasRef {
  const CanvasRef({
    required this.relativePath,
    required this.title,
    this.modified,
  });

  /// 相对 vault 的路径，带 `.nrs` 后缀。
  final String relativePath;

  /// 文件名去掉后缀。白板没有「标题」字段，标题就是文件名。
  final String title;

  final DateTime? modified;

  /// 所在文件夹的相对路径，根目录是空串。文件树按它把白板归到正确的那一层。
  String get folderPath {
    final String normalized = relativePath.replaceAll('\\', '/');
    final int slash = normalized.lastIndexOf('/');
    return slash <= 0 ? '' : normalized.substring(0, slash);
  }
}

/// 写不进去时抛这个：目标文件名被别的东西占了。
class CanvasPathTaken implements Exception {
  CanvasPathTaken(this.relativePath);

  final String relativePath;

  @override
  String toString() => 'CanvasPathTaken($relativePath)';
}

abstract class CanvasStore {
  /// 建目录、做恢复。可以重复调用。
  Future<void> init();

  /// 给人看的位置说明。
  String get location;

  /// 桌面端是真文件，浏览器端不是。
  bool get supportsNativeFiles;

  /// 列出所有白板，按路径排序。
  Future<List<CanvasRef>> list();

  /// 读原文。文件不在就抛 [FileSystemException] / 平台等价物。
  Future<String> read(String relativePath);

  /// 写原文。父目录不存在就建。
  Future<void> write(String relativePath, String contents);

  /// 新建一块空白板，返回它的相对路径。
  ///
  /// 重名会自己加 ` 2`、` 3`，不会覆盖已有的白板。
  Future<String> create(String folderPath, {String? title});

  /// 删除一块白板。
  ///
  /// 桌面端把它移进回收站并返回条目——白板和笔记共用一个 `.nrs-trash/`，
  /// 用户只有一个回收站，白板不该另立门户。浏览器端没有回收站，删了就是
  /// 删了，返回 null。
  Future<TrashEntry?> delete(String relativePath);

  /// 把回收站里的一条白板搬回原来的位置，重名时用 ` 2`。
  ///
  /// 只处理白板条目；笔记的恢复走 `NoteStore.restoreTrash`。
  Future<bool> restoreTrash(String entryId);
}

/// 把用户输入的名字收拾成一个能当文件名的东西。
///
/// 和笔记同一套规则：去掉路径分隔符和 Windows 不接受的字符，空名字退化成
/// 「未命名白板」。
String canvasFileName(String? raw) {
  const String fallback = '未命名白板';
  final String value = (raw ?? '').trim();
  if (value.isEmpty) return fallback;
  final String cleaned = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return fallback;
  return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
}

/// 去掉 `.nrs` 后缀。大小写不敏感，因为 Windows 上它们就是同一个文件。
String canvasTitleOf(String relativePath) {
  final String name = relativePath.split(RegExp(r'[\\/]')).last;
  if (name.toLowerCase().endsWith('.nrs')) {
    return name.substring(0, name.length - 4);
  }
  return name;
}

/// 路径是否安全：不许绝对路径、不许 `..` 往上跳。
///
/// 白板路径会从文件里读出来（`file` 字段），也会从会话恢复里读出来；
/// 任何一个都不该能指到 vault 外面去。
bool isSafeCanvasPath(String relativePath) {
  if (relativePath.trim().isEmpty) return false;
  final String normalized = relativePath.replaceAll('\\', '/');
  if (normalized.startsWith('/')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return false;
  return !normalized.split('/').any((String part) => part == '..');
}
