import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'app_widgets.dart';

/// One row inside [DeleteDialog]'s target block: what is about to go, and where
/// it lives.
@immutable
class DeleteTarget {
  const DeleteTarget({
    required this.name,
    this.meta,
    this.icon = LucideIcons.fileText,
    this.monoName = false,
  });

  /// The note title, or the folder path — the thing the user is deleting.
  final String name;

  /// The secondary column: the note's folder, a child-folder count, and so on.
  final String? meta;

  final IconData icon;

  /// Folder paths read better in the mono face than a title does.
  final bool monoName;
}

/// Asks before a note, a batch, or a folder moves to the recycle bin.
///
/// Returns `true` only when the user confirms; dismissing with Escape, the
/// close button, or the barrier all come back as `false`/`null`, so callers can
/// keep testing `confirmed != true`.
Future<bool?> showDeleteDialog(
  BuildContext context, {
  required String title,
  required String message,
  required List<DeleteTarget> targets,
  String? overflowLabel,
  String? warning,
}) {
  final AppPalette p = context.palette;
  return showDialog<bool>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) => DeleteDialog(
      title: title,
      message: message,
      targets: targets,
      overflowLabel: overflowLabel,
      warning: warning,
    ),
  );
}

/// The confirmation card: a 3px danger edge, an eyebrow that names the act, the
/// target block, and a footer that keeps 「取消」 as the focused default.
///
/// The card is deliberately wider and quieter than a Material [AlertDialog]:
/// a recoverable delete does not need a full-width red slab, and the horizontal
/// button row keeps the two choices one glance apart.
class DeleteDialog extends StatelessWidget {
  const DeleteDialog({
    super.key,
    required this.title,
    required this.message,
    required this.targets,
    this.overflowLabel,
    this.warning,
  });

  final String title;
  final String message;
  final List<DeleteTarget> targets;

  /// The `…还有 N 篇` line, when the batch is longer than the block can list.
  final String? overflowLabel;

  final String? warning;

  /// Wide enough for a two-line sentence and the target block, still narrower
  /// than the settings sheet.
  static const double _width = 420;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(false),
      },
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _width),
              child: SizedBox(
                width: _width,
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
                    child: Stack(
                      children: <Widget>[
                        // The danger edge is structure, not decoration: it runs
                        // the full height of the card the way a quote bar does.
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: 3,
                          child: ColoredBox(color: p.danger),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            _body(context, p),
                            _footer(context, p),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppPalette p) {
    final TextStyle bodyStyle = TextStyle(
      fontSize: 12.5,
      height: 1.62,
      color: p.textSecondary,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 13, 18, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '确认删除',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.7,
              color: p.danger,
              fontFamily: AppFonts.ui,
              fontFamilyFallback: AppFonts.uiFallback,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15.5,
                    height: 1.32,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.15,
                    color: p.textPrimary,
                    fontFamily: AppFonts.ui,
                    fontFamilyFallback: AppFonts.uiFallback,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              _CloseButton(onPressed: () => Navigator.of(context).pop(false)),
            ],
          ),
          const SizedBox(height: 6),
          Text(message, style: bodyStyle),
          const SizedBox(height: AppSpace.md),
          _TargetBlock(
            targets: targets,
            overflowLabel: overflowLabel,
            bodyStyle: bodyStyle,
          ),
          if (warning != null) ...<Widget>[
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    LucideIcons.triangleAlert,
                    size: 13,
                    color: p.warning,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    warning!,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: p.warning,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _footer(BuildContext context, AppPalette p) {
    final TextStyle buttonText = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 18, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.outlineSoft)),
      ),
      child: Row(
        children: <Widget>[
          _EscHint(textColor: p.textTertiary, borderColor: p.outline),
          const Spacer(),
          OutlinedButton(
            autofocus: true,
            style:
                OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
                  textStyle: buttonText,
                ).copyWith(
                  overlayColor: const WidgetStatePropertyAll<Color>(
                    Colors.transparent,
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith((
                    Set<WidgetState> states,
                  ) {
                    return _hot(states) ? p.surfaceSunken : Colors.transparent;
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((
                    Set<WidgetState> states,
                  ) {
                    return _hot(states) ? p.textPrimary : p.textSecondary;
                  }),
                  side: WidgetStateProperty.resolveWith((
                    Set<WidgetState> states,
                  ) {
                    return BorderSide(
                      color: _hot(states) ? p.textTertiary : p.outline,
                    );
                  }),
                ),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          const SizedBox(width: AppSpace.sm),
          FilledButton.icon(
            style:
                FilledButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
                  textStyle: buttonText,
                  elevation: 0,
                ).copyWith(
                  overlayColor: const WidgetStatePropertyAll<Color>(
                    Colors.transparent,
                  ),
                  iconSize: const WidgetStatePropertyAll<double>(13),
                  backgroundColor: WidgetStateProperty.resolveWith((
                    Set<WidgetState> states,
                  ) {
                    return _hot(states) ? p.danger : p.dangerSoft;
                  }),
                  foregroundColor: WidgetStateProperty.resolveWith((
                    Set<WidgetState> states,
                  ) {
                    return _hot(states)
                        ? AppPalette.readableOn(p.danger)
                        : p.danger;
                  }),
                ),
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(LucideIcons.trash2),
            label: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// Hover, press and keyboard focus all mean "this is the live target".
  static bool _hot(Set<WidgetState> states) =>
      states.contains(WidgetState.hovered) ||
      states.contains(WidgetState.pressed) ||
      states.contains(WidgetState.focused);
}

/// The target block: a sunken well holding one or more rows of
/// icon + name + path.
class _TargetBlock extends StatelessWidget {
  const _TargetBlock({
    required this.targets,
    required this.overflowLabel,
    required this.bodyStyle,
  });

  final List<DeleteTarget> targets;
  final String? overflowLabel;
  final TextStyle bodyStyle;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 5),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outlineSoft),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final DeleteTarget target in targets)
            SizedBox(
              height: 22,
              child: Row(
                children: <Widget>[
                  Icon(target.icon, size: 13, color: p.textTertiary),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      target.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: p.textSecondary,
                        fontFamily: target.monoName
                            ? AppFonts.mono
                            : AppFonts.ui,
                        fontFamilyFallback: target.monoName
                            ? AppFonts.monoFallback
                            : AppFonts.uiFallback,
                      ),
                    ),
                  ),
                  if (target.meta != null) ...<Widget>[
                    const SizedBox(width: AppSpace.sm),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 172),
                      child: Text(
                        target.meta!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: p.textTertiary,
                          fontFamily: AppFonts.mono,
                          fontFamilyFallback: AppFonts.monoFallback,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (overflowLabel != null)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 2),
              child: Text(
                overflowLabel!,
                style: TextStyle(
                  fontSize: 10.5,
                  color: p.textTertiary,
                  fontFamily: AppFonts.ui,
                  fontFamilyFallback: AppFonts.uiFallback,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「Esc 取消」 — the one keyboard fact a confirmation card should teach.
class _EscHint extends StatelessWidget {
  const _EscHint({required this.textColor, required this.borderColor});

  final Color textColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Text(
            'Esc',
            style: TextStyle(
              fontSize: 10,
              height: 1.5,
              color: textColor,
              fontFamily: AppFonts.mono,
              fontFamilyFallback: AppFonts.monoFallback,
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text('取消', style: TextStyle(fontSize: 10.5, color: textColor)),
      ],
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
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
