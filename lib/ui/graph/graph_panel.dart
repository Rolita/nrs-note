import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../common/app_widgets.dart';

/// 图谱看哪一部分。
enum GraphScope {
  /// 全库。
  global,

  /// 以当前笔记为心，[GraphSettings.depth] 跳以内。
  local,
}

/// 图谱的可调参数。
///
/// 一个不可变值对象，而不是十个 `onXxxChanged` 回调：面板一次改一项，直接把
/// 新的整份丢回去，调用处只有一个赋值，也不会出现「两个字段各自 setState、
/// 中间态画了一帧」这种事。
@immutable
class GraphSettings {
  const GraphSettings({
    this.scope = GraphScope.global,
    this.depth = 1,
    this.query = '',
    this.showLabels = true,
    this.showOrphans = true,
    this.showArrows = false,
    this.nodeScale = 1,
    this.linkScale = 1,
    this.folder,
  });

  final GraphScope scope;

  /// 局部图谱的跳数，1–4。
  final int depth;

  /// 搜索框内容（已 trim + 小写）。
  final String query;

  /// 显示标签：开就全显示，关就全不显示。没有第三种状态。
  final bool showLabels;

  final bool showOrphans;
  final bool showArrows;

  /// 节点大小 / 连线距离，0.6–1.6。
  final double nodeScale;
  final double linkScale;

  /// 图例点选的分组（顶层文件夹名），`null` 表示不筛。
  final String? folder;

  GraphSettings copyWith({
    GraphScope? scope,
    int? depth,
    String? query,
    bool? showLabels,
    bool? showOrphans,
    bool? showArrows,
    double? nodeScale,
    double? linkScale,
    Object? folder = _keep,
  }) {
    return GraphSettings(
      scope: scope ?? this.scope,
      depth: depth ?? this.depth,
      query: query ?? this.query,
      showLabels: showLabels ?? this.showLabels,
      showOrphans: showOrphans ?? this.showOrphans,
      showArrows: showArrows ?? this.showArrows,
      nodeScale: nodeScale ?? this.nodeScale,
      linkScale: linkScale ?? this.linkScale,
      // 用哨兵而不是 `??`：`null` 本身是「不筛分组」这个有意义的值。
      folder: identical(folder, _keep) ? this.folder : folder as String?,
    );
  }

  static const Object _keep = Object();

  @override
  bool operator ==(Object other) =>
      other is GraphSettings &&
      other.scope == scope &&
      other.depth == depth &&
      other.query == query &&
      other.showLabels == showLabels &&
      other.showOrphans == showOrphans &&
      other.showArrows == showArrows &&
      other.nodeScale == nodeScale &&
      other.linkScale == linkScale &&
      other.folder == folder;

  @override
  int get hashCode => Object.hash(
    scope,
    depth,
    query,
    showLabels,
    showOrphans,
    showArrows,
    nodeScale,
    linkScale,
    folder,
  );
}

/// 画布左上角的浮动设置面板。
///
/// 和大纲、图片那些侧栏不一样：它盖在画布上，可以整块收起，收起后只剩一行
/// 标题——看大图时不该有一块面板占着左上角。
class GraphPanel extends StatelessWidget {
  const GraphPanel({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.visibleCount,
    required this.localCount,
    required this.currentTitle,
    required this.collapsed,
    required this.onToggleCollapsed,
    this.width = AppLayout.graphPanelWidth,
  });

  final GraphSettings settings;
  final ValueChanged<GraphSettings> onChanged;

  /// 当前画了多少个节点（收起时也显示，方便对比筛选效果）。
  final int visibleCount;

  /// 局部图谱一共多少篇（含自己）。
  final int localCount;

