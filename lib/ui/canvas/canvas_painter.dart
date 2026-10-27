/// 白板的自绘画笔。
///
/// 整块画布只有**一个** `CustomPaint`：坐标网格、标尺、连线、卡片、文字、
/// 手柄、框选，全在这一支画笔里按顺序画出来。卡片不是 Widget——没有布局、
/// 没有命中测试的重叠，缩放和平移都只是一次 canvas 变换。
///
/// 三条容易写错的地方：
///
/// * **内容画在世界坐标里**：进入画笔先 `translate(画面中心) → scale(zoom)
///   → translate(-摄像机中心)`，然后所有几何直接用世界坐标。文字也在世界
///   坐标里排版，Skia 会按当前矩阵把字形栅格化到设备分辨率，所以放大不会糊。
/// * **装饰件画在屏幕坐标里**：手柄、连线圆点、框选框、边标签的字号，都是
///   「屏幕上永远这么多像素」，不该跟着缩放变大变小。
/// * **文字排版要缓存**：平移缩放时每帧重排几十段文字会把帧率吃掉。缓存按
///   节点 id 存，内容/宽度/颜色变了才重排（见 [CanvasTextCache]）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/table_colors.dart';
import '../../core/utils/canvas_document.dart';
import '../../core/utils/canvas_geometry.dart';
import '../../core/utils/table_model.dart' show CellColor;
import 'canvas_style.dart';

/// 卡片的内边距（世界坐标，跟着缩放走）。
const double canvasCardPadding = 12;

/// 卡片的最小尺寸（世界坐标）。
const double canvasCardMinSide = canvasMinSize;

/// 卡片圆角（世界坐标）。graphif 的卡片比「一块方角矩形」圆得多。
const double canvasCardRadius = 10;

/// 分组框的圆角。比卡片大一圈——分组是「一块区域」，不是一张卡。
const double canvasGroupRadius = 12;

/// 分组框的内边距。标题要离开边框一点，否则看着像压在线上。
const double canvasGroupPadding = 14;

/// 分组标题的字号（世界坐标）。graphif 的 Section 标题就是这么大。
const double canvasGroupLabelSize = AppText.title;

/// 「打开详细信息」那个小图标的边长（屏幕像素）。
const double canvasDetailsIconSize = 16;

/// 小图标的矩形（**屏幕坐标**）。
///
/// 骑在卡片右上角上，一半在外。往内挪会和右上角那个缩放手柄抢位置，
/// 整个挪到外面又容易被当成连线的圆点——骑在角上是唯一不打架的地方。
///
/// 画和命中测试都调它，两边不可能对不上。
Rect canvasDetailsIconRect(Rect nodeScreen) => Rect.fromCenter(
  center: nodeScreen.topRight,
  width: canvasDetailsIconSize,
  height: canvasDetailsIconSize,
);

/// 一条边画出来要的全部东西。
class CanvasEdgeVisual {
  const CanvasEdgeVisual({
    required this.edge,
    required this.geometry,
    required this.selected,
  });

  final CanvasEdge edge;

  /// **世界坐标**里的三次贝塞尔。
  final CanvasEdgeGeometry geometry;

  final bool selected;
}

/// 按当前文档算一批边的几何。绘制和命中测试都用这一份，免得出现两套公式。
List<CanvasEdgeVisual> buildEdgeVisuals({
  required CanvasDocument? document,
  required Set<String> selected,
}) {
  final CanvasDocument? doc = document;
  if (doc == null) return const <CanvasEdgeVisual>[];
  final List<CanvasEdgeVisual> out = <CanvasEdgeVisual>[];
  for (final CanvasEdge edge in doc.edges) {
    final CanvasNode? from = doc.nodeById(edge.fromNode);
    final CanvasNode? to = doc.nodeById(edge.toNode);
    if (from == null || to == null) continue;
    out.add(
      CanvasEdgeVisual(
        edge: edge,
        geometry: edgeGeometry(
          fromRect: from.rect,
          toRect: to.rect,
          fromSide: CanvasSide.parse(edge.fromSide),
          toSide: CanvasSide.parse(edge.toSide),
        ),
        selected: selected.contains(edge.id),
      ),
    );
  }
  return out;
}

