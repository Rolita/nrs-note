import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/utils/canvas_document.dart';
import 'atomic_file.dart';
import 'canvas_store.dart';

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
}

/// 工厂：桌面端有文件系统，直接用它。
CanvasStore createCanvasStore({String? vaultPath}) =>
    IoCanvasStore(rootPath: vaultPath);
