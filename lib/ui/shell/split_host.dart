import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'split_tree.dart';

/// 把一棵 [SplitNode] 画成可拖的分栏。
///
/// 编辑区和侧边栏共用这一个组件，唯一的区别是 [leafBuilder] 画什么——
/// 分割、拖线、双击均分全部在这里，不在各自的页面里各写一遍。
class SplitHost<T> extends StatelessWidget {
  const SplitHost({
    super.key,
    required this.root,
    required this.leafBuilder,
    required this.onRatioChanged,
    this.dividerThickness = 5,
  });

  final SplitNode<T> root;

  /// 画一个格子。
  final Widget Function(BuildContext context, SplitLeaf<T> leaf) leafBuilder;

  /// 拖动或双击分割线后回调。父级换一棵新树，不要就地改。
  final void Function(SplitBranch<T> branch, double ratio) onRatioChanged;

  final double dividerThickness;

  @override
  Widget build(BuildContext context) {
    return _node(context, root);
  }

  Widget _node(BuildContext context, SplitNode<T> node) {
    // ⛔ 每一格都要裁剪在自己的矩形里。
    //
    // 白板和图谱是自绘的（`CustomPaint` + 世界坐标），画布从 `dart:ui` 拿到的
    // `size` 只是它自己的盒子，**画到盒子外面不会被自动截断**——`Flex` /
    // `Expanded` 都不裁剪。以前它们独占整块编辑区，画出去也没人看得见；装进
    // 半格之后，越界的网格和卡片就盖到隔壁格上（而隔壁格是先画的），甚至
    // 一路盖到侧边栏。这一层 `ClipRect` 是它们唯一的边界，别删。
    if (node is SplitLeaf<T>) {
      return ClipRect(child: leafBuilder(context, node));
    }
    final SplitBranch<T> branch = node as SplitBranch<T>;
    final bool horizontal = branch.axis == Axis.horizontal;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double total = horizontal ? c.maxWidth : c.maxHeight;
        // flex 只认整数：比例乘一个大数再取整，精度够用（1/1000）。
        final int firstFlex = (branch.ratio * 1000).round().clamp(1, 999);
        final int secondFlex = ((1 - branch.ratio) * 1000).round().clamp(
          1,
          999,
        );

        final Widget divider = _SplitDivider(
          axis: branch.axis,
          total: total <= 0 ? 1 : total,
          ratio: branch.ratio,
          thickness: dividerThickness,
          onChanged: (double ratio) => onRatioChanged(branch, ratio),
        );

        return Flex(
          direction: branch.axis,
          children: <Widget>[
            Expanded(flex: firstFlex, child: _node(context, branch.first)),
            divider,
            Expanded(flex: secondFlex, child: _node(context, branch.second)),
          ],
        );
      },
    );
  }
}

/// 两格之间那条细线。
///
/// 它自己记拖动起点，不靠父级的 ratio：父级每次回调都要重建整棵树，
/// 拿重建后的 ratio 去累加位移，一帧没跟上就会跳。
class _SplitDivider extends StatefulWidget {
  const _SplitDivider({
    required this.axis,
    required this.total,
    required this.ratio,
    required this.thickness,
    required this.onChanged,
  });

  final Axis axis;
  final double total;
  final double ratio;
  final double thickness;
  final ValueChanged<double> onChanged;

  @override
  State<_SplitDivider> createState() => _SplitDividerState();
}

class _SplitDividerState extends State<_SplitDivider> {
  bool _hovered = false;
  double? _base;
  double _moved = 0;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool horizontal = widget.axis == Axis.horizontal;
    final bool lit = _hovered || _base != null;

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => widget.onChanged(0.5),
        onHorizontalDragStart: horizontal ? _start : null,
        onHorizontalDragUpdate: horizontal ? _update : null,
        onHorizontalDragEnd: horizontal ? _end : null,
        onHorizontalDragCancel: horizontal ? _end : null,
        onVerticalDragStart: horizontal ? null : _start,
        onVerticalDragUpdate: horizontal ? null : _update,
        onVerticalDragEnd: horizontal ? null : _end,
        onVerticalDragCancel: horizontal ? null : _end,
        child: AnimatedContainer(
          duration: AppMotion.instant,
          width: horizontal ? widget.thickness : double.infinity,
          height: horizontal ? double.infinity : widget.thickness,
          color: lit ? p.outline : p.canvas,
          child: Center(
            child: AnimatedOpacity(
              duration: AppMotion.instant,
              opacity: lit ? 1 : 0,
              child: Container(
                width: horizontal ? 1 : double.infinity,
                height: horizontal ? double.infinity : 1,
                color: p.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _start(DragStartDetails _) {
    _base = widget.ratio;
    _moved = 0;
  }

  void _update(DragUpdateDetails d) {
    final double? base = _base;
    if (base == null) return;
    _moved += widget.axis == Axis.horizontal ? d.delta.dx : d.delta.dy;
    widget.onChanged(
      (base + _moved / widget.total).clamp(SplitLimits.min, SplitLimits.max),
    );
  }

  void _end([DragEndDetails? _]) {
    _base = null;
    _moved = 0;
  }
}
