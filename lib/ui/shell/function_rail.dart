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
/// 图谱、白板、设置都是编辑区里的**一页**（各带一条标签、能分屏、能拖），
/// 所以这里的三颗按钮只是「打开 / 切过去」的入口，`*Active` 只负责点亮。
///
/// Selection is marked the same way here as in every other column: a neutral
/// `rowSelected` square and a brighter glyph. One language, learned once.
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
    this.settingsActive = false,
    this.templatesActive = false,
    this.trashActive = false,
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

  /// 设置 / 模板 / 回收站此刻就在屏幕上（它们也是编辑区里的页，所以和上面
  /// 两颗一样要点亮）。
  final bool settingsActive;
  final bool templatesActive;
  final bool trashActive;

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
    return SizedBox(
      width: AppLayout.railWidth,
      // ⛔ 整条栏要拉满 44 宽。`Column` 默认按子项宽度居中：下面的底色块里
      // 只装着 28 宽的按钮，不 stretch 的话底色就只有 28 宽，两边各露出 8px
      // 画布，看起来像功能栏没填满。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 窗口顶上那 40px 永远属于顶带——左侧边栏收起后，功能栏下半截
          // 并进纸面，但最上面这一条仍要和编辑区的标签条接上，不然窗口顶上
          // 的带子就在功能栏这里断了。
          SizedBox(
            width: double.infinity,
            height: AppLayout.titleBarHeight,
            child: ColoredBox(color: p.sidebar),
          ),
          Expanded(
            child: Container(
              // 和右边那块地同一个色阶：边栏在就跟边栏，边栏收起就跟编辑区。
              color: sidebarVisible ? p.sidebar : p.surface,
              // 顶上 40 + 4 = 44：第一颗按钮和顶带隔开一格。按钮 28、缝 6。
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Column(
                children: <Widget>[
                  _RailButton(
                    icon: LucideIcons.blocks,
                    tooltip: '插入模板',
                    shortcut: 'Ctrl+P',
                    selected: templatesActive,
                    onPressed: onOpenTemplates,
                  ),
                  const SizedBox(height: 6),
                  _RailButton(
                    icon: LucideIcons.gitFork,
                    tooltip: '关系图谱',
                    selected: graphActive,
                    onPressed: onOpenGraph,
                  ),
                  const SizedBox(height: 6),
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
                    selected: trashActive,
                    onPressed: onOpenTrash,
                  ),
                  const SizedBox(height: 6),
                  _RailButton(
                    icon: LucideIcons.settings,
                    tooltip: '设置',
                    shortcut: 'Ctrl+,',
                    selected: settingsActive,
                    onPressed: onOpenSettings,
                  ),
                  const SizedBox(height: AppSpace.sm),
                ],
              ),
            ),
          ),
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
        ? p.rowSelected
        : (_hovered ? p.surfaceRaised : Colors.transparent);
    final Color foreground = widget.selected || _hovered
        ? p.textPrimary
        : p.textTertiary;

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
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(widget.icon, size: AppIconSize.sm, color: foreground),
          ),
        ),
      ),
    );
  }
}
