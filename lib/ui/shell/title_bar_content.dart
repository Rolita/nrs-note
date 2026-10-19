import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';

/// Width of the three leading buttons plus their gaps, measured rather than
/// Width of the leading buttons plus their gaps, measured rather than guessed.
///
/// Expanded: 4 (left pad) + 32 (collapse) + 17 (divider) + 32 (files) +
/// 32 (search) + 8 (right pad) = 125.
///
/// Collapsed: the view buttons are gone with the panel they point at, so only
/// the toggle is left — 4 + 32 + 8 = 44. The tab strip may never start left of
/// this, otherwise it would slide under the buttons.
const double _kLeadingWidth = 125;
const double _kLeadingCollapsedWidth = 44;

const double _kBarButtonSize = 30;

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
        const SizedBox(width: AppSpace.xs),
        _BarButton(
          icon: collapsed
              ? Icons.keyboard_double_arrow_right_rounded
              : Icons.keyboard_double_arrow_left_rounded,
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
          _BarButton(
            icon: SidebarView.search.icon,
            tooltip: SidebarView.search.label,
            selected: view == SidebarView.search,
            onPressed: () => onSelectView(SidebarView.search),
          ),
        ],
        const SizedBox(width: AppSpace.sm),
      ],
    );

    final Widget outlineButton = _BarButton(
      icon: Icons.account_tree_outlined,
      tooltip: '大纲',
      shortcut: 'Ctrl+Shift+O',
      selected: settings.outlineVisible,
      // Positioned by hand, so it must not carry the 1px side margin the row
      // buttons use to keep their hover squares apart.
      margin: 0,
      onPressed: () => settings.outlineVisible = !settings.outlineVisible,
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
        // The outline button sits *on* the outline's left edge; when there is no
        // outline to align with it parks against the caption buttons instead.
        final double outlineLeft = math
            .min(width - rightInset, width - captionWidth - _kBarButtonSize)
            .clamp(0.0, math.max(0.0, width - captionWidth - _kBarButtonSize));
        // The tab strip may grow up to the outline button, and no further.
        final double tabsRight = math.max(
          rightInset,
          captionWidth + _kBarButtonSize,
        );

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
            Positioned(
              left: outlineLeft,
              width: _kBarButtonSize,
              top: 0,
              bottom: 0,
              child: Center(child: outlineButton),
            ),
            Positioned(
              left: tabsLeft,
              right: tabsRight,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerLeft,
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
                                  note: note,
                                  active: note.id == notes.selectedId,
                                  onTap: () => notes.select(note.id),
                                  onClose: () => notes.closeTab(note.id),
                                ),
                              ),
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

/// A 30×30 icon button, sized for the 36px strip.
class _BarButton extends StatefulWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.shortcut,
    this.margin = 1,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool selected;
  final String? shortcut;

  /// Horizontal breathing room around the hover square. Zero when the button is
  /// positioned by hand and must sit exactly on a seam.
  final double margin;

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
            width: _kBarButtonSize,
            height: _kBarButtonSize,
            margin: EdgeInsets.symmetric(horizontal: widget.margin),
            decoration: BoxDecoration(
              color: background,
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(widget.icon, size: 16, color: foreground),
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
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      color: context.palette.outlineSoft,
    );
  }
}

/// One open note.
///
/// Width is content-driven up to 168px; when the strip runs out of room the
/// [Flexible] around it shrinks the tab instead of pushing it under the
/// outline button.
class _TitleTab extends StatefulWidget {
  const _TitleTab({
    super.key,
    required this.note,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  final Note note;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_TitleTab> createState() => _TitleTabState();
}

class _TitleTabState extends State<_TitleTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String title = widget.note.title.trim().isEmpty
        ? '未命名'
        : widget.note.title.trim();
    final Color background = widget.active
        ? p.surfaceRaised
        : (_hovered ? p.surfaceRaised.withValues(alpha: 0.55) : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          height: 28,
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.only(left: 10, right: 3),
          constraints: const BoxConstraints(maxWidth: 168),
          decoration: BoxDecoration(
            color: background,
            borderRadius: AppRadius.smAll,
            border: Border.all(
              color: widget.active ? p.outline : Colors.transparent,
            ),
          ),
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
                    color: widget.active ? p.textPrimary : p.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              // Always laid out, only sometimes visible: hiding it with
              // `Opacity` keeps every tab the same width on hover, so the strip
              // does not twitch as the pointer sweeps across it. `IgnorePointer`
              // then makes sure an invisible × cannot be clicked by accident.
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
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 12,
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
            width: 26,
            height: 26,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceRaised : Colors.transparent,
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(
              Icons.add_rounded,
              size: 16,
              color: _hovered ? p.textPrimary : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
