import 'package:flutter/material.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'main_view.dart';
import 'title_bar_content.dart';

/// Browser build: same three regions as the desktop strip — views, tabs,
/// outline — minus the window buttons, because a page cannot minimize,
/// maximize or drag its own window.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    required this.view,
    required this.onSelectView,
    required this.onToggleSidebar,
    required this.onCreateNote,
    required this.mainView,
    required this.onSelectMainView,
    required this.graphOpen,
    required this.onCloseGraph,
    required this.leftInset,
    required this.rightInset,
  });

  final SidebarView view;
  final ValueChanged<SidebarView> onSelectView;
  final VoidCallback onToggleSidebar;
  final VoidCallback onCreateNote;
  final MainView mainView;
  final ValueChanged<MainView> onSelectMainView;
  final bool graphOpen;
  final VoidCallback onCloseGraph;
  final double leftInset;
  final double rightInset;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: AppLayout.titleBarHeight,
      decoration: BoxDecoration(
        color: p.canvas,
        border: Border(bottom: BorderSide(color: p.outlineSoft)),
      ),
      child: TitleBarLayout(
        view: view,
        onSelectView: onSelectView,
        onToggleSidebar: onToggleSidebar,
        onCreateNote: onCreateNote,
        mainView: mainView,
        onSelectMainView: onSelectMainView,
        graphOpen: graphOpen,
        onCloseGraph: onCloseGraph,
        leftInset: leftInset,
        rightInset: rightInset,
        // No window to drag in a tab.
        grip: const SizedBox.expand(),
      ),
    );
  }
}
