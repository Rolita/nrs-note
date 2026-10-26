import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import 'main_view.dart';

/// Width of the leading buttons plus their gaps, measured rather than guessed.
///
/// Expanded: 6 (left pad) + 32 (collapse) + 13 (divider) + 32 (files) +
/// 4 (gap) + 32 (search) + 6 (right pad) = 125.
///
/// Collapsed: the view buttons are gone with the panel they point at, so only
/// the toggle is left — 6 + 32 + 6 = 44, which is exactly [AppLayout.railWidth].
/// That equality is the point: collapsed, the tab strip starts on the editor's
/// left edge with nothing between them.
const double _kLeadingWidth = 125;
const double _kLeadingCollapsedWidth = 44;

const double _kBarButtonSize = 32;

/// 右侧那三颗面板开关（大纲 / 表格 / 图片）的尺寸。
///
/// 比左侧的按钮小一号：它们三个要挤在「面板左缘 → 窗口按钮」之间那一段里，
/// 三个 32 加两道 4px 缝是 104，而大纲栏最窄时那一段只有 100——差 4px 就会被
/// 夹得往左偏出面板，看起来就是「按钮没和面板对齐」。
const double _kPanelToggleSize = 28;
const double _kPanelToggleGap = 2;

/// Everything inside the title bar except the OS caption buttons.
///
/// Three regions, and the two inner edges are *aligned with the panes below*:
///
///  * the tabs start at [leftInset] — the editor's left edge, so a tab sits
///    exactly above the column it opens;
///  * the outline toggle sits at [rightInset] from the right edge — the
///    outline's left edge, so the button and the panel share one vertical line;
///  * the views — collapse, plus files and search while the sidebar is open —
///    stay pinned to the far left, where the rail used to be.
///
/// The strip is drawn as a [Stack] because those two alignments are absolute
/// positions that no `Row` can express: the buttons and the tabs do not share
/// a layout axis, they share a pixel column.
class TitleBarLayout extends StatelessWidget {
  const TitleBarLayout({
    super.key,
    required this.view,
    required this.onSelectView,
    required this.onToggleSidebar,
    required this.onCreateNote,
    required this.mainView,
    required this.onSelectMainView,
    required this.grip,
    required this.leftInset,
    required this.rightInset,
    this.caption = const <Widget>[],
    this.captionWidth = 0,
  });

  final SidebarView view;
  final ValueChanged<SidebarView> onSelectView;
  final VoidCallback onToggleSidebar;
  final VoidCallback onCreateNote;

  /// Whether the pane under the tabs shows a note or the graph.
  final MainView mainView;
  final ValueChanged<MainView> onSelectMainView;

  /// The window's drag surface. Handed in rather than created here because only
  /// the desktop build may talk to `window_manager`.
  final Widget grip;

  /// Distance from the window's left edge to the editor, i.e. rail + sidebar +
  /// their resize handle. Zero in focus mode.
  final double leftInset;

  /// Distance from the window's right edge to the outline's left edge. Zero
  /// when the outline is hidden or too narrow to show.
  final double rightInset;

  /// Minimize / maximize / close, or nothing in the browser.
  final List<Widget> caption;

  /// Combined width of [caption]; the outline button must not slide under it.
  final double captionWidth;

