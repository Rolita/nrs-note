part of '../live_markdown.dart';

/// Where one row's share of the selection sits, in the table's coordinates.
///
/// `left`/`right` are always **cell edges**, never glyph edges. A table is
/// selected by the cell, not by the character: touching two characters of `就写`
/// washes all of `就写`. That is what makes neighbouring cells merge into one
/// band with no seam at the pipe, and — the reason this used to be wrong — what
/// keeps a two-row selection two clean steps instead of a staircase of
/// half-cells with a frame around each step.
/// user: 「这个选中就是按格子来选中啊，跨表格选中文字干什么？？？」
class _RowBand {
  const _RowBand(this.left, this.right);

  final double left;
  final double right;

  /// Same edge, give or take the sub-pixel the cell boxes rounded to.
  bool near(_RowBand? other) =>
      other != null &&
      (other.left - left).abs() < 0.5 &&
      (other.right - right).abs() < 0.5;

  @override
  bool operator ==(Object other) => other is _RowBand && near(other);

  @override
  int get hashCode => Object.hash(left.round(), right.round());
}

/// The selection's band for every painted row of [table], `null` where the
/// selection does not reach.
///
/// A table is selected **by the cell, as a block**: the wash runs from the
/// anchor's cell to the focus's cell — the rows between them, and the columns
/// between them. Reading the selection as a linear text range instead (which is
/// what this did) washes every cell the range passes over, so a drag down one
/// column came back with the whole middle row lit:
/// user: 「我只选了右边三个表格，为什么会把左边那两个一起选中？？？」
List<_RowBand?> _bandsOfTable(_Table table, int a, int b) {
  final int rows = table.rows.length;
  final List<_RowBand?> none = List<_RowBand?>.filled(rows, null);
  if (b <= a || rows == 0) return none;
  if (a >= table.rows.last.end || b <= table.rows.first.start) return none;

  final (int, int) from = _cellAt(table, a, extent: false);
  // `b` is exclusive: the last selected character is the one before it, and on
  // a row boundary that character is the line break above, not the next row's
  // first cell.
  final (int, int) to = _cellAt(table, b - 1, extent: true);
  final int r0 = math.min(from.$1, to.$1);
  final int r1 = math.max(from.$1, to.$1);
  final int c0 = math.min(from.$2, to.$2);
  final int c1 = math.max(from.$2, to.$2);
  return <_RowBand?>[
    for (int r = 0; r < rows; r++)
      r < r0 || r > r1 ? null : _bandOfRow(table.rows[r], c0, c1),
  ];
}

/// Which painted cell an offset belongs to, as `(row, column)` indices.
///
/// An offset that sits between two rows — a line break, or the `--- | ---`
/// divider — belongs to the row it *reads* into: the one below for an anchor
/// (the caret is at the start of that row's text) and the one above for an
/// extent (the last character selected is the one before the break).
(int, int) _cellAt(_Table table, int offset, {required bool extent}) {
  final List<_RowData> rows = table.rows;
  for (int r = 0; r < rows.length; r++) {
    final _RowData row = rows[r];
    if (offset < row.start) {
      if (!extent || r == 0) return (r, 0);
      return (r - 1, rows[r - 1].data.length - 1);
    }
    if (offset >= row.end || row.data.isEmpty) continue;
    for (int c = 0; c < row.data.length; c++) {
      final _CellData d = row.data[c];
      final int start = d.cell.offset;
      final int end = start + d.cell.text.length;
      if (offset < end) return (r, c);
    }
    // Past the last cell: the row's trailing pipe, which belongs to it.
    return (r, row.data.length - 1);
  }
  if (offset < rows.first.start) return (0, 0);
  return (rows.length - 1, rows.last.data.length - 1);
}

/// Columns `[c0, c1]` of one row, as one span from the first cell's left edge to
/// the last one's right edge. The cells tile the row edge to edge, so this is
/// also where two neighbours merge into one band with no seam at the pipe.
_RowBand? _bandOfRow(_RowData row, int c0, int c1) {
  if (row.data.isEmpty) return null;
  final _CellData first = row.data[c0.clamp(0, row.data.length - 1)];
  final _CellData last = row.data[c1.clamp(0, row.data.length - 1)];
  final double left = first.x;
  final double right = last.x + last.boxWidth;
  if (right - left < 0.5) return null;
  return _RowBand(left, right);
}

