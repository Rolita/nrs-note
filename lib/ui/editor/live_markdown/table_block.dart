part of '../live_markdown.dart';

/// 按行排版下的实时表格。
///
/// 段落排版时表格靠「一个看不见的骨架行 + 一个零宽的 `WidgetSpan`」把格子
/// 的位置喂给 `RenderParagraph`；按行排版没有那层段落，每个源码行自己就是
/// 一条独立的排版单元，所以表格改成引擎级的自绘：[LiveTableBlocks] 按行给出
/// [LineBlockView]，每一行自己画格子、网格、选区洗色和抓手。
///
/// 整张表仍然只测一次（列宽必须一起分配），这份测量结果按源码缓存在这里，
/// 文本/样式/宽度/光标变了才重测。
class LiveTableBlocks {
  LiveTableBlocks({
    required this.base,
    required this.palette,
    required this.text,
    required this.selection,
  });

  /// 正文样式（`editorProseStyle` 的产物）。格子的字号由它派生。
  final TextStyle base;

  /// 当前主题的调色板。
  final AppPalette palette;

  /// 当前源码，调用时才读——实例本身跨帧复用，重建等价的实例会让渲染层
  /// 每一帧都丢掉整篇布局。
  final String Function() text;

  /// 当前的揭示选区，调用时才读。
  final TextSelection? Function() selection;

  String? _measuredText;
  TextStyle? _measuredBase;
  double _measuredWidth = -1;
  TextScaler _measuredScaler = TextScaler.noScaling;
  TextDirection _measuredDirection = TextDirection.ltr;
  int _measuredCaret = -1;

  /// 源码行号 → 这一行的自绘内容。
  final Map<int, _TableLineBlock> _byLine = <int, _TableLineBlock>{};

  /// 每张表最近一次算出的选区色带；`(a, b, bands)`。
  final Map<_Table, (int, int, List<_RowBand?>)> _bandCache =
      <_Table, (int, int, List<_RowBand?>)>{};

  @override
  bool operator ==(Object other) =>
      other is LiveTableBlocks &&
      other.base == base &&
      other.palette == palette;

  @override
  int get hashCode => Object.hash(base, palette);

  /// 丢掉这一份测量（连同每个格子的 `TextPainter`）。宿主换掉实例时调用。
  void dispose() => _disposeBlocks();

  /// 交给 `LineEditableText.lineBlockFor` 的入口。
  LineBlockView? blockFor(SourceLine line, LineBlockContext context) {
    if (line.kind != LineBlockKind.table &&
        line.kind != LineBlockKind.tableHeader) {
      return null;
    }
    final String source = text();
    final TextSelection? sel = selection();
    final int caret = sel != null && sel.isValid && sel.isCollapsed
        ? sel.start
        : -1;
    if (source != _measuredText ||
        base != _measuredBase ||
        context.contentWidth != _measuredWidth ||
        context.textScaler != _measuredScaler ||
        context.textDirection != _measuredDirection ||
        caret != _measuredCaret) {
      _measure(source, context, caret);
    }
    return _byLine[line.index];
  }

  void _disposeBlocks() {
    for (final _TableLineBlock block in _byLine.values) {
      block.dispose();
    }
    _byLine.clear();
    _bandCache.clear();
  }

