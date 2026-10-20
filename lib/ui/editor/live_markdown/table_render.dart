part of '../live_markdown.dart';

/// One inline code token in a cell, as range data for the row renderer.
///
/// [start] and [end] count characters in the cell's painted text (the source
/// the span tree carries), so they can be fed straight to
/// [TextPainter.getBoxesForSelection]. [style] is the code run's own style —
/// the renderer measures it to get the band's height and baseline — and [fill]
/// already has the selection tint mixed in.
class _CellCode {
  const _CellCode({
    required this.start,
    required this.end,
    required this.probe,
    required this.style,
    required this.fill,
  });

  final int start;
  final int end;
  final String probe;
  final TextStyle style;
  final Color fill;
}

class _PaintCell {
  _PaintCell({
    required this.spans,
    required this.cell,
    required this.style,
    required this.dx,
    required this.codeRuns,
  });

  final List<InlineSpan> spans;
  final TableCellGeometry cell;
  final TextStyle style;
  final List<_CellCode> codeRuns;

  /// Left edge of the **text** (not the box), in the table's coordinates.
  /// Comes from [ _CellData.textX ], so a centred or right-aligned column is
  /// painted exactly where the skeleton says its characters are.
  final double dx;
}

/// A rounded fill behind one inline code run, in the cell painter's coordinates.
class _PaintedChip {
  const _PaintedChip(this.rect, this.fill);

  final Rect rect;
  final Color fill;
}

/// One rendered table row.
///
/// ## Why a render object, and why it measures itself zero wide
///
/// The row's source characters are laid out *invisibly* right behind it (see
/// [_tableRowSkeleton]), so the paragraph's own `getPositionForPoint` already
/// maps a click to the right character — the row itself must therefore take no
/// space and, crucially, **refuse every hit**: a `WidgetSpan` child that says
/// "hit me" would swallow the tap before the paragraph ever saw it, and the
/// caret would stop moving. Sizing to `0 × rowHeight` achieves both at once,
/// the same trick [MarkdownDividerLine] uses to paint a full-width rule.
class _TableRowView extends LeafRenderObjectWidget {
  const _TableRowView({
    required this.cells,
    required this.palette,
    required this.rowHeight,
    required this.tableWidth,
    required this.dyShift,
    required this.header,
    required this.last,
    required this.band,
    required this.above,
    required this.below,
    required this.tableId,
    required this.sourceStart,
    required this.rowIndex,
    required this.rowCount,
    required this.textScaler,
    required this.direction,
  });

  final List<_PaintCell> cells;
  final AppPalette palette;
  final double rowHeight;
  final double tableWidth;

  /// How far down the row has to be nudged to sit on its paragraph line — see
  /// [_Table.dyShift].
  final double dyShift;

  /// The row above the divider (bold, and it draws the rule under itself).
  final bool header;

  /// The last row of the block: it closes the grid at the bottom.
  final bool last;

  /// This row's share of the selection, or `null` when the selection does not
  /// reach it — the whole cells it touches, see [_RowBand].
  final _RowBand? band;

  /// The bands of the rows above and below. They are what tells a row which of
  /// its four edges face *out* of the shape: a corner is rounded only where the
  /// shape actually turns, so a stack of equal bands is still one rounded
  /// rectangle rather than one ring per row, while a selection that starts
  /// halfway through the table gets a properly closed left edge.
  final _RowBand? above;
  final _RowBand? below;

  /// Source offset of the block's first line — the table's identity.
  final int tableId;

  /// Source offset of this row's first character, and its index among the
  /// block's non-divider rows. The drag handles hand these straight to
  /// `moveTableRow` / `moveTableColumn`, so the pointer layer never has to
  /// re-parse the document to find out what it grabbed.
  final int sourceStart;
  final int rowIndex;
  final int rowCount;

  final TextScaler textScaler;
  final TextDirection direction;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTableRow(
    cells,
    palette,
    rowHeight,
    tableWidth,
    dyShift,
    header,
    last,
    band,
    above,
    below,
    tableId,
    sourceStart,
    rowIndex,
    rowCount,
    textScaler,
    direction,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderTableRow renderObject) {
    renderObject
      ..cells = cells
      ..palette = palette
      ..rowHeight = rowHeight
      ..tableWidth = tableWidth
      ..dyShift = dyShift
      ..header = header
      ..last = last
      ..band = band
      ..above = above
      ..below = below
      ..tableId = tableId
      ..sourceStart = sourceStart
      ..rowIndex = rowIndex
      ..rowCount = rowCount
      ..textScaler = textScaler
      ..direction = direction;
  }
}

