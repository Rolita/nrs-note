import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/theme_presets.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';
import 'app_color_picker.dart';
import 'preset_picker.dart';

/// Opens the custom-colour editor.
///
/// Centred, behind a **transparent barrier**: the app behind is not dimmed,
/// because it *is* the preview — every drag repaints the real shell, the real
/// editor and the real dialogs. A scrim would demote that to looking at
/// swatches, which is exactly what the editor exists to avoid.
Future<void> showThemeEditorDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: false,
    builder: (BuildContext _) => const ThemeEditorDialog(),
  );
}

class ThemeEditorDialog extends StatefulWidget {
  const ThemeEditorDialog({super.key});

  @override
  State<ThemeEditorDialog> createState() => _ThemeEditorDialogState();
}

class _ThemeEditorDialogState extends State<ThemeEditorDialog> {
  late final SettingsController _settings;

  /// Both keys as they were on entry — one whole pair, so 「取消」 leaves no
  /// residue even if entering the editor had already switched the app to the
  /// custom overlay.
  late final ({ThemePresetId preset, CustomPalette? custom}) _snapshot;

  late CustomPalette _working;

  /// Which *face* is being edited. Not "which face is on screen": with 跟随系统
  /// the user may well be editing the dark board while looking at a light one.
  late Brightness _tab;
  bool _tabSet = false;

  bool _advanced = false;

  /// The one expanded token, by accordion rule.
  AppPaletteToken? _open;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsController>();
    _snapshot = (preset: _settings.themePreset, custom: _settings.customPalette);
    // Seeding from the preset in force gives a board whose colours *are* the
    // ones on screen, so entering the editor changes nothing until the user
    // moves something. An overlay that already exists wins: the editor is how
    // you get back to it.
    final ThemePresetId from = _snapshot.preset == ThemePresetId.custom
        ? ThemePresetId.fallback
        : _snapshot.preset;
    _working = _snapshot.custom ?? ThemePresets.seed(from);
    _settings.themeEditing = true;

