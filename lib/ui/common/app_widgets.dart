import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';

/// Gives a builder access to the hover state — the backbone of a desktop UI
/// that feels alive without being noisy.
class HoverBuilder extends StatefulWidget {
  const HoverBuilder({super.key, required this.builder, this.cursor});

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor? cursor;

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor ?? SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, _hovered),
    );
  }
}

/// Compact square icon button used across every toolbar and header.
class AppIconButton extends StatefulWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.active = false,
    this.activeColor,
    this.size = 30,
    this.iconSize = 16.5,
    this.shortcut,
    this.tone,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;
  final Color? activeColor;
  final double size;
  final double iconSize;
  final String? shortcut;
  final Color? tone;

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool enabled = widget.onPressed != null;
    final Color accent = widget.activeColor ?? p.accent;

    final Color background = widget.active
        ? accent.withValues(alpha: p.isDark ? 0.20 : 0.13)
        : (_hovered && enabled ? p.surfaceRaised : Colors.transparent);

    Color foreground;
    if (widget.tone != null) {
      foreground = widget.tone!;
    } else if (widget.active) {
      foreground = accent;
    } else if (!enabled) {
      foreground = p.textTertiary.withValues(alpha: 0.45);
    } else if (_hovered) {
      foreground = p.textPrimary;
    } else {
      foreground = p.textSecondary;
    }

    return Tooltip(
      message: widget.shortcut == null
          ? widget.tooltip
          : '${widget.tooltip}  ·  ${widget.shortcut}',
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
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
              borderRadius: AppRadius.smAll,
              border: widget.active && !p.isDark
                  ? Border.all(color: accent.withValues(alpha: 0.16))
                  : null,
            ),
            child: Icon(widget.icon, size: widget.iconSize, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// Text button with the same hover language as [AppIconButton].
class AppTextButton extends StatefulWidget {
  const AppTextButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.active = false,
    this.tone,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool active;
  final Color? tone;

  @override
  State<AppTextButton> createState() => _AppTextButtonState();
}

class _AppTextButtonState extends State<AppTextButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool enabled = widget.onPressed != null;
    final Color fg = widget.tone ??
        (widget.active
            ? p.accent
            : (enabled && _hovered ? p.textPrimary : p.textSecondary));
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm + 2),
          decoration: BoxDecoration(
            color: widget.active
                ? p.accent.withValues(alpha: p.isDark ? 0.20 : 0.13)
                : (_hovered && enabled ? p.surfaceRaised : Colors.transparent),
            borderRadius: AppRadius.smAll,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.icon != null) ...<Widget>[
                Icon(widget.icon, size: 14.5, color: fg),
                const SizedBox(width: 7),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded tag pill, optionally interactive.
class TagPill extends StatelessWidget {
  const TagPill({
    super.key,
    required this.label,
    this.count,
    this.selected = false,
    this.onTap,
    this.onRemove,
    this.compact = false,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      cursor: onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        final Color bg = selected
            ? p.accent.withValues(alpha: p.isDark ? 0.24 : 0.14)
            : (hovered ? p.surfaceRaised : p.surfaceSunken);
        final Color fg = selected
            ? p.accent
            : (hovered ? p.textSecondary : p.textTertiary);
        return GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 7 : 9,
              vertical: compact ? 2 : 3.5,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppRadius.pillAll,
              border: Border.all(
                color: selected
                    ? p.accent.withValues(alpha: 0.28)
                    : p.outlineSoft,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: compact ? 10.5 : 11.5,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
                if (count != null) ...<Widget>[
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: compact ? 9.5 : 10.5,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                if (onRemove != null) ...<Widget>[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: onRemove,
                    child: Icon(Icons.close_rounded, size: 11, color: fg),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Small segmented control (editor mode switch, sort picker…).
class SegmentedToggle<T> extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final List<({T value, IconData icon, String label})> items;
  final T value;
  final ValueChanged<T> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        border: Border.all(color: p.outlineSoft),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final ({T value, IconData icon, String label}) item in items)
            _Segment(
              icon: item.icon,
              label: item.label,
              selected: item.value == value,
              compact: compact,
              onTap: () => onChanged(item.value),
            ),
        ],
      ),
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.compact,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color fg = widget.selected
        ? p.textPrimary
        : (_hovered ? p.textSecondary : p.textTertiary);
    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: widget.compact ? 24 : 26,
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 7 : 9),
            decoration: BoxDecoration(
              color: widget.selected ? p.surfaceRaised : Colors.transparent,
              borderRadius: AppRadius.smAll,
              boxShadow: widget.selected
                  ? <BoxShadow>[
                      BoxShadow(
                        color: p.shadow,
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(widget.icon, size: widget.compact ? 14 : 15, color: fg),
                if (!widget.compact) ...<Widget>[
                  const SizedBox(width: 6),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Draggable divider used to resize the panes.
class ResizeHandle extends StatefulWidget {
  const ResizeHandle({
    super.key,
    required this.onDelta,
    this.width = 6,
  });

  /// Called with the horizontal drag delta in logical pixels.
  final ValueChanged<double> onDelta;
  final double width;

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool lit = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragUpdate: (DragUpdateDetails d) =>
            widget.onDelta(d.delta.dx),
        child: SizedBox(
          width: widget.width,
          child: Center(
            child: AnimatedContainer(
              duration: AppMotion.fast,
              width: lit ? 3 : 1,
              decoration: BoxDecoration(
                color: lit ? p.accent.withValues(alpha: 0.55) : p.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small uppercase label used to head a group of controls.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.md, AppSpace.sm),
      child: Row(
        children: <Widget>[
          Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
              color: p.textTertiary,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// A centred message with an optional action — used for empty states.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? AppSpace.lg : AppSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: compact ? 40 : 52,
              height: compact ? 40 : 52,
              decoration: BoxDecoration(
                color: p.surfaceSunken,
                borderRadius: AppRadius.lgAll,
                border: Border.all(color: p.outlineSoft),
              ),
              child: Icon(
                icon,
                size: compact ? 18 : 22,
                color: p.textTertiary,
              ),
            ),
            SizedBox(height: compact ? AppSpace.md : AppSpace.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: compact ? 13.5 : 15,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: p.textTertiary,
                  ),
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: AppSpace.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