class _RenderTableRow extends RenderBox implements TableRowChrome {
  _RenderTableRow(
    this._cells,
    this._palette,
    this._rowHeight,
    this._tableWidth,
    this._dyShift,
    this._header,
    this._last,
    this._band,
    this._above,
    this._below,
    this._tableId,
    this._sourceStart,
    this._rowIndex,
    this._rowCount,
    this._textScaler,
    this._direction,
  );

  List<_PaintCell> _cells;
  set cells(List<_PaintCell> value) {
    if (identical(value, _cells)) return;
    _cells = value;
    markNeedsLayout();
  }

  AppPalette _palette;
  set palette(AppPalette value) {
    if (value == _palette) return;
    _palette = value;
    markNeedsPaint();
  }

  double _rowHeight;
  set rowHeight(double value) {
    if (value == _rowHeight) return;
    _rowHeight = value;
    markNeedsLayout();
  }

  double _tableWidth;
  set tableWidth(double value) {
    if (value == _tableWidth) return;
    _tableWidth = value;
    markNeedsPaint();
  }

  double _dyShift;
  set dyShift(double value) {
    if (value == _dyShift) return;
    _dyShift = value;
    markNeedsPaint();
  }

  bool _header;
  set header(bool value) {
    if (value == _header) return;
    _header = value;
    markNeedsPaint();
  }

  bool _last;
  set last(bool value) {
    if (value == _last) return;
    _last = value;
    markNeedsPaint();
  }

  _RowBand? _band;
  set band(_RowBand? value) {
    if (value == _band) return;
    _band = value;
    markNeedsPaint();
  }

  _RowBand? _above;
  set above(_RowBand? value) {
    if (value == _above) return;
    _above = value;
    markNeedsPaint();
  }

  _RowBand? _below;
  set below(_RowBand? value) {
    if (value == _below) return;
    _below = value;
    markNeedsPaint();
  }

  int _tableId;
  set tableId(int value) {
    if (value == _tableId) return;
    _tableId = value;
    markNeedsPaint();
  }

  int _sourceStart;
  set sourceStart(int value) {
    if (value == _sourceStart) return;
    _sourceStart = value;
  }

  int _rowIndex;
  set rowIndex(int value) {
    if (value == _rowIndex) return;
    _rowIndex = value;
    markNeedsPaint();
  }

  int _rowCount;
  set rowCount(int value) {
    if (value == _rowCount) return;
    _rowCount = value;
  }

  // ------------------------------------------------------------ the chrome
  //
  // The grips and `+` buttons are painted, not widgets: a `WidgetSpan` child
  // that accepted a hit would swallow the click the caret needs, and the row's
  // own box is deliberately zero-wide. The pointer layer reads the rects back
  // through [chromeTargets] and drives `markdown_actions` itself.

  bool get _paintsColumnGrip => _rowIndex == 0;
  bool get _paintsAddRow => _rowIndex == _rowCount - 1;
  bool get _paintsAddColumn => _rowIndex == 0;

  /// Everything the chrome is drawn with, in this row's own coordinates — the
  /// origin is the table's left edge, the row's own box being one padding
  /// column wide (see [paint]).
  ///
  /// The grips live *outside* the table: left of a row, above a column, with
  /// the two `+` buttons right of and below it. That is where they belong
  /// (Obsidian puts them there too), and it keeps them off the cells the user
  /// is reading. All four are sized for their **glyph**, not for a button:
  /// a bare six-dot grip needs 16x16, a bare plus 12x12.
  Rect rowGripRect() => Rect.fromLTWH(
    -_kChromeGap - _kGrip,
    (_contentHeight - _kGrip) / 2,
    _kGrip,
    _kGrip,
  );

  Rect columnGripRect(int column) {
    final Rect cell = _cellRect(column);
    return Rect.fromLTWH(
      cell.center.dx - _kGrip / 2,
      -_kChromeGap - _kGrip,
      _kGrip,
      _kGrip,
    );
  }

  Rect addRowRect() => Rect.fromLTWH(
    _tableWidth / 2 - _kAdd / 2,
    _contentHeight + _kChromeGap,
    _kAdd,
    _kAdd,
  );

  Rect addColumnRect() => Rect.fromLTWH(
    _tableWidth + _kChromeGap,
    (_contentHeight - _kAdd) / 2,
    _kAdd,
    _kAdd,
  );

  /// Every control this row can paint, in paint order.
  ///
  /// One list, so the drawn controls and the hit-testable ones cannot drift
  /// apart — which is also what lets [chromeVisible] answer for the tests
  /// without anyone reading pixels.
  Iterable<(TableChromeKind, Rect, int)> _controls() sync* {
    yield (TableChromeKind.rowHandle, rowGripRect(), _rowIndex);
    if (_paintsColumnGrip) {
      for (int c = 0; c < _cells.length; c++) {
        yield (TableChromeKind.columnHandle, columnGripRect(c), c);
      }
    }
    if (_paintsAddColumn) {
      yield (TableChromeKind.addColumn, addColumnRect(), -1);
    }
    if (_paintsAddRow) {
      yield (TableChromeKind.addRow, addRowRect(), -1);
    }
  }

