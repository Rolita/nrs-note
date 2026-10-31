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
    this.dividerThickness = AppLayout.splitSeamWidth,
    this.dividerColor,
  });

  final SplitNode<T> root;

  /// 画一个格子。
  final Widget Function(BuildContext context, SplitLeaf<T> leaf) leafBuilder;

  /// 拖动或双击分割线后回调。父级换一棵新树，不要就地改。
  final void Function(SplitBranch<T> branch, double ratio) onRatioChanged;

  final double dividerThickness;

  /// 缝填什么色。不传 = 编辑区的纸面。
  ///
  /// ⛔ 缝要跟着**它所在的那一栏**走，别画成画布色、也别在缝心补一条线：
  /// 两格编辑栏是同一种纸，两侧边栏也是同一种侧栏色，缝填成同一档就自然
  /// 消失，只剩一条能拖的、看不见的地带。用户原话：「编辑栏分割的时候，
  /// 移除 1px 的拖拽缝竖线。侧边栏分割的时候好像也有这个 1px 的线，一起
  /// 移除。」
  final Color? dividerColor;

  @override
  Widget build(BuildContext context) {
    return _node(context, root);
  }

  /// [top] 说明这一棵子树的顶边是不是编辑区的顶边：只有贴着最上面的
  /// 横向分栏，缝的顶上 40px 才属于顶带。嵌在别格下面的分栏要是也画这一段，
  /// 半腰就会凭空多出一条 40px 的顶带色。
  Widget _node(BuildContext context, SplitNode<T> node, {bool top = true}) {
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
          color: dividerColor ?? context.palette.surface,
          topBand: top && horizontal,
          onChanged: (double ratio) => onRatioChanged(branch, ratio),
        );

        return Flex(
          direction: branch.axis,
          children: <Widget>[
            Expanded(
              flex: firstFlex,
              child: _node(context, branch.first, top: top),
            ),
            divider,
            Expanded(
              flex: secondFlex,
              child: _node(context, branch.second, top: top && horizontal),
            ),
          ],
        );
      },
    );
  }
}

/// 两格之间那条缝：**只有可拖的宽度，没有线**。
///
/// 它自己记拖动起点，不靠父级的 ratio：父级每次回调都要重建整棵树，
/// 拿重建后的 ratio 去累加位移，一帧没跟上就会跳。
///
/// ⛔ 缝里什么都不画，只填 [color]（= 这一栏的底色）。以前这里是一道画布色
/// 的槽 + 缝心一条 1px `outline`，两格之间看着就是一条黑线；两格本来就是同
/// 一种纸，填同色就够，边界靠两侧内容自己的留白读出来。用户原话：「编辑栏
/// 分割的时候，移除 1px 的拖拽缝竖线。」
class _SplitDivider extends StatefulWidget {
  const _SplitDivider({
    required this.axis,
    required this.total,
    required this.ratio,
    required this.thickness,
    required this.color,
    required this.topBand,
    required this.onChanged,
  });

  final Axis axis;
  final double total;
  final double ratio;
  final double thickness;

  /// 缝的底色：贴着哪一栏就用哪一栏的（编辑区纸面 / 侧边栏侧栏色）。
  final Color color;

  /// 这条缝的顶边贴着编辑区顶边时，顶上 40px 画 `sidebar`——那里是标签条。
  final bool topBand;
  final ValueChanged<double> onChanged;

  @override
  State<_SplitDivider> createState() => _SplitDividerState();
}

class _SplitDividerState extends State<_SplitDivider> {
  double? _base;
  double _moved = 0;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool horizontal = widget.axis == Axis.horizontal;

    // 顶上 40 是标签条那一档，下面才是这一栏的底色。两者同色时（侧边栏）
    // 看起来就是整条一种颜色。
    final Widget track = horizontal && widget.topBand
        ? Column(
            children: <Widget>[
              SizedBox(
                width: double.infinity,
                height: AppLayout.titleBarHeight,
                child: ColoredBox(color: p.sidebar),
              ),
              Expanded(child: ColoredBox(color: widget.color)),
            ],
          )
        : ColoredBox(color: widget.color);

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
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
        child: SizedBox(
          width: horizontal ? widget.thickness : double.infinity,
          height: horizontal ? double.infinity : widget.thickness,
          child: track,
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
