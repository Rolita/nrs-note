import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_outline.dart';
import '../common/app_widgets.dart';

/// 编辑区右缘的大纲刻度与目录卡。
///
/// 收起时是一列 8×2 的短横：每根对应一个标题，当前标题的那根最亮。指针停在
/// 这一列上，它向左展开成一张 300px 的目录卡——三档短横（默认 8 / 悬停 16 /
/// 当前 24）与视觉稿 `design/shell-refine.html` 的 `.toc` 一致。
///
/// 标题扫描按正文对象缓存，并在正文变化后防抖 180ms：这个部件常驻在每一格
/// 上，不能每敲一个字就把整篇逐行扫一遍。卡片打开时立即补扫，内容不滞后。
class TocOverlay extends StatefulWidget {
  const TocOverlay({
    super.key,
    required this.body,
    required this.currentLine,
    required this.onSelect,
  });

  /// 正文全文。换笔记或正文被整段替换时，外壳应换 `key` 重建本组件。
  final String body;

  /// 大纲正在跟随的源码行（从 0 开始）。
  final int currentLine;

  /// 点目录卡里的一行：参数是标题所在的源码行。
  final ValueChanged<int> onSelect;

  @override
  State<TocOverlay> createState() => _TocOverlayState();
}

class _TocOverlayState extends State<TocOverlay> {
  static const Duration _scanDelay = Duration(milliseconds: 180);
  static const Duration _closeDelay = Duration(milliseconds: 160);
  static const Duration _cardMotion = Duration(milliseconds: 140);

  /// 刻度列最多画 24 根；标题更多时按行号取样，当前标题所在的一段亮起。
  static const int _maxTicks = 24;

  final ScrollController _scroll = ScrollController();

