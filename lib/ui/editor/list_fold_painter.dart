import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'line_layout/render_line_editable.dart';

/// 列表项的折叠箭头。
///
/// 箭头画在字段外面：顶级列表项的按钮落在页边距里，而输入框的绘制被裁在
/// 正文列内，所以只能由编辑器这层叠一层画布。几何问渲染对象要（[handles]），
/// 它给出的矩形就是命中和悬停用的同一份。
///
/// 收起的项箭头常驻，展开的项只在指针悬停到这一行时露出——和 Typora /
/// Obsidian 一样，列表读起来是文字，不是一棵挂满控件的树。
class ListFoldPainter extends CustomPainter {
  ListFoldPainter({
    required this.controller,
    required this.scrollController,
    required this.editorBox,
    required this.handles,
    required this.hoveredLine,
    required this.hoveredButton,
    required this.iconColor,
    required this.hoverIconColor,
    required this.hoverFill,
    required this.ellipsisStyle,
    required this.textScaler,
  }) : super(
         repaint: Listenable.merge(<Listenable>[controller, scrollController]),
       );

  final TextEditingController controller;
  final ScrollController scrollController;

  /// 这个画布的宿主盒子；箭头矩形是全局坐标，要换算到画布局部。
  final RenderBox? Function() editorBox;

  /// 每一轮绘制现取：滚动、折叠和文本变化都会让上一帧的矩形过期。
  final List<ListFoldHandle> Function() handles;

  /// 指针所在的可折叠行（行首偏移）；展开的箭头只在这一行显形。
  final int? hoveredLine;

  /// 指针正压在按钮上的行；只有它画悬停底色。
  final int? hoveredButton;

  final Color iconColor;
  final Color hoverIconColor;
  final Color hoverFill;

  /// 收起项末尾省略号的字体。与正文同一套度量，才落在同一条基线上。
  final TextStyle ellipsisStyle;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final RenderBox? box = editorBox();
    if (box == null) return;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final Paint fill = Paint()..color = hoverFill;
    TextPainter? ellipsis;

    try {
      for (final ListFoldHandle handle in handles()) {
        final bool hovered = hoveredLine == handle.lineStart;
        if (!handle.folded && !hovered) continue;

        final Rect local = Rect.fromPoints(
          box.globalToLocal(handle.button.topLeft),
          box.globalToLocal(handle.button.bottomRight),
        );
        if (hoveredButton == handle.lineStart) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(local.deflate(1), const Radius.circular(4)),
            fill,
          );
        }

        stroke.color = hoveredButton == handle.lineStart
            ? hoverIconColor
            : iconColor;
        canvas.save();
        canvas.translate(local.center.dx, local.center.dy);
        // 展开是向下的 V，收起时转成指向右的 >。
        if (handle.folded) canvas.rotate(-math.pi / 2);
        canvas.drawPath(
          Path()
            ..moveTo(-3.5, -2.2)
            ..lineTo(0, 1.4)
            ..lineTo(3.5, -2.2),
          stroke,
        );
        canvas.restore();

        final Offset? at = handle.ellipsis;
        if (at != null) {
          ellipsis ??= TextPainter(
            text: TextSpan(text: '...', style: ellipsisStyle),
            textDirection: TextDirection.ltr,
            textScaler: textScaler,
          )..layout();
          ellipsis.paint(canvas, box.globalToLocal(at));
        }
      }
    } finally {
      ellipsis?.dispose();
    }
  }

  @override
  bool shouldRepaint(ListFoldPainter oldDelegate) {
    // 画布尺寸不变，但滚动、折叠与悬停都会移动箭头；悬停状态本身靠重建
    // 换入新的 painter，直接重画比逐项比对便宜。
    return true;
  }
}
