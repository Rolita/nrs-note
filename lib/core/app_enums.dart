import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// File-tree order. Folders always come before files; the mode decides the order
/// inside each folder.
enum SortMode {
  titleAsc('文件名 (A-Z)'),
  titleDesc('文件名 (Z-A)'),
  updatedDesc('编辑时间（从新到旧）'),
  updatedAsc('编辑时间（从旧到新）'),
  createdDesc('创建时间（从新到旧）'),
  createdAsc('创建时间（从旧到新）');

  const SortMode(this.label);
  final String label;
}

/// The two looks the shell can wear.
///
/// [graphite] is the original solid board. [wallpaper] keeps the same board but
/// lays the design mock's aurora image underneath it and lets the big surfaces
/// show that image through — its transparency is a **surface** alpha, not the
/// native window alpha (see `SettingsController.effectiveWindowOpacity`).
///
/// `name` is the stored id: renaming a value is a storage-format change.
enum ShellAppearance {
  graphite('默认'),
  wallpaper('壁纸');

  const ShellAppearance(this.label);
  final String label;
}

/// Which pane the left sidebar is showing.
enum SidebarView {
  files('文件', LucideIcons.folder),
  search('搜索', LucideIcons.search),
  tags('标签', LucideIcons.tag);

  const SidebarView(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 右侧那一栏（大纲 / 表格 / 图片）的一页。
///
/// 三块面板以前是「三选一」，同一列轮流住；现在和左栏一样，是**每个格子自己
/// 的一组页**：每格顶上排一排图标，点谁切谁，拖到格子上 / 下边缘就分出一格。
enum RightView {
  outline('大纲', LucideIcons.listTree),
  table('表格', LucideIcons.table),
  images('图片', LucideIcons.image);

  const RightView(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 两侧边栏共用的一页。
///
/// 左边那栏的文件 / 搜索 / 标签和右边那栏的大纲 / 表格 / 图片本来是两套枚举，
/// 各自长在自己的分割树里。用户要把它们**拖到对面那一栏**，于是两棵树必须装
/// 同一种东西——就是这里。原始的 [SidebarView] / [RightView] 仍是各面板自己的
/// 词（`NoteListPanel` 只认文件 / 搜索 / 标签），这里只负责「一页是谁」。
///
/// 枚举的 `name` 同时也是落盘用的 id，换名字等于换存档格式。
enum SidePage {
  files('文件', LucideIcons.folder),
  search('搜索', LucideIcons.search),
  tags('标签', LucideIcons.tag),
  outline('大纲', LucideIcons.listTree),
  table('表格', LucideIcons.table),
  images('图片', LucideIcons.image);

  const SidePage(this.label, this.icon);
  final String label;
  final IconData icon;

  /// 这一页是左栏的哪种视图；不是左栏页时为 `null`。
  SidebarView? get leftView => switch (this) {
    SidePage.files => SidebarView.files,
    SidePage.search => SidebarView.search,
    SidePage.tags => SidebarView.tags,
    _ => null,
  };

  /// 这一页是右栏的哪块面板；不是右栏页时为 `null`。
  RightView? get rightView => switch (this) {
    SidePage.outline => RightView.outline,
    SidePage.table => RightView.table,
    SidePage.images => RightView.images,
    _ => null,
  };

  bool get isLeft => leftView != null;

  /// 从落盘的名字找回来；不认识的（手改坏了、旧版本）当没有。
  static SidePage? fromName(String name) {
    for (final SidePage page in SidePage.values) {
      if (page.name == name) return page;
    }
    return null;
  }

  static SidePage ofLeft(SidebarView view) => switch (view) {
    SidebarView.files => SidePage.files,
    SidebarView.search => SidePage.search,
    SidebarView.tags => SidePage.tags,
  };

  static SidePage ofRight(RightView view) => switch (view) {
    RightView.outline => SidePage.outline,
    RightView.table => SidePage.table,
    RightView.images => SidePage.images,
  };
}
