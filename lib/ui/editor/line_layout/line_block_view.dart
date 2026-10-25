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

import '../../../core/utils/image_markup.dart';
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
///
/// [resizeColumn] 不是画出来的图标：它的命中区就是两根柱子之间的那条 1px
/// 竖线，悬停时改画一条线，而不是抓手。
enum TableChromeKind {
  rowHandle,
  columnHandle,
  addRow,
  addColumn,

  /// 第 `index` 列与第 `index + 1` 列之间的分隔线。
  resizeColumn,
}

/// 悬停时显形的两片抓手区：左侧的每一行、上方的每一列。
///
/// 一条边上只露**指针所在那一行/列**的一枚抓手：鼠标沿着边扫过去，抓手
/// 跟着行/列走，而不是整排同时出现。
enum TableChromeStrip { rows, columns }

/// 表格 chrome 伸出内容区左上侧的最大距离（抓手 20px + 间距 5px + 悬停
/// 容差 6px）。
///
/// 块行的 `insets` 是零，表格的左缘就顶在内容原点；行抓手因此落在文档
/// 坐标的负 x 上。字段的绘制裁剪得向这两个方向放宽这么多，抓手才画得
/// 出来（右侧、下侧不动：正文从不为负坐标，只有 chrome 会伸出去）。
const double kTableChromeBleed = 31;

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

  /// 各列的文字宽（不含内边距），渲染像素，从左到右。
  List<double> chromeColumnWidths();

  /// 整张表可用的文字总宽，渲染像素。
  double chromeColumnRoom();

  /// 渲染像素 / 源码 `w=…` 里的设计像素。
  double chromeWidthScale();

  /// 这一行**可能**画出的所有抓手与 `+`，全局坐标。命中测试用它：
  /// 指针只有悬停在上面时才够得到，而那也正是它可见的条件。
  List<TableChromeTarget> chromeTargets();

  /// [globalPosition] 落在哪一片整条抓手区里，不在边上时为 `null`。
  ///
  /// 左侧是整张表高的窄条，上方是整张表宽的窄条。命中测试仍按单枚抓手
  /// 算（见 [chromeTargets]）；这里只回答「指针有没有进这条边」。
  TableChromeStrip? chromeStripAt(Offset globalPosition);

  /// [globalPosition] 落在 [strip] 边上的哪一行/列（行下标或列下标），
  /// 不在本行/列的范围里时为 `null`。
  ///
  /// 可见性按它算：一行只答自己那行（或第一行答每一列），指针扫过边的
  /// 时候只有指针下的那一枚抓手显形。
  int? chromeStripIndexAt(Offset globalPosition, TableChromeStrip strip);

  /// 此刻真的画出来的那一部分——只随悬停出现，拖动时是落点目标。
  List<TableChromeTarget> chromeVisible();

  /// 本行左上角的全局坐标。
  ///
  /// 自绘行只在行内坐标里排版，悬停与命中都发生在全局坐标系里，所以渲染
  /// 对象每次查询前把这份原点写进来。自己就从渲染对象算出全局坐标的实现
  /// （旧的段落内表格行）把它当空操作。
  set chromeOrigin(Offset value);
}

// ------------------------------------------------------------- 图片的控件层
//
// 图片块同样由渲染对象持有。它的右下角手柄要在指针事件里命中，而图片行的
// 源码偏移会随着上方编辑整体平移——行本身被复用、块却不重测——所以渲染
// 对象每次绘制/查询时把当前行范围回写进来，命中与光标映射才不会落在旧偏移上。

/// 图片块右下角缩放手柄的命中区，**全局坐标**。
class ImageResizeHandle {
  const ImageResizeHandle(this.rect);

  /// 建议 14×14，中心在图片右下角。
  final Rect rect;
}

/// 指针层需要一行实时图片回答的东西。
abstract class ImageBlockChrome {
  /// 图片行首字符的文档偏移。
  int get imageSourceStart;

  /// 把这一行当前的源码范围写回来（上方编辑会让整行平移）。
  void chromeSourceRange(int start, int end);

  /// 本行左上角的全局坐标；渲染对象每次查询前写入。
  set chromeOrigin(Offset value);

  /// 图片矩形，全局坐标。
  Rect chromeImageBounds();

  /// 编辑时让出来的那一行源码占的矩形，全局坐标；没在编辑时是空矩形。
  ///
  /// 源码不是浮在图片上的：这一行会为它长高一行，图片整体下移。外面（编辑器）
  /// 就靠这个矩形把输入框摆进去——它正好是那一行本该在的位置。
  Rect chromeSourceBounds();

  /// 不可缩放时 null。
  ImageResizeHandle? chromeResizeHandle();

  /// 靠边浮动时贴哪一边；`null` 表示独占一行。
  ///
  /// 引擎据此把这一行的高度算成 0，并让后面几行在另一侧绕排——图片不再把
  /// 下面所有文字顶开，「左文字右图片」就是这么来的。
  ImageAlign? get chromeAlign;

  /// 浮动时它横向占住的宽度（图片宽 + 与正文的间距）；不浮动为 0。
  double get chromeFloatWidth;

  /// 选中态：画一圈强调色边框。
  ///
  /// 只改绘制、不改排版，所以由编辑器直接写进来再 [RenderObject.markNeedsPaint]
  /// 即可——选中一张图不该把整篇重新排版一遍。
  set chromeSelected(bool value);

  /// 此刻是否画着边框。
  bool get chromeSelected;
}
