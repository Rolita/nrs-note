import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../../state/template_settings.dart';
import '../../templates/template_service.dart';
import '../common/app_widgets.dart';
import '../templates/template_hotkeys_dialog.dart';

/// 设置，作为编辑区里的一页。
///
/// 以前是一层 `showDialog`：改字号看不见正文、改侧边栏宽度看不见侧边栏，而且
/// 每次都要「打开 → 找 → 改 → 关」。现在它就是编辑区的一页，和笔记并排开着，
/// 改哪项当场就看得见；改完即写偏好（[SettingsController] 每个 setter 自己落
/// 盘），所以没有「确定 / 取消」，也没有保存按钮。
///
/// ⛔ 不要在这里自己存一份设置值：整页 watch `SettingsController`，和别处
/// （菜单、快捷键、拖分割线）改出来的值必须立刻反映到这一页上。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// The groups the left navigation can jump to.
enum _Section {
  appearance,
  typography,
  editor,
  templates,
  vault,
  shortcuts,
  about,
}

class _SettingsPageState extends State<SettingsPage> {
  final ScrollController _scroll = ScrollController();

  /// One anchor per group: the nav is a table of contents, not a page switch.
  late final Map<_Section, GlobalKey> _anchors = <_Section, GlobalKey>{
    for (final _Section section in _Section.values)
      section: GlobalKey(debugLabel: 'settings-${section.name}'),
  };

