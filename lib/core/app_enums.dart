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

enum SortMode {
  updatedDesc('最近修改'),
  createdDesc('创建时间'),
  titleAsc('标题 A→Z'),
  longestFirst('字数最多');

  const SortMode(this.label);
  final String label;
}

/// Which slice of the vault the list is showing.
enum NoteScope {
  all('全部笔记', Icons.folder_outlined),
  pinned('置顶', Icons.push_pin_outlined),
  favorites('收藏', Icons.star_outline_rounded),
  tasks('含待办', Icons.check_box_outlined),
  untagged('未加标签', Icons.label_off_outlined);

  const NoteScope(this.label, this.icon);
  final String label;
  final IconData icon;
}
