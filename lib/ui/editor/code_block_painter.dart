import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../core/theme/app_palette.dart';
import 'live_markdown.dart';

/// How far the slab bleeds past the text column on each side.
///
/// The code cannot be moved — it is a `TextField`, and its glyphs start on the
/// column's left edge — so the slab is drawn *wider* than the column instead.
/// The bleed is what reads as the block's inner padding.
const double kCodeSlabBleed = 14;

/// Air above the header row and below the last line of code.
const double kCodeSlabTopPad = 6;
const double kCodeSlabBottomPad = 10;

const double kCodeSlabRadius = 8;

/// The block's fill: a step **up** from the paper in the dark theme (where the
/// card reads as lifted) and a step **down** in the light one (where a lift
/// would be white on white).
Color codeSlabFill(AppPalette p) =>
    p.isDark ? p.surfaceRaised : p.surfaceSunken;

/// Paints one rounded slab behind every fenced code block.
///
/// A `TextStyle` background can only cover the run it belongs to, so a fenced
/// block used to come out as one stripe per line — indented lines narrower than
/// their neighbours, every row separated by the leading. The block has to be
/// one shape, which means paint: this sits under the field, in the same
/// coordinates the selection wash uses, and asks the field for the boxes of the
/// block's own source range so the slab lands on the rows that are really
/// painted there.
class CodeBlockPainter extends CustomPainter {
  CodeBlockPainter({
    required this.controller,
    required this.scrollController,
    required this.editable,
    required this.editorBox,
    required this.fill,
  }) : super(
         repaint: Listenable.merge(<Listenable>[controller, scrollController]),
       );

  final TextEditingController controller;
  final ScrollController scrollController;

  /// Resolves the live field and the box this canvas belongs to, both at paint
  /// time: the render objects are replaced across rebuilds.
  final RenderEditable? Function() editable;
  final RenderBox? Function() editorBox;

  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderEditable? field = editable();
    final RenderBox? box = editorBox();
    if (field == null || box == null) return;

    final String text = controller.text;
    final List<CodeBlockRange> ranges = codeBlockRanges(text);
    if (ranges.isEmpty) return;

    final Rect bounds = Offset.zero & size;
    final Paint paint = Paint()..color = fill;
    canvas.save();
    canvas.clipRect(bounds);
    for (final CodeBlockRange range in ranges) {
      final List<TextBox> boxes = field.getBoxesForSelection(
        TextSelection(baseOffset: range.start, extentOffset: range.end),
      );
      double top = double.infinity;
      double bottom = -double.infinity;
      for (final TextBox glyph in boxes) {
        if (glyph.bottom <= glyph.top) continue;
        top = math.min(top, glyph.top);
        bottom = math.max(bottom, glyph.bottom);
      }
      if (!top.isFinite || bottom <= top) continue;

      final Rect local = Rect.fromLTRB(
        -kCodeSlabBleed,
        top - kCodeSlabTopPad,
        field.size.width + kCodeSlabBleed,
        bottom + kCodeSlabBottomPad,
      );
      final Rect slab = Rect.fromPoints(
        box.globalToLocal(field.localToGlobal(local.topLeft)),
        box.globalToLocal(field.localToGlobal(local.bottomRight)),
      );
      if (slab.isEmpty) continue;
      canvas.drawRRect(
        RRect.fromRectAndRadius(slab, const Radius.circular(kCodeSlabRadius)),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CodeBlockPainter oldDelegate) {
    // The canvas keeps its size while the text inside it reflows, and a font
    // size change moves every row without resizing anything — a rebuild is the
    // only notification that arrives. Repainting is cheap next to leaving the
    // slabs where they were before the last keystroke.
    return true;
  }
}
