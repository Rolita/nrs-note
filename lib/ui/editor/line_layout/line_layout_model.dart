/// 按行排版的数据模型：一行源码怎么分类、怎么切块、标记槽位有多宽。
///
/// 这里只有扫描与几何值，不持有任何渲染对象。测量在
/// `line_layout_engine.dart` 里完成——每行一个 [TextPainter]，因此换行点、
/// 光标位置和选区盒子都只在这一行内部计算，第二行不会再退回段落左边缘。
///
/// 为什么要按行：`ParagraphStyle` 没有 `textIndent`，而 `RenderEditable`
/// 整篇只有一个 `TextPainter`。一个段落里的软换行永远回到段落左边缘，
/// 列表的续行就会钻到序号下面。把每一行源码当成独立段落，续行的起点
/// 就由 [SourceLine.paintStart] 与 [MarkerSlot] 决定。
library;

import 'package:flutter/painting.dart';

import '../../../core/utils/markdown_actions.dart';
import '../../../core/utils/table_model.dart';

/// 一行源码的块种类。
///
/// 与 `live_markdown/spans.dart` 的私有 `_Kind` 一一对应，判定顺序也一致：
/// 先后本身就是规则（`# 标题` 先于 `- 列表`，围栏内的一切都是代码）。
enum LineBlockKind {
  paragraph,
  heading,
  fence,
  code,
  bullet,
  ordered,
  task,
  quote,
  rule,
  setext,
  table,
  tableHeader,
  tableDivider,
}

/// 一行源码（不含换行符）的扫描结果。
///
/// 偏移全部是**文档偏移**，不是行内偏移——渲染层拿到一个全局 offset 就能
/// 直接和 [paintStart]/[end] 比较。
class SourceLine {
  const SourceLine({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
    required this.kind,
    this.headingLevel = 0,
    this.indent = 0,
    this.nestLevel = 0,
    this.markerStart = 0,
    this.markerEnd = 0,
    this.leadEnd = 0,
    this.paintStart = 0,
    this.number,
    this.checked = false,
    this.fenceOpens = false,
  });

  /// 行号，从 0 开始。
  final int index;

  /// 行首的文档偏移。
  final int start;

  /// 行尾的文档偏移（不含换行符）。换行符本身占据 `[end, end + 1)`。
  final int end;

  /// 行源码，不含换行符。
  final String text;

  final LineBlockKind kind;

  /// 标题级别 `1..6`；非标题为 0。
  final int headingLevel;

  /// 用户输入的缩进字符数（Tab 算一个字符）。
  final int indent;

  /// 列表嵌套层级，`0..5`。两个缩进字符算一级，与既有渲染一致。
  final int nestLevel;

  /// 标记起点的文档偏移（缩进之后）。
  final int markerStart;

  /// 标记终点的文档偏移。列表行也是**正文起点**。
  final int markerEnd;

  /// 数字前缀的终点：有序任务里 `[` 的位置，其余列表行等于 [markerEnd]。
  ///
  /// 有序任务（`6. [ ] 事`）的槽位是「数字 + 空白 + 复选框」，复选框宽度是
  /// 固定值，所以数字那一段要单独量。
  final int leadEnd;

  /// 交给 [TextPainter] 的第一个字符的文档偏移。
  ///
  /// 列表行是 [markerEnd]（标记画在左侧槽位里），其余行是 [start]（标记
  /// 由 span 树自己隐藏或显形）。
  final int paintStart;

  /// 有序列表的序号，无序列表为 `null`。
  final int? number;

  /// 任务项是否勾选。
  final bool checked;

  /// 是否是**开**围栏行（闭合围栏行为 false）。
  final bool fenceOpens;

  /// 四种列表：无序、有序、无序任务、有序任务。
  bool get isList =>
      kind == LineBlockKind.bullet ||
      kind == LineBlockKind.ordered ||
      kind == LineBlockKind.task;

  bool get isEmpty => end == start;

  int get length => end - start;

  /// 标记源码，例如 `- `、`1. `、`- [x] `；非列表行为空串。
  String get marker =>
      isList ? text.substring(markerStart - start, markerEnd - start) : '';

  @override
  String toString() => 'SourceLine($index, ${kind.name}, $text)';
}

/// 一条视觉行（软换行之后真正画出来的一行）。
class VisualLine {
  const VisualLine({
    required this.index,
    required this.top,
    required this.height,
    required this.start,
    required this.end,
    required this.width,
  });

