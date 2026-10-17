import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';

/// The far-left navigation column: brand, scopes, tags and vault status.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.onOpenSettings,
    required this.onOpenPalette,
    required this.onToggleCollapsed,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPalette;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();
    final SettingsController settings = context.watch<SettingsController>();
    final bool collapsed = settings.sidebarCollapsed;
    final double width = collapsed
        ? AppLayout.sidebarCollapsedWidth
        : AppLayout.sidebarWidth;

    return AnimatedContainer(
      duration: AppMotion.base,
      curve: AppMotion.enter,
      width: width,
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Brand(collapsed: collapsed),
          Divider(height: 1, color: p.outlineSoft),
          const SizedBox(height: AppSpace.sm),
          if (!collapsed) const SectionLabel('笔记库'),
          _NavItem(
            icon: Icons.layers_outlined,
            label: '全部笔记',
            count: notes.allNotes.length,
            collapsed: collapsed,
            selected: notes.scope == NoteScope.all && notes.activeTag == null,
            onTap: () => notes.setScope(NoteScope.all),
          ),
          _NavItem(
            icon: Icons.push_pin_outlined,
            label: '置顶',
            count: notes.allNotes.where((n) => n.pinned).length,
            collapsed: collapsed,
            selected: notes.scope == NoteScope.pinned,
            onTap: () => notes.setScope(NoteScope.pinned),
          ),
          _NavItem(
            icon: Icons.star_outline_rounded,
            label: '收藏',
            count: notes.totalFavorites,
            collapsed: collapsed,
            selected: notes.scope == NoteScope.favorites,
            onTap: () => notes.setScope(NoteScope.favorites),
          ),
          _NavItem(
            icon: Icons.check_box_outlined,
            label: '含待办',
            count: notes.allNotes.where((n) => n.taskTotal > 0).length,
            collapsed: collapsed,
            selected: notes.scope == NoteScope.tasks,
            onTap: () => notes.setScope(NoteScope.tasks),
          ),
          _NavItem(
            icon: Icons.label_off_outlined,
            label: '未加标签',
            count: notes.allNotes.where((n) => n.tags.isEmpty).length,
            collapsed: collapsed,
            selected: notes.scope == NoteScope.untagged,
            onTap: () => notes.setScope(NoteScope.untagged),
          ),
          const SizedBox(height: AppSpace.md),
          Divider(height: 1, color: p.outlineSoft),
          if (!collapsed) _TagSection(tags: notes.tags),
          if (collapsed) const Spacer(),
          if (!collapsed) const Spacer(),
          Divider(height: 1, color: p.outlineSoft),
          _Footer(
            collapsed: collapsed,
            onOpenSettings: onOpenSettings,
            onOpenPalette: onOpenPalette,
            onToggleCollapsed: onToggleCollapsed,
          ),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.collapsed});

  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SizedBox(
      height: 56,
      child: Row(
        children: <Widget>[
          const SizedBox(width: AppSpace.lg),
          const _Logomark(),
          if (!collapsed) ...<Widget>[
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'NRS',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.6,
                      height: 1.1,
                      color: p.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Markdown 笔记',
                    style: TextStyle(
                      fontSize: 10.5,
                      height: 1.1,
                      letterSpacing: 0.2,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Logomark extends StatelessWidget {
  const _Logomark();

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[p.accentHover, p.accent],
        ),
        borderRadius: BorderRadius.circular(9),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: p.accent.withValues(alpha: 0.32),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        'N',
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w800,
          height: 1,
          letterSpacing: 0,
          color: p.onAccent,
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.collapsed,
    this.count,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool collapsed;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: collapsed ? 12 : AppSpace.sm + 2,
        vertical: 1,
      ),
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) => Tooltip(
          message: collapsed ? label : '',
          waitDuration: const Duration(milliseconds: 500),
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              height: 32,
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 10),
              decoration: BoxDecoration(
                color: selected
                    ? p.accent.withValues(alpha: p.isDark ? 0.20 : 0.12)
                    : (hovered ? p.surfaceRaised.withValues(alpha: 0.7) : Colors.transparent),
                borderRadius: AppRadius.smAll,
              ),
              child: Row(
                mainAxisAlignment: collapsed
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    icon,
                    size: 16,
                    color: selected
                        ? p.accent
                        : (hovered ? p.textPrimary : p.textSecondary),
                  ),
                  if (!collapsed) ...<Widget>[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: selected ? p.accent : p.textSecondary,
                        ),
                      ),
                    ),
                    if (count != null && count! > 0)
                      Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: (selected ? p.accent : p.textTertiary)
                              .withValues(alpha: 0.85),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TagSection extends StatelessWidget {
  const _TagSection({required this.tags});

  final List<TagStat> tags;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();

    if (tags.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
        child: Text(
          '给笔记加上 tag,它们会\n出现在这里。',
          style: TextStyle(fontSize: 11.5, height: 1.6, color: p.textTertiary),
        ),
      );
    }

    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionLabel(
            '标签',
            trailing: notes.activeTag == null
                ? null
                : GestureDetector(
                    onTap: notes.clearFilters,
                    child: Text(
                      '清除',
                      style: TextStyle(fontSize: 10.5, color: p.accent),
                    ),
                  ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              itemCount: tags.length,
              itemBuilder: (BuildContext context, int i) {
                final TagStat tag = tags[i];
                final bool selected = notes.activeTag == tag.name;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.sm + 2,
                    vertical: 1,
                  ),
                  child: HoverBuilder(
                    cursor: SystemMouseCursors.click,
                    builder: (BuildContext context, bool hovered) => GestureDetector(
                      onTap: () => notes.toggleTag(tag.name),
                      behavior: HitTestBehavior.opaque,
                      child: AnimatedContainer(
                        duration: AppMotion.fast,
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: selected
                              ? p.accent.withValues(alpha: p.isDark ? 0.20 : 0.12)
                              : (hovered
                                    ? p.surfaceRaised.withValues(alpha: 0.7)
                                    : Colors.transparent),
                          borderRadius: AppRadius.smAll,
                        ),
                        child: Row(
                          children: <Widget>[
                            Text(
                              '#',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: selected
                                    ? p.accent
                                    : p.textTertiary.withValues(alpha: 0.8),
                              ),
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                tag.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: selected ? p.accent : p.textSecondary,
                                ),
                              ),
                            ),
                            Text(
                              '${tag.count}',
                              style: TextStyle(
                                fontSize: 11,
                                color: p.textTertiary.withValues(alpha: 0.8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.collapsed,
    required this.onOpenSettings,
    required this.onOpenPalette,
    required this.onToggleCollapsed,
  });

  final bool collapsed;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenPalette;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();

    if (collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        child: Column(
          children: <Widget>[
            AppIconButton(
              icon: Icons.search_rounded,
              tooltip: '搜索笔记',
              shortcut: 'Ctrl+K',
              onPressed: onOpenPalette,
            ),
            const SizedBox(height: 4),
            AppIconButton(
              icon: Icons.settings_outlined,
              tooltip: '设置',
              shortcut: 'Ctrl+,',
              onPressed: onOpenSettings,
            ),
            const SizedBox(height: 4),
            AppIconButton(
              icon: Icons.keyboard_double_arrow_right_rounded,
              tooltip: '展开侧栏',
              onPressed: onToggleCollapsed,
            ),
          ],
        ),
      );
    }

    final bool native = notes.supportsNativeFiles;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.md, AppSpace.md, AppSpace.md, AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (native)
            Tooltip(
              message: notes.vaultLocation,
              child: HoverBuilder(
                cursor: SystemMouseCursors.click,
                builder: (BuildContext context, bool hovered) => GestureDetector(
                  onTap: () => notes.revealVault(),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                      vertical: AppSpace.sm,
                    ),
                    decoration: BoxDecoration(
                      color: hovered ? p.surfaceRaised : Colors.transparent,
                      borderRadius: AppRadius.smAll,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.folder_open_outlined,
                          size: 14,
                          color: p.textTertiary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '打开笔记库文件夹',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: p.textTertiary,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 11,
                          color: p.textTertiary.withValues(alpha: 0.7),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpace.xs),
          Row(
            children: <Widget>[
              AppIconButton(
                icon: Icons.search_rounded,
                tooltip: '搜索笔记',
                shortcut: 'Ctrl+K',
                onPressed: onOpenPalette,
              ),
              const SizedBox(width: 2),
              AppIconButton(
                icon: Icons.settings_outlined,
                tooltip: '设置',
                shortcut: 'Ctrl+,',
                onPressed: onOpenSettings,
              ),
              const Spacer(),
              AppIconButton(
                icon: Icons.keyboard_double_arrow_left_rounded,
                tooltip: '收起侧栏',
                shortcut: 'Ctrl+\\',
                onPressed: onToggleCollapsed,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