/// Natural width of a cell: its *painted* span tree, measured on one line.
///
/// The tree, not the raw source — measuring `**加粗**` would hand the column two
/// asterisks' worth of width that nobody can see, and every click in the cell
/// would land on a hidden character instead of the one under the pointer.
double _measureSpans(
  List<InlineSpan> spans,
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
) {
  if (spans.isEmpty) return 0;
  final TextPainter tp = TextPainter(
    text: TextSpan(style: style, children: spans),
    textDirection: direction,
    textScaler: scaler,
  );
  tp.layout(maxWidth: double.infinity);
  final double w = tp.width;
  tp.dispose();
  return w;
}

/// Column alignment, read off the divider row (`:---`, `:-:`, `---:`).
///
/// Obsidian honours these, and a column of numbers that refuses to line up on
/// the right is the single most common reason to write them, so the renderer
/// has to as well — including in the skeleton, or a click in a right-aligned
/// cell would land somewhere else entirely.
TextAlign _alignOf(String divider, int column) {
  final List<_ParsedCell> cells = _parseCells(divider, 0);
  if (column >= cells.length) return TextAlign.start;
  final String cell = cells[column].text.trim();
  final bool left = cell.startsWith(':');
  final bool right = cell.endsWith(':');
  if (left && right) return TextAlign.center;
  if (right) return TextAlign.end;
  return TextAlign.start;
}

/// How far a `PlaceholderAlignment.middle` box of [box] height sits above the
/// line it shares with [style]'s text. Positive means "push it back down".
///
/// Flutter centres such a box on the text's mid-line, `(ascent - descent) / 2`
/// above the baseline, while the line's top is a full ascent up. So the box's
/// top lands at `(ascent + descent - box) / 2` relative to the line's top —
/// negative, i.e. above it, whenever the box is shorter than the text's own
/// line box.
double _middleOverhang(
  TextStyle style,
  TextScaler scaler,
  TextDirection direction,
  double box,
) {
  final TextPainter tp = TextPainter(
    text: TextSpan(text: ' ', style: style),
    textDirection: direction,
    textScaler: scaler,
  )..layout();
  final LineMetrics m = tp.computeLineMetrics().first;
  tp.dispose();
  return (box - (m.ascent + m.descent)) / 2;
}

/// One cell's expensive measurement, reused by every later measure.
///
/// A rendered (not being edited) cell's tree depends on nothing but its display
/// text and whether the row is a header: the table context disables the caret,
/// selection and hover reveals, so no absolute offset leaks into the tree.
class _CellMemo {
  _CellMemo({
    required this.text,
    required this.header,
    required this.rendered,
    required this.codes,
    required this.natural,
  });

  final String text;
  final bool header;

  /// The tree as rendered (exactly what the row paints).
  final List<InlineSpan> rendered;

  /// Inline code / tag runs, in cell-relative offsets.
  final List<_CellCode> codes;

  /// Width the rendered tree wants on one line.
  final double natural;

  /// Generation of the last measure that used this cell.
  int usedIn = 0;
}

/// A cell painter plus the chips measured from it, shared across measures.
class _PaintedCell {
  _PaintedCell(this.painter, this.chips);

  final TextPainter painter;
  final List<_PaintedChip> chips;

  int usedIn = 0;
}

/// Per-cell memoization for one `LiveTableBlocks` instance.
///
/// The palette, base style, scale and direction are fixed for the instance, so
/// a cell's tree only has to be rebuilt when its text changes. Entries unused
/// by a measure are swept at the end of it, which keeps a long editing session
/// from growing the store without bound.
class _CellMemoStore {
  final Map<(String, bool), _CellMemo> _cells = <(String, bool), _CellMemo>{};
  final Map<(Object, int, TextAlign), _PaintedCell> _painted =
      <(Object, int, TextAlign), _PaintedCell>{};

  /// 行内代码探针量测结果：`(文字, 样式)` 决定行高与基线距离，与列宽无关。
  final Map<(TextStyle, String), (double, double)> _probes =
      <(TextStyle, String), (double, double)>{};

  /// `_middleOverhang` 的结果：每张表都要问一次，但答案只取决于字体。
  final Map<(TextStyle, double), double> _overhangs =
      <(TextStyle, double), double>{};

  /// 抓手图标 painter。只有强调色与三级文字色两种，按颜色缓存。
  final Map<Color, TextPainter> _grips = <Color, TextPainter>{};

  int _generation = 0;

