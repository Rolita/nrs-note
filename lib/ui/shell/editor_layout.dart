import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'pane_doc.dart';
import 'split_tree.dart';
import 'tab_group.dart';

/// 编辑区的完整布局：怎么分的 + 每格排着哪些页 + 哪一格是「活的那格」。
///
/// 侧边栏那两棵树一直落盘（`side_layout.dart`），编辑区这棵没有——用户分好的
/// 屏，重启就回到一格（用户原话：「我一重启之前分割的编辑栏全没了」）。这里
/// 补上同一套编解码：树本身是纯内存的不可变结构，只把形状写进偏好的一小段
/// JSON。
@immutable
class EditorLayout {
  const EditorLayout({
    required this.root,
    required this.focusId,
    required this.liveNoteId,
  });

  final SplitNode<TabGroup<PaneDoc>> root;

  /// 聚焦那一格。只有它能写、它才排着「活的那一页」。
  final String focusId;

  /// 「活的那一页」此刻显示的是哪一篇。
  ///
  /// 那一页跟着全局选中走、自己没有 id（`NoteDoc(null)`），不单独记一笔的话
  /// 还原时不知道该把它钉回哪篇。
  final String? liveNoteId;
}

/// 编辑区出生时的样子：一格一页，空着等选中。
EditorLayout defaultEditorLayout() => const EditorLayout(
  root: SplitLeaf<TabGroup<PaneDoc>>(
    id: 'editor-0',
    value: TabGroup<PaneDoc>(<PaneDoc>[NoteDoc(null)], 0),
  ),
  focusId: 'editor-0',
  liveNoteId: null,
);

/// 写成偏好里那一小段 JSON。
String encodeEditorLayout(EditorLayout layout) {
  return jsonEncode(<String, Object?>{
    'v': 1,
    'focus': layout.focusId,
    if (layout.liveNoteId != null) 'live': layout.liveNoteId,
    'root': _encodeNode(layout.root),
  });
}

/// 读回来。坏掉的存档（手改、旧版本、半截写入）一律返回 `null`，调用方退回
/// 默认布局——布局是视图状态，宁可回到一格也不能开不了窗。
EditorLayout? decodeEditorLayout(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final Object? data = jsonDecode(raw);
    if (data is! Map<String, dynamic> || data['v'] != 1) return null;
    final Object? liveRaw = data['live'];
    final String? live = liveRaw is String && liveRaw.isNotEmpty
        ? liveRaw
        : null;
    final SplitNode<TabGroup<PaneDoc>>? root = _decodeNode(data['root'], live);
    if (root == null) return null;
    final String? focus = data['focus'] is String
        ? data['focus'] as String
        : null;
    final String focusId =
        focus != null &&
            SplitTree.findLeaf<TabGroup<PaneDoc>>(root, focus) != null
        ? focus
        : SplitTree.firstLeaf<TabGroup<PaneDoc>>(root).id;
    return EditorLayout(root: root, focusId: focusId, liveNoteId: live);
  } catch (_) {
    return null;
  }
}

