import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';

/// A self-contained colour picker: swatch, HSV bars, optional alpha, hex field.
///
/// Hand-built rather than pulled from a package — a picker is the one widget
/// where "another dependency, another theme to fight" costs more than the ~200
/// lines it replaces.
///
/// The contract is two callbacks on purpose:
/// * [onChanged] fires on **every** frame of a drag (live preview, in memory);
/// * [onChangeEnd] fires when the pointer lifts or the hex field is submitted,
///   which is when the caller should persist.
///
/// Alpha is kept **outside** the HSV triple. [HSVColor] carries no alpha, so
/// round-tripping through it would drop the byte on every drag sample and make
/// the alpha slider fight the pointer.
class AppColorPicker extends StatefulWidget {
  const AppColorPicker({
    super.key,
    required this.color,
    required this.onChanged,
    required this.onChangeEnd,
    this.showAlpha = false,
    this.width = 248,
  });

  final Color color;
  final ValueChanged<Color> onChanged;
  final ValueChanged<Color> onChangeEnd;

  /// Only translucent tokens get an alpha bar.
  final bool showAlpha;

  final double width;

  @override
  State<AppColorPicker> createState() => _AppColorPickerState();
}

class _AppColorPickerState extends State<AppColorPicker> {
  late HSVColor _hsv;
  late int _alpha;

  final TextEditingController _hexController = TextEditingController();
  final FocusNode _hexFocus = FocusNode();
  String? _hexError;

  /// A just-noticeable difference. Anything smaller is our own rounding coming
  /// back around, not the user (or the caller) picking a different colour.
  static const double _eps = 0.5 / 255;

  @override
  void initState() {
    super.initState();
    _adopt(widget.color);
    _hexFocus.addListener(_onHexFocusChanged);
  }

  @override
  void didUpdateWidget(covariant AppColorPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-seed the HSV state only when the incoming colour genuinely differs from
    // what we are already representing — otherwise our own `onChanged` would
    // reset the sliders mid-drag.
    if (!_nearly(widget.color, _current)) _adopt(widget.color);
    if (!_hexFocus.hasFocus) _syncHexText();
  }

  @override
  void dispose() {
    _hexFocus.removeListener(_onHexFocusChanged);
    _hexFocus.dispose();
    _hexController.dispose();
    super.dispose();
  }

  void _adopt(Color color) {
    _hsv = HSVColor.fromColor(color);
    _alpha = (color.a * 255).round();
    _hexError = null;
    _syncHexText();
  }

  Color get _current =>
      _hsv.toColor().withValues(alpha: _alpha / 255);

  static bool _nearly(Color a, Color b) =>
      (a.a - b.a).abs() <= _eps &&
      (a.r - b.r).abs() <= _eps &&
      (a.g - b.g).abs() <= _eps &&
      (a.b - b.b).abs() <= _eps;

  void _onHexFocusChanged() {
    if (!_hexFocus.hasFocus) _syncHexText();
  }

