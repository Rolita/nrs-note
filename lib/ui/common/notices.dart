import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';

/// The tone of a notice. It picks both the icon and the progress-line colour;
/// the card itself stays the raised surface in every case.
enum NoticeKind { success, info, error }

@immutable
class NoticeData {
  const NoticeData({
    required this.message,
    required this.kind,
    this.detail,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? detail;
  final NoticeKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// An action is why the window stays open long enough to use it. A message
  /// with nothing to click gets the short window.
  Duration get duration => switch (kind) {
    NoticeKind.success =>
      onAction == null
          ? const Duration(milliseconds: 2400)
          : const Duration(milliseconds: 6000),
    NoticeKind.info => const Duration(milliseconds: 2400),
    NoticeKind.error => const Duration(milliseconds: 8000),
  };
}

/// One notice at a time: a new message replaces the current one instead of
/// stacking, so an undo window is never pushed off screen by the next event.
class NoticeController extends ChangeNotifier {
  NoticeData? _current;

  NoticeData? get current => _current;

  void show(NoticeData notice) {
    _current = notice;
    notifyListeners();
  }

  void dismiss() {
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }
}

/// Puts a controller in reach of every widget under the shell — the editor's
/// paste refusals have no line to [AppShell], but they still need its host.
class NoticeScope extends InheritedWidget {
  const NoticeScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final NoticeController controller;

  static NoticeController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NoticeScope>()?.controller;

  @override
  bool updateShouldNotify(NoticeScope oldWidget) =>
      !identical(oldWidget.controller, controller);
}

/// Shows [message] in the shell's notice host.
///
/// A widget test that mounts an editor without the shell has no host; the
/// notice is dropped rather than thrown at, because a refusal must never break
/// the paste path it is only trying to explain.
void showNotice(
  BuildContext context,
  String message, {
  NoticeKind kind = NoticeKind.success,
  String? detail,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  NoticeScope.maybeOf(context)?.show(
    NoticeData(
      message: message,
      kind: kind,
      detail: detail,
      actionLabel: actionLabel,
      onAction: onAction,
    ),
  );
}

/// A message shaped like `标题：细节`, with the detail moved to the card's
/// second row — a refusal reads better when the reason is not cut off by the
/// headline in front of it.
void showSplitNotice(
  BuildContext context,
  String message, {
  NoticeKind kind = NoticeKind.success,
}) {
  final int at = message.indexOf('：');
  if (at <= 0) {
    showNotice(context, message, kind: kind);
    return;
  }
  showNotice(
    context,
    message.substring(0, at),
    kind: kind,
    detail: message.substring(at + 1),
  );
}

/// The top-right receipt pill, with its countdown painted as a depleting ring
/// around the leading status dot.
///
/// The host owns both clocks: one for the entry/exit lift, one for how long the
/// notice may stay. Pointing at the card pauses the second clock — an undo
/// button that disappears while the pointer is on it is worse than no button.
class NoticeHost extends StatefulWidget {
  const NoticeHost({super.key, required this.controller});

  final NoticeController controller;

  /// Shared with tests, and with anything that needs to find the one card.
  static const Key cardKey = ValueKey<String>('nrs-notice');

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost> with TickerProviderStateMixin {
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  late final AnimationController _life = AnimationController(vsync: this);

  NoticeData? _notice;
  bool _hovered = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _life.addStatusListener(_onLifeStatus);
    final NoticeData? current = widget.controller.current;
    if (current != null) {
      _notice = current;
      _presence.value = 1;
      _runLife(current);
    }
  }

  @override
  void didUpdateWidget(NoticeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_onControllerChanged);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _life.dispose();
    _presence.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final NoticeData? next = widget.controller.current;
    if (next == null) {
      _startExit();
    } else if (!identical(next, _notice)) {
      _present(next);
    }
  }

  void _present(NoticeData notice) {
    setState(() {
      _notice = notice;
      _exiting = false;
    });
    _presence.duration = const Duration(milliseconds: 180);
    _presence.forward(from: 0);
    _runLife(notice);
  }

  void _runLife(NoticeData notice) {
    _life.duration = notice.duration;
    _life.value = 1;
    if (_hovered) {
      _life.stop();
    } else {
      _life.reverse();
    }
  }

  void _onLifeStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || _exiting) return;
    widget.controller.dismiss();
  }

  void _startExit() {
    if (_notice == null || _exiting) return;
    setState(() => _exiting = true);
    _life.stop();
    _presence.duration = const Duration(milliseconds: 170);
    _presence.reverse().whenCompleteOrCancel(() {
      if (!mounted || !_exiting) return;
      setState(() {
        _exiting = false;
        _notice = null;
      });
    });
  }

  void _onEnter() {
    _hovered = true;
    if (!_exiting) _life.stop();
  }

  void _onExit() {
    _hovered = false;
    if (!_exiting) _life.reverse();
  }

