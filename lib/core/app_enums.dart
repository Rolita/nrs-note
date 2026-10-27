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

/// Which pane the left sidebar is showing.
enum SidebarView {
  files('文件', LucideIcons.folder),
  search('搜索', LucideIcons.search),
  tags('标签', LucideIcons.tag);

  const SidebarView(this.label, this.icon);
  final String label;
  final IconData icon;
}
