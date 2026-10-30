import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';

/// The narrow strip on the far left.
///
/// It holds only what does not fit in the title bar's three regions: the
/// template action and the two full-screen views (graph, canvas) at the top,
/// and the vault utilities — trash, settings — pinned to the bottom where they
/// are always in the same place.
///
/// 文件 / 搜索 / 标签现在都是侧边栏标签条上的页，这里不再替侧边栏切视图：
/// 功能栏只放全局动作（用户原话：「把标签按钮也移到侧边栏按钮上」）。
///
/// The graph and the canvas live here rather than in the tab strip because
/// neither is a document: they have no ×, they cannot be closed, and pinning
/// them to the tabs only stole width from the notes that can.
///
/// Selection is marked the same way here as in every other column: an
/// `accentSoft` square with a 2px `accent` bar against its left edge. One
/// language, learned once.
class AppRail extends StatelessWidget {
  const AppRail({
    super.key,
    required this.onOpenTemplates,
    required this.onOpenGraph,
    required this.onOpenCanvas,
    required this.onOpenTrash,
    required this.onOpenSettings,
    this.graphActive = false,
    this.canvasActive = false,
    this.topInset = 0,
    required this.sidebarVisible,
  });

  final VoidCallback onOpenTemplates;
  final VoidCallback onOpenGraph;
  final VoidCallback onOpenCanvas;
  final VoidCallback onOpenTrash;
  final VoidCallback onOpenSettings;

  /// The main area is showing that view right now.
  ///
  /// The rail is the only place left that says which of the three views is on
  /// screen, so it has to carry the marker the tabs used to.
  final bool graphActive;
  final bool canvasActive;

  /// 顶上要给浮在标签条上的那颗「收起侧边栏」让出来的高度。
  ///
  /// 标签条现在顶到窗口最上面，那颗开关正好落在功能栏的头顶上——不让开就会
  /// 盖住第一颗按钮。
  final double topInset;

  /// 左侧边栏此刻开着没有。
  ///
  /// 功能栏不自己占一档底色，它永远跟右边接着的那块地同色：边栏开着时是
  /// 侧边栏的底色，边栏收起时整排宽度让给编辑区，它就换成编辑区的纸面，
  /// 两者之间不出现一条突兀的暗带（用户原话：「在左侧边栏出现的时候，跟左
  /// 侧边栏保持一致。然后在左侧边栏隐藏的时候，跟编辑栏的颜色保持一致」）。
  final bool sidebarVisible;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: AppLayout.railWidth,
      decoration: BoxDecoration(
        // 和右边那块地同一个色阶：边栏在就跟边栏，边栏收起就跟编辑区。
        color: sidebarVisible ? p.sidebar : p.surface,
        border: Border(right: BorderSide(color: p.outlineSoft)),
      ),
      child: Column(
        children: <Widget>[
          SizedBox(height: topInset > 0 ? topInset : AppSpace.sm),
          _RailButton(
            icon: LucideIcons.blocks,
            tooltip: '插入模板',
            shortcut: 'Ctrl+P',
            onPressed: onOpenTemplates,
          ),
          const SizedBox(height: AppSpace.xs),
          _RailButton(
            icon: LucideIcons.gitFork,
            tooltip: '关系图谱',
            selected: graphActive,
            onPressed: onOpenGraph,
          ),
          const SizedBox(height: AppSpace.xs),
          _RailButton(
            icon: LucideIcons.squareDashed,
            tooltip: '白板',
            shortcut: 'Ctrl+Shift+B',
            selected: canvasActive,
            onPressed: onOpenCanvas,
          ),
          const Spacer(),
          _RailButton(
            icon: LucideIcons.trash2,
            tooltip: '回收站',
            onPressed: onOpenTrash,
          ),
          const SizedBox(height: AppSpace.xs),
          _RailButton(
            icon: LucideIcons.settings,
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