  void _syncHexText() {
    final String text = hexText(_current);
    _hexController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Live: no write, just tell the caller.
  void _preview(Color next, {bool commit = false}) {
    setState(() {
      _hsv = HSVColor.fromColor(next);
      _alpha = (next.a * 255).round();
      _hexError = null;
    });
    if (commit) {
      widget.onChangeEnd(next);
    } else {
      widget.onChanged(next);
    }
  }

  void _applyHsv({double? h, double? s, double? v}) {
    final HSVColor next = HSVColor.fromAHSV(
      1,
      h ?? _hsv.hue,
      s ?? _hsv.saturation,
      v ?? _hsv.value,
    );
    _preview(next.toColor().withValues(alpha: _alpha / 255));
  }

  void _applyAlpha(double a) =>
      _preview(_hsv.toColor().withValues(alpha: a));

  void _submitHex(String raw) {
    final Color? parsed = parseHex(raw);
    if (parsed == null) {
      // Keep the old colour and say so, instead of throwing or silently
      // adopting something the user did not type.
      setState(() => _hexError = '请输入 #RGB / #RRGGBB / #AARRGGBB');
      return;
    }
    // Six digits (or three) mean "no alpha was written", so the alpha bar keeps
    // its byte rather than the field quietly forcing the colour opaque.
    final bool carriesAlpha = raw.trim().replaceAll('#', '').length == 8;
    final Color next = carriesAlpha
        ? parsed
        : parsed.withValues(alpha: _alpha / 255);
    _preview(next, commit: true);
    _syncHexText();
    _hexFocus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color current = _current;
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Swatch(color: current),
              const SizedBox(width: AppSpace.sm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextField(
                      controller: _hexController,
                      focusNode: _hexFocus,
                      onSubmitted: _submitHex,
                      style: TextStyle(
                        fontSize: AppText.mono,
                        fontFamily: AppFonts.mono,
                        fontFamilyFallback: AppFonts.monoFallback,
                        color: p.textPrimary,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        errorText: _hexError,
                        errorStyle: TextStyle(
                          fontSize: AppText.caption - 1,
                          color: p.danger,
                        ),
                      ),
                    ),
                    if (_alpha < 255) ...<Widget>[
                      const SizedBox(height: AppSpace.sm),
                      _CompositeStrip(color: current),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          _ChannelBar(
            value: _hsv.hue / 360,
            colors: <Color>[
              for (int i = 0; i <= 6; i++)
                HSVColor.fromAHSV(1, (i * 60) % 360, 1, 1).toColor(),
            ],
            thumbFill: p.surfaceRaised,
            thumbRing: p.textPrimary.withValues(alpha: 0.45),
            onChanged: (double v) => _applyHsv(h: v * 360),
            onChangeEnd: (double v) => _applyHsv(h: v * 360),
          ),
          const SizedBox(height: AppSpace.xs + 2),
          _ChannelBar(
            value: _hsv.saturation,
            colors: <Color>[
              HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(),
              HSVColor.fromAHSV(1, _hsv.hue, 1, _hsv.value).toColor(),
            ],
            thumbFill: p.surfaceRaised,
            thumbRing: p.textPrimary.withValues(alpha: 0.45),
            onChanged: (double v) => _applyHsv(s: v),
            onChangeEnd: (double v) => _applyHsv(s: v),
          ),
          const SizedBox(height: AppSpace.xs + 2),
          _ChannelBar(
            value: _hsv.value,
            colors: <Color>[
              HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 0).toColor(),
              HSVColor.fromAHSV(1, _hsv.hue, _hsv.saturation, 1).toColor(),
            ],
            thumbFill: p.surfaceRaised,
            thumbRing: p.textPrimary.withValues(alpha: 0.45),
            onChanged: (double v) => _applyHsv(v: v),
            onChangeEnd: (double v) => _applyHsv(v: v),
          ),
          if (widget.showAlpha) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            _ChannelBar(
              value: _alpha / 255,
              colors: <Color>[
                current.withValues(alpha: 0),
                current.withValues(alpha: 1),
              ],
              under: const _Checkerboard(),
              thumbFill: p.surfaceRaised,
              thumbRing: p.textPrimary.withValues(alpha: 0.45),
              onChanged: _applyAlpha,
              onChangeEnd: _applyAlpha,
            ),
            const SizedBox(height: AppSpace.xxs),
            Text(
              'A:$_alpha  (0x${_alpha.toRadixString(16).padLeft(2, '0')})',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: AppText.caption - 1,
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                color: p.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// `#RRGGBB`, or `#AARRGGBB` when the colour is not fully opaque.
String hexText(Color c) {
  final int a = (c.a * 255).round();
  final int r = (c.r * 255).round();
  final int g = (c.g * 255).round();
  final int b = (c.b * 255).round();
  String two(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  return a == 0xFF ? '#${two(r)}${two(g)}${two(b)}' : '#${two(a)}${two(r)}${two(g)}${two(b)}';
}

/// Accepts `#RGB`, `#RRGGBB` and `#AARRGGBB`, with or without the hash.
/// Returns null rather than throwing when the text is not a colour.
Color? parseHex(String raw) {
  String s = raw.trim().replaceAll('#', '').replaceAll(' ', '');
  if (s.length == 3) {
    s = s.split('').map((String c) => '$c$c').join();
  }
  if (s.length != 6 && s.length != 8) return null;
  final int? n = int.tryParse(s, radix: 16);
  if (n == null) return null;
  return Color(s.length == 6 ? 0xFF000000 | n : n);
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: 40,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outline),
      ),
      child: Stack(
        children: <Widget>[
          if (color.a < 1) const Positioned.fill(child: _Checkerboard()),
          Positioned.fill(child: ColoredBox(color: color)),
        ],
      ),
    );
  }
}

/// A translucent colour's look depends on what it sits on, so a single block
/// cannot tell the truth. This bar composites it over `canvas` (left 40%) and
/// over `surface` (right 60%) — the two backdrops every translucent token
/// actually lands on.
class _CompositeStrip extends StatelessWidget {
  const _CompositeStrip({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: 7,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: p.outlineSoft),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: ColoredBox(color: Color.alphaBlend(color, p.canvas)),
          ),
          Expanded(
            flex: 6,
            child: ColoredBox(color: Color.alphaBlend(color, p.surface)),
          ),
        ],
      ),
    );
  }
}

