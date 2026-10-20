import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
    this.size = AppLayout.buttonHeight,
    this.iconSize = AppIconSize.sm,
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
        ? p.accentSoft
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
              borderRadius: AppRadius.mdAll,
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
          height: AppLayout.buttonHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm + 2),
          decoration: BoxDecoration(
            color: widget.active
                ? p.accentSoft
                : (_hovered && enabled ? p.surfaceRaised : Colors.transparent),
            borderRadius: AppRadius.mdAll,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.icon != null) ...<Widget>[
                Icon(widget.icon, size: AppIconSize.xs, color: fg),
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
            ? p.accentSoft
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
              vertical: compact ? 2 : 3,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AppRadius.pillAll,
              border: Border.all(
                color: selected
                    ? p.accent.withValues(alpha: 0.3)
                    : p.outlineSoft,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(
                    fontSize: compact ? 11 : AppText.caption,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
                if (count != null) ...<Widget>[
                  const SizedBox(width: AppSpace.xs),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: compact ? 10 : 11,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                if (onRemove != null) ...<Widget>[
                  const SizedBox(width: AppSpace.xs),
                  GestureDetector(
                    onTap: onRemove,
                    child: Icon(LucideIcons.x, size: 11, color: fg),
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
      padding: const EdgeInsets.all(AppSpace.xxs),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.mdAll,
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
        ? p.accent
        : (_hovered ? p.textPrimary : p.textSecondary);
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
            height: widget.compact ? 22 : 24,
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 7 : 9),
            decoration: BoxDecoration(
              // The selected segment speaks the same language as a selected row:
              // an `accentSoft` fill with an `accent` glyph. Marking it by
              // surface alone was invisible in the light theme, where
              // `surfaceRaised` and `surfaceSunken` are three levels apart.
              color: widget.selected ? p.accentSoft : Colors.transparent,
              borderRadius: AppRadius.smAll,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(widget.icon, size: widget.compact ? AppIconSize.xs : AppIconSize.sm, color: fg),
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
    required this.background,
    this.width = AppLayout.resizeHandleWidth,
  });

  /// Called with the horizontal drag delta in logical pixels.
  final ValueChanged<double> onDelta;

  /// The pane colour this strip is carved out of.
  ///
  /// The shell paints its own background with the darkest step on screen, and
  /// the strip is a *gap* between two panes, so leaving it unpainted drew a 5px
  /// trench at every seam the panes could be dragged on — while the rail, which
  /// has no strip, met its neighbour flush. Painting the strip as the pane it
  /// belongs to makes all three seams the same thing: a hairline between two
  /// surfaces, with nothing else in between.
  final Color background;

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
          child: ColoredBox(
            color: widget.background,
            // The line sits hard against the pane that follows, so the seam it
            // marks is exactly where the panes meet. Centring it instead left
            // two pixels of trench on either side and the edge stopped reading
            // as an edge.
            child: Align(
              alignment: Alignment.centerRight,
              child: AnimatedContainer(
                duration: AppMotion.fast,
                width: lit ? 2 : 1,
                decoration: BoxDecoration(
                  color: lit ? p.accent.withValues(alpha: 0.8) : p.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
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
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.sm,
        AppSpace.xs,
      ),
      child: Row(
        children: <Widget>[
          Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: AppText.caption,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
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
              width: compact ? 38 : 48,
              height: compact ? 38 : 48,
              decoration: BoxDecoration(
                color: p.surfaceSunken,
                borderRadius: AppRadius.lgAll,
                border: Border.all(color: p.outlineSoft),
              ),
              child: Icon(
                icon,
                size: compact ? 17 : 21,
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
                    fontSize: AppText.ui,
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
