import 'package:flutter/material.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';

/// The far-left function rail. Buttons only: it switches the middle sidebar
/// between files, search and tags, and collapses that sidebar entirely.
class AppRail extends StatelessWidget {
  const AppRail({
    super.key,
    required this.view,
    required this.collapsed,
    required this.onToggleCollapsed,
    required this.onSelectView,
    required this.onOpenPalette,
    required this.onOpenSettings,
  });

  final SidebarView view;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<SidebarView> onSelectView;
  final VoidCallback onOpenPalette;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: AppLayout.railWidth,
      decoration: BoxDecoration(
        color: p.sidebar,
        border: Border(right: BorderSide(color: p.outlineSoft)),
      ),
      child: Column(
        children: <Widget>[
          const SizedBox(height: AppSpace.sm),
          _RailButton(
            icon: collapsed
                ? Icons.keyboard_double_arrow_right_rounded
                : Icons.keyboard_double_arrow_left_rounded,
            tooltip: collapsed ? '展开侧边栏' : '收起侧边栏',
            shortcut: 'Ctrl+\\',
            onPressed: onToggleCollapsed,
          ),
          const SizedBox(height: AppSpace.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13),
            child: Divider(height: 1, color: p.outlineSoft),
          ),
          const SizedBox(height: AppSpace.sm),
          for (final SidebarView item in SidebarView.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _RailButton(
                icon: item.icon,
                tooltip: item.label,
                selected: view == item,
                onPressed: () => onSelectView(item),
              ),
            ),
          const Spacer(),
          _RailButton(
            icon: Icons.bolt_outlined,
            tooltip: '快速打开',
            shortcut: 'Ctrl+P',
            onPressed: onOpenPalette,
          ),
          const SizedBox(height: 4),
          _RailButton(
            icon: Icons.settings_outlined,
            tooltip: '设置',
            shortcut: 'Ctrl+,',
            onPressed: onOpenSettings,
          ),
          const SizedBox(height: AppSpace.sm),
        ],
      ),
    );
  }
}

class _RailButton extends StatefulWidget {
  const _RailButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.shortcut,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;
  final String? shortcut;

  @override
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color background = widget.selected
        ? p.accent.withValues(alpha: p.isDark ? 0.22 : 0.13)
        : (_hovered ? p.surfaceRaised : Colors.transparent);
    final Color foreground = widget.selected
        ? p.accent
        : (_hovered ? p.textPrimary : p.textSecondary);

    return Tooltip(
      message: widget.shortcut == null
          ? widget.tooltip
          : '${widget.tooltip}  ·  ${widget.shortcut}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: background,
              borderRadius: AppRadius.mdAll,
              border: widget.selected && !p.isDark
                  ? Border.all(color: p.accent.withValues(alpha: 0.16))
                  : null,
            ),
            child: Icon(widget.icon, size: 18, color: foreground),
          ),
        ),
      ),
    );
  }
}
