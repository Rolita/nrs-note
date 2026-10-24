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
///
/// A merge is one cell to the user, so touching any part of it selects all of
/// it: the rectangle grows over every merge it touches before the bands are
/// built.
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
  final ({int fromRow, int toRow, int fromColumn, int toColumn}) whole =
      expandOverMerges(
        table.merges,
        fromRow: math.min(from.$1, to.$1),
        toRow: math.max(from.$1, to.$1),
        fromColumn: math.min(from.$2, to.$2),
        toColumn: math.max(from.$2, to.$2),
      );
  return <_RowBand?>[
    for (int r = 0; r < rows; r++)
      r < whole.fromRow || r > whole.toRow
          ? null
          : _bandOfRow(table, r, whole.fromColumn, whole.toColumn),
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

/// Columns `[c0, c1]` of [rowIndex], as one span from the first cell's left
/// edge to the last one's right edge. The cells tile the row edge to edge, so
/// this is also where two neighbours merge into one band with no seam at the
/// pipe.
///
/// The edges come from the **columns**, not from the row's cells: a covered
/// cell has zero width, but its column still occupies space inside the merge,
/// and an expanded band may end on it.
_RowBand? _bandOfRow(_Table table, int rowIndex, int c0, int c1) {
  final _RowData row = table.rows[rowIndex];
  if (row.data.isEmpty || table.columns.isEmpty) return null;
  final int last = math.min(row.data.length, table.columns.length) - 1;
  if (last < 0) return null;
  final int a = c0.clamp(0, last);
  final int b = c1.clamp(0, last);
  final double left = table.columns[a].x;
  final double right = table.columns[b].right;
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
/// text, whether the row is a header, and the resolved ink: the table context
/// disables the caret, selection and hover reveals, so no absolute offset leaks
/// into the tree.
class _CellMemo {
  _CellMemo({
    required this.text,
    required this.header,
    required this.ink,
    required this.rendered,
    required this.codes,
    required this.natural,
  });

  final String text;
  final bool header;

  /// The cell's resolved text color — part of the key, because changing a
  /// cell's `fg` has to rebuild its tree.
  final Color? ink;

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

/// A rounded fill behind one inline code run, in the cell painter's coordinates.
class _PaintedChip {
  const _PaintedChip(this.rect, this.fill, {this.tint = false});

  final Rect rect;
  final Color fill;

  /// 底片是否跟着表格选区换色。标签不跟：它在选中格里也保留自己的配色。
  final bool tint;
}

/// Per-cell memoization for one `LiveTableBlocks` instance.
///
/// The palette, base style, scale and direction are fixed for the instance, so
/// a cell's tree only has to be rebuilt when its text or its ink changes.
/// Entries unused by a measure are swept at the end of it, which keeps a long
/// editing session from growing the store without bound.
class _CellMemoStore {
  final Map<(String, bool, Color?), _CellMemo> _cells =
      <(String, bool, Color?), _CellMemo>{};
  final Map<(Object, int, TextAlign), _PaintedCell> _painted =
      <(Object, int, TextAlign), _PaintedCell>{};

  /// 行内代码探针量测结果：`(文字, 样式)` 决定行高与基线距离，与列宽无关。
  final Map<(TextStyle, String), (double, double)> _probes =
      <(TextStyle, String), (double, double)>{};

  /// `_middleOverhang` 的结果：每张表都要问一次，但答案只取决于字体。
  final Map<(TextStyle, double), double> _overhangs =
      <(TextStyle, double), double>{};

  /// 抓手图标 painter。只有强调色与三级文字色、横竖两个方向，按这四组缓存。
  final Map<(Color, bool), TextPainter> _grips = <(Color, bool), TextPainter>{};

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

  _CellMemo? cell(String text, bool header, Color? ink) {
    final _CellMemo? memo = _cells[(text, header, ink)];
    if (memo != null) memo.usedIn = _generation;
    return memo;
  }

  _CellMemo addCell({
    required String text,
    required bool header,
    required Color? ink,
    required List<InlineSpan> rendered,
    required List<_CellCode> codes,
    required double natural,
  }) {
    spanBuilds++;
    return _cells[(text, header, ink)] = _CellMemo(
      text: text,
      header: header,
      ink: ink,
      rendered: rendered,
      codes: codes,
      natural: natural,
    )..usedIn = _generation;
  }

  _PaintedCell? painted(_CellMemo? memo, double width, TextAlign align) {
    if (memo == null) return null;
    final _PaintedCell? cell = _painted[(memo, _widthKey(width), align)];
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

  /// 抓手图标：固定字号、不做无障碍缩放，随颜色与方向缓存。
  ///
  /// 行抓手用两列三行（`gripVertical`），列抓手用三列两行
  /// （`gripHorizontal`）：点阵的朝向就是拖动方向。
  TextPainter gripPainter(Color color, {required bool horizontal}) {
    final (Color, bool) key = (color, horizontal);
    final TextPainter? hit = _grips[key];
    if (hit != null) return hit;
    final IconData icon = horizontal
        ? LucideIcons.gripHorizontal
        : LucideIcons.gripVertical;
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: _kGripDots,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
      // 抓手是界面，不是笔记：缩放时不该跟着变大。
      textScaler: TextScaler.noScaling,
    )..layout();
    return _grips[key] = tp;
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
///
/// A merge is one cell with one box: its anchor's natural width is a demand on
/// the **sum** of the columns it spans, and its painter's height is a demand on
/// the **sum** of its rows. Neither demand is allowed to overflow the text
/// column; when it cannot be met the content wraps inside its block instead.
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
  final double baseRowHeight = _lineHeightOf(base);
  final TextStyle bodyStyle = base.copyWith(fontWeight: FontWeight.w400);
  final TextStyle headStyle = base.copyWith(fontWeight: FontWeight.w700);

  final List<TableMerge> sourceMerges = tableMergesFromStyles(
    rowCount: rows.length,
    columns: cols,
    styleAt: (int row, int column) =>
        row < rows.length && column < rows[row].cells.length
        ? rows[row].cells[column].format
        : const TableCellStyle(),
  );

  // The escape hatch. A merge hides the source of everything it covers, so a
  // caret that lands in a covered cell would be typing into text the renderer
  // refuses to draw. Rendering the table **unmerged** for as long as the caret
  // is in there gives that cell back its own row and column; leaving it
  // restores the merge. It is the one state where the pixels disagree with the
  // directive, and it only lasts while the user is editing against it.
  final List<TableMerge> merges =
      _caretInCoveredCell(rows, sourceMerges, editAt)
      ? const <TableMerge>[]
      : sourceMerges;

  final Map<(int, int), TableMerge> blocks = <(int, int), TableMerge>{};
  for (final TableMerge m in merges) {
    for (int r = m.row; r <= m.lastRow; r++) {
      for (int c = m.column; c <= m.lastColumn; c++) {
        blocks[(r, c)] = m;
      }
    }
  }

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
  final Map<TableMerge, double> spanNatural = <TableMerge, double>{};
  for (int ri = 0; ri < rows.length; ri++) {
    final _RowData r = rows[ri];
    final List<List<InlineSpan>> rowTrees = <List<InlineSpan>>[];
    final List<List<_CellCode>> rowCodes = <List<_CellCode>>[];
    final List<_CellMemo?> rowMemos = <_CellMemo?>[];
    for (int c = 0; c < r.cells.length; c++) {
      final TableMerge? block = blocks[(ri, c)];
      if (block != null && !(block.row == ri && block.column == c)) {
        // Covered: it has neither visible text nor pixels of its own.
        rowTrees.add(const <InlineSpan>[]);
        rowCodes.add(const <_CellCode>[]);
        rowMemos.add(null);
        continue;
      }
      final Color? ink = tableCellInk(ctx.p, r.cells[c].format);
      final TextStyle style = ink == null
          ? (r.header ? headStyle : bodyStyle)
          : (r.header ? headStyle : bodyStyle).copyWith(color: ink);
      final int from = r.cells[c].offset;
      final int to = from + r.cells[c].text.length;
      final bool editing = editAt >= from && editAt <= to;
      // While typing, every cell but one is unchanged: its tree, code runs and
      // natural width come straight out of the memo. The cell being edited is
      // never memoized — its source changes with each keystroke.
      _CellMemo? memoHit = editing
          ? null
          : memo.cell(r.cells[c].text, r.header, ink);
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
            ink: ink,
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
      if (block != null && block.columnSpan > 1) {
        spanNatural[block] = math.max(spanNatural[block] ?? 0, w);
      } else {
        natural[c] = math.max(natural[c], w);
      }
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
  // `kTableMinColumnWidth` is the floor — it is what keeps `|  |  |` (the empty table
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
  final double fit = math.max(1, available - cols * 2 * _kCellPad);

  // A `w=…` in the first cell's directive is a table-level manual width. The
  // values are design pixels at 15.5pt, so they follow the editor's font size
  // and the accessibility scale instead of pinning literal pixels. Manual
  // widths replace the natural ones: content that outgrows its column wraps
  // inside it, and the merge-demand block below deliberately does not widen
  // the columns back.
  final List<int>? designWidths = rows.isEmpty
      ? null
      : tableColumnWidthsOfLine(lines[rows.first.line], cols);
  final double fontSize = base.fontSize ?? _kReadableColAt;
  final List<double>? manualWidths = designWidths == null
      ? null
      : <double>[
          for (final int design in designWidths)
            math.max(
              kTableMinColumnWidth,
              ctx.textScaler.scale(design * fontSize / _kReadableColAt),
            ),
        ];
  final double widthScale = ctx.textScaler.scale(fontSize) / _kReadableColAt;

  final List<double> wanted = <double>[
    for (int c = 0; c < cols; c++)
      manualWidths?[c] ?? math.max(natural[c], kTableMinColumnWidth),
  ];
  final double span = wanted.fold<double>(0, (double a, double w) => a + w);
  final List<double> widths;
  if (span <= fit) {
    widths = wanted;
  } else {
    final double readable = math.max(
      kTableMinColumnWidth,
      ctx.textScaler.scale(
        _kReadableCol * (base.fontSize ?? _kReadableColAt) / _kReadableColAt,
      ),
    );
    final List<double> floor = <double>[
      for (final double w in wanted) math.min(w, readable),
    ];
    final double floorSum = floor.fold<double>(
      0,
      (double a, double b) => a + b,
    );
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

  // A column span asks for one wide text area, and its demand is on the sum of
  // its columns. Give the columns their share only when the whole table still
  // fits; otherwise the merged text wraps, exactly like an ordinary cell that
  // is wider than its column.
  if (merges.isNotEmpty && manualWidths == null) {
    final List<(TableMerge, double)> demands = <(TableMerge, double)>[];
    double extra = 0;
    for (final TableMerge m in merges) {
      if (m.columnSpan < 2) continue;
      final double need = spanNatural[m] ?? 0;
      final double have = _spanTextWidth(widths, m);
      if (need <= have) continue;
      final double add = (need - have) / m.columnSpan;
      demands.add((m, add));
      extra += add * m.columnSpan;
    }
    if (demands.isNotEmpty && extra > 0) {
      final double used = widths.fold<double>(0, (double a, double b) => a + b);
      final double room = math.max(0, fit - used);
      final double scale = extra <= room ? 1 : room / extra;
      for (final (TableMerge m, double add) in demands) {
        for (int c = m.column; c <= m.lastColumn; c++) {
          widths[c] += add * scale;
        }
      }
    }
  }

  // Every source column keeps a box, covered or not: the grips, the drag
  // preview and the selection band all address source columns.
  final List<_ColumnBox> columns = <_ColumnBox>[];
  double cx = 0;
  for (int c = 0; c < cols; c++) {
    final double box = widths[c] + 2 * _kCellPad;
    columns.add(_ColumnBox(cx, box));
    cx += box;
  }
  final double tableWidth = cx;

  final List<TextAlign> aligns = <TextAlign>[
    for (int c = 0; c < cols; c++)
      divider >= 0 ? _alignOf(lines[divider], c) : TextAlign.start,
  ];

  // Pass three: record where each box ended up.
  for (int ri = 0; ri < rows.length; ri++) {
    final _RowData r = rows[ri];
    for (int c = 0; c < r.cells.length; c++) {
      final TableMerge? block = blocks[(ri, c)];
      final bool covered =
          block != null && !(block.row == ri && block.column == c);
      final bool anchor = block != null && block.row == ri && block.column == c;
      final Color? ink = tableCellInk(ctx.p, r.cells[c].format);
      final TextStyle plain = r.header ? headStyle : bodyStyle;
      final TextStyle style = ink == null ? plain : plain.copyWith(color: ink);
      final double textWidth = covered
          ? 0
          : anchor
          ? _spanTextWidth(widths, block)
          : widths[c];
      final double x = block == null ? columns[c].x : columns[block.column].x;
      final double boxWidth = covered
          ? 0
          : anchor
          ? columns[block.lastColumn].right - columns[block.column].x
          : columns[c].width;
      final _CellData data =
          _CellData(
              cell: r.cells[c],
              style: style,
              spans: trees[ri][c],
              codeRuns: codes[ri][c],
              width: textWidth,
              align: anchor ? TextAlign.center : aligns[c],
              memo: memos[ri][c],
            )
            ..covered = covered
            ..block = block
            ..x = x
            ..boxWidth = boxWidth
            ..fill = tableCellFill(ctx.p, r.cells[c].format);
      r.data.add(data);
    }
  }

  // Painters. A merged block gets **one** painter, laid out at the width of its
  // whole box; covered cells get none. Row heights are read from these
  // painters, so they have to exist before the rows are handed their slices.
  final List<TextPainter> owned = <TextPainter>[];
  for (final _RowData r in rows) {
    for (final _CellData cell in r.data) {
      if (cell.covered) continue;
      final double maxWidth = math.max(1, cell.width);
      _PaintedCell? painted = memo.painted(cell.memo, cell.width, cell.align);
      if (painted == null) {
        final TextPainter tp = TextPainter(
          text: TextSpan(style: cell.style, children: cell.spans),
          textDirection: direction,
          textScaler: ctx.textScaler,
          textAlign: cell.align,
        )..layout(minWidth: maxWidth, maxWidth: maxWidth);
        memo.notePainterBuild();
        final List<_PaintedChip> chips = _chipsFor(tp, cell, memo);
        if (cell.memo == null) {
          // 编辑中的格每击键都变，不写共享缓存，由这张表持有。
          owned.add(tp);
        } else {
          painted = memo.addPainted(
            memo: cell.memo!,
            width: cell.width,
            align: cell.align,
            painter: tp,
            chips: chips,
          );
        }
        cell
          ..painter = tp
          ..chips = chips;
      } else {
        cell
          ..painter = painted.painter
          ..chips = painted.chips;
      }
      cell.painted = painted;
    }
  }

  // Row heights: the base line, grown by the tallest cell that lives in one
  // row, then shared out over the rows of every rowspan.
  final List<double> rowHeights = List<double>.filled(
    rows.length,
    baseRowHeight,
  );
  for (int ri = 0; ri < rows.length; ri++) {
    for (final _CellData cell in rows[ri].data) {
      if (cell.covered) continue;
      final TableMerge? block = cell.block;
      if (block != null && block.rowSpan > 1) continue;
      rowHeights[ri] = math.max(rowHeights[ri], cell.painter?.height ?? 0);
    }
  }
  for (final TableMerge m in merges) {
    if (m.rowSpan < 2) continue;
    final _CellData anchor = rows[m.row].data[m.column];
    final double need = anchor.painter?.height ?? 0;
    double have = 0;
    for (int r = m.row; r <= m.lastRow; r++) {
      have += rowHeights[r];
    }
    if (need <= have) continue;
    final double add = (need - have) / m.rowSpan;
    for (int r = m.row; r <= m.lastRow; r++) {
      rowHeights[r] += add;
    }
  }
  final List<double> rowTops = <double>[];
  double ty = 0;
  for (final double h in rowHeights) {
    rowTops.add(ty);
    ty += h;
  }

  for (int ri = 0; ri < rows.length; ri++) {
    for (final _CellData cell in rows[ri].data) {
      final TableMerge? block = cell.block;
      cell.mergeTop = block == null ? rowTops[ri] : rowTops[block.row];
      cell.mergeHeight = block == null
          ? rowHeights[ri]
          : rowTops[block.lastRow] +
                rowHeights[block.lastRow] -
                rowTops[block.row];
      final TextPainter? painter = cell.painter;
      if (painter != null) {
        cell.textTop = cell.mergeTop + (cell.mergeHeight - painter.height) / 2;
      }
    }
  }

  final List<List<TableCellGeometry>> perRow = <List<TableCellGeometry>>[
    for (final _RowData _ in rows) <TableCellGeometry>[],
  ];
  for (int ri = 0; ri < rows.length; ri++) {
    final _RowData r = rows[ri];
    for (final _CellData cell in r.data) {
      perRow[ri].add(
        TableCellGeometry(
          start: cell.cell.offset,
          end: cell.cell.offset + cell.cell.text.length,
          x: cell.x,
          width: cell.boxWidth,
        ),
      );
    }
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

  final _Table table = _Table(
    rows: rows,
    width: tableWidth,
    rowHeight: baseRowHeight,
    dyShift: memo.overhang(base, baseRowHeight),
    lineOfRow: lineOfRow,
    columns: columns,
    columnRoom: fit,
    widthScale: widthScale,
    rowHeights: rowHeights,
    rowTops: rowTops,
    merges: merges,
    ownedPainters: owned,
    geometry: TableGeometry(
      first: first,
      last: last,
      width: tableWidth,
      rowHeight: baseRowHeight,
      rows: geometryRows,
    ),
  );
  return table;
}

/// The text width a merge's anchor gets: its columns' text widths plus the
/// padding that moved to the inside of the span.
double _spanTextWidth(List<double> widths, TableMerge m) {
  double sum = 0;
  for (int c = m.column; c <= m.lastColumn; c++) {
    sum += widths[c];
  }
  return sum + 2 * _kCellPad * (m.columnSpan - 1);
}

/// Whether [caret] is inside a cell some **other** cell's merge covers.
bool _caretInCoveredCell(
  List<_RowData> rows,
  List<TableMerge> merges,
  int caret,
) {
  if (caret < 0 || merges.isEmpty) return false;
  for (int r = 0; r < rows.length; r++) {
    final _RowData row = rows[r];
    for (int c = 0; c < row.cells.length; c++) {
      final _ParsedCell cell = row.cells[c];
      if (caret < cell.offset || caret > cell.offset + cell.text.length) {
        continue;
      }
      for (final TableMerge m in merges) {
        if (!m.covers(r, c)) continue;
        return !(m.row == r && m.column == c);
      }
      return false;
    }
  }
  return false;
}

/// Measures the rounded bands behind every inline code run of one cell.
///
/// 换行的格子会把一段代码折到两条视觉行上：底片按视觉行分别铺，否则会
/// 拉成一条横跨两行文字的长条。
List<_PaintedChip> _chipsFor(
  TextPainter tp,
  _CellData cell,
  _CellMemoStore memoStore,
) {
  if (cell.codeRuns.isEmpty) return const <_PaintedChip>[];
  final List<LineMetrics> lines = tp.computeLineMetrics();
  final List<_PaintedChip> chips = <_PaintedChip>[];
  for (final _CellCode code in cell.codeRuns) {
    final List<TextBox> boxes = tp.getBoxesForSelection(
      TextSelection(baseOffset: code.start, extentOffset: code.end),
    );
    if (boxes.isEmpty) continue;
    // 探针尺寸只取决于文字与样式，跨表跨测量共用；换行时每条视觉行都要用。
    final (double drop, double probeHeight) = memoStore.probeMetrics(
      code.probe.isEmpty ? ' ' : code.probe,
      code.style,
    );
    if (lines.length <= 1) {
      final double baseline = tp.computeDistanceToActualBaseline(
        TextBaseline.alphabetic,
      );
      double left = boxes.first.left;
      double right = boxes.first.right;
      for (final TextBox box in boxes) {
        left = math.min(left, box.left);
        right = math.max(right, box.right);
      }
      chips.add(
        _PaintedChip(
          Rect.fromLTRB(
            left,
            baseline - drop,
            right,
            baseline - drop + probeHeight,
          ),
          code.fill,
          tint: code.isCode,
        ),
      );
    } else {
      final Map<int, (LineMetrics, double, double)> byLine =
          <int, (LineMetrics, double, double)>{};
      for (final TextBox box in boxes) {
        final LineMetrics line = _lineAt(lines, (box.top + box.bottom) / 2);
        final (LineMetrics, double, double) span =
            byLine[line.lineNumber] ?? (line, box.left, box.right);
        byLine[line.lineNumber] = (
          line,
          math.min(span.$2, box.left),
          math.max(span.$3, box.right),
        );
      }
      for (final (LineMetrics line, double left, double right)
          in byLine.values) {
        chips.add(
          _PaintedChip(
            Rect.fromLTRB(
              left,
              line.baseline - drop,
              right,
              line.baseline - drop + probeHeight,
            ),
            code.fill,
            tint: code.isCode,
          ),
        );
      }
    }
  }
  return chips;
}

/// painter 坐标 [y] 落在哪条视觉行上。
LineMetrics _lineAt(List<LineMetrics> lines, double y) {
  for (final LineMetrics line in lines) {
    if (y < line.baseline - line.ascent + line.height) return line;
  }
  return lines.last;
}
