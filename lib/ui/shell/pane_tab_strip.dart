import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'tab_drag.dart';

/// 一格顶上那条标签条。
///
/// 编辑区和侧边栏各画一条，**挂在各自格子的顶上**。它同时也是窗口最上面那条
/// 带子：顶栏不再单独占一行，只剩下几颗按钮浮在它上面（见
/// `title_bar_content.dart`）。用户原话：「顶部的 tab 并不是顶部栏的一部分，
/// 其实也是跟着自己的编辑栏的，只是在顶部显示而已。侧边栏也是同理。」
class PaneTabStrip extends StatelessWidget {
  const PaneTabStrip({
    super.key,
    required this.tabs,
    required this.index,
    required this.focused,
    required this.onSelect,
    required this.onClose,
    this.filler,
    this.trailingInset = 0,
    this.onDropTab,
    this.acceptsTab,
    this.compactIcons = false,
  });

  final List<PaneTabData> tabs;

  /// 当前那一页的下标。
  final int index;

  /// 这一格是不是聚焦的那一格。只影响下划线的颜色——**每一格都要标出自己
  /// 的当前页**，否则分屏之后不知道另一格在干什么。
  final bool focused;

  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;

  /// 标签条上没被标签占住的那一段交给它——桌面端在这儿放「拖窗口」。
  ///
  /// 它压在标签**底下**：点在标签上算标签，点空白处才算拖窗口。
  final Widget? filler;

  /// 右端要让给浮在标签条上面的那几颗按钮的宽度（面板开关 + 窗口按钮）。
  final double trailingInset;

  /// 往这一格的标签条上丢下一页。
  ///
  /// 格子中间那一大块归 `PaneDropZone` 管，标签条这 40 是它上面另外一块地：
  /// 分出去的那一页想「并回来」，最顺手的就是丢到对面那格的标签条上——看
  /// 起来就是把一张纸塞回那一摞里。不传 = 这条标签条不收货。
  final void Function(TabDrag tab)? onDropTab;

  /// 收货之前先问一句。
  ///
  /// 编辑区只收 [DocDrag]、侧边栏只收 [SidePageDrag]；从**自己这一格**拎起来的
  /// 那一页也不收——它本来就在这儿，拖回自己的条上没什么可做的，而且一起手
  /// 整条就亮起来，反倒像在暗示「可以放这里」。
  final bool Function(TabDrag tab)? acceptsTab;

