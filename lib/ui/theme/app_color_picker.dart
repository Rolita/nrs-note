import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../common/app_widgets.dart';
import 'screen_eyedropper.dart';

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

  /// 正在跑的那一枪吸管。取色期间整窗都被覆盖层挡着，只有 Esc 或单击能结束，
  /// 所以这一路上不可能同时冒出第二枪。
  EyedropSession? _session;
  bool _sampling = false;

  /// 吸管用不了时留在取色器上的一句话。下一枪或下一次改动颜色就撤掉。
  String? _eyedropNotice;

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
    // 取色还没结束就被收掉（比如整个编辑器关了）：会话会把盖在窗口上的
    // 那一层一并摘走，不留下一个吃掉所有点击的透明罩。
    _session?.end();
    _hexFocus.removeListener(_onHexFocusChanged);
    _hexFocus.dispose();
    _hexController.dispose();
    super.dispose();
  }

  void _adopt(Color color) {
    _hsv = HSVColor.fromColor(color);
    _alpha = (color.a * 255).round();
    _hexError = null;
    // 换了令牌（或颜色被别处改了）就把上一句吸管提示收掉。
    _eyedropNotice = null;
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

  /// 吸管：取屏幕上任意位置的颜色。
  ///
  /// 屏幕像素是不透明的，所以带 alpha 的令牌保留自己原来的字节 ——
  /// 否则取一次色就把「选区」「投影」「遮罩」变成实心色块了。
  Future<void> _sampleScreen() async {
    if (_session != null) return;
    // 取色途中会把扫到的颜色实时写进预览（并让整个应用一起跟着变），取消
    // 时得退回这一枪之前的颜色，否则 Esc 会留下一个没人确认过的配色。
    final Color before = _current;
    setState(() => _eyedropNotice = null);
    final EyedropSession? session = startScreenEyedrop(context);
    if (session == null) return;

    setState(() {
      _session = session;
      _sampling = true;
    });
    // 光标走到哪，预览跟到哪。取色期间窗口被压成屏幕底部一条，这条路是
    // 唯一还能看见「现在指着的是什么颜色」的地方；窗口没被压时（非
    // Windows）就是取色器里的色块和三条色带跟着走。
    void followLive() {
      final Color? live = session.live.value;
      if (!mounted || live == null) return;
      _previewLive(live);
    }

    session.live.addListener(followLive);
    final Color? picked = await session.done;
    session.live.removeListener(followLive);
    if (!mounted) return;
    setState(() {
      _session = null;
      _sampling = false;
      // 原生没回应（例如跑的还是没带这个通道的旧构建）时说一句，别闪一下
      // 就没了 —— 用户会以为是点了没反应。按 Esc 取消则什么都不说。
      if (picked == null && session.unavailable) {
        _eyedropNotice = '吸管需要 Windows 桌面版的原生通道，当前进程没有回应。';
      }
    });
    if (picked == null) {
      if (!_nearly(before, _current)) _preview(before);
      return;
    }

    _preview(
      widget.showAlpha ? picked.withValues(alpha: _alpha / 255) : picked,
      commit: true,
    );
  }

  /// 取色过程中的预览：进界面、不落盘，也不动 alpha。
  ///
  /// 和 [_preview] 的区别只有一点：屏幕像素永远不透明，若照搬它，带 alpha
  /// 的令牌会在光标移动时先变成实心块，直到松手才跳回半透明。
  void _previewLive(Color picked) {
    final Color next = widget.showAlpha
        ? picked.withValues(alpha: _alpha / 255)
        : picked;
    if (_nearly(next, _current)) return;
    _preview(next);
  }

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
              const SizedBox(width: AppSpace.sm),
              AppIconButton(
                key: const Key('eyedropper'),
                icon: LucideIcons.pipette,
                tooltip: '吸管取色 · 取屏幕上任意位置的颜色',
                active: _sampling,
                onPressed: _sampleScreen,
              ),
            ],
          ),
          if (_eyedropNotice != null) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  LucideIcons.info,
                  size: AppIconSize.xs,
                  color: p.warning,
                ),
                const SizedBox(width: AppSpace.xs + 2),
                Expanded(
                  child: Text(
                    _eyedropNotice!,
                    style: TextStyle(
                      fontSize: AppText.caption - 1,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ],
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
