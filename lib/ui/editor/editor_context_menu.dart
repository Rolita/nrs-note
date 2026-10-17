import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_actions.dart';

// --------------------------------------------------------------- layout rules
//
// The menu places *itself*, cascading submenus included, from these numbers
// instead of from measured intrinsics. Two reasons, both load-bearing:
//
//  * A submenu's origin is "the top of the row that spawned it", and no single
//    child's intrinsic size can answer that. Measuring would mean laying the
//    tree out twice and still risking a panel that disagrees with the row the
//    pointer is on.
//  * A fixed row height means the geometry in a test is the geometry on screen,
//    so "the submenu opens to the right of the row you hovered" can be asserted
//    rather than eyeballed.

/// Width shared by every panel — root and submenu alike.
const double kMenuPanelWidth = 226;

/// Height of one row.
const double kMenuRowHeight = 30;

/// Height of the hairline between groups: the rule plus the air around it.
const double kMenuSeparatorHeight = 9;

/// Air above the first row and below the last.
const double kMenuPanelPadding = 6;

/// Between a panel and the submenu it opened.
const double kMenuPanelGap = 3;

/// Closest any panel may come to a screen edge.
const double kMenuScreenMargin = 6;

// ------------------------------------------------------------------ the model

/// One line of the right-click menu.
sealed class MenuNode {
  const MenuNode();
}

/// A line that does something when clicked.
class MenuAction extends MenuNode {
  const MenuAction({
    required this.label,
    required this.icon,
    this.leading,
    this.shortcut,
    this.onPressed,
    this.checked = false,
  });

  final String label;

  final IconData icon;

  /// A short glyph drawn in the icon slot instead of [icon] — `H1`…`H6` read
  /// better as themselves than as six identical title marks.
  final String? leading;

  /// Right-aligned hint. Only ever set when that shortcut actually works, so
  /// the menu never teaches a key that does nothing.
  final String? shortcut;

  /// Null means "cannot be used right now" and paints the row greyed out.
  final VoidCallback? onPressed;

  /// Ticks the row — block styles use it to say "this line already is that".
  final bool checked;

  bool get enabled => onPressed != null;
}

/// A line that reveals [children] in a panel of its own, beside this one.
class MenuSubmenu extends MenuNode {
  const MenuSubmenu({
    required this.label,
    required this.icon,
    required this.children,
  });

  final String label;
  final IconData icon;
  final List<MenuNode> children;
}

/// The hairline between groups.
class MenuSeparator extends MenuNode {
  const MenuSeparator();
}

// ------------------------------------------------------------- entry points

/// The editor's right-click menu, ready to be returned from a [TextField]'s
/// `contextMenuBuilder`.
///
/// [state] is used for two things only: the anchors that say where the pointer
/// went down, and the clipboard / select-all commands, which are the platform's
/// own and must not be re-implemented here.
Widget buildEditorContextMenu({
  required EditableTextState state,
  required TextEditingValue value,
  required ValueChanged<MarkdownEditFn> onApply,
  required VoidCallback onDismiss,
}) {
  return _EditorContextMenu(
    entries: buildEditorMenu(value: value, onApply: onApply, state: state),
    anchor: state.contextMenuAnchors.primaryAnchor,
    onDismiss: onDismiss,
  );
}

