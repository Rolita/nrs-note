import 'package:flutter/material.dart';

import '../../core/theme/app_tokens.dart';
import 'title_bar_content.dart';

/// Browser build: the same regions as the desktop strip — the sidebar toggle,
/// the right-sidebar toggle and the panel tabs — minus the window buttons,
/// because a page cannot minimize, maximize or drag its own window.
///
/// 和桌面端一样，这不是一条横带：标签条顶在页面最上面，这一层只是浮在它上面
/// 的几颗按钮（见 [TitleBarLayout]）。
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    required this.onToggleSidebar,
    required this.rightInset,
    this.showSidebarToggle = true,
    this.showRightToggle = false,
    this.onToggleRight,
  });

  final VoidCallback onToggleSidebar;
  final double rightInset;
  final bool showSidebarToggle;
  final bool showRightToggle;
  final VoidCallback? onToggleRight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppLayout.titleBarHeight,
      child: TitleBarLayout(
        onToggleSidebar: onToggleSidebar,
        showSidebarToggle: showSidebarToggle,
        rightInset: rightInset,
        showRightToggle: showRightToggle,
        onToggleRight: onToggleRight,
        captionWidth: 0,
      ),
    );
  }
}

/// 标签条上没被标签占住的那一段。浏览器里没有窗口可拖，留空。
Widget titleBarGrip() => const SizedBox.expand();
