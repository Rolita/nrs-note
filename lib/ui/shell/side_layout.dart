import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../core/app_enums.dart';
import 'split_tree.dart';
import 'tab_group.dart';

/// 一侧边栏的完整布局：怎么分的 + 每格排着哪些页。
///
/// 分割树本身是纯内存的不可变结构，这里只负责把它写成偏好里的一小段 JSON。
/// 左栏和右栏各存一条——用户把文件拖到右栏、把大纲拖到左栏之后，下次启动
/// 还得是那个样子。
@immutable
class SideLayout {
  const SideLayout({required this.root, required this.focusId});

  final SplitNode<TabGroup<SidePage>> root;

  /// 左栏「聚焦那一格」的 id。右栏没有聚焦的概念，存第一个叶子就行。
  final String focusId;
}

/// 左栏出生时的样子：文件 / 搜索 / 标签一排三页。
///
/// 标签原来住在功能栏上，用户要求「把标签按钮也移到侧边栏按钮上」之后，
/// 它和文件 / 搜索一样是常驻的一页。
SideLayout defaultLeftSideLayout() {
  const TabGroup<SidePage> group = TabGroup<SidePage>(
    <SidePage>[SidePage.files, SidePage.search, SidePage.tags],
    0,
  );
  return const SideLayout(
    root: SplitLeaf<TabGroup<SidePage>>(id: 'side-0', value: group),
    focusId: 'side-0',
  );
}

/// 右栏出生时的样子：大纲 / 表格 / 图片一排三页。
SideLayout defaultRightSideLayout() {
  const TabGroup<SidePage> group = TabGroup<SidePage>(
    <SidePage>[SidePage.outline, SidePage.table, SidePage.images],
    0,
  );
  return const SideLayout(
    root: SplitLeaf<TabGroup<SidePage>>(id: 'right-0', value: group),
    focusId: 'right-0',
  );
}

/// 写成偏好里那一小段 JSON。
///
/// 页用枚举的 `name` 记，分割线记轴和比例。树很小（一层最多几格），每次
/// 改布局重写一整段也就几百字节。
String encodeSideLayout(SideLayout layout) {
  return jsonEncode(<String, Object?>{
    'v': 1,
    'focus': layout.focusId,
    'root': _encodeNode(layout.root),
  });
}

/// 读回来。坏掉的存档（手改、旧版本、半截写入）一律返回 `null`，调用方
/// 退回默认布局——布局是视图状态，宁可回到默认也不能开不了窗。
SideLayout? decodeSideLayout(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final Object? data = jsonDecode(raw);
    if (data is! Map<String, dynamic> || data['v'] != 1) return null;
    final SplitNode<TabGroup<SidePage>>? root = _decodeNode(data['root']);
    if (root == null) return null;
    final String? focus = data['focus'] is String
        ? data['focus'] as String
        : null;
    final String focusId = focus != null &&
            SplitTree.findLeaf<TabGroup<SidePage>>(root, focus) != null
        ? focus
        : SplitTree.firstLeaf<TabGroup<SidePage>>(root).id;
    return SideLayout(root: root, focusId: focusId);
  } catch (_) {
    return null;
  }
}

/// 这棵树里出现过的最大的 id 序号。
///
/// 新格子的 id 用 `前缀-序号` 递增；从存档恢复之后接着往下数，才不会撞上
/// 已经存在的格子。`split_tree` 按下标认人，撞了 id 会改错格。
int nextSideSeq(SplitNode<TabGroup<SidePage>> root) {
  int max = 0;
  void hit(String id) {
    final int dash = id.lastIndexOf('-');
    if (dash < 0 || dash == id.length - 1) return;
    final int? n = int.tryParse(id.substring(dash + 1));
    if (n != null && n > max) max = n;
  }

  void walk(SplitNode<TabGroup<SidePage>> node) {
    switch (node) {
      case SplitLeaf<TabGroup<SidePage>> leaf:
        hit(leaf.id);
      case SplitBranch<TabGroup<SidePage>> branch:
        hit(branch.id);
        walk(branch.first);
        walk(branch.second);
    }
  }

  walk(root);
  return max;
}

Map<String, Object?> _encodeNode(SplitNode<TabGroup<SidePage>> node) {
  return switch (node) {
    SplitLeaf<TabGroup<SidePage>> leaf => <String, Object?>{
      'id': leaf.id,
      'tabs': <String>[for (final SidePage page in leaf.value.tabs) page.name],
      'index': leaf.value.index,
    },
    SplitBranch<TabGroup<SidePage>> branch => <String, Object?>{
      'id': branch.id,
      'axis': branch.axis == Axis.horizontal ? 'h' : 'v',
      'ratio': branch.ratio,
      'first': _encodeNode(branch.first),
      'second': _encodeNode(branch.second),
    },
  };
}

SplitNode<TabGroup<SidePage>>? _decodeNode(Object? raw) {
  if (raw is! Map<String, dynamic>) return null;
  final String? id = raw['id'] is String ? raw['id'] as String : null;
  if (id == null) return null;

  // 叶子：一排页。
  if (raw['tabs'] is List) {
    final List<SidePage> tabs = <SidePage>[];
    for (final Object? name in raw['tabs'] as List<dynamic>) {
      if (name is! String) continue;
      final SidePage? page = SidePage.fromName(name);
      if (page != null && !tabs.contains(page)) tabs.add(page);
    }
    if (tabs.isEmpty) return null;
    final int index = raw['index'] is num
        ? (raw['index'] as num).toInt().clamp(0, tabs.length - 1)
        : 0;
    return SplitLeaf<TabGroup<SidePage>>(
      id: id,
      value: TabGroup<SidePage>(tabs, index),
    );
  }

  // 分支：两棵子树 + 一条线。
  if (raw['axis'] is String) {
    final SplitNode<TabGroup<SidePage>>? first = _decodeNode(raw['first']);
    final SplitNode<TabGroup<SidePage>>? second = _decodeNode(raw['second']);
    if (first == null) return second;
    if (second == null) return first;
    final double ratio = raw['ratio'] is num
        ? (raw['ratio'] as num)
              .toDouble()
              .clamp(SplitLimits.min, SplitLimits.max)
        : 0.5;
    return SplitBranch<TabGroup<SidePage>>(
      id: id,
      axis: raw['axis'] == 'h' ? Axis.horizontal : Axis.vertical,
      ratio: ratio,
      first: first,
      second: second,
    );
  }
  return null;
}