/// Assembles the menu for the current caret / selection.
///
/// Split out from the widget so the *content* can be asserted on its own: which
/// rows exist, which one is ticked, which are greyed out.
List<MenuNode> buildEditorMenu({
  required TextEditingValue value,
  required ValueChanged<MarkdownEditFn> onApply,
  required EditableTextState state,
}) {
  final BlockStyle current = blockStyleOf(markerAt(value));
  final bool hasSelection = value.selection.isValid && !value.selection.isCollapsed;

  MenuAction style(String label, IconData icon, BlockStyle block, {String? shortcut}) {
    return MenuAction(
      label: label,
      icon: icon,
      shortcut: shortcut,
      checked: current == block,
      onPressed: () => onApply(applyBlockStyle(block)),
    );
  }

  return <MenuNode>[
    MenuAction(
      label: '新增链接',
      icon: Icons.link_rounded,
      onPressed: () => onApply(insertWikilink()),
    ),
    MenuAction(
      label: '新增外部链接',
      icon: Icons.open_in_new_rounded,
      shortcut: 'Ctrl+K',
      onPressed: () => onApply(insertLink()),
    ),
    const MenuSeparator(),
    MenuSubmenu(
      label: '文本格式',
      icon: Icons.text_format_rounded,
      children: <MenuNode>[
        MenuAction(
          label: '加粗',
          icon: Icons.format_bold_rounded,
          shortcut: 'Ctrl+B',
          onPressed: () => onApply(wrapSelection('**', '**')),
        ),
        MenuAction(
          label: '倾斜',
          icon: Icons.format_italic_rounded,
          shortcut: 'Ctrl+I',
          onPressed: () => onApply(wrapSelection('*', '*')),
        ),
        MenuAction(
          label: '删除线',
          icon: Icons.format_strikethrough_rounded,
          onPressed: () => onApply(wrapSelection('~~', '~~')),
        ),
        MenuAction(
          label: '高亮',
          icon: Icons.brush_rounded,
          onPressed: () => onApply(wrapSelection('==', '==', placeholder: '高亮')),
        ),
      ],
    ),
    MenuSubmenu(
      label: '段落设置',
      icon: Icons.subject_rounded,
      children: <MenuNode>[
        style('无序列表', Icons.format_list_bulleted_rounded, BlockStyle.bullet,
            shortcut: 'Ctrl+Shift+8'),
        style('有序列表', Icons.format_list_numbered_rounded, BlockStyle.ordered,
            shortcut: 'Ctrl+Shift+7'),
        style('任务列表', Icons.checklist_rounded, BlockStyle.task),
        // Not in the reference menu, but NRS has it and the old ribbon had it:
        // dropping it would quietly delete a capability.
        style('有序任务列表', Icons.checklist_rtl_rounded, BlockStyle.orderedTask),
        const MenuSeparator(),
        for (int level = 1; level <= 6; level++)
          MenuAction(
            label: '$level 级标题',
            icon: Icons.title_rounded,
            leading: 'H$level',
            shortcut: level <= 3 ? 'Ctrl+$level' : null,
            checked: current.headingLevel == level,
            onPressed: () => onApply(
              applyBlockStyle(BlockStyle.values[BlockStyle.h1.index + level - 1]),
            ),
          ),
        const MenuSeparator(),
        style('正文', Icons.format_clear_rounded, BlockStyle.paragraph, shortcut: 'Ctrl+0'),
        style('引用', Icons.format_quote_rounded, BlockStyle.quote, shortcut: 'Ctrl+Shift+Q'),
      ],
    ),
    MenuSubmenu(
      label: '插入',
      icon: Icons.add_rounded,
      children: <MenuNode>[
        MenuAction(
          label: '分割线',
          icon: Icons.horizontal_rule_rounded,
          onPressed: () => onApply(insertDivider()),
        ),
        MenuAction(
          label: '代码块',
          icon: Icons.code_off_rounded,
          shortcut: 'Ctrl+Shift+E',
          onPressed: () => onApply(codeBlock()),
        ),
      ],
    ),
    const MenuSeparator(),
    MenuAction(
      label: '剪切',
      icon: Icons.content_cut_rounded,
      shortcut: 'Ctrl+X',
      onPressed: hasSelection
          ? () => state.cutSelection(SelectionChangedCause.toolbar)
          : null,
    ),
    MenuAction(
      label: '复制',
      icon: Icons.content_copy_rounded,
      shortcut: 'Ctrl+C',
      onPressed: hasSelection
          ? () => state.copySelection(SelectionChangedCause.toolbar)
          : null,
    ),
    MenuAction(
      label: '粘贴',
      icon: Icons.content_paste_rounded,
      shortcut: 'Ctrl+V',
      onPressed: () => unawaited(pasteIntoEditor(state, plain: false)),
    ),
    MenuAction(
      label: '以纯文本形式粘贴',
      icon: Icons.content_paste_off_rounded,
      shortcut: 'Ctrl+Shift+V',
      onPressed: () => unawaited(pasteIntoEditor(state, plain: true)),
    ),
    const MenuSeparator(),
    MenuAction(
      label: '全选',
      icon: Icons.select_all_rounded,
      shortcut: 'Ctrl+A',
      onPressed: () => state.selectAll(SelectionChangedCause.toolbar),
    ),
  ];
}