/// 把存档里**已经不存在的东西**摘掉。
///
/// 笔记可能被删了、白板这次没开、图片页没有图——留着就是一片空白页。摘空的
/// 格子连同它的分割线一起收掉；全摘空了返回 `null`，调用方退回默认布局。
///
/// [noteExists] 问的是「这篇还在不在 vault 里」，[singletons] 是这次**可以**
/// 出现的那几种单例文档（`graph` / `canvas` / `image`）——每种最多一份，多出来
/// 的（存档被改过）只留第一份。
SplitNode<TabGroup<PaneDoc>>? pruneEditorTree(
  SplitNode<TabGroup<PaneDoc>> root, {
  required bool Function(String noteId) noteExists,
  required Set<String> singletons,
}) {
  final Set<String> usedSingletons = <String>{};

  SplitNode<TabGroup<PaneDoc>>? walk(SplitNode<TabGroup<PaneDoc>> node) {
    switch (node) {
      case SplitLeaf<TabGroup<PaneDoc>> leaf:
        final List<PaneDoc> tabs = <PaneDoc>[];
        for (final PaneDoc doc in leaf.value.tabs) {
          if (doc is NoteDoc) {
            final String? id = doc.noteId;
            // 「活的那一页」留着（它可能是空状态），钉住的笔记要查一遍。
            if (id != null && !noteExists(id)) continue;
            if (!tabs.contains(doc)) tabs.add(doc);
          } else {
            // 设置 / 模板 / 回收站不依赖任何外部状态（不像白板要有文件、图片
            // 要有图），所以它们永远认，不进 [singletons] 那张白名单。
            if (doc is! SettingsDoc &&
                doc is! TemplatesDoc &&
                doc is! TrashDoc &&
                !singletons.contains(doc.identity)) {
              continue;
            }
            if (!usedSingletons.add(doc.identity)) continue;
            tabs.add(doc);
          }
        }
        if (tabs.isEmpty) return null;
        // 当前那一页还在就还停在它上面，被摘掉了才退到最近的合法下标。
        final int kept = tabs.indexOf(leaf.value.current);
        final int index = kept >= 0
            ? kept
            : leaf.value.index.clamp(0, tabs.length - 1);
        return SplitLeaf<TabGroup<PaneDoc>>(
          id: leaf.id,
          value: TabGroup<PaneDoc>(tabs, index),
        );
      case SplitBranch<TabGroup<PaneDoc>> branch:
        final SplitNode<TabGroup<PaneDoc>>? first = walk(branch.first);
        final SplitNode<TabGroup<PaneDoc>>? second = walk(branch.second);
        if (first == null) return second;
        if (second == null) return first;
        return SplitBranch<TabGroup<PaneDoc>>(
          id: branch.id,
          axis: branch.axis,
          ratio: branch.ratio,
          first: first,
          second: second,
        );
    }
  }

  return walk(root);
}

/// 树里出现过的最大格子序号。
///
/// 新格子的 id 用 `editor-序号` 递增；从存档恢复之后接着往下数，才不会撞上
/// 已经存在的格子（`split_tree` 按下标认人，撞了 id 会改错格）。
int nextEditorSeq(SplitNode<TabGroup<PaneDoc>> root) {
  int max = 0;
  void hit(String id) {
    final int dash = id.lastIndexOf('-');
    if (dash < 0 || dash == id.length - 1) return;
    final int? n = int.tryParse(id.substring(dash + 1));
    if (n != null && n > max) max = n;
  }

  void walk(SplitNode<TabGroup<PaneDoc>> node) {
    switch (node) {
      case SplitLeaf<TabGroup<PaneDoc>> leaf:
        hit(leaf.id);
      case SplitBranch<TabGroup<PaneDoc>> branch:
        hit(branch.id);
        walk(branch.first);
        walk(branch.second);
    }
  }

  walk(root);
  return max;
}

/// 树上所有笔记页的 id，按屏幕顺序——用来对齐 `NotesController` 的标签栏。
List<String> noteIdsIn(SplitNode<TabGroup<PaneDoc>> root) {
  final List<String> ids = <String>[];
  for (final SplitLeaf<TabGroup<PaneDoc>> leaf
      in SplitTree.leaves<TabGroup<PaneDoc>>(root)) {
    for (final PaneDoc doc in leaf.value.tabs) {
      if (doc is NoteDoc && doc.noteId != null && !ids.contains(doc.noteId)) {
        ids.add(doc.noteId!);
      }
    }
  }
  return ids;
}

/// 这份存档里，有没有哪一格**正显示着** [identity] 那份单例文档。
///
/// 图谱首屏不建（一次收敛几十毫秒），所以只在它当时就在屏幕上时才认这份存档
/// ——停在别的格子标签上、没切到前面的一页，重启后不值得为它先建一遍图。
bool hasCurrentDoc(SplitNode<TabGroup<PaneDoc>> root, String identity) {
  return SplitTree.leaves<TabGroup<PaneDoc>>(root).any(
    (SplitLeaf<TabGroup<PaneDoc>> leaf) =>
        leaf.value.current.identity == identity,
  );
}