/// 点在连线上的判定：贝塞尔近似成折线后的最近距离（世界坐标）。
CanvasEdgeVisual? edgeAtVisual(
  List<CanvasEdgeVisual> visuals,
  Offset world, {
  required double tolerance,
}) {
  CanvasEdgeVisual? best;
  double bestDistance = tolerance;
  for (final CanvasEdgeVisual visual in visuals) {
    final double d = visual.geometry.distanceTo(world);
    if (d <= bestDistance) {
      bestDistance = d;
      best = visual;
    }
  }
  return best;
}

/// 画布上那条从圆点拖出来的预览线（世界坐标）。
CanvasEdgeGeometry connectPreview({
  required Rect fromRect,
  required CanvasSide side,
  required Offset cursor,
}) => edgeGeometry(
  fromRect: fromRect,
  toRect: Rect.fromCenter(center: cursor, width: 1, height: 1),
  fromSide: side,
);

/// 文字排版缓存。
///
/// 每张卡片、每条边标签、每个图标最多一条。键是「节点 id + 用途」，
/// 内容、宽度、颜色、字号任一变化就重排；被删掉的节点在 [prune] 里释放。
class CanvasTextCache {
  final Map<String, _CachedText> _entries = <String, _CachedText>{};

  TextPainter get(
    String key, {
    required String text,
    required TextStyle style,
    required double width,
    TextAlign align = TextAlign.left,
    int? maxLines,
  }) {
    final _CachedText? old = _entries[key];
    if (old != null &&
        old.text == text &&
        old.style == style &&
        old.width == width &&
        old.align == align &&
        old.maxLines == maxLines) {
      return old.painter;
    }
    old?.painter.dispose();
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    )..layout(maxWidth: width);
    _entries[key] = _CachedText(
      text: text,
      style: style,
      width: width,
      align: align,
      maxLines: maxLines,
      painter: painter,
    );
    return painter;
  }

  /// 释放所有不在 [alive] 里的排版结果。
  void prune(Iterable<String> alive) {
    final Set<String> keep = alive.toSet();
    final List<String> drop = <String>[
      for (final String key in _entries.keys)
        if (!keep.contains(key)) key,
    ];
    for (final String key in drop) {
      _entries.remove(key)?.painter.dispose();
    }
  }

  void dispose() {
    for (final _CachedText entry in _entries.values) {
      entry.painter.dispose();
    }
    _entries.clear();
  }
}

class _CachedText {
  const _CachedText({
    required this.text,
    required this.style,
    required this.width,
    required this.align,
    required this.maxLines,
    required this.painter,
  });

  final String text;
  final TextStyle style;
  final double width;
  final TextAlign align;
  final int? maxLines;
  final TextPainter painter;
}

/// 相机震动/动画状态之外，画笔需要知道的一切。
class CanvasScenePainter extends CustomPainter {
  CanvasScenePainter({
    required this.document,
    required this.camera,
    required this.style,
    required this.palette,
    required this.selected,
    required this.editingId,
    required this.hoverNodeId,
    required this.connectFromId,
    required this.connectSide,
    required this.connectCursor,
    required this.marquee,
    required this.textCache,
    required this.canEdit,
    required this.emptyHint,
  });

  final CanvasDocument? document;
  final CanvasCamera camera;
  final CanvasStyle style;
  final AppPalette palette;
  final Set<String> selected;
  final String? editingId;
  final String? hoverNodeId;
  final String? connectFromId;
  final CanvasSide? connectSide;

  /// 连线预览的光标位置（**屏幕**坐标）。
  final Offset? connectCursor;

  /// 框选框（**世界**坐标）。null = 没在框选。
  final Rect? marquee;

  final CanvasTextCache textCache;

  /// 能不能编辑（只读空板时为 false）。
  final bool canEdit;

  /// 空板提示的两行文字。
  final (String, String)? emptyHint;

  /// 线宽 / 箭头 / 标签这些「装饰」的屏幕尺寸，换算成世界单位要除以 zoom。
  double get _px => 1 / camera.zoom;

  // ------------------------------------------------------- 网格与坐标标尺