  _Section _active = _Section.appearance;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _goTo(_Section section) {
    setState(() => _active = section);
    final BuildContext? anchor = _anchors[section]?.currentContext;
    if (anchor == null) return;
    Scrollable.ensureVisible(
      anchor,
      duration: AppMotion.slow,
      curve: AppMotion.enter,
      alignment: 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final SettingsController settings = context.watch<SettingsController>();
    final NotesController notes = context.watch<NotesController>();

    // 一页，不是一层浮层：没有 Dialog、没有圆角阴影、没有关闭按钮——这一页
    // 的 × 在标签条上，和别的页一样。铺满它那一格。
    return ColoredBox(
      color: p.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _buildNav(p),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(
                22,
                AppSpace.lg,
                22,
                AppSpace.xxl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _section(
                    _Section.appearance,
                    title: '外观',
                    desc:
                        '两块外观共用一块深色石墨：默认是实色界面；'
                        '壁纸把设计稿的极光图垫在下面，大块面层透出一成。',
                    children: <Widget>[
                      _SettingRow(
                        label: '侧边栏',
                        hint: 'Ctrl + \\',
                        control: _Switch(
                          value: !settings.sidebarCollapsed,
                          label: settings.sidebarCollapsed ? '已收起' : '已展开',
                          onChanged: (bool v) => settings.sidebarCollapsed = !v,
                        ),
                      ),
                      _SettingRow(
                        label: '外观',
                        stretch: true,
                        note: settings.appearance == ShellAppearance.wallpaper
                            ? '壁纸压在大块面层下面；文字、图标和 1px 缝线保持实色。'
                            : '实色石墨；窗口不透明度负责透出桌面。',
                        control: _Segmented<ShellAppearance>(
                          value: settings.appearance,
                          keyPrefix: 'appearance',
                          options: const <ShellAppearance, String>{
                            ShellAppearance.graphite: '默认',
                            ShellAppearance.wallpaper: '壁纸',
                          },
                          onChanged: (ShellAppearance v) =>
                              settings.appearance = v,
                        ),
                      ),
                      if (settings.appearance == ShellAppearance.graphite)
                        _SettingRow(
                          label: '窗口不透明度',
                          stretch: true,
                          note:
                              '整扇窗一起透出桌面，文字也会跟着变淡；'
                              '100% 完全不透明，50% 最透。',
                          control: _SliderControl(
                            value: settings.windowOpacity * 100,
                            min: SettingsController.windowOpacityMin * 100,
                            max: SettingsController.windowOpacityMax * 100,
                            // 50%–100% 全程 1% 一档：92%、87% 都停得住，
                            // 不用凑整到 5% 的倍数。
                            divisions: 50,
                            suffix: '%',
                            separator: '',
                            onChanged: (double v) =>
                                settings.windowOpacity = v / 100,
                          ),
                        )
                      else
                        _SettingRow(
                          label: '面层不透明度',
                          stretch: true,
                          note:
                              '界面压在壁纸上的不透明度；'
                              '90% 时壁纸透出一成，100% 完全盖住。',
                          control: _SliderControl(
                            value: settings.surfaceOpacity * 100,
                            min: SettingsController.surfaceOpacityMin * 100,
                            max: SettingsController.surfaceOpacityMax * 100,
                            // 同样 1% 一档。
                            divisions: 50,
                            suffix: '%',
                            separator: '',
                            onChanged: (double v) =>
                                settings.surfaceOpacity = v / 100,
                          ),
                        ),
                    ],
                  ),
                  _section(
                    _Section.typography,
                    title: '排版',
                    desc:
                        '只影响阅读区域。拖动侧边栏与编辑栏的交界，'
                        '这里的宽度数值也会跟着变。',
                    children: <Widget>[
                      _SettingRow(
                        label: '正文字号',
                        stretch: true,
                        control: _SliderControl(
                          value: settings.proseSize,
                          min: 13,
                          max: 22,
                          divisions: 18,
                          suffix: 'pt',
                          onChanged: (double v) => settings.proseSize = v,
                        ),
                      ),
                      _SettingRow(
                        label: '侧边栏宽度',
                        stretch: true,
                        control: _SliderControl(
                          value: settings.listWidth,
                          min: AppLayout.listMinWidth,
                          max: AppLayout.listMaxWidth,
                          divisions: 28,
                          suffix: 'px',
                          onChanged: (double v) => settings.listWidth = v,
                        ),
                      ),
                    ],
                  ),
                  _section(
                    _Section.editor,
                    title: '编辑器',
                    children: <Widget>[
                      _SettingRow(
                        label: '显示大纲',
                        hint: 'Ctrl + Shift + O',
                        control: _Switch(
                          value: settings.outlineVisible,
                          label: settings.outlineVisible ? '开' : '关',
                          onChanged: (bool v) => settings.outlineVisible = v,
                        ),
                      ),
                      _SettingRow(
                        label: '专注模式',
                        note: '隐藏功能栏、侧边栏与大纲，只留下文字。',
                        control: _Switch(
                          value: settings.focusMode,
                          label: settings.focusMode ? '开' : '关',
                          onChanged: (bool v) => settings.focusMode = v,
                        ),
                      ),
                      _SettingRow(
                        label: '默认排序',
                        note: '文件列表与搜索结果都按它排列。',
                        control: _Dropdown<SortMode>(
                          value: settings.sort,
                          items: <SortMode, String>{
                            for (final SortMode m in SortMode.values)
                              m: m.label,
                          },
                          onChanged: (SortMode v) {
                            settings.sort = v;
                            notes.sortMode = v;
                          },
                        ),
                      ),
                    ],
                  ),
                  _section(
                    _Section.templates,
                    title: '模板',
                    desc: '模板文件夹里的笔记既是模板，也是普通笔记。',
                    children: <Widget>[
                      _SettingRow(
                        label: '模板文件夹',
                        stretch: true,
                        note:
                            '填库里任意文件夹的路径，支持子文件夹'
                            '（如 工作/模板），也可从右侧选择；'
                            '留空回到「模板」。',
                        control: const _TemplatesFolderField(),
                      ),
                      _SettingRow(
                        label: '新建笔记时套用文件夹模板',
                        note: '只填空笔记的正文；模板文件夹里的笔记不受影响。',
                        control: _Switch(
                          value: settings.autoApplyFolderTemplates,
                          label: settings.autoApplyFolderTemplates ? '开' : '关',
                          onChanged: (bool v) =>
                              settings.autoApplyFolderTemplates = v,
                        ),
                      ),
                      _SettingRow(
                        label: '文件夹规则',
                        stretch: true,
                        control: const _FolderTemplateRules(),
                      ),
                      _SettingRow(
                        label: '模板快捷键',
                        note: settings.templateHotkeys.isEmpty
                            ? '为常用模板绑定一个组合键。'
                            : '${settings.templateHotkeys.length} 个模板已绑定。',
                        control: AppTextButton(
                          label: '管理',
                          icon: LucideIcons.keyboard,
                          onPressed: () => showTemplateHotkeysDialog(context),
                        ),
                      ),
                    ],
                  ),
                  _section(
                    _Section.vault,
                    title: '笔记库',
                    children: <Widget>[_VaultCard(notes: notes)],
                  ),
                  _section(
                    _Section.shortcuts,
                    title: '快捷键',
                    children: <Widget>[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
                        child: _ShortcutTable(
                          rows: <(String, String)>[
                            ('Ctrl + N', '新建笔记'),
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
                      ),
                    ],
                  ),
                  _section(
                    _Section.about,
                    title: '关于',
                    children: <Widget>[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
                        child: _AboutRow(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNav(AppPalette p) {
    const List<(_Section, IconData, String)> items =
        <(_Section, IconData, String)>[
          (_Section.appearance, LucideIcons.palette, '外观'),
          (_Section.typography, LucideIcons.type, '排版'),
          (_Section.editor, LucideIcons.pencil, '编辑器'),
          (_Section.templates, LucideIcons.blocks, '模板'),
          (_Section.vault, LucideIcons.folder, '笔记库'),
          (_Section.shortcuts, LucideIcons.keyboard, '快捷键'),
          (_Section.about, LucideIcons.info, '关于'),
        ];

    return Container(
      width: 186,
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(right: BorderSide(color: p.outlineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(height: AppSpace.sm),
          for (final (_Section, IconData, String) item in items)
            _NavItem(
              icon: item.$2,
              label: item.$3,
              selected: _active == item.$1,
              onTap: () => _goTo(item.$1),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.sm + 2,
              AppSpace.sm,
              AppSpace.sm + 2,
              AppSpace.md,
            ),
            child: Row(
              children: <Widget>[
                Icon(LucideIcons.check, size: 12, color: p.success),
                const SizedBox(width: 5),
                Text(
                  '设置已自动保存',
                  style: TextStyle(
                    fontSize: AppText.caption - 0.5,
                    color: p.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A group: title, an optional one-line explanation, then its rows.
  Widget _section(
    _Section id, {
    required String title,
    String? desc,
    required List<Widget> children,
  }) {
    final AppPalette p = context.palette;
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Container(height: 1, color: p.outlineSoft));
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: children[i],
        ),
      );
    }
    return Padding(
      key: _anchors[id],
      padding: const EdgeInsets.only(bottom: AppSpace.md + 2),
      child: DecoratedBox(
        // 每组一张卡片：组与组之间靠 14px 留白和卡片边框分开，而不是靠一段
        // 标题和细线硬切——标题混在滚动内容里时，很容易读成一整片选项。
        decoration: BoxDecoration(
          color: p.surfaceRaised,
          borderRadius: AppRadius.lgAll,
          border: Border.all(color: p.outlineSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: p.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.1,
                            color: p.textPrimary,
                          ),
                        ),
                        if (desc != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              desc,
                              style: TextStyle(
                                fontSize: AppText.caption - 0.5,
                                height: 1.5,
                                color: p.textTertiary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Text(
                    '${children.length} 项',
                    style: TextStyle(
                      fontSize: AppText.caption - 0.5,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: p.outlineSoft),
            ...rows,
          ],
        ),
      ),
    );
  }
}

/// One entry of the left navigation.
class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.sm, 0, AppSpace.sm, 2),
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) {
          final Color fg = selected
              ? p.accent
              : (hovered ? p.textPrimary : p.textSecondary);
          return GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              height: 30,
              padding: EdgeInsets.only(left: selected ? 7 : 9),
              decoration: BoxDecoration(
                color: selected
                    ? p.accentSoft
                    : (hovered ? p.surfaceRaised : Colors.transparent),
                borderRadius: AppRadius.mdAll,
                border: selected
                    ? Border(left: BorderSide(color: p.accent, width: 2))
                    : null,
              ),
              child: Row(
                children: <Widget>[
                  Icon(icon, size: AppIconSize.sm, color: fg),
                  const SizedBox(width: AppSpace.sm),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The two-column setting row: a fixed label column, then a control column
/// where every control begins at the same x.
///
/// [hint] is the short glyph line under the label (a shortcut). [note] is a
/// sentence under the control — a 132px label column cannot carry a paragraph
/// without turning the row into a wall of small text.
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.label,
    required this.control,
    this.hint,
    this.note,
    this.stretch = false,
  });

  final String label;
  final Widget control;
  final String? hint;
  final String? note;

  /// Whether the control fills the whole column (sliders, fields, galleries)
  /// instead of sitting at its natural size against the left edge.
  final bool stretch;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm + 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 132,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: AppText.ui,
                    fontWeight: FontWeight.w500,
                    height: 1.35,
                    color: p.textPrimary,
                  ),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      hint!,
                      style: TextStyle(
                        fontSize: AppText.mono - 0.5,
                        fontFamily: AppFonts.mono,
                        fontFamilyFallback: AppFonts.monoFallback,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.xl),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (stretch)
                  SizedBox(width: double.infinity, child: control)
                else
                  Align(alignment: Alignment.centerLeft, child: control),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Text(
                      note!,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        height: 1.5,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SliderControl extends StatelessWidget {
  const _SliderControl({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
    this.separator = ' ',
  });

  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;

  /// Number and unit are separated by a space for 「16 pt」; a percent sign
  /// reads better attached (「90%」), so that row passes an empty separator.
  final String separator;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Row(
      children: <Widget>[
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
            '${value.toStringAsFixed(0)}$separator$suffix',
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

class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.options,
    required this.onChanged,
    this.keyPrefix,
  });

  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;

  /// 给每个选项挂一个 `keyPrefix-label` 的 key，测试点得到；界面上不显示。
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: AppLayout.fieldHeight,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outlineSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final MapEntry<T, String> option in options.entries)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: keyPrefix == null
                    ? null
                    : ValueKey<String>('$keyPrefix-${option.value}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(option.key),
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: option.key == value
                        ? p.rowSelected
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    option.value,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: option.key == value
                          ? p.textPrimary
                          : p.textTertiary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
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
          icon: Icon(LucideIcons.chevronDown, size: 16, color: p.textTertiary),
          style: TextStyle(fontSize: AppText.ui, color: p.textPrimary),
          onChanged: (T? v) {
            if (v != null) onChanged(v);
          },
          items: items.entries
              .map(
                (MapEntry<T, String> e) =>
                    DropdownMenuItem<T>(value: e.key, child: Text(e.value)),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _VaultCard extends StatelessWidget {
  const _VaultCard({required this.notes});

  final NotesController notes;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm + 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          ? LucideIcons.folder
                          : LucideIcons.cloud,
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
                          fontFamilyFallback: AppFonts.monoFallback,
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
                        icon: LucideIcons.externalLink,
                        onPressed: notes.revealVault,
                      ),
                    AppTextButton(
                      label: '重新载入',
                      icon: LucideIcons.refreshCw,
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
                  ? '每篇笔记都是一个独立的 .md 文件，可以用任何编辑器打开、同步或备份。'
                  : '当前运行在浏览器中，笔记保存在 localStorage 里。'
                        '用桌面版运行即可获得真正的 .md 文件。',
              style: TextStyle(
                fontSize: AppText.caption,
                height: 1.6,
                color: p.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Row(
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
                '版本 1.0.0 · Flutter 桌面应用 · 本地优先，数据完全属于你',
                style: TextStyle(
                  fontSize: AppText.caption,
                  color: p.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The templates folder is a vault-relative path, not a name: the field commits
/// on Enter, on losing focus, and when the dialog closes, then shows the value
/// the controller actually stored (an empty path falls back to 「模板」).
class _TemplatesFolderField extends StatefulWidget {
  const _TemplatesFolderField();

  @override
  State<_TemplatesFolderField> createState() => _TemplatesFolderFieldState();
}

class _TemplatesFolderFieldState extends State<_TemplatesFolderField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'templates-folder');
  late SettingsController _settings;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Captured once so the value can still be committed from dispose when the
    // dialog is closed by Esc while the field holds focus.
    _settings = context.read<SettingsController>();
    if (_loaded) return;
    _loaded = true;
    _controller.text = _settings.templatesFolder;
  }

  @override
  void dispose() {
    _commit();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    _settings.templatesFolder = _controller.text;
    final String normalized = _settings.templatesFolder;
    if (_controller.text == normalized) return;
    _controller.value = TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final SettingsController settings = context.watch<SettingsController>();
    final List<String> folders = context.watch<NotesController>().folders;
    return AnimatedContainer(
      duration: AppMotion.fast,
      height: AppLayout.fieldHeight,
      padding: const EdgeInsets.only(left: AppSpace.sm),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: _focus.hasFocus ? p.accent : p.outlineSoft),
      ),
      child: Row(
        children: <Widget>[
          Icon(LucideIcons.folder, size: 14, color: p.textTertiary),
          const SizedBox(width: 7),
          Expanded(
            child: TextField(
              key: const ValueKey<String>('templates-folder'),
              controller: _controller,
              focusNode: _focus,
              onSubmitted: (_) {
                _commit();
                _focus.unfocus();
              },
              cursorColor: p.accent,
              cursorWidth: 1.3,
              style: TextStyle(
                fontSize: 12.5,
                color: p.textPrimary,
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '模板',
                hintStyle: TextStyle(
                  fontSize: 12.5,
                  color: p.textTertiary,
                  fontFamily: AppFonts.mono,
                  fontFamilyFallback: AppFonts.monoFallback,
                ),
              ),
            ),
          ),
          if (folders.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: '选择已有文件夹',
              position: PopupMenuPosition.under,
              offset: const Offset(0, 6),
              color: p.surfaceRaised,
              constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
              onSelected: _select,
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                for (final String folder in folders)
                  PopupMenuItem<String>(
                    value: folder,
                    height: 32,
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 22,
                          child: settings.templatesFolder == folder
                              ? Icon(
                                  LucideIcons.check,
                                  size: 14,
                                  color: p.accent,
                                )
                              : null,
                        ),
                        Flexible(
                          child: Text(
                            folder,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: settings.templatesFolder == folder
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: settings.templatesFolder == folder
                                  ? p.accent
                                  : p.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              child: SizedBox(
                width: 26,
                height: 26,
                child: Icon(
                  LucideIcons.chevronDown,
                  size: 14,
                  color: p.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _select(String folder) {
    _controller.text = folder;
    _commit();
    _focus.unfocus();
  }
}

/// `文件夹 → 模板` rules for automatic application.
///
/// Rules reference template **ids**, so renaming or moving a template keeps the
/// rule working; a deleted one stays visible as 「模板已失效」 until removed.
class _FolderTemplateRules extends StatelessWidget {
  const _FolderTemplateRules();

  static const TemplateService _service = TemplateService();

  static List<FolderTemplateRule> _replaced(
    List<FolderTemplateRule> rules,
    int index,
    FolderTemplateRule updated,
  ) {
    return <FolderTemplateRule>[
      for (int i = 0; i < rules.length; i++)
        if (i != index &&
            rules[i].folderPath.toLowerCase() !=
                updated.folderPath.toLowerCase())
          rules[i],
      updated,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final SettingsController settings = context.watch<SettingsController>();
    final NotesController notes = context.watch<NotesController>();
    final List<Note> templates = _service.discoverTemplates(
      notes.allNotes,
      settings.templatesFolder,
    );
    final List<FolderTemplateRule> rules = settings.folderTemplateRules;

    if (templates.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpace.xs),
        child: Text(
          '模板文件夹里还没有模板。先新建一篇模板，再回来配置文件夹规则。',
          style: TextStyle(
            fontSize: AppText.caption,
            height: 1.6,
            color: p.textTertiary,
          ),
        ),
      );
    }

    final List<String> folderOptions = <String>[''];
    for (final String folder in notes.folders) {
      if (_service.isInsideTemplatesFolder(folder, settings.templatesFolder)) {
        continue;
      }
      if (folderOptions.any(
        (String f) => f.toLowerCase() == folder.toLowerCase(),
      )) {
        continue;
      }
      folderOptions.add(folder);
    }
    for (final FolderTemplateRule rule in rules) {
      if (folderOptions.any(
        (String f) => f.toLowerCase() == rule.folderPath.toLowerCase(),
      )) {
        continue;
      }
      folderOptions.add(rule.folderPath);
    }

    bool folderExists(String folder) => notes.folders.any(
      (String f) => f.toLowerCase() == folder.toLowerCase(),
    );
    final Map<String, String> folderLabels = <String, String>{
      for (final String folder in folderOptions)
        folder: folder.isEmpty
            ? '根目录'
            : (folderExists(folder) ? folder : '$folder（已不存在）'),
    };
    final Set<String> staleTemplates = <String>{
      for (final FolderTemplateRule rule in rules)
        if (!templates.any((Note note) => note.id == rule.templateId))
          rule.templateId,
    };
    final Map<String, String> templateLabels = <String, String>{
      for (final Note note in templates)
        note.id: note.title.trim().isEmpty ? '未命名' : note.title.trim(),
      for (final String id in staleTemplates) id: '模板已失效',
    };

    final Set<String> usedFolders = <String>{
      for (final FolderTemplateRule rule in rules)
        rule.folderPath.toLowerCase(),
    };
    String? freeFolder;
    for (final String folder in folderOptions) {
      if (!usedFolders.contains(folder.toLowerCase())) {
        freeFolder = folder;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1, bottom: 3),
          child: Text(
            '新笔记落在匹配的文件夹时，用对应模板填满空正文；更深的文件夹优先。',
            style: TextStyle(
              fontSize: AppText.caption,
              height: 1.55,
              color: p.textTertiary,
            ),
          ),
        ),
        if (rules.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Text(
              '还没有规则。',
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
              ),
            ),
          ),
        for (int i = 0; i < rules.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _RuleDropdown<String>(
                    value: rules[i].folderPath,
                    items: folderLabels,
                    danger: <String>{
                      if (!rules[i].isRoot &&
                          !folderExists(rules[i].folderPath))
                        rules[i].folderPath,
                    },
                    onChanged: (String folder) =>
                        settings.folderTemplateRules = _replaced(
                          rules,
                          i,
                          FolderTemplateRule(
                            folderPath: folder,
                            templateId: rules[i].templateId,
                          ),
                        ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.xs + 1,
                  ),
                  child: Icon(
                    LucideIcons.arrowRight,
                    size: 13,
                    color: p.textTertiary,
                  ),
                ),
                Expanded(
                  child: _RuleDropdown<String>(
                    value: rules[i].templateId,
                    items: templateLabels,
                    danger: staleTemplates,
                    onChanged: (String templateId) =>
                        settings.folderTemplateRules = _replaced(
                          rules,
                          i,
                          FolderTemplateRule(
                            folderPath: rules[i].folderPath,
                            templateId: templateId,
                          ),
                        ),
                  ),
                ),
                const SizedBox(width: AppSpace.xs),
                AppIconButton(
                  icon: LucideIcons.trash2,
                  tooltip: '删除规则',
                  size: 26,
                  iconSize: 13,
                  onPressed: () =>
                      settings.folderTemplateRules = <FolderTemplateRule>[
                        for (int j = 0; j < rules.length; j++)
                          if (j != i) rules[j],
                      ],
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AppTextButton(
              label: '添加规则',
              icon: LucideIcons.plus,
              onPressed: freeFolder == null
                  ? null
                  : () => settings.folderTemplateRules = <FolderTemplateRule>[
                      ...rules,
                      FolderTemplateRule(
                        folderPath: freeFolder!,
                        templateId: templates.first.id,
                      ),
                    ],
            ),
          ),
        ),
        if (freeFolder == null)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            child: Text(
              '每个文件夹都已经有一条规则。',
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
              ),
            ),
          ),
      ],
    );
  }
}

class _RuleDropdown<T> extends StatelessWidget {
  const _RuleDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
    this.danger = const <Never>{},
  });

  final T value;
  final Map<T, String> items;
  final ValueChanged<T> onChanged;

  /// Values whose label should be red — a stale template or a folder that no
  /// longer exists. They stay selectable so the rule can be repaired.
  final Set<T> danger;

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
          isExpanded: true,
          borderRadius: AppRadius.mdAll,
          dropdownColor: p.surfaceRaised,
          icon: Icon(LucideIcons.chevronDown, size: 15, color: p.textTertiary),
          style: TextStyle(fontSize: AppText.ui, color: p.textPrimary),
          onChanged: (T? v) {
            if (v != null) onChanged(v);
          },
          items: items.entries
              .map(
                (MapEntry<T, String> e) => DropdownMenuItem<T>(
                  value: e.key,
                  child: Text(
                    e.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: danger.contains(e.key)
                        ? TextStyle(color: p.danger)
                        : null,
                  ),
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
                  style: TextStyle(
                    fontSize: AppText.label,
                    color: p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