Map<String, Object?> _encodeNode(SplitNode<TabGroup<PaneDoc>> node) {
  return switch (node) {
    SplitLeaf<TabGroup<PaneDoc>> leaf => <String, Object?>{
      'id': leaf.id,
      'tabs': <Object?>[
        for (final PaneDoc doc in leaf.value.tabs) _encodeDoc(doc),
      ],
      'index': leaf.value.index,
    },
    SplitBranch<TabGroup<PaneDoc>> branch => <String, Object?>{
      'id': branch.id,
      'axis': branch.axis == Axis.horizontal ? 'h' : 'v',
      'ratio': branch.ratio,
      'first': _encodeNode(branch.first),
      'second': _encodeNode(branch.second),
    },
  };
}

Map<String, Object?> _encodeDoc(PaneDoc doc) => switch (doc) {
  // 「活的那一页」没有 id：还原时按 `live` 那一笔把它钉回去。
  NoteDoc(:final String? noteId) => <String, Object?>{
    't': 'note',
    'id': ?noteId,
  },
  GraphDoc() => <String, Object?>{'t': 'graph'},
  CanvasDoc() => <String, Object?>{'t': 'canvas'},
  ImageDoc() => <String, Object?>{'t': 'image'},
  SettingsDoc() => <String, Object?>{'t': 'settings'},
  TemplatesDoc() => <String, Object?>{'t': 'templates'},
  TrashDoc() => <String, Object?>{'t': 'trash'},
};

SplitNode<TabGroup<PaneDoc>>? _decodeNode(Object? raw, String? live) {
  if (raw is! Map<String, dynamic>) return null;
  final String? id = raw['id'] is String ? raw['id'] as String : null;
  if (id == null) return null;

  // 叶子：一排页。
  if (raw['tabs'] is List) {
    final List<PaneDoc> tabs = <PaneDoc>[];
    for (final Object? item in raw['tabs'] as List<dynamic>) {
      final PaneDoc? doc = _decodeDoc(item, live);
      if (doc != null && !tabs.contains(doc)) tabs.add(doc);
    }
    if (tabs.isEmpty) return null;
    final int index = raw['index'] is num
        ? (raw['index'] as num).toInt().clamp(0, tabs.length - 1)
        : 0;
    return SplitLeaf<TabGroup<PaneDoc>>(
      id: id,
      value: TabGroup<PaneDoc>(tabs, index),
    );
  }

  // 分支：两棵子树 + 一条线。
  if (raw['axis'] is String) {
    final SplitNode<TabGroup<PaneDoc>>? first = _decodeNode(raw['first'], live);
    final SplitNode<TabGroup<PaneDoc>>? second = _decodeNode(
      raw['second'],
      live,
    );
    if (first == null) return second;
    if (second == null) return first;
    final double ratio = raw['ratio'] is num
        ? (raw['ratio'] as num).toDouble().clamp(
            SplitLimits.min,
            SplitLimits.max,
          )
        : 0.5;
    return SplitBranch<TabGroup<PaneDoc>>(
      id: id,
      axis: raw['axis'] == 'h' ? Axis.horizontal : Axis.vertical,
      ratio: ratio,
      first: first,
      second: second,
    );
  }
  return null;
}

PaneDoc? _decodeDoc(Object? raw, String? live) {
  if (raw is! Map<String, dynamic>) return null;
  switch (raw['t']) {
    case 'note':
      final Object? id = raw['id'];
      if (id is String && id.isNotEmpty) return NoteDoc(id);
      // 没有 id 的那一页就是「活的那一页」：钉回它上次显示的那一篇。
      return NoteDoc(live);
    case 'graph':
      return const GraphDoc();
    case 'canvas':
      return const CanvasDoc();
    case 'image':
      return const ImageDoc();
    case 'settings':
      return const SettingsDoc();
    case 'templates':
      return const TemplatesDoc();
    case 'trash':
      return const TrashDoc();
  }
  return null;
}