  void _act() {
    if (_exiting) return;
    final VoidCallback? action = _notice?.onAction;
    widget.controller.dismiss();
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final NoticeData? notice = _notice;
    if (notice == null) return const SizedBox.shrink();

    return IgnorePointer(
      ignoring: _exiting,
      child: MouseRegion(
        onEnter: (_) => _onEnter(),
        onExit: (_) => _onExit(),
        child: AnimatedBuilder(
          animation: _presence,
          builder: (BuildContext context, Widget? child) {
            final double t = Curves.easeOutCubic.transform(_presence.value);
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, -5 * (1 - t)),
                child: Transform.scale(
                  scale: 0.985 + 0.015 * t,
                  alignment: Alignment.topCenter,
                  child: child,
                ),
              ),
            );
          },
          child: _NoticeCard(
            key: NoticeHost.cardKey,
            notice: notice,
            life: _life,
            onAction: _act,
            onClose: widget.controller.dismiss,
          ),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    super.key,
    required this.notice,
    required this.life,
    required this.onAction,
    required this.onClose,
  });

  final NoticeData notice;
  final Animation<double> life;
  final VoidCallback onAction;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final (Color tone, Color soft) = switch (notice.kind) {
      NoticeKind.success => (p.success, p.successSoft),
      NoticeKind.info => (p.accent, p.accentSoft),
      NoticeKind.error => (p.danger, p.dangerSoft),
    };
    // A refusal carries a reason worth reading, so it gets a second line
    // instead of cutting the sentence off. Every other notice is one receipt.
    final bool twoLine =
        notice.kind == NoticeKind.error && notice.detail != null;

    final TextStyle messageStyle = TextStyle(
      fontSize: 12,
      height: 1.25,
      fontWeight: FontWeight.w600,
      color: p.textPrimary,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );
    final TextStyle detailStyle = TextStyle(
      fontSize: 11,
      height: 1.25,
      color: p.textTertiary,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );

    final Widget ring = AnimatedBuilder(
      animation: life,
      builder: (BuildContext context, Widget? _) =>
          _CountdownRing(value: life.value, tone: tone),
    );

    final Widget message = Text(
      notice.message,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: messageStyle,
    );

    final Widget? detail = notice.detail == null
        ? null
        : Text(
            notice.detail!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: detailStyle,
          );

    final Widget? action = notice.onAction == null
        ? null
        : _NoticeAction(
            label: notice.actionLabel ?? '撤销',
            tone: tone,
            soft: soft,
            onPressed: onAction,
          );

    final Widget close = _NoticeClose(onPressed: onClose);

    final Widget body = twoLine
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(padding: const EdgeInsets.only(top: 2), child: ring),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    message,
                    if (detail != null) ...<Widget>[
                      const SizedBox(height: 1),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Flexible(child: detail),
                          if (action != null) ...<Widget>[
                            const SizedBox(width: 8),
                            action,
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              close,
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ring,
              const SizedBox(width: 8),
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: <Widget>[
                    message,
                    if (detail != null) ...<Widget>[
                      const SizedBox(width: 6),
                      Flexible(child: detail),
                    ],
                  ],
                ),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(width: 8),
                Container(width: 1, height: 13, color: p.outlineSoft),
                const SizedBox(width: 8),
                action,
              ],
              const SizedBox(width: 8),
              close,
            ],
          );

    return Semantics(
      liveRegion: true,
      container: true,
      // The width follows the text: a fixed column leaves a hole in the short
      // receipts that make up most notices. Only a refusal's reason may reach
      // the cap, and even then it stops at a readable measure.
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 352),
        child: Container(
          height: twoLine ? null : 32,
          padding: twoLine
              ? const EdgeInsets.fromLTRB(10, 7, 7, 7)
              : const EdgeInsets.fromLTRB(10, 0, 7, 0),
          decoration: BoxDecoration(
            color: p.surfaceRaised,
            borderRadius: BorderRadius.circular(twoLine ? 13 : 16),
            border: Border.all(color: p.outline),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: p.shadow,
                blurRadius: 26,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: p.shadow,
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: body,
        ),
      ),
    );
  }
}

/// The countdown, drawn as a 13px ring around an empty centre.
///
/// The centre is left unpainted so it reads as a hole onto the card rather than
/// as a second icon; the arc is the only thing that moves.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.value, required this.tone});

  final double value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 13,
      child: CustomPaint(
        painter: _CountdownRingPainter(
          value: value.clamp(0.0, 1.0).toDouble(),
          tone: tone,
        ),
      ),
    );
  }
}

class _CountdownRingPainter extends CustomPainter {
  const _CountdownRingPainter({required this.value, required this.tone});

  final double value;
  final Color tone;

  static const double _stroke = 2.4;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = (size.shortestSide - _stroke) / 2;
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..color = tone.withValues(alpha: 0.20);
    canvas.drawCircle(center, radius, track);
    if (value <= 0) return;

    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..color = tone;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * value,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_CountdownRingPainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.tone != tone;
}

class _NoticeAction extends StatefulWidget {
  const _NoticeAction({
    required this.label,
    required this.tone,
    required this.soft,
    required this.onPressed,
  });

  final String label;
  final Color tone;
  final Color soft;
  final VoidCallback onPressed;

  @override
  State<_NoticeAction> createState() => _NoticeActionState();
}

class _NoticeActionState extends State<_NoticeAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered ? widget.soft : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: _hovered ? widget.tone : context.palette.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticeClose extends StatefulWidget {
  const _NoticeClose({required this.onPressed});

  final VoidCallback onPressed;

  @override
  State<_NoticeClose> createState() => _NoticeCloseState();
}

class _NoticeCloseState extends State<_NoticeClose> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Tooltip(
      message: '关闭提示',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            width: 19,
            height: 19,
            decoration: BoxDecoration(
              color: _hovered
                  ? p.textPrimary.withValues(alpha: 0.07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(
              LucideIcons.x,
              size: 11,
              color: _hovered ? p.textPrimary : p.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}
