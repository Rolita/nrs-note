import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/note_graph.dart';
import '../../core/utils/table_model.dart' show CellColorToken;
import '../../data/models/note.dart';
import '../common/app_widgets.dart';
import 'graph_legend.dart';
import 'graph_painter.dart';
import 'graph_panel.dart';
import 'graph_physics.dart';
import 'graph_style.dart';

/// 关系图谱。
///
/// 从全库笔记的 `[[双链]]` 里抽边，用一套固定的力导向参数摆位，画在
/// [CustomPaint] 上。它不是侧边栏而是**主区的一个视图**：图要的是面积，
/// 挤在 252px 的栏里只能看见一团线头。
///
/// 三条设计约束，改之前先读：
///
/// * **首屏是稳定布局**。打开时同步跑 `settle()` 再 fit，第一帧就是最终形状，
///   不会「先炸开再收拢」。
/// * **静止就停 Ticker**。布局不动的图谱不该烧电，`alpha` 掉到阈值以下
///   就把 Ticker 停掉。
/// * **标签只有两种状态**。开关打开就全画，关掉就一个都不画；没有「缩小时
///   自动隐藏」这种猜心思的第三态。
class GraphView extends StatefulWidget {
  const GraphView({
    super.key,
    required this.notes,
    required this.currentId,
    required this.onOpenNote,
  });

  /// 全库笔记。由外壳传进来，图谱自己不碰 controller，测试才好写。
  final List<Note> notes;

  /// 当前笔记的 id。局部图谱以它为心，它自己也常驻一圈淡环。
  final String? currentId;

  /// 双击某个节点：打开那篇笔记。
  final ValueChanged<String> onOpenNote;

  @override
  State<GraphView> createState() => GraphViewState();
}

