/// localStorage 的一次落盘计划。
///
/// 从 `WebNoteStore` 里拆出来只为能测试：`package:web` 在 Dart VM 上无法
/// 导入，而「先写变化项、全部写成功后再删过期项」恰恰是配额异常时保住旧库
/// 的关键顺序，需要能在测试里用会抛错的假存储验证。
library;

/// 只读的键值写入接口；`WebNoteStore` 用 localStorage 实现，测试用内存实现。
abstract interface class WebKeyValue {
  void setItem(String key, String value);

  void removeItem(String key);
}

/// [persisted] 是上次成功写入的「相对路径 → 正文」，[next] 是当前内存库。
class WebSyncPlan {
  const WebSyncPlan({required this.write, required this.remove});

  /// 需要写入或覆盖的键（相对路径 → 正文）。
  final Map<String, String> write;

  /// 需要删除的过期键（相对路径）。
  final List<String> remove;

  static WebSyncPlan between({
    required Map<String, String> persisted,
    required Map<String, String> next,
  }) {
    final Map<String, String> write = <String, String>{};
    next.forEach((String path, String raw) {
      if (persisted[path] != raw) write[path] = raw;
    });
    final List<String> remove = <String>[
      for (final String path in persisted.keys)
        if (!next.containsKey(path)) path,
    ];
    return WebSyncPlan(write: write, remove: remove);
  }

  /// 按「先写后删」的顺序落盘。
  ///
  /// 写入抛错（多半是配额超限）时直接向上抛：已经写成功的键记进
  /// [persisted]，没轮到写的变化项和过期键都不动，旧值因此仍然可用。
  void apply(
    WebKeyValue kv,
    Map<String, String> persisted, {
    required String prefix,
  }) {
    write.forEach((String path, String raw) {
      kv.setItem('$prefix$path', raw);
      persisted[path] = raw;
    });
    for (final String path in remove) {
      kv.removeItem('$prefix$path');
      persisted.remove(path);
    }
  }
}
