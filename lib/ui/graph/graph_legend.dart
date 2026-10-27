import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../common/app_widgets.dart';

/// 一个分组（顶层文件夹）在图上分到的颜色和笔记数。
class GraphGroup {
  const GraphGroup({
    required this.folder,
    required this.label,
    required this.color,
    required this.count,
  });

  /// 顶层文件夹名，`''` 是根目录。点选时原样回传。
  final String folder;

  /// 显示给人看的名：根目录不叫「空字符串」。
  final String label;

  final Color color;
  final int count;
}

/// 画布左下角的文件夹图例。
///
/// 它同时是**筛选器**：点一项就把别的分组淡掉，再点取消。图上光有颜色没有
/// 图例，等于让人猜；有了图例还能顺手当开关用，比在设置面板里再列一遍文件夹
/// 省一半地方。
///
/// 默认收起：分组多的时候这块能占掉小半屏，而大部分时候读者只是在看球。
/// 点标题展开，展开/收起只影响自己，不写进设置。
class GraphLegend extends StatefulWidget {
  const GraphLegend({
    super.key,
    required this.groups,
    required this.selected,
    required this.onSelect,
  });

  final List<GraphGroup> groups;

  /// 当前筛中的分组，`null` 表示没筛。
  final String? selected;

  final ValueChanged<String?> onSelect;

  @override
  State<GraphLegend> createState() => _GraphLegendState();
}

class _GraphLegendState extends State<GraphLegend> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    if (widget.groups.length < 2) return const SizedBox.shrink();

    // IntrinsicWidth：图例挂在 Positioned 里，宽度无界，而里面每一行都要
    // 用 Flexible 把计数推到右边。不给它一个「按最宽那一行收」的宽度，Row
    // 会拿到无穷大约束直接炸掉。
    return IntrinsicWidth(
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.sm + 2,
          AppSpace.sm,
          AppSpace.sm + 2,
          AppSpace.sm + 1,
        ),
        decoration: BoxDecoration(
          color: p.sidebar.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: p.outline),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: p.shadow,
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 2,
                  bottom: _expanded ? AppSpace.xs + 1 : 0,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '分组 · 文件夹',
                      style: TextStyle(
                        fontSize: AppText.caption - 1,
                        letterSpacing: 0.4,
                        color: p.textTertiary,
                      ),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Icon(
                      _expanded
                          ? LucideIcons.chevronDown
                          : LucideIcons.chevronRight,
                      size: 12,
                      color: p.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              for (final GraphGroup group in widget.groups)
                _LegendRow(
                  group: group,
                  selected: widget.selected == group.folder,
                  dimmed:
                      widget.selected != null &&
                      widget.selected != group.folder,
                  onTap: () => widget.onSelect(
                    widget.selected == group.folder ? null : group.folder,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.group,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final GraphGroup group;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => Opacity(
        opacity: dimmed ? 0.42 : 1,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 21,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: selected
                  ? p.surfaceRaised.withValues(alpha: 0.7)
                  : (hovered ? p.surfaceRaised.withValues(alpha: 0.4) : null),
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: group.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: AppSpace.sm - 1),
                Flexible(
                  child: Text(
                    group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.label,
                      color: selected || hovered
                          ? p.textPrimary
                          : p.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Text(
                  '${group.count}',
                  style: TextStyle(
                    fontSize: AppText.caption - 1,
                    color: p.textTertiary,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