  @override
  Widget build(BuildContext context) {
    final SettingsController settings = context.watch<SettingsController>();
    final NotesController notes = context.watch<NotesController>();
    final List<Note> open = notes.openNotes;
    final bool collapsed = settings.sidebarCollapsed;

    final Widget leading = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(width: 6),
        _BarButton(
          icon: collapsed
              ? LucideIcons.chevronsRight
              : LucideIcons.chevronsLeft,
          tooltip: collapsed ? '展开侧边栏' : '收起侧边栏',
          shortcut: 'Ctrl+\\',
          onPressed: onToggleSidebar,
        ),
        // The two view buttons go away with the panel they switch: with the
        // sidebar collapsed there is nothing on screen for them to point at,
        // and leaving them out is what lets the tabs start at the editor's edge
        // instead of 80px to the right of it.
        if (!collapsed) ...<Widget>[
          const _BarDivider(),
          _BarButton(
            icon: SidebarView.files.icon,
            tooltip: SidebarView.files.label,
            selected: view == SidebarView.files,
            onPressed: () => onSelectView(SidebarView.files),
          ),
          const SizedBox(width: AppSpace.xs),
          _BarButton(
            icon: SidebarView.search.icon,
            tooltip: SidebarView.search.label,
            selected: view == SidebarView.search,
            onPressed: () => onSelectView(SidebarView.search),
          ),
        ],
        const SizedBox(width: 6),
      ],
    );

    // 图谱里右侧那一栏是收起来的，三颗开关也就没有可指向的面板了——
    // 留着能点但什么都不发生，比不显示更让人困惑。
    final bool showPanelToggles = mainView != MainView.graph;

    final Widget outlineButton = _BarButton(
      icon: LucideIcons.listTree,
      tooltip: '大纲',
      shortcut: 'Ctrl+Shift+O',
      size: _kPanelToggleSize,
      selected: settings.outlineVisible,
      onPressed: () => settings.outlineVisible = !settings.outlineVisible,
    );

    // 大纲、表格、图片共用右侧那一栏，互斥关系由 SettingsController 保证。
    final Widget tableButton = _BarButton(
      icon: LucideIcons.table,
      tooltip: '表格',
      size: _kPanelToggleSize,
      selected: settings.tablePanelVisible,
      onPressed: () => settings.tablePanelVisible = !settings.tablePanelVisible,
    );

    final Widget imageButton = _BarButton(
      icon: LucideIcons.image,
      tooltip: '图片',
      size: _kPanelToggleSize,
      selected: settings.imagePanelVisible,
      onPressed: () => settings.imagePanelVisible = !settings.imagePanelVisible,
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double width = c.maxWidth;
        // Never left of the leading buttons: with the sidebar collapsed the
        // editor starts at the rail, but the tabs cannot go there.
        final double tabsLeft = math.max(
          leftInset,
          collapsed ? _kLeadingCollapsedWidth : _kLeadingWidth,
        );
        // Three toggles, one seam: they sit on the left edge of whichever panel
        // is open, so the row lines up with the panel below instead of drifting.
        final double pairWidth = showPanelToggles
            ? _kPanelToggleSize * 3 + _kPanelToggleGap * 2
            : 0;
        final double pairLeft = math
            .min(width - rightInset, width - captionWidth - pairWidth)
            .clamp(0.0, math.max(0.0, width - captionWidth - pairWidth));
        // The tab strip may grow up to the toggles, and no further.
        final double tabsRight = math.max(rightInset, captionWidth + pairWidth);

        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: Row(
                children: <Widget>[
                  leading,
                  Expanded(child: grip),
                  ...caption,
                ],
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
                      outlineButton,
                      const SizedBox(width: _kPanelToggleGap),
                      tableButton,
                      const SizedBox(width: _kPanelToggleGap),
                      imageButton,
                    ],
                  ),
                ),
              ),
            Positioned(
              left: tabsLeft,
              right: tabsRight,
              top: 0,
              bottom: 0,
              child: Align(
                // Tabs hang from the bottom of the bar so the active one can
                // meet the editor's surface with its 2px underline; centring
                // them left the underline floating in the middle of the strip.
                alignment: Alignment.bottomLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: ClipRect(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            for (final Note note in open)
                              Flexible(
                                child: _TitleTab(
                                  key: ValueKey<String>(note.id),
                                  label: note.title.trim().isEmpty
                                      ? '未命名'
                                      : note.title.trim(),
                                  active:
                                      mainView == MainView.note &&
                                      note.id == notes.selectedId,
                                  onTap: () {
                                    notes.select(note.id);
                                    onSelectMainView(MainView.note);
                                  },
                                  onClose: () => notes.closeTab(note.id),
                                ),
                              ),
                            // 图谱和白板曾经也钉在这里，但它们不是文档、没有
                            // ×，占着标签条只会让真正的笔记标签被挤窄。现在
                            // 两个入口都在左侧功能栏（见 AppRail）。
                          ],
                        ),
                      ),
                    ),
                    _NewTabButton(onPressed: onCreateNote),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A 32×32 icon button, sized for the 40px strip. The panel toggles ask for the
/// smaller [_kPanelToggleSize] so three of them still line up with the panel.
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

class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: context.palette.outline,
    );
  }
}

/// One tab in the strip: either an open note, or the graph view.
///
/// The active tab is marked by a 2px underline that meets the editor's surface,
/// not by a filled block: a block turns the strip into a row of buttons, while
/// an underline keeps the bar flat and still says exactly one thing.
///
/// Width is content-driven up to 180px; when the strip runs out of room the
/// [Flexible] around it shrinks the tab instead of pushing it under the
/// outline button.
class _TitleTab extends StatefulWidget {
  const _TitleTab({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.onClose,
  });

  final String label;

  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  @override
  State<_TitleTab> createState() => _TitleTabState();
}

class _TitleTabState extends State<_TitleTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String title = widget.label;
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
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          height: 32,
          margin: const EdgeInsets.only(right: 2),
          constraints: const BoxConstraints(maxWidth: 180),
          decoration: BoxDecoration(
            color: background,
            // Only the top corners: the bottom edge is the editor's edge, and
            // rounding it would lift the tab off the surface it belongs to.
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadius.md),
            ),
          ),
          child: Stack(
            // Centred, not top-aligned: the stack is what carries the underline,
            // so without this the label would ride the tab's top edge.
            alignment: Alignment.centerLeft,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        title,
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
                    // Always laid out, only sometimes visible: hiding it with
                    // `Opacity` keeps every tab the same width on hover, so the
                    // strip does not twitch as the pointer sweeps across it.
                    // `IgnorePointer` then makes sure an invisible × cannot be
                    // clicked by accident.
                    if (widget.onClose != null) ...<Widget>[
                      const SizedBox(width: 4),
                      IgnorePointer(
                        ignoring: !(widget.active || _hovered),
                        child: Opacity(
                          opacity: widget.active || _hovered ? 1 : 0,
                          child: _TabCloseButton(onPressed: widget.onClose!),
                        ),
                      ),
                    ],
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
                      color: p.accent,
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
    return MouseRegion(
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
    );
  }
}

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
      // Deliberately not the file toolbar's "新建笔记 · Ctrl+N": two identical
      // tooltips in one window make `find.byTooltip` — and the user — guess.
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
            // Nudged up 2px so its centre matches the 32px tabs it sits beside
            // rather than hanging below them.
            margin: const EdgeInsets.only(left: 2, bottom: 2),
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
