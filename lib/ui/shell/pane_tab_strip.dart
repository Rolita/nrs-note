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
    this.onNewTab,
    this.filler,
    this.trailingInset = 0,
  });

  final List<PaneTabData> tabs;

  /// 当前那一页的下标。
  final int index;

  /// 这一格是不是聚焦的那一格。只影响下划线的颜色——**每一格都要标出自己
  /// 的当前页**，否则分屏之后不知道另一格在干什么。
  final bool focused;

  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;

  /// 末尾那颗「新建笔记」。侧边栏不传——它没有「新建一个视图」这回事。
  final VoidCallback? onNewTab;

  /// 标签条上没被标签占住的那一段交给它——桌面端在这儿放「拖窗口」。
  ///
  /// 它压在标签**底下**：点在标签上算标签，点空白处才算拖窗口。
  final Widget? filler;

  /// 右端要让给浮在标签条上面的那几颗按钮的宽度（面板开关 + 窗口按钮）。
  final double trailingInset;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: AppLayout.paneTabStripHeight,
      // 标签条是壳子的一部分：和功能栏、侧边栏同一种底色。
      color: p.canvas,
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
                      // 标签挂在下沿：当前那一页的下划线要和格子里的纸面接上。
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            for (int i = 0; i < tabs.length; i++)
                              Flexible(
                                child: DraggableTab(
                                  data: tabs[i].drag,
                                  child: PaneTab(
                                    key: tabs[i].key,
                                    label: tabs[i].label,
                                    active: i == index,
                                    focused: focused,
                                    onTap: () => onSelect(i),
                                    onClose: () => onClose(i),
                                    onSecondaryTapDown: tabs[i].onSecondaryTap,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (onNewTab != null) _NewTabButton(onPressed: onNewTab!),
                ],
              ),
            ),
          ),
        ],
      ),
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
    this.onSecondaryTap,
  });

  /// 给测试认这一页用的。
  final Key? key;

  final String label;

  /// 拖出去时拎在手上的东西。编辑区是 [DocDrag]，侧边栏是 [ViewDrag]。
  final TabDrag drag;

  /// 右键这一页（只给侧边栏用：在那儿「上 / 下分屏」）。
  final void Function(Offset at)? onSecondaryTap;
}

/// 标签条上的一页。
///
/// 当前那一页用一条 2px 下划线标出来，而不是填一块底色：填色会把标签条变成
/// 一排按钮，下划线只说明一件事，还让整条保持平坦。
class PaneTab extends StatefulWidget {
  const PaneTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    this.focused = true,
    this.onSecondaryTapDown,
  });

  final String label;
  final bool active;

  /// 所在格子是不是聚焦的那一格。不聚焦时下划线退成中性色。
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
    final Color background = widget.active
        ? p.surface
        : (_hovered
              ? p.surfaceRaised.withValues(alpha: 0.6)
              : Colors.transparent);

    return MouseRegion(
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
        child: AnimatedContainer(
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
                          color: widget.active
                              ? p.textPrimary
                              : p.textSecondary,
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
        ),
      ),
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

/// 标签条末尾那颗「新建笔记」。
class _NewTabButton extends StatefulWidget {
  const _NewTabButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_NewTabButton> createState() => _NewTabButtonState();
}

class _NewTabButtonState extends State<_NewTabButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Tooltip(
      // 刻意不叫「新建笔记 · Ctrl+N」：同一窗口里两个一样的 tooltip 会让
      // `find.byTooltip` 和用户一起猜。
      message: '新建笔记',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(left: 2, right: 4, bottom: 2),
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceRaised : Colors.transparent,
              borderRadius: AppRadius.mdAll,
            ),
            child: Icon(
              LucideIcons.plus,
              size: AppIconSize.sm,
              color: _hovered ? p.textPrimary : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
