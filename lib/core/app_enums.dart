import 'package:flutter/material.dart';

enum ThemePreference {
  system('跟随系统', Icons.brightness_auto_outlined),
  light('浅色', Icons.light_mode_outlined),
  dark('深色', Icons.dark_mode_outlined);

  const ThemePreference(this.label, this.icon);
  final String label;
  final IconData icon;

  ThemeMode get mode => switch (this) {
    ThemePreference.system => ThemeMode.system,
    ThemePreference.light => ThemeMode.light,
    ThemePreference.dark => ThemeMode.dark,
  };
}

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
  files('文件', Icons.folder_outlined),
  search('搜索', Icons.search_rounded),
  tags('标签', Icons.sell_outlined);

  const SidebarView(this.label, this.icon);
  final String label;
  final IconData icon;
}
