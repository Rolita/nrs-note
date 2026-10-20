part of '../live_markdown.dart';

/// The marker shell around a task checkbox.
///
/// [sourceOffset] is the offset of the character this box stands in for.
///
/// ⛔ **Deliberately not tappable.** A `GestureDetector` here would be hit
/// through the `TextPainter`'s *placeholder* box rather than the box the user
/// can see, which drifts apart as soon as the row wraps or the marker column has
/// more than one element — the reported symptom is "the box on the first line
/// works and the others do not". The editor instead runs a `Listener` over the
/// whole field and hit-tests this widget's real paint rect; see
/// `MarkdownEditor`.
class MarkdownTodoCheckbox extends StatelessWidget {
  const MarkdownTodoCheckbox({
    super.key,
    required this.sourceOffset,
    required this.child,
  });

  final int sourceOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

WidgetSpan _taskBox(AppPalette p, bool done, int sourceOffset) => _decoration(
  MarkdownTodoCheckbox(
    sourceOffset: sourceOffset,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Padding(
        padding: const EdgeInsets.only(left: 2, right: 9),
        child: Container(
          width: 15,
          height: 15,
          decoration: BoxDecoration(
            color: done ? p.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(
              color: done ? p.accent : _strongRule(p),
              width: 1.5,
            ),
          ),
          child: done
              ? Icon(LucideIcons.check, size: 11, color: p.onAccent)
              : null,
        ),
      ),
    ),
  ),
);

WidgetSpan _tagChip(
  AppPalette p,
  String tag,
  TextStyle body,
  void Function(String tag) onTap,
) {
  final double size = (body.fontSize ?? 15).clamp(11.0, 15.0);
  return _decoration(
    // The tappable box stays the outermost widget: the pill's hover wash lives
    // in [_TagPill] so the document's own tap detection is unchanged.
    GestureDetector(
      onTap: () => onTap(tag),
      child: _TagPill(tag: tag, size: size, palette: p),
    ),
  );
}

/// A `#tag` pill.
///
/// Stateful only for the hover wash: in the design sheet a tag inverts to a
/// solid accent fill under the pointer, which is the one place in the document
/// where a *word* is also a button. Without it the pill looked like decoration
/// and nobody clicked it.
class _TagPill extends StatefulWidget {
  const _TagPill({
    required this.tag,
    required this.size,
    required this.palette,
  });

  final String tag;
  final double size;
  final AppPalette palette;

  @override
  State<_TagPill> createState() => _TagPillState();
}

class _TagPillState extends State<_TagPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = widget.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          // No border: at 12.5px a hairline around a pill is the difference
          // between "a tag" and "a form field".
          color: _hovered ? p.accent : p.accentSoft,
          borderRadius: AppRadius.smAll,
        ),
        child: Text(
          '#${widget.tag}',
          style: TextStyle(
            fontSize: widget.size * 0.88,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: _hovered ? p.onAccent : p.accent,
          ),
        ),
      ),
    );
  }
}

WidgetSpan _wikiChip(
  AppPalette p,
  String label,
  TextStyle body,
  void Function(String target) onTap,
) => _decoration(
  MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: () => onTap(label),
      child: Text(
        label,
        style: TextStyle(
          fontSize: body.fontSize,
          height: body.height,
          fontWeight: body.fontWeight,
          color: p.accent,
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
          decorationColor: p.accent.withValues(alpha: 0.45),
        ),
      ),
    ),
  ),
);

WidgetSpan _embedChip(
  AppPalette p,
  String label,
  void Function(String target) onTap,
) => _decoration(
  MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: () => onTap(label),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
        decoration: BoxDecoration(
          color: p.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          border: Border.all(color: p.rule),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LucideIcons.paperclip, size: 11, color: p.textTertiary),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: p.textSecondary)),
          ],
        ),
      ),
    ),
  ),
);

WidgetSpan _linkChip(AppPalette p, String label, TextStyle body) => _decoration(
  Text(
    label,
    style: TextStyle(
      fontSize: body.fontSize,
      height: body.height,
      color: p.accent,
      decoration: TextDecoration.underline,
      decorationColor: p.accent.withValues(alpha: 0.35),
    ),
  ),
);

WidgetSpan _imageSpan(AppPalette p, String url, String alt, double maxWidth) =>
    _decoration(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: ClipRRect(
          borderRadius: AppRadius.mdAll,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(120, maxWidth - 24),
              maxHeight: 420,
            ),
            child: Image.network(
              url,
              fit: BoxFit.contain,
              errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                  _brokenImage(p, alt),
            ),
          ),
        ),
      ),
    );

Widget _brokenImage(AppPalette p, String alt) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  decoration: BoxDecoration(
    color: p.surfaceSunken,
    borderRadius: AppRadius.smAll,
    border: Border.all(color: p.rule),
  ),
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(LucideIcons.imageOff, size: 13, color: p.textTertiary),
      const SizedBox(width: 6),
      Text(
        alt.trim().isEmpty ? '图片无法加载' : alt.trim(),
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: p.textTertiary,
        ),
      ),
    ],
  ),
);

