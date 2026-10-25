import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/canvas_document.dart';
import '../../core/utils/canvas_geometry.dart';
import '../../core/utils/table_model.dart' show CellColor;
import 'canvas_style.dart';

/// 卡片的内边距（世界坐标，跟着缩放走）。
const double canvasCardPadding = 12;

/// 卡片的最小尺寸（世界坐标）。
const double canvasCardMinSide = 40;

/// 一张卡片。
///
/// 卡片是**真的 Widget**，不是画出来的：要能选中文字、要能放一个
/// `TextField` 进去编辑、要能长按出菜单。画在 `CustomPaint` 上的东西
/// 这些都做不到，除非自己重写一遍文本排版。
///
/// 代价是每张卡片一次布局。所以卡片只在视口内建（P5 做裁剪），而且
/// 字号乘 zoom 而不是整块 `Transform.scale`——后者会把文字糊成一片。
class CanvasCard extends StatelessWidget {
  const CanvasCard({
    super.key,
    required this.node,
    required this.zoom,
    required this.selected,
    this.editing = false,
    this.editor,
  });

  final CanvasNode node;

  /// 当前缩放。字号、圆角、内边距都乘它。
  final double zoom;

  final bool selected;

  /// 正在编辑：卡片里换成一个输入框。
  final bool editing;

  /// 编辑时用的输入框。由白板持有，因为光标和输入法状态要跨帧活着。
  final Widget? editor;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final CellColor? color = canvasCellColor(node.color);
    final double radius = (AppRadius.md * zoom).clamp(2.0, AppRadius.md);
    // 分组是底板：半透明的浅色块 + 一圈细边，没有阴影。它得看起来像
    // 「一块区域」，而不是「一张卡片」——否则用户会以为它和卡片同级。
    final bool isGroup = node is GroupNode;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: isGroup
            ? p.accentSoft.withValues(alpha: 0.22)
            : canvasCardFill(p, color),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: selected
              ? p.accent
              : (isGroup
                    ? p.accent.withValues(alpha: 0.35)
                    : canvasCardBorder(p, color)),
          width: selected ? 1.5 : 1,
        ),
        boxShadow: isGroup
            ? const <BoxShadow>[]
            : <BoxShadow>[
                BoxShadow(
                  color: p.shadow,
                  blurRadius: selected ? 20 : 12,
                  offset: Offset(0, 2 * zoom),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Padding(
          padding: EdgeInsets.all(canvasCardPadding * zoom),
          child: editing ? editor : _body(p, color),
        ),
      ),
    );
  }

  Widget _body(AppPalette p, CellColor? color) {
    final Color ink = canvasCardInk(p, color);
    return switch (node) {
      FileNode(:final String file) => _FileBody(
        label: file.split('/').last,
        detail: file,
        zoom: zoom,
        ink: ink,
        muted: p.textTertiary,
      ),
      LinkNode(:final String url) => _FileBody(
        label: url,
        detail: null,
        zoom: zoom,
        ink: ink,
        muted: p.textTertiary,
        icon: LucideIcons.link,
      ),
      GroupNode(:final String? label) => Align(
        alignment: Alignment.topLeft,
        child: Text(
          label ?? '分组',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _style(ink.withValues(alpha: 0.8), zoom),
        ),
      ),
      TextNode(:final String text) when text.isEmpty => Text(
        // 空卡片给一句占位，不然它看起来像画错了。
        '空卡片',
        style: _style(ink.withValues(alpha: 0.35), zoom),
      ),
      TextNode(:final String text) => Align(
        alignment: Alignment.topLeft,
        child: Text(text, style: _style(ink, zoom)),
      ),
    };
  }
}

TextStyle _style(Color color, double zoom) => TextStyle(
  fontSize: AppText.ui * zoom,
  height: 1.6,
  color: color,
  fontFamily: AppFonts.ui,
  fontFamilyFallback: AppFonts.uiFallback,
);

/// 文件卡片和链接卡片：一个图标 + 一行名字 + 一行小字。
class _FileBody extends StatelessWidget {
  const _FileBody({
    required this.label,
    required this.detail,
    required this.zoom,
    required this.ink,
    required this.muted,
    this.icon = LucideIcons.fileText,
  });

  final String label;
  final String? detail;
  final double zoom;
  final Color ink;
  final Color muted;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 14 * zoom, color: muted),
            SizedBox(width: 6 * zoom),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style(ink, zoom),
              ),
            ),
          ],
        ),
        if (detail != null)
          Padding(
            padding: EdgeInsets.only(top: 4 * zoom),
            child: Text(
              detail!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _style(muted, zoom).copyWith(fontSize: AppText.caption * zoom),
            ),
          ),
      ],
    );
  }
}

/// 八向手柄。
///
/// 手柄画在一层 `CustomPaint` 上而不是做成八个 Widget：它们只有 6px，
/// 做成 Widget 就要参与命中测试和布局，而命中测试我们已经自己做了——
/// 多一层只会让「拖手柄」和「拖卡片」抢手势。
class CanvasHandlesPainter extends CustomPainter {
  const CanvasHandlesPainter({
    required this.rect,
    required this.viewport,
    required this.fill,
    required this.ring,
  });

  /// 选中卡片的矩形（世界坐标）。null = 没有单选，不画。
  final Rect? rect;
  final CanvasViewport viewport;
  final Color fill;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect? world = rect;
    if (world == null) return;
    final Rect screen = viewport.rectToScreen(world);
    // 卡片小到看不见时手柄也没有意义，反而糊成一片。
    if (screen.width < 12 || screen.height < 12) return;

    final Paint dot = Paint()..color = fill;
    final Paint edge = Paint()
      ..color = ring
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final CanvasResizeHandle handle in CanvasResizeHandle.values) {
      final Offset at = handle.at(screen);
      canvas.drawCircle(at, 4, edge);
      canvas.drawCircle(at, 3, dot);
    }
  }

  @override
  bool shouldRepaint(CanvasHandlesPainter old) =>
      old.rect != rect ||
      old.viewport != viewport ||
      old.fill != fill ||
      old.ring != ring;
}