  /// 行内序号，从 0 开始。
  final int index;

  /// 相对所属源码行顶部的距离。
  final double top;

  final double height;

  /// 视觉行覆盖的文档偏移范围 `[start, end)`。
  final int start;
  final int end;

  /// 该视觉行实际文本宽度。
  final double width;

  double get bottom => top + height;

  @override
  String toString() => 'VisualLine($index, $start..$end, top=$top, h=$height)';
}

/// 列表行左侧的标记槽位。
///
/// 正文列 = [indent] + [marker]。续行（第二行及以后）从正文列开始画，
/// 这就是悬挂缩进的几何来源。
class MarkerSlot {
  const MarkerSlot({
    this.level = 0,
    this.indent = 0,
    this.marker = 0,
    this.digitWidth = 0,
    this.ownRailAbove = false,
    this.railXs = const <double>[],
    this.revealedMarkers = false,
  });

  /// 嵌套层级。
  final int level;

  /// 嵌套缩进总宽（`level * indentStep`）。
  final double indent;

  /// 标记自身宽度（圆点、序号+空白、复选框，或「数字 + 复选框」）。
  final double marker;

  /// 有序标记里**数字本身**的宽度（不含 `. ` 和复选框），用于把导轨对到
  /// 数字中心而不是整个前缀的中心。
  final double digitWidth;

  /// 同级自己那一列是否要从**上方**接过来。
  ///
  /// 只有同一组里前面已经有条目时才画标记上方那一段；组里的第一项（比如
  /// 一个带子项的长条目）从标记本身往下起线，避免在它上面凭空多一截。
  final bool ownRailAbove;

  /// 标记源码是否已经摊进正文（`- `、`1. `、`[ ] ` 作为真实文字参与排版）。
  ///
  /// 光标落在标记区时这一行为真：标记要能被点击、被编辑，就不能再画在槽位里。
  final bool revealedMarkers;

  /// 正文列，也就是整条缩进的宽度。
  ///
  /// 标记摊进正文后槽位不再占宽，正文直接从行首起排（缩进跟着变成真的空格）。
  double get width => revealedMarkers ? 0 : indent + marker;

  /// 每一级导轨的中心 x，供渲染层画嵌套竖线。
  final List<double> railXs;

  static const MarkerSlot none = MarkerSlot();

  @override
  String toString() =>
      'MarkerSlot(level=$level, indent=$indent, marker=$marker)';
}

/// 光标在一行里的落点。
class CaretGeometry {
  const CaretGeometry({
    required this.offset,
    required this.origin,
    required this.height,
    required this.lineIndex,
    required this.visualIndex,
  });

  /// 文档偏移。
  final int offset;

  /// 光标左上角的文档坐标。
  final Offset origin;

  final double height;
  final int lineIndex;
  final int visualIndex;

  double get top => origin.dy;
  double get bottom => origin.dy + height;
}

/// 列表槽位的度量常量。
///
/// 默认值与 `live_markdown` 的既有实现逐项对齐：
/// 每级嵌套 26px、圆点 `2 + 5 + 9 = 16`、复选框 `2 + 15 + 9 = 26`、
/// 导轨中心 `9.5`。
class LineLayoutMetrics {
  const LineLayoutMetrics({
    this.indentStep = 26,
    this.markerCentre = 9.5,
    this.bulletWidth = 16,
    this.taskWidth = 26,
    this.emptySelectionWidth = 2,
  });

  /// 每级嵌套的宽度。
  final double indentStep;

  /// 复选框中心到行首的距离。
  final double markerCentre;

  /// 无序列表圆点槽位宽度。
  final double bulletWidth;

  /// 任务复选框槽位宽度（含左右留白）。
  final double taskWidth;

  /// 空行被选中时那块光标状高亮的宽度。
  final double emptySelectionWidth;
}

// ------------------------------------------------------------------ scanning

final RegExp _kFenceRe = RegExp(r'^(\s{0,3})(`{3,}|~{3,})(.*)$');
final RegExp _kSetextRe = RegExp(r'^ {0,3}(=+)\s*$');

