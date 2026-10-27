import 'dart:convert';

import 'package:web/web.dart' as web;

import '../../core/utils/canvas_document.dart';
import 'canvas_store.dart';
import 'note_store.dart' show TrashEntry;

/// 浏览器端：白板存在 `localStorage` 里，和笔记一个路子。
///
/// 桌面版才是长期放白板的地方；浏览器版存在的意义是「界面能预览、能分享」，
/// 所以这里只保证「刷新之后东西还在」，不做版本历史、不做原子写。
class WebCanvasStore implements CanvasStore {
  static const String _prefix = 'nrs/v1/canvas/';

  final Map<String, String> _cache = <String, String>{};
  bool _ready = false;

  @override
  String get location => '浏览器本地存储 (localStorage)';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    final int length = web.window.localStorage.length;
    for (int i = 0; i < length; i++) {
      final String? key = web.window.localStorage.key(i);
      if (key == null || !key.startsWith(_prefix)) continue;
      final String? value = web.window.localStorage.getItem(key);
      if (value != null) _cache[key.substring(_prefix.length)] = value;
    }
  }

  @override
  Future<List<CanvasRef>> list() async {
    await init();
    final List<CanvasRef> out = <CanvasRef>[
      for (final String path in _cache.keys)
        CanvasRef(relativePath: path, title: canvasTitleOf(path)),
    ]..sort(
      (CanvasRef a, CanvasRef b) =>
          a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase()),
    );
    return out;
  }

  @override
  Future<String> read(String relativePath) async {
    await init();
    final String? value = _cache[relativePath];
    if (value == null) {
      throw StateError('白板不存在：$relativePath');
    }
    return value;
  }

  @override
  Future<void> write(String relativePath, String contents) async {
    await init();
    _cache[relativePath] = contents;
    web.window.localStorage.setItem('$_prefix$relativePath', contents);
  }

  @override
  Future<String> create(String folderPath, {String? title}) async {
    await init();
    final String folder = folderPath
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    final String base = canvasFileName(title);
    for (int n = 1; n < 1000; n++) {
      final String name = n == 1 ? base : '$base $n';
      final String relative = folder.isEmpty
          ? '$name$canvasExtension'
          : '$folder/$name$canvasExtension';
      if (_cache.containsKey(relative)) continue;
      await write(
        relative,
        encodeCanvas(CanvasDocument(nodes: <CanvasNode>[], edges: <CanvasEdge>[])),
      );
      return relative;
    }
    throw CanvasPathTaken('$base$canvasExtension');
  }

  @override
  Future<TrashEntry?> delete(String relativePath) async {
    await init();
    // 浏览器端没有回收站：删掉就是删掉，返回 null 让上层不要说「已移入
    // 回收站」——那句话在这里是谎话，也没有撤销可做。
    _cache.remove(relativePath);
    web.window.localStorage.removeItem('$_prefix$relativePath');
    return null;
  }

  @override
  Future<bool> restoreTrash(String entryId) async => false;

  /// 调试用：把缓存里的东西打成一段 JSON。
  String debugDump() => jsonEncode(_cache);
}

/// 工厂：浏览器端没有文件系统，走 localStorage。
CanvasStore createCanvasStore({String? vaultPath}) => WebCanvasStore();
