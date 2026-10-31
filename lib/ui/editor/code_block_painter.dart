import 'package:flutter/widgets.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'line_layout/render_line_editable.dart';
import 'live_markdown.dart';

/// Air above the header row and below the last line of code.
///
/// The header itself is a real (empty) line — [kCodeHeaderHeight] — so the
/// card only needs a couple of pixels above it. The bottom has no line of its
/// own: the closing fence is collapsed, and all of the breathing room below the
/// last code row lives here.
///
/// 左右的内边距不在这里：它由按行引擎的 `LineInsetResolver` 退进卡片内部
/// （见 [kCodeBlockInset]），卡片本身铺满正文列，不再越出列外。
const double kCodeSlabTopPad = 1;
const double kCodeSlabBottomPad = 12;

const double kCodeSlabRadius = AppRadius.sm;

/// The language label, laid into the card's top-right corner the way the
/// reference does: inside the padding, not on a header row that pushes the code
/// down. Measured from the slab's own edge.
const double kCodeSlabLabelTop = 10;
const double kCodeSlabLabelRight = 13;

/// The block's fill: the step that makes the card read as its own surface.
///
/// The reference draws the boundary with the fill alone and no border, and the
/// step goes *up*: `surfaceRaised` is what separates the card from the page.
Color codeSlabFill(AppPalette p) => p.surfaceRaised;

/// Paints one rounded slab behind every fenced code block, plus its language
/// label.
///
/// A `TextStyle` background can only cover the run it belongs to, so a fenced
/// block used to come out as one stripe per line — indented lines narrower than
/// their neighbours, every row separated by the leading. The block has to be
/// one shape, which means paint: this sits under the field, in the same
/// coordinates the selection wash uses, and asks the line engine
/// ([RenderLineEditable.blockRectFor]) for the rows the block covers — the
/// slab therefore lands on exactly the lines that are painted there.
///
/// The label lives here for the same reason. A `WidgetSpan` label would be a
/// line of the paragraph, and that line pushed the first code row a full header
/// below the card's edge. Painted, it can sit in the top-right corner without
/// costing a line, and it can follow the slab when the block scrolls.
class CodeBlockPainter extends CustomPainter {
  CodeBlockPainter({
    required this.controller,
    required this.scrollController,
    required this.editable,
    required this.editorBox,
    required this.fill,
    required this.labelStyle,
    required this.selection,
  }) : super(
         repaint: Listenable.merge(<Listenable>[controller, scrollController]),
       );

  final TextEditingController controller;
  final ScrollController scrollController;

  /// Resolves the live field and the box this canvas belongs to, both at paint
  /// time: the render objects are replaced across rebuilds.
  final RenderLineEditable? Function() editable;
  final RenderBox? Function() editorBox;

  final Color fill;

  /// The type on the right of the card's header — `Dart`, `Python`.
  final TextStyle labelStyle;

  /// The selection the renderer is painting for, so the label disappears while
  /// the block is knocked back to its source. `revealAs` freezes that selection
  /// for a drag, which is why this is a callback rather than [controller.selection].
  final TextSelection? Function() selection;

  /// 上一次扫描的文本与结果。滚动、光标闪烁会反复重画，而文本没变时围栏块的
  /// 位置一个字节都不会动——不必每帧把整篇源码再扫一遍。
  String? _rangesText;
  List<CodeBlockRange> _ranges = const <CodeBlockRange>[];

  /// 实际执行过全篇围栏扫描的次数，供测试确认滚动期不再扫描。
  @visibleForTesting
  static int debugRangeScans = 0;

  List<CodeBlockRange> _rangesOf(String text) {
    if (_rangesText == text) return _ranges;
    debugRangeScans++;
    _rangesText = text;
    _ranges = codeBlockRanges(text);
    return _ranges;
  }

  /// 语言标签的排版结果按标签文本缓存。只在可见块上画，通常 0~2 个。
  final Map<String, TextPainter> _labels = <String, TextPainter>{};

  @override
  void paint(Canvas canvas, Size size) {
    final RenderLineEditable? field = editable();
    final RenderBox? box = editorBox();
    if (field == null || box == null) return;

    final String text = controller.text;
    final List<CodeBlockRange> ranges = _rangesOf(text);
    if (ranges.isEmpty) return;

    final TextSelection? sel = selection();
    final bool hasSelection = sel != null && sel.isValid && sel.start >= 0;

    final Rect bounds = Offset.zero & size;
    final Paint paint = Paint()..color = fill;
    final double top = field.visibleDocumentTop;
    final double bottom = field.visibleDocumentBottom;
    final Set<String> usedLabels = <String>{};
    canvas.save();
    canvas.clipRect(bounds);
    for (final CodeBlockRange range in ranges) {
      // 卡片要的是「这个围栏块占了几行、从哪到哪」，行引擎直接给整行矩形；
      // 不再逐字形求包围盒——那需要把每一行的盒子逐一取回来再并起来。
      final Rect? rows = field.blockRectFor(range.start, range.end);
      if (rows == null) continue;
      // 视口外的块不用画；块矩形已按布局缓存，这一判据只省绘制与标签。
      if (rows.bottom < top - kCodeSlabBottomPad ||
          rows.top > bottom + kCodeSlabTopPad) {
        continue;
      }

      final Rect local = Rect.fromLTRB(
        0,
        rows.top - kCodeSlabTopPad,
        field.size.width,
        rows.bottom + kCodeSlabBottomPad,
      );
      final Rect slab = Rect.fromPoints(
        box.globalToLocal(field.localToGlobal(local.topLeft)),
        box.globalToLocal(field.localToGlobal(local.bottomRight)),
      );
      if (slab.isEmpty) continue;
      final RRect rounded = RRect.fromRectAndRadius(
        slab,
        const Radius.circular(kCodeSlabRadius),
      );
      canvas.drawRRect(rounded, paint);

      final String? label = range.label;
      if (label == null) continue;
      // When the block is open for editing the fence line shows its source and
      // the label has no meaning; the paragraph is already painting `dart`
      // there. Same rule the header used to follow.
      if (hasSelection &&
          sel.start <= range.end &&
          sel.end >= range.start) {
        continue;
      }
      usedLabels.add(label);
      final TextPainter tp = _labels.putIfAbsent(
        label,
        () => TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout(),
      );
      tp.paint(
        canvas,
        Offset(
          slab.right - kCodeSlabLabelRight - tp.width,
          slab.top + kCodeSlabLabelTop,
        ),
      );
    }
    canvas.restore();

    // 这一帧没用上的标签排版结果留着只会越积越多：丢掉并释放。
    if (_labels.length > usedLabels.length) {
      _labels.removeWhere((String key, TextPainter tp) {
        if (usedLabels.contains(key)) return false;
        tp.dispose();
        return true;
      });
    }
    }

  @override
  bool shouldRepaint(CodeBlockPainter oldDelegate) {
    // The canvas keeps its size while the text inside it reflows, and a font
    // size change moves every row without resizing anything — a rebuild is the
    // only notification that arrives. Repainting is cheap next to leaving the
    // slabs where they were before the last keystroke.
    return true;
  }
}