  /// 坐标网格。**屏幕坐标**里算：世界坐标铺满再整体变换，缩到 8% 时
  /// 要画上百万条线，而屏幕只有一两千像素。
  ///
  /// 只有两层：主格（标尺上写数字的那层）和原点十字。**主格里面不再分
  /// 小格子**——一格就是标尺上相邻两个数字之间的距离。
  void _paintGrid(Canvas canvas, Size size) {
    final double zoom = camera.zoom;
    final double major = canvasGridMajorStep(zoom);
    // 阶梯走完了还不够 8px 一格，说明已经缩到「格子比点还密」的地方，
    // 再画就是一片实心灰。
    if (major * zoom < 8) return;
    final Offset origin = camera.toScreen(Offset.zero, size);

    _strokeLines(
      canvas,
      size,
      canvasGridLineOffsets(origin.dx, major * zoom, size.width),
      canvasGridLineOffsets(origin.dy, major * zoom, size.height),
      style.gridMajor,
    );

    // 世界原点的十字：平移时它是一根能抓住的参照线。
    final Paint axis = Paint()
      ..color = style.axis
      ..strokeWidth = 1;
    if (origin.dx >= 0 && origin.dx <= size.width) {
      canvas.drawLine(
        Offset(origin.dx, 0),
        Offset(origin.dx, size.height),
        axis,
      );
    }
    if (origin.dy >= 0 && origin.dy <= size.height) {
      canvas.drawLine(
        Offset(0, origin.dy),
        Offset(size.width, origin.dy),
        axis,
      );
    }
  }

