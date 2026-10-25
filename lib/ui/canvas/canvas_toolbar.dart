import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../common/app_widgets.dart';

/// 白板右下角那颗浮动工具条：缩小 / 百分比 / 放大 / 适应窗口 / 新建卡片。
///
/// 和图谱的 HUD 是同一个形状、同一个位置，学一次就够。区别只有一处：
/// 百分比是可以点的，点了回到 100%——「我缩放乱了」比「我要精确设成某个
/// 比例」常见得多，所以不弹输入框。
class CanvasToolbar extends StatelessWidget {
  const CanvasToolbar({
    super.key,
    required this.zoom,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onResetZoom,
    required this.onFit,
    this.onCreateCard,
  });

  final double zoom;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;

  /// 点百分比：回到 100%。
  final VoidCallback onResetZoom;

  /// 适应窗口。
  final VoidCallback onFit;

  /// 新建卡片。null 表示这一阶段还没有卡片（P1），按钮就不出现。
  final VoidCallback? onCreateCard;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final VoidCallback? create = onCreateCard;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: p.sidebar.withValues(alpha: 0.82),
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: p.outline),
        boxShadow: <BoxShadow>[
          BoxShadow(color: p.shadow, blurRadius: 14, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _ToolButton(
            icon: LucideIcons.minus,
            tooltip: '缩小',
            onPressed: onZoomOut,
          ),
          _ZoomReadout(zoom: zoom, onPressed: onResetZoom),
          _ToolButton(
            icon: LucideIcons.plus,
            tooltip: '放大',
            onPressed: onZoomIn,
          ),
          Container(width: 1, height: 14, color: p.outline),
          _ToolButton(
            icon: LucideIcons.maximize,
            tooltip: '适应窗口',
            onPressed: onFit,
          ),
          if (create != null) ...<Widget>[
            Container(width: 1, height: 14, color: p.outline),
            _ToolButton(
              icon: LucideIcons.squarePlus,
              tooltip: '新建卡片',
              onPressed: create,
            ),
          ],
        ],
      ),
    );
  }
}

/// 百分比读数。定宽 + 等宽数字，缩放时数字不会左右跳。
class _ZoomReadout extends StatelessWidget {
  const _ZoomReadout({required this.zoom, required this.onPressed});

  final double zoom;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => Tooltip(
        message: '回到 100%',
        waitDuration: const Duration(milliseconds: 700),
        child: GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 42,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? p.surfaceRaised : Colors.transparent,
              borderRadius: AppRadius.smAll,
            ),
            child: Text(
              '${(zoom * 100).round()}%',
              style: TextStyle(
                fontSize: AppText.caption - 1,
                color: hovered ? p.textPrimary : p.textTertiary,
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 700),
        child: GestureDetector(
          onTap: onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: hovered ? p.surfaceRaised : Colors.transparent,
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(
              icon,
              size: AppIconSize.xs - 2,
              color: hovered ? p.textPrimary : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
