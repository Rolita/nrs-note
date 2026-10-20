part of '../live_markdown.dart';

/// The vertical rails down the left of a nested list row.
///
/// One rail per ancestor level, each at that level's marker centre, and exactly
/// one row tall — so consecutive rows butt up against each other and the rails
/// read as one continuous line down a branch rather than a dashed one. The box
/// is as wide as the whole indent ([levels] × [_kIndentStep]) because it *is*
/// the indent: the first leading space of the source stands in for it.
class MarkdownIndentGuides extends LeafRenderObjectWidget {
  const MarkdownIndentGuides({
    super.key,
    required this.levels,
    required this.color,
    required this.rowHeight,
  });

  final int levels;
  final Color color;
  final double rowHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderIndentGuides(levels, color, rowHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderIndentGuides renderObject,
  ) {
    renderObject
      ..levels = levels
      ..color = color
      ..rowHeight = rowHeight;
  }
}

/// [MarkdownIndentGuides]'s render object: `levels × step` wide, rails in
/// `paint`.
class RenderIndentGuides extends RenderBox {
  RenderIndentGuides(this._levels, this._color, this._rowHeight);

  int _levels;
  int get levels => _levels;
  set levels(int value) {
    if (value == _levels) return;
    _levels = value;
    markNeedsLayout();
  }

  Color _color;
  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double _rowHeight;
  double get rowHeight => _rowHeight;
  set rowHeight(double value) {
    if (value == _rowHeight) return;
    _rowHeight = value;
    markNeedsLayout();
  }

  Size _size() => Size(_levels * _kIndentStep, _rowHeight);

  @override
  void performLayout() {
    size = constraints.constrain(_size());
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_size());

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_levels <= 0 || _rowHeight <= 0) return;
    final Paint paint = Paint()..color = _color;
    for (int i = 0; i < _levels; i++) {
      // Half-pixel back so a 1px rail lands on the pixel grid instead of being
      // antialiased across two of them.
      final double x = offset.dx + i * _kIndentStep + _kMarkerCentre - 0.5;
      context.canvas.drawRect(
        Rect.fromLTWH(x, offset.dy, 1, size.height),
        paint,
      );
    }
  }

  /// ⛔ Never take part in hit testing — a click on the rail has to place the
  /// caret, exactly like a click on the indent's whitespace did.
  @override
  bool hitTestSelf(Offset position) => false;
}

// -------------------------------------------------------------- the rule line

/// A horizontal rule (`---`, `***`, `___`), drawn as a full-width line.
///
/// ## Why this is a render object and not a `Container(width: …)`
///
/// A `WidgetSpan` child gets `BoxConstraints(maxWidth: 编辑框宽度)`, so its width
/// could just be a fixed number — except that number has to come from somewhere,
/// and one pixel over the edge makes the paragraph wrap: the row would grow a
/// phantom extra line. This box sidesteps the question entirely by **measuring
/// itself as zero wide** and painting the line out to whatever width its
/// constraints allow. A zero-width inline box can never wrap, and the line is
/// exactly as long as the column at any window size, no matter how many dashes
/// were typed.
///
/// It is `height` tall (a normal text row) with the line centred inside, so the
/// rule keeps the vertical rhythm instead of squashing the rows around it.
class MarkdownDividerLine extends LeafRenderObjectWidget {
  const MarkdownDividerLine({
    super.key,
    required this.color,
    required this.height,
    this.thickness = 1,
    this.inset = 4,
  });

  final Color color;
  final double height;
  final double thickness;
  final double inset;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderMarkdownDividerLine(color, height, thickness, inset);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMarkdownDividerLine renderObject,
  ) {
    renderObject
      ..color = color
      ..rowHeight = height
      ..thickness = thickness
      ..inset = inset;
  }
}

/// [MarkdownDividerLine]'s render object: size `0 × rowHeight`, line in `paint`.
class RenderMarkdownDividerLine extends RenderBox {
  RenderMarkdownDividerLine(
    this._color,
    this._rowHeight,
    this._thickness,
    this._inset,
  );

  Color _color;
  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  double _rowHeight;
  double get rowHeight => _rowHeight;
  set rowHeight(double value) {
    if (value == _rowHeight) return;
    _rowHeight = value;
    markNeedsLayout();
  }

  double _thickness;
  double get thickness => _thickness;
  set thickness(double value) {
    if (value == _thickness) return;
    _thickness = value;
    markNeedsLayout();
  }

  double _inset;
  double get inset => _inset;
  set inset(double value) {
    if (value == _inset) return;
    _inset = value;
    markNeedsPaint();
  }

  /// How long the line turned out to be = the available width at the last
  /// layout pass. Only ever written from [performLayout] — [computeDryLayout] is
  /// a probe and may run after the real layout.
  double _lineWidth = 0;

  /// The width the last layout pass allowed (test-only).
  @visibleForTesting
  double get debugLineWidth => _lineWidth;

  @override
  void performLayout() {
    _lineWidth = constraints.maxWidth;
    size = constraints.constrain(Size(0, _rowHeight));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(0, _rowHeight));

  @override
  void paint(PaintingContext context, Offset offset) {
    final double w = _lineWidth - _inset;
    // Unbounded (or degenerate) constraints: draw nothing rather than throw.
    if (!w.isFinite || w <= 0 || _thickness <= 0) return;
    context.canvas.drawRect(
      Rect.fromLTWH(
        offset.dx + _inset / 2,
        offset.dy + (size.height - _thickness) / 2,
        w,
        _thickness,
      ),
      Paint()..color = _color,
    );
  }

  /// ⛔ Never take part in hit testing — clicking the rule must place the caret.
  @override
  bool hitTestSelf(Offset position) => false;
}