/// 扫描整篇源码，按行给出块种类与列表几何。
///
/// 判定顺序沿用原段落排版器的扫描次序（围栏 → 标题 → 分隔线/标题下划线 →
/// 列表/任务 → 引用），按行渲染与段落渲染对同一份源码给出同样的块种类。块标记
/// 本身复用 [scanLineMarker]——它是全项目唯一的标记判定来源，这里不再复制正则。
List<SourceLine> scanSourceLines(String text) {
  final List<String> raw = text.split('\n');
  final int n = raw.length;
  final List<int> starts = List<int>.filled(n, 0);
  for (int i = 1; i < n; i++) {
    starts[i] = starts[i - 1] + raw[i - 1].length + 1;
  }
  final List<_Scan> scans = <_Scan>[for (int i = 0; i < n; i++) _Scan(raw[i])];

  bool inFence = false;
  for (int i = 0; i < n; i++) {
    final String line = raw[i];
    final _Scan scan = scans[i];

    final Match? fence = _kFenceRe.firstMatch(line);
    if (fence != null) {
      scan.kind = LineBlockKind.fence;
      scan.fenceOpens = !inFence;
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      scan.kind = LineBlockKind.code;
      continue;
    }
    if (_kSetextRe.hasMatch(line) &&
        i > 0 &&
        scans[i - 1].kind == LineBlockKind.paragraph &&
        raw[i - 1].trim().isNotEmpty) {
      scans[i - 1].kind = LineBlockKind.heading;
      scans[i - 1].headingLevel = 1;
      scan.kind = LineBlockKind.setext;
      continue;
    }
    if (line.trimLeft().startsWith('|')) {
      final bool divider = isDividerLine(line);
      if (divider && i > 0 && scans[i - 1].kind == LineBlockKind.table) {
        scans[i - 1].kind = LineBlockKind.tableHeader;
      }
      scan.kind = divider ? LineBlockKind.tableDivider : LineBlockKind.table;
      continue;
    }
    if (line.trim().isEmpty) continue;

    final LineMarker marker = scanLineMarker(line);
    scan.indent = marker.indent;
    scan.markerLength = marker.length;
    scan.number = marker.number;
    scan.checked = marker.checked;
    scan.kind = switch (marker.kind) {
      LineMarkerKind.heading => LineBlockKind.heading,
      LineMarkerKind.bullet => LineBlockKind.bullet,
      LineMarkerKind.ordered => LineBlockKind.ordered,
      LineMarkerKind.task => LineBlockKind.task,
      LineMarkerKind.quote => LineBlockKind.quote,
      LineMarkerKind.rule => LineBlockKind.rule,
      LineMarkerKind.paragraph => LineBlockKind.paragraph,
    };
    scan.headingLevel = marker.level;
  }

  return <SourceLine>[
    for (int i = 0; i < n; i++) scans[i].toSourceLine(i, starts[i]),
  ];
}

/// 一层可变的扫描中间态，最后才冻成 [SourceLine]。
class _Scan {
  _Scan(this.text);

  final String text;
  LineBlockKind kind = LineBlockKind.paragraph;
  int headingLevel = 0;
  int indent = 0;
  int markerLength = 0;
  int? number;
  bool checked = false;
  bool fenceOpens = false;

  SourceLine toSourceLine(int index, int start) {
    final int end = start + text.length;
    final bool list =
        kind == LineBlockKind.bullet ||
        kind == LineBlockKind.ordered ||
        kind == LineBlockKind.task;
    final int markerStart = start + indent;
    final int markerEnd = markerStart + markerLength;
    int leadEnd = markerEnd;
    if (kind == LineBlockKind.task) {
      final int bracket = text.indexOf('[', indent);
      if (bracket >= 0) leadEnd = start + bracket;
    }
    return SourceLine(
      index: index,
      start: start,
      end: end,
      text: text,
      kind: kind,
      headingLevel: headingLevel,
      indent: indent,
      nestLevel: _nestLevel(text.substring(0, indent)),
      markerStart: markerStart,
      markerEnd: markerEnd,
      leadEnd: leadEnd,
      paintStart: list ? markerEnd : start,
      number: number,
      checked: checked,
      fenceOpens: fenceOpens,
    );
  }
}

/// 缩进宽度换层级：Tab 记两个字符，两个字符一级，最多五级。
int _nestLevel(String indent) {
  int width = 0;
  for (final int unit in indent.codeUnits) {
    width += unit == 0x09 ? 2 : 1;
  }
  return (width ~/ 2).clamp(0, 5);
}
