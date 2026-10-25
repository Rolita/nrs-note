/// 白板的撤销栈。
///
/// 存的是**整份文档的字符串快照**，不是「加了一张卡片」这种操作记录。
/// 理由：
///
/// * 白板的修改动作又多又碎（移动、缩放、换色、连线、改标签、拖分组连带
///   一串卡片），每种都写一个反向操作，写漏一个就是「撤销之后图坏了」。
/// * 一份白板撑死几十上百张卡片，`encodeCanvas` 一次几毫秒，比人工维护
///   几十种逆操作便宜。
/// * 快照天生和「兼容 JSON Canvas、未知字段原样保留」这条要求对齐：
///   撤销回去的东西和存到磁盘的东西是同一个序列化器出的。
///
/// 上限 50 步：再多也没人按那么多次，而且每步都占一份完整文档的内存。
library;

import 'dart:collection';

class CanvasHistory {
  CanvasHistory({this.limit = 50});

  /// 最多记多少步。
  final int limit;

  final List<String> _undo = <String>[];
  final List<String> _redo = <String>[];

  bool get canUndo => _undo.isNotEmpty;

  bool get canRedo => _redo.isNotEmpty;

  /// 撤销栈的深度（测试用）。
  int get undoDepth => _undo.length;

  int get redoDepth => _redo.length;

  /// 记一步。**改动之前**调用，传的是改动前的样子。
  ///
  /// 一旦有新动作，重做栈就作废——这是所有编辑器的规矩：从历史中间改一笔，
  /// 原来的「未来」就不成立了。
  void push(String snapshot) {
    _undo.add(snapshot);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
  }

  /// 退一步。返回要恢复成什么样；没得退就返回 null。
  ///
  /// [current] 是现在这个样子，它会被压进重做栈。
  String? undo(String current) {
    if (_undo.isEmpty) return null;
    _redo.add(current);
    return _undo.removeLast();
  }

  /// 进一步。语义和 [undo] 对称。
  String? redo(String current) {
    if (_redo.isEmpty) return null;
    _undo.add(current);
    return _redo.removeLast();
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }

  /// 只读视图，给调试和测试看。
  List<String> get undoSnapshots => UnmodifiableListView<String>(_undo);
}
