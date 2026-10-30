import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../state/settings_controller.dart';
import 'main_view.dart';

const double _kBarButtonSize = 32;

/// 一个窗口按钮的宽度。44 是 Windows 的标题栏度量，落在外壳的 4px 网格上。
const double kCaptionButtonWidth = 44;

/// 三个窗口按钮加起来。
const double kCaptionWidth = kCaptionButtonWidth * 3;

/// 右侧那三颗面板开关（大纲 / 表格 / 图片）的尺寸。
///
/// 比左边那颗侧栏开关小一号：它们三个要挤在「面板左缘 → 窗口按钮」之间那一段
/// 里，三个 28 加两道 2px 缝是 88，而大纲栏最窄时那一段只有 100——再大就会被
/// 夹得往左偏出面板，看起来就是「按钮没和面板对齐」。
const double kPanelToggleSize = 28;
const double kPanelToggleGap = 2;
const double kPanelTogglesWidth = kPanelToggleSize * 3 + kPanelToggleGap * 2;

/// 右端那一坨的总宽：三颗面板开关 + 三个窗口按钮。
///
/// 面板收起来的时候它们全落在窗口右边缘上，正好压住最右边那一格的标签条尾巴
/// ——所以标签条要按这个宽度留出 `trailingInset`。
const double kTitleBarRightWidth = kPanelTogglesWidth + kCaptionWidth;

/// 窗口顶上那条带子里的按钮，除了 OS 自己画的三个窗口按钮。
///
/// ⛔ **这里不是一条 40px 的横带，而是一层浮在标签条上的按钮。**
///
/// 用户原话：「让 tab 还是在顶部栏显示啊。为什么往下移了？」——顶栏和标签条
/// 本来就是同一条带子：标签条顶到窗口最上面，顶栏的按钮浮在它上面。多压一条
/// 空带子只会让标签看起来被推下去了。
///
/// 所以它只画两小坨：左上角那颗侧栏开关（正好落在功能栏顶上），右上角的三颗
/// 面板开关 + 三个窗口按钮。**中间是空的**，鼠标穿过去就是下面的标签条——
/// `Stack` 没有自己的命中区域，没点中按钮就等于没点中这一层。
///
/// 拖窗口的手势不在这儿：它跟着搬进标签条没被标签占住的那一段
/// （`PaneTabStrip.filler`），否则这层空区域会吃掉标签的拖拽。
class TitleBarLayout extends StatelessWidget {
  const TitleBarLayout({
    super.key,
    required this.onToggleSidebar,
    required this.mainView,
    required this.rightInset,
    this.showSidebarToggle = true,
    this.caption = const <Widget>[],
    this.captionWidth = kCaptionWidth,
  });

  final VoidCallback onToggleSidebar;

  /// 聚焦那一格显示的是笔记还是图谱——决定右侧三颗开关要不要出现。
  final MainView mainView;

  /// Distance from the window's right edge to the outline's left edge. Zero
  /// when the outline is hidden or too narrow to show.
  final double rightInset;

  /// 功能栏藏起来时（专注模式）没有地方搁这颗开关，它也就不画了——画了会
  /// 盖在第一格的标签上。
  final bool showSidebarToggle;

  /// Minimize / maximize / close, or nothing in the browser.
  final List<Widget> caption;

  /// Combined width of [caption]; the outline button must not slide under it.
  final double captionWidth;

  @override
  Widget build(BuildContext context) {
    final SettingsController settings = context.watch<SettingsController>();
    final bool collapsed = settings.sidebarCollapsed;

    // 图谱和图片里右侧那一栏是收起来的，三颗开关也就没有可指向的面板了——
    // 留着能点但什么都不发生，比不显示更让人困惑。
    final bool showPanelToggles =
        mainView != MainView.graph && mainView != MainView.image;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        // Three toggles, one seam: they sit on the left edge of whichever panel
        // is open, so the row lines up with the panel below instead of drifting.
        final double pairWidth = showPanelToggles ? kPanelTogglesWidth : 0;
        final double pairLeft = math
            .min(width - rightInset, width - captionWidth - pairWidth)
            .clamp(0.0, math.max(0.0, width - captionWidth - pairWidth));

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
            if (showPanelToggles)
              Positioned(
                left: pairLeft,
                width: pairWidth,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _BarButton(
                        icon: LucideIcons.listTree,
                        tooltip: '大纲',
                        shortcut: 'Ctrl+Shift+O',
                        size: kPanelToggleSize,
                        selected: settings.outlineVisible,
                        onPressed: () =>
                            settings.outlineVisible = !settings.outlineVisible,
                      ),
                      const SizedBox(width: kPanelToggleGap),
                      _BarButton(
                        icon: LucideIcons.table,
                        tooltip: '表格',
                        size: kPanelToggleSize,
                        selected: settings.tablePanelVisible,
                        onPressed: () => settings.tablePanelVisible =
                            !settings.tablePanelVisible,
                      ),
                      const SizedBox(width: kPanelToggleGap),
                      _BarButton(
                        icon: LucideIcons.image,
                        tooltip: '图片',
                        size: kPanelToggleSize,
                        selected: settings.imagePanelVisible,
                        onPressed: () => settings.imagePanelVisible =
                            !settings.imagePanelVisible,
                      ),
                    ],
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

/// A 32×32 icon button, sized for the 40px strip. The panel toggles ask for the
/// smaller [kPanelToggleSize] so three of them still line up with the panel.
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.shortcut,
    this.size = _kBarButtonSize,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;
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
