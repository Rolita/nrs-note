import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/note_graph.dart';
import '../../core/utils/table_model.dart' show CellColorToken;
import '../../data/models/note.dart';
import '../common/app_widgets.dart';
import 'graph_legend.dart';
import 'graph_panel.dart';
import 'graph_style.dart';
import 'orb_layout.dart';
import 'orb_math.dart';
import 'orb_painter.dart';

/// 关系图谱：球面上的点云。
///
/// 每篇笔记是单位球面上的一个点，同一个顶层文件夹的笔记聚成一片「大陆」。
/// 立体感来自三件事，都不需要画一个球：
///
/// * **N·L 光照**。节点方向本身就是球面法线，与一个固定光源点乘得到明暗。
///   球转起来光斑不动，立体感立刻成立——这是最关键的一招。
/// * **透视近大远小**。相机在 5.4 倍半径处，前后差约 1.5 倍。
/// * **深度雾**。远端压暗压小，近端全亮。
///
/// ## 三条改之前要读的约束
///
/// 1. **明暗只走 alpha，不走颜色**。把颜色乘一个亮度系数会同时把饱和度压掉，
///    五百颗点会糊成一片灰蓝，文件夹的颜色完全分不出来。
/// 2. **球体边缘要压暗**。投影把边缘的点压缩到几像素里，密度是中心的 3~5 倍；
///    同亮度的话边缘会比中心还亮，球就变成一圈发光的环。
/// 3. **静止时自转，但测试里必须能停**。`pumpAndSettle` 会一直等「没有下一帧」，
///    常驻动画会让所有测试挂住，所以只在非测试环境开自转。
class GraphView extends StatefulWidget {
  const GraphView({
    super.key,
    required this.notes,
    required this.currentId,
    required this.onOpenNote,
  });

  /// 全库笔记。由外壳传进来，图谱自己不碰 controller，测试才好写。
  final List<Note> notes;

  /// 当前笔记的 id。局部图谱以它为心。
  final String? currentId;

  /// 单击某个节点：打开那篇笔记。
  final ValueChanged<String> onOpenNote;

  @override
  State<GraphView> createState() => GraphViewState();
}