  List<Heading> _headings = const <Heading>[];
  String? _scannedBody;
  Timer? _scanTimer;
  Timer? _closeTimer;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _scannedBody = widget.body;
    _headings = extractHeadings(widget.body);
  }

  @override
  void didUpdateWidget(TocOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.body, widget.body)) return;
    if (_open) {
      // 卡片开着：这一次 build 就要拿到新标题。
      _rescanNow();
      return;
    }
    _scanTimer?.cancel();
    _scanTimer = Timer(_scanDelay, () {
      if (mounted) setState(_rescanNow);
    });
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _closeTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 立刻重扫。调用点都在 build 之前或 setState 之内。
  void _rescanNow() {
    _scanTimer?.cancel();
    _scanTimer = null;
    if (identical(_scannedBody, widget.body)) return;
    _scannedBody = widget.body;
    _headings = extractHeadings(widget.body);
    if (_headings.isEmpty) {
      // 标题被削光时整列消失，下一次标题出现应从收起态开始。
      _closeTimer?.cancel();
      _open = false;
    }
  }

  void _openCard() {
    _closeTimer?.cancel();
    if (_open) return;
    _scanTimer?.cancel();
    _scanTimer = null;
    final bool changed = !identical(_scannedBody, widget.body);
    if (changed) {
      _scannedBody = widget.body;
      _headings = extractHeadings(widget.body);
    }
    // 正文刚被削成一个标题也没有：没有可展开的卡，刻度列也要跟着消失。
    if (_headings.isEmpty) {
      if (changed) setState(() {});
      return;
    }
    setState(() => _open = true);
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(_closeDelay, () {
      if (!mounted || !_open) return;
      setState(() => _open = false);
    });
  }

  int get _activeIndex {
    int active = -1;
    for (int i = 0; i < _headings.length; i++) {
      if (_headings[i].line > widget.currentLine) break;
      active = i;
    }
    return active;
  }

  @override
  Widget build(BuildContext context) {
    if (_headings.isEmpty) return const SizedBox.shrink();
    final AppPalette p = context.palette;
    final int active = _activeIndex;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        if (!c.hasBoundedWidth || !c.hasBoundedHeight) {
          return const SizedBox.shrink();
        }
        // 分屏分出来的窄格：卡片连一行字都放不下，刻度让位给正文。
        if (c.maxWidth < 160) return const SizedBox.shrink();
        final double cardWidth = math.min(300, math.max(120, c.maxWidth - 28));
        final double cardMaxHeight = math.max(
          72,
          math.min(420, c.maxHeight - 48),
        );
        // 一根占 2px 短横 + 12px 间隔，上下再各留 12px 悬停余量。
        final int fit = ((cardMaxHeight - 12) / 14).floor();
        final int tickLimit = math.max(1, math.min(_maxTicks, fit));
        final List<bool> ticks = _sampleTicks(
          count: _headings.length,
          active: active,
          limit: tickLimit,
        );

        return Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 14),
            child: SizedBox(
              width: cardWidth,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerRight,
                children: <Widget>[
                  _card(p, active, cardWidth, cardMaxHeight),
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 2,
                    child: Center(child: _hint(p, ticks)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 把标题分成至多 [limit] 根刻度；当前标题所在的那一段亮起。
  List<bool> _sampleTicks({
    required int count,
    required int active,
    required int limit,
  }) {
    final int shown = math.min(count, math.max(1, limit));
    if (shown >= count) {
      return <bool>[for (int i = 0; i < count; i++) i == active];
    }
    return <bool>[
      for (int i = 0; i < shown; i++)
        active >= (i * count) ~/ shown && active < ((i + 1) * count) ~/ shown,
    ];
  }

  Widget _hint(AppPalette p, List<bool> ticks) {
    return AnimatedOpacity(
      opacity: _open ? 0 : 1,
      duration: AppMotion.fast,
      curve: AppMotion.enter,
      child: IgnorePointer(
        ignoring: _open,
        child: MouseRegion(
          onEnter: (_) => _openCard(),
          onExit: (_) => _scheduleClose(),
          child: HoverBuilder(
            builder: (BuildContext context, bool hovered) => Padding(
              // 右缘 6 + 卡片右缘 2 + 外边 14 = 距正文右缘 22，与视觉稿一致。
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  for (int i = 0; i < ticks.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 12),
                    Container(
                      width: 8,
                      height: 2,
                      decoration: BoxDecoration(
                        color: ticks[i]
                            ? p.textPrimary
                            : p.textSecondary.withValues(
                                alpha: hovered ? 0.58 : 0.42,
                              ),
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(AppPalette p, int active, double width, double maxHeight) {
    final double contentHeight = _headings.length * 26 + 10;
    return AnimatedSlide(
      offset: _open ? Offset.zero : const Offset(0.02, 0),
      duration: _cardMotion,
      curve: AppMotion.enter,
      child: AnimatedOpacity(
        opacity: _open ? 1 : 0,
        duration: _cardMotion,
        curve: AppMotion.enter,
        child: IgnorePointer(
          ignoring: !_open,
          child: MouseRegion(
            onEnter: (_) => _openCard(),
            onExit: (_) => _scheduleClose(),
            child: Container(
              width: width,
              height: math.min(contentHeight, maxHeight),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: p.surfaceRaised.withValues(alpha: 0.97),
                border: Border.all(color: p.outline),
                borderRadius: BorderRadius.circular(12),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: p.shadow,
                    blurRadius: 56,
                    spreadRadius: -28,
                    offset: const Offset(0, 28),
                  ),
                ],
              ),
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: 5),
                itemCount: _headings.length,
                itemBuilder: (BuildContext context, int i) {
                  final Heading h = _headings[i];
                  return _TocRow(
                    heading: h,
                    current: i == active,
                    onTap: () => widget.onSelect(h.line),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 目录卡的一行：没有底色、没有强调条，只靠文字和行尾短横的档位说话。
class _TocRow extends StatelessWidget {
  const _TocRow({
    required this.heading,
    required this.current,
    required this.onTap,
  });

  final Heading heading;
  final bool current;
  final VoidCallback onTap;

  static const Duration _dashMotion = Duration(milliseconds: 100);

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final double left = switch (heading.level) {
      1 => 14,
      2 => 26,
      _ => 40,
    };
    final Color rest = heading.level >= 3 ? p.textTertiary : p.textSecondary;
    final String label = heading.plainText;

    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        final bool lit = hovered || current;
        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 26,
            child: Padding(
              padding: EdgeInsets.only(left: left, right: 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      label.isEmpty ? '(空标题)' : label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.caption,
                        height: 1.2,
                        fontWeight: lit ? FontWeight.w600 : FontWeight.w400,
                        color: lit ? p.textPrimary : rest,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // 槽宽固定 24，右缘对齐：短 / 中 / 长三档只改长度，文字不会
                  // 因为悬停变粗而被重新截断到另一个位置。
                  SizedBox(
                    width: 24,
                    height: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: AnimatedContainer(
                        duration: _dashMotion,
                        curve: Curves.easeOut,
                        width: current ? 24 : (hovered ? 16 : 8),
                        height: 2,
                        decoration: BoxDecoration(
                          color: current
                              ? p.textPrimary
                              : (hovered
                                    ? p.textPrimary.withValues(alpha: 0.85)
                                    : p.textSecondary.withValues(alpha: 0.42)),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
