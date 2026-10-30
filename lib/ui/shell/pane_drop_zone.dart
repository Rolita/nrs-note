import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import 'tab_drag.dart';

/// 一个格子的落点层：拖过来的 tab 落在哪块，就往哪块长。
///
/// 中间 = 换掉这一格的内容；四条边 = 在这一侧切出新的一格。判定只看指针
/// 离哪条边最近——离得最近的那条还在 28% 以内就算「那条边」，否则算中间。
///
/// ⛔ 拖拽的坐标必须用 `Draggable` 的 `pointerDragAnchorStrategy`：默认的
/// `childDragAnchorStrategy` 会让 `DragTargetDetails.offset` 变成「指针减去
/// 指针在 tab 内的位置」，落点整体偏一截，边就判不准了。
class PaneDropZone extends StatefulWidget {
  const PaneDropZone({
    super.key,
    required this.onDrop,
    required this.child,
    this.accepts,
    this.verticalOnly = false,
  });

  final void Function(DropZone zone, TabDrag tab) onDrop;
  final Widget child;

  /// 这一格收不收这件东西。不传 = 什么都收。
  ///
  /// 编辑区的格子只收文档、侧边栏的格子只收视图——两处共用这一个组件，
  /// 靠这个谓词分开。
  final bool Function(TabDrag tab)? accepts;

  /// 只认上下两条边。
  ///
  /// 侧边栏本来就只有 288 宽，左右各 28% 会把整格吃掉、也切不出能用的格子，
  /// 所以它只上下切。
  final bool verticalOnly;

  @override
  State<PaneDropZone> createState() => _PaneDropZoneState();
}

class _PaneDropZoneState extends State<PaneDropZone> {
  /// 边缘带占一格的比例。28% 是「够宽好瞄准、又不至于把中间挤没」的值：
  /// 一格 400×800 时四条边各 112 / 224，中间还剩 176×352。
  static const double _edgeBand = 0.28;

  final GlobalKey _boxKey = GlobalKey(debugLabel: 'nrs-drop-zone');
  DropZone? _zone;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return DragTarget<TabDrag>(
      onWillAcceptWithDetails: (DragTargetDetails<TabDrag> d) =>
          widget.accepts?.call(d.data) ?? true,
      onMove: _onMove,
      onLeave: (TabDrag? _) => _setZone(null),
      onAcceptWithDetails: (DragTargetDetails<TabDrag> d) {
        final DropZone zone = _zone ?? DropZone.center;
        _setZone(null);
        widget.onDrop(zone, d.data);
      },
      builder:
          (
            BuildContext context,
            List<TabDrag?> candidate,
            List<dynamic> rejected,
          ) {
            return Stack(
              key: _boxKey,
              fit: StackFit.expand,
              children: <Widget>[
                widget.child,
                if (_zone != null)
                  // 预览只是提示，不能挡住底下的画布 / 编辑器。
                  IgnorePointer(child: _preview(p, _zone!)),
              ],
            );
          },
    );
  }

  void _onMove(DragTargetDetails<TabDrag> details) {
    final RenderObject? box = _boxKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final Size size = box.size;
    if (size.isEmpty) return;
    _setZone(_zoneAt(box.globalToLocal(details.offset), size));
  }

  void _setZone(DropZone? zone) {
    if (_zone == zone) return;
    setState(() => _zone = zone);
  }

  /// 指针在一格里的哪个区域。
  DropZone _zoneAt(Offset local, Size size) {
    final double top = local.dy / size.height;
    final double bottom = 1 - top;
    if (widget.verticalOnly) {
      final double nearestY = top < bottom ? top : bottom;
      if (nearestY > _edgeBand) return DropZone.center;
      return nearestY == top ? DropZone.top : DropZone.bottom;
    }
    final double left = local.dx / size.width;
    final double right = 1 - left;
    final double nearest = <double>[
      left,
      right,
      top,
      bottom,
    ].reduce((double a, double b) => a < b ? a : b);
    if (nearest > _edgeBand) return DropZone.center;
    if (nearest == left) return DropZone.left;
    if (nearest == right) return DropZone.right;
    if (nearest == top) return DropZone.top;
    return DropZone.bottom;
  }

  /// 把「新格会出现的那半块」提前画出来。
  Widget _preview(AppPalette p, DropZone zone) {
    final bool horizontal = zone == DropZone.left || zone == DropZone.right;
    final bool vertical = zone == DropZone.top || zone == DropZone.bottom;
    final Alignment align = switch (zone) {
      DropZone.left => Alignment.centerLeft,
      DropZone.right => Alignment.centerRight,
      DropZone.top => Alignment.topCenter,
      DropZone.bottom => Alignment.bottomCenter,
      DropZone.center => Alignment.center,
    };
    return Align(
      alignment: align,
      child: FractionallySizedBox(
        widthFactor: vertical || zone == DropZone.center ? 1 : 0.5,
        heightFactor: horizontal || zone == DropZone.center ? 1 : 0.5,
        child: Container(
          decoration: BoxDecoration(
            color: p.accent.withValues(alpha: 0.10),
            border: Border.all(color: p.accent),
          ),
        ),
      ),
    );
  }
}
