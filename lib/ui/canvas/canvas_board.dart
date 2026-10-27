import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/canvas_document.dart';
import '../../core/utils/canvas_geometry.dart';
import '../../core/utils/table_model.dart' show CellColor;
import 'canvas_history.dart';
import 'canvas_painter.dart';
import 'canvas_pickers.dart';
import 'canvas_style.dart';

/// 白板。一块可以无限平移缩放的画布，卡片和连线都摆在上面。
///
/// 五条设计约束，改之前先读：
///
/// * **全画布只有一个 `CustomPaint`**。卡片不是 Widget：它们由
///   [CanvasScenePainter] 在世界坐标里直接画出来，命中测试也在这一层自己
///   做。这样平移缩放只是矩阵变换，没有逐张卡片的布局开销。
/// * **只有一层 [Listener]**。手柄、卡片、连线、空白，所有目标全在这一个
///   入口里按顺序做命中测试，再用 [_Interaction] 记「现在在干什么」。
///   用嵌套 `GestureDetector` 会互相抢手势。
/// * **摄像机模型**：画面中心对准哪个世界坐标（[CanvasCamera.center]）加
///   一个缩放。缩放会平滑逼近目标值，平移/缩放都以光标为锚点。
/// * **点阵在屏幕坐标里算**。世界坐标铺满再整体变换，缩放越小画得越多。
/// * **空白处左键拖是框选，不是平移**。平移交给中键拖、空格拖、WASD；
///   滚轮是缩放（往上放大、往下缩小）。
class CanvasBoard extends StatefulWidget {
  const CanvasBoard({
    super.key,
    required this.document,
    this.onChanged,
    this.files = const <({String path, String title})>[],
    this.onOpenFile,
    this.onOpenLink,
  });

  /// 要画的文档。null = 只读空板（还不能编辑），此时不响应任何修改。
  final CanvasDocument? document;

  /// 文档被改过（新建 / 移动 / 缩放 / 改文字 / 换色 / 删除）。
  final VoidCallback? onChanged;

  /// 可以放到白板上的笔记。文件卡片的挑选列表就是它。
  final List<({String path, String title})> files;

  /// 双击文件卡片：打开那篇笔记。
  final ValueChanged<String>? onOpenFile;

  /// 双击链接卡片：用系统浏览器打开。
  final ValueChanged<String>? onOpenLink;

  @override
  State<CanvasBoard> createState() => CanvasBoardState();
}

/// 现在在干什么。一次只有一个。
enum _Interaction {
  idle,

  /// 中键 / 空格 / 左键拖：平移画布。
  panning,

  /// 左键拖空白：框选。
  marquee,

  /// 按在卡片上，还没走够 3px。走够了才升级成 [dragging]。
  ///
  /// 这一档是为了「单击选中不该把卡片挪 1px」：手指按下去总有一两像素的
  /// 抖动，直接算拖动会让每张被点过的卡片都歪一点。
  maybeDrag,

  dragging,

  resizing,

  /// 从卡片边上的圆点拖出来一条连线，还没落地。
  connecting,
}

/// 翻页键的方向：往**哪边看**（不是内容往哪边走）。
enum CanvasPageDirection { up, down, left, right }

/// 翻一屏走多少：留 10% 重叠，翻过去还认得出原来那一片。
const double canvasPagePanRatio = 0.9;

/// 摄像机缓动（适应窗口等）。
class _CameraTween {
  _CameraTween({required this.from, required this.to});

  final CanvasCamera from;
  final CanvasCamera to;
}

