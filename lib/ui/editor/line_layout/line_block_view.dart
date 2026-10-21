/// 按行排版里「这一行不是一行文字」的出口。
///
/// 绝大多数源码行就是一个 `TextPainter`：字形、换行、光标落点全由引擎算。
/// 但实时表格的一行不是——它的列宽由整张表决定，格子的文字要对齐到网格，
/// 行和列的抓手、`+` 按钮、整块的选区还要按格子画。这些都不是单个
/// `TextPainter` 能表达的，也不是「把源码排成一行字」能得到的结果。
///
/// 所以引擎留了这一个口子：宿主按行给一个 [LineBlockView]，这一行的行高、
/// 绘制、光标落点改由它回答，引擎只负责把它放在正确的 y 上、把坐标换算好。
/// 表格是唯一的使用者，但 [LineBlockView] 本身不认识表格。
library;

import 'package:flutter/painting.dart';

import 'line_layout_model.dart';

/// 一行源码的自绘内容。
///
/// 所有坐标都是**行内局部坐标**：原点在这一行的左上角（正文列），x 向右，
/// y 向下。渲染对象负责把它放到 `(gutter, top)` 上再叠加滚动偏移。
abstract class LineBlockView {
  /// 这一行占的高度。引擎不再按文字测量它。
  double get height;

  /// 内容宽度（表格的实际宽度，可以窄于正文列）。
  double get width;

  /// [origin] 是这一行在画布坐标里的左上角，[globalOrigin] 是同一个点的
  /// 全局坐标（用来把 1px 的网格线对齐到设备像素，也用来判断悬停）。
  void paint(Canvas canvas, Offset origin, Offset globalOrigin);

  /// 释放这一行持有的排版资源。可能被调用多次。
  void dispose();

  /// 行内局部坐标 [local] 对应的源码偏移。
  int offsetAt(Offset local);

  /// 源码偏移 [offset] 处的光标矩形（行内局部坐标）。
  Rect caretRectAt(int offset);

  /// 源码区间 `[from, to)` 的高亮矩形（行内局部坐标）。
  ///
  /// 这一行没有字形可量，选区盒子只能由它自己回答；表格按格子给块，所以
  /// 一次查询可能返回多个矩形。区间只擦到行首/行尾以外的字符时返回空。
  List<Rect> highlightRects(int from, int to);
}

/// 排版一行时能拿到的环境。
class LineBlockContext {
  const LineBlockContext({
    required this.contentWidth,
    required this.textScaler,
    required this.textDirection,
  });

  /// 正文列的可用宽度。
  final double contentWidth;
  final TextScaler textScaler;
  final TextDirection textDirection;
}

/// 按行取自绘内容；`null` 表示这一行照常排文字。
typedef LineBlockResolver =
    LineBlockView? Function(SourceLine line, LineBlockContext context);

// ------------------------------------------------------------- 表格的控件层
//
// 下面这些是表格特有的，但定义在这里而不是 `live_markdown` 里：自绘行由
// 渲染对象持有，而渲染对象只在 `line_layout/` 里；把契约放在两边都能看到
// 的这一个文件里，就不必让通用渲染层反过来依赖 live 层。

/// 实时表格挂在表格边缘的小控件：拖整行、拖整列，以及在两个方向上加一行/列。
enum TableChromeKind { rowHandle, columnHandle, addRow, addColumn }

/// 一个画出来的 chrome 控件，**全局坐标**。
class TableChromeTarget {
  const TableChromeTarget(this.kind, this.rect, this.index);

  final TableChromeKind kind;
  final Rect rect;

  /// 控件所属的行或列。两个 `+` 按钮是 `-1`：它们的方向就是全部含义。
  final int index;
}

/// 指针层需要一行实时表格回答的东西。
abstract class TableRowChrome {
  /// 这一行所属表格块的身份（块首行的偏移）。
  int get chromeTableId;

  /// 这一行首字符的文档偏移。
  int get chromeSourceStart;

  /// 这一行在块内非分隔行里的序号。
  int get chromeRowIndex;
  int get chromeRowCount;

  /// 这一行画出来的矩形，全局坐标——宽度是整张表的宽度。
  Rect chromeBounds();

  /// 各格子的全局矩形，从左到右。
  List<Rect> chromeCells();

  /// 各格子此刻画出来的 span 树，从左到右。
  ///
  /// 格子由 `TextPainter` 直接画，没有 widget 可查；「这一格展开成源码、
  /// 那一格仍是成品」只体现在这棵树上，所以命中调试与测试读这里。
  List<InlineSpan> chromeCellSpans();

  /// 这一行**可能**画出的所有抓手与 `+`，全局坐标。命中测试用它：
  /// 指针只有悬停在上面时才够得到，而那也正是它可见的条件。
  List<TableChromeTarget> chromeTargets();

  /// 此刻真的画出来的那一部分——只随悬停出现，拖动时是落点目标。
  List<TableChromeTarget> chromeVisible();

  /// 本行左上角的全局坐标。
  ///
  /// 自绘行只在行内坐标里排版，悬停与命中都发生在全局坐标系里，所以渲染
  /// 对象每次查询前把这份原点写进来。自己就从渲染对象算出全局坐标的实现
  /// （旧的段落内表格行）把它当空操作。
  set chromeOrigin(Offset value);
}
