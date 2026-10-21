import 'package:flutter/widgets.dart';

import 'line_layout/render_line_editable.dart';

/// Width of the wash an empty line gets while it is part of a selection.
///
/// Typora paints a narrow gutter bar on the empty lines between two selected
/// paragraphs; four logical pixels is the width its screenshot shows. The bar
/// is deliberately not full-width: the rest of the selection hugs the glyphs
/// (`BoxWidthStyle.tight`), and a full stripe on blank lines alone would read as
/// a different, much heavier selection.
const double kBlankLineSelectionWidth = 4;

/// The paper left showing between two lines of a selection, in logical pixels.
///
/// The field paints its boxes edge to edge, so a multi-line selection reads as
/// one solid block. Obsidian's source view measures 22px of wash on a 24px
/// line, and that two-pixel seam is what makes the selection read line by line
/// instead of as a filled rectangle.
const double kSelectionLineGap = 2;

/// Start offsets of the empty source lines that [selection] covers.
///
/// An empty line is a newline with no characters before it. It counts as
/// selected when its own offset is inside the selection: the line is "started"
/// but not finished, exactly the way a text line is selected from its first
/// character. A selection that stops *at* the empty line's start leaves it out,
/// and so does one that starts after its newline; in both cases the empty line
/// is the paper between two selected paragraphs, not part of the selection.
///
/// The phantom line after a trailing newline is never included: its start is
/// the document length, which is the selection end at most, never inside it.
List<int> selectedBlankLineStarts(String text, TextSelection selection) {
  if (!selection.isValid || selection.isCollapsed) return const <int>[];
  final int from = selection.start.clamp(0, text.length);
  final int to = selection.end.clamp(0, text.length);
  if (from >= to) return const <int>[];

  final List<int> starts = <int>[];
  int lineStart = 0;
  while (lineStart < text.length) {
    final int newline = text.indexOf('\n', lineStart);
    final int lineEnd = newline < 0 ? text.length : newline;
    if (lineEnd == lineStart && lineStart >= from && lineStart < to) {
      starts.add(lineStart);
    }
    if (newline < 0) break;
    lineStart = newline + 1;
  }
  return starts;
}

/// Paints the selection's wash on the paper **behind** the field.
///
/// The main field's own selection colour is transparent (`MarkdownEditor`),
/// because its boxes tile: every line's band touches the next one, so a
/// multi-line selection is one solid block. Meanwhile the bands themselves come
/// from the line engine ([RenderLineEditable.selectionBands]) — one box per
/// visual line, tight to the glyphs — so this painter only takes
/// [kSelectionLineGap] out of each one, half at the top and half at the bottom.
/// A selection therefore keeps its tight width, its whole-pixel line grid and
/// its blank-line bars, and gains the seam Obsidian shows.
///
/// It sits under the field: glyphs, inline-code slabs and the table's opaque
/// row paint stay on top. It repaints straight off the controller, the scroll
/// position and the focus node, so selecting, scrolling and focusing need no
/// widget rebuild. Hidden while the field is unfocused, which is what the
/// field's own selection does.
class EditorSelectionPainter extends CustomPainter {
  EditorSelectionPainter({
    required this.controller,
    required this.scrollController,
    required this.focusNode,
    required this.editable,
    required this.editorBox,
    required this.color,
  }) : super(
         repaint: Listenable.merge(<Listenable>[
           controller,
           scrollController,
           focusNode,
         ]),
       );

  final TextEditingController controller;
  final ScrollController scrollController;
  final FocusNode focusNode;

  /// Resolves the live field and the box this painter's canvas belongs to.
  /// Both are looked up at paint time: the render objects are replaced across
  /// rebuilds, and either can be legitimately absent while the pane is being
  /// assembled.
  final RenderLineEditable? Function() editable;
  final RenderBox? Function() editorBox;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final TextSelection selection = controller.selection;
    if (!focusNode.hasFocus || !selection.isValid || selection.isCollapsed) {
      return;
    }
    final RenderLineEditable? field = editable();
    final RenderBox? box = editorBox();
    if (field == null || box == null) return;

    final Paint paint = Paint()..color = color;
    final Rect bounds = Offset.zero & size;

    void drawBand(Rect local) {
      if (local.width <= 0 || local.height <= 0) return;
      final Rect global = Rect.fromPoints(
        field.localToGlobal(local.topLeft),
        field.localToGlobal(local.bottomRight),
      );
      final Rect band = Rect.fromPoints(
        box.globalToLocal(global.topLeft),
        box.globalToLocal(global.bottomRight),
      );
      final Rect visible = band.intersect(bounds);
      if (visible.isEmpty) return;
      canvas.drawRect(visible, paint);
    }

    /// A row's band, pulled in by the half-seam at each end.
    Rect bandOf(Rect glyph, {double? width}) {
      final double top = glyph.top + kSelectionLineGap / 2;
      final double bottom = glyph.bottom - kSelectionLineGap / 2;
      if (bottom <= top) return Rect.zero;
      return Rect.fromLTRB(
        glyph.left,
        top,
        width == null ? glyph.right : glyph.left + width,
        bottom,
      );
    }

    // Every ordinary run in the selection. A zero-width band is a newline —
    // the engine reports one for every line the selection only brushes — and
    // has no pixels of its own to wash.
    for (final Rect glyph in field.selectionBands(selection)) {
      if (glyph.width <= 0) continue;
      drawBand(bandOf(glyph));
    }

    // An empty line has no glyphs at all, so it gets the narrow bar instead.
    for (final int start in selectedBlankLineStarts(
      controller.text,
      selection,
    )) {
      for (final Rect glyph in field.selectionBands(
        TextSelection(baseOffset: start, extentOffset: start + 1),
      )) {
        drawBand(bandOf(glyph, width: kBlankLineSelectionWidth));
      }
    }
  }

  @override
  bool shouldRepaint(EditorSelectionPainter oldDelegate) {
    // The canvas keeps its size while the text inside it reflows — a prose-size
    // change moves every line without resizing the overlay, and a rebuild is
    // the only notification that arrives. Repainting costs nothing next to
    // showing the bands at yesterday's offsets.
    return true;
  }
}
