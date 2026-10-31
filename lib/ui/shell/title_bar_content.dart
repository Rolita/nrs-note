import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../state/settings_controller.dart';

const double _kBarButtonSize = 28;

/// 一个窗口按钮的宽度。44 是 Windows 的标题栏度量，落在外壳的 4px 网格上。
const double kCaptionButtonWidth = 44;

/// 三个窗口按钮加起来。
const double kCaptionWidth = kCaptionButtonWidth * 3;

/// 顶栏按钮之间的缝。
const double kBarButtonGap = 2;

/// 收 / 展右侧边栏那颗按钮，以及它占的槽。
///
/// 它住在编辑区顶端的**右缘**：右栏开着时贴着右栏左缘，收起时贴着三个窗口
/// 按钮的左缘——也就是以前标签条末尾「新建笔记」的位置。用户原话：「这个按钮
/// 不再属于编辑栏的按钮，是属于右侧边栏的按钮。而且固定这个位置，只有这一个。」
/// 所以它由顶栏这一层画（全局只有一颗），不跟着编辑区的格子数复制。
///
/// ⛔ 那三颗面板图标（大纲 / 表格 / 图片）**不归顶栏**：它们是右栏上格自己的
/// 标签页，右栏收起时就跟着一起走。用户原话：「收起右侧边栏后不要显示图标了，
/// 因为这三个图标是属于右侧边栏的一部分，应该一起收起。」收起后还挂一排固定
/// 的三颗也是错的——页早就可以在两侧边栏之间搬来搬去了。
const double kRightSidebarToggleSize = 28;
const double kRightSidebarToggleSlot =
    kRightSidebarToggleSize + kBarButtonGap * 2;

/// 窗口顶上那条带子里的按钮，除了 OS 自己画的三个窗口按钮。
///
/// ⛔ **这里不是一条 40px 的横带，而是一层浮在标签条上的按钮。**
///
/// 用户原话：「让 tab 还是在顶部栏显示啊。为什么往下移了？」——顶栏和标签条
/// 本来就是同一条带子：标签条顶到窗口最上面，顶栏的按钮浮在它上面。多压一条
/// 空带子只会让标签看起来被推下去了。
///
/// 所以它只画两小坨：左上角那颗侧栏开关（正好落在功能栏顶上），右上角那颗
/// 右栏收 / 展按钮 + 三个窗口按钮。**中间是空的**，鼠标穿过去就是下面的标签
/// 条——`Stack` 没有自己的命中区域，没点中按钮就等于没点中这一层。
///
/// 拖窗口的手势不在这儿：它跟着搬进标签条没被标签占住的那一段
/// （`PaneTabStrip.filler`），否则这层空区域会吃掉标签的拖拽。
class TitleBarLayout extends StatelessWidget {
  const TitleBarLayout({
    super.key,
    required this.onToggleSidebar,
    required this.rightInset,
    this.showSidebarToggle = true,
    this.showRightToggle = false,
    this.onToggleRight,
    this.caption = const <Widget>[],
    this.captionWidth = kCaptionWidth,
  });

  final VoidCallback onToggleSidebar;

  /// Distance from the window's right edge to the right column's left edge.
  /// Zero when the right column is hidden or too narrow to show.
  final double rightInset;

  /// 功能栏藏起来时（专注模式）没有地方搁这颗开关，它也就不画了——画了会
  /// 盖在第一格的标签上。
  final bool showSidebarToggle;

  /// 要不要画右侧边栏那颗收 / 展按钮。
  ///
  /// 图谱 / 图片里右栏整列不出现（那两块要整块画布），按钮也就没有可指向的
  /// 东西；窗口窄到容不下右栏时同理。
  final bool showRightToggle;

  final VoidCallback? onToggleRight;

  /// Minimize / maximize / close, or nothing in the browser.
  final List<Widget> caption;

  /// Combined width of [caption]; the outline button must not slide under it.
  final double captionWidth;

  @override
  Widget build(BuildContext context) {
    final SettingsController settings = context.watch<SettingsController>();
    final bool collapsed = settings.sidebarCollapsed;
    // 右栏开着时，右端那一坨从右栏左缘开始算；收起时从窗口按钮左缘开始算。
    final bool rightOpen = rightInset > 0;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        // 右栏的收 / 展按钮就住在右栏的左邻：右栏开着时贴右栏左缘，收起时
        // 贴三个窗口按钮的左缘。两种情况下都只隔一道 2px 的缝。它是右栏的，
        // 不是编辑栏的，也是顶栏右端唯一的一颗（面板图标都在右栏里）。
        final bool drawRightToggle = showRightToggle && onToggleRight != null;
        final double rightToggleLeft = math.max(
          0.0,
          width -
              (rightOpen ? rightInset : captionWidth) -
              kRightSidebarToggleSlot,
        );

        return Stack(
          children: <Widget>[
            if (showSidebarToggle)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: AppLayout.railWidth,
                child: Center(
                  child: _BarButton(
                    icon: collapsed
                        ? LucideIcons.chevronsRight
                        : LucideIcons.chevronsLeft,
                    tooltip: collapsed ? '展开侧边栏' : '收起侧边栏',
                    shortcut: 'Ctrl+\\',
                    onPressed: onToggleSidebar,
                  ),
                ),
              ),
            if (drawRightToggle)
              Positioned(
                left: rightToggleLeft,
                width: kRightSidebarToggleSlot,
                top: 0,
                bottom: 0,
                child: Center(
                  child: _BarButton(
                    icon: rightOpen
                        ? LucideIcons.chevronsRight
                        : LucideIcons.chevronsLeft,
                    tooltip: rightOpen ? '收起右侧边栏' : '展开右侧边栏',
                    size: kRightSidebarToggleSize,
                    onPressed: onToggleRight!,
                  ),
                ),
              ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Row(mainAxisSize: MainAxisSize.min, children: caption),
            ),
          ],
        );
      },
    );
  }
}

/// A 28×28 icon button, the one square every icon in the top band uses. The
/// right-sidebar toggle keeps the same size; its slot is 32 so it leaves a 2px
/// gap to the column and to the window buttons.
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.shortcut,
    this.size = _kBarButtonSize,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final String? shortcut;
  final double size;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color background = _hovered ? p.surfaceRaised : Colors.transparent;
    final Color foreground = _hovered ? p.textPrimary : p.textTertiary;

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
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: background,
              borderRadius: AppRadius.mdAll,
            ),
            child: Icon(widget.icon, size: AppIconSize.sm, color: foreground),
          ),
        ),
      ),
    );
  }
}