  /// Is the pointer within [kTableChromeSlop] of [local]? This — not the caret
  /// — is what makes a control exist on screen.
  bool _hovering(Rect local, [Offset? origin]) {
    final Offset? p = tablePointerPosition.value;
    if (p == null) return false;
    return local
        .shift(origin ?? _paintedOrigin)
        .inflate(kTableChromeSlop)
        .contains(p);
  }

  /// …and is it *on* the glyph rather than merely near the edge? A control
  /// under the pointer is drawn through the accent; its neighbours stay quiet.
  bool _pointing(Rect local) {
    final Offset? p = tablePointerPosition.value;
    if (p == null || !_hovering(local)) return false;
    return local.shift(_paintedOrigin).inflate(2).contains(p);
  }

  /// True while [kind] is the drop target of a drag — the grip the row or
  /// column would land on stays lit even though the pointer has left it.
  bool _dragging(TableChromeKind kind, int index) {
    final TableDragPreview? preview = tableDragPreview.value;
    if (preview == null || preview.tableId != _tableId) return false;
    if (kind == TableChromeKind.rowHandle) {
      return !preview.column &&
          index >= preview.index &&
          index < preview.index + preview.count;
    }
    if (kind == TableChromeKind.columnHandle) {
      return preview.column &&
          index >= preview.index &&
          index < preview.index + preview.count;
    }
    return false;
  }

  bool _visible(TableChromeKind kind, Rect local, int index) =>
      _dragging(kind, index) || _hovering(local);

  /// The box of column [column] in this row, or a zero-width sliver at the
  /// table's right edge when the row has fewer cells than the table.
  Rect _cellRect(int column) {
    if (column < 0 || column >= _cells.length) {
      return Rect.fromLTWH(_tableWidth, 0, 0, _contentHeight);
    }
    final TableCellGeometry c = _cells[column].cell;
    return Rect.fromLTWH(c.x, 0, c.width, _contentHeight);
  }

  // ------------------------------------------------------- the pointer layer

  @override
  int get chromeTableId => _tableId;

  @override
  int get chromeSourceStart => _sourceStart;

  @override
  int get chromeRowIndex => _rowIndex;

  @override
  int get chromeRowCount => _rowCount;

  /// The row's paint origin: `paint` nudges the whole row down by [_dyShift] to
  /// sit on its paragraph line, so the painted box is that much lower than the
  /// box the framework hit-tests. Every rect the pointer layer gets has to be
  /// measured from *here*, or the grips sit a couple of pixels off their paint.
  Offset get _paintedOrigin => localToGlobal(Offset(0, _dyShift));

  @override
  Rect chromeBounds() => _paintedOrigin & Size(_tableWidth, _contentHeight);

  @override
  List<Rect> chromeCells() => <Rect>[
    for (final _PaintCell cell in _cells)
      _paintedOrigin + Offset(cell.cell.x, 0) &
          Size(cell.cell.width, _contentHeight),
  ];

  @override
  List<TableChromeTarget> chromeTargets() {
    final Offset origin = _paintedOrigin;
    return <TableChromeTarget>[
      for (final (TableChromeKind k, Rect r, int i) in _controls())
        TableChromeTarget(k, r.shift(origin), i),
    ];
  }

  @override
  List<TableChromeTarget> chromeVisible() {
    final Offset origin = _paintedOrigin;
    return <TableChromeTarget>[
      for (final (TableChromeKind k, Rect r, int i) in _controls())
        if (_visible(k, r, i)) TableChromeTarget(k, r.shift(origin), i),
    ];
  }