  /// 局部图谱的中心笔记标题。
  final String? currentTitle;

  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final double width;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return Container(
      width: width,
      decoration: BoxDecoration(
        // 半透明 + 模糊：面板压在图上是「浮着」的，而不是把图切开一块。
        color: p.sidebar.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: p.outline),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: p.shadow,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Header(
            collapsed: collapsed,
            onTap: onToggleCollapsed,
            count: visibleCount,
          ),
          if (!collapsed) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.md - 1,
                0,
                AppSpace.md - 1,
                AppSpace.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (settings.scope == GraphScope.local)
                    _Section(
                      title: '局部图谱',
                      trailing: localCount > 0 ? '$localCount 篇' : null,
                      first: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          _SliderRow(
                            label: '深度',
                            value: settings.depth.toDouble(),
                            min: 1,
                            max: 4,
                            divisions: 3,
                            display: '${settings.depth}',
                            onChanged: (double v) =>
                                onChanged(settings.copyWith(depth: v.round())),
                          ),
                          _Hint(
                            '离「${currentTitle ?? '当前笔记'}」几跳',
                          ),
                        ],
                      ),
                    ),
                  _Section(
                    title: '筛选',
                    first: settings.scope != GraphScope.local,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _SearchField(
                          value: settings.query,
                          onChanged: (String v) =>
                              onChanged(settings.copyWith(query: v)),
                        ),
                        _SwitchRow(
                          label: '显示标签',
                          value: settings.showLabels,
                          onChanged: (bool v) =>
                              onChanged(settings.copyWith(showLabels: v)),
                        ),
                        _SwitchRow(
                          label: '孤立笔记',
                          value: settings.showOrphans,
                          onChanged: (bool v) =>
                              onChanged(settings.copyWith(showOrphans: v)),
                        ),
                        _SwitchRow(
                          label: '连线箭头',
                          value: settings.showArrows,
                          onChanged: (bool v) =>
                              onChanged(settings.copyWith(showArrows: v)),
                        ),
                      ],
                    ),
                  ),
                  _Section(
                    title: '显示',
                    trailing: '$visibleCount 个节点',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _SliderRow(
                          label: '节点大小',
                          value: settings.nodeScale,
                          min: 0.6,
                          max: 1.6,
                          display: '${(settings.nodeScale * 100).round()}',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(nodeScale: v)),
                        ),
                        _SliderRow(
                          label: '连线距离',
                          value: settings.linkScale,
                          min: 0.6,
                          max: 1.6,
                          display: '${(settings.linkScale * 100).round()}',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(linkScale: v)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.collapsed,
    required this.onTap,
    required this.count,
  });

  final bool collapsed;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md - 1,
              0,
              AppSpace.sm,
              0,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  LucideIcons.filter,
                  size: AppIconSize.xs - 2,
                  color: hovered ? p.textSecondary : p.textTertiary,
                ),
                const SizedBox(width: AppSpace.sm - 2),
                Text(
                  '图谱设置',
                  style: TextStyle(
                    fontSize: AppText.caption,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: hovered ? p.textSecondary : p.textTertiary,
                  ),
                ),
                const Spacer(),
                if (collapsed)
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                const SizedBox(width: AppSpace.xs),
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: AppMotion.fast,
                  child: Icon(
                    LucideIcons.chevronDown,
                    size: AppIconSize.xs - 3,
                    color: p.textTertiary,
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

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.trailing,
    this.first = false,
  });

  final String title;
  final Widget child;
  final String? trailing;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      padding: EdgeInsets.only(top: first ? 2 : AppSpace.sm, bottom: AppSpace.sm),
      decoration: BoxDecoration(
        border: first
            ? null
            : Border(top: BorderSide(color: p.outlineSoft, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.xs + 1),
            child: Row(
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppText.caption - 1,
                    letterSpacing: 0.4,
                    color: p.textTertiary,
                  ),
                ),
                const Spacer(),
                if (trailing != null)
                  Text(
                    trailing!,
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
          child,
        ],
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  const _SearchField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_SearchField old) {
    super.didUpdateWidget(old);
    // 面板收起再展开会重建输入框；把外部的值同步回来，别让用户看见空框。
    if (widget.value != _controller.text) {
      _controller.text = widget.value;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: 26,
      margin: const EdgeInsets.only(bottom: AppSpace.xxs),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(
          color: _focus.hasFocus ? p.outline : p.outlineSoft,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(LucideIcons.search, size: AppIconSize.xs - 3, color: p.textTertiary),
          const SizedBox(width: AppSpace.sm - 2),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              onChanged: widget.onChanged,
              cursorHeight: 13,
              style: TextStyle(
                fontSize: AppText.label,
                color: p.textPrimary,
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
              cursorColor: p.accent,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '搜索笔记…',
                hintStyle: TextStyle(
                  fontSize: AppText.label,
                  color: p.textTertiary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return HoverBuilder(
      builder: (BuildContext context, bool hovered) => GestureDetector(
        onTap: () => onChanged(!value),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 24,
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppText.label,
                    color: hovered ? p.textPrimary : p.textSecondary,
                  ),
                ),
              ),
              _MiniSwitch(value: value),
            ],
          ),
        ),
      ),
    );
  }
}

/// 26×15 的开关。
///
/// 不用 Material 的 [Switch]：它最小也有 40×30，比整行还高，塞进 24px 的
/// 行里只能靠 `Transform.scale` 缩，缩完边缘发糊。
class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return AnimatedContainer(
      duration: AppMotion.fast,
      width: 26,
      height: 15,
      padding: const EdgeInsets.all(2),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      decoration: BoxDecoration(
        color: value ? p.accent : p.outline,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: value ? p.onAccent : p.textSecondary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return SizedBox(
      height: 24,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: TextStyle(fontSize: AppText.label, color: p.textSecondary),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                activeTrackColor: p.accent,
                inactiveTrackColor: p.outline,
                thumbColor: p.accent,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                trackShape: const RoundedRectSliderTrackShape(),
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 24,
            child: Text(
              display,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: AppText.caption - 1,
                color: p.textTertiary,
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(left: 52, top: 1),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppText.caption - 1,
          color: p.textTertiary,
        ),
      ),
    );
  }
}
