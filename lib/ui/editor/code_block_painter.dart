import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'live_markdown.dart';

/// How far the slab bleeds past the text column on each side.
///
/// The code cannot be moved — it is a `TextField`, and its glyphs start on the
/// column's left edge — so the slab is drawn *wider* than the column instead.
/// The block's inner padding, and the reason it has to be a bleed.
///
/// The sheet gets its `pre { padding: 14px 16px }` from CSS. Here the code *is*
/// the paragraph: its glyphs start on the column's left edge and a `TextField`
/// has no way to indent one line. So the only way to put air between the code
/// and the block's edge is to draw the block 16px wider than the column on each
/// side. Zero bleed (flush edges, code glued to the border) is the alternative,
/// and it is worse — the block stops reading as a card at all.
const double kCodeSlabBleed = 16;

/// Air above the header row and below the last line of code.
///
/// The header itself is a real (empty) line — [kCodeHeaderHeight] — so the
/// card only needs a couple of pixels above it. The bottom has no line of its
/// own: the closing fence is collapsed, and all of the breathing room below the
/// last code row lives here.
const double kCodeSlabTopPad = 1;
const double kCodeSlabBottomPad = 12;

const double kCodeSlabRadius = AppRadius.sm;

/// The language label, laid into the card's top-right corner the way the
/// reference does: inside the padding, not on a header row that pushes the code
/// down. Measured from the slab's own edge.
const double kCodeSlabLabelTop = 10;
const double kCodeSlabLabelRight = 13;

/// The block's fill: the step that makes the card read as its own surface.
///
/// The reference draws the boundary with the fill alone and no border, and in
/// dark that step goes *up* — `surfaceRaised` is what separates the card from
/// the page. In light nothing sits above the page but pure white, a
/// four-level step that vanishes on screen; the step has to go *down* instead,
/// into the same well the inline chip sits in.
Color codeSlabFill(AppPalette p) =>
    p.isDark ? p.surfaceRaised : p.surfaceSunken;

/// Paints one rounded slab behind every fenced code block, plus its language
/// label.
///
/// A `TextStyle` background can only cover the run it belongs to, so a fenced
/// block used to come out as one stripe per line — indented lines narrower than
/// their neighbours, every row separated by the leading. The block has to be
/// one shape, which means paint: this sits under the field, in the same
/// coordinates the selection wash uses, and asks the field for the boxes of the
/// block's own source range so the slab lands on the rows that are really
/// painted there.
///
/// The label lives here for the same reason. A `WidgetSpan` label would be a
/// line of the paragraph, and that line pushed the first code row a full header
/// below the card's edge. Painted, it can sit in the top-right corner without
/// costing a line, and it can follow the slab when the block scrolls.
class CodeBlockPainter extends CustomPainter {
  CodeBlockPainter({
    required this.controller,
    required this.scrollController,
    required this.editable,
    required this.editorBox,
    required this.fill,
    required this.labelStyle,
    required this.selection,
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

  /// The type on the right of the card's header — `Dart`, `Python`.
  final TextStyle labelStyle;

  /// The selection the renderer is painting for, so the label disappears while
  /// the block is knocked back to its source. `revealAs` freezes that selection
  /// for a drag, which is why this is a callback rather than [controller.selection].
  final TextSelection? Function() selection;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderEditable? field = editable();
    final RenderBox? box = editorBox();
    if (field == null || box == null) return;

    final String text = controller.text;
    final List<CodeBlockRange> ranges = codeBlockRanges(text);
    if (ranges.isEmpty) return;

    final TextSelection? sel = selection();
    final bool hasSelection = sel != null && sel.isValid && sel.start >= 0;

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
      final RRect rounded = RRect.fromRectAndRadius(
        slab,
        const Radius.circular(kCodeSlabRadius),
      );
      canvas.drawRRect(rounded, paint);

      final String? label = range.label;
      if (label == null) continue;
      // When the block is open for editing the fence line shows its source and
      // the label has no meaning; the paragraph is already painting `dart`
      // there. Same rule the header used to follow.
      if (hasSelection &&
          sel.start <= range.end &&
          sel.end >= range.start) {
        continue;
      }
      final TextPainter tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          slab.right - kCodeSlabLabelRight - tp.width,
          slab.top + kCodeSlabLabelTop,
        ),
      );
      tp.dispose();
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