/// Writes the clipboard into the field over the selection, caret after it.
///
/// [plain] is the whole difference between the two paste rows. `粘贴` hands the
/// job to the field, which also brings the caret back into view and tidies its
/// own toolbar; `以纯文本形式粘贴` reads the clipboard here and writes the
/// characters in, so it can never pick up anything but text and never depends on
/// the field's idea of whether a paste is allowed. On a plain-Markdown surface
/// the two land the same text today — keeping the second one explicit rather
/// than aliasing it is what keeps that true if the route above ever changes.
Future<void> pasteIntoEditor(EditableTextState state, {required bool plain}) async {
  if (!plain) {
    await state.pasteText(SelectionChangedCause.toolbar);
    return;
  }

  final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
  final String? text = data?.text;
  if (text == null || text.isEmpty) return;

  final TextEditingValue value = state.textEditingValue;
  final String source = value.text;
  final TextSelection selection = value.selection;
  final int a = (selection.start < 0 ? source.length : selection.start).clamp(0, source.length);
  final int b = (selection.end < 0 ? source.length : selection.end).clamp(0, source.length);
  final int from = math.min(a, b);
  final int to = math.max(a, b);
  final String next = source.replaceRange(from, to, text);

  state.userUpdateTextEditingValue(
    TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: from + text.length),
    ),
    SelectionChangedCause.toolbar,
  );
}

// ---------------------------------------------------------------- the widget

class _PanelLayout {
  const _PanelLayout({required this.rect, required this.nodes});

  final Rect rect;
  final List<MenuNode> nodes;
}

class _EditorContextMenu extends StatefulWidget {
  const _EditorContextMenu({
    required this.entries,
    required this.anchor,
    required this.onDismiss,
  });

  final List<MenuNode> entries;

  /// Where the pointer went down, in the overlay's own coordinates.
  final Offset anchor;

  final VoidCallback onDismiss;

  @override
  State<_EditorContextMenu> createState() => _EditorContextMenuState();
}

class _EditorContextMenuState extends State<_EditorContextMenu> {
  /// The chain of open submenus: `_open[i]` is the index, inside panel `i`, of
  /// the row whose submenu is showing. Empty means only the root panel is up.
  List<int> _open = const <int>[];

  // Escape is deliberately *not* handled here. It is already wired — `WidgetsApp`
  // binds it to a `DismissIntent`, which pops the menu's own route — and a
  // second handler on the raw keyboard cannot get in front of that: the return
  // value of a `HardwareKeyboard` handler only orders the handlers, it does not
  // stop the event reaching the focus tree. Backing out one panel at a time
  // would mean taking focus off the field, and the field has to keep it: the
  // caret, the selection colour and the clipboard rows all depend on it.

  /// The first [level] entries of the open chain — always a fresh growable list,
  /// because every caller goes on to push an entry onto it. (Handing back
  /// `_open` itself when it is already short enough is what made the very first
  /// click on a submenu throw: `_open` starts as a `const []`.)
  List<int> _prefix(int level) {
    final int n = math.min(level, _open.length);
    return <int>[for (int i = 0; i < n; i++) _open[i]];
  }

  void _hover(int level, int index, MenuNode node) {
    final List<int> next = _prefix(level);
    if (node is MenuSubmenu) next.add(index);
    if (_samePath(next, _open)) return;
    setState(() => _open = next);
  }