    // The two writes that notify are deferred past this frame. A dialog route is
    // inflated *during* the build phase, and notifying there would mark the
    // ancestor `Consumer` dirty mid-build. Deferring costs nothing: the board
    // being previewed is the one already on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _settings.themePreset = ThemePresetId.custom;
      _settings.previewCustomPalette(_working);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tabSet) return;
    _tabSet = true;
    _tab = Theme.of(context).brightness;
  }

  @override
  void dispose() {
    // Backstop for a pop that never came through `_cancel` / `_done`: leaving
    // the tween switched off would keep every later scheme change instant.
    _settings.themeEditing = false;
    super.dispose();
  }

  void _selectTab(Brightness value) {
    if (_tab == value) return;
    setState(() {
      _tab = value;
      _open = null;
    });
  }

  void _setAdvanced(bool value) {
    setState(() {
      _advanced = value;
      // A token the basic view cannot show must not stay expanded behind it.
      if (!value && _open != null && !AppPaletteToken.featured.contains(_open)) {
        _open = null;
      }
    });
  }

  /// One write to the board being edited, live in memory and persisted when the
  /// pointer comes up.
  void _applyToken(
    AppPaletteToken token,
    Color color, {
    required bool commit,
  }) {
    final AppPalette face = _working.paletteFor(_tab);
    final Map<AppPaletteToken, Color> patch = <AppPaletteToken, Color>{
      token: color,
      // Touching the accent always carries its five companions along. Without
      // this, editing the accent from the basic view leaves `onAccent` on its
      // old value and the primary button's label can end up unreadable. Edit a
      // companion *after* the accent if you want a different pairing.
      if (token == AppPaletteToken.accent)
        ..._deriveFromAccent(color, face),
    };
    final CustomPalette next = _working.withTokens(_tab, patch);
    setState(() => _working = next);
    if (commit) {
      _settings.commitCustomPalette(next);
    } else {
      _settings.previewCustomPalette(next);
    }
  }

  void _reset() {
    final CustomPalette next = ThemePresets.seed(ThemePresetId.fallback);
    setState(() => _working = next);
    _settings.previewCustomPalette(next);
  }

  void _cancel() {
    _settings.themeEditing = false;
    _settings.restoreTheme(_snapshot);
    Navigator.of(context).pop();
  }

  void _done() {
    _settings.themeEditing = false;
    _settings.commitCustomPalette(_working);
    _settings.themePreset = ThemePresetId.custom;
    Navigator.of(context).pop();
  }

  /// The accent's five companions, derived in the same step as the accent.
  static Map<AppPaletteToken, Color> _deriveFromAccent(
    Color accent,
    AppPalette p,
  ) => <AppPaletteToken, Color>{
    AppPaletteToken.accentHover: _shiftLightness(
      accent,
      p.isDark ? 0.10 : -0.10,
    ),
    AppPaletteToken.accentSoft: Color.alphaBlend(
      accent.withValues(alpha: p.isDark ? 0.14 : 0.12),
      p.isDark ? p.surfaceRaised : p.surface,
    ),
    AppPaletteToken.onAccent: AppPalette.readableOn(accent),
    AppPaletteToken.selection: accent.withValues(alpha: p.isDark ? 0.30 : 0.20),
    AppPaletteToken.selectionEdge: selectionEdgeFor(accent, p.brightness),
  };

  static Color _shiftLightness(Color c, double delta) {
    final HSLColor hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final AppPalette face = _working.paletteFor(_tab);
    final List<AppPaletteToken> visible = _advanced
        ? AppPaletteToken.values
        : AppPaletteToken.featured;

    return PopScope(
      // Escape and any other pop request mean the same thing as 「取消」.
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _cancel();
      },
      child: Dialog(
        alignment: Alignment.center,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Header(
                brightness: Theme.of(context).brightness,
                mode: _settings.theme.label,
                onClose: _cancel,
              ),
              Divider(height: 1, color: p.outlineSoft),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xl,
                  AppSpace.md,
                  AppSpace.lg,
                  AppSpace.md,
                ),
                child: Row(
                  children: <Widget>[
                    SegmentedToggle<Brightness>(
                      value: _tab,
                      onChanged: _selectTab,
                      items: const <({Brightness value, IconData icon, String label})>[
                        (
                          value: Brightness.light,
                          icon: LucideIcons.sun,
                          label: '浅色',
                        ),
                        (
                          value: Brightness.dark,
                          icon: LucideIcons.moon,
                          label: '深色',
                        ),
                      ],
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Text(
                        '这里切换的是「正在编辑哪一面」，不是现在显示哪一面。',
                        style: TextStyle(
                          fontSize: AppText.caption,
                          color: p.textTertiary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpace.xl,
                          0,
                          AppSpace.lg,
                          AppSpace.xl,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _AdvancedRow(
                              value: _advanced,
                              onChanged: _setAdvanced,
                            ),
                            for (final TokenGroup group in TokenGroup.values)
                              if (visible.any(
                                (AppPaletteToken t) => t.group == group,
                              ))
                                _GroupBlock(
                                  group: group,
                                  tokens: visible
                                      .where(
                                        (AppPaletteToken t) => t.group == group,
                                      )
                                      .toList(),
                                  face: face,
                                  open: _open,
                                  onToggle: (AppPaletteToken t) => setState(
                                    () => _open = _open == t ? null : t,
                                  ),
                                  onChanged: (AppPaletteToken t, Color c) =>
                                      _applyToken(t, c, commit: false),
                                  onChangeEnd: (AppPaletteToken t, Color c) =>
                                      _applyToken(t, c, commit: true),
                                ),
                          ],
                        ),
                      ),
                    ),
                    VerticalDivider(width: 1, color: p.outlineSoft),
                    Expanded(
                      flex: 2,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpace.lg,
                          0,
                          AppSpace.xl,
                          AppSpace.xl,
                        ),
                        child: _LivePanel(face: face),
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: p.outlineSoft),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.md,
                  AppSpace.sm,
                  AppSpace.md,
                  AppSpace.sm,
                ),
                child: Row(
                  children: <Widget>[
                    AppTextButton(
                      label: '重置为石墨素白',
                      icon: LucideIcons.rotateCcw,
                      onPressed: _reset,
                    ),
                    const Spacer(),
                    AppTextButton(label: '取消', onPressed: _cancel),
                    AppTextButton(
                      label: '完成',
                      icon: LucideIcons.check,
                      tone: p.accent,
                      onPressed: _done,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.brightness,
    required this.mode,
    required this.onClose,
  });

  final Brightness brightness;
  final String mode;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.lg,
        AppSpace.md,
        AppSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '自定义配色',
                  style: TextStyle(
                    fontSize: AppText.display,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '当前生效：${brightness == Brightness.dark ? '深色' : '浅色'}（$mode）',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: p.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          AppIconButton(
            icon: LucideIcons.x,
            tooltip: '关闭 · 等于取消',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _AdvancedRow extends StatelessWidget {
  const _AdvancedRow({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '高级 · 显示全部 25 个令牌',
              style: TextStyle(fontSize: AppText.ui, color: p.textSecondary),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// One labelled group of token rows.
class _GroupBlock extends StatelessWidget {
  const _GroupBlock({
    required this.group,
    required this.tokens,
    required this.face,
    required this.open,
    required this.onToggle,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final TokenGroup group;
  final List<AppPaletteToken> tokens;
  final AppPalette face;
  final AppPaletteToken? open;
  final ValueChanged<AppPaletteToken> onToggle;
  final void Function(AppPaletteToken, Color) onChanged;
  final void Function(AppPaletteToken, Color) onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpace.lg,
            bottom: AppSpace.xs,
          ),
          child: Text(
            group.label,
            style: TextStyle(
              fontSize: AppText.label,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: p.textTertiary,
            ),
          ),
        ),
        for (final AppPaletteToken t in tokens)
          _TokenRow(
            key: Key('token-${t.name}'),
            token: t,
            color: face.colorOf(t),
            open: open == t,
            onToggle: () => onToggle(t),
            onChanged: (Color c) => onChanged(t, c),
            onChangeEnd: (Color c) => onChangeEnd(t, c),
          ),
      ],
    );
  }
}

/// A colour name, the token's wire name, its swatch, and its hex — expanding a
/// picker underneath when tapped.
class _TokenRow extends StatefulWidget {
  const _TokenRow({
    super.key,
    required this.token,
    required this.color,
    required this.open,
    required this.onToggle,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final AppPaletteToken token;
  final Color color;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<Color> onChanged;
  final ValueChanged<Color> onChangeEnd;

  @override
  State<_TokenRow> createState() => _TokenRowState();
}

class _TokenRowState extends State<_TokenRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onToggle,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: AppSpace.xs + 2,
              ),
              decoration: BoxDecoration(
                color: widget.open
                    ? p.accentSoft
                    : (_hovered ? p.surfaceRaised : Colors.transparent),
                borderRadius: AppRadius.smAll,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.token.label,
                          style: TextStyle(
                            fontSize: AppText.ui,
                            fontWeight: FontWeight.w500,
                            color: p.textPrimary,
                          ),
                        ),
                        Text(
                          widget.token.name,
                          style: TextStyle(
                            fontSize: AppText.caption - 1,
                            fontFamily: AppFonts.mono,
                            fontFamilyFallback: AppFonts.monoFallback,
                            color: p.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _SwatchBlock(color: widget.color),
                  const SizedBox(width: AppSpace.sm + 2),
                  SizedBox(
                    width: 86,
                    child: Text(
                      hexText(widget.color),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: AppText.mono,
                        fontFamily: AppFonts.mono,
                        fontFamilyFallback: AppFonts.monoFallback,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (widget.open)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.sm,
              AppSpace.sm,
              AppSpace.sm,
              AppSpace.lg,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AppColorPicker(
                key: Key('picker-${widget.token.name}'),
                color: widget.color,
                showAlpha: widget.token.hasAlpha,
                onChanged: widget.onChanged,
                onChangeEnd: widget.onChangeEnd,
              ),
            ),
          ),
      ],
    );
  }
}

/// 24×24, checked against a checkerboard when it is translucent so an almost
/// transparent colour does not read as "no colour".
class _SwatchBlock extends StatelessWidget {
  const _SwatchBlock({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      width: 24,
      height: 24,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outline),
      ),
      child: Stack(
        children: <Widget>[
          if (color.a < 1) ...<Widget>[
            const Positioned.fill(child: ColoredBox(color: Color(0xFFFFFFFF))),
            Positioned.fill(
              child: CustomPaint(painter: const _SwatchCheckers()),
            ),
          ],
          Positioned.fill(child: ColoredBox(color: color)),
        ],
      ),
    );
  }
}