class GraphViewState extends State<GraphView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _Repaint _repaint = _Repaint();
  final GraphLabelCache _labels = GraphLabelCache();

  /// 光点的时钟。painter 每帧现取，不用为它重建绘制数据。
  final GraphClock _clock = GraphClock();

  /// 上一次 tick 的 elapsed。Ticker 停掉再启动会从 0 重新计，
  /// 所以要把「倒退」当成新的一轮，否则时间会往回跳、光点集体倒着走。
  Duration _lastTick = Duration.zero;

  /// 鼠标是不是在画布里。
  ///
  /// 光点只在鼠标进来时才跑：一直转的 Ticker 会让 `pumpAndSettle` 永远
  /// 等不到静止，也违背「静止的图谱不该烧电」。测试用触摸事件，这里恒为
  /// false，所以测试里图是静止的。
  bool _mouseInside = false;

  /// 全库的图。建一次，局部视图靠 [NoteGraph.subgraph] 切片。
  NoteGraph _graph = NoteGraph.empty();

  /// 当前画的那张图（全局，或局部子图）。
  NoteGraph _view = NoteGraph.empty();

  GraphLayout _layout = GraphLayout(0);

  /// 已乘过「节点大小」的半径。绘制和命中测试都用它。
  Float64List _radii = Float64List(0);

  /// 每个节点是否通过筛选（没通过就淡到 16%，不删）。
  List<bool> _lit = <bool>[];

  /// 文件夹 → 色名。存色名不存色值：建图在 `initState` 里发生，那时读不到
  /// `Theme`，而浅色/深色主题要解析成两组不同的色值。
  Map<String, CellColorToken> _folderTokens = <String, CellColorToken>{};

  /// 全库每个文件夹的篇数（图例用，不受筛选影响）。
  Map<String, int> _folderCounts = <String, int>{};

  GraphSettings _settings = const GraphSettings();
  bool _panelCollapsed = false;

  int? _hover;
  int? _selected;

  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _stageSize = Size.zero;

  int? _dragging;
  bool _dragMoved = false;
  Offset? _panFrom;
  Offset _panStart = Offset.zero;
  bool _panned = false;
  Offset _pointer = Offset.zero;

  /// 上一次建图时笔记的指纹，用来判断「真的变了没有」。
  int _signature = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _signature = _signatureOf(widget.notes);
    _rebuildAll();
  }

  @override
  void didUpdateWidget(GraphView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int signature = _signatureOf(widget.notes);
    final bool structureChanged = signature != _signature;
    final bool centreChanged =
        widget.currentId != oldWidget.currentId &&
        _settings.scope == GraphScope.local;
    if (!structureChanged && !centreChanged) return;
    _signature = signature;
    _rebuildAll();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 建图

  /// 笔记列表的指纹。
  ///
  /// `allNotes` 每次调用都返回一个新 List，比身份永远不相等——那样每帧都会
  /// 重建整张图。所以比内容：`String.hashCode` 在 Dart 里算一次就缓存，
  /// 三百篇也就几百次哈希查表。
  static int _signatureOf(List<Note> notes) {
    int h = notes.length;
    for (final Note n in notes) {
      h = h * 31 + n.id.hashCode;
      h = h * 31 + n.title.hashCode;
      h = h * 31 + n.folderPath.hashCode;
      h = h * 31 + n.body.hashCode;
    }
    return h;
  }

  void _rebuildAll() {
    _graph = buildNoteGraph(widget.notes);
    _folderTokens = assignFolderTokens(
      _graph.nodes.map((GraphNode n) => n.folder),
    );
    _rebuildView();
  }

  /// 重新切子图 + 重新摆位。
  void _rebuildView() {
    NoteGraph view = _graph;
    final int? centre = _graph.indexOfId(widget.currentId);
    if (_settings.scope == GraphScope.local) {
      // 没有选中的笔记时局部图谱没有中心，退化成空图，界面上给一句提示。
      view = centre == null
          ? NoteGraph.empty()
          : _graph.subgraph(_graph.neighbourhood(centre, _settings.depth));
    }
    if (!_settings.showOrphans) {
      // 孤立笔记是**结构性**选择，所以是真删（要重排），不是变淡。
      view = view.subgraph(<int>{
        for (final GraphNode n in view.nodes)
          if (!n.isOrphan) n.index,
      });
    }

    _view = view;
    _layout = GraphLayout.of(view);
    _layout.restLength = GraphPhysics.restLength * _settings.linkScale;
    _layout.settle(view, settleTicksFor(view.nodes.length));
    _applyNodeScale();
    _lit = List<bool>.filled(view.nodes.length, true);
    _recomputeLit();

    _hover = null;
    _selected = null;
    _dragging = null;
    _updateGroups();
    // 首屏：布局已经收敛，直接 fit 到窗口，第一帧就是最终形状。
    _fitToStage();
    _labels.clear();
  }

  void _applyNodeScale() {
    _radii = _layout.scaledRadii(_settings.nodeScale);
  }

  /// 数一遍每个文件夹有几篇，给图例用。颜色留到 `build` 里解析。
  void _updateGroups() {
    final Map<String, int> counts = <String, int>{};
    for (final GraphNode n in _graph.nodes) {
      counts[n.folder] = (counts[n.folder] ?? 0) + 1;
    }
    _folderCounts = <String, int>{
      for (final String folder in counts.keys.toList()..sort())
        folder: counts[folder]!,
    };
  }

  /// 把色名解析成当前主题下的颜色（图例、节点、气泡点共用这一份）。
  Map<String, Color> _resolveFolderColors(AppPalette p) => <String, Color>{
    for (final MapEntry<String, CellColorToken> e in _folderTokens.entries)
      e.key: groupColor(p, e.value),
  };

  List<GraphGroup> _groupsOf(AppPalette p, Map<String, Color> colors) =>
      <GraphGroup>[
        for (final MapEntry<String, int> e in _folderCounts.entries)
          GraphGroup(
            folder: e.key,
            label: e.key.isEmpty ? '根目录' : e.key,
            color: colors[e.key] ?? p.textSecondary,
            count: e.value,
          ),
      ];

  // ------------------------------------------------------------------ 筛选

  void _recomputeLit() {
    final String q = _settings.query.trim().toLowerCase();
    for (final GraphNode n in _view.nodes) {
      bool ok = true;
      if (_settings.folder != null && n.folder != _settings.folder) ok = false;
      if (ok && q.isNotEmpty) {
        ok =
            n.title.toLowerCase().contains(q) ||
            n.tags.any((String t) => t.toLowerCase().contains(q));
      }
      _lit[n.index] = ok;
    }
  }

  // ------------------------------------------------------------------ 视口

  Rect _bounds() {
    if (_view.isEmpty) return Rect.zero;
    double x0 = double.infinity;
    double y0 = double.infinity;
    double x1 = double.negativeInfinity;
    double y1 = double.negativeInfinity;
    for (int i = 0; i < _view.nodes.length; i++) {
      final double r = _radii[i];
      if (_layout.x[i] - r < x0) x0 = _layout.x[i] - r;
      if (_layout.y[i] - r < y0) y0 = _layout.y[i] - r;
      if (_layout.x[i] + r > x1) x1 = _layout.x[i] + r;
      if (_layout.y[i] + r > y1) y1 = _layout.y[i] + r;
    }
    return Rect.fromLTRB(x0, y0, x1, y1);
  }

  /// 把整张图装进画布并居中。
  void _fitToStage() {
    final Size size = _stageSize;
    if (size.isEmpty) return;
    if (_view.isEmpty) {
      _scale = 1;
      _offset = Offset(size.width / 2, size.height / 2);
      return;
    }
    final Rect b = _bounds();
    const double pad = 74;
    final double fit = math.min(
      (size.width - pad * 2) / math.max(b.width, 1),
      (size.height - pad * 2) / math.max(b.height, 1),
    );
    _scale = fit.clamp(0.2, 1.5);
    _offset = Offset(
      size.width / 2 - b.center.dx * _scale,
      size.height / 2 - b.center.dy * _scale,
    );
  }

  void _zoomAt(Offset local, double factor) {
    final double next = (_scale * factor).clamp(0.22, 3.2);
    final double k = next / _scale;
    _offset = local - (local - _offset) * k;
    _scale = next;
  }

  Offset _toWorld(Offset local) => (local - _offset) / _scale;

  /// 命中测试：反变换回世界坐标，找最近且在半径内的节点。
  ///
  /// 线性扫描，不建空间索引——三百个节点一次扫描是微秒级，建索引反而更慢。
  int? _nodeAt(Offset local) {
    final Offset world = _toWorld(local);
    int? best;
    double bestDistance = double.infinity;
    for (int i = 0; i < _view.nodes.length; i++) {
      final double dx = world.dx - _layout.x[i];
      final double dy = world.dy - _layout.y[i];
      final double d = math.sqrt(dx * dx + dy * dy);
      // 和 painter 用同一个下限：画得比物理半径大时，点边缘也得点得到。
      final double r = math.max(
        _radii[i],
        GraphPainter.minScreenRadius / math.max(_scale, 0.01),
      );
      if (d <= r + 6 && d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  // ------------------------------------------------------------------ 动画

  void _heat(double alpha) {
    _layout.alpha = alpha;
    if (!_ticker.isActive) _ticker.start();
  }

  /// 有焦点、鼠标也在画布里时，让 Ticker 一直转——出链上的光点要跑。
  void _flow() {
    if (!_mouseInside) return;
    if ((_hover ?? _selected) == null) return;
    if (!_ticker.isActive) _ticker.start();
  }

  void _onTick(Duration elapsed) {
    if (elapsed < _lastTick) _lastTick = Duration.zero;
    _clock.seconds += (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;

    final bool settled =
        _layout.alpha < GraphPhysics.restingAlpha && _dragging == null;
    if (!settled) {
      _layout.step(
        _view,
        math.max(_layout.alpha, _dragging != null ? 0.7 : 0),
      );
      _layout.alpha *= 0.972;
    }
    _repaint.tick();

    // 布局停了还在转，只可能是光点在跑；鼠标一离开就停。
    final bool flowing = _mouseInside && (_hover ?? _selected) != null;
    if (settled && !flowing) {
      _ticker.stop();
      _lastTick = Duration.zero;
    }
  }

  // ------------------------------------------------------------------ 设置

  void _onSettings(GraphSettings next) {
    final GraphSettings old = _settings;
    setState(() => _settings = next);

    if (next.scope != old.scope ||
        next.depth != old.depth ||
        next.showOrphans != old.showOrphans) {
      _rebuildView();
      return;
    }
    if (next.nodeScale != old.nodeScale) {
      _applyNodeScale();
      _repaint.tick();
    }
    if (next.linkScale != old.linkScale) {
      _layout.restLength = GraphPhysics.restLength * next.linkScale;
      _heat(0.9);
    }
    if (next.query != old.query ||
        next.folder != old.folder ||
        next.showArrows != old.showArrows) {
      _recomputeLit();
      _repaint.tick();
    }
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final GraphStyle style = GraphStyle.from(p);
    final int? focus = _hover ?? _selected;
    // 色名 → 颜色只在这里解析一次：主题一换，`build` 重跑，颜色跟着换。
    final Map<String, Color> folderColors = _resolveFolderColors(p);

    return ColoredBox(
      color: p.surface,
      child: Column(
        children: <Widget>[
          _header(p),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final Size size = Size(c.maxWidth, c.maxHeight);
                if (size != _stageSize) {
                  _stageSize = size;
                  // 尺寸变了要重新装一次，否则窗口拉大后图还缩在角落。
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    setState(_fitToStage);
                  });
                }
                return _stage(
                  context,
                  p,
                  style,
                  focus,
                  size,
                  folderColors,
                  _groupsOf(p, folderColors),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(AppPalette p) {
    final int notes = _view.nodes.length;
    final int edges = _view.edges.length;
    final bool local = _settings.scope == GraphScope.local;

    return Container(
      height: AppLayout.panelHeaderHeight + 6,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.outlineSoft)),
      ),
      child: Row(
        children: <Widget>[
          SegmentedToggle<GraphScope>(
            value: _settings.scope,
            onChanged: (GraphScope v) =>
                _onSettings(_settings.copyWith(scope: v)),
            items: const <({GraphScope value, IconData icon, String label})>[
              (
                value: GraphScope.global,
                icon: LucideIcons.globe,
                label: '全局',
              ),
              (value: GraphScope.local, icon: LucideIcons.target, label: '局部'),
            ],
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text.rich(
              _metaSpan(p, notes, edges, local),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          AppIconButton(
            icon: LucideIcons.refreshCw,
            tooltip: '重新布局',
            size: 26,
            iconSize: AppIconSize.sm - 2,
            onPressed: _relayout,
          ),        ],
      ),
    );
  }

  TextSpan _metaSpan(AppPalette p, int notes, int edges, bool local) {
    final TextStyle base = TextStyle(
      fontSize: AppText.caption,
      color: p.textTertiary,
    );
    final TextStyle strong = base.copyWith(
      color: p.textSecondary,
      fontWeight: FontWeight.w600,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final List<InlineSpan> spans = <InlineSpan>[];
    void sep() => spans.add(TextSpan(text: '  ·  ', style: base));

    if (local) {
      final String? title = _currentTitle();
      if (title != null) {
        spans
          ..add(TextSpan(text: title, style: strong))
          ..add(TextSpan(text: '  ·  ', style: base));
      }
      spans
        ..add(TextSpan(text: '${_settings.depth}', style: strong))
        ..add(TextSpan(text: ' 跳内', style: base));
      sep();
      spans
        ..add(TextSpan(text: '${math.max(notes - 1, 0)}', style: strong))
        ..add(TextSpan(text: ' 篇笔记', style: base));
    } else {
      spans
        ..add(TextSpan(text: '$notes', style: strong))
        ..add(TextSpan(text: ' 篇笔记', style: base));
    }
    sep();
    spans
      ..add(TextSpan(text: '$edges', style: strong))
      ..add(TextSpan(text: ' 条连接', style: base));
    if (_graph.orphanCount > 0) {
      sep();
      spans
        ..add(TextSpan(text: '${_graph.orphanCount}', style: strong))
        ..add(TextSpan(text: ' 孤立', style: base));
    }
    return TextSpan(children: spans);
  }

  String? _currentTitle() {
    final int? i = _graph.indexOfId(widget.currentId);
    return i == null ? null : _graph.nodes[i].title;
  }

  void _relayout() {
    _layout
      ..seed(_view)
      ..alpha = 0.6;
    _layout.settle(_view, settleTicksFor(_view.nodes.length));
    setState(_fitToStage);
    _repaint.tick();
  }

  Widget _stage(
    BuildContext context,
    AppPalette p,
    GraphStyle style,
    int? focus,
    Size size,
    Map<String, Color> folderColors,
    List<GraphGroup> groups,
  ) {
    final GraphPaintData data = GraphPaintData(
      graph: _view,
      layout: _layout,
      radii: _radii,
      lit: _lit,
      focus: focus,
      selected: _selected,
      arrows: _settings.showArrows,
      style: style,
      folderColors: folderColors,
      scale: _scale,
      offset: _offset,
      textScaler: MediaQuery.textScalerOf(context),
    );

    return Stack(
      key: debugStageKey,
      children: <Widget>[
        Positioned.fill(
          child: MouseRegion(
            onEnter: (_) {
              _mouseInside = true;
              _flow();
            },
            onExit: (_) {
              _mouseInside = false;
              _clearHover();
            },
            child: GestureDetector(
              onDoubleTapDown: (TapDownDetails d) {
                final int? hit = _nodeAt(d.localPosition);
                if (hit != null) widget.onOpenNote(_view.nodes[hit].id);
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: _onPointerDown,
                onPointerMove: _onPointerMove,
                onPointerUp: _onPointerUp,
                onPointerCancel: _onPointerUp,
                onPointerSignal: _onPointerSignal,
                child: CustomPaint(
                  painter: GraphPainter(
                    data: data,
                    labels: _labels,
                    clock: _clock,
                    repaint: _repaint,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
        if (_view.isEmpty) Positioned.fill(child: _emptyState(p)),
        if (_view.isNotEmpty && _view.edges.isEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: AppSpace.md,
            child: _hintPill(p),
          ),
        Positioned(
          left: AppSpace.md,
          top: AppSpace.md,
          child: GraphPanel(
            settings: _settings,
            onChanged: _onSettings,
            visibleCount: _view.nodes.length,
            localCount: _settings.scope == GraphScope.local
                ? _view.nodes.length
                : 0,
            currentTitle: _currentTitle(),
            collapsed: _panelCollapsed,
            onToggleCollapsed: () =>
                setState(() => _panelCollapsed = !_panelCollapsed),
          ),
        ),
        if (_view.isNotEmpty)
          Positioned(
            left: AppSpace.md,
            bottom: AppSpace.md,
            child: GraphLegend(
              groups: groups,
              selected: _settings.folder,
              onSelect: (String? f) =>
                  _onSettings(_settings.copyWith(folder: f)),
            ),
          ),
        Positioned(right: AppSpace.md, bottom: AppSpace.md, child: _hud(p)),
        if (_hover != null && _dragging == null)
          _tooltip(p, _view.nodes[_hover!], folderColors),
      ],
    );
  }

  Widget _hud(AppPalette p) {
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
          _HudButton(
            icon: LucideIcons.minus,
            tooltip: '缩小',
            onPressed: () => setState(
              () => _zoomAt(
                Offset(_stageSize.width / 2, _stageSize.height / 2),
                1 / 1.22,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${(_scale * 100).round()}%',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppText.caption - 1,
                color: p.textTertiary,
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          _HudButton(
            icon: LucideIcons.plus,
            tooltip: '放大',
            onPressed: () => setState(
              () => _zoomAt(
                Offset(_stageSize.width / 2, _stageSize.height / 2),
                1.22,
              ),
            ),
          ),
          Container(width: 1, height: 14, color: p.outline),
          _HudButton(
            icon: LucideIcons.maximize,
            tooltip: '适应窗口',
            onPressed: () => setState(() => _fitToStage()),
          ),
        ],
      ),
    );
  }

  /// 这张图为什么空——三种空法，三句话。
  ///
  /// 有笔记但一条边都没有时节点是散落的点，看着像坏了，所以也要给一句。
  String _hintText() {
    if (widget.notes.isEmpty) {
      return '还没有笔记。\n写一篇，用 [[双链]] 连到别处，\n这里就会长出一张图。';
    }
    if (_settings.scope == GraphScope.local) {
      return _currentTitle() == null
          ? '没有选中的笔记。\n切到「全局」看看整张图。'
          : '这篇笔记还没有双链。\n在正文里写 [[另一篇的标题]]，\n它就会连到别处。';
    }
    return '这些笔记之间还没有双链。\n在正文里写 [[另一篇的标题]]，\n它们之间就会连上线。';
  }

  TextStyle _hintStyle(AppPalette p) => TextStyle(
    fontSize: AppText.label,
    height: 1.8,
    color: p.textTertiary,
  );

  /// 一个节点都没有：整块画布正中给提示。
  Widget _emptyState(AppPalette p) {
    return IgnorePointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text(
            _hintText(),
            textAlign: TextAlign.center,
            style: _hintStyle(p),
          ),
        ),
      ),
    );
  }

  /// 有节点但没连线：别挡住那些点，压到底部中间说一句。
  Widget _hintPill(AppPalette p) {
    return IgnorePointer(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: AppSpace.md),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            decoration: BoxDecoration(
              color: p.sidebar.withValues(alpha: 0.86),
              borderRadius: AppRadius.mdAll,
              border: Border.all(color: p.outlineSoft),
            ),
            child: Text(
              _hintText(),
              textAlign: TextAlign.center,
              style: _hintStyle(p).copyWith(fontSize: AppText.caption),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tooltip(AppPalette p, GraphNode node, Map<String, Color> colors) {
    const double w = 216;
    final double left = (_pointer.dx + 16).clamp(
      8.0,
      math.max(8.0, _stageSize.width - w - 8),
    );
    final double top = (_pointer.dy + 16).clamp(
      8.0,
      math.max(8.0, _stageSize.height - 84),
    );
    final Color dot = colors[node.folder] ?? p.textSecondary;

    return Positioned(
      left: left,
      top: top,
      child: IgnorePointer(
        child: Container(
          constraints: const BoxConstraints(maxWidth: w),
          padding: const EdgeInsets.fromLTRB(
            AppSpace.sm + 2,
            AppSpace.sm,
            AppSpace.sm + 2,
            AppSpace.sm,
          ),
          decoration: BoxDecoration(
            color: p.surfaceRaised,
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: p.outline),
            boxShadow: <BoxShadow>[
              BoxShadow(color: p.shadow, blurRadius: 16, offset: const Offset(0, 6)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                node.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppText.label,
                  fontWeight: FontWeight.w600,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                children: <Widget>[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 5),
                  // 文件夹名可能很长，让它先让位，度数永远看得见。
                  Flexible(
                    child: Text(
                      node.folder.isEmpty ? '根目录' : node.folder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppText.caption - 1,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '出 ${node.outDegree} · 入 ${node.inDegree}',
                    style: TextStyle(
                      fontSize: AppText.caption - 1,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
              if (node.tags.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final String tag in node.tags.take(4))
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: p.surfaceSunken,
                          borderRadius: BorderRadius.circular(AppRadius.xs),
                        ),
                        child: Text(
                          '#$tag',
                          style: TextStyle(
                            fontSize: AppText.caption - 1,
                            color: p.textTertiary,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 指针

  void _onPointerDown(PointerDownEvent e) {
    final int? hit = _nodeAt(e.localPosition);
    if (hit != null) {
      setState(() {
        _selected = hit;
        _dragging = hit;
        _dragMoved = false;
        _hover = hit;
      });
      _flow();
      return;
    }
    _panFrom = e.localPosition;
    _panStart = _offset;
    _panned = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_dragging != null) {
      _dragMoved = true;
      final Offset world = _toWorld(e.localPosition);
      _layout
        ..x[_dragging!] = world.dx
        ..y[_dragging!] = world.dy
        ..vx[_dragging!] = 0
        ..vy[_dragging!] = 0;
      _heat(0.55);
      _repaint.tick();
      return;
    }
    if (_panFrom != null) {
      final Offset delta = e.localPosition - _panFrom!;
      if (delta.distance > 3) _panned = true;
      if (_panned) {
        setState(() => _offset = _panStart + delta);
      }
      return;
    }
    final int? hit = _nodeAt(e.localPosition);
    if (hit != _hover) {
      setState(() {
        _hover = hit;
        _pointer = e.localPosition;
      });
      _flow();
    } else if (hit != null) {
      setState(() => _pointer = e.localPosition);
    }
  }

  void _onPointerUp(PointerEvent e) {
    if (_dragging != null) {
      setState(() => _dragging = null);
      // 只有真的拖过才回弹：单击选中不该让整张图抖一下。
      if (_dragMoved) _heat(0.45);
      _dragMoved = false;
      return;
    }
    if (_panFrom != null && !_panned) {
      setState(() => _selected = null);
    }
    _panFrom = null;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final Offset local = e.localPosition;
    setState(() => _zoomAt(local, math.exp(-e.scrollDelta.dy * 0.0016)));
  }

  /// 把指针移出画布时清掉悬停——否则气泡会挂在那儿不动。
  void _clearHover() {
    if (_hover == null) return;
    setState(() => _hover = null);
  }

  // ------------------------------------------------------- 测试用只读快照

  /// 画了几个节点。
  @visibleForTesting
  int get debugNodeCount => _view.nodes.length;

  /// 有几条边。
  @visibleForTesting
  int get debugEdgeCount => _view.edges.length;

  /// 通过筛选的节点数（其余淡到 16%）。
  @visibleForTesting
  int get debugLitCount => _lit.where((bool b) => b).length;

  @visibleForTesting
  int? get debugSelected => _selected;

  /// 画布（不含顶部那一行）的 key。测试用它把节点坐标换算成屏幕坐标。
  @visibleForTesting
  final GlobalKey debugStageKey = GlobalKey();

  /// 某个节点在画布内的坐标；不在当前视图里返回 `null`。
  ///
  /// `CustomPainter` 画的东西不进语义树，点不到也 find 不到，所以测试只能
  /// 拿到坐标再 `tapAt`。
  @visibleForTesting
  Offset? debugNodeCenter(String noteId) {
    final int? i = _view.indexOfId(noteId);
    if (i == null) return null;
    return Offset(_layout.x[i], _layout.y[i]) * _scale + _offset;
  }

  @visibleForTesting
  GraphSettings get debugSettings => _settings;
}

/// 一个能被 `CustomPainter` 订阅的重绘信号。
///
/// 每帧 `setState` 会把整个子树重建一遍；布局推进只需要「重画」，不需要
/// 「重建」，所以用 [ChangeNotifier] 直接敲 painter。
class _Repaint extends ChangeNotifier {
  void tick() => notifyListeners();
}

class _HudButton extends StatelessWidget {
  const _HudButton({
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