  /// 图标页排得更紧：28 的方块、彼此隔 2、左边不空。
  ///
  /// 右栏顶上那三颗（大纲 / 表格 / 图片）本来就和窗口按钮挤在同一段里——面板
  /// 最窄时只剩 88 宽，三颗 28 加两道 2px 缝正好填满。它们从顶栏的开关变成
  /// 右栏上格的标签页之后，量法不能变：位置、大小、缝宽都照旧，否则面板一开
  /// 那排图标就整体往右偏一截。侧边栏不传——它没有窗口按钮让位，照旧用 32
  /// 的方块。
  final bool compactIcons;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // 侧边栏那一格排的是图标页：它们是一排方块按钮，不是标题，左边从 6 起、
    // 彼此隔 4（和顶栏那组按钮同一套量法）。右栏那排是紧凑版：从 0 起、隔 2。
    final bool iconTabs =
        tabs.isNotEmpty && tabs.every((PaneTabData t) => t.icon != null);
    final Widget strip = Container(
      height: AppLayout.paneTabStripHeight,
      // 标签条和侧边栏同一种底色：窗口顶上那条带子属于侧边栏那一档，而不是
      // 最深的画布档。编辑区比它亮一档，于是标签带在下、纸面在上，边界自
      // 然而然分出来（用户原话：「让顶部栏的颜色跟侧边栏保持一致」）。
      color: p.sidebar,
      child: Stack(
        children: <Widget>[
          if (filler != null) Positioned.fill(child: filler!),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(right: trailingInset),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: ClipRect(
                      // 标签挂在下沿：文字页的下划线要和纸面接上；图标页的方块
                      // 靠自己的下边距在 40 的带子里居中（见 `_iconTab`）。
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (iconTabs && !compactIcons)
                              const SizedBox(width: 6),
                            for (int i = 0; i < tabs.length; i++) ...<Widget>[
                              if (compactIcons && i > 0)
                                const SizedBox(width: 2),
                              Flexible(
                                child: DraggableTab(
                                  data: tabs[i].drag,
                                  child: PaneTab(
                                    key: tabs[i].key,
                                    label: tabs[i].label,
                                    tooltip: tabs[i].tooltip,
                                    icon: tabs[i].icon,
                                    compact: compactIcons,
                                    active: i == index,
                                    focused: focused,
                                    onTap: () => onSelect(i),
                                    onClose: () => onClose(i),
                                    onSecondaryTapDown: tabs[i].onSecondaryTap,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (onDropTab == null) return strip;
    return DragTarget<TabDrag>(
      onWillAcceptWithDetails: (DragTargetDetails<TabDrag> d) =>
          acceptsTab?.call(d.data) ?? true,
      onAcceptWithDetails: (DragTargetDetails<TabDrag> d) => onDropTab!(d.data),
      builder:
          (
            BuildContext context,
            List<TabDrag?> candidate,
            List<dynamic> rejected,
          ) {
            // 只是提示「松手就并进这一格」，别挡着底下的标签和拖窗口的那一段。
            return Stack(
              children: <Widget>[
                strip,
                if (candidate.isNotEmpty)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: p.accent.withValues(alpha: 0.06),
                          border: Border.all(color: p.accent),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
    );
  }
}

/// 标签条上的一页：标题 + 拖拽载荷。
@immutable
class PaneTabData {
  const PaneTabData({
    this.key,
    required this.label,
    required this.drag,
    this.icon,
    this.tooltip,
    this.onSecondaryTap,
  });

  /// 给测试认这一页用的。
  final Key? key;

  final String label;

  /// 有图标就画成一颗 32 的方块页（侧边栏的「文件 / 搜索 / 标签」），名字退到
  /// tooltip 上。编辑区不传——在那里必须一眼看见是哪一篇。
  final IconData? icon;

  /// 悬停时说的话。不传就用 [label]。
  ///
  /// 右栏的大纲页要带上快捷键（它以前是顶栏那颗开关），而标签上的名字只有
  /// 「大纲」两个字——tooltip 是唯一能放下「· Ctrl+Shift+O」的地方。
  final String? tooltip;

  /// 拖出去时拎在手上的东西。编辑区是 [DocDrag]，侧边栏是 [SidePageDrag]。
  final TabDrag drag;

  /// 右键这一页（只给侧边栏用：在那儿「上 / 下分屏、关闭这一页」）。
  final void Function(Offset at)? onSecondaryTap;
}

/// 标签条上的一页。
///
/// 编辑区里是「标题 + 2px 下划线」，当前那一页用下划线标出来，而不是填一块
/// 底色：填色会把标签条变成一排按钮，下划线只说明一件事，还让整条保持平坦。
///
/// 侧边栏里传了 [icon]，画成一颗方块按钮（和顶栏的面板开关同一套量法）：
/// 一排视图用图标说话，比「文件 ×」这种文字页省地方，也更像一列开关。
class PaneTab extends StatefulWidget {
  const PaneTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    this.icon,
    this.tooltip,
    this.compact = false,
    this.focused = true,
    this.onSecondaryTapDown,
  });

  final String label;
  final bool active;

  /// 有它就是图标页（侧边栏）；[label] 只挂在 tooltip 和拖起来的影子上。
  final IconData? icon;

  /// tooltip 上写什么；不传用 [label]。
  final String? tooltip;

  /// 图标页的紧凑版：28 的方块、不占右缝（右栏顶上那三颗）。
  final bool compact;

  /// 所在格子是不是聚焦的那一格。不聚焦时文字页的下划线退成中性色，
  /// 图标页的方块退成纸面的颜色。
  final bool focused;

  final VoidCallback onTap;
  final VoidCallback onClose;

  /// 右键：把按下点交给调用方去弹菜单。
  final ValueChanged<Offset>? onSecondaryTapDown;

  @override
  State<PaneTab> createState() => _PaneTabState();
}

class _PaneTabState extends State<PaneTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Widget tab = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapDown: widget.onSecondaryTapDown == null
            ? null
            : (TapDownDetails d) =>
                  widget.onSecondaryTapDown!(d.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: widget.icon == null ? _textTab(p) : _iconTab(p),
      ),
    );
    if (widget.icon == null) return tab;
    // 名字从标签上收进 tooltip：一颗方块只够说一个词。
    return Tooltip(
      message: widget.tooltip ?? widget.label,
      waitDuration: const Duration(milliseconds: 600),
      child: tab,
    );
  }

  /// 编辑区的文字页。
  Widget _textTab(AppPalette p) {
    final Color background = widget.active
        ? p.surface
        : (_hovered
              ? p.surfaceRaised.withValues(alpha: 0.6)
              : Colors.transparent);

    return AnimatedContainer(
      duration: AppMotion.fast,
      height: AppLayout.paneTabHeight,
      margin: const EdgeInsets.only(right: 2),
      constraints: const BoxConstraints(maxWidth: 180),
      decoration: BoxDecoration(
        color: background,
        // 只有上面两个角是圆的：下沿是纸面的边，圆了就把标签从它所属的
        // 那一面上抬起来了。
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.md),
        ),
      ),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.label,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                      fontWeight: widget.active
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: widget.active ? p.textPrimary : p.textSecondary,
                    ),
                  ),
                ),
                // 永远排版、只偶尔可见：用 `Opacity` 藏起来，每一页的宽
                // 度才不会在指针扫过时跳。`IgnorePointer` 保证看不见的
                // × 点不中。
                const SizedBox(width: 4),
                IgnorePointer(
                  ignoring: !(widget.active || _hovered),
                  child: Opacity(
                    opacity: widget.active || _hovered ? 1 : 0,
                    child: _TabCloseButton(onPressed: widget.onClose),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 8,
            right: 8,
            bottom: 0,
            child: AnimatedOpacity(
              duration: AppMotion.fast,
              opacity: widget.active ? 1 : 0,
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  color: widget.focused ? p.accent : p.outline,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 侧边栏的图标页：32 的方块，选中填 `accentSoft`。
  ///
  /// 还是**一页**：能拖、能分屏、右键能关，只是不再画标题和下划线。没聚焦的
  /// 那一格退成纸面的颜色——两格并排时，当前视图照样看得见，但谁在听键盘
  /// 也分得清。
  Widget _iconTab(AppPalette p) {
    final Color background = widget.active
        ? (widget.focused ? p.accentSoft : p.surface)
        : (_hovered
              ? p.surfaceRaised.withValues(alpha: 0.6)
              : Colors.transparent);
    final Color foreground = widget.active
        ? (widget.focused ? p.accent : p.textPrimary)
        : (_hovered ? p.textPrimary : p.textSecondary);

    // 紧凑版是 28 的方块、底边留 6：在 40 的带子里同样居中，但右缝交给标签条
    // 画（2px），三颗加起来才刚好是顶栏那组开关的 88 宽。
    return AnimatedContainer(
      duration: AppMotion.fast,
      width: widget.compact ? 28 : 32,
      height: widget.compact ? 28 : 32,
      margin: widget.compact
          ? const EdgeInsets.only(bottom: 6)
          : const EdgeInsets.only(right: 4, bottom: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.mdAll,
      ),
      child: Icon(widget.icon, size: AppIconSize.sm, color: foreground),
    );
  }
}

/// 让一页标签能被拖进别的格子（或者拖到格子边上再切一格）。
///
/// 点还是点（拖拽要先超过 touch slop 才会赢下手势竞争），所以「点一下切过去」
/// 一点没变。
///
/// ⛔ `dragAnchorStrategy` 必须用 [pointerDragAnchorStrategy]：默认的
/// [childDragAnchorStrategy] 会让 `DragTargetDetails.offset` 变成「指针 −
/// 指针在标签内的位置」，落点整体偏一截，格子边上那 28% 就判不准了。
/// 同理 `feedbackOffset` 只能留零——它还会把**命中测试点**一起挪走。
class DraggableTab extends StatelessWidget {
  const DraggableTab({super.key, required this.data, required this.child});

  final TabDrag data;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Draggable<TabDrag>(
      data: data,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Transform.translate(
        offset: const Offset(-26, -14),
        child: _TabGhost(label: data.label),
      ),
      child: child,
    );
  }
}

/// 拖起来时跟着指针的那枚小标签。
class _TabGhost extends StatelessWidget {
  const _TabGhost({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 180),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.sm,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          color: p.surfaceRaised,
          border: Border.all(color: p.accent),
          borderRadius: AppRadius.mdAll,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppText.label,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
            color: p.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _TabCloseButton extends StatefulWidget {
  const _TabCloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_TabCloseButton> createState() => _TabCloseButtonState();
}

class _TabCloseButtonState extends State<_TabCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Tooltip(
      // 一格里可能排着好几页，所以这句要能配上那一页的 key 用。
      message: '关闭这一页',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceSunken : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
            child: Icon(
              LucideIcons.x,
              size: AppIconSize.xs - 2,
              color: _hovered ? p.textPrimary : p.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}
