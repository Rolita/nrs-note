import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/theme_presets.dart';

/// The 「配色方案」 picker: one cell per scheme, each previewing its own board.
///
/// Deliberately **not** a [SegmentedToggle]: labelled segments would burst the
/// settings dialog, and that control has no way to show a colour. The cells
/// reuse the same visual language instead — a sunken track, a raised fill on
/// hover, an `accentSoft` fill plus an `accent` ring when selected.
class ThemePresetPicker extends StatelessWidget {
  const ThemePresetPicker({
    super.key,
    required this.value,
    required this.onChanged,
    required this.brightness,
    required this.overrides,
    required this.onEdit,
  });

  /// The scheme currently in force.
  final ThemePresetId value;

  /// Fired for every cell — tapping a cell only switches to that scheme.
  final ValueChanged<ThemePresetId> onChanged;

  /// Which face of each board to preview: the light one in light mode, the dark
  /// one in dark mode. The cell then shows what the user would actually get.
  final Brightness brightness;

  /// The user's edits to a given scheme, so the cell previews *their* colours
  /// rather than the factory ones once they have changed something.
  final PaletteOverride? Function(ThemePresetId preset) overrides;

  /// Opens the editor for a scheme. Wired to that cell's corner badge.
  final ValueChanged<ThemePresetId> onEdit;

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
        children: <Widget>[
          for (final ThemePresetId id in ThemePresetId.values) ...<Widget>[
            if (id != ThemePresetId.values.first)
              const SizedBox(width: AppSpace.xxs),
            Expanded(
              child: _PresetCell(
                key: Key('preset-${id.name}'),
                label: id.label,
                selected: id == value,
                badge: LucideIcons.squarePen,
                onTap: () => onChanged(id),
                onBadgeTap: () => onEdit(id),
                editTooltip: '编辑「${id.label}」',
                preview: MiniShell(palette: _boardFor(id, brightness)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Which board a cell draws: the user's overlay when this scheme has one,
  /// the factory board otherwise.
  AppPalette _boardFor(ThemePresetId id, Brightness brightness) {
    final PaletteOverride? layer = overrides(id);
    if (layer != null) return layer.paletteFor(brightness);
    return ThemePresets.of(id).paletteFor(brightness);
  }
}

/// A thumbnail of the shell, painted from an **explicit** palette.
///
/// Note the missing `context.palette`: a preview must never read the palette in
/// force, or every cell would draw the same board. Canvas underneath, a sidebar
/// strip down the left, a surface block in the middle, and an accent bar along
/// the bottom — enough to judge a scheme at a glance.
///
/// Everything inside is scaled from the box rather than hard-coded, so the same
/// widget serves the 44×30 cell in the settings dialog and the much larger
/// preview in the editor.
class MiniShell extends StatelessWidget {
  const MiniShell({
    super.key,
    required this.palette,
    this.width = 44,
    this.height = 30,
  });

  final AppPalette palette;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double w = c.maxWidth;
            final double h = c.maxHeight;
            return Stack(
              children: <Widget>[
                Positioned.fill(child: ColoredBox(color: palette.canvas)),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: w * 10 / 44,
                  child: ColoredBox(color: palette.sidebar),
                ),
                Positioned(
                  left: w * 14 / 44,
                  top: h * 5 / 30,
                  right: w * 5 / 44,
                  bottom: h * 7 / 30,
                  child: ColoredBox(color: palette.surface),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: h * 2 / 30,
                  child: ColoredBox(color: palette.accent),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _PresetCell extends StatefulWidget {
  const _PresetCell({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onBadgeTap,
    required this.editTooltip,
    required this.badge,
    required this.preview,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onBadgeTap;
  final String editTooltip;
  final IconData badge;
  final Widget preview;

  @override
  State<_PresetCell> createState() => _PresetCellState();
}

class _PresetCellState extends State<_PresetCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // The ring speaks **the scheme in force**, not the one being previewed:
    // a ring drawn in the previewed colour vanishes exactly on the cell that is
    // selected.
    final Color ring = p.accent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: widget.label,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
            decoration: BoxDecoration(
              color: widget.selected
                  ? p.accentSoft
                  : (_hovered ? p.surfaceRaised : Colors.transparent),
              borderRadius: AppRadius.smAll,
              border: Border.all(
                color: widget.selected ? ring : Colors.transparent,
              ),
            ),
            child: Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    widget.preview,
                    const SizedBox(height: AppSpace.xs + 2),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: widget.selected ? p.accent : p.textSecondary,
                      ),
                    ),
                  ],
                ),
                // Each cell's way into the editor: a pencil on its own top-right
                // corner. Tapping the cell itself only switches the scheme.
                Positioned(
                  top: 0,
                  right: 0,
                  child: Tooltip(
                    message: widget.editTooltip,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: widget.onBadgeTap,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: p.surfaceRaised,
                            shape: BoxShape.circle,
                            border: Border.all(color: p.outline),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            widget.badge,
                            size: 11,
                            color: p.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