  void _measure(String source, LineBlockContext context, int caret) {
    _disposeBlocks();
    _measuredText = source;
    _measuredBase = base;
    _measuredWidth = context.contentWidth;
    _measuredScaler = context.textScaler;
    _measuredDirection = context.textDirection;
    _measuredCaret = caret;

    final List<SourceLine> sources = scanSourceLines(source);
    bool any = false;
    for (final SourceLine line in sources) {
      if (_isTableSource(line.kind)) {
        any = true;
        break;
      }
    }
    if (!any) return;

    final List<String> lines = source.split('\n');
    final List<int> starts = <int>[for (final SourceLine s in sources) s.start];
    final TextSelection? sel = selection();
    final bool selValid = sel != null && sel.isValid;
    // 格子的 span 树由渲染对象重画，芯片（标签、链接）拿不到 BuildContext，
    // 所以整棵树走 `plain` 上下文：格子里的行内代码不画胶囊，改由自绘层画。
    final _Ctx ctx = _Ctx(
      p: palette,
      caretA: -1,
      caretB: -1,
      selA: selValid ? sel.start : -1,
      selB: selValid ? sel.end : -1,
      contentWidth: context.contentWidth,
      direction: context.textDirection,
      textScaler: context.textScaler,
      plain: true,
    );

    int i = 0;
    while (i < sources.length) {
      if (!_isTableSource(sources[i].kind)) {
        i++;
        continue;
      }
      int last = i;
      while (last + 1 < sources.length &&
          _isTableRun(sources[last + 1].kind)) {
        last++;
      }
      int divider = -1;
      for (int k = i; k <= last; k++) {
        if (sources[k].kind == LineBlockKind.tableDivider) {
          divider = k;
          break;
        }
      }
      final _Table table = _measureTable(
        lines: lines,
        starts: starts,
        first: i,
        last: last,
        divider: divider,
        base: base,
        ctx: ctx,
        editAt: caret,
        direction: context.textDirection,
      );
      for (int ri = 0; ri < table.rows.length; ri++) {
        final _RowData row = table.rows[ri];
        _byLine[row.line] = _TableLineBlock(
          table: table,
          row: row,
          rowIndex: ri,
          rowCount: table.rows.length,
          tableId: table.rows.first.start,
          header: row.header,
          last: ri == table.rows.length - 1,
          palette: palette,
          textScaler: context.textScaler,
          direction: context.textDirection,
          bandOf: (int index) => _bandOf(table, index),
        );
      }
      i = last + 1;
    }
  }

  /// 这一行就是表格块里的一行（分隔行不算，它不占像素）。
  static bool _isTableSource(LineBlockKind kind) =>
      kind == LineBlockKind.table || kind == LineBlockKind.tableHeader;

  /// 同一张表里紧随其后的行：正文行、表头行，**以及分隔行**。
  ///
  /// 分隔行不占像素、也不自绘，但它属于这张表：把它当成块的边界会让表头与
  /// 正文被切成两张独立的表（列宽各自分配，行号也从 0 重新数）。
  static bool _isTableRun(LineBlockKind kind) =>
      _isTableSource(kind) || kind == LineBlockKind.tableDivider;

  /// 在整张表的选区色带里取第 [index] 行那一份。
  _RowBand? _bandOf(_Table table, int index) {
    final TextSelection? sel = selection();
    if (sel == null || !sel.isValid || sel.isCollapsed) return null;
    final int a = sel.start;
    final int b = sel.end;
    final (int, int, List<_RowBand?>)? cached = _bandCache[table];
    final List<_RowBand?> bands;
    if (cached != null && cached.$1 == a && cached.$2 == b) {
      bands = cached.$3;
    } else {
      bands = _bandsOfTable(table, a, b);
      _bandCache[table] = (a, b, bands);
    }
    return index >= 0 && index < bands.length ? bands[index] : null;
  }
}

/// A rounded fill behind one inline code run, in the cell painter's coordinates.
class _PaintedChip {
  const _PaintedChip(this.rect, this.fill);

  final Rect rect;
  final Color fill;
}

/// 一行实时表格：既是行引擎的自绘内容，也是指针层的 chrome 提供者。
class _TableLineBlock implements LineBlockView, TableRowChrome {
  _TableLineBlock({
    required this.table,
    required this.row,
    required this.rowIndex,
    required this.rowCount,
    required this.tableId,
    required this.header,
    required this.last,
    required this.palette,
    required this.textScaler,
    required this.direction,
    required this.bandOf,
  }) {
    _measureCells();
  }

  final _Table table;
  final _RowData row;
  final int rowIndex;
  final int rowCount;
  final int tableId;
  final bool header;

  /// 块的最后一行：它负责闭合表格的底边。
  final bool last;

  final AppPalette palette;
  final TextScaler textScaler;
  final TextDirection direction;

  /// 按行号取整张表的选区色带（`null` 表示这一行没被选中）。
  final _RowBand? Function(int index) bandOf;

  final List<TextPainter> _painters = <TextPainter>[];
  final List<List<_PaintedChip>> _chips = <List<_PaintedChip>>[];

  double _contentHeight = 0;
  Offset _globalOrigin = Offset.zero;
  bool _disposed = false;

  void _measureCells() {
    _contentHeight = table.rowHeight;
    for (final _CellData cell in row.data) {
      final TextPainter tp = TextPainter(
        text: TextSpan(style: cell.style, children: cell.spans),
        textDirection: direction,
        textScaler: textScaler,
        // 永远一行：换行的格子会画到自己的行框外面，直接切到下一行。
        maxLines: 1,
        ellipsis: '…',
      );
      tp.layout(maxWidth: math.max(1, cell.boxWidth - 2 * _kCellPad));
      _painters.add(tp);
      _chips.add(_chipsFor(tp, cell));
      _contentHeight = math.max(_contentHeight, tp.height);
    }
  }

