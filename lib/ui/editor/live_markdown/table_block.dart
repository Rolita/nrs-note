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
    this.paper,
  });

  /// 正文样式（`editorProseStyle` 的产物）。格子的字号由它派生。
  final TextStyle base;

  /// 当前主题的调色板。
  final AppPalette palette;

  /// 表格下面那层「纸」；`null` 用 [AppPalette.surface]。
  ///
  /// 编辑器里纸面就是编辑区本身，所以默认值够用；白板的卡片底色是另一种
  /// 半透明面，同一张表画在卡片里要铺卡片自己的底色，否则会浮出一块比
  /// 卡片更暗的矩形。
  final Color? paper;

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

  /// 每张表一份记录：源码块不变、光标也不在同一格时直接复用。
  final List<_TableRecord> _records = <_TableRecord>[];

  /// 实际跑过几次整表测量。测试用它断言「只有变了的表才重测」。
  @visibleForTesting
  int debugTableMeasures = 0;

  /// 每张表最近一次算出的选区色带；`(a, b, bands)`。
  final Map<_Table, (int, int, List<_RowBand?>)> _bandCache =
      <_Table, (int, int, List<_RowBand?>)>{};

  /// 格的 span 树、自然宽、painter 跨测量复用：一次按键只新建真正变了的格。
  final _CellMemoStore _cellMemo = _CellMemoStore();

  /// 实际建过多少棵非编辑格的树；同格连续输入时应保持不变。
  @visibleForTesting
  int get debugCellSpanBuilds => _cellMemo.spanBuilds;

  /// 实际排版过多少次格 painter，包含正在编辑的那一格。
  @visibleForTesting
  int get debugCellPainterBuilds => _cellMemo.painterBuilds;

  /// 第 [index] 张表每一行的选区横带（表坐标），`null` 表示该行没被选中。
  ///
  /// 绘制的色带没有 widget 可查，测试只能从这里读：选中合并块的一部分时，
  /// 整块经过的每一行都应该是同一条通栏色带。
  @visibleForTesting
  List<(double, double)?> debugBandsOfTable(int index) {
    if (index < 0 || index >= _records.length) {
      return const <(double, double)?>[];
    }
    final _Table table = _records[index].table;
    final TextSelection? sel = selection();
    if (sel == null || !sel.isValid || sel.isCollapsed) {
      return List<(double, double)?>.filled(table.rows.length, null);
    }
    return <(double, double)?>[
      for (final _RowBand? band in _bandsOfTable(table, sel.start, sel.end))
        band == null ? null : (band.left, band.right),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is LiveTableBlocks &&
      other.base == base &&
      other.palette == palette &&
      other.paper == paper;

  @override
  int get hashCode => Object.hash(base, palette, paper);

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
    for (final _TableRecord record in _records) {
      record.dispose();
    }
    _records.clear();
    _byLine.clear();
    _bandCache.clear();
    _cellMemo.clear();
  }

  void _measure(String source, LineBlockContext context, int caret) {
    final bool environmentChanged =
        context.contentWidth != _measuredWidth ||
        context.textScaler != _measuredScaler ||
        context.textDirection != _measuredDirection;
    _measuredText = source;
    _measuredBase = base;
    _measuredWidth = context.contentWidth;
    _measuredScaler = context.textScaler;
    _measuredDirection = context.textDirection;
    _measuredCaret = caret;

    // 列宽、行高和每个格子的 TextPainter 一起构成一张表的测量，只有环境变了
    // 才会让所有表一起作废；源码或光标的变化按表处理。
    if (environmentChanged) _disposeBlocks();
    _cellMemo.useEnvironment(context.textScaler, context.textDirection);
    _cellMemo.beginMeasure();

    final List<SourceLine> sources = scanSourceLines(source);
    final List<String> lines = source.split('\n');
    final List<int> starts = <int>[for (final SourceLine s in sources) s.start];

    // 旧记录按源码块配对。源码没变的表，测量结果原样可用，只需把行号和
    // 偏移跟着上面的编辑挪一下。
    final Map<String, List<_TableRecord>> pool = <String, List<_TableRecord>>{};
    for (final _TableRecord record in _records) {
      (pool[record.key] ??= <_TableRecord>[]).add(record);
    }

    final List<_TableRecord> next = <_TableRecord>[];
    _byLine.clear();

    // 格子的 span 树由渲染对象重画，芯片（标签、链接）拿不到 BuildContext，
    // 所以整棵树走 `plain` 上下文：格子里的行内代码不画胶囊，改由自绘层画。
    // 胶囊的选中色不在测量时决定：表格的选区是一个**格子矩形**，而线性选区
    // 的区间会扫过两端之间的所有列。选中色留到绘制时按色带（按格子）上。
    final _Ctx ctx = _Ctx(
      p: palette,
      caretA: -1,
      caretB: -1,
      selA: -1,
      selB: -1,
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
      while (last + 1 < sources.length && _isTableRun(sources[last + 1].kind)) {
        last++;
      }
      int divider = -1;
      for (int k = i; k <= last; k++) {
        if (sources[k].kind == LineBlockKind.tableDivider) {
          divider = k;
          break;
        }
      }

      final String key = _sourceKeyOf(lines, i, last);
      final List<_TableRecord>? available = pool[key];
      final _TableRecord? reused = available != null && available.isNotEmpty
          ? available.removeLast()
          : null;
      if (reused != null) {
        _rebind(
          reused,
          firstLine: i,
          lastLine: last,
          dividerLine: divider,
          firstStart: starts[i],
        );
        final (int, int) edit = _editCellOf(reused.table, caret);
        // 光标停在同一个格子里时，揭开的那一格没有变，整张表都不用重测。
        if (edit.$1 == reused.editRow && edit.$2 == reused.editColumn) {
          next.add(reused);
          for (final _TableLineBlock block in reused.blocks) {
            _byLine[block.row.line] = block;
          }
          i = last + 1;
          continue;
        }
        reused.dispose();
        _bandCache.remove(reused.table);
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
        memo: _cellMemo,
      );
      debugTableMeasures++;
      final (int, int) edit = _editCellOf(table, caret);
      final List<_TableLineBlock> blocks = <_TableLineBlock>[];
      for (int ri = 0; ri < table.rows.length; ri++) {
        final _RowData row = table.rows[ri];
        final _TableLineBlock block = _TableLineBlock(
          table: table,
          row: row,
          rowIndex: ri,
          rowCount: table.rows.length,
          tableId: table.rows.first.start,
          header: row.header,
          last: ri == table.rows.length - 1,
          palette: palette,
          paper: paper ?? palette.surface,
          textScaler: context.textScaler,
          memoStore: _cellMemo,
          bandOf: (int index) => _bandOf(table, index),
        );
        blocks.add(block);
        _byLine[row.line] = block;
      }
      next.add(
        _TableRecord(
          key: key,
          firstLine: i,
          lastLine: last,
          dividerLine: divider,
          firstStart: starts[i],
          table: table,
          blocks: blocks,
          editRow: edit.$1,
          editColumn: edit.$2,
        ),
      );
      i = last + 1;
    }

    // 没配上源码块的旧表已经从文档里消失（或换了内容），连同格子的
    // TextPainter 一起释放。
    for (final List<_TableRecord> leftovers in pool.values) {
      for (final _TableRecord record in leftovers) {
        record.dispose();
        _bandCache.remove(record.table);
      }
    }
    // 复用的表没有重新测量，但它们的格仍属于这一代：sweep 之前先打标记。
    for (final _TableRecord record in next) {
      record.table.touch(_cellMemo.generation);
    }
    _cellMemo.sweep();
    _records
      ..clear()
      ..addAll(next);
  }

  /// 一张表的源码块（含分隔行）拼成匹配键。相同源码的表测量结果完全等价，
  /// 所以重复的表互换记录也不影响显示。
  static String _sourceKeyOf(List<String> lines, int first, int last) =>
      lines.sublist(first, last + 1).join('\n');

  /// 把复用的表挪到新的行号和源码偏移上。格子的文字与几何不动，只改绝对
  /// 偏移，光标命中、选区和 chrome 才能继续落在正确的字符上。
  void _rebind(
    _TableRecord record, {
    required int firstLine,
    required int lastLine,
    required int dividerLine,
    required int firstStart,
  }) {
    final int lineShift = firstLine - record.firstLine;
    final int offsetShift = firstStart - record.firstStart;
    record
      ..firstLine = firstLine
      ..lastLine = lastLine
      ..dividerLine = dividerLine
      ..firstStart = firstStart;
    if (lineShift == 0 && offsetShift == 0) return;
    for (final _RowData row in record.table.rows) {
      row.rebind(
        line: row.line + lineShift,
        start: row.start + offsetShift,
        end: row.end + offsetShift,
      );
    }
    final int tableId = record.table.rows.isEmpty
        ? firstStart
        : record.table.rows.first.start;
    for (final _TableLineBlock block in record.blocks) {
      block.tableId = tableId;
    }
  }

  /// [caret] 落在哪个格子里。与 [_measureTable] 的 `editAt` 判定同一口径
  /// （两端都算），复用时拿它和上次的格子比较。
  static (int, int) _editCellOf(_Table table, int caret) {
    if (caret < 0) return (-1, -1);
    for (int r = 0; r < table.rows.length; r++) {
      final _RowData row = table.rows[r];
      for (int c = 0; c < row.cells.length; c++) {
        final _ParsedCell cell = row.cells[c];
        if (caret >= cell.offset && caret <= cell.offset + cell.text.length) {
          return (r, c);
        }
      }
    }
    return (-1, -1);
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

/// 一张表的测量记录：源码块、它的行号、以及上一次光标落在哪一格。
///
/// 记录拥有整张表的 painter；复用时只改绝对偏移，重测时整份换掉。
class _TableRecord {
  _TableRecord({
    required this.key,
    required this.firstLine,
    required this.lastLine,
    required this.dividerLine,
    required this.firstStart,
    required this.table,
    required this.blocks,
    required this.editRow,
    required this.editColumn,
  });

  final String key;
  int firstLine;
  int lastLine;
  int dividerLine;
  int firstStart;
  final _Table table;
  final List<_TableLineBlock> blocks;

  /// 测量时光标所在的格子（行、列）；`-1` 表示光标不在表里。
  int editRow;
  int editColumn;

  void dispose() {
    table.dispose();
    for (final _TableLineBlock block in blocks) {
      block.dispose();
    }
  }
}

/// 整格落在 [band] 里就算选中。
///
/// 色带的两端就是格子边界，所以一格要么整个在里面、要么整个在外面；半像素
/// 只是给外框的栅格化取整留余量。
bool _cellInBand(_CellData cell, _RowBand band) =>
    cell.x >= band.left - 0.5 && cell.x + cell.boxWidth <= band.right + 0.5;

/// 一行实时表格：既是行引擎的自绘内容，也是指针层的 chrome 提供者。
///
/// 一行只画**自己那一段**：整表测量给出每格在表坐标里的位置与合并块的完整
/// 矩形，绘制时按行裁剪，所以跨行的合并块由它经过的每一行各画一截，行滚出
/// 视口也不会留下空白。
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
    required this.paper,
    required this.textScaler,
    required this.memoStore,
    required this.bandOf,
  });

  final _Table table;
  final _RowData row;
  final int rowIndex;
  final int rowCount;

  /// 表的身份就是第一行的源码偏移；表在文档里移动后由 [_rebind] 更新，
  /// 拖拽预览和 chrome 才能继续认得出它。
  int tableId;
  final bool header;

  /// 块的最后一行：它负责闭合表格的底边。
  final bool last;

  final AppPalette palette;

  /// 整行纸面的颜色（见 [LiveTableBlocks.paper]）。
  final Color paper;

  final TextScaler textScaler;

  /// 抓手图标的共享缓存；实例归 [LiveTableBlocks] 所有。
  final _CellMemoStore memoStore;

  /// 按行号取整张表的选区色带（`null` 表示这一行没被选中）。
  final _RowBand? Function(int index) bandOf;

  Offset _globalOrigin = Offset.zero;
  bool _disposed = false;

  double get _rowHeight => table.rowHeights[rowIndex];

  @override
  double get height => _rowHeight;

  @override
  double get width => table.width;

  /// Every cell that puts pixels on this row: the row's own cells, plus the
  /// anchors of merges that started above and reach down here.
  Iterable<_CellData> _cellsToPaint() sync* {
    for (final _CellData cell in row.data) {
      if (!cell.covered) yield cell;
    }
    for (final TableMerge m in table.merges) {
      if (m.row < rowIndex && rowIndex <= m.lastRow) {
        yield table.rows[m.row].data[m.column];
      }
    }
  }

  /// Where a cell's painter starts, in this row's coordinates.
  double _localTop(_CellData cell) => cell.textTop - table.rowTops[rowIndex];

  /// A cell's **whole** box in canvas coordinates. For a merge this is the
  /// whole merged rectangle — the row clip keeps the slice.
  Rect _paintRect(_CellData cell, double left, double top) => Rect.fromLTWH(
    left + cell.x,
    top - table.rowTops[rowIndex] + cell.mergeTop,
    cell.boxWidth,
    cell.mergeHeight,
  );

  // ------------------------------------------------------------ 行内几何

  /// 第 [column] 列的格子在本行里的矩形。覆盖格宽度为零。
  Rect _cellRect(int column) {
    if (column < 0 || column >= row.data.length) {
      return Rect.fromLTWH(table.width, 0, 0, _rowHeight);
    }
    final _CellData cell = row.data[column];
    return Rect.fromLTWH(cell.x, 0, cell.boxWidth, _rowHeight);
  }

  List<Rect> cells() => <Rect>[
    for (int i = 0; i < row.data.length; i++) _cellRect(i),
  ];

  @override
  int offsetAt(Offset local) {
    if (row.data.isEmpty) return row.start;
    final int? column = table.columnAt(local.dx);
    if (column == null) {
      // 表格左/右的空白：贴到最近的一端，与段落里点空白的行为一致。
      return local.dx < 0 ? row.data.first.cell.offset : row.end;
    }
    final TableMerge? merge = table.mergeAt(rowIndex, column);
    if (merge != null) {
      return _offsetIn(table.anchorCell(rowIndex, column), local);
    }
    if (column >= row.data.length) return row.end;
    return _offsetIn(row.data[column], local);
  }

  int _offsetIn(_CellData cell, Offset local) {
    final TextPainter? tp = cell.painter;
    if (tp == null) return cell.cell.offset;
    final int at = tp
        .getPositionForOffset(
          Offset(
            local.dx - cell.textX,
            table.rowTops[rowIndex] + local.dy - cell.textTop,
          ),
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
      return Rect.fromLTWH(0, 0, 0, _rowHeight);
    }
    int index = row.data.length - 1;
    for (int i = 0; i < row.data.length; i++) {
      final _CellData cell = row.data[i];
      if (offset <= cell.cell.offset + cell.cell.text.length) {
        index = i;
        break;
      }
    }
    final _CellData raw = row.data[index];
    final _CellData cell = table.mergeAt(rowIndex, index) == null
        ? raw
        : table.anchorCell(rowIndex, index);
    final TextPainter? tp = cell.painter;
    if (tp == null) {
      return Rect.fromLTWH(cell.x, 0, 0, _rowHeight);
    }
    final int local = (offset - cell.cell.offset).clamp(
      0,
      cell.cell.text.length,
    );
    final TextPosition position = TextPosition(offset: local);
    final Offset caret = tp.getOffsetForCaret(position, Rect.zero);
    final double caretHeight = tp.getFullHeightForCaret(position, Rect.zero);
    return Rect.fromLTWH(
      cell.textX + caret.dx,
      _localTop(cell) + caret.dy,
      0,
      caretHeight > 0 ? caretHeight : tp.height,
    );
  }

  @override
  List<Rect> highlightRects(int from, int to) {
    if (to <= from || row.data.isEmpty) return const <Rect>[];
    final List<Rect> out = <Rect>[];
    for (final _CellData cell in row.data) {
      final TextPainter? tp = cell.painter;
      if (tp == null) continue;
      final int start = cell.cell.offset;
      final int end = start + cell.cell.text.length;
      final int a = math.max(from, start);
      final int b = math.min(to, end);
      if (b <= a) continue;
      final List<TextBox> boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: a - start, extentOffset: b - start),
      );
      if (boxes.isEmpty) continue;
      final List<LineMetrics> lines = tp.computeLineMetrics();
      final double origin = _localTop(cell);
      for (final TextBox box in boxes) {
        // 单行格沿用整行高度（与表格色带一致）；换行后的格子每一折行
        // 只染自己那一条，避免两条高亮在同一个格子里叠色。
        if (lines.length <= 1) {
          out.add(
            Rect.fromLTRB(
              cell.textX + box.left,
              cell.mergeHeight == _rowHeight ? 0 : origin,
              cell.textX + box.right,
              cell.mergeHeight == _rowHeight ? _rowHeight : origin + tp.height,
            ),
          );
        } else {
          final LineMetrics line = _lineAt(lines, (box.top + box.bottom) / 2);
          final double top = origin + line.baseline - line.ascent;
          out.add(
            Rect.fromLTRB(
              cell.textX + box.left,
              top,
              cell.textX + box.right,
              top + line.height,
            ),
          );
        }
      }
    }
    return out;
  }

  // -------------------------------------------------------------- 绘制

  @override
  void paint(Canvas canvas, Offset origin, Offset globalOrigin) {
    _globalOrigin = globalOrigin;
    if (row.data.isEmpty) return;

    final double rowHeight = _rowHeight;
    // 1px 的网格线必须落在设备像素上：整体坐标里的那点小数偏差在这里抹掉。
    final double left =
        origin.dx + (globalOrigin.dx.roundToDouble() - globalOrigin.dx);
    final double top =
        origin.dy + (globalOrigin.dy.roundToDouble() - globalOrigin.dy);
    final double right = left + table.width;
    final double bottom = top + rowHeight;

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
    RRect bandShape() => RRect.fromRectAndCorners(
      Rect.fromLTRB(bl, top, br, bottom),
      topLeft: roundTL ? Radius.circular(radius) : Radius.zero,
      topRight: roundTR ? Radius.circular(radius) : Radius.zero,
      bottomLeft: roundBL ? Radius.circular(radius) : Radius.zero,
      bottomRight: roundBR ? Radius.circular(radius) : Radius.zero,
    );

    final List<_CellData> painted = _cellsToPaint().toList(growable: false);

    canvas.save();
    // The clip is the row slice: a rowspan's fill and glyphs must not reach
    // into the rows above or below. Horizontally it bleeds one pixel each
    // side, because the outer rules are snapped to the device grid and
    // `edgeAt(table.width)` can round a fraction past the table's fractional
    // right edge — a hard clip at `right` erased the right border.
    canvas.clipRect(Rect.fromLTRB(left - 1, top, right + 1, bottom));

    // 纸面：整行先铺一层不透明的纸色。字段自己那层整行高亮还在下面，
    // 不铺这一层，没被格子覆盖到的地方会露出“整行都选中”的错觉。
    final Paint paperPaint = Paint()..color = paper;
    canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), paperPaint);

    // 单元格填充在文字和选区**之下**：选中格里仍能看见填色。
    for (final _CellData cell in painted) {
      final Color? fill = cell.fill;
      if (fill == null) continue;
      canvas.drawRect(_paintRect(cell, left, top), Paint()..color = fill);
    }

    // 选区洗色：**一整块不透明的、按格子吸附的**色带，只在形状真正拐弯的
    // 角上圆角。上下两行叠起来就是一条连续的带子。有填色的格子从填色起调，
    // 没填色的从纸面起调。
    if (band != null) {
      final double washAlpha = header ? 0.18 : 0.11;
      final Color tint = palette.selectionEdge.withValues(alpha: washAlpha);
      final RRect shape = bandShape();
      canvas.save();
      canvas.clipRRect(shape);
      canvas.drawRect(
        Rect.fromLTRB(bl, top, br, bottom),
        Paint()..color = Color.alphaBlend(tint, paper),
      );
      for (final _CellData cell in painted) {
        final Color? fill = cell.fill;
        if (fill == null) continue;
        canvas.drawRect(
          _paintRect(cell, left, top),
          Paint()..color = Color.alphaBlend(tint, tableFillOver(palette, fill)),
        );
      }
      canvas.restore();
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
          table.columns.length - 1,
          preview.index + preview.count - 1,
        );
        for (int c = preview.index; c <= stop; c++) {
          final _ColumnBox box = table.columns[c];
          if (box.width <= 0) continue;
          canvas.drawRect(
            Rect.fromLTWH(left + box.x, top, box.width, rowHeight),
            hot,
          );
          if (c == preview.index) {
            canvas.drawRect(
              Rect.fromLTWH(left + box.x, top, 2, rowHeight),
              Paint()..color = palette.accent,
            );
          }
        }
      } else if (rowIndex >= preview.index &&
          rowIndex < preview.index + preview.count) {
        canvas.drawRect(Rect.fromLTWH(left, top, table.width, rowHeight), hot);
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
    // 选中色按**格子**上：色带就是这一行里被选中的那几格，格子要么整格在里
    // 面、要么整格在外面。按线性选区上色会把两端之间的邻列一起点亮。
    final Color selectedChip = _selectedChip(palette);
    for (final _CellData cell in painted) {
      if (cell.chips.isEmpty) continue;
      final bool cellSelected = band != null && _cellInBand(cell, band);
      final Offset cellOrigin = Offset(
        left + cell.textX,
        top + _localTop(cell),
      );
      for (final _PaintedChip chip in cell.chips) {
        chipPaint.color = chip.tint && cellSelected ? selectedChip : chip.fill;
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
    // 合并块内部的横线与竖线跳过——一个合并块是一个人眼里的一格。
    final Paint line = Paint()..color = palette.rule;
    final Paint strong = Paint()
      ..color = band == null ? _strongRule(palette) : palette.rule;
    void grid(Paint paint) {
      _lineAcross(canvas, left, top, table.width, _topSkips(), paint);
      for (int c = 0; c < table.columns.length; c++) {
        if (c > 0 && table.mergeAcross(rowIndex, c)) continue;
        canvas.drawRect(
          Rect.fromLTWH(edgeAt(table.columns[c].x), top, 1, rowHeight),
          paint,
        );
      }
      canvas.drawRect(
        Rect.fromLTWH(edgeAt(table.width), top, 1, rowHeight),
        paint,
      );
    }

    grid(line);
    if (header || last) {
      _lineAcross(
        canvas,
        left,
        bottom - 1,
        table.width,
        _bottomSkips(),
        strong,
      );
    }
    if (band != null) {
      final RRect shape = bandShape();
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
        _lineAcross(
          canvas,
          left,
          bottom - 1,
          table.width,
          _bottomSkips(),
          lifted,
        );
      }
      canvas.restore();
      _paintBandOutline(canvas, left, band, above, below, bl, br, top, bottom);
    }

    // 文字最后画，压在底色和网格上。
    for (final _CellData cell in painted) {
      final TextPainter? tp = cell.painter;
      if (tp == null) continue;
      tp.paint(canvas, Offset(left + cell.textX, top + _localTop(cell)));
    }

    canvas.restore();

    // chrome 再压在一切之上，免得被自己画出来的洗色盖住。
    _paintChrome(canvas, left, top);

    // 拖动列宽时的落点线：每一行各画自己那一截，拼起来就是整张表高度。
    final TableResizePreview? resize = tableResizePreview.value;
    if (resize != null && resize.tableId == tableId) {
      final double x = (left + resize.localX).roundToDouble();
      canvas.drawRect(
        Rect.fromLTWH(x - 1, top, 2, rowHeight),
        Paint()..color = palette.accent,
      );
    }
  }

  /// 本行顶线上被“从上面延续下来的合并块”占据的横向区间。
  List<(double, double)> _topSkips() => <(double, double)>[
    for (final TableMerge m in table.merges)
      if (m.row < rowIndex && rowIndex <= m.lastRow) table.mergeSpan(m),
  ];

  /// 本行底线上被“继续向下延伸的合并块”占据的横向区间。
  List<(double, double)> _bottomSkips() => <(double, double)>[
    for (final TableMerge m in table.merges)
      if (m.row <= rowIndex && rowIndex < m.lastRow) table.mergeSpan(m),
  ];

  /// 一条横向网格线，跳过 [skips] 的区间。
  static void _lineAcross(
    Canvas canvas,
    double left,
    double top,
    double width,
    List<(double, double)> skips,
    Paint paint,
  ) {
    if (skips.isEmpty) {
      canvas.drawRect(Rect.fromLTWH(left, top, width, 1), paint);
      return;
    }
    final List<(double, double)> sorted = skips.toList()
      ..sort((a, b) => a.$1.compareTo(b.$1));
    double x = 0;
    for (final (double a, double b) in sorted) {
      if (a > x) {
        canvas.drawRect(Rect.fromLTWH(left + x, top, a - x, 1), paint);
      }
      x = math.max(x, b);
    }
    if (x < width) {
      canvas.drawRect(Rect.fromLTWH(left + x, top, width - x, 1), paint);
    }
  }

  /// 抓手、两个 `+` 和列分隔线：**只有悬停时才画**。抓手是一枚按钮，
  /// `+` 与分隔线仍然只有图标 / 线本身。
  void _paintChrome(Canvas canvas, double left, double top) {
    final Offset painted = Offset(left, top);
    final bool resizing = tableResizePreview.value != null;
    for (final TableChromeTarget target in _controls()) {
      if (!_visible(target.kind, target.rect, target.index)) continue;
      final bool grabbed = _dragging(target.kind, target.index);
      final bool on = grabbed || _pointing(target.rect);
      final Color color = on ? palette.accent : palette.textTertiary;
      final double weight = on ? 1.6 : 1.2;
      final Rect r = target.rect.shift(painted);
      switch (target.kind) {
        case TableChromeKind.rowHandle:
          _paintGrip(canvas, r, active: on, horizontal: false);
        case TableChromeKind.columnHandle:
          _paintGrip(canvas, r, active: on, horizontal: true);
        case TableChromeKind.addRow:
        case TableChromeKind.addColumn:
          _paintPlus(canvas, r, color: color, weight: weight);
        case TableChromeKind.resizeColumn:
          // 拖动时由落点线接管，悬停线让位。
          if (resizing) continue;
          canvas.drawRect(
            Rect.fromLTWH(r.left.roundToDouble(), r.top, 1, r.height),
            Paint()..color = palette.accent.withValues(alpha: 0.45),
          );
      }
    }
  }

  /// 六点抓手：一枚圆角按钮，行抓手两列三行，列抓手三列两行。
  ///
  /// 只有六个点时，抓手在深色纸上既看不清也不像控件。按钮用浮层色打底、
  /// 控件描边收口，点阵居中标出拖动方向；指到或抓住时整枚反相，与 `+` 的
  /// 悬停反馈同一个语气。
  ///
  /// 点阵从图标字体里重绘，而不是手描六个圆：绘制发生在自绘层里，`Icon`
  /// 需要一个 widget，而那个 widget 会把光标需要的点击吞掉。
  void _paintGrip(
    Canvas canvas,
    Rect r, {
    required bool active,
    required bool horizontal,
  }) {
    final RRect button = RRect.fromRectAndRadius(r, const Radius.circular(4));
    canvas.drawRRect(
      button,
      Paint()..color = active ? palette.accent : palette.surfaceRaised,
    );
    // 半像素内缩让 1px 描边落在像素中心；浅色主题下白底白纸也要有边。
    canvas.drawRRect(
      button.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = active ? palette.accent : palette.outline,
    );
    // 图标 painter 按颜色与方向缓存：绘制每帧、每个可见抓手都要用，
    // 而同一帧里颜色只有静息 / 反相两种。
    final TextPainter tp = memoStore.gripPainter(
      active ? palette.onAccent : palette.textSecondary,
      horizontal: horizontal,
    );
    tp.paint(canvas, r.center - Offset(tp.width / 2, tp.height / 2));
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
    // 所有 painter 都归整表测量所有；行块只借来画。
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
  Rect chromeBounds() => _globalOrigin & Size(table.width, _rowHeight);

  @override
  List<Rect> chromeCells() => <Rect>[
    for (final Rect cell in cells()) _globalOrigin + cell.topLeft & cell.size,
  ];

  @override
  List<InlineSpan> chromeCellSpans() => <InlineSpan>[
    for (final _CellData cell in row.data)
      TextSpan(style: cell.style, children: cell.spans),
  ];

  @override
  List<double> chromeColumnWidths() => <double>[
    for (final _ColumnBox box in table.columns) box.width - 2 * _kCellPad,
  ];

  @override
  double chromeColumnRoom() => table.columnRoom;

  @override
  double chromeWidthScale() => table.widthScale;

  bool get _paintsColumnGrip => rowIndex == 0;
  bool get _paintsAddRow => rowIndex == rowCount - 1;
  bool get _paintsAddColumn => rowIndex == 0;

  Rect _rowGripRect() => Rect.fromLTWH(
    -_kChromeGap - _kGrip,
    (_rowHeight - _kGrip) / 2,
    _kGrip,
    _kGrip,
  );

  Rect _columnGripRect(int column) {
    final _ColumnBox? box = column >= 0 && column < table.columns.length
        ? table.columns[column]
        : null;
    final double cx = box == null ? table.width : box.x + box.width / 2;
    return Rect.fromLTWH(
      cx - _kGrip / 2,
      -_kChromeGap - _kGrip,
      _kGrip,
      _kGrip,
    );
  }

  Rect _addRowRect() => Rect.fromLTWH(
    table.width / 2 - _kAdd / 2,
    _rowHeight + _kChromeGap,
    _kAdd,
    _kAdd,
  );

  Rect _addColumnRect() => Rect.fromLTWH(
    table.width + _kChromeGap,
    (_rowHeight - _kAdd) / 2,
    _kAdd,
    _kAdd,
  );

  /// 这一行可能画出的所有控件（行内坐标）。
  List<TableChromeTarget> _controls() => <TableChromeTarget>[
    TableChromeTarget(TableChromeKind.rowHandle, _rowGripRect(), rowIndex),
    if (_paintsColumnGrip)
      for (int c = 0; c < table.columns.length; c++)
        TableChromeTarget(TableChromeKind.columnHandle, _columnGripRect(c), c),
    // 每一行都有一条条露出来的内部分隔线；合并块内部的边界没有。
    // `mergeAcross` 要的是线右侧那一列的下标，而 chrome 的 `index` 记的是左列。
    for (int c = 0; c + 1 < table.columns.length; c++)
      if (!table.mergeAcross(rowIndex, c + 1))
        TableChromeTarget(TableChromeKind.resizeColumn, _resizeRect(c), c),
    // 最右边那条竖线是表格的外框，合并块盖不到它：拖它只改最后一列。
    if (table.columns.isNotEmpty)
      TableChromeTarget(
        TableChromeKind.resizeColumn,
        _resizeRect(table.columns.length - 1),
        table.columns.length - 1,
      ),
    if (_paintsAddColumn)
      TableChromeTarget(TableChromeKind.addColumn, _addColumnRect(), -1),
    if (_paintsAddRow)
      TableChromeTarget(TableChromeKind.addRow, _addRowRect(), -1),
  ];

  /// 内部分隔线的命中矩形：就是网格里那根 1px 竖线。
  Rect _resizeRect(int boundary) =>
      Rect.fromLTWH(table.columns[boundary].right, 0, 1, _rowHeight);

  bool _hovering(Rect local, {double slop = kTableChromeSlop}) {
    final Offset? p = tablePointerPosition.value;
    if (p == null) return false;
    return local.shift(_globalOrigin).inflate(slop).contains(p);
  }

  /// 整张表在全局坐标里的矩形：这一行只是其中一条，抓手区却按整张表算。
  Rect _tableBounds() {
    final double top = _globalOrigin.dy - table.rowTops[rowIndex];
    final double height = table.rowTops.last + table.rowHeights.last;
    return Rect.fromLTWH(_globalOrigin.dx, top, table.width, height);
  }

  /// 左侧或上方那条整条悬停带：宽/高就是一枚抓手加两侧的容差。
  ///
  /// 左侧带纵向覆盖整张表，上方带横向覆盖整张表——但只有指针所在的那一
  /// 行/列才露抓手：鼠标扫过整条边，抓手跟着行/列一枚一枚地走。容差只
  /// 负责「够得着这条带」，行/列归谁另按恰好分界算（见 [_stripRowHovered]），
  /// 免得相邻两行在边界附近同时认领指针。
  Rect _stripRect(TableChromeStrip strip) {
    final Rect table = _tableBounds();
    return switch (strip) {
      TableChromeStrip.rows => Rect.fromLTRB(
        table.left - _kChromeGap - _kGrip - kTableChromeSlop,
        table.top - kTableChromeSlop,
        table.left - _kChromeGap + kTableChromeSlop,
        table.bottom + kTableChromeSlop,
      ),
      TableChromeStrip.columns => Rect.fromLTRB(
        table.left - kTableChromeSlop,
        table.top - _kChromeGap - _kGrip - kTableChromeSlop,
        table.right + kTableChromeSlop,
        table.top - _kChromeGap + kTableChromeSlop,
      ),
    };
  }

  /// 指针在左带里、且纵向落在这**这一行**上——行与行恰好分界、互不重叠，
  /// 所以任意时刻至多一枚行抓手露出来。分界处不给容差：指针瞄的是行中央
  /// 那枚 20px 按钮，不是行与行之间的缝；给容差反而让相邻两行同时认领
  /// 指针（±6 会重叠 12px），上一枚抓手就赖着不消失。
  bool _stripRowHovered() {
    final Offset? p = tablePointerPosition.value;
    if (p == null || !_stripRect(TableChromeStrip.rows).contains(p)) {
      return false;
    }
    return p.dy >= _globalOrigin.dy && p.dy < _globalOrigin.dy + _rowHeight;
  }

  /// 指针在上带里、且横向落在第 [column] 列上——列与列恰好分界、互不重叠，
  /// 只有这一列的抓手该露面。列抓手只由第一行画。
  bool _stripColumnHovered(int column) {
    final Offset? p = tablePointerPosition.value;
    if (p == null || !_stripRect(TableChromeStrip.columns).contains(p)) {
      return false;
    }
    final _ColumnBox box = table.columns[column];
    return p.dx >= _globalOrigin.dx + box.x &&
        p.dx < _globalOrigin.dx + box.x + box.width;
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

  bool _visible(TableChromeKind kind, Rect local, int index) {
    if (_dragging(kind, index)) return true;
    return switch (kind) {
      TableChromeKind.rowHandle => _stripRowHovered(),
      TableChromeKind.columnHandle => _stripColumnHovered(index),
      TableChromeKind.addRow || TableChromeKind.addColumn => _hovering(local),
      TableChromeKind.resizeColumn => _hovering(
        local,
        slop: kTableResizeHitSlop,
      ),
    };
  }

  @override
  TableChromeStrip? chromeStripAt(Offset globalPosition) {
    if (_stripRect(TableChromeStrip.rows).contains(globalPosition)) {
      return TableChromeStrip.rows;
    }
    if (_stripRect(TableChromeStrip.columns).contains(globalPosition)) {
      return TableChromeStrip.columns;
    }
    return null;
  }

  @override
  int? chromeStripIndexAt(Offset globalPosition, TableChromeStrip strip) {
    if (!_stripRect(strip).contains(globalPosition)) return null;
    if (strip == TableChromeStrip.rows) {
      final bool inRow =
          globalPosition.dy >= _globalOrigin.dy &&
          globalPosition.dy < _globalOrigin.dy + _rowHeight;
      return inRow ? rowIndex : null;
    }
    if (!_paintsColumnGrip) return null;
    for (int c = 0; c < table.columns.length; c++) {
      final _ColumnBox box = table.columns[c];
      if (globalPosition.dx >= _globalOrigin.dx + box.x &&
          globalPosition.dx < _globalOrigin.dx + box.x + box.width) {
        return c;
      }
    }
    return null;
  }

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
