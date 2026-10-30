import 'package:flutter/foundation.dart';

import '../../core/app_enums.dart';
import 'pane_doc.dart';

/// 拖起来的那一页。
///
/// 两种落点完全不同：文档 tab 只能落进**编辑区**的格子；两侧边栏共用同一种
/// 视图页，既能落在左栏，也能落在右栏——用户原话：「这两个侧边栏之间是互通
/// 的」。所以载荷分两支，落点用类型筛。
@immutable
sealed class TabDrag {
  const TabDrag({required this.label});

  /// 跟着指针飞的那个小标签上写的字。拖的时候还看不出落点，得让人知道
  /// 手上拎的是什么。
  final String label;
}

/// 一份文档：笔记 / 图谱 / 白板 / 图片。落进编辑区。
final class DocDrag extends TabDrag {
  const DocDrag(this.doc, {required super.label, this.fromPane});

  final PaneDoc doc;

  /// 从哪一格的标签条上拎起来的，`null` = 不是从格子里来的。
  ///
  /// 拖到别的格子里是**搬家**不是复印：落下去之后要在原来那一格把这一页
  /// 关掉，否则同一篇笔记会同时开着两份，白板那张更会撞 `GlobalKey`。
  final String? fromPane;
}

/// 两侧边栏的一页（文件 / 搜索 / 标签 / 大纲 / 表格 / 图片）。
///
/// 左右两栏都能收，也都能发：一页从左栏拖到右栏、或者反过来，都是**搬家**
/// ——先从原来那格摘掉，再落进目标格。载荷里必须带上来源那一栏
/// （[fromColumn]），因为同一页可能正住在对面。
final class SidePageDrag extends TabDrag {
  const SidePageDrag(
    this.page, {
    required super.label,
    required this.fromColumn,
    this.fromPane,
  });

  final SidePage page;

  /// 从哪一栏拎起来的。页面自己分不出这个：文件也可能已经搬到右栏了。
  final SideColumn fromColumn;

  /// 从哪一格的标签条上拎起来的。
  final String? fromPane;
}

/// 两侧边栏。分割树是两棵，但页是同一套。
enum SideColumn {
  left,
  right;

  bool get isLeft => this == SideColumn.left;
}

/// 落点是格子的哪一块。
///
/// 中间 = 换掉这一格的内容；四条边 = 在这一侧切出新的一格。
enum DropZone {
  center,
  left,
  right,
  top,
  bottom;

  bool get isEdge => this != DropZone.center;

  /// 上 / 左 = 新格在前。
  bool get before => this == DropZone.left || this == DropZone.top;

  /// 侧边栏只能上下切：它本来就只有 288 宽，左右切出来两格都没法用。
  /// 所以左 / 右也当成上 / 下。
  DropZone get verticalized => switch (this) {
    DropZone.left => DropZone.top,
    DropZone.right => DropZone.bottom,
    _ => this,
  };
}