class GraphViewState extends State<GraphView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _Repaint _repaint = _Repaint();
  final OrbLabelCache _labels = OrbLabelCache();
  final OrbCamera _camera = OrbCamera();

  /// 每种文件夹色一张预渲染的辉光贴图。
  ///
  /// 绝不用 `MaskFilter.blur` 逐点画：那是最贵的绘制路径，五百颗点会把帧率
  /// 直接打到个位数。预渲染一张 64×64 的径向渐变，之后只是缩放贴图。
  final Map<Color, ui.Image> _glow = <Color, ui.Image>{};

  /// 全库的图，建一次。
  NoteGraph _graph = NoteGraph.empty();

  /// 当前画的这张（全局，或局部子图）。
  NoteGraph _view = NoteGraph.empty();

  /// 全库的球面布局。局部视图靠它继承位置。
  OrbLayout _globalLayout = OrbLayout(0);

  OrbLayout _layout = OrbLayout(0);

  // ---- 投影缓冲。每帧原地写，不重新分配 ----
  Float32List _sx = Float32List(0);
  Float32List _sy = Float32List(0);
  Float32List _scl = Float32List(0);
  Float32List _dep = Float32List(0);
  Float32List _camX = Float32List(0);
  Float32List _camY = Float32List(0);
  Float32List _camZ = Float32List(0);

  /// 世界半径（相对球半径的比例，已含「节点大小」）。**只读**，不要拿它
  /// 当屏幕半径用——投影会把屏幕半径写进 [_radii]。
  Float32List _worldRadii = Float32List(0);

  /// 屏幕半径（逻辑像素）。绘制和命中测试都读它。
  Float32List _radii = Float32List(0);
  Float32List _alphas = Float32List(0);
  List<int> _order = <int>[];

  /// 每个节点是否通过筛选（没通过就压淡，不删）。
  List<bool> _lit = <bool>[];

  /// 文件夹 → 色名。存色名不存色值：建图在 `initState` 里发生，那时读不到
  /// `Theme`，而浅色/深色主题要解析成两组不同的色值。
  Map<String, CellColorToken> _folderTokens = <String, CellColorToken>{};
  Map<String, int> _folderCounts = <String, int>{};

  GraphSettings _settings = const GraphSettings();
  bool _panelCollapsed = false;

  /// 鼠标停在哪个节点上。**这就是「选中」**——和 Obsidian 一样，悬浮即高亮，
  /// 不需要先点一下再高亮。
  int? _hover;

  /// 被钉住的节点：悬浮它的时候屏幕位置冻结，球照样漂。
  ///
  /// 球是刚体，正常情况下所有点一起转。要让一颗点「不动」，只能把它的
  /// **相机空间方向**在钉住那一刻抄下来，之后每帧都用这份旧值投影——它就
  /// 停在原地，连向它的边会跟着周围的点在它周围拉长。
  int? _pinNode;
  final Float64List _pinCam = Float64List(3);

  /// 1 = 完全钉住，0 = 已经放回球面。
  ///
  /// 鼠标移开时不能立刻松手：漂了 3 秒再移开，点会「啪」地跳回去十几度。
  /// 用 200ms 淡出，看着就像它自己滑回了队伍里。
  double _pinFade = 0;

  /// 转速倍率。悬浮节点时降到 0.35，离开再回到 1。
  ///
  /// 走指数逼近而不是直接切换：直接切，松手后一悬停，整个球会「咔」地
  /// 掉速，比匀速还难看。
  double _slow = 1;

  /// 高亮的浓度：0 = 没有焦点，1 = 完全聚焦。
  ///
  /// 悬浮时其余节点从「正常」压到 0.55 倍。这一下如果是硬切，鼠标扫过
  /// 画布就是一路闪。用 180ms 线性过渡（线性才能**精确**到达 0 和 1，
  /// 指数逼近永远差一点，测试里会永远等不到静止）。
  double _focusFade = 0;

  // ---- 相机与指针状态 ----
  double _velX = 0;
  double _velY = 0;
  double _idle = 0;
  double _clock = 0;
  double _scale = 1;
  Size _stageSize = Size.zero;

  int? _dragNode;
  bool _dragMoved = false;

  /// 按下的位置。判断「这是拖动还是单击」要看累计位移——看单帧增量的话，
  /// 慢慢挪 5 像素（每帧都不到 0.5）会被当成单击，松手就跳去打开笔记。
  Offset _dragOrigin = Offset.zero;

  Offset? _rotateFrom;
  Offset? _rotateLast;
  bool _rotated = false;
  Offset _pointer = Offset.zero;

  // ---- 拖拽时把邻居拨开 ----
  //
  // 位移存的是**世界空间的偏移**：画的时候加回坐标再归一化回球面，所以它
  // 永远是「沿球面滑动」，不会把点推进球里。真实位置（`_layout.px` 等）不动，
  // 松手后把 [_pushFade] 收到 0，邻居就弹回原位。
  Float32List _pushX = Float32List(0);
  Float32List _pushY = Float32List(0);
  Float32List _pushZ = Float32List(0);

  /// 0 = 没有形变，1 = 完全推开。线性收放，两端精确落在 0 / 1。
  double _pushFade = 0;

  /// 拨开范围（球面弦长）与最大位移量，按球的密度算，见 [_updatePushSpan]。
  double _pushRadius = 0;
  double _pushAmount = 0;

  /// 上一次建图时笔记的指纹。
  int _signature = 0;

  /// 是否允许空闲自转。测试里必须关掉，否则 `pumpAndSettle` 永远等不到头。
  late final bool _drift;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _drift = !WidgetsBinding.instance.runtimeType.toString().contains('Test');
    _signature = _signatureOf(widget.notes);
    _rebuildAll();
    if (_drift) _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureGlowSprites();
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
    _labels.clear();
    for (final ui.Image img in _glow.values) {
      img.dispose();
    }
    super.dispose();
  }

  // ------------------------------------------------------------------ 建图

  /// 笔记列表的指纹。
  ///
  /// `allNotes` 每次调用都返回一个新 List，比身份永远不相等——那样每次
  /// build 都会重建整张图。所以比内容。
  static int _signatureOf(List<Note> notes) {
    int h = notes.length;
    for (final Note n in notes) {
      h = h * 31 + n.id.hashCode;
      h = h * 31 + n.updatedAt.millisecondsSinceEpoch;
    }
    return h;
  }

  void _rebuildAll() {
    _graph = buildNoteGraph(widget.notes);
    _globalLayout = OrbLayout(_graph.nodes.length);
    _globalLayout.seed(_graph);
    // 大图少迭代几轮：全对全是 O(n²)，859 篇时每轮 37 万对。
    _globalLayout.relax(_graph, iterations: _graph.nodes.length > 420 ? 14 : 26);
    _orientToLargestCluster();
    _rebuildView();
  }

  /// 首次进入把节点最多的文件夹转到正面。
  ///
  /// 球心正好落在两片大陆之间的空隙上时，第一眼是一团空的，用户会以为
  /// 图谱坏了。目标方向刻意偏一点——完全正对会把球压平。
  void _orientToLargestCluster() {
    if (_graph.isEmpty) return;
    final OrbPoint c = _globalLayout.largestClusterCentre(_graph);
    const double tx = 0.17, ty = -0.13, tz = 0.976;
    final double tl = math.sqrt(tx * tx + ty * ty + tz * tz);
    _camera.alignTo(c.x, c.y, c.z, tx / tl, ty / tl, tz / tl);
  }

  void _rebuildView() {
    // 换了子图，下标就是另一批笔记了：悬停、钉住、手上正在拖的，都必须清掉，
    // 否则会指着别的节点（甚至越界）。
    _hover = null;
    _pinNode = null;
    _pinFade = 0;
    _dragNode = null;
    _dragMoved = false;
    _pushFade = 0;
    if (_graph.isEmpty) {
      _view = _graph;
      _layout = OrbLayout(0);
      _allocBuffers();
      _updateGroups();
      _recomputeLit();
      return;
    }

    NoteGraph base = _graph;
    OrbLayout baseLayout = _globalLayout;

    // 局部图谱：切子图，但**位置从全局继承**。重新撒点会让整张图跳一下，
    // 读者会以为换了一张图。
    if (_settings.scope == GraphScope.local) {
      final int? centre = _graph.indexOfId(widget.currentId);
      if (centre == null) {
        _view = NoteGraph.empty();
        _layout = OrbLayout(0);
        _allocBuffers();
        _updateGroups();
        _recomputeLit();
        return;
      }
      final Set<int> keep = _graph.neighbourhood(centre, _settings.depth);
      final (NoteGraph g, OrbLayout l) = _slice(_graph, _globalLayout, keep);
      base = g;
      baseLayout = l;
    }

    // 隐藏孤立笔记：同样保留位置，只是把它们从图里摘掉。
    if (!_settings.showOrphans) {
      final Set<int> keep = <int>{
        for (final GraphNode n in base.nodes)
          if (!n.isOrphan) n.index,
      };
      if (keep.length != base.nodes.length) {
        final (NoteGraph g, OrbLayout l) = _slice(base, baseLayout, keep);
        base = g;
        baseLayout = l;
      }
    }

    _view = base;
    _layout = baseLayout;
    _allocBuffers();
    _updateGroups();
    _recomputeLit();
  }

  /// 按 [keep] 切子图，并把位置一起搬过来。
  ///
  /// 单独写是因为「切图」和「保住位置」必须同时发生：只切图会让节点重新编号，
  /// 位置对不上，球上会瞬间重排。
  (NoteGraph, OrbLayout) _slice(NoteGraph from, OrbLayout fromLayout, Set<int> keep) {
    final NoteGraph sub = from.subgraph(keep);
    final OrbLayout layout = OrbLayout(sub.nodes.length);
    for (int k = 0; k < sub.nodes.length; k++) {
      final int? src = from.indexOfId(sub.nodes[k].id);
      if (src == null) continue;
      layout.px[k] = fromLayout.px[src];
      layout.py[k] = fromLayout.py[src];
      layout.pz[k] = fromLayout.pz[src];
    }
    return (sub, layout);
  }

  void _allocBuffers() {
    final int n = _view.nodes.length;
    if (_sx.length == n) {
      _recomputeRadii();
      _updatePushSpan(n);
      return;
    }
    _sx = Float32List(n);
    _sy = Float32List(n);
    _scl = Float32List(n);
    _dep = Float32List(n);
    _camX = Float32List(n);
    _camY = Float32List(n);
    _camZ = Float32List(n);
    _worldRadii = Float32List(n);
    _radii = Float32List(n);
    _alphas = Float32List(n);
    _pushX = Float32List(n);
    _pushY = Float32List(n);
    _pushZ = Float32List(n);
    _order = List<int>.generate(n, (int i) => i);
    _recomputeRadii();
    _updatePushSpan(n);
  }

  /// 「拨开邻居」的范围与力度，跟着球的密度走。
  ///
  /// 球面平均间距是 `sqrt(4π/n)`：520 个点是 0.156，20 个点是 0.79。固定一个
  /// 半径的话，稀疏的图上根本碰不到任何人（看起来像没生效），密集的图上又会
  /// 一次推开半个球。取 1.5 倍间距，正好覆盖最近的几圈。
  void _updatePushSpan(int n) {
    if (n < 2) {
      _pushRadius = 0;
      _pushAmount = 0;
      return;
    }
    _pushRadius = (math.sqrt(4 * math.pi / n) * 1.5).clamp(0.16, 0.75);
    // 力度取半径的 0.85 倍。落在一个平均间距上的邻居会被推开大约半个间距
    // ——洞开得出来，但整片大陆不会被推散。520 篇的库上大约是 15px 的位移。
    _pushAmount = _pushRadius * 0.85;
  }

  /// 节点屏幕半径：按度数的幂次拉开差距，枢纽才有存在感。
  void _recomputeRadii() {
    for (int i = 0; i < _view.nodes.length; i++) {
      final double deg = math.max(_view.nodes[i].degree, 1).toDouble();
      final double world = 0.0060 + 0.0042 * math.pow(deg, 0.62);
      _worldRadii[i] = math.min(world, 0.0300) * _settings.nodeScale;
    }
  }

  void _updateGroups() {
    _folderCounts = <String, int>{};
    for (final GraphNode n in _graph.nodes) {
      _folderCounts[n.folder] = (_folderCounts[n.folder] ?? 0) + 1;
    }
    _folderTokens = assignFolderTokens(_folderCounts.keys);
  }

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

  /// 搜索 / 文件夹筛选：只算「谁该亮」，不动图。
  void _recomputeLit() {
    final String q = _settings.query.trim().toLowerCase();
    _lit = List<bool>.generate(_view.nodes.length, (int i) {
      final GraphNode n = _view.nodes[i];
      if (_settings.folder != null && n.folder != _settings.folder) return false;
      if (q.isEmpty) return true;
      if (n.title.toLowerCase().contains(q)) return true;
      for (final String t in n.tags) {
        if (t.toLowerCase().contains(q)) return true;
      }
      return false;
    });
  }

  // ------------------------------------------------------------------ 投影

  /// 相机到球心的距离，以球半径为单位。
  ///
  /// 5.4 是调出来的：更近边缘会被拉得很夸张，更远就没有前后差了。
  static const double _camDistance = 5.4;

  /// 球半径占短边的比例。
  ///
  /// 0.30 留出的余量是给**标签**的，不是给球的：球本身只占 2×0.30 = 60% 的
  /// 短边，但贴在球顶/球底的标签还要往上/下再走十几个像素，加上缩放上限
  /// 2.6 倍，太满就会把标签推出画布。
  static const double _radiusRatio = 0.30;

  double get _sphereRadius => math.min(_stageSize.width, _stageSize.height) * _radiusRatio;

  /// 算一遍投影 + 每帧的亮度。命中测试和绘制共用这批结果。
  void _project() {
    final int n = _view.nodes.length;
    if (n == 0) return;

    final Float64List m = _camera.matrix;
    final double radius = _sphereRadius;
    final double cx = _stageSize.width / 2;
    final double cy = _stageSize.height / 2;

    _updatePin();

    // 拖拽时邻居被拨开：位移加回坐标再归一化，点仍然贴在球面上。
    final double pf = _pushFade;
    final bool pushing = pf > 0;

    for (int i = 0; i < n; i++) {
      double x = _layout.px[i], y = _layout.py[i], z = _layout.pz[i];
      if (pushing) {
        x += _pushX[i] * pf;
        y += _pushY[i] * pf;
        z += _pushZ[i] * pf;
        final double len = math.sqrt(x * x + y * y + z * z);
        if (len > 1e-9) {
          x /= len;
          y /= len;
          z /= len;
        }
      }
      double X = m[0] * x + m[1] * y + m[2] * z;
      double Y = m[3] * x + m[4] * y + m[5] * z;
      double Z = m[6] * x + m[7] * y + m[8] * z;
      if (i == _pinNode) {
        // 钉住的点不跟着球转：用钉住那一刻的方向，屏幕位置就冻住了。
        if (_pinFade >= 1) {
          X = _pinCam[0];
          Y = _pinCam[1];
          Z = _pinCam[2];
        } else {
          // 淡出：在「该在的位置」和「冻住的位置」之间插值。两个都是单位
          // 向量，线性插值后归一化就是球面上那条短弧。
          double bx = X + (_pinCam[0] - X) * _pinFade;
          double by = Y + (_pinCam[1] - Y) * _pinFade;
          double bz = Z + (_pinCam[2] - Z) * _pinFade;
          final double len = math.sqrt(bx * bx + by * by + bz * bz);
          if (len > 1e-6) {
            bx /= len;
            by /= len;
            bz /= len;
          }
          X = bx;
          Y = by;
          Z = bz;
        }
      }
      _camX[i] = X;
      _camY[i] = Y;
      _camZ[i] = Z;

      final double proj = _camDistance / (_camDistance - Z);
      _scl[i] = proj * _scale;
      _sx[i] = cx + X * radius * proj * _scale;
      _sy[i] = cy - Y * radius * proj * _scale;
      _dep[i] = (Z + 1) * 0.5;
    }

    _sortByDepth();
    _computeAlpha(radius);
  }

  /// 决定这一帧谁被钉住。
  ///
  /// 只在「鼠标停着、没在拖、没在转」的时候钉：用户主动转球时把点拽住不放
  /// 会像卡住了一样；拖节点本身也在动，更不能钉。
  void _updatePin() {
    final int? want = (_hover != null && _dragNode == null && _rotateFrom == null)
        ? _hover
        : null;
    // 松手后的淡出由 [_fadePin] 管，这里只管「钉上去」。
    if (want == null) return;
    if (_pinNode == want && _pinFade >= 1) return;
    // 刚钉上（或换了一个点）：抄下它这一帧的相机空间方向。这一帧还没转，
    // 所以抄到的就是屏幕上看到的那个位置，不会跳。
    _pinNode = want;
    _pinFade = 1;
    _pinCam[0] = _camX[want];
    _pinCam[1] = _camY[want];
    _pinCam[2] = _camZ[want];
  }

  /// 钉住 / 放回。每帧调一次，放在 [_step] 最前面——转球的时候也必须能
  /// 放回去，不然球一转，那颗点就永远悬在屏幕中间。
  void _fadePin(double dt) {
    if (_pinNode == null) return;
    final bool wanted =
        _hover == _pinNode && _dragNode == null && _rotateFrom == null;
    if (wanted) {
      _pinFade = 1;
      return;
    }
    _pinFade -= dt / 0.20;
    if (_pinFade <= 0) {
      _pinFade = 0;
      _pinNode = null;
    }
  }

  /// 高亮浓度过渡。线性 180ms，两端都能精确落到 0 / 1。
  void _fadeFocus(double dt) {
    final double want = _hover != null ? 1 : 0;
    if (_focusFade == want) return;
    _focusFade = (_focusFade + (want > _focusFade ? dt : -dt) / 0.18)
        .clamp(0.0, 1.0);
  }

  /// 推开的浓度。线性：起手 90ms 铺开，松手 260ms 收回，两端都精确落在 0/1。
  ///
  /// 收回比起手慢：邻居「让开」应该是被拨开的，回位应该是自己滑回去的。
  void _fadePush(double dt) {
    final double want = (_dragNode != null && _dragMoved) ? 1 : 0;
    if (_pushFade == want) return;
    final double dur = want > _pushFade ? 0.09 : 0.26;
    _pushFade = (_pushFade + (want > _pushFade ? dt : -dt) / dur)
        .clamp(0.0, 1.0);
  }

  void _sortByDepth() {
    final int n = _view.nodes.length;
    for (int i = 0; i < n; i++) {
      _order[i] = i;
    }
    // 远 → 近。TypedData 没有 sort，用 List<int> 就够：520 个元素每帧
    // 排一次是几十微秒。
    _order.sort((int a, int b) => _dep[a].compareTo(_dep[b]));
  }

  /// 每颗点的最终不透明度。
  ///
  /// 明暗全部走这个通道。颜色只负责「这是哪个文件夹」，绝不参与明暗——
  /// 一旦把颜色乘上亮度，饱和度会跟着掉，整张图糊成一片灰。
  void _computeAlpha(double radius) {
    final int n = _view.nodes.length;
    final int? hi = _hover;
    final double f = _focusFade;
    final List<int>? related = hi == null ? null : _view.nodes[hi].neighbours;

    // 光源固定在左上偏前。球转的时候光斑不动，这是立体感的主要来源。
    const double lx = -0.4175, ly = -0.5468, lz = 0.7257;

    for (int i = 0; i < n; i++) {
      final double ndl = _camX[i] * lx + _camY[i] * ly + _camZ[i] * lz;
      final double lit = 0.56 + 0.44 * math.pow(ndl < 0 ? 0 : ndl, 0.85);

      final double d = _dep[i];
      // 边缘压暗：投影压缩让边缘天然更密，同亮度会糊成一圈比中心还亮的环。
      final double edge = 0.66 + 0.34 * ((d - 0.42) / 0.50).clamp(0.0, 1.0);
      final double base = (0.32 + 0.68 * math.pow(d, 1.15)) * lit * edge;
      double a = base;

      if (!_lit[i]) {
        a = base * 0.14;
      } else if (hi != null && f > 0) {
        // 焦点态不是「切过去」，而是从常态**插值**过去：鼠标扫过画布时，
        // 整颗球会跟着一暗一亮，硬切就是一路闪。
        double target;
        if (i == hi) {
          target = 1;
        } else if (related!.contains(i)) {
          target = math.min(1, base * 1.2 + 0.34);
        } else {
          // 压到 0.55 而不是 0.40：压得太狠，扫一下就像在闪。
          target = base * 0.55;
        }
        a = base + (target - base) * f;
      }
      _alphas[i] = a;

      // 半径在这里落地：世界半径 × 球半径 × 透视缩放。
      double r = _worldRadii[i] * radius * _scl[i];
      if (hi != null && f > 0) {
        if (i == hi) {
          r *= 1 + 0.5 * f;
        } else if (related!.contains(i)) {
          r *= 1 + 0.14 * f;
        }
      }
      _radii[i] = math.max(r, 1.6);
    }
  }

  // ------------------------------------------------------------------ 动画

  void _onTick(Duration elapsed) {
    final double dt;
    if (_firstTick) {
      _firstTick = false;
      dt = 0.016;
    } else {
      // 窗口被拖动、系统挂起之后 dt 可能很大，钳一下——不然球会瞬移。
      dt = ((elapsed - _lastElapsed).inMicroseconds / 1e6).clamp(0.0, 0.05);
    }
    _lastElapsed = elapsed;
    _step(dt);
    _project();
    _repaint.tick();

    // 测试环境不自转，所以「静止」是可以到达的状态——到了就停表，
    // 否则 pumpAndSettle 会一直等下一帧。
    if (!_drift && _isResting) _ticker.stop();
  }

  Duration _lastElapsed = Duration.zero;
  bool _firstTick = true;

  bool get _isResting =>
      _dragNode == null &&
      _rotateFrom == null &&
      // 淡出中间不能停表，否则那颗点会僵在半路上。钉住（=1）本身不需要
      // 帧——它就是一帧一帧抄旧值。
      (_pinFade <= 0 || _pinFade >= 1) &&
      // 高亮的过渡同理：停在半路，整张图就一直是「压了一半」的样子。
      (_focusFade <= 0 || _focusFade >= 1) &&
      // 拨开的邻居也一样：停在半路，它们就永远歪在那儿回不去。
      (_pushFade <= 0 || _pushFade >= 1) &&
      _velX.abs() < 0.004 &&
      _velY.abs() < 0.004;

  void _step(double dt) {
    _clock += dt;
    _idle += dt;
    _fadePin(dt);
    _fadeFocus(dt);
    _fadePush(dt);

    // 拖节点：不转球，只跟手 + 拨开邻居。必须每帧跑——拖到球体边缘时球
    // 自己在转，光靠 pointermove 是纠不回来的（鼠标不动，球还在转）。
    if (_dragNode != null) {
      _stepDrag(dt);
      return;
    }

    if (_rotateFrom != null) return;

    if (_drift && _idle > 1.4) {
      // 漂浮：低频噪声驱动目标角速度。三层正弦叠起来，看起来像悬浮物在
      // 慢慢漂，而不是匀速自转——匀速会像加载动画。
      final double t = _clock * 0.135;
      final double tgtY =
          0.115 + 0.052 * math.sin(t * 1.7) + 0.026 * math.sin(t * 3.13 + 1.2);
      final double tgtX =
          0.020 * math.sin(t * 1.13 + 0.7) + 0.014 * math.sin(t * 2.41 + 2.1);
      final double k = 1 - math.exp(-dt * 0.85);
      _velY += (tgtY - _velY) * k;
      _velX += (tgtX - _velX) * k;
    } else {
      // 松手后的惯性衰减。
      final double damp = math.exp(-dt * 2.6);
      _velX *= damp;
      _velY *= damp;
    }

    // 悬浮在某个节点上时把转速压下来：那颗点已经钉住了，周围再飞快地流过
    // 去会让人读不清它和邻居的关系。0.35 是「明显变慢、但还看得出在动」。
    final double wantSlow = _hover != null ? 0.35 : 1;
    _slow += (wantSlow - _slow) * (1 - math.exp(-dt * 6));
    _camera.rotate(_velX * dt * _slow, _velY * dt * _slow);
  }

  // ------------------------------------------------------------- 拖拽手感

  /// 拖拽的三件事，顺序有讲究：先把节点拉到光标，再看要不要转球，转完
  /// 立刻再拉一次——不然球一转，节点会落在光标后面，而且永远追不上。
  void _stepDrag(double dt) {
    if (!_dragMoved) return;
    // 拖了很久之后松手，球不该立刻开始自转——刚放下的东西要先稳住。
    _idle = 0;
    _applyDrag();
    _autoTurn(dt);
    _applyDrag();
    _pushAside(_dragNode!);
  }

  /// 一个节点当前在屏幕上的位置、透视缩放，以及相机空间坐标。
  ///
  /// 拖拽只关心被拖的那一个点，没必要走整张图的 [_project]（它还带排序和
  /// 高亮）。更要紧的是：球自转的那几帧里 [_sx] 还是转之前的值，拿它算
  /// 「误差」会永远差一步，节点就永远追不上光标。
  ({double sx, double sy, double scl, double x, double y}) _screenOf(int i) {
    final Float64List m = _camera.matrix;
    final double px = _layout.px[i], py = _layout.py[i], pz = _layout.pz[i];
    final double X = m[0] * px + m[1] * py + m[2] * pz;
    final double Y = m[3] * px + m[4] * py + m[5] * pz;
    final double Z = m[6] * px + m[7] * py + m[8] * pz;
    final double scl = _camDistance / (_camDistance - Z) * _scale;
    return (
      sx: _stageSize.width / 2 + X * _sphereRadius * scl,
      sy: _stageSize.height / 2 - Y * _sphereRadius * scl,
      scl: scl,
      x: X,
      y: Y,
    );
  }

  /// 把节点拉回光标。
  ///
  /// 用的是「误差」而不是「增量」：每帧算 `光标 − 节点当前屏幕位置` 再修正。
  /// 增量写法一旦相机同时在动（[_autoTurn]），误差就会一帧一帧攒下去。
  /// 这个修正本身是幂等的——节点已经在光标上就什么都不做，所以一帧里多调
  /// 几次也没有副作用。
  void _applyDrag() {
    if (!_dragMoved) return;
    final int i = _dragNode!;
    final double radius = _sphereRadius;
    if (radius <= 0) return;

    // 透视投影不是线性的：像素 → 弧度那个换算只在当前位置成立，走完一大步
    // 之后同样的像素对应的是另一个角度。只修一次会剩下几个百分点，快拖时
    // 节点就明显掉在光标后面。迭代到亚像素。
    double last = double.infinity;
    for (int it = 0; it < 4; it++) {
      final s = _screenOf(i);
      final double ex = _pointer.dx - s.sx;
      final double ey = _pointer.dy - s.sy;
      final double e = ex.abs() + ey.abs();
      // 死区：亚像素的来回修正是纯抖动。
      if (e <= 0.75) return;
      // 够不着了（光标在轮廓之外）：误差不再下降，再推只会把节点绕到背面
      // 去。剩下的交给 [_autoTurn]——让球在指下滚。
      if (e >= last - 0.25) return;
      last = e;
      _layout.dragNode(i, _camera, ex, ey, 1 / (radius * s.scl));
    }
  }

  /// 拖到球体边缘时，让球自己慢慢转，把节点带回正面。
  ///
  /// 球面上最远只能拖到轮廓线——再往外是背面，手够不到。与其让节点卡在
  /// 轮廓上干瞪眼，不如让球在指下滚动：节点始终跟着光标，球面从它下面
  /// 流过去。这样「把笔记放到球的另一边」才是一个能完成的操作。
  void _autoTurn(double dt) {
    final double radius = _sphereRadius;
    if (radius <= 0) return;

    // 看光标离球心多远。节点已经被拉到光标上了，两者是同一件事。
    final double dx = _pointer.dx - _stageSize.width / 2;
    final double dy = _pointer.dy - _stageSize.height / 2;
    final double dist = math.sqrt(dx * dx + dy * dy);
    final double lim = radius * 0.84;
    if (dist <= lim) return;

    // 0.14R 的过渡带：刚过线时几乎不转，越往外越快。没有它，一碰线
    // 球就猛地一甩。0.6 是「跟手但不晃眼」——满速大约 90°/秒。
    final double over = math.min(1, (dist - lim) / (radius * 0.14));
    final double f = (1 - math.exp(-dt * 3.0)) * over * 0.6;
    if (f <= 0) return;

    // 绕「屏幕上垂直于半径」的那根轴转，把节点往球心方向带。
    final s = _screenOf(_dragNode!);
    _camera.rotate(s.y * f, -s.x * f);
  }

  /// 把被拖节点周围的邻居拨开，像手指划过水面。
  ///
  /// 位移是**世界空间的偏移**，画的时候加回坐标再归一化（见 [_project]），
  /// 所以点仍然沿球面滑动，不会陷进球里。力度按二次衰减：紧贴的邻居让得
  /// 最多，边界处正好归零——所以邻居进圈时不会「啪」地跳一下。
  void _pushAside(int pivot) {
    final int n = _view.nodes.length;
    if (n == 0 || _pushRadius <= 0) return;

    final double r2 = _pushRadius * _pushRadius;
    final double px0 = _layout.px[pivot];
    final double py0 = _layout.py[pivot];
    final double pz0 = _layout.pz[pivot];

    for (int i = 0; i < n; i++) {
      if (i == pivot) {
        _pushX[i] = 0;
        _pushY[i] = 0;
        _pushZ[i] = 0;
        continue;
      }
      final double dx = _layout.px[i] - px0;
      final double dy = _layout.py[i] - py0;
      final double dz = _layout.pz[i] - pz0;
      final double d2 = dx * dx + dy * dy + dz * dz;
      if (d2 >= r2 || d2 < 1e-12) {
        _pushX[i] = 0;
        _pushY[i] = 0;
        _pushZ[i] = 0;
        continue;
      }
      final double d = math.sqrt(d2);
      final double w = (_pushRadius - d) / _pushRadius;
      final double k = w * _pushAmount / d;
      _pushX[i] = dx * k;
      _pushY[i] = dy * k;
      _pushZ[i] = dz * k;
    }
  }

  /// 敲一下重绘信号，并确保 Ticker 在跑。
  void _heat() {
    if (!_ticker.isActive) {
      _firstTick = true;
      _ticker.start();
    }
    _repaint.tick();
  }

  // ------------------------------------------------------------------ 辉光

  Future<void> _ensureGlowSprites() async {
    final AppPalette p = context.palette;
    final Map<String, Color> colors = _resolveFolderColors(p);
    final Set<Color> want = <Color>{...colors.values, _orbStyle(p).node};
    if (want.every(_glow.containsKey)) return;

    final Map<Color, ui.Image> made = <Color, ui.Image>{};
    for (final Color c in want) {
      final ui.Image? existing = _glow[c];
      made[c] = existing ?? await _makeGlow(c);
    }
    if (!mounted) {
      for (final ui.Image img in made.values) {
        img.dispose();
      }
      return;
    }
    setState(() {
      for (final MapEntry<Color, ui.Image> e in made.entries) {
        _glow[e.key] = e.value;
      }
    });
  }

  /// 预渲染一张径向渐变的辉光贴图。
  ///
  /// 五段色标是照着「中心实、外圈几乎看不见」调的。段数少了边缘会出现
  /// 一圈生硬的截止线，贴着深色底看非常明显。
  static Future<ui.Image> _makeGlow(Color color) async {
    const double size = 64;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, size, size),
      Paint()
        ..shader = ui.Gradient.radial(
          const Offset(size / 2, size / 2),
          size / 2,
          <Color>[
            color.withValues(alpha: 1),
            color.withValues(alpha: 0.55),
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.045),
            color.withValues(alpha: 0),
          ],
          <double>[0, 0.16, 0.38, 0.66, 1],
        ),
    );
    return recorder.endRecording().toImage(64, 64);
  }

  OrbStyle _orbStyle(AppPalette p) => OrbStyle(
    canvasInner: p.isDark ? const Color(0xFF101A2C) : const Color(0xFFF7F8FA),
    canvasOuter: p.isDark ? const Color(0xFF04060A) : const Color(0xFFE8EBF0),
    rim: const Color(0xFF6EA0EB).withValues(alpha: p.isDark ? 0.13 : 0.18),
    edge: p.isDark ? const Color(0xFF93A9C9) : const Color(0xFF5A6B85),
    node: p.isDark ? const Color(0xFFC2C5CC) : const Color(0xFF7A7A7A),
    ring: p.accent,
    // 逆方向粒子用琥珀：主题色在「石墨素白」这套默认主题里是近黑/近白，
    // 拿它当第二个方向等于没有方向。琥珀在深浅两套底上都跳得出来。
    flowIn: groupColor(p, CellColorToken.amber),
    label: p.isDark ? const Color(0xFFCEDCF2) : p.textSecondary,
    labelFocus: p.isDark ? const Color(0xFFF2F8FF) : p.textPrimary,
    labelHalo: p.isDark ? const Color(0xFF03060B) : const Color(0xFFF2F4F8),
  );

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
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
                // 投影直接在这里算：它是纯派生值，不影响 widget 树，所以
                // 不需要 setState 绕一圈——绕了会多一帧空白。
                _stageSize = size;
                _project();
                return _stage(
                  context,
                  p,
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
            onChanged: (GraphScope v) => _onSettings(_settings.copyWith(scope: v)),
            items: const <({GraphScope value, IconData icon, String label})>[
              (value: GraphScope.global, icon: LucideIcons.globe, label: '全局'),
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
          ),
        ],
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
    return TextSpan(children: spans);
  }

  String? _currentTitle() {
    final int? i = _graph.indexOfId(widget.currentId);
    return i == null ? null : _graph.nodes[i].title;
  }

  Widget _stage(
    BuildContext context,
    AppPalette p,
    Size size,
    Map<String, Color> folderColors,
    List<GraphGroup> groups,
  ) {
    final OrbPaintData data = OrbPaintData(
      graph: _view,
      layout: _layout,
      screenX: _sx,
      screenY: _sy,
      scale: _scl,
      depth: _dep,
      camX: _camX,
      camY: _camY,
      camZ: _camZ,
      radii: _radii,
      alphas: _alphas,
      order: _order,
      lit: _lit,
      focus: _hover,
      focusFade: _focusFade,
      useFolderColors: _settings.useFolderColors,
      folderColors: folderColors,
      style: _orbStyle(p),
      glowSprites: _glow,
      edgeScale: _settings.linkScale,
      textScaler: MediaQuery.textScalerOf(context),
      labels: _labels,
      sphereRadius: _sphereRadius,
      zoom: _scale,
    );

    return Stack(
      key: debugStageKey,
      children: <Widget>[
        Positioned.fill(
          child: MouseRegion(
            // 光标是唯一的「这里能点」的提示：节点可以拖、可以点开，
            // 空白处只能转。不给反馈的话，用户得先试一下才知道。
            cursor: _dragNode != null
                ? SystemMouseCursors.grabbing
                : _hover != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onExit: (_) => _clearHover(),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              // 鼠标不按键移动发的是 `PointerHoverEvent`，只走 `onPointerHover`；
              // `onPointerMove` 收不到。两个都要接，不然「悬停」只在按住鼠标
              // 的时候才生效。
              onPointerHover: _onPointerMove,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerUp,
              onPointerSignal: _onPointerSignal,
              child: CustomPaint(
                painter: OrbPainter(
                  data: data,
                  repaint: _repaint,
                  clock: () => _clock,
                ),
                child: const SizedBox.expand(),
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
            localCount: _settings.scope == GraphScope.local ? _view.nodes.length : 0,
            currentTitle: _currentTitle(),
            collapsed: _panelCollapsed,
            onToggleCollapsed: () => setState(() => _panelCollapsed = !_panelCollapsed),
          ),
        ),
        if (_view.isNotEmpty)
          Positioned(
            left: AppSpace.md,
            bottom: AppSpace.md,
            child: GraphLegend(
              groups: groups,
              selected: _settings.folder,
              onSelect: (String? f) => _onSettings(_settings.copyWith(folder: f)),
            ),
          ),
        Positioned(right: AppSpace.md, bottom: AppSpace.md, child: _hud(p)),
        if (_hover != null && _dragNode == null)
          _tooltip(p, _view.nodes[_hover!], folderColors),
      ],
    );
  }

  // ------------------------------------------------------------- 设置变化

  void _onSettings(GraphSettings next) {
    final bool structureChanged =
        next.scope != _settings.scope ||
        next.depth != _settings.depth ||
        next.showOrphans != _settings.showOrphans;
    setState(() {
      _settings = next;
      _recomputeRadii();
      if (structureChanged) {
        _rebuildView();
      } else {
        _recomputeLit();
      }
    });
    _project();
    _heat();
  }

  void _relayout() {
    setState(() {
      _globalLayout = OrbLayout(_graph.nodes.length);
      _globalLayout.seed(_graph);
      _globalLayout.relax(_graph);
      _orientToLargestCluster();
      _rebuildView();
    });
    _project();
    _heat();
  }

  // ------------------------------------------------------------------ 指针

  void _onPointerDown(PointerDownEvent e) {
    _idle = 0;
    _velX = 0;
    _velY = 0;

    final int? hit = _nodeAt(e.localPosition);
    if (hit != null) {
      // 记下起点：拖拽要靠它判断「这是拖动还是单击」，也要靠它给第一帧
      // 一个正确的目标位置。
      _rotateLast = e.localPosition;
      _pointer = e.localPosition;
      _dragOrigin = e.localPosition;
      setState(() {
        _hover = hit;
        _dragNode = hit;
        _dragMoved = false;
      });
      _heat();
      return;
    }

    _rotateFrom = e.localPosition;
    _rotateLast = e.localPosition;
    _rotated = false;
    // 转球时要能把钉住的那颗放回球面，而放回是靠帧驱动的。
    _heat();
  }

  /// 指针移动。悬停（[PointerHoverEvent]）和拖动（[PointerMoveEvent]）都走这里，
  /// 两者只有 `localPosition` 有用。
  void _onPointerMove(PointerEvent e) {
    if (_dragNode != null) {
      // 这里只记位置，真正的位移在 [_stepDrag] 里做：拖到边缘时球要自己
      // 转，光靠指针事件推不动。
      _pointer = e.localPosition;
      if (!_dragMoved && (e.localPosition - _dragOrigin).distance > 3) {
        _dragMoved = true;
      }
      _applyDrag();
      _project();
      _repaint.tick();
      return;
    }

    if (_rotateFrom != null) {
      final Offset delta = e.localPosition - (_rotateLast ?? e.localPosition);
      if (delta.distance > 0) {
        _rotated = true;
        _camera.rotate(delta.dy * 0.0062, delta.dx * 0.0062);
        // 记下瞬时角速度，松手后当惯性用。
        _velX = delta.dy * 0.0062 * 46;
        _velY = delta.dx * 0.0062 * 46;
        _velX = _velX.clamp(-1.6, 1.6);
        _velY = _velY.clamp(-1.6, 1.6);
        _project();
        _repaint.tick();
      }
      _rotateLast = e.localPosition;
      return;
    }

    final int? hit = _nodeAt(e.localPosition);
    if (hit != _hover) {
      setState(() {
        _hover = hit;
        _pointer = e.localPosition;
      });
      _project();
      _heat();
    } else if (hit != null) {
      setState(() => _pointer = e.localPosition);
    }
  }

  void _onPointerUp(PointerEvent e) {
    if (_dragNode != null) {
      final int node = _dragNode!;
      final bool moved = _dragMoved;
      final String id = _view.nodes[node].id;
      setState(() {
        _dragNode = null;
        _dragMoved = false;
      });
      _rotateLast = null;
      _heat();
      // 单击（按下到松开没挪过）= 打开。和 Obsidian 一样，没有双击：
      // 悬停已经把「选中」表达完了，单击再选中一次没有意义。
      if (!moved) widget.onOpenNote(id);
      return;
    }

    if (_rotateFrom != null) {
      final bool rotated = _rotated;
      _rotateFrom = null;
      _rotateLast = null;
      _rotated = false;
      if (!rotated) {
        // 点空白：清掉高亮，同时停掉自转的惯性。
        setState(() => _hover = null);
        _velX = 0;
        _velY = 0;
        _heat();
      } else {
        _idle = 0;
        _heat();
      }
    }
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final double next = (_scale * math.exp(-e.scrollDelta.dy * 0.0016)).clamp(0.45, 2.6);
    if (next == _scale) return;
    setState(() => _scale = next);
    _project();
    _heat();
  }

  void _clearHover() {
    if (!mounted || _hover == null) return;
    setState(() => _hover = null);
    _project();
    _heat();
  }

  /// 命中测试。用投影时算好的屏幕坐标，和画出来的位置逐像素一致。
  int? _nodeAt(Offset local) {
    int? best;
    double bestScore = double.infinity;
    for (int i = 0; i < _view.nodes.length; i++) {
      if (!_lit[i]) continue;
      final double dx = local.dx - _sx[i];
      final double dy = local.dy - _sy[i];
      final double hit = math.max(_radii[i] + 6, 9);
      final double d2 = dx * dx + dy * dy;
      if (d2 > hit * hit) continue;
      // 靠前的优先：球背面的点被球挡住时不该抢走点击。
      final double score = d2 - _camZ[i] * 600;
      if (score < bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  // ------------------------------------------------------------------ 杂项 UI

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
            onPressed: () => _zoomBy(1 / 1.22),
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
            onPressed: () => _zoomBy(1.22),
          ),
          Container(width: 1, height: 14, color: p.outline),
          _HudButton(
            icon: LucideIcons.maximize,
            tooltip: '回到正面',
            onPressed: _resetView,
          ),
        ],
      ),
    );
  }

  void _zoomBy(double factor) {
    final double next = (_scale * factor).clamp(0.45, 2.6);
    if (next == _scale) return;
    setState(() => _scale = next);
    _project();
    _heat();
  }

  void _resetView() {
    setState(() {
      _scale = 1;
      _velX = 0;
      _velY = 0;
      _orientToLargestCluster();
    });
    _project();
    _heat();
  }

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

  Widget _emptyState(AppPalette p) {
    return IgnorePointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text(_hintText(), textAlign: TextAlign.center, style: _hintStyle(p)),
        ),
      ),
    );
  }

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
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------- 测试用只读快照

  @visibleForTesting
  int get debugNodeCount => _view.nodes.length;

  @visibleForTesting
  int get debugEdgeCount => _view.edges.length;

  @visibleForTesting
  int get debugLitCount => _lit.where((bool b) => b).length;

  @visibleForTesting
  int? get debugHover => _hover;

  /// 某颗点这一帧的最终不透明度。用来验证高亮是「渐变」而不是「硬切」。
  @visibleForTesting
  double? debugAlphaOf(String noteId) {
    final int? i = _view.indexOfId(noteId);
    return i == null ? null : _alphas[i];
  }

  /// 手动把球转一点，再重投影。
  ///
  /// 测试里没有自转（`_drift` 关着，否则 `pumpAndSettle` 永远等不到头），
  /// 所以「钉住的点不动」只能靠这个来制造「球在转」。
  @visibleForTesting
  void debugSpin(double ax, double ay) {
    _camera.rotate(ax, ay);
    _project();
  }

  @visibleForTesting
  final GlobalKey debugStageKey = GlobalKey();

  /// 某个节点在画布内的坐标。
  ///
  /// `CustomPainter` 画的东西不进语义树，点不到也 find 不到，所以测试只能
  /// 拿到坐标再 `tapAt`。
  @visibleForTesting
  Offset? debugNodeCenter(String noteId) {
    final int? i = _view.indexOfId(noteId);
    if (i == null) return null;
    return Offset(_sx[i], _sy[i]);
  }

  /// 某个节点在球面上的方向（单位向量）。
  ///
  /// 屏幕坐标在球面上是有天花板的——最远只能到轮廓线，所以「拖到球的另一侧」
  /// 只能靠世界坐标来验证。
  @visibleForTesting
  ({double x, double y, double z}) debugWorldOf(String noteId) {
    final int? i = _view.indexOfId(noteId);
    if (i == null) return (x: 0, y: 0, z: 0);
    return (x: _layout.px[i], y: _layout.py[i], z: _layout.pz[i]);
  }

  @visibleForTesting
  GraphSettings get debugSettings => _settings;
}

/// 一个能被 `CustomPainter` 订阅的重绘信号。
///
/// 每帧 `setState` 会把整个子树重建一遍；相机转动只需要「重画」，不需要
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
