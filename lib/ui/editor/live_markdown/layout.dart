part of '../live_markdown.dart';

// ------------------------------------------------------- the length invariant

/// One character position is all a [WidgetSpan] gets, so every decoration in
/// this file is a widget standing in for the *first* character of the syntax it
/// replaces, followed by [_swallowed].
WidgetSpan _decoration(Widget child) =>
    WidgetSpan(alignment: PlaceholderAlignment.middle, child: child);

/// A widget aligned on the text's baseline rather than on the line's middle.
///
/// The middle of a taller paragraph line and the middle of a shorter run's own
/// line box are not the same point when the two fonts have different ascent
/// ratios; a code chip's ends measured against the line middle sat about a
/// pixel below the run's own background. Baseline alignment lines the cap's
/// box up with the run the moment both are measured with the same style.
WidgetSpan _baselineDecoration(Widget child) => WidgetSpan(
  alignment: PlaceholderAlignment.baseline,
  baseline: TextBaseline.alphabetic,
  child: child,
);

/// The characters a decoration did not consume, collapsed to nothing so the
/// caret still has real offsets to move through.
TextSpan _swallowed(String marker, TextStyle base) => TextSpan(
  text: marker.length <= 1 ? '' : marker.substring(1),
  style: _collapsed(base),
);

/// Turns a designed line-height multiplier into one the paragraph can honour.
///
/// A paragraph rounds every line's *advance* to a whole logical pixel, but it
/// computes that line's box from `fontSize * height` unchanged. `15.5 * 1.78`
/// is 27.59, so every box is 0.41px shorter than the step to the next line;
/// the table's row chrome and the selection's boxes are then measured on a
/// different grid from the glyphs and drift inside their rows. Handing back a
/// multiplier whose product is *already* whole makes the box and the advance
/// agree to the last bit (the box height is `fontSize * height` — verified
/// across 1.7 … 1.9).
///
/// The multiplier moves by at most half a pixel of line spacing, which is not
/// visible as spacing but does put the line grid on whole pixels.
double snapLineHeight(double fontSize, double designed) {
  final double line = fontSize * designed;
  if (line <= 0) return designed;
  return line.roundToDouble() / fontSize;
}

/// Height of one editor row. Full-row decorations (a rule, a code band) need it
/// so they neither shrink nor stretch the line they live on — which means the
/// *rounded* advance, the number the paragraph actually steps by.
double _lineHeightOf(TextStyle base) =>
    ((base.fontSize ?? 15) * (base.height ?? 1.78)).roundToDouble();

/// How much text is laid out above source line [line], in paragraph
/// coordinates — the measure the pane needs to put a line at a given place on
/// screen ("jump to heading", typewriter centring).
///
/// The whole prefix goes through **one** [TextPainter] pass, so a paragraph that
/// wrapped is counted at the width it will really be painted at. That pass can
/// only be handed one style, though, and a heading does not occupy a body row:
/// every heading above [line] comes out of the pass as one body row and is then
/// corrected here by the difference between what it really occupies and that row.
///
/// ⛔ The correction is not optional. Without it the landing point falls short by
/// the sum of those differences, and that sum grows with every heading above the
/// target — a long, heading-heavy note lands tens to hundreds of pixels high.
/// [extractHeadings] is the level source on purpose: the outline panel uses the
/// same scan, and the two have to agree about which line is a heading at all.
///
/// Still approximate for a heading long enough to wrap (the pass sees one line,
/// so the correction adds one line box) and for inline images, which a
/// [TextPainter] lays out at no size.
double textHeightAbove({
  required String text,
  required TextStyle base,
  required AppPalette p,
  required int line,
  double contentWidth = AppLayout.proseMaxWidth,
}) {
  if (line <= 0) return 0;
  final List<String> lines = text.split('\n');
  final int target = line.clamp(0, lines.length - 1);
  int offset = 0;
  for (int i = 0; i < target; i++) {
    offset += lines[i].length + 1;
  }
  if (offset <= 0) return 0;

  // The prefix is every character of the lines above, which always ends on the
  // newline that closed the last of them. Paint that newline and the paragraph
  // opens one more, empty line box — a whole row of overshoot on every measure.
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text.substring(0, offset - 1), style: base),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: contentWidth);
  final double measured = painter.height;
  painter.dispose();

  final double row = _lineHeightOf(base);
  double correction = 0;
  for (final Heading h in extractHeadings(text)) {
    if (h.line >= target) continue;
    correction += _lineHeightOf(_headingStyle(base, p, h.level)) - row;
  }

  // A fenced block's rows are shorter than a body row, and the pass above laid
  // every one of them out at the body style. Same deal as a heading: every row
  // above the target has to give the difference back, or a jump to a heading
  // under a long snippet lands short. The opening fence is a 16px header row,
  // the closing one collapses, and only the code between them is a code row —
  // counting all of them as code rows overshoots by more than a line per block.
  final double codeRow = _lineHeightOf(_codeLine(base, p));
  for (final CodeBlockRange fence in codeBlockRanges(text)) {
    final int startLine = _lineOf(text, fence.start);
    final int endLine = _lineOf(
      text,
      math.min(fence.end, math.max(0, text.length - 1)),
    );
    for (int i = startLine; i <= endLine && i < target; i++) {
      final double actual = i == startLine
          ? _kCodeHeaderHeight
          : (fence.closed && i == endLine ? 0 : codeRow);
      correction += actual - row;
    }
  }
  return measured + correction;
}

_Fence? _blockAt(List<_Fence> blocks, int index) =>
    index >= 0 && index < blocks.length ? blocks[index] : null;

int _lineOf(String text, int offset) {
  int count = 0;
  for (int i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) count++;
  }
  return count;
}

/// Nesting depth from a run of leading whitespace (two spaces ≈ one level).
int _level(String indent) {
  int width = 0;
  for (final int unit in indent.codeUnits) {
    width += unit == 0x09 ? 2 : 1;
  }
  return (width ~/ 2).clamp(0, 5);
}

/// How far one nest level pushes the marker to the right.
///
/// Exactly one marker column (`_taskBox`'s 2 + 15 + 9), so a child's content
/// lines up under its parent's content instead of drifting.
const double _kIndentStep = 26;

/// Distance from the row start to the *centre* of a level's marker — where that
/// level's rail is drawn.
const double _kMarkerCentre = 9.5;
