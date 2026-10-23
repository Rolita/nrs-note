import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../common/app_widgets.dart';

/// The card every template dialog sits in.
///
/// It mirrors [DeleteDialog]'s geometry — raised surface, one hairline, a
/// header that names the dialog and a footer that carries the actions — so the
/// template surfaces feel like part of NRS rather than Material defaults.
class TemplateDialogFrame extends StatelessWidget {
  const TemplateDialogFrame({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.body,
    this.footer,
    this.onClose,
    this.width = 540,
    this.maxHeight = 560,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget body;
  final Widget? footer;
  final VoidCallback? onClose;
  final double width;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.surfaceRaised,
                  borderRadius: AppRadius.lgAll,
                  border: Border.all(color: p.outline),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: p.shadow,
                      blurRadius: 34,
                      offset: const Offset(0, 12),
                    ),
                    BoxShadow(
                      color: p.shadow,
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: AppRadius.lgAll,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _header(p),
                      Flexible(child: body),
                      if (footer != null) _footer(p, footer!),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: AppIconSize.md, color: p.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                    color: p.textPrimary,
                    fontFamily: AppFonts.ui,
                    fontFamilyFallback: AppFonts.uiFallback,
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: p.textTertiary,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          _CloseButton(onPressed: onClose),
        ],
      ),
    );
  }

  Widget _footer(AppPalette p, Widget child) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.outlineSoft)),
      ),
      child: child,
    );
  }
}

/// A footer action with the same hover language as the rest of the chrome.
class TemplateDialogButton extends StatefulWidget {
  const TemplateDialogButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.primary = false,
    this.autofocus = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool autofocus;

  @override
  State<TemplateDialogButton> createState() => _TemplateDialogButtonState();
}

class _TemplateDialogButtonState extends State<TemplateDialogButton> {
  bool _hovered = false;

  static bool _hot(Set<WidgetState> states) =>
      states.contains(WidgetState.hovered) ||
      states.contains(WidgetState.pressed) ||
      states.contains(WidgetState.focused);

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool enabled = widget.onPressed != null;
    final MouseCursor cursor = enabled
        ? SystemMouseCursors.click
        : SystemMouseCursors.basic;

    final Color ink = !enabled
        ? p.textTertiary.withValues(alpha: 0.5)
        : widget.primary
        ? AppPalette.readableOn(p.accent)
        : p.textSecondary;
    final TextStyle textStyle = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: ink,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );

    final Widget label = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.icon != null) ...<Widget>[
          Icon(widget.icon, size: 13, color: ink),
          const SizedBox(width: 6),
        ],
        Text(widget.label, style: textStyle),
      ],
    );

    if (widget.primary) {
      return FilledButton(
        autofocus: widget.autofocus,
        style:
            FilledButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
              elevation: 0,
              iconSize: 13,
              textStyle: textStyle,
            ).copyWith(
              overlayColor: const WidgetStatePropertyAll<Color>(
                Colors.transparent,
              ),
              backgroundColor: WidgetStateProperty.resolveWith((
                Set<WidgetState> states,
              ) {
                if (!enabled) return p.accentSoft;
                return _hot(states)
                    ? p.accent.withValues(alpha: 0.86)
                    : p.accent;
              }),
              foregroundColor: WidgetStatePropertyAll<Color>(ink),
            ),
        onPressed: widget.onPressed,
        child: label,
      );
    }

    return MouseRegion(
      cursor: cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          decoration: BoxDecoration(
            color: enabled && _hovered ? p.surfaceSunken : Colors.transparent,
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: p.outline),
          ),
          child: Center(widthFactor: 1, child: label),
        ),
      ),
    );
  }
}

/// The search field shared by the picker and the suggester.
///
/// Focus is shown three ways — accent border, accent wash and a soft ring —
/// because one of them alone disappears against the sidebar greys.
class TemplateSearchField extends StatefulWidget {
  const TemplateSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.leading = LucideIcons.search,
    this.showClear = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final IconData leading;
  final bool showClear;

  @override
  State<TemplateSearchField> createState() => _TemplateSearchFieldState();
}

class _TemplateSearchFieldState extends State<TemplateSearchField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(covariant TemplateSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocus);
      widget.focusNode.addListener(_onFocus);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (!mounted) return;
    setState(() => _focused = widget.focusNode.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return AnimatedContainer(
      duration: AppMotion.fast,
      height: 32,
      decoration: BoxDecoration(
        color: _focused ? p.accentSoft : p.surfaceSunken,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: _focused ? p.accent : p.outline),
        boxShadow: _focused
            ? <BoxShadow>[
                BoxShadow(
                  color: p.accent.withValues(alpha: 0.18),
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 10),
          Icon(
            widget.leading,
            size: AppIconSize.xs,
            color: _focused ? p.accent : p.textTertiary,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              cursorColor: p.accent,
              cursorWidth: 1.3,
              style: TextStyle(
                fontSize: 12.5,
                color: p.textPrimary,
                height: 1.2,
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: widget.hint,
                hintStyle: TextStyle(
                  fontSize: 12.5,
                  color: p.textTertiary,
                  fontFamily: AppFonts.ui,
                  fontFamilyFallback: AppFonts.uiFallback,
                ),
              ),
            ),
          ),
          if (widget.showClear && widget.controller.text.isNotEmpty)
            AppIconButton(
              icon: LucideIcons.x,
              tooltip: '清除',
              size: 24,
              iconSize: 12,
              onPressed: () {
                widget.controller.clear();
                widget.onChanged?.call('');
                widget.focusNode.requestFocus();
              },
            )
          else
            const SizedBox(width: AppSpace.sm),
        ],
      ),
    );
  }
}

/// 「Esc 取消」 — the one keyboard fact every template dialog should teach.
class TemplateEscHint extends StatelessWidget {
  const TemplateEscHint({super.key, required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color ink = color ?? p.textTertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border.all(color: p.outline),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Text(
            'Esc',
            style: TextStyle(
              fontSize: 10,
              height: 1.5,
              color: ink,
              fontFamily: AppFonts.mono,
              fontFamilyFallback: AppFonts.monoFallback,
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            color: ink,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
          ),
        ),
      ],
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    if (onPressed == null) return const SizedBox(width: 20, height: 20);
    return Tooltip(
      message: '关闭',
      waitDuration: const Duration(milliseconds: 600),
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: hovered
                    ? p.textPrimary.withValues(alpha: 0.07)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadius.xs),
              ),
              child: Icon(
                LucideIcons.x,
                size: 13,
                color: hovered ? p.textPrimary : p.textTertiary,
              ),
            ),
          );
        },
      ),
    );
  }
}
