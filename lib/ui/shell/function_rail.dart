import 'package:flutter/material.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';

/// The narrow strip on the far left.
///
/// It holds only what does not fit in the title bar's three regions: the tag
/// view at the top, and the two window-wide commands — quick open and settings
/// — pinned to the bottom where they are always in the same place.
///
/// Selection is marked the same way here as in every other column: an
/// `accentSoft` square with a 2px `accent` bar against its left edge. One
/// language, learned once.
class AppRail extends StatelessWidget {
  const AppRail({
    super.key,
    required this.view,
    required this.onSelectView,
    required this.onOpenPalette,
    required this.onOpenSettings,
  });

  final SidebarView view;
  final ValueChanged<SidebarView> onSelectView;
  final VoidCallback onOpenPalette;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: AppLayout.railWidth,
      decoration: BoxDecoration(
        // The deepest step on screen: the rail reads as the window's own edge,
        // so the sidebar next to it can sit *above* it instead of beside it.
        color: p.canvas,
        border: Border(right: BorderSide(color: p.outlineSoft)),
      ),
      child: Column(
        children: <Widget>[
          const SizedBox(height: AppSpace.sm),
          _RailButton(
            icon: SidebarView.tags.icon,
            tooltip: SidebarView.tags.label,
            selected: view == SidebarView.tags,
            onPressed: () => onSelectView(SidebarView.tags),
          ),
          const Spacer(),
          _RailButton(
            icon: Icons.bolt_outlined,
            tooltip: '快速打开',
            shortcut: 'Ctrl+P',
            onPressed: onOpenPalette,
          ),
          // A hairline, not a gap: without it the two pinned commands read as a
          // third view that happens to be at the bottom.
          Container(
            width: 20,
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            color: p.outlineSoft,
          ),
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
        ? p.accentSoft
        : (_hovered ? p.surfaceRaised : Colors.transparent);
    final Color foreground = widget.selected
        ? p.accent
        : (_hovered ? p.textPrimary : p.textSecondary);

    return Tooltip(
      message: widget.shortcut == null
          ? widget.tooltip
          : '${widget.tooltip}  ·  ${widget.shortcut}',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: background,
              borderRadius: AppRadius.mdAll,
            ),
            child: Stack(
              children: <Widget>[
                Center(
                  child: Icon(
                    widget.icon,
                    size: AppIconSize.md,
                    color: foreground,
                  ),
                ),
                // The bar sits on the button's own left edge rather than the
                // rail's: 6px away from the pill it belongs to, it would read
                // as a rule on the window instead of a marker on the item.
                Positioned(
                  left: 0,
                  top: 8,
                  bottom: 8,
                  child: AnimatedOpacity(
                    duration: AppMotion.fast,
                    opacity: widget.selected ? 1 : 0,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