  /// 把一批竖线 / 横线合并成一条 path 一次画完。
  ///
  /// 线宽 1px 落在整数坐标上会被抗锯齿摊成两像素的灰边，所以统一压到
  /// 半像素上——坐标纸的线要「利」，糊一点整块画布就脏了。
  void _strokeLines(
    Canvas canvas,
    Size size,
    List<double> xs,
    List<double> ys,
    Color color,
  ) {
    if (xs.isEmpty && ys.isEmpty) return;
    final Path path = Path();
    for (final double x in xs) {
      final double px = x.floorToDouble() + 0.5;
      path
        ..moveTo(px, 0)
        ..lineTo(px, size.height);
    }
    for (final double y in ys) {
      final double py = y.floorToDouble() + 0.5;
      path
        ..moveTo(0, py)
        ..lineTo(size.width, py);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  /// 上边与左边的两条坐标标尺。
  ///
  /// 底色就是画布色（不透明），内容滚到带子下面会被截断——像一张尺子压在
  /// 纸上，而不是浮在纸上的水印。数字按主格的整数倍算，不经过屏幕换算，
  /// 所以永远是 100 / 200 / 500 这种干净的刻度。
  void _paintRulers(Canvas canvas, Size size) {
    const double top = canvasRulerThickness;
    const double side = canvasRulerSideWidth;
    if (size.width <= side || size.height <= top) return;

    final Paint band = Paint()..color = style.rulerBackground;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, top), band);
    canvas.drawRect(Rect.fromLTWH(0, 0, side, size.height), band);

    final Paint edge = Paint()
      ..color = style.rulerEdge
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, top + 0.5), Offset(size.width, top + 0.5), edge);
    canvas.drawLine(
      Offset(side + 0.5, 0),
      Offset(side + 0.5, size.height),
      edge,
    );

    final double major = canvasGridMajorStep(camera.zoom);
    final double stepPx = major * camera.zoom;
    // 刻度挤到 32px 以内，数字就会互相压在一起，索性一条都不写。
    if (stepPx < 32) return;
    final Offset origin = camera.toScreen(Offset.zero, size);
    final Paint tick = Paint()
      ..color = style.rulerTick
      ..strokeWidth = 1;

    // 上边：竖刻度 + 世界 x，数字压在线中间。
    int k = ((-origin.dx) / stepPx).floor();
    while (true) {
      final double x = origin.dx + k * stepPx;
      if (x > size.width) break;
      final String label = canvasRulerLabel(k * major);
      k++;
      if (x < side) continue;
      canvas.drawLine(Offset(x, top - 4), Offset(x, top), tick);
      _paintRulerText(canvas, label, Offset(x, top / 2));
    }

    // 左边：横刻度 + 世界 y，数字靠右对齐，长负数也不会跑出带子。
    int j = ((-origin.dy) / stepPx).floor();
    while (true) {
      final double y = origin.dy + j * stepPx;
      if (y > size.height) break;
      final String label = canvasRulerLabel(j * major);
      j++;
      if (y < top) continue;
      canvas.drawLine(Offset(side - 4, y), Offset(side, y), tick);
      _paintRulerText(
        canvas,
        label,
        Offset(side / 2, y),
        rightAlignAt: side - 5,
      );
    }
  }

  /// 一个刻度数字。[at] 是它的中心；给了 [rightAlignAt] 就改成右对齐。
  void _paintRulerText(
    Canvas canvas,
    String text,
    Offset at, {
    double? rightAlignAt,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 10,
          height: 1,
          color: style.rulerText,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double left = rightAlignAt == null
        ? at.dx - painter.width / 2
        : rightAlignAt - painter.width;
    painter.paint(canvas, Offset(left, at.dy - painter.height / 2));
    painter.dispose();
  }

  // ------------------------------------------------------------------ 连线

  void _paintEdges(Canvas canvas) {
    for (final CanvasEdgeVisual visual in buildEdgeVisuals(
      document: document,
      selected: selected,
    )) {
      _paintEdge(canvas, visual);
    }
    final Offset? cursorScreen = connectCursor;
    final String? fromId = connectFromId;
    if (cursorScreen != null && fromId != null) {
      final CanvasNode? node = document?.nodeById(fromId);
      if (node != null) {
        final CanvasEdgeGeometry ghost = connectPreview(
          fromRect: node.rect,
          side: connectSide ?? CanvasSide.right,
          cursor: _toWorld(cursorScreen, _lastSize ?? Size.zero),
        );
        _paintCurve(
          canvas,
          ghost,
          Paint()
            ..color = style.accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * _px
            ..strokeCap = StrokeCap.round,
          arrow: true,
        );
      }
    }
  }

  /// 画笔在 [paint] 里拿到的尺寸，预览线要用它把屏幕光标换回世界坐标。
  Size? _lastSize;

  Offset _toWorld(Offset screen, Size size) => camera.toWorld(screen, size);

  void _paintEdge(Canvas canvas, CanvasEdgeVisual visual) {
    final CanvasEdge edge = visual.edge;
    final CellColor? color = canvasCellColor(edge.color);
    final Color line = color == null
        ? style.edge
        : tableInkColor(palette, color);
    final Color stroke = visual.selected ? style.edgeSelected : line;

    _paintCurve(
      canvas,
      visual.geometry,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = (visual.selected ? 2 : 1.2) * _px
        ..strokeCap = StrokeCap.round,
      arrow: edge.toIsArrow,
      arrowAtStart: edge.fromIsArrow,
    );

    if (visual.selected) {
      final Paint dot = Paint()..color = style.edgeSelected;
      canvas.drawCircle(visual.geometry.from, 3.5 * _px, dot);
      canvas.drawCircle(visual.geometry.to, 3.5 * _px, dot);
    }

    final String? label = edge.label;
    if (label == null || label.trim().isEmpty) return;
    _paintEdgeLabel(canvas, visual.geometry, label.trim(), stroke);
  }

  void _paintCurve(
    Canvas canvas,
    CanvasEdgeGeometry g,
    Paint paint, {
    required bool arrow,
    bool arrowAtStart = false,
  }) {
    final Path path = Path()
      ..moveTo(g.from.dx, g.from.dy)
      ..cubicTo(
        g.fromControl.dx,
        g.fromControl.dy,
        g.toControl.dx,
        g.toControl.dy,
        g.to.dx,
        g.to.dy,
      );
    canvas.drawPath(path, paint);

    final Paint fill = Paint()..color = paint.color;
    final double length = 8 * _px;
    if (arrow) _arrow(canvas, g.to, g.tangentAt(1), fill, length);
    if (arrowAtStart) {
      _arrow(canvas, g.from, -g.tangentAt(0), fill, length);
    }
  }

  /// 箭头：一个沿切线方向的三角。屏幕上固定 8px，缩放时不变。
  void _arrow(
    Canvas canvas,
    Offset tip,
    Offset direction,
    Paint paint,
    double length,
  ) {
    final double angle = math.atan2(direction.dy, direction.dx);
    const double spread = 0.36;
    final Path path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(
        tip.dx - length * math.cos(angle - spread),
        tip.dy - length * math.sin(angle - spread),
      )
      ..lineTo(
        tip.dx - length * math.cos(angle + spread),
        tip.dy - length * math.sin(angle + spread),
      )
      ..close();
    canvas.drawPath(path, paint);
  }

  /// 标签压在线的中点上，背后描一圈画布色。
  ///
  /// 字号固定在屏幕上是 11.5px，所以世界单位里是 `11.5 / zoom`。
  void _paintEdgeLabel(
    Canvas canvas,
    CanvasEdgeGeometry g,
    String text,
    Color color,
  ) {
    final double fontSize = 11.5 * _px;
    final TextPainter halo = textCache.get(
      'edge-label-halo-$text-$fontSize',
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * _px
          ..color = style.labelHalo,
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
      width: 220 * _px,
      maxLines: 1,
    );
    final TextPainter fill = textCache.get(
      'edge-label-$text-$fontSize',
      text: text,
      style: TextStyle(
        fontSize: fontSize,
        color: color,
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
      width: 220 * _px,
      maxLines: 1,
    );

    final Offset center = g.pointAt(0.5);
    final Offset origin = Offset(
      center.dx - fill.width / 2,
      center.dy - fill.height / 2,
    );
    halo.paint(canvas, origin);
    fill.paint(canvas, origin);
  }

  // ------------------------------------------------------------------ 卡片

  void _paintNodes(Canvas canvas) {
    final CanvasDocument? doc = document;
    if (doc == null) return;

    // 分组是底板：先画所有分组，再画卡片。分组之间按面积从大到小，
    // 嵌套时外框先画、内框后画，不会出现内框把外框切一半。
    final List<GroupNode> groups =
        <GroupNode>[
          for (final CanvasNode node in doc.nodes)
            if (node is GroupNode) node,
        ]..sort((GroupNode a, GroupNode b) {
          final double areaA = a.rect.width * a.rect.height;
          final double areaB = b.rect.width * b.rect.height;
          return areaB.compareTo(areaA);
        });
    for (final GroupNode group in groups) {
      _paintNode(canvas, group);
    }
    for (final CanvasNode node in doc.nodes) {
      if (node is GroupNode) continue;
      _paintNode(canvas, node);
    }
  }

  void _paintNode(Canvas canvas, CanvasNode node) {
    final Rect rect = node.rect;
    final bool isGroup = node is GroupNode;
    final bool isSelected = selected.contains(node.id);
    final double radius = math.min(
      isGroup ? canvasGroupRadius : canvasCardRadius,
      rect.shortestSide / 2,
    );
    final RRect rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final CellColor? color = canvasCellColor(node.color);

    // 卡片：一层很薄的半透明面 + 一根描边，没有投影。graphif 的卡片就是
    // 这样「浮」起来的——靠边线交代轮廓，不靠阴影。
    // 分组反过来：**不填底**，只画一个框，框里的画布纹理照样看得见。
    if (!isGroup) {
      canvas.drawRRect(rrect, Paint()..color = style.cardFill);
    }

    // 选中：卡片**外面**再套一圈粗描边。
    //
    // 不是把原来那根边框加粗——加粗会往里吃，卡片看起来像被换了张。套在
    // 外面则原卡一丝不动，多出来的那一圈就是「选中」的全部信息。
    //
    // 正在编辑时换成**虚线**：那圈实线说的是「选中」，虚线说的是「这张卡
    // 现在在吃键盘」——两者要分开，否则输入光标和选中框会互相冒充。
    if (isSelected) {
      final double gap = 3 * _px;
      final Rect ring = rect.inflate(gap);
      final double radius =
          (isGroup ? canvasGroupRadius : canvasCardRadius) + gap;
      if (node.id == editingId) {
        _paintDashedRing(canvas, ring, radius);
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(ring, Radius.circular(radius)),
          Paint()
            ..color = palette.accent.withValues(alpha: 0.85)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3 * _px,
        );
      }
    }

    final Color border = isSelected
        ? palette.accent
        : (isGroup ? style.groupOutline : canvasCardBorder(palette, color));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = (isSelected ? 1.5 : 1) * _px,
    );

    // 卡片内容裁剪在圆角内，长文本不会溢到卡片外面。
    canvas.save();
    canvas.clipRRect(rrect);
    // 内边距也跟着字号倍率走：字放大一倍、内边距还是 12，卡片就会显得很挤。
    final double pad =
        (isGroup ? canvasGroupPadding : canvasCardPadding) * node.scale;
    final Rect content = Rect.fromLTRB(
      rect.left + pad,
      rect.top + pad,
      rect.right - pad,
      rect.bottom - pad,
    );
    if (content.width > 0 && content.height > 0) {
      switch (node) {
        case TextNode(:final String text):
          // 正在编辑的卡片不画正文：上面那层输入框会自己画。
          //
          // 但**空卡片例外**：它的「•••」由画笔负责，编辑态也照画。让输入框
          // 用 hint 再画一份占位，两边迟早对不上（字号、位置、字距各写一套），
          // 而且用户看到的是「输入文字」这种说明书，不是节点自己的样子。
          if (text.isEmpty || node.id != editingId) {
            _paintTextNode(canvas, node, content, color, text);
          }
        case FileNode(:final String file):
          _paintReferenceNode(
            canvas,
            node,
            content,
            color,
            icon: LucideIcons.fileText,
            title: file.split('/').last,
            detail: file,
          );
        case LinkNode(:final String url):
          _paintReferenceNode(
            canvas,
            node,
            content,
            color,
            icon: LucideIcons.link,
            title: url,
            detail: null,
          );
        case GroupNode(:final String? label):
          if (node.id != editingId) {
            _paintGroupLabel(canvas, node, content, label);
          }
      }
    }
    canvas.restore();
  }

  /// 一圈虚线（世界坐标）。编辑态用它代替那圈实线。
  ///
  /// 圆角用四段直线近似：虚线的目的只是「看起来是虚线」，为圆角去拆
  /// `PathMetric` 不值得——半径才 10px，切角看不出来。
  void _paintDashedRing(Canvas canvas, Rect rect, double radius) {
    final Paint paint = Paint()
      ..color = palette.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * _px;
    const double dash = 6;
    const double gap = 4;
    final double step = (dash + gap) * _px;

    void run(Offset a, Offset b) {
      final double length = (b - a).distance;
      if (length <= 0) return;
      final Offset unit = (b - a) / length;
      for (double t = 0; t < length; t += step) {
        canvas.drawLine(
          a + unit * t,
          a + unit * math.min(t + dash * _px, length),
          paint,
        );
      }
    }

    // 四边各让出圆角半径，短边（卡片比圆角还小时）按一半算。
    final double r = math.min(radius, rect.shortestSide / 2);
    run(Offset(rect.left + r, rect.top), Offset(rect.right - r, rect.top));
    run(Offset(rect.right, rect.top + r), Offset(rect.right, rect.bottom - r));
    run(
      Offset(rect.right - r, rect.bottom),
      Offset(rect.left + r, rect.bottom),
    );
    run(Offset(rect.left, rect.bottom - r), Offset(rect.left, rect.top + r));
  }

  void _paintTextNode(
    Canvas canvas,
    TextNode node,
    Rect content,
    CellColor? color,
    String text,
  ) {
    if (text.isEmpty) {
      _paintEmptyDots(canvas, node, content);
      return;
    }
    final TextPainter painter = textCache.get(
      'node-${node.id}',
      text: text,
      style: TextStyle(
        fontSize: AppText.ui * node.scale,
        height: 1.6,
        color: canvasCardInk(palette, color),
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
      width: content.width,
    );
    painter.paint(canvas, content.topLeft);
  }

  /// 空卡片：正中三个点。
  ///
  /// 不写「空卡片」这种说明书——卡片是内容，不是控件；三个点只是说「这里
  /// 还什么都没有」，和 graphif 空节点的样子一致。
  ///
  /// 点和 [canvasEmptyDotsStyle] 是**共享**的：卡片的宽度就是按这串点量
  /// 出来的，画笔换个字号就会和量出来的宽度对不上。
  void _paintEmptyDots(Canvas canvas, TextNode node, Rect content) {
    final TextPainter painter = textCache.get(
      'node-empty-${node.id}',
      text: canvasEmptyDots,
      style: canvasEmptyDotsStyle(
        color: palette.textTertiary,
        scale: node.scale,
      ),
      width: content.width,
      maxLines: 1,
    );
    painter.paint(
      canvas,
      Offset(
        content.left + (content.width - painter.width) / 2,
        content.top + (content.height - painter.height) / 2,
      ),
    );
  }

  void _paintReferenceNode(
    Canvas canvas,
    CanvasNode node,
    Rect content,
    CellColor? color, {
    required IconData icon,
    required String title,
    required String? detail,
  }) {
    final Color ink = canvasCardInk(palette, color);
    final Color muted = palette.textTertiary;
    const double iconSize = 14;

    final TextPainter iconPainter = textCache.get(
      'icon-${node.id}',
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: iconSize,
        color: muted,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
      width: iconSize * 2,
      maxLines: 1,
    );
    iconPainter.paint(
      canvas,
      Offset(content.left, content.top + (AppText.ui * 1.6 - iconSize) / 2),
    );

    final double textLeft = content.left + iconSize + 6;
    final double textWidth = math.max(0, content.right - textLeft);
    if (textWidth <= 0) return;

    final TextPainter titlePainter = textCache.get(
      'title-${node.id}',
      text: title.isEmpty ? '（未命名）' : title,
      style: TextStyle(
        fontSize: AppText.ui,
        height: 1.6,
        color: ink,
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
      width: textWidth,
      maxLines: 1,
    );
    titlePainter.paint(canvas, Offset(textLeft, content.top));

    final String? sub = detail;
    if (sub == null || sub.isEmpty) return;
    final TextPainter detailPainter = textCache.get(
      'detail-${node.id}',
      text: sub,
      style: TextStyle(
        fontSize: AppText.caption,
        height: 1.5,
        color: muted,
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
      width: textWidth,
      maxLines: 2,
    );
    final double top = content.top + titlePainter.height + 4;
    if (top < content.bottom) {
      detailPainter.paint(canvas, Offset(textLeft, top));
    }
  }

  void _paintGroupLabel(
    Canvas canvas,
    GroupNode node,
    Rect content,
    String? label,
  ) {
    final TextPainter painter = textCache.get(
      'group-label-${node.id}',
      text: label ?? '分组',
      style: TextStyle(
        fontSize: canvasGroupLabelSize * node.scale,
        height: 1.4,
        color: canvasGroupInk(palette),
        fontFamily: AppFonts.ui,
        fontFamilyFallback: AppFonts.uiFallback,
      ),
      width: content.width,
      maxLines: 1,
    );
    painter.paint(canvas, content.topLeft);
  }

  // -------------------------------------------------------------- 装饰件

  /// 悬停卡片四边中点的圆点（屏幕坐标）。
  void _paintConnectDots(Canvas canvas, Size size) {
    if (!canEdit) return;
    final String? id = connectFromId ?? hoverNodeId;
    if (id == null) return;
    final CanvasNode? node = document?.nodeById(id);
    if (node == null) return;
    final Rect screen = camera.rectToScreen(node.rect, size);
    if (screen.width < 20 || screen.height < 20) return;

    final Paint ring = Paint()
      ..color = palette.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final Paint dot = Paint()..color = palette.accent;
    for (final CanvasSide side in CanvasSide.values) {
      final Offset at = anchorOf(screen, side);
      canvas.drawCircle(at, 5, ring);
      canvas.drawCircle(at, 3.5, dot);
    }
  }

  /// 单选时的八个缩放手柄（屏幕坐标）。
  void _paintHandles(Canvas canvas, Size size) {
    if (selected.length != 1 || editingId != null) return;
    final CanvasNode? node = document?.nodeById(selected.first);
    if (node == null) return;
    final Rect screen = camera.rectToScreen(node.rect, size);
    if (screen.width < 12 || screen.height < 12) return;

    final Paint ring = Paint()
      ..color = palette.surface
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final Paint dot = Paint()..color = palette.accent;
    for (final CanvasResizeHandle handle in CanvasResizeHandle.values) {
      final Offset at = handle.at(screen);
      canvas.drawCircle(at, 4, ring);
      canvas.drawCircle(at, 3, dot);
    }
  }

  /// 选中卡片右上角那颗「打开详细信息」的小图标（屏幕坐标）。
  ///
  /// 只在单选时出现：多选的时候「详细信息」不知道要显示谁。
  void _paintDetailsIcon(Canvas canvas, Size size) {
    if (!canEdit || editingId != null || selected.length != 1) return;
    final CanvasNode? node = document?.nodeById(selected.first);
    if (node == null) return;
    final Rect screen = camera.rectToScreen(node.rect, size);
    // 卡片在屏幕上比图标还小的时候，图标会盖满整张卡，反而点不到卡片。
    if (screen.width < 24 || screen.height < 24) return;

    final Rect box = canvasDetailsIconRect(screen);
    final RRect rrect = RRect.fromRectAndRadius(box, const Radius.circular(4));
    canvas.drawRRect(rrect, Paint()..color = palette.surfaceRaised);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = palette.outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    final IconData glyph = LucideIcons.slidersHorizontal;
    final TextPainter icon = textCache.get(
      'details-icon-${node.id}',
      text: String.fromCharCode(glyph.codePoint),
      style: TextStyle(
        fontSize: 9,
        height: 1,
        color: palette.textSecondary,
        fontFamily: glyph.fontFamily,
        package: glyph.fontPackage,
      ),
      width: canvasDetailsIconSize,
      maxLines: 1,
    );
    icon.paint(canvas, box.center - Offset(icon.width / 2, icon.height / 2));
  }

  /// 框选框：虚线 + 一层很淡的填充（屏幕坐标）。
  void _paintMarquee(Canvas canvas) {
    final Rect? world = marquee;
    if (world == null) return;
    final Size? size = _lastSize;
    if (size == null) return;
    final Rect r = camera.rectToScreen(world, size);
    if (r.width < 1 || r.height < 1) return;

    canvas.drawRect(r, Paint()..color = style.selectionFill);
    final Paint stroke = Paint()
      ..color = style.selectionOutline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const double dash = 4;
    const double gap = 3;
    for (final (Offset a, Offset b) in <(Offset, Offset)>[
      (r.topLeft, r.topRight),
      (r.topRight, r.bottomRight),
      (r.bottomRight, r.bottomLeft),
      (r.bottomLeft, r.topLeft),
    ]) {
      final double length = (b - a).distance;
      if (length <= 0) continue;
      final Offset unit = (b - a) / length;
      for (double t = 0; t < length; t += dash + gap) {
        final double end = (t + dash).clamp(0, length);
        canvas.drawLine(a + unit * t, a + unit * end, stroke);
      }
    }
  }

  /// 空板提示。居中、只读、不挡指针。
  void _paintEmptyHint(Canvas canvas, Size size) {
    final (String, String)? hint = emptyHint;
    if (hint == null) return;
    final TextPainter title = TextPainter(
      text: TextSpan(
        text: hint.$1,
        style: TextStyle(
          fontSize: AppText.ui,
          color: style.emptyHint,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final TextPainter sub = TextPainter(
      text: TextSpan(
        text: hint.$2,
        style: TextStyle(
          fontSize: AppText.caption,
          color: style.emptyHint.withValues(alpha: style.emptyHint.a * 0.75),
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final double gap = 8;
    final double total = title.height + gap + sub.height;
    final double top = size.height / 2 - total / 2;
    title.paint(canvas, Offset((size.width - title.width) / 2, top));
    sub.paint(
      canvas,
      Offset((size.width - sub.width) / 2, top + title.height + gap),
    );
    title.dispose();
    sub.dispose();
  }

  // ------------------------------------------------------------ 生命周期

  @override
  void paint(Canvas canvas, Size size) {
    _lastSize = size;
    _paintScene(canvas, size);
  }

  void _paintScene(Canvas canvas, Size size) {
    // 缩到这么小，整块板子加起来不到一个像素，画什么都是白费——
    // 而且 `1 / zoom` 已经大得离谱，线宽会把绘制拖垮。
    if (camera.zoom < 1e-5) return;

    _paintGrid(canvas, size);

    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(camera.zoom);
    canvas.translate(-camera.center.dx, -camera.center.dy);

    _paintEdges(canvas);
    _paintNodes(canvas);

    canvas.restore();

    // 标尺压在内容上：内容滚到带子下面就被截断，不会跟刻度数字糊在一起。
    _paintRulers(canvas, size);

    _paintConnectDots(canvas, size);
    _paintHandles(canvas, size);
    _paintDetailsIcon(canvas, size);
    _paintMarquee(canvas);
    _paintEmptyHint(canvas, size);
  }

  @override
  bool shouldRepaint(CanvasScenePainter old) => true;
}