class _SwatchCheckers extends CustomPainter {
  const _SwatchCheckers();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = const Color(0xFFD5D5D5);
    const double square = 5;
    for (double y = 0; y < size.height; y += square) {
      for (double x = 0; x < size.width; x += square) {
        final bool odd =
            ((x / square).floor() + (y / square).floor()) % 2 != 0;
        if (odd) canvas.drawRect(Rect.fromLTWH(x, y, square, square), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SwatchCheckers oldDelegate) => false;
}

/// The right-hand half: what the board being edited actually looks like.
///
/// Painted entirely from [face] — the app's own palette is deliberately not
/// consulted, or the panel could not show a face the app is not currently
/// displaying.
class _LivePanel extends StatelessWidget {
  const _LivePanel({required this.face});

  final AppPalette face;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final double textOnSurface = AppPalette.contrastRatio(
      face.textPrimary,
      face.surface,
    );
    final double onAccent = AppPalette.contrastRatio(face.onAccent, face.accent);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            top: AppSpace.lg,
            bottom: AppSpace.sm,
          ),
          child: Text(
            '预览',
            style: TextStyle(
              fontSize: AppText.label,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: p.textTertiary,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: p.outlineSoft),
          ),
          child: ClipRRect(
            borderRadius: AppRadius.mdAll,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                MiniShell(
                  palette: face,
                  width: double.infinity,
                  height: 220,
                ),
                SizedBox(
                  height: 16,
                  child: Row(
                    children: <Widget>[
                      for (final AppPaletteToken t in AppPaletteToken.featured)
                        Expanded(child: ColoredBox(color: face.colorOf(t))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpace.md),
        _Reading(label: '正文 / 内容面', ratio: textOnSurface),
        const SizedBox(height: AppSpace.xxs),
        _Reading(label: '强调上文字 / 强调色', ratio: onAccent),
      ],
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({required this.label, required this.ratio});

  final String label;
  final double ratio;

  /// WCAG AA for body text. Below it the user has built a pair that cannot be
  /// read, which is worth saying out loud.
  static const double _aaBody = 4.5;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool low = ratio < _aaBody;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
          ),
        ),
        Icon(
          low ? LucideIcons.triangleAlert : LucideIcons.check,
          size: AppIconSize.xs,
          color: low ? p.danger : p.textTertiary,
        ),
        const SizedBox(width: AppSpace.xs + 2),
        Text(
          '${ratio.toStringAsFixed(1)} : 1',
          style: TextStyle(
            fontSize: AppText.mono,
            fontFamily: AppFonts.mono,
            fontFamilyFallback: AppFonts.monoFallback,
            color: low ? p.danger : p.textSecondary,
          ),
        ),
      ],
    );
  }
}