/// One rounded end of an inline code chip, standing in for a backtick.
///
/// A [TextStyle.backgroundColor] can only paint a rectangle flush with the
/// glyphs, so the padding and the rounded corners are carried by the two
/// characters the syntax already has: each backtick collapses into a fixed-width
/// box that paints its half of the chip. The run between them keeps a plain
/// background; together the three pieces read as one continuous chip, and no
/// source character is lost — the caret still steps through the backticks.
///
/// The box is measured from [probe] under the same [style] as the run, and it
/// is placed by **baseline**, not by the line's middle. That is what keeps the
/// cap and the run's own background on the same two horizontal edges when the
/// paragraph font and the mono font have different ascent ratios.
class _InlineCodeEnd extends LeafRenderObjectWidget {
  const _InlineCodeEnd({
    required this.width,
    required this.radius,
    required this.color,
    required this.roundStart,
    required this.probe,
    required this.style,
    required this.textDirection,
    required this.textScaler,
  });

  final double width;
  final double radius;
  final Color color;

  /// Whether the rounded corners are on the visual start side — left in LTR,
  /// right in RTL. The other side stays square and bleeds into the code run.
  final bool roundStart;

  /// The code itself: measuring the real content keeps a fallback glyph (CJK
  /// in a code span, say) from changing the run's metrics behind the cap's back.
  final String probe;
  final TextStyle style;
  final TextDirection textDirection;
  final TextScaler textScaler;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderInlineCodeEnd(
    width,
    radius,
    color,
    roundStart,
    probe,
    style,
    textDirection,
    textScaler,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderInlineCodeEnd renderObject,
  ) {
    renderObject
      ..width = width
      ..radius = radius
      ..color = color
      ..roundStart = roundStart
      ..setMetrics(probe, style, textDirection, textScaler);
  }
}

class _RenderInlineCodeEnd extends RenderBox {
  _RenderInlineCodeEnd(
    this._width,
    this._radius,
    this._color,
    this._roundStart,
    String probe,
    TextStyle style,
    TextDirection textDirection,
    TextScaler textScaler,
  ) : _metrics = _measure(probe, style, textDirection, textScaler);

  /// The line the cap must be as tall as, and the baseline it hangs from.
  static TextPainter _measure(
    String probe,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
  ) => TextPainter(
    text: TextSpan(text: probe.isEmpty ? ' ' : probe, style: style),
    textDirection: direction,
    textScaler: scaler,
  )..layout();

  TextPainter _metrics;

  double _width;
  double get width => _width;
  set width(double value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  double _radius;
  double get radius => _radius;
  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  Color _color;
  Color get color => _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  bool _roundStart;
  bool get roundStart => _roundStart;
  set roundStart(bool value) {
    if (value == _roundStart) return;
    _roundStart = value;
    markNeedsPaint();
  }

  void setMetrics(
    String probe,
    TextStyle style,
    TextDirection direction,
    TextScaler scaler,
  ) {
    final TextPainter next = _measure(probe, style, direction, scaler);
    if (next.height == _metrics.height &&
        next.computeDistanceToActualBaseline(TextBaseline.alphabetic) ==
            _metrics.computeDistanceToActualBaseline(TextBaseline.alphabetic)) {
      next.dispose();
      return;
    }
    _metrics.dispose();
    _metrics = next;
    markNeedsLayout();
  }

  Size _size() => Size(_width, _metrics.height);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      _metrics.computeDistanceToActualBaseline(baseline);

  @override
  void performLayout() {
    size = constraints.constrain(_size());
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_size());

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_width <= 0 || size.height <= 0 || _color.a == 0) return;
    // Bleed one pixel towards the run: cap and run paint two abutting
    // rectangles, and antialiasing each edge separately leaves a hairline
    // seam between them at fractional device-pixel ratios. Both sides are the
    // same colour, so the overlap is invisible.
    final Rect band = Rect.fromLTWH(
      offset.dx + (_roundStart ? 0 : -1),
      offset.dy,
      _width + 1,
      size.height,
    );
    final Radius corner = Radius.circular(_radius);
    final RRect shape = _roundStart
        ? RRect.fromRectAndCorners(
            band,
            topLeft: corner,
            bottomLeft: corner,
          )
        : RRect.fromRectAndCorners(
            band,
            topRight: corner,
            bottomRight: corner,
          );
    context.canvas.drawRRect(shape, Paint()..color = _color);
  }

  @override
  void dispose() {
    _metrics.dispose();
    super.dispose();
  }

  /// ⛔ Never take part in hit testing — a click on the chip's padding has to
  /// place the caret, exactly like a click on the backtick it replaced.
  @override
  bool hitTestSelf(Offset position) => false;
}