  /// Cell trees actually built (memo misses). Typing inside one cell adds
  /// none: every other cell, and its own rendered tree, is a hit.
  @visibleForTesting
  int spanBuilds = 0;

  /// Cell painters actually laid out, the cell being edited included.
  @visibleForTesting
  int painterBuilds = 0;

  /// 环境（缩放与方向）在一次实例生命周期内不变：变了宿主会 `clear()`。
  TextScaler _scaler = TextScaler.noScaling;
  TextDirection _direction = TextDirection.ltr;

  int get generation => _generation;

  void useEnvironment(TextScaler scaler, TextDirection direction) {
    _scaler = scaler;
    _direction = direction;
  }

  void beginMeasure() => _generation++;

  _CellMemo? cell(String text, bool header) {
    final _CellMemo? memo = _cells[(text, header)];
    if (memo != null) memo.usedIn = _generation;
    return memo;
  }

  _CellMemo addCell({
    required String text,
    required bool header,
    required List<InlineSpan> rendered,
    required List<_CellCode> codes,
    required double natural,
  }) {
    spanBuilds++;
    return _cells[(text, header)] = _CellMemo(
      text: text,
      header: header,
      rendered: rendered,
      codes: codes,
      natural: natural,
    )..usedIn = _generation;
  }

  _PaintedCell? painted(
    _CellMemo? memo,
    double width,
    TextAlign align,
  ) {
    if (memo == null) return null;
    final _PaintedCell? cell =
        _painted[(memo, _widthKey(width), align)];
    if (cell != null) cell.usedIn = _generation;
    return cell;
  }

  _PaintedCell addPainted({
    required _CellMemo memo,
    required double width,
    required TextAlign align,
    required TextPainter painter,
    required List<_PaintedChip> chips,
  }) {
    final _PaintedCell cell = _PaintedCell(painter, chips)
      ..usedIn = _generation;
    _painted[(memo, _widthKey(width), align)] = cell;
    return cell;
  }

  /// 行内代码探针的 `(基线到顶的距离, 行高)`。
  ///
  /// 每段代码每次测量都会问一次，但答案只取决于文字与样式；探针通常只有一个
  /// 字符，所以重复量测的代价全在建 `TextPainter` 与一次布局上。
  (double, double) probeMetrics(String text, TextStyle style) {
    final (TextStyle, String) key = (style, text);
    final (double, double)? hit = _probes[key];
    if (hit != null) return hit;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: _direction,
      textScaler: _scaler,
    )..layout();
    final (double, double) value = (
      tp.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      tp.height,
    );
    tp.dispose();
    return _probes[key] = value;
  }

  /// 盒子垂直居中相对文字行的上悬量（见 `_middleOverhang`）。
  double overhang(TextStyle style, double box) {
    final (TextStyle, double) key = (style, box);
    final double? hit = _overhangs[key];
    if (hit != null) return hit;
    final double value = _middleOverhang(style, _scaler, _direction, box);
    _overhangs[key] = value;
    return value;
  }

  /// 抓手图标：固定字号、不做无障碍缩放，随颜色缓存。
  TextPainter gripPainter(Color color) {
    final TextPainter? hit = _grips[color];
    if (hit != null) return hit;
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
      // 抓手是界面，不是笔记：缩放时不该跟着变大。
      textScaler: TextScaler.noScaling,
    )..layout();
    return _grips[color] = tp;
  }

  void notePainterBuild() => painterBuilds++;

  void sweep() {
    _cells.removeWhere((_, _CellMemo memo) => memo.usedIn != _generation);
    _painted.removeWhere((_, _PaintedCell cell) {
      if (cell.usedIn == _generation) return false;
      cell.painter.dispose();
      return true;
    });
  }

  void clear() {
    for (final _PaintedCell cell in _painted.values) {
      cell.painter.dispose();
    }
    _painted.clear();
    _cells.clear();
    for (final TextPainter grip in _grips.values) {
      grip.dispose();
    }
    _grips.clear();
    _probes.clear();
    _overhangs.clear();
  }

  static int _widthKey(double width) => (width * 4).round();
}

