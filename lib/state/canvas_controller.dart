import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/utils/canvas_document.dart';
import '../data/storage/canvas_store_factory.dart';

/// 白板的状态：现在打开的是哪一份、脏没脏、什么时候落盘。
///
/// 为什么不塞进 [NotesController]：白板不参与笔记的任何索引（`allNotes`、
/// 标签、大纲、关系图谱）。混进去之后每个遍历笔记的地方都要先问一句
/// 「这个 id 是不是白板」。
///
/// 自动保存策略：改完 900ms 落盘。拖卡片时会连着改几十次，每次写盘既慢
/// 又没必要；而 900ms 足够短，短到「关掉窗口再打开」不会丢东西——真正的
/// 保底是 `flush()`，关窗前会调它。
class CanvasController extends ChangeNotifier {
  CanvasController({
    CanvasStore? store,
    this.vaultPathOf,
    this.autosaveDelay = const Duration(milliseconds: 900),
  }) {
    _store = store;
  }

  /// 注入用（测试）。为 null 时按平台建一个。
  CanvasStore? _store;

  /// 问外面「vault 在磁盘哪儿」。
  ///
  /// 做成回调而不是构造时传值：控制器在 `main` 里就建好了，而 vault 路径
  /// 要等 `bootstrap()` 读盘完才有。等第一次真正要用存储时再问，答案就是
  /// 对的。
  final String? Function()? vaultPathOf;

  final Duration autosaveDelay;

  CanvasStore get store =>
      _store ??= createCanvasStore(vaultPath: vaultPathOf?.call());

  CanvasDocument? _document;
  String? _path;
  bool _dirty = false;
  String? _error;
  Timer? _timer;

  /// 当前打开的白板。null = 还没打开过。
  CanvasDocument? get document => _document;

  /// 相对 vault 的 `.nrs` 路径。
  String? get path => _path;

  bool get hasDocument => _document != null;

  /// 有还没落盘的改动。
  bool get isDirty => _dirty;

  /// 最近一次失败的原因。读盘/写盘失败时给用户看。
  String? get error => _error;

  String get location => store.location;

  bool get supportsNativeFiles => store.supportsNativeFiles;

  /// 列出 vault 里所有白板。
  Future<List<CanvasRef>> list() async {
    try {
      return await store.list();
    } catch (e) {
      _fail('读取白板列表失败', e);
      return const <CanvasRef>[];
    }
  }

  /// 打开一份白板。
  ///
  /// 读不出来或者 JSON 坏了，**不动当前打开的那份**：把白板清空是最糟的
  /// 处理方式，用户会以为文件被删了。
  Future<bool> open(String relativePath) async {
    await flush();
    try {
      final String text = await store.read(relativePath);
      final CanvasDocument parsed = parseCanvas(text);
      _document = parsed;
      _path = relativePath;
      _dirty = false;
      _error = null;
      notifyListeners();
      return true;
    } on CanvasFormatException catch (e) {
      _fail('这块白板打不开', e.message);
      return false;
    } catch (e) {
      _fail('这块白板打不开', e);
      return false;
    }
  }

  /// 新建一块空白板并打开它。
  Future<bool> createNew(String folderPath, {String? title}) async {
    await flush();
    try {
      final String relative = await store.create(folderPath, title: title);
      _document = CanvasDocument(
        nodes: <CanvasNode>[],
        edges: <CanvasEdge>[],
      );
      _path = relative;
      _dirty = false;
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _fail('新建白板失败', e);
      return false;
    }
  }

  /// 白板被改了。排一次自动保存。
  void markDirty() {
    if (_document == null) return;
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(autosaveDelay, () {
      unawaited(flush());
    });
  }

  /// 立刻落盘。关窗前、切走前调它。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final CanvasDocument? doc = _document;
    final String? path = _path;
    if (!_dirty || doc == null || path == null) return;
    // 先清脏标记再写：写失败会重新置脏，写成功就不用再记一次。
    _dirty = false;
    try {
      await store.write(path, encodeCanvas(doc));
    } catch (e) {
      _dirty = true;
      _fail('保存白板失败', e);
    }
  }

  /// 关掉当前这块（不删文件）。
  Future<void> close() async {
    await flush();
    _document = null;
    _path = null;
    _dirty = false;
    notifyListeners();
  }

  void setError(String? message) {
    if (_error == message) return;
    _error = message;
    notifyListeners();
  }

  void _fail(String what, Object detail) {
    _error = '$what：$detail';
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