  /// 量出一个格子里每段行内代码的圆角底片（格子坐标）。
  List<_PaintedChip> _chipsFor(TextPainter tp, _CellData cell) {
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
        textDirection: direction,
        textScaler: textScaler,
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
  double get height => _contentHeight;

  @override
  double get width => table.width;

  /// 文字在行框里垂直居中的偏移。
  double _textTop(TextPainter tp) => (_contentHeight - tp.height) / 2;

  // ------------------------------------------------------------ 行内几何

  /// 第 [column] 列的格子在本行里的矩形。
  Rect _cellRect(int column) {
    if (column < 0 || column >= row.data.length) {
      return Rect.fromLTWH(table.width, 0, 0, _contentHeight);
    }
    final _CellData cell = row.data[column];
    return Rect.fromLTWH(cell.x, 0, cell.boxWidth, _contentHeight);
  }

  List<Rect> cells() => <Rect>[
    for (int i = 0; i < row.data.length; i++) _cellRect(i),
  ];

  int? _cellAtLocal(Offset local) {
    for (int i = 0; i < row.data.length; i++) {
      final _CellData cell = row.data[i];
      if (local.dx >= cell.x && local.dx < cell.x + cell.boxWidth) return i;
    }
    return null;
  }

  @override
  int offsetAt(Offset local) {
    if (row.data.isEmpty) return row.start;
    final int? index = _cellAtLocal(local);
    if (index == null) {
      // 表格左/右的空白：贴到最近的一端，与段落里点空白的行为一致。
      return local.dx < 0 ? row.data.first.cell.offset : row.end;
    }
    final _CellData cell = row.data[index];
    final TextPainter tp = _painters[index];
    final int at = tp
        .getPositionForOffset(
          Offset(local.dx - cell.textX, local.dy - _textTop(tp)),
        )
        .offset;
    return (cell.cell.offset + at).clamp(
      cell.cell.offset,
      cell.cell.offset + cell.cell.text.length,
    );
  }

  @override
  Rect caretRectAt(int offset) {
    if (row.data.isEmpty) {
      return Rect.fromLTWH(0, 0, 0, _contentHeight);
    }
    int index = row.data.length - 1;
    for (int i = 0; i < row.data.length; i++) {
      final _CellData cell = row.data[i];
      if (offset <= cell.cell.offset + cell.cell.text.length) {
        index = i;
        break;
      }
    }
    final _CellData cell = row.data[index];
    final TextPainter tp = _painters[index];
    final int local = (offset - cell.cell.offset).clamp(
      0,
      cell.cell.text.length,
    );
    final TextPosition position = TextPosition(offset: local);
    final Offset caret = tp.getOffsetForCaret(position, Rect.zero);
    final double caretHeight = tp.getFullHeightForCaret(position, Rect.zero);
    return Rect.fromLTWH(
      cell.textX + caret.dx,
      _textTop(tp) + caret.dy,
      0,
      caretHeight > 0 ? caretHeight : tp.height,
    );
  }

  @override
  List<Rect> highlightRects(int from, int to) {
    if (to <= from || row.data.isEmpty) return const <Rect>[];
    final List<Rect> out = <Rect>[];
    for (int i = 0; i < row.data.length && i < _painters.length; i++) {
      final _CellData cell = row.data[i];
      final int start = cell.cell.offset;
      final int end = start + cell.cell.text.length;
      final int a = math.max(from, start);
      final int b = math.min(to, end);
      if (b <= a) continue;
      final TextPainter tp = _painters[i];
      final List<TextBox> boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: a - start, extentOffset: b - start),
      );
      for (final TextBox box in boxes) {
        out.add(
          Rect.fromLTRB(
            cell.textX + box.left,
            0,
            cell.textX + box.right,
            _contentHeight,
          ),
        );
      }
    }
    return out;
  }

  // -------------------------------------------------------------- 绘制

  @override
  void paint(Canvas canvas, Offset origin, Offset globalOrigin) {
    _globalOrigin = globalOrigin;
    if (row.data.isEmpty) return;

    final double cellHeight = _contentHeight;
    // 1px 的网格线必须落在设备像素上：整体坐标里的那点小数偏差在这里抹掉。
    final double left =
        origin.dx + (globalOrigin.dx.roundToDouble() - globalOrigin.dx);
    final double top =
        origin.dy + (globalOrigin.dy.roundToDouble() - globalOrigin.dy);
    final double right = left + table.width;
    final double bottom = top + cellHeight;

    /// 表格坐标里的一条列边界，吸附到像素栅格上。每条单独取整，误差不会
    /// 沿表格累积，每根线都恰好一像素。
    double edgeAt(double tableX) => (left + tableX).roundToDouble();

    final _RowBand? band = bandOf(rowIndex);
    final _RowBand? above = rowIndex > 0 ? bandOf(rowIndex - 1) : null;
    final _RowBand? below = rowIndex + 1 < rowCount
        ? bandOf(rowIndex + 1)
        : null;

    final double bl = band == null ? left : edgeAt(math.max(0, band.left));
    final double br = band == null
        ? right
        : edgeAt(math.min(table.width, band.right));
    final double radius = math.min(_kSelectRadius, math.max(0, (br - bl) / 2));
    final bool roundTL =
        band != null && (above == null || above.left > band.left + 0.5);
    final bool roundTR =
        band != null && (above == null || above.right < band.right - 0.5);
    final bool roundBL =
        band != null && (below == null || below.left > band.left + 0.5);
    final bool roundBR =
        band != null && (below == null || below.right < band.right - 0.5);

    // 选区洗色：**一整块不透明的、按格子吸附的**色带，只在形状真正拐弯的
    // 角上圆角。上下两行叠起来就是一条连续的带子。
    final Color wash = Color.alphaBlend(
      palette.selectionEdge.withValues(alpha: header ? 0.18 : 0.11),
      palette.surface,
    );
    if (band != null) {
      // 未选中的那一段先用纸色盖一遍：字段自己那层整行高亮还在下面，
      // 只盖中间一段会让整行看起来都被选中了。
      final Paint paper = Paint()..color = palette.surface;
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

    // 拖拽预览：抓手正在提议的落点，画成一层浅强调色。
    final TableDragPreview? preview = tableDragPreview.value;
    if (preview != null && preview.tableId == tableId) {
      final Paint hot = Paint()
        ..color = Color.alphaBlend(
          palette.accent.withValues(alpha: 0.18),
          palette.surface,
        );
      if (preview.column) {
        final int stop = math.min(
          row.data.length - 1,
          preview.index + preview.count - 1,
        );
        for (int c = preview.index; c <= stop; c++) {
          final Rect cell = _cellRect(c);
          if (cell.width <= 0) continue;
          canvas.drawRect(
            Rect.fromLTWH(left + cell.left, top, cell.width, cellHeight),
            hot,
          );
          if (c == preview.index) {
            canvas.drawRect(
              Rect.fromLTWH(left + cell.left, top, 2, cellHeight),
              Paint()..color = palette.accent,
            );
          }
        }
      } else if (rowIndex >= preview.index &&
          rowIndex < preview.index + preview.count) {
        canvas.drawRect(
          Rect.fromLTWH(left, top, table.width, cellHeight),
          hot,
        );
        if (rowIndex == preview.index) {
          canvas.drawRect(
            Rect.fromLTWH(left, top, table.width, 2),
            Paint()..color = palette.accent,
          );
        }
      }
    }

    // 行内代码的圆角底片，画在网格**之前**：26px 的底片压在 28px 的行上
    // 会啃掉表头的下边框。
    final double chipRadius = textScaler.scale(_kInlineCodeRadius);
    final Paint chipPaint = Paint();
    for (int i = 0; i < row.data.length && i < _chips.length; i++) {
      if (_chips[i].isEmpty) continue;
      final TextPainter tp = _painters[i];
      final Offset cellOrigin = Offset(
        left + row.data[i].textX,
        top + _textTop(tp),
      );
      for (final _PaintedChip chip in _chips[i]) {
        chipPaint.color = chip.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            chip.rect.shift(cellOrigin),
            Radius.circular(chipRadius),
          ),
          chipPaint,
        );
      }
    }

    // 网格：每一行都有一条顶线（表头和末行再加一条底线），每条列边界一根。
    final Paint line = Paint()..color = palette.rule;
    final Paint strong = Paint()
      ..color = band == null ? _strongRule(palette) : palette.rule;
    final Set<double> edges = <double>{0, table.width};
    for (final _CellData cell in row.data) {
      edges
        ..add(cell.x)
        ..add(cell.x + cell.boxWidth);
    }
    void grid(Paint paint) {
      canvas.drawRect(Rect.fromLTWH(left, top, table.width, 1), paint);
      for (final double x in edges) {
        canvas.drawRect(Rect.fromLTWH(edgeAt(x), top, 1, cellHeight), paint);
      }
    }

    grid(line);
    if (header || last) {
      canvas.drawRect(
        Rect.fromLTWH(left, bottom - 1, table.width, 1),
        strong,
      );
    }
    if (band != null) {
      final RRect shape = RRect.fromRectAndCorners(
        Rect.fromLTRB(bl, top, br, bottom),
        topLeft: roundTL ? Radius.circular(radius) : Radius.zero,
        topRight: roundTR ? Radius.circular(radius) : Radius.zero,
        bottomLeft: roundBL ? Radius.circular(radius) : Radius.zero,
        bottomRight: roundBR ? Radius.circular(radius) : Radius.zero,
      );
      // 提亮是从**网格色**上提的，不是从洗色上提：块里的线仍然读作线，
      // 而不是把整块切开的强调色亮条。
      final Paint lifted = Paint()
        ..color = Color.alphaBlend(
          palette.selectionEdge.withValues(alpha: 0.2),
          palette.rule,
        );
      canvas.save();
      canvas.clipRRect(shape);
      grid(lifted);
      if (header || last) {
        canvas.drawRect(
          Rect.fromLTWH(left, bottom - 1, table.width, 1),
          lifted,
        );
      }
      canvas.restore();
      _paintBandOutline(canvas, left, band, above, below, bl, br, top, bottom);
    }

    // 文字最后画，压在底色和网格上。
    for (int i = 0; i < row.data.length && i < _painters.length; i++) {
      _painters[i].paint(
        canvas,
        Offset(left + row.data[i].textX, top + _textTop(_painters[i])),
      );
    }

    // chrome 再压在一切之上，免得被自己画出来的洗色盖住。
    _paintChrome(canvas, left, top);
  }

  /// 抓手和两个 `+` 按钮：**只有悬停时才画**，而且就是图标本身。
  void _paintChrome(Canvas canvas, double left, double top) {
    final Offset painted = Offset(left, top);
    for (final TableChromeTarget target in _controls()) {
      final bool grabbed = _dragging(target.kind, target.index);
      final Rect local = target.rect.shift(-_globalOrigin);
      if (!grabbed && !_hovering(local)) continue;
      final bool on = grabbed || _pointing(local);
      final Color color = on ? palette.accent : palette.textTertiary;
      final double weight = on ? 1.6 : 1.2;
      final Rect r = local.shift(painted);
      switch (target.kind) {
        case TableChromeKind.rowHandle:
        case TableChromeKind.columnHandle:
          _paintGrip(canvas, r, color: color);
        case TableChromeKind.addRow:
        case TableChromeKind.addColumn:
          _paintPlus(canvas, r, color: color, weight: weight);
      }
    }
  }

  /// 六个点：两列三行，重排列表里人人都认得的那只手。
  ///
  /// 从图标字体里重绘，而不是手描六个圆：绘制发生在自绘层里，`Icon` 需要
  /// 一个 widget，而那个 widget 会把光标需要的点击吞掉。
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
      // 抓手是界面，不是笔记：缩放时不该跟着变大。
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

  /// 一行一行地描出选区块的轮廓，描边中心落在半像素上。
  void _paintBandOutline(
    Canvas canvas,
    double left,
    _RowBand band,
    _RowBand? above,
    _RowBand? below,
    double bl,
    double br,
    double top,
    double bottom,
  ) {
    final double l = bl + 0.5;
    final double r = br - 0.5;
    final double t = top + 0.5;
    final double b = bottom - 0.5;
    if (r - l <= 0 || b - t <= 0) return;

    final bool roundTL = above == null || above.left > band.left + 0.5;
    final bool roundTR = above == null || above.right < band.right - 0.5;
    final bool roundBL = below == null || below.left > band.left + 0.5;
    final bool roundBR = below == null || below.right < band.right - 0.5;

    final double rr = math.max(
      0,
      math.min(_kSelectRadius, math.min((r - l) / 2, (b - t) / 2)),
    );
    final double tl = roundTL ? rr : 0;
    final double tr = roundTR ? rr : 0;
    final double blr = roundBL ? rr : 0;
    final double brr = roundBR ? rr : 0;

    double xAt(double tableX) => (left + tableX).roundToDouble() + 0.5;

    final Path path = Path()
      ..moveTo(l, t + tl)
      ..lineTo(l, b - blr)
      ..moveTo(r, t + tr)
      ..lineTo(r, b - brr);
    for (final (double a, double c) in _exposed(band, above)) {
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
    for (final (double a, double c) in _exposed(band, below)) {
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
        ..color = palette.selectionEdge,
    );
  }

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

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final TextPainter tp in _painters) {
      tp.dispose();
    }
    _painters.clear();
    _chips.clear();
  }

  // ------------------------------------------------------------ chrome 契约

  @override
  int get chromeTableId => tableId;

  @override
  int get chromeSourceStart => row.start;

  @override
  int get chromeRowIndex => rowIndex;

  @override
  int get chromeRowCount => rowCount;

  @override
  set chromeOrigin(Offset value) => _globalOrigin = value;

  @override
  Rect chromeBounds() =>
      _globalOrigin & Size(table.width, _contentHeight);

  @override
  List<Rect> chromeCells() => <Rect>[
    for (final Rect cell in cells())
      _globalOrigin + cell.topLeft & cell.size,
  ];

  @override
  List<InlineSpan> chromeCellSpans() => <InlineSpan>[
    for (final _CellData cell in row.data)
      TextSpan(style: cell.style, children: cell.spans),
  ];

  bool get _paintsColumnGrip => rowIndex == 0;
  bool get _paintsAddRow => rowIndex == rowCount - 1;
  bool get _paintsAddColumn => rowIndex == 0;

  Rect _rowGripRect() => Rect.fromLTWH(
    -_kChromeGap - _kGrip,
    (_contentHeight - _kGrip) / 2,
    _kGrip,
    _kGrip,
  );

  Rect _columnGripRect(int column) {
    final Rect cell = _cellRect(column);
    return Rect.fromLTWH(
      cell.center.dx - _kGrip / 2,
      -_kChromeGap - _kGrip,
      _kGrip,
      _kGrip,
    );
  }

  Rect _addRowRect() => Rect.fromLTWH(
    table.width / 2 - _kAdd / 2,
    _contentHeight + _kChromeGap,
    _kAdd,
    _kAdd,
  );

  Rect _addColumnRect() => Rect.fromLTWH(
    table.width + _kChromeGap,
    (_contentHeight - _kAdd) / 2,
    _kAdd,
    _kAdd,
  );

  /// 这一行可能画出的所有控件（行内坐标）。
  List<TableChromeTarget> _controls() => <TableChromeTarget>[
    TableChromeTarget(TableChromeKind.rowHandle, _rowGripRect(), rowIndex),
    if (_paintsColumnGrip)
      for (int c = 0; c < row.data.length; c++)
        TableChromeTarget(
          TableChromeKind.columnHandle,
          _columnGripRect(c),
          c,
        ),
    if (_paintsAddColumn)
      TableChromeTarget(TableChromeKind.addColumn, _addColumnRect(), -1),
    if (_paintsAddRow)
      TableChromeTarget(TableChromeKind.addRow, _addRowRect(), -1),
  ];

  bool _hovering(Rect local) {
    final Offset? p = tablePointerPosition.value;
    if (p == null) return false;
    return local.shift(_globalOrigin).inflate(kTableChromeSlop).contains(p);
  }

  bool _pointing(Rect local) {
    final Offset? p = tablePointerPosition.value;
    if (p == null || !_hovering(local)) return false;
    return local.shift(_globalOrigin).inflate(2).contains(p);
  }

  bool _dragging(TableChromeKind kind, int index) {
    final TableDragPreview? preview = tableDragPreview.value;
    if (preview == null || preview.tableId != tableId) return false;
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

  @override
  List<TableChromeTarget> chromeTargets() => <TableChromeTarget>[
    for (final TableChromeTarget target in _controls())
      TableChromeTarget(
        target.kind,
        target.rect.shift(_globalOrigin),
        target.index,
      ),
  ];

  @override
  List<TableChromeTarget> chromeVisible() => <TableChromeTarget>[
    for (final TableChromeTarget target in _controls())
      if (_visible(target.kind, target.rect, target.index))
        TableChromeTarget(
          target.kind,
          target.rect.shift(_globalOrigin),
          target.index,
        ),
  ];
}