/// Measures a whole table block.
///
/// Two rules decide the geometry:
///
/// * a table is **as wide as its content** and starts on the text column's left
///   edge, the way Obsidian's does — columns get their widest cell plus padding,
///   and the table stops there. It only shrinks (proportionally, every column at
///   once) when the content is wider than the column itself;
/// * every cell is measured from its **painted** tree, so the columns, the
///   painted glyphs and the invisible skeleton all agree on where each character
///   is.
_Table _measureTable({
  required List<String> lines,
  required List<int> starts,
  required int first,
  required int last,
  required int divider,
  required TextStyle base,
  required _Ctx ctx,
  required int editAt,
  required TextDirection direction,
  required _CellMemoStore memo,
}) {
  final List<_RowData> rows = <_RowData>[];
  final Map<int, int> lineOfRow = <int, int>{};
  for (int i = first; i <= last; i++) {
    if (i == divider) continue;
    final int at = starts[i];
    final List<_ParsedCell> cells = _parseCells(lines[i], at);
    if (cells.isEmpty) continue;
    lineOfRow[i] = rows.length;
    rows.add(
      _RowData(
        line: i,
        start: at,
        end: at + lines[i].length,
        header: divider >= 0 && i == divider - 1,
        cells: cells,
      ),
    );
  }

  final int cols = rows.fold<int>(
    0,
    (int m, _RowData r) => math.max(m, r.cells.length),
  );
  final double rowHeight = _lineHeightOf(base);
  final TextStyle bodyStyle = base.copyWith(fontWeight: FontWeight.w400);
  final TextStyle headStyle = base.copyWith(fontWeight: FontWeight.w700);

  // Pass one: build each cell's tree and measure it. The tree is kept — it is
  // exactly what the row renderer paints and what the skeleton redraws
  // invisibly, so the three of them cannot drift apart.
  //
  // The cell under the caret gets **two** trees: the rendered one decides the
  // column widths (so entering a cell never reflows the table under the
  // pointer), and the source-revealed one is what is painted and laid out
  // underneath it.
  final List<List<List<InlineSpan>>> trees = <List<List<InlineSpan>>>[];
  final List<List<List<_CellCode>>> codes = <List<List<_CellCode>>>[];
  final List<List<_CellMemo?>> memos = <List<_CellMemo?>>[];
  final List<double> natural = List<double>.filled(cols, 0);
  for (final _RowData r in rows) {
    final TextStyle style = r.header ? headStyle : bodyStyle;
    final List<List<InlineSpan>> rowTrees = <List<InlineSpan>>[];
    final List<List<_CellCode>> rowCodes = <List<_CellCode>>[];
    final List<_CellMemo?> rowMemos = <_CellMemo?>[];
    for (int c = 0; c < r.cells.length; c++) {
      final int from = r.cells[c].offset;
      final int to = from + r.cells[c].text.length;
      final bool editing = editAt >= from && editAt <= to;
      // While typing, every cell but one is unchanged: its tree, code runs and
      // natural width come straight out of the memo. The cell being edited is
      // never memoized — its source changes with each keystroke.
      _CellMemo? memoHit = editing
          ? null
          : memo.cell(r.cells[c].text, r.header);
      final List<InlineSpan> rendered;
      final List<_CellCode> codeRuns;
      final double w;
      if (memoHit != null) {
        rendered = memoHit.rendered;
        codeRuns = memoHit.codes;
        w = memoHit.natural;
      } else {
        final List<_CellCode> fresh = <_CellCode>[];
        rendered = _inline(
          r.cells[c].text,
          style,
          from,
          ctx,
          // A revealed cell paints no chip, so it has no chip runs to report.
          codeRuns: editing ? null : fresh,
        );
        w = _measureSpans(rendered, style, ctx.textScaler, direction);
        if (editing) {
          codeRuns = const <_CellCode>[];
        } else {
          codeRuns = fresh;
          memoHit = memo.addCell(
            text: r.cells[c].text,
            header: r.header,
            rendered: rendered,
            codes: codeRuns,
            natural: w,
          );
        }
      }
      final List<InlineSpan> paintSpans = editing
          ? _inline(r.cells[c].text, style, from, _cellEditCtx(ctx, from, to))
          : rendered;
      rowTrees.add(paintSpans);
      rowCodes.add(codeRuns);
      rowMemos.add(memoHit);
      natural[c] = math.max(natural[c], w);
    }
    trees.add(rowTrees);
    codes.add(rowCodes);
    memos.add(rowMemos);
  }

  // Pass two: hand out the columns.
  //
  // The table is **as wide as its content**, the way Obsidian's is: each column
  // gets its widest cell plus the cell padding, and the whole thing stops there
  // instead of stretching to the text column's right edge. A short table that
  // fills six hundred pixels of paper reads as a diagram, not as a table.
  //
  // `_kMinCell` is the floor — it is what keeps `|  |  |` (the empty table
  // `insertTable` writes) a usable grid instead of a 32px speck, and what stops
  // a one-letter column from being a sliver.
  //
  // When the natural widths exceed the column, the table **wraps** instead of
  // squeezing: every column keeps a readable floor, the space above it is
  // shared in proportion to what each column still wants, and a cell that does
  // not fit its column wraps inside it. Negative `letterSpacing` — the old way
  // of forcing the table onto one line — made long cells into unreadable
  // slivers of overlapping glyphs, so it is gone for good.
  //
  // Only when even the floors do not fit (`cols × readable > fit`, a table
  // with more columns than the text column can host) does every column get an
  // equal share; long unbreakable words then break inside the cell.
  //
  // The 1px from `contentWidth` is not cosmetic: a line break fires on a strict
  // `> contentWidth`, so a table landing exactly on the last pixel makes
  // rounding decide whether the row wraps — and a wrapped row is twice as tall
  // as its cells.
  final double available = math.max(60, ctx.contentWidth - 1);
  final List<double> wanted = <double>[
    for (int c = 0; c < cols; c++) math.max(natural[c], _kMinCell),
  ];
  final double fit = math.max(1, available - cols * 2 * _kCellPad);
  final double span = wanted.fold<double>(0, (double a, double w) => a + w);
  final List<double> widths;
  if (span <= fit) {
    widths = wanted;
  } else {
    final double readable = math.max(
      _kMinCell,
      ctx.textScaler.scale(
        _kReadableCol * (base.fontSize ?? _kReadableColAt) / _kReadableColAt,
      ),
    );
    final List<double> floor = <double>[
      for (final double w in wanted) math.min(w, readable),
    ];
    final double floorSum = floor.fold<double>(0, (double a, double b) => a + b);
    if (floorSum > fit) {
      widths = <double>[for (int c = 0; c < cols; c++) fit / cols];
    } else {
      final double extra = span - floorSum;
      final double room = fit - floorSum;
      widths = <double>[
        for (int c = 0; c < cols; c++)
          floor[c] + (extra <= 0 ? 0 : (wanted[c] - floor[c]) * room / extra),
      ];
    }
  }

  // Pass three: record where each box ended up. The tree is painted exactly as
  // measured — a cell that does not fit wraps inside its column, so there is
  // no tracking correction to bake in any more.
  for (int ri = 0; ri < rows.length; ri++) {
    final _RowData r = rows[ri];
    final TextStyle style = r.header ? headStyle : bodyStyle;
    for (int c = 0; c < r.cells.length; c++) {
      r.data.add(
        _CellData(
          cell: r.cells[c],
          style: style,
          spans: trees[ri][c],
          memo: memos[ri][c],
          codeRuns: codes[ri][c],
          width: widths[c],
          align: divider >= 0 ? _alignOf(lines[divider], c) : TextAlign.start,
        ),
      );
    }
  }

  final List<List<TableCellGeometry>> perRow = <List<TableCellGeometry>>[
    for (final _RowData _ in rows) <TableCellGeometry>[],
  ];
  double cx = 0;
  for (int c = 0; c < cols; c++) {
    final double boxWidth = widths[c] + 2 * _kCellPad;
    for (int ri = 0; ri < rows.length; ri++) {
      final _RowData r = rows[ri];
      if (c >= r.cells.length) continue;
      final _CellData d = r.data[c];
      d
        ..x = cx
        ..boxWidth = boxWidth;
      perRow[ri].add(
        TableCellGeometry(
          start: r.cells[c].offset,
          end: r.cells[c].offset + r.cells[c].text.length,
          x: cx,
          width: boxWidth,
        ),
      );
    }
    cx += boxWidth;
  }
  final List<TableRowGeometry> geometryRows = <TableRowGeometry>[
    for (int ri = 0; ri < rows.length; ri++)
      TableRowGeometry(
        line: rows[ri].line,
        start: rows[ri].start,
        header: rows[ri].header,
        cells: perRow[ri],
      ),
  ];

  return _Table(
    rows: rows,
    width: cx,
    rowHeight: rowHeight,
    dyShift: memo.overhang(base, rowHeight),
    lineOfRow: lineOfRow,
    geometry: TableGeometry(
      first: first,
      last: last,
      width: cx,
      rowHeight: rowHeight,
      rows: geometryRows,
    ),
  );
}

