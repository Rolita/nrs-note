import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';

/// Preferences, vault status and a keyboard reference in one dialog.
Future<void> showSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0x44000000),
    builder: (BuildContext context) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog();

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final SettingsController settings = context.watch<SettingsController>();
    final NotesController notes = context.watch<NotesController>();

    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xl,
                AppSpace.lg,
                AppSpace.md,
                AppSpace.sm,
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    '设置',
                    style: TextStyle(
                      fontSize: AppText.display,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: p.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  AppIconButton(
                    icon: Icons.close,
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.outlineSoft),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  AppSpace.md,
                  AppSpace.xl,
                  AppSpace.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _Group(
                      title: '外观',
                      children: <Widget>[
                        _Row(
                          label: '主题',
                          hint: '跟随系统会随 Windows 的浅色/深色模式切换',
                          control: SegmentedToggle<ThemePreference>(
                            value: settings.theme,
                            onChanged: (ThemePreference v) => settings.theme = v,
                            items: <({ThemePreference value, IconData icon, String label})>[
                              for (final ThemePreference t in ThemePreference.values)
                                (value: t, icon: t.icon, label: t.label),
                            ],
                          ),
                        ),
                        _Row(
                          label: '侧边栏',
                          hint: 'Ctrl + \\',
                          control: _Switch(
                            value: !settings.sidebarCollapsed,
                            label: settings.sidebarCollapsed ? '已收起' : '已展开',
                            onChanged: (bool v) =>
                                settings.sidebarCollapsed = !v,
                          ),
                        ),
                      ],
                    ),
                    _Group(
                      title: '排版',
                      children: <Widget>[
                        _SliderRow(
                          label: '正文字号',
                          value: settings.proseSize,
                          min: 13,
                          max: 22,
                          divisions: 18,
                          suffix: 'pt',
                          onChanged: (double v) => settings.proseSize = v,
                        ),
                        _SliderRow(
                          label: '侧边栏宽度',
                          value: settings.listWidth,
                          min: AppLayout.listMinWidth,
                          max: AppLayout.listMaxWidth,
                          divisions: 28,
                          suffix: 'px',
                          onChanged: (double v) => settings.listWidth = v,
                        ),
                      ],
                    ),
                    _Group(
                      title: '编辑器',
                      children: <Widget>[
                        _Row(
                          label: '显示大纲',
                          hint: 'Ctrl + Shift + O',
                          control: _Switch(
                            value: settings.outlineVisible,
                            label: settings.outlineVisible ? '开' : '关',
                            onChanged: (bool v) => settings.outlineVisible = v,
                          ),
                        ),
                        _Row(
                          label: '专注模式',
                          hint: '隐藏功能栏、侧边栏与大纲,只留下文字',
                          control: _Switch(
                            value: settings.focusMode,
                            label: settings.focusMode ? '开' : '关',
                            onChanged: (bool v) => settings.focusMode = v,
                          ),
                        ),
                        _Row(
                          label: '打字机模式',
                          hint: '光标始终停在屏幕中间',
                          control: _Switch(
                            value: settings.typewriter,
                            label: settings.typewriter ? '开' : '关',
                            onChanged: (bool v) => settings.typewriter = v,
                          ),
                        ),
                        _Row(
                          label: '默认排序',
                          hint: '文件列表与搜索结果都按它排列',
                          control: _Dropdown<SortMode>(
                            value: settings.sort,
                            items: <SortMode, String>{
                              for (final SortMode m in SortMode.values) m: m.label,
                            },
                            onChanged: (SortMode v) {
                              settings.sort = v;
                              notes.sortMode = v;
                            },
                          ),
                        ),
                      ],
                    ),
                    _Group(
                      title: '笔记库',
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.all(AppSpace.md),
                          decoration: BoxDecoration(
                            color: p.surfaceSunken,
                            borderRadius: AppRadius.mdAll,
                            border: Border.all(color: p.outlineSoft),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Icon(
                                    notes.supportsNativeFiles
                                        ? Icons.folder_outlined
                                        : Icons.cloud_outlined,
                                    size: 15,
                                    color: p.textTertiary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: SelectableText(
                                      notes.vaultLocation,
                                      maxLines: 2,
                                      style: TextStyle(
                                        fontSize: AppText.mono,
                                        height: 1.5,
                                        fontFamily: AppFonts.mono,
                                        fontFamilyFallback:
                                            AppFonts.monoFallback,
                                        color: p.textSecondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppSpace.md),
                              Row(
                                children: <Widget>[
                                  Text(
                                    '${notes.allNotes.length} 篇笔记 · '
                                    '${notes.totalWords} 字 · '
                                    '${notes.tags.length} 个标签',
                                    style: TextStyle(
                                      fontSize: AppText.caption,
                                      color: p.textTertiary,
                                    ),
                                  ),
                                  const Spacer(),
                                  if (notes.supportsNativeFiles)
                                    AppTextButton(
                                      label: '打开文件夹',
                                      icon: Icons.open_in_new_outlined,
                                      onPressed: notes.revealVault,
                                    ),
                                  AppTextButton(
                                    label: '重新载入',
                                    icon: Icons.refresh_outlined,
                                    onPressed: () => notes.refresh(),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.sm, left: 2),
                          child: Text(
                            notes.supportsNativeFiles
                                ? '每篇笔记都是一个独立的 .md 文件,可以用任何编辑器打开、同步或备份。'
                                : '当前运行在浏览器中,笔记保存在 localStorage 里。用桌面版运行即可获得真正的 .md 文件。',
                            style: TextStyle(
                              fontSize: AppText.caption,
                              height: 1.6,
                              color: p.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    _Group(
                      title: '快捷键',
                      children: <Widget>[
                        _ShortcutTable(
                          rows: const <(String, String)>[
                            ('Ctrl + N', '新建笔记'),
                            ('Ctrl + P', '快速打开 / 命令面板'),
                            ('Ctrl + S', '立即保存'),
                            ('Ctrl + K', '插入链接'),
                            ('Ctrl + B / I', '加粗 / 斜体'),
                            ('Ctrl + E', '行内代码'),
                            ('Ctrl + Shift + E', '代码块'),
                            ('Ctrl + 1…3 / 0', '标题级别 / 正文'),
                            ('Ctrl + Alt + ↑ ↓', '上一篇 / 下一篇'),
                            ('Ctrl + \\\\', '收起或展开侧边栏'),
                            ('Ctrl + Shift + O', '显示 / 隐藏大纲'),
                            ('Ctrl + Shift + F', '专注模式'),
                            ('Ctrl + ,', '打开设置'),
                          ],
                        ),
                      ],
                    ),
                    _Group(
                      title: '关于',
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: p.accentSoft,
                                borderRadius: AppRadius.mdAll,
                                border: Border.all(color: p.outline),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                'N',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: p.accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpace.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'NRS · Markdown 笔记',
                                    style: TextStyle(
                                      fontSize: AppText.ui,
                                      fontWeight: FontWeight.w600,
                                      color: p.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '版本 1.0.0 · Flutter 桌面应用 · 本地优先,数据完全属于你',
                                    style: TextStyle(
                                      fontSize: AppText.caption,
                                      color: p.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xs),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: AppText.label,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: p.textTertiary,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: AppRadius.mdAll,
              border: Border.all(color: p.outlineSoft),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: AppSpace.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.control, this.hint});

  final String label;
  final String? hint;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppText.ui,
                    fontWeight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
                if (hint != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    hint!,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      height: 1.45,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpace.lg),
          control,
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.suffix,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppText.ui,
                fontWeight: FontWeight.w500,
                color: p.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${value.toStringAsFixed(0)} $suffix',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: AppText.mono,
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                color: p.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Row(
      children: <Widget>[
        Text(
          label,
          style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
        ),
        const SizedBox(width: AppSpace.sm),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: AppLayout.fieldHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outline),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          borderRadius: AppRadius.mdAll,
          dropdownColor: p.surfaceRaised,
          icon: Icon(
            Icons.expand_more,
            size: 16,
            color: p.textTertiary,
          ),
          style: TextStyle(fontSize: AppText.ui, color: p.textPrimary),
          onChanged: (T? v) {
            if (v != null) onChanged(v);
          },
          items: items.entries
              .map(
                (MapEntry<T, String> e) => DropdownMenuItem<T>(
                  value: e.key,
                  child: Text(e.value),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _ShortcutTable extends StatelessWidget {
  const _ShortcutTable({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Column(
      children: <Widget>[
        for (final (String keys, String label) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Container(
                  constraints: const BoxConstraints(minWidth: 132),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: p.surfaceSunken,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                    border: Border.all(color: p.outlineSoft),
                  ),
                  child: Text(
                    keys,
                    style: TextStyle(
                      fontSize: AppText.mono,
                      fontWeight: FontWeight.w600,
                      fontFamily: AppFonts.mono,
                      fontFamilyFallback: AppFonts.monoFallback,
                      color: p.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Text(
                  label,
                  style: TextStyle(fontSize: AppText.label, color: p.textSecondary),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