class _Checkerboard extends StatelessWidget {
  const _Checkerboard();

  @override
  Widget build(BuildContext context) => const CustomPaint(
    painter: _CheckerboardPainter(),
    size: Size.infinite,
  );
}

class _CheckerboardPainter extends CustomPainter {
  const _CheckerboardPainter();

  static const double _square = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint light = Paint()..color = const Color(0xFFFFFFFF);
    final Paint dark = Paint()..color = const Color(0xFFD5D5D5);
    canvas.drawRect(Offset.zero & size, light);
    for (double y = 0; y < size.height; y += _square) {
      for (double x = 0; x < size.width; x += _square) {
        final bool odd =
            ((x / _square).floor() + (y / _square).floor()) % 2 == 0;
        if (odd) continue;
        canvas.drawRect(Rect.fromLTWH(x, y, _square, _square), dark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerboardPainter oldDelegate) => false;
}

/// One HSV (or alpha) bar: a gradient track plus a thumb that stays visible on
/// both a white and a black end.
class _ChannelBar extends StatefulWidget {
  const _ChannelBar({
    required this.value,
    required this.colors,
    required this.thumbFill,
    required this.thumbRing,
    required this.onChanged,
    required this.onChangeEnd,
    this.under,
  });

  final double value;
  final List<Color> colors;
  final Color thumbFill;
  final Color thumbRing;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  /// Painted beneath the gradient — the checkerboard on the alpha bar.
  final Widget? under;

  @override
  State<_ChannelBar> createState() => _ChannelBarState();
}

class _ChannelBarState extends State<_ChannelBar> {
  static const double _thumbRadius = 7;
  static const double _thumbRingWidth = 1.5;
  static const double _trackHeight = 10;
  static const double _height = 22;

  /// The last value this gesture produced. Read on release so the commit can
  /// never depend on a stale closure.
  late double _latest = widget.value;

  @override
  void didUpdateWidget(covariant _ChannelBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _latest = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double usable = (constraints.maxWidth - _thumbRadius * 2).clamp(
          1.0,
          double.infinity,
        );

        void report(double dx, {required bool commit}) {
          _latest = ((dx - _thumbRadius) / usable).clamp(0.0, 1.0);
          if (commit) {
            widget.onChangeEnd(_latest);
          } else {
            widget.onChanged(_latest);
          }
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) =>
              report(d.localPosition.dx, commit: false),
          onTapUp: (TapUpDetails _) =>
              widget.onChangeEnd(_latest),
          onHorizontalDragStart: (DragStartDetails d) =>
              report(d.localPosition.dx, commit: false),
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              report(d.localPosition.dx, commit: false),
          onHorizontalDragEnd: (DragEndDetails _) =>
              widget.onChangeEnd(_latest),
          child: SizedBox(
            height: _height,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: _thumbRadius,
                  right: _thumbRadius,
                  top: (_height - _trackHeight) / 2,
                  height: _trackHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_trackHeight / 2),
                    child: Stack(
                      children: <Widget>[
                        if (widget.under != null)
                          Positioned.fill(child: widget.under!),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: widget.colors),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: usable * widget.value.clamp(0.0, 1.0),
                  top: (_height - _thumbRadius * 2) / 2,
                  child: Container(
                    width: _thumbRadius * 2,
                    height: _thumbRadius * 2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.thumbFill,
                      border: Border.all(
                        color: widget.thumbRing,
                        width: _thumbRingWidth,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