  // ----------------------------------------------------------- the preview

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    tableDragPreview.addListener(markNeedsPaint);
    tablePointerPosition.addListener(_pointerMoved);
  }

  @override
  void detach() {
    tableDragPreview.removeListener(markNeedsPaint);
    tablePointerPosition.removeListener(_pointerMoved);
    super.detach();
  }

  /// Hovering is a paint-only change, so the rows listen to the pointer
  /// themselves instead of the span tree being rebuilt for it.
  ///
  /// Guarded by [_pointerNear]: a mouse moving across a long note would
  /// otherwise repaint every table in it — the whole point of not rebuilding
  /// the tree is lost if the painting is just as eager.
  bool _wereNear = false;

  bool _pointerNear() {
    final Offset? p = tablePointerPosition.value;
    if (p == null) return false;
    final Rect box = _paintedOrigin & Size(_tableWidth, _contentHeight);
    return box
        .inflate(_kChromeGap + _kGrip + kTableChromeSlop + 8)
        .contains(p);
  }

  void _pointerMoved() {
    final bool near = _pointerNear();
    if (!near && !_wereNear) return;
    _wereNear = near;
    markNeedsPaint();
  }

  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    markNeedsLayout();
  }

  TextDirection _direction;
  set direction(TextDirection value) {
    if (value == _direction) return;
    _direction = value;
    markNeedsLayout();
  }

  final List<TextPainter> _painters = <TextPainter>[];
  final List<List<_PaintedChip>> _chips = <List<_PaintedChip>>[];
  double _contentHeight = 0;

  void _disposePainters() {
    for (final TextPainter tp in _painters) {
      tp.dispose();
    }
    _painters.clear();
  }

  @override
  void performLayout() {
    _disposePainters();
    _chips.clear();
    _contentHeight = _rowHeight;
    for (final _PaintCell cell in _cells) {
      final TextPainter tp = TextPainter(
        text: TextSpan(style: cell.style, children: cell.spans),
        textDirection: _direction,
        textScaler: _textScaler,
        // One line, always. A cell that wrapped would paint a second line
        // outside its own row box and cut straight through the row below it —
        // the column widths and the skeleton already guarantee it fits.
        maxLines: 1,
        ellipsis: '…',
      );
      tp.layout(maxWidth: math.max(1, cell.cell.width - 2 * _kCellPad));
      _painters.add(tp);
      _chips.add(_chipsFor(tp, cell));
      _contentHeight = math.max(_contentHeight, tp.height);
    }
    // `_kCellPad` wide, not zero: the row stands on the line's first character
    // and that character has to leave room for the first cell's left padding,
    // or the skeleton under the row would sit 8px left of the painted text.
    // (The table is painted from `-_kCellPad`, so the grid still starts at the
    // text column's left edge.)
    size = constraints.constrain(Size(_kCellPad, _contentHeight));
  }

  /// Measures one rounded chip per inline code run in [cell].
  ///
  /// The horizontal span comes from the cell's own painter — the two collapsed
  /// backticks reserve the padding as `letterSpacing`, so their boxes are the
  /// chip's true ends, squeeze correction and all. Vertically the chip must
  /// match the code run's *line box*, not its ink: a separate painter measures
  /// the mono style, and the band hangs from the cell's baseline exactly like
  /// the prose chip's end caps do.
  List<_PaintedChip> _chipsFor(TextPainter tp, _PaintCell cell) {
    if (cell.codeRuns.isEmpty) return const <_PaintedChip>[];
    final double baseline = tp.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final List<_PaintedChip> chips = <_PaintedChip>[];
    for (final _CellCode code in cell.codeRuns) {
      final List<TextBox> boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: code.start, extentOffset: code.end),
      );
      if (boxes.isEmpty) continue;
      double left = boxes.first.left;
      double right = boxes.first.right;
      for (final TextBox box in boxes) {
        left = math.min(left, box.left);
        right = math.max(right, box.right);
      }
      final TextPainter metrics = TextPainter(
        text: TextSpan(
          text: code.probe.isEmpty ? ' ' : code.probe,
          style: code.style,
        ),
        textDirection: _direction,
        textScaler: _textScaler,
      )..layout();
      final double drop = metrics.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      chips.add(
        _PaintedChip(
          Rect.fromLTRB(
            left,
            baseline - drop,
            right,
            baseline - drop + metrics.height,
          ),
          code.fill,
        ),
      );
      metrics.dispose();
    }
    return chips;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(_kCellPad, _rowHeight));

  /// ⛔ Never take part in hit testing. The invisible skeleton underneath owns
  /// the pointer; if this box absorbed a tap the caret would stop moving.
  @override
  bool hitTestSelf(Offset position) => false;

  @override
  void paint(PaintingContext context, Offset offset) {
    final Canvas canvas = context.canvas;
    final double height = _contentHeight;
    // ⛔ `offset` is the row's own position **inside the paragraph**, and the
    // canvas is *not* translated for us: `RenderParagraph.paintInlineChildren`
    // calls `context.paintChild(child, childOffset + offset)`, so a child that
    // draws at its local (0, 0) lands at the paragraph's origin — which for this
    // editor is the top of the document. Dropping `offset` here is what put the
    // whole frame above the note, user: 「表格的方框在最顶部显示了」. The other
    // two render objects in this file (the indent rail, the divider) both add
    // it; only this one used to believe the canvas came pre-translated.
    //
    // [localToGlobal] is then only good for *sub-pixel* snapping: the paragraph
    // sits at a fractional origin once the editor scrolls, and a 1px rule at a
    // fractional `dy` lands between two device pixels and dissolves into the
    // selection wash instead of closing around it — user: 「四周怎么没有闭合？」.
    final Offset origin = localToGlobal(Offset.zero);
    // The table starts **on the text column's left edge**: the row's own box is
    // one padding column wide and stands on the line's first character (`|`),
    // so that padding is already spent by the paragraph before this point.
    // Both edges are then nudged by less than half a pixel so they land on
    // whole device pixels (`_dyShift` is the row's share of the line height:
    // the placeholder is `PlaceholderAlignment.middle`, so the frame has to be
    // pushed down to the top of the glyphs the cells paint).
    final double left = offset.dx + origin.dx.roundToDouble() - origin.dx;
    final double top =
        offset.dy + (origin.dy + _dyShift).roundToDouble() - origin.dy;
    final double right = left + _tableWidth;
    final double bottom = top + height;

    /// A column boundary in this row's coordinates, snapped to the pixel grid.
    /// Each one is rounded on its own, so the rounding cannot accumulate across
    /// the table and every rule comes out exactly one pixel wide.
    double edgeAt(double tableX) => (left + tableX).roundToDouble();

    final _RowBand? band = _band;
    // The band is a run of whole cells, so it stops on column boundaries — the
    // very ones the grid uses, which is what keeps the border *on* the grid
    // instead of half a pixel beside it.
    final double bl = band == null ? left : edgeAt(math.max(0, band.left));
    final double br = band == null
        ? right
        : edgeAt(math.min(_tableWidth, band.right));
    final double radius = math.min(_kSelectRadius, math.max(0, (br - bl) / 2));
    // Which corners the shape actually *turns* at: only where the row above (or
    // below) does not carry the same edge on. A stack of equal bands is
    // therefore one rounded rectangle, while a band that begins halfway down
    // the table still closes itself off; a step between two rows closes the
    // outward corner and leaves the inward one square, which is what makes the
    // steps read as one shape instead of a pile of boxes.
    final bool roundTL =
        band != null && (_above == null || _above!.left > band.left + 0.5);
    final bool roundTR =
        band != null && (_above == null || _above!.right < band.right - 0.5);
    final bool roundBL =
        band != null && (_below == null || _below!.left > band.left + 0.5);
    final bool roundBR =
        band != null && (_below == null || _below!.right < band.right - 0.5);

    // The selection wash: **one opaque band per row, snapped to whole cells**,
    // rounded only where the shape turns. Stacked, those bands are one
    // continuous shape — that is the whole point.
    //
    // **Dark**, not the 27%-accent selection colour the prose uses: a table is a
    // dense grid of glyphs, and a light band behind all of them washed the text
    // out — user: 「表格的颜色改深一点点，不然看不清晰」. Obsidian's selected
    // table is a near-black purple — measured #272231 against a #1C1C1C page —
    // and a 1px edge, not the fill, is what marks the selection.
    //
    // Opaque, not `selection` itself: the paragraph paints its own
    // text-highlight over the skeleton runs underneath, and blending the two
    // double-purples every glyph box.
    final Color wash = Color.alphaBlend(
      _palette.selectionEdge.withValues(alpha: _header ? 0.18 : 0.11),
      _palette.surface,
    );
    if (band != null) {
      // …which is also why the row's *unselected* share has to be repainted in
      // paper first. That paragraph highlight is a full-column stripe: with the
      // wash covering only a few cells, the stripe would still show next to
      // them and the row would look selected end to end — the exact complaint
      // this band exists to answer.
      final Paint paper = Paint()..color = _palette.surface;
      if (bl > left) {
        canvas.drawRect(Rect.fromLTRB(left, top, bl, bottom), paper);
      }
      if (br < right) {
        canvas.drawRect(Rect.fromLTRB(br, top, right, bottom), paper);
      }
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(bl, top, br, bottom),
          topLeft: roundTL ? Radius.circular(radius) : Radius.zero,
          topRight: roundTR ? Radius.circular(radius) : Radius.zero,
          bottomLeft: roundBL ? Radius.circular(radius) : Radius.zero,
          bottomRight: roundBR ? Radius.circular(radius) : Radius.zero,
        ),
        Paint()..color = wash,
      );
    }

    // What the pointer is proposing to do, if it is dragging a grip: the row or
    // column it would land on, painted as a light accent wash so the drop is
    // not a guess.
    //
    // Under the chips, the grid and the band outline on purpose. Pressing a
    // grip also selects its row/column, and the drop target starts out on that
    // very row — painted last, this wash would cover the selection's edge and
    // the press would look like a plain highlight instead of a selection.
    final TableDragPreview? preview = tableDragPreview.value;
    if (preview != null && preview.tableId == _tableId) {
      final Paint hot = Paint()
        ..color = Color.alphaBlend(
          _palette.accent.withValues(alpha: 0.18),
          _palette.surface,
        );
      if (preview.column) {
        // The destination is a contiguous run: paint the run as one wash with
        // an accent rule down each end, so a block drag reads as a block.
        final int last = math.min(
          _cells.length - 1,
          preview.index + preview.count - 1,
        );
        for (int c = preview.index; c <= last; c++) {
          final Rect cell = _cellRect(c);
          if (cell.width > 0) {
            canvas.drawRect(
              Rect.fromLTWH(left + cell.left, top, cell.width, height),
              hot,
            );
            if (c == preview.index) {
              canvas.drawRect(
                Rect.fromLTWH(left + cell.left, top, 2, height),
                Paint()..color = _palette.accent,
              );
            }
          }
        }
      } else if (_rowIndex >= preview.index &&
          _rowIndex < preview.index + preview.count) {
        canvas.drawRect(Rect.fromLTWH(left, top, _tableWidth, height), hot);
        if (_rowIndex == preview.index) {
          canvas.drawRect(
            Rect.fromLTWH(left, top, _tableWidth, 2),
            Paint()..color = _palette.accent,
          );
        }
      }
    }

    // Inline code's padded, rounded band. A cell is a `TextPainter`, so it
    // cannot carry the prose chip's widget caps; the row paints the band
    // itself, behind the glyphs. It goes down **before** the grid so the rules
    // stay on top — a 26px band on a 28px row otherwise shaves the header's
    // bottom border (「代码挡住了表格的边框」).
    final double chipRadius = _textScaler.scale(_kInlineCodeRadius);
    final Paint chipPaint = Paint();
    for (int i = 0; i < _cells.length && i < _painters.length; i++) {
      if (i >= _chips.length || _chips[i].isEmpty) continue;
      final TextPainter tp = _painters[i];
      final Offset origin = Offset(
        left + _cells[i].dx,
        offset.dy + (height - tp.height) / 2,
      );
      for (final _PaintedChip chip in _chips[i]) {
        chipPaint.color = chip.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            chip.rect.shift(origin),
            Radius.circular(chipRadius),
          ),
          chipPaint,
        );
      }
    }

    // The grid: a rule along the top of every row (plus the bottom of the header
    // and of the last row), and a rule at every column boundary.
    //
    // Inside the wash the rules stay — a table should still read as a table —
    // but in a colour lifted towards the accent, so they sit *in* the band
    // instead of cutting it into rectangles. They are drawn twice rather than
    // split into segments: once in the paper colour across the whole row, then
    // again in the lifted colour with a clip to the band. A rule that runs out
    // of the band therefore changes colour exactly at its edge, and the ones
    // the outline covers (the band's own two sides) are stroked over anyway.
    final Paint line = Paint()..color = _palette.rule;
    final Paint strong = Paint()
      ..color = band == null ? _strongRule(_palette) : _palette.rule;
    final Set<double> edges = <double>{0, _tableWidth};
    for (final _PaintCell cell in _cells) {
      edges
        ..add(cell.cell.x)
        ..add(cell.cell.x + cell.cell.width);
    }
    void grid(Paint paint) {
      canvas.drawRect(Rect.fromLTWH(left, top, _tableWidth, 1), paint);
      for (final double x in edges) {
        canvas.drawRect(Rect.fromLTWH(edgeAt(x), top, 1, height), paint);
      }
    }

    grid(line);
    if (_header || _last) {
      // The header's and the block's closing line are the two strong rules in
      // the grid; `grid` draws one paint only, so it goes down separately.
      canvas.drawRect(Rect.fromLTWH(left, bottom - 1, _tableWidth, 1), strong);
    }
    if (band != null) {
      final RRect shape = RRect.fromRectAndCorners(
        Rect.fromLTRB(bl, top, br, bottom),
        topLeft: roundTL ? Radius.circular(radius) : Radius.zero,
        topRight: roundTR ? Radius.circular(radius) : Radius.zero,
        bottomLeft: roundBL ? Radius.circular(radius) : Radius.zero,
        bottomRight: roundBR ? Radius.circular(radius) : Radius.zero,
      );
      // Lifted off the grid colour rather than off the wash: the rules inside
      // the block stay *rules* (measured #3C3746 on Obsidian's #272231 fill),
      // not accent-bright bars that cut the block into cells.
      final Paint lifted = Paint()
        ..color = Color.alphaBlend(
          _palette.selectionEdge.withValues(alpha: 0.2),
          _palette.rule,
        );
      canvas.save();
      canvas.clipRRect(shape);
      grid(lifted);
      if (_header || _last) {
        canvas.drawRect(
          Rect.fromLTWH(left, bottom - 1, _tableWidth, 1),
          lifted,
        );
      }
      canvas.restore();
      _paintBandOutline(canvas, left, bl, br, top, bottom);
    }

    // The text, last, so the glyphs sit on top of fill and grid alike.
    for (int i = 0; i < _cells.length && i < _painters.length; i++) {
      final _PaintCell cell = _cells[i];
      final TextPainter tp = _painters[i];
      tp.paint(
        canvas,
        Offset(left + cell.dx, offset.dy + (height - tp.height) / 2),
      );
    }

    // …and the chrome over everything, so a washed row cannot paint out its
    // own grips.
    _paintChrome(canvas, left, top);
  }

  /// The grips and the two `+` buttons — **hover-only**, and bare glyphs.
  ///
  /// The style is Obsidian's own edge controls, which is what the user pointed
  /// at: six thin dots and a thin `+` floating in the margin with **nothing**
  /// behind them. So no plate, no ring, no chip — the icon *is* the button.
  ///
  /// Three states, and only three:
  ///  * out of reach  — not painted at all (a table is a page, not a toolbar);
  ///  * at the edge   — the tertiary ink, so the control whispers "here";
  ///  * on the glyph, or the drop target of a drag — the accent, which is the
  ///    whole "you are holding it" feedback.
  void _paintChrome(Canvas canvas, double left, double top) {
    // ⛔ Two different origins, and mixing them up silently draws nothing:
    // the glyphs are drawn at `(left, top)` — paragraph coordinates plus the
    // sub-pixel nudge — while the *hit testing* has to run against
    // [localToGlobal], because a pointer event arrives in global coordinates.
    // Both describe the same point; only their frames of reference differ.
    final Offset painted = Offset(left, top);
    for (final (TableChromeKind kind, Rect local, int index) in _controls()) {
      final bool grabbed = _dragging(kind, index);
      if (!grabbed && !_hovering(local)) continue;
      final bool on = grabbed || _pointing(local);
      final Color color = on ? _palette.accent : _palette.textTertiary;
      final double weight = on ? 1.6 : 1.2;
      final Rect r = local.shift(painted);
      switch (kind) {
        case TableChromeKind.rowHandle:
        case TableChromeKind.columnHandle:
          _paintGrip(canvas, r, color: color);
        case TableChromeKind.addRow:
        case TableChromeKind.addColumn:
          _paintPlus(canvas, r, color: color, weight: weight);
      }
    }
  }

  /// The six dots that say "drag me": two columns of three, the grip everyone
  /// already knows from reorderable lists. A grab *hand* belongs to the cursor
  /// alone — here the dots stay upright for both axes, so a row and a column
  /// read as the same kind of control.
  ///
  /// Repainted from the icon font rather than stroked by hand: the
  /// chrome is painted by a render object, and an [Icon] would need a widget —
  /// which would swallow the taps the skeleton owns.
  void _paintGrip(Canvas canvas, Rect r, {required Color color}) {
    final IconData icon = LucideIcons.gripVertical;
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: _kGrip,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      // The editor's own text scale belongs to the note, not to the chrome;
      // a grip has to stay the same size at any zoom.
      textScaler: TextScaler.noScaling,
    )..layout();
    tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
    tp.dispose();
  }

  void _paintPlus(
    Canvas canvas,
    Rect r, {
    required Color color,
    required double weight,
  }) {
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = weight
      ..strokeCap = StrokeCap.round;
    final double arm = r.width / 2 - weight / 2;
    canvas.drawLine(
      Offset(r.center.dx - arm, r.center.dy),
      Offset(r.center.dx + arm, r.center.dy),
      stroke,
    );
    canvas.drawLine(
      Offset(r.center.dx, r.center.dy - arm),
      Offset(r.center.dx, r.center.dy + arm),
      stroke,
    );
  }

  /// Strokes the block's outline, one row at a time.
  ///
  /// A row owns only the segments that face out of the shape: its two vertical
  /// sides, and the parts of its top and bottom edge that the neighbouring band
  /// does not continue. Nothing is drawn twice and nothing is rounded twice, so
  /// a stack of rows paints exactly one outline — even when the stack steps in
  /// and out as the selection covers a different run of cells.
  ///
  /// ⛔ Every coordinate below is a **stroke centre on a half pixel**, and the
  /// sides and the ends all come off the same two edges ([l]/[r] for a row's
  /// sides, [t]/[b] for its ends). A side and an end therefore share their
  /// corner pixel exactly. Mixing snapped and unsnapped edges — which is what
  /// this did, `bl` for the sides against `bl + 0.5` for the ends — put the
  /// corners half a pixel apart, and the outline came out with four gaps the
  /// width of the stroke: user: 「四周怎么没有闭合？？」.
  void _paintBandOutline(
    Canvas canvas,
    double left,
    double bl,
    double br,
    double top,
    double bottom,
  ) {
    final _RowBand band = _band!;
    // `bl`/`br`/`top`/`bottom` are whole numbers, so a 1px stroke centred on
    // `n + 0.5` covers exactly the pixel row `n .. n+1`: the border lands on
    // the grid rule it replaces instead of straddling it into a grey smear.
    final double l = bl + 0.5;
    final double r = br - 0.5;
    final double t = top + 0.5;
    final double b = bottom - 0.5;
    if (r - l <= 0 || b - t <= 0) return;

    final bool roundTL = _above == null || _above!.left > band.left + 0.5;
    final bool roundTR = _above == null || _above!.right < band.right - 0.5;
    final bool roundBL = _below == null || _below!.left > band.left + 0.5;
    final bool roundBR = _below == null || _below!.right < band.right - 0.5;

    final double rr = math.max(
      0,
      math.min(_kSelectRadius, math.min((r - l) / 2, (b - t) / 2)),
    );
    final double tl = roundTL ? rr : 0;
    final double tr = roundTR ? rr : 0;
    final double blr = roundBL ? rr : 0;
    final double brr = roundBR ? rr : 0;

    /// A step edge, snapped the same way the grid snaps it, then moved to the
    /// stroke's centre. The band's own two sides use [l]/[r] rather than this,
    /// because there the stroke sits *inside* the wash and not on its edge.
    double xAt(double tableX) => (left + tableX).roundToDouble() + 0.5;

    final Path path = Path()
      // The two sides, already shortened by whatever corner radii their ends
      // have — so an end and a side meet at the very same point.
      ..moveTo(l, t + tl)
      ..lineTo(l, b - blr)
      ..moveTo(r, t + tr)
      ..lineTo(r, b - brr);
    for (final (double a, double c) in _exposed(band, _above)) {
      _horizontal(
        path,
        a <= band.left + 0.5 ? l : xAt(a),
        c >= band.right - 0.5 ? r : xAt(c),
        t,
        top: true,
        roundLeft: a <= band.left + 0.5 && roundTL,
        roundRight: c >= band.right - 0.5 && roundTR,
        radius: rr,
      );
    }
    for (final (double a, double c) in _exposed(band, _below)) {
      _horizontal(
        path,
        a <= band.left + 0.5 ? l : xAt(a),
        c >= band.right - 0.5 ? r : xAt(c),
        b,
        top: false,
        roundLeft: a <= band.left + 0.5 && roundBL,
        roundRight: c >= band.right - 0.5 && roundBR,
        radius: rr,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _palette.selectionEdge,
    );
  }

  /// The parts of [band]'s width that [other] does not also cover — i.e. the
  /// bits of this row's top (or bottom) edge that are on the shape's boundary.
  static List<(double, double)> _exposed(_RowBand band, _RowBand? other) {
    if (other == null) return <(double, double)>[(band.left, band.right)];
    final List<(double, double)> out = <(double, double)>[];
    if (other.left > band.left + 0.5) {
      out.add((band.left, math.min(band.right, other.left)));
    }
    if (other.right < band.right - 0.5) {
      out.add((math.max(band.left, other.right), band.right));
    }
    return out;
  }

  /// One horizontal edge of the outline, with a rounded turn at either end
  /// where the shape actually turns.
  ///
  /// A quadratic with the corner point as its control: at a two-pixel radius it
  /// is indistinguishable from a circular arc, and — unlike [Path.arcToPoint]
  /// with its `clockwise` flag — it cannot be built backwards. A backwards arc
  /// ends up on the far side of the edge, which is the other way to leave the
  /// corners open.
  static void _horizontal(
    Path path,
    double x0,
    double x1,
    double y, {
    required bool top,
    required bool roundLeft,
    required bool roundRight,
    required double radius,
  }) {
    if (x1 - x0 < 0.5) return;
    final double lr = roundLeft ? math.min(radius, (x1 - x0) / 2) : 0;
    final double rr = roundRight ? math.min(radius, (x1 - x0) / 2) : 0;
    // The corner turns **into** the row: down from a top edge, up from a
    // bottom one.
    final double into = top ? 1 : -1;
    if (lr > 0) {
      path
        ..moveTo(x0, y + into * lr)
        ..quadraticBezierTo(x0, y, x0 + lr, y);
    } else {
      path.moveTo(x0, y);
    }
    path.lineTo(x1 - rr, y);
    if (rr > 0) {
      path.quadraticBezierTo(x1, y, x1, y + into * rr);
    }
  }
}