class CanvasBoardState extends State<CanvasBoard>
    with SingleTickerProviderStateMixin {
  final FocusNode _focus = FocusNode(debugLabel: 'nrs-canvas');

  // ------------------------------------------------------------- 摄像机

  CanvasCamera _camera = const CanvasCamera();

  /// 平滑缩放的目标值。每帧朝它逼近，滚轮可以连着叠加。
  double _targetZoom = 1;

  /// 缩放锚点（屏幕坐标）。滚动缩放时锚在光标，按钮缩放锚在画面中心。
  Offset? _zoomAnchor;

  _CameraTween? _tween;
  double _tweenElapsed = 0;
  static const Duration _tweenDuration = Duration(milliseconds: 240);

  /// WASD 平移的惯性速度（屏幕像素/秒）。
  Offset _cameraVelocity = Offset.zero;

  final Set<LogicalKeyboardKey> _moveKeys = <LogicalKeyboardKey>{};

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  Size _stage = Size.zero;

  /// 当前摄像机是按哪份文档自适应的。文档换了就重新适应。
  Object? _fittedDocument;

  _Interaction _mode = _Interaction.idle;

  /// 选中的节点 id / 边 id。
  final Set<String> _selected = <String>{};

  /// 正在编辑的节点 id。
  String? _editingId;
  final TextEditingController _editor = TextEditingController();
  final FocusNode _editorFocus = FocusNode(debugLabel: 'nrs-canvas-editor');

  /// 平移：上一次指针位置（屏幕坐标）。
  Offset _lastPointer = Offset.zero;

  /// 框选：起点与当前点（**世界**坐标）。
  ///
  /// 存世界坐标而不是屏幕坐标，是为了「框着框着滚一下滚轮」时框还贴在
  /// 内容上。
  Offset? _marqueeStart;
  Offset? _marqueeEnd;

  /// 拖动：按下时的世界坐标，以及每张被拖的卡片原来的左上角。
  Offset _dragFrom = Offset.zero;
  Offset _dragFromScreen = Offset.zero;
  final Map<String, Offset> _dragOrigins = <String, Offset>{};
  bool _dragMoved = false;

  /// 缩放：按下的手柄、被缩放的卡片、按下时的矩形。
  CanvasResizeHandle? _handle;
  String? _resizeId;
  Rect _resizeStart = Rect.zero;

  /// 悬停在哪张卡片上（连线圆点只给悬停的那张）。
  String? _hoverNodeId;

  /// 连线：从哪张卡片的哪条边出发，光标现在在屏幕哪里。
  String? _connectFromId;
  CanvasSide _connectSide = CanvasSide.right;
  Offset? _connectCursor;

  /// 正在编辑标签的边。
  String? _editingEdgeId;

  // ------------------------------------------------------------------ 浮层

  /// 搜索框开着吗。开着的时候键盘归它，白板自己的快捷键全部让位。
  bool _searchOpen = false;
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'nrs-canvas-search');

  /// 搜索命中的节点 id，按文档顺序。
  List<String> _searchHits = const <String>[];
  int _searchCursor = 0;

  /// 详细信息面板开着吗。
  ///
  /// 面板**没有自己的目标节点**：它永远显示当前那一张单选。选中没了、选了
  /// 第二张，面板就跟着换或者收起来——比再存一个 id 再去同步它省事得多。
  bool _detailsOpen = false;

  /// 面板尺寸。右下角的握把能拖它——「任何子窗口都能改大小」。
  Size _detailsSize = const Size(296, 352);

  /// 面板左上角（屏幕坐标）。null = 贴在舞台右下角。
  Offset? _detailsOrigin;

  /// 正在拖面板的右下角。
  bool _resizingDetails = false;
  Offset _detailsGripFrom = Offset.zero;
  Size _detailsGripSize = Size.zero;

  /// 撤销栈。快照是整份文档的 JSON。
  final CanvasHistory _history = CanvasHistory();

  /// 复制缓冲区：选中的节点和它们之间的边，也是 JSON。
  String? _clipboard;

  /// 空格按住 = 临时切换成抓手。
  bool _spaceHeld = false;

  /// 悬停光标。
  MouseCursor _cursor = SystemMouseCursors.basic;

  /// 上一次点击的位置和目标，和一个「双击窗口」的计时器。
  Timer? _tapWindow;
  Offset _lastTapAt = Offset.zero;
  String _lastTapTarget = '';

  /// 触控板：上一帧的累计缩放，用来算增量。
  double _panZoomScale = 1;

  /// 文字排版缓存。跨帧复用，删掉的节点会释放。
  final CanvasTextCache _textCache = CanvasTextCache();

  CanvasDocument? get _doc => widget.document;

  bool get _readOnly => _doc == null;

  /// 让白板拿到键盘。外壳切到白板时调它。
  void requestFocus() => _focus.requestFocus();

  // 测试探针。
  CanvasCamera get debugCamera => _camera;
  double get debugZoom => _camera.zoom;
  Offset get debugCenter => _camera.center;
  double get debugTargetZoom => _targetZoom;
  Size get debugStage => _stage;
  bool get debugPanning => _mode == _Interaction.panning;
  bool get debugDragging => _mode == _Interaction.dragging;
  bool get debugResizing => _mode == _Interaction.resizing;
  bool get debugTicking => _ticker.isActive;
  bool get debugSpaceHeld => _spaceHeld;
  Rect? get debugMarquee => _marqueeWorld;
  Set<String> get debugSelection => Set<String>.of(_selected);
  String? get debugEditing => _editingId;
  String? debugColorOf(String id) => _doc?.nodeById(id)?.color;
  String? get debugEditingEdge => _editingEdgeId;
  int get debugEdgeCount => _doc?.edges.length ?? 0;
  bool get debugSearchOpen => _searchOpen;
  List<String> get debugSearchHits => List<String>.of(_searchHits);
  String? get debugDetails => _detailsNode?.id;
  Size get debugDetailsSize => _detailsSize;
  Rect get debugDetailsRect => _detailsRect;
  Rect get debugSearchRect => _searchRect;
  String? debugLabelOf(String id) {
    for (final CanvasEdge edge in _doc?.edges ?? const <CanvasEdge>[]) {
      if (edge.id == id) return edge.label;
    }
    return null;
  }

  /// 世界坐标里的可见矩形（测试用）。
  Rect get debugVisibleWorld => _camera.visibleWorld(_stage);

  /// 空板提示的两行文字（测试用）。null = 不是空板。
  (String, String)? get debugEmptyHint => _emptyHint(_doc);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _editorFocus.addListener(() {
      // 输入框丢了焦点（点了别处、切了窗口）就收工。
      if (!_editorFocus.hasFocus && _editingId != null) _commitEdit();
    });
  }

  @override
  void didUpdateWidget(CanvasBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      // 换了一份文档：下次 build 按内容重新适应视野。
      _fittedDocument = null;
      _editingId = null;
      _editingEdgeId = null;
      _selected.clear();
      _detailsOpen = false;
      _resetSearch();
    }
  }

  @override
  void dispose() {
    _tapWindow?.cancel();
    _ticker.dispose();
    _textCache.dispose();
    _editor.dispose();
    _editorFocus.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 摄像机

  Offset _toWorld(Offset screen) => _camera.toWorld(screen, _stage);

  Offset _toScreen(Offset world) => _camera.toScreen(world, _stage);

  Rect _rectToScreen(Rect world) => _camera.rectToScreen(world, _stage);

  void _ensureTicking() {
    if (_ticker.isActive) return;
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final double dt = _lastTick == Duration.zero
        ? 1 / 120
        : (elapsed - _lastTick).inMicroseconds / 1000000;
    _lastTick = elapsed;
    final double step = dt.clamp(0.001, 0.05);
    CanvasCamera cam = _camera;
    bool busy = false;

    if (_tween != null) {
      _tweenElapsed += step;
      final double t = (_tweenElapsed / (_tweenDuration.inMilliseconds / 1000))
          .clamp(0.0, 1.0);
      final double e = easeOutCubic(t);
      final _CameraTween tw = _tween!;
      cam = CanvasCamera(
        center: lerpOffset(tw.from.center, tw.to.center, e),
        zoom: lerpDouble(tw.from.zoom, tw.to.zoom, e),
      );
      if (t >= 1) {
        _tween = null;
        _targetZoom = cam.zoom;
      } else {
        busy = true;
      }
    } else if (_zoomAnchor != null) {
      final double diff = _targetZoom - cam.zoom;
      // 收敛判据是**相对**的：没有缩放上限之后，绝对阈值在 1e-6 和 1e6 上
      // 都不对——前者一下就「到位」，后者永远收不住。
      final double epsilon = math.max(1e-9, _targetZoom.abs() * 1e-3);
      if (diff.abs() <= epsilon) {
        cam = cam.withZoomAt(_zoomAnchor!, _targetZoom, _stage);
        _zoomAnchor = null;
      } else {
        busy = true;
        final double z = cam.zoom + diff * (1 - math.exp(-step * 18));
        cam = cam.withZoomAt(_zoomAnchor!, z, _stage);
      }
    }

    // WASD：按着加速，松开靠摩擦滑停。
    final Offset dir = _moveDirection();
    if (dir != Offset.zero) {
      _cameraVelocity += dir * (2600 * step);
      busy = true;
    }
    if (_cameraVelocity != Offset.zero) {
      final double speed = _cameraVelocity.distance;
      if (speed > 2200) {
        _cameraVelocity = _cameraVelocity / speed * 2200;
      }
      cam = CanvasCamera(
        center: cam.center + _cameraVelocity * step / cam.zoom,
        zoom: cam.zoom,
      );
      _cameraVelocity *= math.exp(-step * 5.5);
      if (dir == Offset.zero && _cameraVelocity.distance < 6) {
        _cameraVelocity = Offset.zero;
      }
      if (_cameraVelocity != Offset.zero) busy = true;
    }

    setState(() => _camera = cam);
    if (!busy) {
      _ticker.stop();
      _lastTick = Duration.zero;
    }
  }

  Offset _moveDirection() {
    double dx = 0;
    double dy = 0;
    if (_moveKeys.contains(LogicalKeyboardKey.keyA)) dx -= 1;
    if (_moveKeys.contains(LogicalKeyboardKey.keyD)) dx += 1;
    if (_moveKeys.contains(LogicalKeyboardKey.keyW)) dy -= 1;
    if (_moveKeys.contains(LogicalKeyboardKey.keyS)) dy += 1;
    return Offset(dx, dy);
  }

  /// 立刻停掉摄像机的一切自动运动。用户一上手拖动就该停。
  void _stopCameraMotion({bool keepVelocity = false}) {
    _tween = null;
    _zoomAnchor = null;
    _targetZoom = _camera.zoom;
    if (!keepVelocity) _cameraVelocity = Offset.zero;
  }

  /// 缩放到目标值。**只有数值下限，没有上限**——往大了放没有墙。
  void _zoomAt(Offset anchorScreen, double factor) {
    _tween = null;
    _zoomAnchor = anchorScreen;
    final double next = _targetZoom * factor;
    _targetZoom = next < CanvasCamera.minZoom ? CanvasCamera.minZoom : next;
    _ensureTicking();
  }

  void zoomIn() => _zoomAt(_stage.center(Offset.zero), 1.25);

  void zoomOut() => _zoomAt(_stage.center(Offset.zero), 1 / 1.25);

  void resetZoom() {
    _tween = null;
    _zoomAnchor = _stage.center(Offset.zero);
    _targetZoom = 1;
    _ensureTicking();
  }

  /// 平滑移动到目标摄像机。
  void _animateTo(CanvasCamera to) {
    if (to == _camera) return;
    _zoomAnchor = null;
    _targetZoom = to.zoom;
    _cameraVelocity = Offset.zero;
    _tween = _CameraTween(from: _camera, to: to);
    _tweenElapsed = 0;
    _ensureTicking();
  }

  Rect _contentBounds([CanvasDocument? doc]) {
    final CanvasDocument? board = doc ?? _doc;
    if (board == null || board.isEmpty) return Rect.zero;
    return unionOf(board.nodes.map((CanvasNode n) => n.rect));
  }

  CanvasCamera _cameraFor(CanvasDocument? doc, Size stage) {
    final Rect content = _contentBounds(doc);
    if (content.width <= 0 || content.height <= 0) {
      return const CanvasCamera();
    }
    return CanvasCamera.fit(content, stage);
  }

  /// 适应窗口。空板时回到原点、100%。
  void fitToContent() => _animateTo(_cameraFor(_doc, _stage));

  /// 重置视野：有选中就只框住选中那一块，没选中就框住全部内容。
  ///
  /// 「框选 → 按 F」是白板上最常用的一个动作：先圈出一片，再让它铺满屏幕。
  void fitToSelection() {
    final Rect? selection = _selectionBounds();
    if (selection == null) {
      fitToContent();
      return;
    }
    _animateTo(CanvasCamera.fit(selection, _stage));
  }

  Rect? _selectionBounds() {
    final CanvasDocument? doc = _doc;
    if (doc == null) return null;
    final List<Rect> rects = <Rect>[
      for (final String id in _selected)
        if (doc.nodeById(id) case final CanvasNode node) node.rect,
    ];
    if (rects.isEmpty) return null;
    return unionOf(rects);
  }

  /// 翻一屏。`[` 方向是「往哪边看」，不是「内容往哪边走」。
  void panByPage(CanvasPageDirection direction) {
    final double dx = _stage.width * canvasPagePanRatio;
    final double dy = _stage.height * canvasPagePanRatio;
    _panBy(switch (direction) {
      CanvasPageDirection.up => Offset(0, dy),
      CanvasPageDirection.down => Offset(0, -dy),
      CanvasPageDirection.left => Offset(dx, 0),
      CanvasPageDirection.right => Offset(-dx, 0),
    });
  }

  void _panBy(Offset screenDelta) {
    _stopCameraMotion();
    setState(() => _camera = _camera.pannedBy(screenDelta));
  }

  // ------------------------------------------------------------- 文档修改

  /// 改文档的唯一入口：改完重画一遍，再告诉外面「脏了」。
  void _mutate(VoidCallback change, {bool record = true}) {
    if (_readOnly) return;
    if (record) _pushHistory();
    setState(change);
    widget.onChanged?.call();
  }

  void _pushHistory() {
    final CanvasDocument? doc = _doc;
    if (doc == null) return;
    _history.push(encodeCanvas(doc));
  }

  bool get canUndo => _history.canUndo;

  bool get canRedo => _history.canRedo;

  void undo() {
    final CanvasDocument? doc = _doc;
    if (doc == null) return;
    final String? snapshot = _history.undo(encodeCanvas(doc));
    if (snapshot == null) return;
    _restore(snapshot);
  }

  void redo() {
    final CanvasDocument? doc = _doc;
    if (doc == null) return;
    final String? snapshot = _history.redo(encodeCanvas(doc));
    if (snapshot == null) return;
    _restore(snapshot);
  }

  /// 把一份快照装回当前文档。
  ///
  /// 是**原地替换内容**而不是换掉 `widget.document` 那个对象：外壳、选择、
  /// 视口都拿着同一个引用，换对象等于让它们全部指向旧的那份。
  void _restore(String snapshot) {
    final CanvasDocument parsed;
    try {
      parsed = parseCanvas(snapshot);
    } on CanvasFormatException {
      // 自己写进去的快照解析不了，说明是代码 bug，不是用户数据问题。
      // 与其把白板清空，不如什么都不做。
      return;
    }
    _mutate(() {
      _doc!
        ..nodes.clear()
        ..nodes.addAll(parsed.nodes)
        ..edges.clear()
        ..edges.addAll(parsed.edges);
      _selected.clear();
      _editingId = null;
      _editingEdgeId = null;
    }, record: false);
  }

  /// 新卡片落在视口正中（或指定位置）。坐标是自由的，不吸附。
  ///
  /// 先按 [canvasMinSize] 摆一个方块，再走 [_fitTextNode]——空文字就贴成
  /// 「刚好装下 `•••` 的宽 × 一行正文的高」。**这里不写任何尺寸常量**：
  /// 空卡片一旦有了自己的尺寸，就一定会和它显示的那三个点对不上。
  void createCard({Offset? at}) {
    final CanvasDocument? doc = _doc;
    if (doc == null) return;
    final Offset center = at ?? _camera.center;
    final TextNode node = TextNode(
      id: newCanvasId(),
      x: center.dx - canvasMinSize / 2,
      y: center.dy - canvasMinSize / 2,
      width: canvasMinSize,
      height: canvasMinSize,
    );
    // 贴合之后再落盘：`_mutate` 记的是这一刻的快照。
    _fitTextNode(node);
    _mutate(() {
      doc.nodes.add(node);
      _selected
        ..clear()
        ..add(node.id);
    });
    _beginEdit(node);
  }

  /// 把一张卡片放到视口正中（或指定位置）并选中它。
  T _addCard<T extends CanvasNode>(T node, {Offset? at}) {
    final CanvasDocument doc = _doc!;
    final Offset center = at ?? _camera.center;
    node.x = center.dx - node.width / 2;
    node.y = center.dy - node.height / 2;
    _mutate(() {
      // 分组是底板，永远压在最下面；其它卡片叠在最上面。
      if (node is GroupNode) {
        doc.nodes.insert(0, node);
      } else {
        doc.nodes.add(node);
      }
      _selected
        ..clear()
        ..add(node.id);
    });
    return node;
  }

  /// 放一篇笔记到白板上。
  Future<void> createFileCard({Offset? at}) async {
    if (_readOnly) return;
    final String? path = await showCanvasFilePicker(
      context,
      files: widget.files,
    );
    if (!mounted || path == null) return;
    _addCard<FileNode>(
      FileNode(
        id: newCanvasId(),
        x: 0,
        y: 0,
        width: canvasDefaultWidth,
        height: 100,
        file: path,
      ),
      at: at,
    );
  }

  /// 放一个网址到白板上。
  Future<void> createLinkCard({Offset? at}) async {
    if (_readOnly) return;
    final String? url = await showCanvasLinkDialog(context);
    if (!mounted || url == null) return;
    _addCard<LinkNode>(
      LinkNode(
        id: newCanvasId(),
        x: 0,
        y: 0,
        width: canvasDefaultWidth,
        height: 100,
        url: url,
      ),
      at: at,
    );
  }

  /// 放一个分组框。
  Future<void> createGroupCard({Offset? at}) async {
    if (_readOnly) return;
    _addCard<GroupNode>(
      GroupNode(
        id: newCanvasId(),
        x: 0,
        y: 0,
        width: 420,
        height: 300,
        label: '分组',
      ),
      at: at,
    );
  }

  /// 删掉选中的节点，连带删掉连在它们身上的边。
  void deleteSelection() {
    final CanvasDocument? doc = _doc;
    if (doc == null || _selected.isEmpty) return;
    _mutate(() {
      doc.nodes.removeWhere((CanvasNode n) => _selected.contains(n.id));
      doc.edges.removeWhere(
        (CanvasEdge e) =>
            _selected.contains(e.fromNode) ||
            _selected.contains(e.toNode) ||
            _selected.contains(e.id),
      );
      _selected.clear();
      _editingId = null;
    });
  }

  /// 框选松手：框到谁就选谁。
  ///
  /// 判据是**相交**而不是「完全框住」：从右下往左上拖的人，心里想的是
  /// 「碰到的都算」。
  void _selectInMarquee() {
    final Rect? box = _marqueeWorld;
    final CanvasDocument? doc = _doc;
    if (box == null || doc == null || box.width < 2 || box.height < 2) return;
    setState(() {
      for (final CanvasNode node in doc.nodes) {
        if (node.rect.overlaps(box)) _selected.add(node.id);
      }
    });
  }

  /// 全选。
  void selectAll() {
    final CanvasDocument? doc = _doc;
    if (doc == null) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(doc.nodes.map((CanvasNode n) => n.id))
        ..addAll(doc.edges.map((CanvasEdge e) => e.id));
    });
  }

  /// 复制选中的卡片（连同它们之间的边）。
  void copySelection() {
    final CanvasDocument? doc = _doc;
    if (doc == null || _selected.isEmpty) return;
    final List<CanvasNode> nodes = doc.nodes
        .where((CanvasNode n) => _selected.contains(n.id))
        .toList();
    if (nodes.isEmpty) return;
    final Set<String> ids = nodes.map((CanvasNode n) => n.id).toSet();
    _clipboard = encodeCanvas(
      CanvasDocument(
        nodes: nodes,
        // 只带上「两端都在选区里」的边。一端在外面的，粘出来会连到一张
        // 没被复制的卡片上，那是个悬空引用。
        edges: doc.edges
            .where(
              (CanvasEdge e) =>
                  ids.contains(e.fromNode) && ids.contains(e.toNode),
            )
            .toList(),
      ),
    );
  }

  /// 粘贴。偏移 +20,+20，粘完选中粘出来的那一批。
  void pasteClipboard() {
    final String? raw = _clipboard;
    if (raw == null || _doc == null) return;
    final CanvasDocument clip;
    try {
      clip = parseCanvas(raw);
    } on CanvasFormatException {
      return;
    }
    _pasteFrom(clip);
  }

  /// 原地复制（Ctrl+D）。
  void duplicateSelection() {
    if (_doc == null || _selected.isEmpty) return;
    copySelection();
    pasteClipboard();
  }

  void _pasteFrom(CanvasDocument clip) {
    final CanvasDocument doc = _doc!;
    // 换 id、挪位置都在 **JSON 层**做，然后整体解析回来。
    final Map<String, Object?> json = clip.toJson();
    final List<Object?> rawNodes =
        (json['nodes'] as List<Object?>?) ?? const <Object?>[];
    final List<Object?> rawEdges =
        (json['edges'] as List<Object?>?) ?? const <Object?>[];

    final Map<String, String> remap = <String, String>{};
    const double offset = 20;
    for (final Object? raw in rawNodes) {
      final Map<String, Object?> node = (raw! as Map<Object?, Object?>)
          .cast<String, Object?>();
      final String? old = node['id'] as String?;
      if (old == null) continue;
      final String next = newCanvasId();
      remap[old] = next;
      node['id'] = next;
      node['x'] = ((node['x'] as num?)?.toDouble() ?? 0) + offset;
      node['y'] = ((node['y'] as num?)?.toDouble() ?? 0) + offset;
    }
    final List<Object?> keptEdges = <Object?>[];
    for (final Object? raw in rawEdges) {
      final Map<String, Object?> edge = (raw! as Map<Object?, Object?>)
          .cast<String, Object?>();
      final String? from = remap[edge['from']];
      final String? to = remap[edge['to']];
      if (from == null || to == null) continue;
      edge['id'] = newCanvasId();
      edge['from'] = from;
      edge['to'] = to;
      keptEdges.add(edge);
    }
    json['nodes'] = rawNodes;
    json['edges'] = keptEdges;

    final CanvasDocument pasted;
    try {
      pasted = parseCanvas(jsonEncode(json));
    } on CanvasFormatException {
      return;
    }

    _mutate(() {
      doc.nodes.addAll(pasted.nodes);
      doc.edges.addAll(pasted.edges);
      _selected
        ..clear()
        ..addAll(pasted.nodes.map((CanvasNode n) => n.id));
    });
  }

  /// 方向键微调。
  void nudgeSelection(double dx, double dy) {
    final CanvasDocument? doc = _doc;
    if (doc == null || _selected.isEmpty) return;
    _mutate(() {
      for (final CanvasNode node in doc.nodes) {
        if (!_selected.contains(node.id)) continue;
        node.x += dx;
        node.y += dy;
      }
    });
  }

  /// 给选中的节点换色。null = 恢复默认。
  void setSelectionColor(String? value) {
    final CanvasDocument? doc = _doc;
    if (doc == null || _selected.isEmpty) return;
    _mutate(() {
      for (final CanvasNode node in doc.nodes) {
        if (_selected.contains(node.id)) node.color = value;
      }
    });
  }

  /// 等比放大 / 缩小选中的卡片（`Ctrl+=` / `Ctrl+-`）。
  ///
  /// 锚在**中心**而不是左上角：连按五下之后卡片还在原地，不会一路往右下角
  /// 爬。撞到最小尺寸就停在最小尺寸，不会因为继续按而翻成负宽。
  /// `Ctrl+=` / `Ctrl+-`：**改字，不改框**。
  ///
  /// 这是 graphif 的「调整大小」：按下去字变大变小，卡片跟着字重新贴合，
  /// 所以看起来是「整张卡变大」，本质上动的是字号倍率。把框拉大而字不动，
  /// 得到的是「一张卡里空了一大片」，那是另一件事。
  ///
  /// 文件 / 链接卡片没有「文字即内容」这回事（它们是固定样式的引用卡），
  /// 所以对它们仍然是改框。
  void resizeSelectionBy(double factor) {
    final CanvasDocument? doc = _doc;
    if (doc == null || _selected.isEmpty) return;
    _mutate(() {
      for (final CanvasNode node in doc.nodes) {
        if (!_selected.contains(node.id)) continue;
        if (node is TextNode) {
          node.scale *= factor;
          _fitTextNode(node);
          continue;
        }
        if (node is GroupNode) {
          // 分组框是用户圈出来的一块区域，不能跟着标题字号变——只放大标题。
          node.scale *= factor;
          continue;
        }
        final double w = math.max(canvasMinSize, node.width * factor);
        final double h = math.max(canvasMinSize, node.height * factor);
        node.x += (node.width - w) / 2;
        node.y += (node.height - h) / 2;
        node.width = w;
        node.height = h;
      }
    });
  }

  // ------------------------------------------------------------------ 搜索

  /// 一张卡片「能被搜到」的那段文字。
  ///
  /// 文件卡片搜路径、链接卡片搜网址：卡片上印的就是这两个，眼睛看到什么
  /// 就该能搜到什么。
  String _searchTextOf(CanvasNode node) => switch (node) {
    TextNode(:final String text) => text,
    GroupNode(:final String? label) => label ?? '',
    FileNode(:final String file) => file,
    LinkNode(:final String url) => url,
  };

  void openSearch() {
    _commitEdit();
    _detailsOpen = false;
    setState(() {
      _searchOpen = true;
      _searchHits = const <String>[];
      _searchCursor = 0;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_searchOpen) return;
      _searchFocus.requestFocus();
      _search.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _search.text.length,
      );
    });
  }

  void _resetSearch() {
    _searchOpen = false;
    _searchHits = const <String>[];
    _searchCursor = 0;
    _search.clear();
  }

  void closeSearch() {
    if (!_searchOpen) return;
    setState(_resetSearch);
    if (mounted) _focus.requestFocus();
  }

  /// 重新算命中，并跳到第一个。
  void _applySearch() {
    final CanvasDocument? doc = _doc;
    final String query = _search.text.trim().toLowerCase();
    final List<String> hits = <String>[];
    if (doc != null && query.isNotEmpty) {
      for (final CanvasNode node in doc.nodes) {
        if (_searchTextOf(node).toLowerCase().contains(query)) {
          hits.add(node.id);
        }
      }
    }
    setState(() {
      _searchHits = hits;
      _searchCursor = 0;
    });
    _focusHit(0);
  }

  void nextHit() => _focusHit(_searchCursor + 1);

  void previousHit() => _focusHit(_searchCursor - 1);

  /// 跳到第 [index] 个命中（越界就绕回来），选中它并把镜头移过去。
  ///
  /// 只移镜头不改缩放：搜索是「这张卡在哪」，不是「把它放大给我看」。
  void _focusHit(int index) {
    if (_searchHits.isEmpty) return;
    final int n = _searchHits.length;
    final int i = ((index % n) + n) % n;
    final CanvasNode? node = _doc?.nodeById(_searchHits[i]);
    if (node == null) return;
    setState(() {
      _searchCursor = i;
      _selected
        ..clear()
        ..add(node.id);
    });
    _animateTo(_camera.movedTo(node.rect.center));
  }

  // ---------------------------------------------------------- 详细信息面板

  /// 搜索框在屏幕上的位置：贴着上边、水平居中，压在上边标尺下面一点。
  Rect get _searchRect {
    const double width = 360;
    const double height = 42;
    final double maxLeft = _stage.width - width - 12;
    final double left = maxLeft <= 12 ? 12 : (_stage.width - width) / 2;
    return Rect.fromLTWH(left, canvasRulerThickness + 10, width, height);
  }

  /// 面板在屏幕上的矩形。没给 [_detailsOrigin] 就贴在右下角。
  Rect get _detailsRect {
    final Offset origin =
        _detailsOrigin ??
        Offset(
          math.max(12, _stage.width - _detailsSize.width - 16),
          math.max(12, _stage.height - _detailsSize.height - 16),
        );
    return origin & _detailsSize;
  }

  /// 面板右下角那个拖拽握把。
  Rect get _detailsGripRect => Rect.fromLTWH(
    _detailsRect.right - canvasDetailsGripSide,
    _detailsRect.bottom - canvasDetailsGripSide,
    canvasDetailsGripSide,
    canvasDetailsGripSide,
  );

  /// 面板正在看的那张卡片。面板没开、或不是单选，就没有。
  CanvasNode? get _detailsNode {
    if (!_detailsOpen || _readOnly || _selected.length != 1) return null;
    return _doc?.nodeById(_selected.first);
  }

  /// 打开详细信息面板。目标就是当前那一张单选。
  void openDetails() {
    if (_readOnly || _selected.length != 1) return;
    _commitEdit();
    setState(() => _detailsOpen = true);
  }

  void closeDetails() {
    if (!_detailsOpen) return;
    setState(() => _detailsOpen = false);
    if (mounted) _focus.requestFocus();
  }

  /// 选中卡片右上角那颗小图标（屏幕坐标命中）。
  String? _detailsIconAt(Offset screen) {
    if (_readOnly || _editingId != null || _selected.length != 1) return null;
    final CanvasNode? node = _doc?.nodeById(_selected.first);
    if (node == null) return null;
    final Rect rect = _rectToScreen(node.rect);
    if (rect.width < 24 || rect.height < 24) return null;
    // 图标本身只有 16px，给 3px 的容差，不然要瞄准。
    return canvasDetailsIconRect(rect).inflate(3).contains(screen)
        ? node.id
        : null;
  }

  // --------------------------------------------------------------- editing

  /// 这张卡片能编辑的那段文字。null = 不可编辑（文件卡片、链接卡片）。
  String? _editableText(CanvasNode node) => switch (node) {
    TextNode(:final String text) => text,
    GroupNode(:final String? label) => label ?? '',
    _ => null,
  };

  void _writeText(CanvasNode node, String value) {
    switch (node) {
      case TextNode():
        node.text = value;
        _fitTextNode(node);
      case GroupNode():
        // 空标签存 null：和别人交换文件时不会出现「有名字但是空的」分组。
        node.label = value.trim().isEmpty ? null : value;
      case FileNode():
      case LinkNode():
        break;
    }
  }

  /// 让文字卡片贴合自己的文字。
  ///
  /// 照着 `thinks-mindmap` 的导图节点来：**卡片就是文字**，不是一块固定的
  /// 面板再去装文字。不贴合的话，打两个字之后卡片下面就是一大片空白。
  ///
  /// **空文字不是例外，它只是内容恰好是那三个点**：宽 = [canvasEmptyDots]
  /// 量出来的宽 + 内边距（所以卡片刚好装下 `•••`，多一个像素都不给），
  /// 高 = 一行正文（和打完一行字的卡片**同高**，两张并排才对齐）。
  ///
  /// 曾经这里写过一堆常量（120×160、90×120、120×一行高……），每一版都被
  /// 指出「太大 / 太宽 / 太高」——因为空卡片本来就不该有自己的尺寸，它应该
  /// 和文字卡片是**同一个算法**。别再往这里加常量。
  ///
  /// **宽高都跟着内容双向走**：字多了变宽，删了字缩回来。没有「只长不缩」
  /// 这回事——那样删光文字之后卡片还摊着，看着就是一块空面板。手拖过的尺寸
  /// 只在拖的那一刻有效，一旦改字就以内容为准（文字卡片本来就没有「固定
  /// 宽度」这个概念）。
  ///
  /// 宽度上限是 [canvasTextMaxWidth]，超了就按上限折行，高度随之增长。
  void _fitTextNode(TextNode node) {
    // 字号倍率参与排版：`Ctrl+=` 放大的是字，卡片再按放大后的字重新贴合。
    // 内边距也一起放大——字大了一圈、边距不动，卡片会显得挤。
    final double scale = node.scale;
    final double pad = canvasCardPadding * scale;
    final TextStyle style = TextStyle(
      fontSize: AppText.ui * scale,
      height: 1.6,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );

    if (node.text.isEmpty) {
      // 宽：那三个点正好装下。
      final TextPainter dots = TextPainter(
        text: TextSpan(
          text: canvasEmptyDots,
          style: canvasEmptyDotsStyle(scale: scale),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final double width = dots.width + pad * 2 + canvasTextFitSlack;
      dots.dispose();

      // 高：一行正文。用 `' '` 量一行，和正文走同一个 TextPainter，不会漂。
      final TextPainter line = TextPainter(
        text: TextSpan(text: ' ', style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final double height = line.height + pad * 2;
      line.dispose();

      _resizeNodeAroundCenter(node, width, height);
      return;
    }

    // 折行上限也按倍率放大：字放大一倍，卡片就该能宽一倍，而不是把同一句
    // 话挤成好几行、越堆越高。
    final double maxWidth = math.max(canvasMinSize, canvasTextMaxWidth * scale);
    final double maxText = math.max(1, maxWidth - pad * 2);

    // 一行放得下要多宽。超过上限就按上限算，剩下的交给折行。
    final TextPainter single = TextPainter(
      text: TextSpan(text: node.text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: maxText);
    final double needed = single.width + pad * 2;
    single.dispose();

    // 宽**就是**文字需要的宽度（+ 那 1px 余量），不看 node.width：
    // 字多了变宽、字少了缩回去、字号小了跟着小，宽度永远跟着内容。
    // **没有下限**：`canvasMinSize` 只管手拖 / 键盘改框，不管贴合——字缩到
    // 一半，卡片就该只有一半宽，留一个 40px 的底就等于「宽度是固定的」。
    final double width = math.min(needed + canvasTextFitSlack, maxWidth);

    final TextPainter block = TextPainter(
      text: TextSpan(text: node.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, width - pad * 2));
    final double height = block.height + pad * 2;
    block.dispose();

    _resizeNodeAroundCenter(node, width, height);
  }

  /// 改尺寸但**锚在中心**：贴一次尺寸，卡片不会整体往右下角挪。
  void _resizeNodeAroundCenter(CanvasNode node, double width, double height) {
    node.x += (node.width - width) / 2;
    node.y += (node.height - height) / 2;
    node.width = width;
    node.height = height;
  }

  void _beginEdit(CanvasNode node) {
    final String? current = _editableText(node);
    if (current == null) return;
    _editor.text = current;
    // **全选**，光标不是停在末尾。graphif 的双击编辑态就是这样：内容整块
    // 高亮，随手一打就把旧的换掉，不用先 Ctrl+A 或者一路退格。
    // 新建的空卡片这里全选等于什么也没选，光标照样在框里，直接能打。
    _editor.selection = TextSelection(
      baseOffset: 0,
      extentOffset: current.length,
    );
    setState(() => _editingId = node.id);
    // 输入框这一帧才建出来，等它挂上再要焦点。少了这一步就得先点一下输入框
    // 才能打字——「随时可以输入」靠的就是它。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _editingId != node.id) return;
      _editorFocus.requestFocus();
      _editor.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _editor.text.length,
      );
    });
  }

  void _commitEdit() {
    if (_editingEdgeId != null) {
      _commitEdgeEdit();
      return;
    }
    final CanvasDocument? doc = _doc;
    final String? id = _editingId;
    if (id == null) return;
    if (doc != null) {
      final CanvasNode? node = doc.nodeById(id);
      if (node != null) _writeText(node, _editor.text);
    }
    setState(() => _editingId = null);
    widget.onChanged?.call();
    if (mounted) _focus.requestFocus();
  }

  // ---------------------------------------------------------- hit testing

  /// 最上面的那张卡片。后加的在上，所以倒着找。
  CanvasNode? _nodeAt(Offset world, {double tolerance = 0}) {
    final CanvasDocument? doc = _doc;
    if (doc == null) return null;
    for (int i = doc.nodes.length - 1; i >= 0; i--) {
      final CanvasNode node = doc.nodes[i];
      if (hitsRect(node.rect, world, tolerance: tolerance)) return node;
    }
    return null;
  }

  /// 单选时才有手柄。
  CanvasNode? get _singleSelection {
    if (_selected.length != 1) return null;
    return _doc?.nodeById(_selected.first);
  }

  /// 手柄的命中测试在**屏幕坐标**里做：手柄是固定 6px 的视觉尺寸。
  CanvasResizeHandle? _handleAt(Offset screen) {
    final CanvasNode? node = _singleSelection;
    if (node == null || _editingId != null) return null;
    final Rect rect = _rectToScreen(node.rect);
    if (rect.width < 12 || rect.height < 12) return null;
    for (final CanvasResizeHandle handle in CanvasResizeHandle.values) {
      if ((handle.at(rect) - screen).distance <= 7) return handle;
    }
    return null;
  }

  /// 悬停卡片四条边中点的圆点。
  ({CanvasNode node, CanvasSide side})? _connectDotAt(Offset screen) {
    final String? id = _hoverNodeId;
    if (id == null || _readOnly) return null;
    final CanvasNode? node = _doc?.nodeById(id);
    if (node == null) return null;
    final Rect rect = _rectToScreen(node.rect);
    if (rect.width < 20 || rect.height < 20) return null;
    for (final CanvasSide side in CanvasSide.values) {
      final Offset at = anchorOf(rect, side);
      if ((at - screen).distance <= 7) return (node: node, side: side);
    }
    return null;
  }

  List<CanvasEdgeVisual> _edgeVisuals() =>
      buildEdgeVisuals(document: _doc, selected: _selected);

  CanvasEdgeVisual? _edgeAt(Offset screen) {
    final Offset world = _toWorld(screen);
    return edgeAtVisual(_edgeVisuals(), world, tolerance: 6 / _camera.zoom);
  }

  /// 松手：落在另一张卡片上就建边，落在空白或自己身上就取消。
  void _finishConnect(Offset screen) {
    final CanvasDocument? doc = _doc;
    final String? fromId = _connectFromId;
    if (doc == null || fromId == null) return;
    final CanvasNode? target = _nodeAt(_toWorld(screen));
    if (target == null || target.id == fromId) return;

    final CanvasEdge edge = CanvasEdge(
      id: newCanvasId(),
      fromNode: fromId,
      toNode: target.id,
      // 只记出发那条边；目标那头交给自动选边。
      fromSide: _connectSide.name,
    );
    _mutate(() {
      doc.edges.add(edge);
      _selected
        ..clear()
        ..add(edge.id);
    });
  }

  // ------------------------------------------------------------ 边标签

  void _beginEdgeEdit(CanvasEdgeVisual visual) {
    _editor.text = visual.edge.label ?? '';
    _editor.selection = TextSelection.collapsed(offset: _editor.text.length);
    setState(() {
      _editingEdgeId = visual.edge.id;
      _editingId = null;
      _selected
        ..clear()
        ..add(visual.edge.id);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingEdgeId != null) _editorFocus.requestFocus();
    });
  }

  void _commitEdgeEdit() {
    final CanvasDocument? doc = _doc;
    final String? id = _editingEdgeId;
    if (id == null) return;
    final String text = _editor.text.trim();
    if (doc != null) {
      for (final CanvasEdge edge in doc.edges) {
        if (edge.id != id) continue;
        edge.label = text.isEmpty ? null : text;
        break;
      }
    }
    setState(() => _editingEdgeId = null);
    widget.onChanged?.call();
    if (mounted) _focus.requestFocus();
  }

  CanvasEdgeVisual? get _editingEdge {
    final String? id = _editingEdgeId;
    if (id == null) return null;
    for (final CanvasEdgeVisual visual in _edgeVisuals()) {
      if (visual.edge.id == id) return visual;
    }
    return null;
  }

  // ------------------------------------------------------------- pointers

  void _onPointerDown(PointerDownEvent e) {
    _lastPointer = e.localPosition;

    // 浮层自己吃掉的点击不往画布传：点搜索框不该清掉选中，点面板里的输入
    // 框也不该把正在编辑的卡片收掉。
    if (_searchOpen) {
      if (_searchRect.contains(e.localPosition)) return;
      closeSearch();
    }
    if (_detailsNode != null && _detailsRect.contains(e.localPosition)) {
      if (e.buttons & kPrimaryMouseButton != 0 &&
          _detailsGripRect.contains(e.localPosition)) {
        setState(() {
          _resizingDetails = true;
          // 把左上角钉死：不钉的话「贴右下角」的默认位置会让面板一边变大
          // 一边往左上跑。
          _detailsOrigin = _detailsRect.topLeft;
          _detailsGripFrom = e.localPosition;
          _detailsGripSize = _detailsSize;
        });
      }
      return;
    }

    // 点在自己正在用的输入框上：交给它自己（放光标、选字、拖选）。
    // 走到下面那句 `_focus.requestFocus()` 就等于把键盘从输入框手里抢回来，
    // `_editorFocus` 一失焦就 `_commitEdit`——用户只是想点一下换个光标位置，
    // 结果编辑被提交掉了。
    if (_editingId != null) {
      final CanvasNode? editing = _doc?.nodeById(_editingId!);
      if (editing != null &&
          _rectToScreen(editing.rect).contains(e.localPosition)) {
        return;
      }
    }
    if (_editingEdgeId != null && _edgeLabelRect.contains(e.localPosition)) {
      return;
    }

    _focus.requestFocus();

    // 点别处就先把正在编辑的东西收掉（卡片或边标签）。
    if (_editingId != null || _editingEdgeId != null) _commitEdit();

    // 中键平移。右键留给菜单。
    if (e.buttons & kMiddleMouseButton != 0) {
      _stopCameraMotion();
      setState(() => _mode = _Interaction.panning);
      return;
    }
    if (e.buttons & kSecondaryMouseButton != 0) {
      _onSecondaryDown(e);
      return;
    }
    if (e.buttons & kPrimaryMouseButton == 0) return;

    if (_spaceHeld) {
      _stopCameraMotion();
      setState(() => _mode = _Interaction.panning);
      return;
    }

    final Offset world = _toWorld(e.localPosition);

    // 0. 选中卡片右上角那颗小图标：开详细信息面板。
    if (_detailsIconAt(e.localPosition) != null) {
      openDetails();
      return;
    }

    // 1. 手柄
    final CanvasResizeHandle? handle = _handleAt(e.localPosition);
    if (handle != null) {
      final CanvasNode node = _singleSelection!;
      _pushHistory();
      setState(() {
        _mode = _Interaction.resizing;
        _handle = handle;
        _resizeId = node.id;
        _resizeStart = node.rect;
        _dragFromScreen = e.localPosition;
      });
      return;
    }

    // 2. 连线圆点
    final ({CanvasNode node, CanvasSide side})? dot = _connectDotAt(
      e.localPosition,
    );
    if (dot != null) {
      setState(() {
        _mode = _Interaction.connecting;
        _connectFromId = dot.node.id;
        _connectSide = dot.side;
        _connectCursor = e.localPosition;
      });
      return;
    }

    // 3. 卡片
    final CanvasNode? node = _nodeAt(world);
    if (node != null) {
      if (_isDoubleTap(e.localPosition, node.id)) {
        // Ctrl + 双击 = 看详细信息，双击 = 就地改文字。文件卡片和链接卡片
        // 也一样：想看路径 / 网址也走这条路。
        if (HardwareKeyboard.instance.isControlPressed) {
          setState(() {
            _selected
              ..clear()
              ..add(node.id);
          });
          openDetails();
          return;
        }
        switch (node) {
          case FileNode(:final String file):
            widget.onOpenFile?.call(file);
          case LinkNode(:final String url):
            widget.onOpenLink?.call(url);
          default:
            _beginEdit(node);
        }
        return;
      }
      final bool additive = HardwareKeyboard.instance.isControlPressed;
      setState(() {
        if (additive) {
          if (!_selected.remove(node.id)) _selected.add(node.id);
        } else if (!_selected.contains(node.id)) {
          _selected
            ..clear()
            ..add(node.id);
        }
        // 一次拖动只记一步：在按下时记，不是每一帧都记。
        _pushHistory();
        _mode = _Interaction.maybeDrag;
        _dragFrom = world;
        _dragFromScreen = e.localPosition;
        _dragMoved = false;
        _dragOrigins
          ..clear()
          ..addEntries(
            _doc!.nodes
                .where((CanvasNode n) => _selected.contains(n.id))
                .map(
                  (CanvasNode n) =>
                      MapEntry<String, Offset>(n.id, Offset(n.x, n.y)),
                ),
          );
        // 拖分组时把它框住的卡片一起带走（嵌套分组也会被带一层）。
        if (node is GroupNode) {
          final Rect box = node.rect;
          for (final CanvasNode other in _doc!.nodes) {
            if (other.id == node.id) continue;
            if (!box.contains(other.rect.center)) continue;
            _dragOrigins.putIfAbsent(other.id, () => Offset(other.x, other.y));
          }
        }
      });
      return;
    }

    // 4. 连线。放在卡片后面：线画在卡片下面，压到卡片上的那一段
    // 应该点中卡片，而不是点中一条看不见的线。
    final CanvasEdgeVisual? edge = _edgeAt(e.localPosition);
    if (edge != null) {
      if (_isDoubleTap(e.localPosition, edge.edge.id)) {
        _beginEdgeEdit(edge);
        return;
      }
      setState(() {
        if (!HardwareKeyboard.instance.isControlPressed) _selected.clear();
        _selected.add(edge.edge.id);
      });
      return;
    }

    // 5. 空白
    if (_isDoubleTap(e.localPosition, '')) {
      createCard(at: world);
      return;
    }
    setState(() {
      if (!HardwareKeyboard.instance.isControlPressed) _selected.clear();
      _mode = _Interaction.marquee;
      _marqueeStart = world;
      _marqueeEnd = world;
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_resizingDetails) {
      final Offset delta = e.localPosition - _detailsGripFrom;
      setState(() {
        _detailsSize = Size(
          (_detailsGripSize.width + delta.dx).clamp(
            canvasDetailsMinWidth,
            canvasDetailsMaxWidth,
          ),
          (_detailsGripSize.height + delta.dy).clamp(
            canvasDetailsMinHeight,
            canvasDetailsMaxHeight,
          ),
        );
      });
      return;
    }
    switch (_mode) {
      case _Interaction.idle:
        break;
      case _Interaction.panning:
        final Offset delta = e.localPosition - _lastPointer;
        _lastPointer = e.localPosition;
        _panBy(delta);
      case _Interaction.marquee:
        setState(() => _marqueeEnd = _toWorld(e.localPosition));
      case _Interaction.maybeDrag:
        // 3px 的死区：按下时的一两像素抖动不该挪动卡片。
        if ((e.localPosition - _dragFromScreen).distance < 3) break;
        setState(() => _mode = _Interaction.dragging);
        _dragTo(e.localPosition);
      case _Interaction.dragging:
        _dragTo(e.localPosition);
      case _Interaction.resizing:
        _resizeTo(e.localPosition);
      case _Interaction.connecting:
        setState(() => _connectCursor = e.localPosition);
    }
  }

  void _dragTo(Offset screen) {
    final CanvasDocument? doc = _doc;
    if (doc == null) return;
    final Offset delta = _toWorld(screen) - _dragFrom;
    _dragMoved = true;
    setState(() {
      for (final CanvasNode node in doc.nodes) {
        final Offset? origin = _dragOrigins[node.id];
        if (origin == null) continue;
        node.x = origin.dx + delta.dx;
        node.y = origin.dy + delta.dy;
      }
    });
  }

  void _resizeTo(Offset screen) {
    final CanvasDocument? doc = _doc;
    final String? id = _resizeId;
    final CanvasResizeHandle? handle = _handle;
    if (doc == null || id == null || handle == null) return;
    final CanvasNode? node = doc.nodeById(id);
    if (node == null) return;
    final Offset delta = _toWorld(screen) - _toWorld(_dragFromScreen);
    final Rect next = resizeRect(
      _resizeStart,
      handle,
      delta,
      minSize: canvasCardMinSide,
    );
    setState(() {
      node.x = next.left;
      node.y = next.top;
      node.width = next.width;
      node.height = next.height;
    });
  }

  void _onPointerUp(PointerEvent e) {
    if (_resizingDetails) {
      setState(() => _resizingDetails = false);
      return;
    }
    if (_mode == _Interaction.idle) return;
    if (_mode == _Interaction.connecting) {
      _finishConnect(e.localPosition);
      setState(() {
        _mode = _Interaction.idle;
        _connectFromId = null;
        _connectCursor = null;
      });
      return;
    }
    if (_mode == _Interaction.marquee) {
      _selectInMarquee();
      setState(() {
        _mode = _Interaction.idle;
        _marqueeStart = null;
        _marqueeEnd = null;
      });
      return;
    }
    final bool moved = _mode == _Interaction.dragging && _dragMoved;
    final bool resized = _mode == _Interaction.resizing;

    setState(() {
      _mode = _Interaction.idle;
      _marqueeStart = null;
      _marqueeEnd = null;
      _handle = null;
      _resizeId = null;
      _dragOrigins.clear();
    });
    if (moved || resized) widget.onChanged?.call();
  }

  /// 滚轮 = **缩放**：往上放大、往下缩小，以光标为锚点。
  ///
  /// 平移不占滚轮——它归中键拖 / 空格拖 / WASD。滚轮如果兼做平移，缩放就得
  /// 按 Ctrl，那反而是反直觉的那一半（其它画布工具都是滚轮直接缩放）。
  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    // 浮层里的滚轮归它自己（面板内容可能超出高度要滚），不该顺手把画布
    // 也缩放一下。
    if (_overOverlay(e.localPosition)) return;
    // 指数映射：滚一格的感觉和当前缩放无关，缩到 8% 和放到 800% 一样跟手。
    _zoomAt(e.localPosition, math.exp(-e.scrollDelta.dy / 320));
  }

  /// 这个位置是不是落在某个浮层上。
  bool _overOverlay(Offset screen) =>
      (_searchOpen && _searchRect.contains(screen)) ||
      (_detailsNode != null && _detailsRect.contains(screen));

  void _onPointerHover(PointerHoverEvent e) {
    // 面板右下角是拖拽握把，光标要跟着变。
    if (_detailsNode != null && _detailsGripRect.contains(e.localPosition)) {
      if (_cursor != SystemMouseCursors.resizeUpLeftDownRight) {
        setState(() => _cursor = SystemMouseCursors.resizeUpLeftDownRight);
      }
      return;
    }
    // 浮层上面不放画布的光标（抓手、连线点、缩放手柄都不该在那儿出现）。
    if (_overOverlay(e.localPosition)) {
      if (_cursor != SystemMouseCursors.basic) {
        setState(() => _cursor = SystemMouseCursors.basic);
      }
      return;
    }
    if (_detailsIconAt(e.localPosition) != null) {
      if (_cursor != SystemMouseCursors.click) {
        setState(() => _cursor = SystemMouseCursors.click);
      }
      return;
    }
    final CanvasResizeHandle? handle = _handleAt(e.localPosition);
    final ({CanvasNode node, CanvasSide side})? dot = _connectDotAt(
      e.localPosition,
    );
    final CanvasNode? over = _nodeAt(
      _toWorld(e.localPosition),
      tolerance: 1 / _camera.zoom,
    );

    final MouseCursor next = handle != null
        ? _cursorFor(handle)
        : (dot != null
              ? SystemMouseCursors.precise
              : (_spaceHeld
                    ? SystemMouseCursors.grab
                    : (over != null
                          ? SystemMouseCursors.click
                          : SystemMouseCursors.basic)));
    final String? hoverId = dot?.node.id ?? over?.id;
    if (next != _cursor || hoverId != _hoverNodeId) {
      setState(() {
        _cursor = next;
        _hoverNodeId = hoverId;
      });
    }
  }

  static MouseCursor _cursorFor(CanvasResizeHandle handle) {
    if (handle == CanvasResizeHandle.topLeft ||
        handle == CanvasResizeHandle.bottomRight) {
      return SystemMouseCursors.resizeUpLeftDownRight;
    }
    if (handle == CanvasResizeHandle.topRight ||
        handle == CanvasResizeHandle.bottomLeft) {
      return SystemMouseCursors.resizeUpRightDownLeft;
    }
    if (handle == CanvasResizeHandle.topCenter ||
        handle == CanvasResizeHandle.bottomCenter) {
      return SystemMouseCursors.resizeUpDown;
    }
    return SystemMouseCursors.resizeLeftRight;
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _panZoomScale = 1;
    _lastPointer = e.localPosition;
    _stopCameraMotion();
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    CanvasCamera next = _camera.pannedBy(e.panDelta);
    if (e.scale != _panZoomScale && _panZoomScale > 0) {
      next = next.withZoomAt(
        e.localPosition,
        next.zoom * (e.scale / _panZoomScale),
        _stage,
      );
      _panZoomScale = e.scale;
    }
    setState(() => _camera = next);
  }

  // ----------------------------------------------------------------- 菜单

  void _onSecondaryDown(PointerDownEvent e) {
    final CanvasNode? node = _nodeAt(_toWorld(e.localPosition));
    if (node != null) {
      setState(() {
        if (!_selected.contains(node.id)) {
          _selected
            ..clear()
            ..add(node.id);
        }
      });
      _showCardMenu(e.position);
      return;
    }
    _showBoardMenu(e.position);
  }

  /// 右键卡片：换色 + 删除。
  Future<void> _showCardMenu(Offset global) async {
    final String? picked = await _popup(global, <PopupMenuEntry<String>>[
      for (final String? value in canvasColorChoices)
        PopupMenuItem<String>(
          value: 'color:${value ?? ''}',
          height: 34,
          child: Row(
            children: <Widget>[
              _ColorDot(value: value),
              const SizedBox(width: AppSpace.sm),
              Text(
                _colorLabel(value),
                style: const TextStyle(fontSize: AppText.ui),
              ),
            ],
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'delete',
        height: 34,
        child: Text('删除', style: TextStyle(fontSize: AppText.ui)),
      ),
    ]);
    if (!mounted || picked == null) return;
    if (picked == 'delete') {
      deleteSelection();
      return;
    }
    setSelectionColor(
      picked.substring('color:'.length).isEmpty
          ? null
          : picked.substring('color:'.length),
    );
  }

  Future<void> _showBoardMenu(Offset global) async {
    final String? picked = await _popup(global, <PopupMenuEntry<String>>[
      const PopupMenuItem<String>(
        value: 'text',
        height: 34,
        child: Text('新建文字卡片', style: TextStyle(fontSize: AppText.ui)),
      ),
      const PopupMenuItem<String>(
        value: 'file',
        height: 34,
        child: Text('新建文件卡片', style: TextStyle(fontSize: AppText.ui)),
      ),
      const PopupMenuItem<String>(
        value: 'link',
        height: 34,
        child: Text('新建链接卡片', style: TextStyle(fontSize: AppText.ui)),
      ),
      const PopupMenuItem<String>(
        value: 'group',
        height: 34,
        child: Text('新建分组', style: TextStyle(fontSize: AppText.ui)),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'fit',
        height: 34,
        child: Text('适应窗口', style: TextStyle(fontSize: AppText.ui)),
      ),
    ]);
    if (!mounted || picked == null) return;
    if (picked == 'fit') {
      fitToContent();
      return;
    }
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Offset local = box?.globalToLocal(global) ?? global;
    final Offset at = _toWorld(local);
    switch (picked) {
      case 'text':
        createCard(at: at);
      case 'file':
        await createFileCard(at: at);
      case 'link':
        await createLinkCard(at: at);
      case 'group':
        await createGroupCard(at: at);
    }
  }

  /// 菜单要一个「相对整个窗口」的位置。用 overlay 的坐标系，最省事。
  Future<String?> _popup(Offset global, List<PopupMenuEntry<String>> items) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final Offset local = box?.globalToLocal(global) ?? global;
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(local.dx, local.dy, local.dx, local.dy),
      items: items,
    );
  }

  static String _colorLabel(String? value) => switch (value) {
    null => '无颜色',
    '1' => '红色',
    '2' => '橙色',
    '3' => '黄色',
    '4' => '绿色',
    '5' => '青色',
    '6' => '紫色',
    _ => '自定义',
  };

  // -------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.space && _spaceHeld) {
        setState(() => _spaceHeld = false);
        return KeyEventResult.handled;
      }
      if (_isMoveKey(event.logicalKey)) {
        if (_moveKeys.remove(event.logicalKey)) {
          // 松手后靠惯性滑停，继续跑计时器。
          if (_ticker.isActive) _ensureTicking();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final HardwareKeyboard keys = HardwareKeyboard.instance;

    // 浮层开着的时候键盘归它。放在最前面，否则「空格」会先被当成抓手，
    // 搜索框里就打不出空格了。
    if (_searchOpen) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        closeSearch();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        if (keys.isShiftPressed) {
          previousHit();
        } else {
          nextHit();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (_detailsOpen && event.logicalKey == LogicalKeyboardKey.escape) {
      closeDetails();
      return KeyEventResult.handled;
    }

    // Esc 收编辑态要放在「输入框吃键盘」那道闸**前面**：正在编辑时键盘在
    // 输入框手里，不放行的话 Esc 就再也退不出编辑了。
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_editingId != null || _editingEdgeId != null) {
        _commitEdit();
        return KeyEventResult.handled;
      }
    }

    // Ctrl + `=` / `-` 调的是**字号**——它不会往输入框里打字，所以编辑时也
    // 放行。一边打字一边调字号是很自然的动作；被下面那道闸挡住的话，用户
    // 看到的只有「字号调不动 / 卡片宽度是死的」。
    if (keys.isControlPressed && _editingId != null) {
      final double? factor = _resizeFactorOf(event.logicalKey);
      if (factor != null) {
        resizeSelectionBy(factor);
        return KeyEventResult.handled;
      }
    }

    // ⚠️ 键盘在**输入框里**的时候，白板一个键都不许抢。
    //
    // 判 `hasPrimaryFocus` 而不是 `hasFocus`：本板的 `Focus` 是输入框的祖先，
    // 子节点拿到焦点时它的 `hasFocus` 也是 true，只有 `hasPrimaryFocus` 才
    // 区分得出「现在到底是谁在吃键盘」。判错的话，在卡片里打 `f` 会触发
    // 「适应窗口」、打 `w/a/s/d` 会平移、打空格会进抓手模式——一个字都打不进去。
    if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.space &&
        !keys.isControlPressed) {
      if (!_spaceHeld) setState(() => _spaceHeld = true);
      return KeyEventResult.handled;
    }

    // WASD 平移：没有修饰键时才生效，免得和快捷键抢。
    if (!keys.isControlPressed && !keys.isShiftPressed && !keys.isAltPressed) {
      if (_isMoveKey(event.logicalKey)) {
        if (_moveKeys.add(event.logicalKey)) _ensureTicking();
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_selected.isNotEmpty) {
        setState(_selected.clear);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      if (_selected.isEmpty) return KeyEventResult.ignored;
      deleteSelection();
      return KeyEventResult.handled;
    }
    final bool ctrl = keys.isControlPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (keys.isShiftPressed) {
        redo();
      } else {
        undo();
      }
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyY) {
      redo();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyA) {
      selectAll();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyC) {
      copySelection();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyV) {
      pasteClipboard();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyD) {
      duplicateSelection();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      openSearch();
      return KeyEventResult.handled;
    }
    // Ctrl + `=` / `-` 改的是**字号**，滚轮和 `[` `]` 改的才是视野。
    if (ctrl) {
      final double? factor = _resizeFactorOf(event.logicalKey);
      if (factor != null) {
        resizeSelectionBy(factor);
        return KeyEventResult.handled;
      }
    }
    // Enter = 就地改文字，Ctrl+Enter = 看详细信息。
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_selected.length != 1) return KeyEventResult.ignored;
      final CanvasNode? node = _doc?.nodeById(_selected.first);
      if (node == null) return KeyEventResult.ignored;
      if (ctrl) {
        openDetails();
        return KeyEventResult.handled;
      }
      // 文件卡片 / 链接卡片没有可编辑的文字，Enter 什么也不做。
      if (_editableText(node) == null) return KeyEventResult.ignored;
      _beginEdit(node);
      return KeyEventResult.handled;
    }
    // 方向键微调：1px，按住 Shift 10px。
    final (double dx, double dy) = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => (-1.0, 0.0),
      LogicalKeyboardKey.arrowRight => (1.0, 0.0),
      LogicalKeyboardKey.arrowUp => (0.0, -1.0),
      LogicalKeyboardKey.arrowDown => (0.0, 1.0),
      _ => (0.0, 0.0),
    };
    if ((dx != 0 || dy != 0) && _selected.isNotEmpty && !ctrl) {
      final double step = keys.isShiftPressed ? 10 : 1;
      nudgeSelection(dx * step, dy * step);
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.digit0) {
      resetZoom();
      return KeyEventResult.handled;
    }
    if (ctrl &&
        keys.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyH) {
      fitToContent();
      return KeyEventResult.handled;
    }

    // 视野：`[` / `]` 缩放，PageUp / PageDown / Home / End 翻页，F 重置。
    // 都不带修饰键——带 Ctrl 的那几个是文档操作，别混。
    if (!ctrl && !keys.isAltPressed) {
      if (event.logicalKey == LogicalKeyboardKey.bracketLeft) {
        zoomOut();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.bracketRight) {
        zoomIn();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.pageUp) {
        panByPage(CanvasPageDirection.up);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.pageDown) {
        panByPage(CanvasPageDirection.down);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.home) {
        panByPage(CanvasPageDirection.left);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.end) {
        panByPage(CanvasPageDirection.right);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        fitToSelection();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  static bool _isMoveKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.keyW ||
      key == LogicalKeyboardKey.keyA ||
      key == LogicalKeyboardKey.keyS ||
      key == LogicalKeyboardKey.keyD;

  /// `Ctrl` + 这几个键调字号：`=` / 小键盘 `+` 放大，`-` / 小键盘 `-` 缩小。
  ///
  /// 只在这一处列键位：编辑态那道闸前面也要用同一份，两边分开写迟早对不上。
  static double? _resizeFactorOf(LogicalKeyboardKey key) => switch (key) {
    LogicalKeyboardKey.equal ||
    LogicalKeyboardKey.numpadAdd => canvasResizeStep,
    LogicalKeyboardKey.minus ||
    LogicalKeyboardKey.numpadSubtract => 1 / canvasResizeStep,
    _ => null,
  };

  /// 自己数双击：同一处、同一个目标、上一个「双击窗口」还没关，就算。
  ///
  /// 用 [Timer] 而不是比时间戳，是因为时间戳在测试里推不动——`pump(700ms)`
  /// 推的是假时钟，`DateTime.now()` 一动不动。计时器走的就是假时钟。
  bool _isDoubleTap(Offset at, String target) {
    final bool doubled =
        (_tapWindow?.isActive ?? false) &&
        target == _lastTapTarget &&
        (at - _lastTapAt).distance <= 6;
    _tapWindow?.cancel();
    _tapWindow = null;
    _lastTapAt = at;
    _lastTapTarget = target;
    if (doubled) return true;
    _tapWindow = Timer(kDoubleTapTimeout, () => _tapWindow = null);
    return false;
  }

  // ---------------------------------------------------------------- build

  /// 框选的矩形（**世界**坐标）。没在框选就是 null。
  Rect? get _marqueeWorld {
    final Offset? a = _marqueeStart;
    final Offset? b = _marqueeEnd;
    if (a == null || b == null) return null;
    return Rect.fromPoints(a, b);
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final CanvasStyle style = CanvasStyle.of(p);
    final CanvasDocument? doc = _doc;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 尺寸只能在 build 里拿到，没有 `onSizeChanged` 这种回调。这里直接
        // 赋值而不 setState——正在 build，重建没有意义。
        final Size size = c.biggest;
        if (!size.isEmpty && size != _stage) _stage = size;
        if (!_stage.isEmpty && !identical(widget.document, _fittedDocument)) {
          _fittedDocument = widget.document;
          _camera = _cameraFor(doc, _stage);
          _targetZoom = _camera.zoom;
          _zoomAnchor = null;
          _tween = null;
          _cameraVelocity = Offset.zero;
        }

        final CanvasNode? editing = _editingId == null
            ? null
            : doc?.nodeById(_editingId!);
        final CanvasEdgeVisual? editingEdge = _editingEdge;

        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: _mode == _Interaction.panning
                ? SystemMouseCursors.grabbing
                : _cursor,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerUp,
              onPointerHover: _onPointerHover,
              onPointerSignal: _onPointerSignal,
              onPointerPanZoomStart: _onPanZoomStart,
              onPointerPanZoomUpdate: _onPanZoomUpdate,
              child: Container(
                color: style.background,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Positioned.fill(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: CanvasScenePainter(
                            document: doc,
                            camera: _camera,
                            style: style,
                            palette: p,
                            selected: Set<String>.of(_selected),
                            editingId: _editingId,
                            hoverNodeId: _hoverNodeId,
                            connectFromId: _connectFromId,
                            connectSide: _connectSide,
                            connectCursor: _connectCursor,
                            marquee: _marqueeWorld,
                            textCache: _textCache,
                            canEdit: !_readOnly,
                            emptyHint: _emptyHint(doc),
                          ),
                          isComplex: true,
                          willChange: true,
                        ),
                      ),
                    ),
                    // 编辑态：只在这张卡片的位置盖一个真输入框。显示仍由
                    // 画笔画，输入法、选区、光标交给 Flutter。
                    if (editing != null) _editorOverlay(p, editing),
                    if (editingEdge != null) _edgeLabelEditor(p, editingEdge),
                    if (_searchOpen) _searchOverlay(p),
                    if (_detailsNode case final CanvasNode node)
                      _detailsOverlay(p, node),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  (String, String)? _emptyHint(CanvasDocument? doc) {
    if (doc == null) {
      return ('这块白板还是空的', '中键拖动平移，滚轮缩放');
    }
    if (doc.isNotEmpty) return null;
    return ('这块白板还是空的', '双击空白处新建一张卡片');
  }

  /// 编辑态输入框：位置、字号、内边距都跟着摄像机走。
  ///
  /// ⚠️ 这里**必须**自己写全 [InputDecoration]，不能用 `InputDecoration.collapsed`：
  /// 全局 `inputDecorationTheme` 是 `filled: true` + `OutlineInputBorder`（给
  /// 搜索框、表单用的），`collapsed` 只把 `border` 置成 none，`filled` 会从
  /// 主题里漏进来——画布上就会出现一个带底色、带描边的「节点面板」。
  /// 编辑框在画布上必须是**隐形的**：卡片本身就是那个框。
  Widget _editorOverlay(AppPalette p, CanvasNode node) {
    final Rect rect = _rectToScreen(node.rect);
    final double zoom = _camera.zoom;
    final CellColor? color = canvasCellColor(node.color);
    final bool isGroup = node is GroupNode;
    // 浮层要和画笔排得一模一样，否则一进编辑字就跳一下。字号、内边距都要
    // 乘上节点的字号倍率（`Ctrl+=` 调过大小的卡片，编辑时不能缩回原大小）。
    final double scale = node.scale;
    final double fontSize =
        (isGroup ? canvasGroupLabelSize : AppText.ui) * scale * zoom;
    final Color ink = isGroup ? canvasGroupInk(p) : canvasCardInk(p, color);
    // 空卡片把占位文字摆在正中：和画笔画的「•••」同一个位置，一进编辑
    // 三个点变成「输入文字」，不会从中间跳到左上角去。
    final bool centered = !isGroup && _editableText(node)!.isEmpty;

    // `RenderEditable` 排版前会先把可用宽度扣掉「光标宽 + 1」给光标让位
    // （`editable.dart` 的 `_caretMargin`）。不补回来，输入框就比画笔少排
    // 几个像素——打满一行的卡片一进编辑，最后一个字被挤到第二行。
    // 再加 [canvasTextFitSlack]：贴合出来的宽度本来就在折行临界点上，多留
    // 这一点，输入框和画笔才都稳稳地排成一行。
    final double cursorWidth = math.max(1, 1.6 * zoom);
    final double inset =
        (isGroup ? canvasGroupPadding : canvasCardPadding) * scale * zoom;
    // 空卡片是居中摆放的，补在右边会把它推偏，而且空文字本来也不会折行。
    final double rightInset = centered
        ? inset
        : math.max(0, inset - cursorWidth - 1 - canvasTextFitSlack);

    return Positioned.fromRect(
      rect: rect,
      child: Container(
        padding: EdgeInsets.fromLTRB(inset, inset, rightInset, inset),
        alignment: centered ? Alignment.center : Alignment.topLeft,
        child: TextField(
          controller: _editor,
          focusNode: _editorFocus,
          // 文字卡片是多行的，Enter 必须是换行，退出编辑走 Esc / 点别处。
          // 分组标题只有一行，Enter 就是「改完了」——那是它唯一说得通的
          // 用法（graphif 的「Enter 退出编辑」在单行里才成立）。
          maxLines: isGroup ? 1 : null,
          textInputAction: isGroup
              ? TextInputAction.done
              : TextInputAction.newline,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          cursorWidth: cursorWidth,
          cursorColor: p.accent,
          style: TextStyle(
            fontSize: fontSize,
            height: isGroup ? 1.4 : 1.6,
            color: ink,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
          ),
          decoration: InputDecoration(
            isDense: true,
            isCollapsed: true,
            filled: false,
            fillColor: Colors.transparent,
            contentPadding: EdgeInsets.zero,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            // 文字卡片没有 hint：空卡片那个「•••」由画笔负责画，输入框只出
            // 一根光标。两边都画就成了两层占位，位置也一定会差一点点。
            hintText: isGroup ? '分组标题' : null,
            // 占位钉成一行：它会被算进装饰器的高度，折行会把正文顶上去。
            hintMaxLines: 1,
            hintStyle: TextStyle(
              fontSize: fontSize,
              color: p.textTertiary,
              fontFamily: AppFonts.ui,
              fontFamilyFallback: AppFonts.uiFallback,
            ),
          ),
          // 走 `_mutate` 而不是直接改：卡片尺寸会跟着文字变，不 setState 的话
          // 模型改了、画面还是旧的（画笔拿的是旧矩形）。
          onChanged: (String value) =>
              _mutate(() => _writeText(node, value), record: false),
          onTapOutside: (_) => _commitEdit(),
          onSubmitted: isGroup ? (_) => _commitEdit() : null,
        ),
      ),
    );
  }

  /// 边标签输入框的尺寸（屏幕像素）。
  static const double _edgeLabelWidth = 132;
  static const double _edgeLabelHeight = 26;

  /// 边标签输入框的矩形（屏幕坐标）。画和「点自己身上不要抢焦点」共用。
  Rect get _edgeLabelRect {
    final CanvasEdgeVisual? visual = _editingEdge;
    if (visual == null) return Rect.zero;
    return Rect.fromCenter(
      center: _toScreen(visual.geometry.pointAt(0.5)),
      width: _edgeLabelWidth,
      height: _edgeLabelHeight,
    );
  }

  /// 边标签的输入框：一条压在线上、居中的小输入框。
  Widget _edgeLabelEditor(AppPalette p, CanvasEdgeVisual visual) {
    final Rect rect = _edgeLabelRect;
    return Positioned.fromRect(
      rect: rect,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: p.surfaceRaised,
          borderRadius: AppRadius.smAll,
          border: Border.all(color: p.accent),
        ),
        alignment: Alignment.centerLeft,
        child: TextField(
          controller: _editor,
          focusNode: _editorFocus,
          maxLines: 1,
          style: TextStyle(
            fontSize: AppText.caption,
            color: p.textPrimary,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
          ),
          cursorColor: p.accent,
          // 同上：不能走 `InputDecoration.collapsed`，全局主题会把底色和描边
          // 漏进来，在那个小框里再套一层框。
          decoration: InputDecoration(
            isDense: true,
            isCollapsed: true,
            filled: false,
            fillColor: Colors.transparent,
            contentPadding: EdgeInsets.zero,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            hintText: '边标签',
            hintMaxLines: 1,
            hintStyle: TextStyle(
              fontSize: AppText.caption,
              color: p.textTertiary,
              fontFamily: AppFonts.ui,
              fontFamilyFallback: AppFonts.uiFallback,
            ),
          ),
          onTapOutside: (_) => _commitEdit(),
          onSubmitted: (_) => _commitEdit(),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 浮层：搜索

  /// 搜索框。贴在画布上边、水平居中，压在上边标尺下面一点。
  Widget _searchOverlay(AppPalette p) {
    final bool empty = _search.text.trim().isEmpty;
    final int total = _searchHits.length;
    final String counter = empty
        ? ''
        : (total == 0 ? '没有匹配' : '${_searchCursor + 1}/$total');
    return Positioned.fromRect(
      rect: _searchRect,
      child: CallbackShortcuts(
        // 快捷键挂在浮层自己身上，而不是靠事件冒泡到白板那层：输入框是
        // 单行的，Enter 会被它先吃掉一半。和挑笔记那个弹窗同一套写法。
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): nextHit,
          const SingleActivator(LogicalKeyboardKey.enter, shift: true):
              previousHit,
          const SingleActivator(LogicalKeyboardKey.escape): closeSearch,
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: p.surfaceRaised,
              borderRadius: AppRadius.mdAll,
              border: Border.all(color: p.accent),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: <Widget>[
                Icon(LucideIcons.search, size: 14, color: p.textTertiary),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: TextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    cursorColor: p.accent,
                    cursorWidth: 1.3,
                    style: TextStyle(
                      fontSize: AppText.ui,
                      height: 1.5,
                      color: p.textPrimary,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                      hintText: '搜索节点',
                      hintStyle: TextStyle(
                        fontSize: AppText.ui,
                        color: p.textTertiary,
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                      ),
                    ),
                    onChanged: (_) => _applySearch(),
                  ),
                ),
                if (counter.isNotEmpty) ...<Widget>[
                  const SizedBox(width: AppSpace.sm),
                  Text(
                    counter,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------ 浮层：详细信息

  /// 详细信息面板。一个能改文字、颜色、位置、尺寸的子窗口，右下角可拖拽。
  Widget _detailsOverlay(AppPalette p, CanvasNode node) {
    return Positioned.fromRect(
      rect: _detailsRect,
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: _detailsBody(p, node)),
            // 右下角的拖拽握把。只是画三道斜线，指针事件由外面那层
            // Listener 统一接（见 [_onPointerDown] 里的握把分支）。
            Positioned(
              right: 0,
              bottom: 0,
              width: canvasDetailsGripSide,
              height: canvasDetailsGripSide,
              child: CustomPaint(painter: _GripPainter(color: p.textTertiary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detailsBody(AppPalette p, CanvasNode node) {
    final CellColor? color = canvasCellColor(node.color);
    final String? editable = _editableText(node);
    return Container(
      decoration: BoxDecoration(
        color: p.surfaceRaised,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: p.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _detailsHeader(p, node),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (editable != null) ...<Widget>[
                    _detailsLabel(p, '文字'),
                    const SizedBox(height: 6),
                    _DetailsTextEditor(
                      // 换了卡片就整块重建：输入框的草稿属于那张卡，
                      // 不该被带到下一张上。
                      key: ValueKey<String>('details-text-${node.id}'),
                      initial: editable,
                      maxLines: node is GroupNode ? 1 : null,
                      onChanged: (String value) =>
                          _mutate(() => _writeText(node, value)),
                    ),
                    const SizedBox(height: 14),
                  ] else ...<Widget>[
                    _detailsLabel(p, node is FileNode ? '文件' : '网址'),
                    const SizedBox(height: 6),
                    SelectableText(
                      switch (node) {
                        FileNode(:final String file) => file,
                        LinkNode(:final String url) => url,
                        _ => '',
                      },
                      style: TextStyle(
                        fontSize: AppText.caption,
                        height: 1.5,
                        color: p.textSecondary,
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  _detailsLabel(p, '颜色'),
                  const SizedBox(height: 8),
                  _detailsColors(p, color),
                  const SizedBox(height: 14),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _NumField(
                          label: 'X',
                          value: node.x,
                          onSubmitted: (double v) => _mutate(() => node.x = v),
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: _NumField(
                          label: 'Y',
                          value: node.y,
                          onSubmitted: (double v) => _mutate(() => node.y = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _NumField(
                          label: '宽',
                          value: node.width,
                          min: canvasMinSize,
                          onSubmitted: (double v) =>
                              _mutate(() => node.width = v),
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: _NumField(
                          label: '高',
                          value: node.height,
                          min: canvasMinSize,
                          onSubmitted: (double v) =>
                              _mutate(() => node.height = v),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsHeader(AppPalette p, CanvasNode node) {
    final (String title, IconData icon) = switch (node) {
      TextNode() => ('文字卡片', LucideIcons.type),
      GroupNode() => ('分组', LucideIcons.frame),
      FileNode() => ('文件卡片', LucideIcons.fileText),
      LinkNode() => ('链接卡片', LucideIcons.link),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.outline)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 13, color: p.textTertiary),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textSecondary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          _DetailsIconButton(
            icon: LucideIcons.x,
            tooltip: '关闭',
            onTap: closeDetails,
          ),
        ],
      ),
    );
  }

  Widget _detailsLabel(AppPalette p, String text) => Text(
    text,
    style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
  );

  /// 面板里的六个色点。当前色高亮，点一下换过去。
  Widget _detailsColors(AppPalette p, CellColor? current) {
    return Row(
      children: <Widget>[
        for (final String? value in canvasColorChoices)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setSelectionColor(value),
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: canvasSwatchFill(p, canvasCellColor(value)),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _sameColor(current, canvasCellColor(value))
                        ? p.accent
                        : p.outline,
                    width: _sameColor(current, canvasCellColor(value)) ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 两个颜色算不算同一个。`null`（无颜色）也要能比。
  static bool _sameColor(CellColor? a, CellColor? b) {
    if (a == null || b == null) return a == null && b == null;
    return a == b;
  }
}

/// 面板里的多行文字框。
///
/// 自己的控制器，不和卡片上的就地编辑共用：面板和画布可能同时开着，共用
/// 一个 controller 会互相把对方的字冲掉。
class _DetailsTextEditor extends StatefulWidget {
  const _DetailsTextEditor({
    super.key,
    required this.initial,
    required this.onChanged,
    this.maxLines,
  });

  final String initial;
  final ValueChanged<String> onChanged;

  /// 分组标题是单行，按 Enter 就是「改完了」。
  final int? maxLines;

  @override
  State<_DetailsTextEditor> createState() => _DetailsTextEditorState();
}

class _DetailsTextEditorState extends State<_DetailsTextEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: TextField(
        controller: _controller,
        maxLines: widget.maxLines,
        cursorColor: p.accent,
        cursorWidth: 1.3,
        style: TextStyle(
          fontSize: AppText.ui,
          height: 1.5,
          color: p.textPrimary,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
        decoration: InputDecoration.collapsed(
          hintText: '输入文字…',
          hintStyle: TextStyle(
            fontSize: AppText.ui,
            color: p.textTertiary,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
          ),
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}

/// 面板里的一个数字输入框（位置 / 尺寸）。
///
/// 只在**提交**时写回，不是每敲一个字就写：边打字边改宽度，卡片会跟着
/// 每一帧跳，而且「1」「12」「120」会各记一次撤销。
class _NumField extends StatefulWidget {
  const _NumField({
    required this.label,
    required this.value,
    required this.onSubmitted,
    this.min,
  });

  final String label;
  final double value;
  final ValueChanged<double> onSubmitted;

  /// 下限（尺寸用）。null = 位置，可以是负数。
  final double? min;

  @override
  State<_NumField> createState() => _NumFieldState();
}

class _NumFieldState extends State<_NumField> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(widget.value),
  );
  final FocusNode _focus = FocusNode(debugLabel: 'nrs-canvas-num');

  @override
  void initState() {
    super.initState();
    // 焦点一丢就提交：点面板别处时输入的数字不该被吞掉。
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  static String _format(double value) {
    final double rounded = value.roundToDouble();
    if ((value - rounded).abs() < 0.05) return rounded.round().toString();
    return value.toStringAsFixed(1);
  }

  void _commit() {
    final double? parsed = double.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = _format(widget.value);
      return;
    }
    final double next = widget.min == null
        ? parsed
        : math.max(widget.min!, parsed);
    _controller.text = _format(next);
    if (next != widget.value) widget.onSubmitted(next);
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outline),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: <Widget>[
          Text(
            widget.label,
            style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              maxLines: 1,
              cursorColor: p.accent,
              cursorWidth: 1.3,
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textPrimary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
              decoration: const InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => _commit(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板标题栏上的一个小图标按钮。
class _DetailsIconButton extends StatefulWidget {
  const _DetailsIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_DetailsIconButton> createState() => _DetailsIconButtonState();
}

class _DetailsIconButtonState extends State<_DetailsIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: _hovered ? p.accentSoft : Colors.transparent,
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(widget.icon, size: 13, color: p.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// 面板右下角的三道斜线：告诉人「这里能拖」。
class _GripPainter extends CustomPainter {
  const _GripPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    for (final double d in <double>[6, 10, 14]) {
      canvas.drawLine(
        Offset(size.width - d, size.height - 3),
        Offset(size.width - 3, size.height - d),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}

/// 换色菜单里的一个小圆点。
///
/// 卡片身上的颜色只走描边（见 [canvasCardBorder]），但菜单里必须是**实心**
/// 的色块，否则六个选项看起来一模一样。
class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.value});

  final String? value;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final CellColor? color = canvasCellColor(value);
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: canvasSwatchFill(p, color),
        shape: BoxShape.circle,
        border: Border.all(color: canvasCardBorder(p, color)),
      ),
    );
  }
}