  void _tap(int level, int index, MenuNode node) {
    if (node is MenuSubmenu) {
      final List<int> next = _prefix(level);
      // A second click on the row that opened a panel takes it back down, so
      // the menu can be driven by clicking alone. `next` is already the prefix
      // (this row and anything deeper dropped), which is exactly the "close"
      // state — the question is only whether it *was* open.
      final bool open = _open.length > level && _open[level] == index;
      if (!open) next.add(index);
      setState(() => _open = next);
      return;
    }
    if (node is MenuAction) {
      // Tear the menu down first: the edit re-lays out the field underneath, and
      // a panel still on screen would be measured against the old text.
      widget.onDismiss();
      node.onPressed?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final List<_PanelLayout> panels = _layout(screen);

    return Stack(
      children: <Widget>[
        // Opaque on purpose. A menu is modal for as long as it is up: a click
        // that misses every panel closes it and stops there, which is also what
        // keeps the field's own right-click handler from toggling the menu
        // straight back open under the closing click.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => widget.onDismiss(),
            onSecondaryTapDown: (_) => widget.onDismiss(),
            child: const SizedBox.expand(),
          ),
        ),
        for (int level = 0; level < panels.length; level++)
          Positioned.fromRect(
            rect: panels[level].rect,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: AppMotion.instant,
              curve: AppMotion.enter,
              builder: (BuildContext context, double t, Widget? child) =>
                  Opacity(opacity: t, child: child),
              child: _MenuPanel(
                nodes: panels[level].nodes,
                level: level,
                openIndex: level < _open.length ? _open[level] : -1,
                onHover: _hover,
                onTap: _tap,
              ),
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------- geometry

  List<_PanelLayout> _layout(Size screen) {
    final List<List<MenuNode>> levels = <List<MenuNode>>[widget.entries];
    List<MenuNode> current = widget.entries;
    for (final int index in _open) {
      if (index < 0 || index >= current.length) break;
      final MenuNode node = current[index];
      if (node is! MenuSubmenu) break;
      levels.add(node.children);
      current = node.children;
    }

    final List<_PanelLayout> out = <_PanelLayout>[];
    double x = widget.anchor.dx;
    double y = widget.anchor.dy;
    for (int level = 0; level < levels.length; level++) {
      final List<MenuNode> nodes = levels[level];
      final double width = kMenuPanelWidth;
      final double height = _panelHeight(nodes);

      if (level == 0) {
        x = _clampTo(x, width, screen.width);
        y = _clampTo(y, height, screen.height);
      } else {
        final _PanelLayout parent = out[level - 1];
        final int row = _open[level - 1].clamp(0, math.max(0, parent.nodes.length - 1));
        final double rowTop =
            parent.rect.top + kMenuPanelPadding + _heightBefore(parent.nodes, row);
        final double right = parent.rect.right + kMenuPanelGap;
        final double left = parent.rect.left - kMenuPanelGap - width;
        // Right of the row, unless that runs off the window — then left of the
        // parent, which is what a cascading menu has always done.
        final bool fits = right + width <= screen.width - kMenuScreenMargin;
        x = _clampTo(fits ? right : left, width, screen.width);
        y = _clampTo(rowTop, height, screen.height);
      }
      out.add(_PanelLayout(rect: Rect.fromLTWH(x, y, width, height), nodes: nodes));
    }
    return out;
  }

  static bool _samePath(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Keeps a [size]-long edge inside `[kMenuScreenMargin, extent - margin]`.
///
/// The `math.max` matters when a panel is taller than the window: the lower
/// bound would otherwise overtake the upper one and `clamp` would throw.
double _clampTo(double v, double size, double extent) {
  final double max = math.max(kMenuScreenMargin, extent - kMenuScreenMargin - size);
  return v.clamp(kMenuScreenMargin, math.max(kMenuScreenMargin, max));
}

double _nodeHeight(MenuNode node) =>
    node is MenuSeparator ? kMenuSeparatorHeight : kMenuRowHeight;

double _heightBefore(List<MenuNode> nodes, int index) {
  double height = 0;
  for (int i = 0; i < index && i < nodes.length; i++) {
    height += _nodeHeight(nodes[i]);
  }
  return height;
}

double _panelHeight(List<MenuNode> nodes) =>
    kMenuPanelPadding * 2 + _heightBefore(nodes, nodes.length);

/// The hover / "this submenu is open" fill for a row.
///
/// Derived from the palette rather than written out in hex: the same few per
/// cent of the text colour lifts a dark panel *and* deepens a light one, so both
/// themes get their highlight from one rule instead of two literals that drift.
Color _menuRowFill(AppPalette p) => Color.alphaBlend(
  p.textPrimary.withValues(alpha: p.isDark ? 0.07 : 0.06),
  p.surfaceRaised,
);

class _MenuPanel extends StatelessWidget {
  const _MenuPanel({
    required this.nodes,
    required this.level,
    required this.openIndex,
    required this.onHover,
    required this.onTap,
  });

  final List<MenuNode> nodes;
  final int level;
  final int openIndex;
  final void Function(int level, int index, MenuNode node) onHover;
  final void Function(int level, int index, MenuNode node) onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: p.outline),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: p.shadow,
            blurRadius: 22,
            spreadRadius: -4,
            offset: const Offset(0, 9),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: kMenuPanelPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < nodes.length; i++) _row(context, i, nodes[i]),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int index, MenuNode node) => switch (node) {
    MenuSeparator() => SizedBox(
      height: kMenuSeparatorHeight,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(height: 1, color: context.palette.outlineSoft),
        ),
      ),
    ),
    MenuSubmenu() => _MenuRow(
      label: node.label,
      icon: node.icon,
      submenu: true,
      expanded: openIndex == index,
      onHover: () => onHover(level, index, node),
      onTap: () => onTap(level, index, node),
    ),
    MenuAction() => _MenuRow(
      label: node.label,
      icon: node.icon,
      leading: node.leading,
      shortcut: node.shortcut,
      checked: node.checked,
      enabled: node.enabled,
      onHover: () => onHover(level, index, node),
      onTap: () => onTap(level, index, node),
    ),
  };
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({
    required this.label,
    required this.icon,
    this.leading,
    this.shortcut,
    this.submenu = false,
    this.expanded = false,
    this.checked = false,
    this.enabled = true,
    this.onHover,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final String? leading;
  final String? shortcut;
  final bool submenu;
  final bool expanded;
  final bool checked;
  final bool enabled;
  final VoidCallback? onHover;
  final VoidCallback? onTap;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // An open submenu keeps its parent row lit: the highlight is the thread
    // between the row you clicked and the panel that appeared beside it, and it
    // has to survive the pointer crossing the gap between the two.
    final bool lit = (_hovered || widget.expanded) && widget.enabled;
    final Color foreground = widget.enabled
        ? p.textPrimary
        : p.textTertiary.withValues(alpha: 0.55);

    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover?.call();
      },
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? widget.onTap : null,
        child: Container(
          height: kMenuRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: lit ? _menuRowFill(p) : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 22,
                child: Center(
                  child: widget.leading != null
                      ? Text(
                          widget.leading!,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            fontFamily: AppFonts.mono,
                            fontFamilyFallback: AppFonts.monoFallback,
                            color: widget.enabled ? p.textSecondary : foreground,
                          ),
                        )
                      : Icon(
                          widget.icon,
                          size: 15,
                          color: widget.enabled ? p.textSecondary : foreground,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: foreground),
                ),
              ),
              if (widget.shortcut != null) ...<Widget>[
                const SizedBox(width: 12),
                Text(
                  widget.shortcut!,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: AppFonts.mono,
                    fontFamilyFallback: AppFonts.monoFallback,
                    color: p.textTertiary.withValues(alpha: 0.9),
                  ),
                ),
              ],
              if (widget.submenu) ...<Widget>[
                const SizedBox(width: 6),
                Icon(Icons.chevron_right_rounded, size: 15, color: p.textTertiary),
              ],
              if (widget.checked) ...<Widget>[
                const SizedBox(width: 6),
                Icon(Icons.check_rounded, size: 14, color: p.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
