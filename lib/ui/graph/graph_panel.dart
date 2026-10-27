import 'dart:math' as math;

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
    this.showOrphans = true,
    this.useFolderColors = false,
    this.nodeScale = 0.75,
    this.linkScale = 1,
    this.labelZoomStart = 2.25,
    this.labelZoomFull = 5.2,
    this.spinScale = 0.2,
    this.spinFalloff = 1.7,
    this.dragLink = 0.7,
    this.dragFarPull = 1.2,
    this.dragStiffness = 1.2,
    this.dragRepel = 1,
    this.dragGap = 0.16,
    this.folder,
  });

  final GraphScope scope;

  /// 局部图谱的跳数，1–4。
  final int depth;

  /// 搜索框内容（已 trim + 小写）。
  final String query;

  final bool showOrphans;

  /// 按文件夹着色。默认关：大多数库的笔记集中在少数几个文件夹里，打开之后
  /// 整颗球只有一两种颜色，反而不如灰白的点云能看出结构。想要颜色语言时
  /// 再手动打开。
  final bool useFolderColors;

  /// 节点大小 / 连线粗细，0.6–1.6。
  final double nodeScale;
  final double linkScale;

  /// 标签随缩放的淡入区间：缩到 [labelZoomStart] 以下不显示，放大到
  /// [labelZoomFull] 以上完全显示，中间平滑过渡。
  final double labelZoomStart;
  final double labelZoomFull;

  /// 空闲自转速度倍数：0 = 不转，1 = 默认，2 = 两倍速。
  final double spinScale;

  /// 拖动转动随放大倍率减速的强度：0 = 不减速，1 = 转速与倍率成反比，
  /// 越大放大后转得越慢。
  ///
  /// 放大之后球面在屏幕上变大，同样的角度会让球面滑出很远；这个指数
  /// 把转速按倍率的幂次压下来，用户自己调到手感合适。
  final double spinFalloff;

  /// 拖拽力导向的参数。
  ///
  /// 邻居像被弹簧拴在被拖节点上：连接长度决定它们最终隔多远（相对建图时的
  /// 原距离），远端收拢让原本很远的邻居额外向中心靠，弹簧强度决定跟手的
  /// 快慢，斥力与最小间距负责把挤到一起的节点推开。
  final double dragLink;

  /// 远端收拢：0 = 只按连接长度等比例缩放；越大，原来角距越远的邻居被拉得
  /// 越靠中心。默认 1.2，近处几乎不变，跨半球的边会明显缩短。
  final double dragFarPull;

  final double dragStiffness;
  final double dragRepel;
  final double dragGap;

  /// 图例点选的分组（顶层文件夹名），`null` 表示不筛。
  final String? folder;

  GraphSettings copyWith({
    GraphScope? scope,
    int? depth,
    String? query,
    bool? showOrphans,
    bool? useFolderColors,
    double? nodeScale,
    double? linkScale,
    double? labelZoomStart,
    double? labelZoomFull,
    double? spinScale,
    double? spinFalloff,
    double? dragLink,
    double? dragFarPull,
    double? dragStiffness,
    double? dragRepel,
    double? dragGap,
    Object? folder = _keep,
  }) {
    return GraphSettings(
      scope: scope ?? this.scope,
      depth: depth ?? this.depth,
      query: query ?? this.query,
      showOrphans: showOrphans ?? this.showOrphans,
      useFolderColors: useFolderColors ?? this.useFolderColors,
      nodeScale: nodeScale ?? this.nodeScale,
      linkScale: linkScale ?? this.linkScale,
      labelZoomStart: labelZoomStart ?? this.labelZoomStart,
      labelZoomFull: labelZoomFull ?? this.labelZoomFull,
      spinScale: spinScale ?? this.spinScale,
      spinFalloff: spinFalloff ?? this.spinFalloff,
      dragLink: dragLink ?? this.dragLink,
      dragFarPull: dragFarPull ?? this.dragFarPull,
      dragStiffness: dragStiffness ?? this.dragStiffness,
      dragRepel: dragRepel ?? this.dragRepel,
      dragGap: dragGap ?? this.dragGap,
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
      other.showOrphans == showOrphans &&
      other.useFolderColors == useFolderColors &&
      other.nodeScale == nodeScale &&
      other.linkScale == linkScale &&
      other.labelZoomStart == labelZoomStart &&
      other.labelZoomFull == labelZoomFull &&
      other.spinScale == spinScale &&
      other.spinFalloff == spinFalloff &&
      other.dragLink == dragLink &&
      other.dragFarPull == dragFarPull &&
      other.dragStiffness == dragStiffness &&
      other.dragRepel == dragRepel &&
      other.dragGap == dragGap &&
      other.folder == folder;

  @override
  int get hashCode => Object.hash(
    scope,
    depth,
    query,
    showOrphans,
    useFolderColors,
    nodeScale,
    linkScale,
    labelZoomStart,
    labelZoomFull,
    spinScale,
    spinFalloff,
    dragLink,
    dragFarPull,
    dragStiffness,
    dragRepel,
    dragGap,
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
                          label: '孤立笔记',
                          value: settings.showOrphans,
                          onChanged: (bool v) =>
                              onChanged(settings.copyWith(showOrphans: v)),
                        ),
                        _SwitchRow(
                          label: '按文件夹着色',
                          value: settings.useFolderColors,
                          onChanged: (bool v) => onChanged(
                            settings.copyWith(useFolderColors: v),
                          ),
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
                        _SliderRow(
                          label: '标签起始',
                          value: settings.labelZoomStart,
                          min: 0.45,
                          max: 5.1,
                          divisions: 93,
                          display: '${(settings.labelZoomStart * 100).round()}',
                          onChanged: (double v) => onChanged(
                            settings.copyWith(
                              labelZoomStart: v,
                              // 起始不能越过完整，拖过头时把另一头一起推走。
                              labelZoomFull: v + 0.05 > settings.labelZoomFull
                                  ? v + 0.05
                                  : settings.labelZoomFull,
                            ),
                          ),
                        ),
                        _SliderRow(
                          label: '标签完整',
                          value: settings.labelZoomFull,
                          min: 0.5,
                          max: 5.2,
                          divisions: 94,
                          display: '${(settings.labelZoomFull * 100).round()}',
                          onChanged: (double v) => onChanged(
                            settings.copyWith(
                              labelZoomFull: v,
                              labelZoomStart:
                                  v - 0.05 < settings.labelZoomStart
                                  ? v - 0.05
                                  : settings.labelZoomStart,
                            ),
                          ),
                        ),
                        _Hint(
                          '${(settings.labelZoomStart * 100).round()}% 开始出现，'
                          '${(settings.labelZoomFull * 100).round()}% 完全显示',
                        ),
                        _SliderRow(
                          label: '旋转速度',
                          value: settings.spinScale,
                          min: 0,
                          max: 2,
                          divisions: 40,
                          display: '${(settings.spinScale * 100).round()}',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(spinScale: v)),
                        ),
                        _SliderRow(
                          label: '放大减速',
                          value: settings.spinFalloff,
                          min: 0,
                          max: 2.5,
                          divisions: 25,
                          display:
                              '${(settings.spinFalloff * 100).round()}%',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(spinFalloff: v)),
                        ),
                        _Hint('越大，放大后拖动转动越慢；0% 不减速'),
                        _SliderRow(
                          label: '连接长度',
                          value: settings.dragLink,
                          min: 0.4,
                          max: 1.3,
                          divisions: 18,
                          display: '${(settings.dragLink * 100).round()}%',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(dragLink: v)),
                        ),
                        _SliderRow(
                          label: '远端收拢',
                          value: settings.dragFarPull,
                          min: 0,
                          max: 2,
                          divisions: 40,
                          display:
                              '${(settings.dragFarPull * 100).round()}%',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(dragFarPull: v)),
                        ),
                        _SliderRow(
                          label: '弹簧强度',
                          value: settings.dragStiffness,
                          min: 0.3,
                          max: 2,
                          divisions: 34,
                          display:
                              '${(settings.dragStiffness * 100).round()}%',
                          onChanged: (double v) => onChanged(
                            settings.copyWith(dragStiffness: v),
                          ),
                        ),
                        _SliderRow(
                          label: '斥力',
                          value: settings.dragRepel,
                          min: 0,
                          max: 2,
                          divisions: 40,
                          display: '${(settings.dragRepel * 100).round()}%',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(dragRepel: v)),
                        ),
                        _SliderRow(
                          label: '最小间距',
                          value: settings.dragGap,
                          min: 0.08,
                          max: 0.36,
                          divisions: 14,
                          display:
                              '${(settings.dragGap * 180 / math.pi).round()}°',
                          onChanged: (double v) =>
                              onChanged(settings.copyWith(dragGap: v)),
                        ),
                        _Hint('越远的邻居收得越多；最小间距防止挤成一团'),
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
