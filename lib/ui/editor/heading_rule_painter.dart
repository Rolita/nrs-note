import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'live_markdown.dart';

/// Paints the hairline under an `## ` heading.
///
/// The design sheet gives an H2 a bottom rule, and it is the one piece of the
/// document's hierarchy that a `TextStyle` cannot express: a decoration belongs
/// to a run of glyphs, not to a line box, and a heading that wraps would end up
/// with a rule under every wrapped row. So it is painted — under the field, in
/// the same coordinates the code slab and the selection wash use, from the boxes
/// the field itself reports for the heading's own characters.
///
/// Only level 2 carries a rule. Level 1 is the note title, which the shell draws
/// as its own field above the body; a rule under every `#` in a note that starts
/// with one would read as a second title bar.
class HeadingRulePainter extends CustomPainter {
  HeadingRulePainter({
    required this.controller,
    required this.scrollController,
    required this.editable,
    required this.editorBox,
    required this.color,
  }) : super(
         repaint: Listenable.merge(<Listenable>[controller, scrollController]),
       );

  final TextEditingController controller;
  final ScrollController scrollController;

  /// Resolves the live field and the box this canvas belongs to, both at paint
  /// time: the render objects are replaced across rebuilds.
  final RenderEditable? Function() editable;
  final RenderBox? Function() editorBox;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderEditable? field = editable();
    final RenderBox? box = editorBox();
    if (field == null || box == null) return;

    final List<CodeBlockRange> fences = codeBlockRanges(controller.text);
    final List<CodeBlockRange> headings = _h2Lines(controller.text, fences);
    if (headings.isEmpty) return;

    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..isAntiAlias = false;

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final CodeBlockRange heading in headings) {
      final List<TextBox> boxes = field.getBoxesForSelection(
        TextSelection(baseOffset: heading.start, extentOffset: heading.end),
      );
      double bottom = -double.infinity;
      double left = double.infinity;
      double right = -double.infinity;
      for (final TextBox glyph in boxes) {
        if (glyph.bottom <= glyph.top) continue;
        bottom = math.max(bottom, glyph.bottom);
        left = math.min(left, glyph.left);
        right = math.max(right, glyph.right);
      }
      if (!bottom.isFinite || right <= left) continue;

      // Half a pixel down: a 1px stroke centred on an integer y straddles two
      // device pixels and comes out as a two-pixel smear on a 1x screen.
      final Offset from = box.globalToLocal(
        field.localToGlobal(Offset(0, bottom + 0.5)),
      );
      final Offset to = box.globalToLocal(
        field.localToGlobal(Offset(field.size.width, bottom + 0.5)),
      );
      canvas.drawLine(from, to, paint);
    }
    canvas.restore();
  }

  /// The source range of every `## ` line, fences excluded.
  ///
  /// A line is a heading only if it starts with exactly two `#` and then a
  /// space — `###` is an H3, `#hashtag` is not a heading at all.
  static List<CodeBlockRange> _h2Lines(
    String text,
    List<CodeBlockRange> fences,
  ) {
    final List<CodeBlockRange> out = <CodeBlockRange>[];
    int at = 0;
    while (at <= text.length) {
      final int breakAt = text.indexOf('\n', at);
      final int end = breakAt < 0 ? text.length : breakAt;
      final String line = text.substring(at, end);
      if (line.startsWith('## ') && !_inside(at, fences)) {
        out.add(CodeBlockRange(start: at, end: end));
      }
      if (breakAt < 0) break;
      at = breakAt + 1;
    }
    return out;
  }

  static bool _inside(int offset, List<CodeBlockRange> fences) {
    for (final CodeBlockRange fence in fences) {
      if (offset >= fence.start && offset < fence.end) return true;
    }
    return false;
  }

  @override
  bool shouldRepaint(HeadingRulePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.controller != controller ||
      oldDelegate.scrollController != scrollController;
}
