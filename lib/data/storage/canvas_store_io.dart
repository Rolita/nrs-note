import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/utils/canvas_document.dart';
import 'atomic_file.dart';
import 'canvas_store.dart';
import 'note_store.dart' show TrashEntry;
import 'trash_store.dart';

/// 桌面端：vault 里的真实 `.nrs` 文件。
///
/// 目录和笔记共用同一个 vault（默认「文稿/NRS Notes」），因为白板就是
/// vault 里的一份文件——放进别的目录，用户在两棵树里找不到它。
class IoCanvasStore implements CanvasStore {
  IoCanvasStore({this.rootPath, AtomicFileWriter? writer})
    : _writer = writer ?? AtomicFileWriter();

  /// 没给就用和 `IoNoteStore` 一样的默认目录。
  ///
  /// 两个默认值必须一致：vault 换了地方而白板还写在老地方，用户会发现
  /// 「笔记都在，白板全没了」。
  final String? rootPath;  final AtomicFileWriter _writer;

  Directory? _root;

  /// vault 里的隐藏目录（回收站、版本历史）不是白板，扫的时候要跳过。
  static const Set<String> _skipDirs = <String>{'.nrs-trash', '.nrs-history'};

  @override
  String get location => _root?.path ?? rootPath ?? '';

  @override
  bool get supportsNativeFiles => true;

  @override
  Future<void> init() async {
    if (_root != null) return;
    final String path;
    if (rootPath != null) {
      path = rootPath!;
    } else {
      final Directory docs = await getApplicationDocumentsDirectory();
      path = '${docs.path}${Platform.pathSeparator}NRS Notes';
    }
    final Directory dir = Directory(path);
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
  }

  Future<Directory> get _vault async {
    await init();
    return _root!;
  }

  String _separator() => Platform.pathSeparator;

  String _absolute(String relativePath) {
    if (!isSafeCanvasPath(relativePath)) {
      throw ArgumentError.value(relativePath, 'relativePath', '路径不安全');
    }
    final String clean = relativePath.replaceAll('\\', '/');
    return '${_root!.path}${_separator()}${clean.replaceAll('/', _separator())}';
  }

  @override
  Future<List<CanvasRef>> list() async {
    final Directory root = await _vault;
    if (!await root.exists()) return const <CanvasRef>[];
    final List<CanvasRef> out = <CanvasRef>[];
    await for (final FileSystemEntity entity in root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final String relative = entity.path
          .substring(root.path.length)
          .replaceAll('\\', '/')
          .replaceFirst(RegExp(r'^/+'), '');
      if (relative.isEmpty) continue;
      // 隐藏目录里的东西（回收站里的旧白板）不算。
      if (relative.split('/').any((String part) => _skipDirs.contains(part))) {
        continue;
      }
      if (!relative.toLowerCase().endsWith(canvasExtension)) continue;
      DateTime? modified;
      try {
        modified = await entity.lastModified();
      } on FileSystemException {
        modified = null;
      }
      out.add(
        CanvasRef(
          relativePath: relative,
          title: canvasTitleOf(relative),
          modified: modified,
        ),
      );
    }
    out.sort(
      (CanvasRef a, CanvasRef b) =>
          a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()),
    );
    return out;
  }

  @override
  Future<String> read(String relativePath) async {
    await _vault;
    final File file = File(_absolute(relativePath));
    return file.readAsString();
  }

  @override
  Future<void> write(String relativePath, String contents) async {
    await _vault;
    final File file = File(_absolute(relativePath));
    await file.parent.create(recursive: true);
    // 走原子写：白板一次写几 KB 到几百 KB，写一半断电留个坏文件，
    // 下次打开就是「白板打不开了」。
    await _writer.replace(file, contents);
  }

  @override
  Future<String> create(String folderPath, {String? title}) async {
    await _vault;
    final String folder = folderPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final String base = canvasFileName(title);
    for (int n = 1; n < 1000; n++) {
      final String name = n == 1 ? base : '$base $n';
      final String relative = folder.isEmpty
          ? '$name$canvasExtension'
          : '$folder/$name$canvasExtension';
      final File file = File(_absolute(relative));
      if (await file.exists()) continue;
      await file.parent.create(recursive: true);
      await file.writeAsString(
        encodeCanvas(CanvasDocument(nodes: <CanvasNode>[], edges: <CanvasEdge>[])),
        flush: true,
      );
      return relative;
    }
    throw CanvasPathTaken('$base$canvasExtension');
  }

  @override
  Future<TrashEntry?> delete(String relativePath) async {
    final Directory root = await _vault;
    final File file = File(_absolute(relativePath));
    if (!await file.exists()) return null;
    // 和笔记共用一个回收站：用户点一次「回收站」就该看到所有删掉的东西，
    // 而不是按文件类型分成两处。
    return TrashStore(root).move(file, relativePath);
  }

  @override
  Future<bool> restoreTrash(String entryId) async {
    final Directory root = await _vault;
    final TrashStore trash = TrashStore(root);
    final TrashRecord? record = await trash.read(entryId);
    if (record == null) return false;
    final String original = record.entry.originalPath;
    if (!isSafeCanvasPath(original)) return false;
    try {
      await write(await _freePath(original), record.markdown);
    } catch (_) {
      // 写不回去就把条目留在回收站：宁可多一条，不能两边都没有。
      return false;
    }
    await trash.purge(entryId);
    return true;
  }

  /// 恢复时的落点：原路径还空着就原位回去，被占了就退到 ` 2`、` 3`。
  ///
  /// 不覆盖是硬要求——用户可能是「删了旧白板、又新建了一块同名的」，
  /// 恢复时把新的顶掉，等于删了两次。
  Future<String> _freePath(String originalPath) async {
    final String clean = originalPath
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/+'), '');
    final int slash = clean.lastIndexOf('/');
    final String folder = slash < 0 ? '' : clean.substring(0, slash);
    final String name = slash < 0 ? clean : clean.substring(slash + 1);
    final String base = name.toLowerCase().endsWith(canvasExtension)
        ? name.substring(0, name.length - canvasExtension.length)
        : name;
    for (int n = 1; n < 1000; n++) {
      final String candidate = n == 1
          ? '$base$canvasExtension'
          : '$base $n$canvasExtension';
      final String relative = folder.isEmpty
          ? candidate
          : '$folder/$candidate';
      if (!await File(_absolute(relative)).exists()) return relative;
    }
    throw CanvasPathTaken('$base$canvasExtension');
  }
}

/// 工厂：桌面端有文件系统，直接用它。
CanvasStore createCanvasStore({String? vaultPath}) =>
    IoCanvasStore(rootPath: vaultPath);
