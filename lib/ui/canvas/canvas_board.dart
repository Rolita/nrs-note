import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/canvas_document.dart';
import '../../core/utils/canvas_geometry.dart';
import '../../core/utils/table_model.dart' show CellColor;
import 'canvas_card.dart';
import 'canvas_edge_painter.dart';
import 'canvas_grid_painter.dart';
import 'canvas_pickers.dart';
import 'canvas_style.dart';
import 'canvas_toolbar.dart';

/// 白板。一块可以无限平移缩放的画布，卡片和连线都摆在上面。
///
/// 四条设计约束，改之前先读：
///
/// * **只有一层 [Listener]**。手柄、卡片、连线、空白，所有目标全在这一个
///   入口里按顺序做命中测试，再用 [_Interaction] 记「现在在干什么」。
///   用嵌套 `GestureDetector` 会互相抢手势，最后变成「拖卡片时画布跟着
///   平移」这种经典 bug。
/// * **卡片是真 Widget，其余是画的**。要能选中文字、要能塞进 `TextField`
///   编辑；但手柄只有 6px，做成 Widget 就要参与布局和命中测试，而命中测试
///   我们已经自己做了。
/// * **点阵在屏幕坐标里算**。世界坐标铺满再整体变换，缩放越小画得越多。
/// * **空白处左键拖是框选，不是平移**。平移交给滚轮、中键、空格。
class CanvasBoard extends StatefulWidget {
  const CanvasBoard({
    super.key,
    required this.document,
    this.onChanged,
    this.onViewportChanged,
    this.files = const <({String path, String title})>[],
    this.onOpenFile,
    this.onOpenLink,
  });

  /// 要画的文档。null = 只读空板（还不能编辑），此时不响应任何修改。
  final CanvasDocument? document;

  /// 文档被改过（新建 / 移动 / 缩放 / 改文字 / 换色 / 删除）。
  /// P6 会用它触发自动保存。
  final VoidCallback? onChanged;

  /// 视口变了（缩放或平移）。
  final ValueChanged<CanvasViewport>? onViewportChanged;

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

  /// 中键 / 空格拖动：平移画布。
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

class CanvasBoardState extends State<CanvasBoard> {
  final FocusNode _focus = FocusNode(debugLabel: 'nrs-canvas');

  CanvasViewport _viewport = const CanvasViewport();
  Size _stage = Size.zero;
  bool _didInitialFit = false;

  _Interaction _mode = _Interaction.idle;

  /// 选中的节点 id。P3 起还会放边 id。
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
  /// 内容上——存屏幕坐标的话滚轮一滚，框就跟着画布跑了。
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

  /// 空格按住 = 临时切换成抓手。
  bool _spaceHeld = false;

  /// 悬停光标。手柄上是缩放箭头，空格时是抓手。
  MouseCursor _cursor = SystemMouseCursors.basic;

  /// 上一次点击的位置和目标，和一个「双击窗口」的计时器。
  ///
  /// 自己数双击而不用 `DoubleTapGestureRecognizer`：那个识别器会往手势竞技场
  /// 里塞一个长按分支，和「拖空白 = 框选」抢同一串指针；而且它在测试里会留下
  /// 一个 40ms 的挂起计时器。这里就是一个 `Timer`，[dispose] 里能干净地取消。
  Timer? _tapWindow;
  Offset _lastTapAt = Offset.zero;
  String _lastTapTarget = '';

  /// 触控板：上一帧的累计缩放，用来算增量。
  double _panZoomScale = 1;

  CanvasViewport get viewport => _viewport;

  CanvasDocument? get _doc => widget.document;

  bool get _readOnly => _doc == null;

  /// 让白板拿到键盘。外壳切到白板时调它——`autofocus` 只在挂载那一次
  /// 生效，切回来时不会重来一遍。
  void requestFocus() => _focus.requestFocus();

  // 测试探针。`CustomPaint` 不进语义树，界面上也问不出「现在缩放多少」，
  // 所以把状态摊开给测试看，和 `graph_view.dart` 的 `debug*` 一个路子。
  double get debugZoom => _viewport.zoom;
  Offset get debugOffset => _viewport.offset;
  Size get debugStage => _stage;
  bool get debugPanning => _mode == _Interaction.panning;
  bool get debugDragging => _mode == _Interaction.dragging;
  bool get debugResizing => _mode == _Interaction.resizing;
  Rect? get debugMarquee => _marqueeRect;
  Set<String> get debugSelection => Set<String>.of(_selected);
  String? get debugEditing => _editingId;
  String? debugColorOf(String id) => _doc?.nodeById(id)?.color;
  String? get debugEditingEdge => _editingEdgeId;
  int get debugEdgeCount => _doc?.edges.length ?? 0;
  String? debugLabelOf(String id) {
    for (final CanvasEdge edge in _doc?.edges ?? const <CanvasEdge>[]) {
      if (edge.id == id) return edge.label;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _editorFocus.addListener(() {
      // 输入框丢了焦点（点了别处、切了窗口）就收工。
      if (!_editorFocus.hasFocus && _editingId != null) _commitEdit();
    });
  }

  @override
  void dispose() {
    _tapWindow?.cancel();
    _editor.dispose();
    _editorFocus.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 改文档的唯一入口：改完重画一遍，再告诉外面「脏了」。
  void _mutate(VoidCallback change) {
    if (_readOnly) return;
    setState(change);
    widget.onChanged?.call();
  }

  // ------------------------------------------------------------- viewport

  void _applyViewport(CanvasViewport next) {
    if (next == _viewport) return;
    setState(() => _viewport = next);
    widget.onViewportChanged?.call(next);
  }

  void zoomIn() => _zoomBy(1.22);

  void zoomOut() => _zoomBy(1 / 1.22);

  void resetZoom() => _applyViewport(
    _viewport.withZoomAt(_stage.center(Offset.zero), 1),
  );

  void _zoomBy(double factor) =>
      _applyViewport(_viewport.zoomedAt(_stage.center(Offset.zero), factor));

  /// 适应窗口。空板时退化成「原点落在正中」，不然内容矩形是 0×0，
  /// 算出来的 zoom 会顶到上限。
  void fitToContent() {
    final Rect content = _contentBounds();
    _applyViewport(
      content.width <= 0 || content.height <= 0
          ? CanvasViewport(offset: _stage.center(Offset.zero))
          : CanvasViewport.fit(content, _stage),
    );
  }

  Rect _contentBounds() {
    final CanvasDocument? doc = _doc;
    if (doc == null || doc.isEmpty) return Rect.zero;
    return unionOf(doc.nodes.map((CanvasNode n) => n.rect));
  }

  /// 新卡片落在视口正中（或指定位置），对齐到网格。
  void createCard({Offset? at}) {
    final CanvasDocument? doc = _doc;
    if (doc == null) return;
    final Offset center =
        at ?? _viewport.toWorld(_stage.center(Offset.zero));
    final TextNode node = TextNode(
      id: newCanvasId(),
      x: snapToGrid(center.dx - canvasDefaultWidth / 2),
      y: snapToGrid(center.dy - canvasDefaultHeight / 2),
      width: canvasDefaultWidth,
      height: canvasDefaultHeight,
    );
    _mutate(() {
      doc.nodes.add(node);
      _selected
        ..clear()
        ..add(node.id);
    });
    _beginEdit(node);
  }

  /// 把一张卡片放到视口正中（或指定位置），对齐到网格并选中它。
  T _addCard<T extends CanvasNode>(T node, {Offset? at}) {
    final CanvasDocument doc = _doc!;
    final Offset center = at ?? _viewport.toWorld(_stage.center(Offset.zero));
    node.x = snapToGrid(center.dx - node.width / 2);
    node.y = snapToGrid(center.dy - node.height / 2);
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

  // --------------------------------------------------------------- editing

  /// 这张卡片能编辑的那段文字。null = 不可编辑（文件卡片、链接卡片）。
  ///
  /// 文字卡片编的是正文，分组编的是标签——两处都只有一行 `String`，
  /// 用一个开关比开两套编辑状态省事。
  String? _editableText(CanvasNode node) => switch (node) {
    TextNode(:final String text) => text,
    GroupNode(:final String? label) => label ?? '',
    _ => null,
  };

  void _writeText(CanvasNode node, String value) {
    switch (node) {
      case TextNode():
        node.text = value;
      case GroupNode():
        // 空标签存 null：规范里 label 是可选的，空字符串会在别人那边
        // 变成一个「有名字但是空的」分组。
        node.label = value.trim().isEmpty ? null : value;
      case FileNode():
      case LinkNode():
        break;
    }
  }

  void _beginEdit(CanvasNode node) {
    final String? current = _editableText(node);
    if (current == null) return;
    _editor.text = current;
    _editor.selection = TextSelection.collapsed(offset: current.length);
    setState(() => _editingId = node.id);
    // 输入框这一帧才建出来，等它挂上再要焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingId == node.id) _editorFocus.requestFocus();
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
    _focus.requestFocus();
  }

  // ---------------------------------------------------------- hit testing

  /// 最上面的那张卡片。后加的在上，所以倒着找。
  ///
  /// [tolerance] 只给悬停用：连线圆点摆在卡片边界**上**，而 `Rect.contains`
  /// 不含右边界和下边界。不给一点容差的话，指针正好压在圆点上时反而判成
  /// 「不在卡片上」，圆点就永远点不到。
  CanvasNode? _nodeAt(Offset world, {double tolerance = 0}) {
    final CanvasDocument? doc = _doc;
    if (doc == null) return null;
    for (int i = doc.nodes.length - 1; i >= 0; i--) {
      final CanvasNode node = doc.nodes[i];
      if (hitsRect(node.rect, world, tolerance: tolerance)) return node;
    }
    return null;
  }

  /// 单选时才有手柄。多选时不给手柄——八个手柄指向哪一张卡片会说不清。
  CanvasNode? get _singleSelection {
    if (_selected.length != 1) return null;
    return _doc?.nodeById(_selected.first);
  }

  /// 手柄的命中测试在**屏幕坐标**里做：手柄是 6px 的视觉尺寸，不该跟着
  /// 缩放变成一个永远点不到的点。
  CanvasResizeHandle? _handleAt(Offset screen) {
    final CanvasNode? node = _singleSelection;
    if (node == null || _editingId != null) return null;
    final Rect rect = _viewport.rectToScreen(node.rect);
    if (rect.width < 12 || rect.height < 12) return null;
    for (final CanvasResizeHandle handle in CanvasResizeHandle.values) {
      if ((handle.at(rect) - screen).distance <= 7) return handle;
    }
    return null;
  }

  /// 悬停卡片四条边中点的圆点。只给**悬停的那一张**——每张卡片都挂着
  /// 四个点，屏幕上会全是点。
  ({CanvasNode node, CanvasSide side})? _connectDotAt(Offset screen) {
    final String? id = _hoverNodeId;
    if (id == null || _readOnly) return null;
    final CanvasNode? node = _doc?.nodeById(id);
    if (node == null) return null;
    final Rect rect = _viewport.rectToScreen(node.rect);
    if (rect.width < 20 || rect.height < 20) return null;
    for (final CanvasSide side in CanvasSide.values) {
      final Offset at = anchorOf(rect, side);
      if ((at - screen).distance <= CanvasConnectDotsPainter.dotRadius + 2) {
        return (node: node, side: side);
      }
    }
    return null;
  }

  /// 当前视口下的所有连线。命中测试和绘制都用这一份，免得出现两套公式。
  List<CanvasEdgeVisual> _edgeVisuals() => buildEdgeVisuals(
    document: _doc,
    viewport: _viewport,
    selected: _selected,
  );

  CanvasEdgeVisual? _edgeAt(Offset screen) =>
      edgeAt(_edgeVisuals(), screen, tolerance: 6);

  /// 松手：落在另一张卡片上就建边，落在空白或自己身上就取消。
  void _finishConnect(Offset screen) {
    final CanvasDocument? doc = _doc;
    final String? fromId = _connectFromId;
    if (doc == null || fromId == null) return;
    final CanvasNode? target = _nodeAt(_viewport.toWorld(screen));
    if (target == null || target.id == fromId) return;

    final CanvasEdge edge = CanvasEdge(
      id: newCanvasId(),
      fromNode: fromId,
      toNode: target.id,
      // 只记出发那条边；目标那头交给自动选边，线才不会为了对齐
      // 绕一圈从卡片背面穿过去。
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
    _focus.requestFocus();
  }

  /// 正在编辑标签的那条边（用来摆输入框的位置）。
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
    _focus.requestFocus();
    _lastPointer = e.localPosition;

    // 点别处就先把正在编辑的东西收掉（卡片或边标签）。
    if (_editingId != null || _editingEdgeId != null) _commitEdit();

    // 中键平移。右键留给菜单，不在这里当抓手。
    if (e.buttons & kMiddleMouseButton != 0) {
      setState(() => _mode = _Interaction.panning);
      return;
    }
    if (e.buttons & kSecondaryMouseButton != 0) {
      _onSecondaryDown(e);
      return;
    }
    if (e.buttons & kPrimaryMouseButton == 0) return;

    if (_spaceHeld) {
      setState(() => _mode = _Interaction.panning);
      return;
    }

    final Offset world = _viewport.toWorld(e.localPosition);

    // 1. 手柄
    final CanvasResizeHandle? handle = _handleAt(e.localPosition);
    if (handle != null) {
      final CanvasNode node = _singleSelection!;
      setState(() {
        _mode = _Interaction.resizing;
        _handle = handle;
        _resizeId = node.id;
        _resizeStart = node.rect;
        // 缩放也算「从这一刻的位置量增量」，和拖动共用同一个起点。
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
        // 文件卡片和链接卡片的「双击」是打开，不是编辑——它们没有可编辑
        // 的正文。分组卡片改的是标签，所以仍然进编辑。
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
                  (CanvasNode n) => MapEntry<String, Offset>(
                    n.id,
                    Offset(n.x, n.y),
                  ),
                ),
          );
        // 拖分组时把它框住的卡片一起带走：分组的意思就是「这些是一伙的」，
        // 只挪框不挪内容，等于每次都要再手动搬一遍。
        if (node is GroupNode) {
          final Rect box = node.rect;
          for (final CanvasNode other in _doc!.nodes) {
            if (other.id == node.id || other is GroupNode) continue;
            if (!box.contains(other.rect.center)) continue;
            _dragOrigins.putIfAbsent(
              other.id,
              () => Offset(other.x, other.y),
            );
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
    switch (_mode) {
      case _Interaction.idle:
        break;
      case _Interaction.panning:
        final Offset delta = e.localPosition - _lastPointer;
        _lastPointer = e.localPosition;
        _applyViewport(_viewport.pannedBy(delta));
      case _Interaction.marquee:
        setState(() => _marqueeEnd = _viewport.toWorld(e.localPosition));
      case _Interaction.maybeDrag:
        // 3px 的死区：手指按下去的那一两像素抖动不该挪动卡片。
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
    final Offset delta = _viewport.toWorld(screen) - _dragFrom;
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
    final Offset delta =
        _viewport.toWorld(screen) - _viewport.toWorld(_dragFromScreen);
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
    final bool moved = _mode == _Interaction.dragging && _dragMoved;
    final bool resized = _mode == _Interaction.resizing;

    if (moved) {
      // 松手吸附网格。拖动过程中不吸附：跟手比对齐重要。
      // 只吸位置，不动尺寸——拖一下把 250 宽的卡片变成 240 是另一种 bug。
      for (final String id in _dragOrigins.keys) {
        _snapPosition(id);
      }
    } else if (resized) {
      _snapGeometry(_resizeId);
    }

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

  void _snapPosition(String id) {
    final CanvasNode? node = _doc?.nodeById(id);
    if (node == null) return;
    node.x = snapToGrid(node.x);
    node.y = snapToGrid(node.y);
  }

  void _snapGeometry(String? id) {
    final CanvasNode? node = id == null ? null : _doc?.nodeById(id);
    if (node == null) return;
    node.x = snapToGrid(node.x);
    node.y = snapToGrid(node.y);
    node.width = math.max(canvasCardMinSide, snapToGrid(node.width));
    node.height = math.max(canvasCardMinSide, snapToGrid(node.height));
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final HardwareKeyboard keys = HardwareKeyboard.instance;
    if (keys.isControlPressed) {
      // 以光标为锚点。指数映射让每一格滚动的「感觉」一样，不管当前多少倍。
      _applyViewport(
        _viewport.zoomedAt(
          e.localPosition,
          math.exp(-e.scrollDelta.dy / 320),
        ),
      );
      return;
    }
    Offset delta = e.scrollDelta;
    // Windows 上 Shift+滚轮 本来就给 dx；触控板和一些鼠标只给 dy，这里补上。
    if (keys.isShiftPressed && delta.dx == 0) {
      delta = Offset(delta.dy, 0);
    }
    _applyViewport(_viewport.pannedBy(-delta));
  }

  void _onPointerHover(PointerHoverEvent e) {
    final CanvasResizeHandle? handle = _handleAt(e.localPosition);
    final ({CanvasNode node, CanvasSide side})? dot = _connectDotAt(
      e.localPosition,
    );
    final CanvasNode? over = _nodeAt(
      _viewport.toWorld(e.localPosition),
      tolerance: 1 / _viewport.zoom,
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
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    CanvasViewport next = _viewport.pannedBy(e.panDelta);
    if (e.scale != _panZoomScale && _panZoomScale > 0) {
      next = next.zoomedAt(e.localPosition, e.scale / _panZoomScale);
      _panZoomScale = e.scale;
    }
    _applyViewport(next);
  }

  // ----------------------------------------------------------------- 菜单

  void _onSecondaryDown(PointerDownEvent e) {
    final CanvasNode? node = _nodeAt(_viewport.toWorld(e.localPosition));
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
  ///
  /// 换色做成菜单里的一排色点而不是「换色 ▸ 子菜单」：六个色一眼能看完，
  /// 多一层菜单只是多一次点击。
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
              Text(_colorLabel(value), style: const TextStyle(fontSize: AppText.ui)),
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
    setSelectionColor(picked.substring('color:'.length).isEmpty
        ? null
        : picked.substring('color:'.length));
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
    final Offset at = _viewport.toWorld(local);
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
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final HardwareKeyboard keys = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.space && !keys.isControlPressed) {
      if (!_spaceHeld) setState(() => _spaceHeld = true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // 编辑中按 Esc：先退出编辑，选择留着。再按一次才清选择。
      if (_editingId != null || _editingEdgeId != null) {
        _commitEdit();
        return KeyEventResult.handled;
      }
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
    if (keys.isControlPressed && event.logicalKey == LogicalKeyboardKey.digit0) {
      resetZoom();
      return KeyEventResult.handled;
    }
    if (keys.isControlPressed &&
        keys.isShiftPressed &&
        event.logicalKey == LogicalKeyboardKey.keyH) {
      fitToContent();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 自己数双击：同一处、同一个目标、上一个「双击窗口」还没关，就算。
  ///
  /// 用 [Timer] 而不是比时间戳，是因为时间戳在测试里推不动——`pump(700ms)`
  /// 推的是假时钟，`DateTime.now()` 一动不动。计时器走的就是假时钟。
  ///
  /// 双击之后把窗口清掉：连点三下只触发一次，不是两次。
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

  /// 框选的矩形（**屏幕**坐标）。没在框选就是 null。
  Rect? get _marqueeRect {
    final Offset? a = _marqueeStart;
    final Offset? b = _marqueeEnd;
    if (a == null || b == null) return null;
    return Rect.fromPoints(_viewport.toScreen(a), _viewport.toScreen(b));
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final CanvasStyle style = CanvasStyle.of(p);
    final CanvasDocument? doc = _doc;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 尺寸只能在 build 里拿到，没有 `onSizeChanged` 这种回调。这里直接
        // 赋值而不 setState——正在 build，重建没有意义；视口变了就在下面
        // 顺手算好，本帧的画笔立刻用上。
        final Size size = c.biggest;
        if (size != _stage && !size.isEmpty) {
          _stage = size;
          if (!_didInitialFit) {
            _didInitialFit = true;
            _viewport = CanvasViewport.fit(_contentBounds(), size);
          }
        }

        final CanvasNode? editing = _editingId == null
            ? null
            : doc?.nodeById(_editingId!);
        final List<CanvasEdgeVisual> edges = buildEdgeVisuals(
          document: doc,
          viewport: _viewport,
          selected: _selected,
        );
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
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: CanvasGridPainter(
                          viewport: _viewport,
                          style: style,
                        ),
                        isComplex: true,
                        willChange: true,
                      ),
                    ),
                    // 连线画在卡片下面：白板的主体是内容，线是内容之间的
                    // 关系。线压在卡片上会让每张卡片看起来都被划了一道。
                    IgnorePointer(
                      child: CustomPaint(
                        painter: CanvasEdgePainter(
                          edges: edges,
                          palette: p,
                          preview: _connectPreview(),
                          previewColor: p.accent,
                          labelHalo: style.background,
                        ),
                      ),
                    ),
                    // 卡片层不吃指针：所有命中测试都在上面那层 Listener 里
                    // 自己做了。让卡片也参与，就会出现「拖卡片时画布跟着
                    // 平移」这种两份真相打架的 bug。
                    IgnorePointer(
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          for (final CanvasNode node in doc?.nodes ?? const <CanvasNode>[])
                            if (node.id != _editingId)
                              _positioned(
                                node,
                                CanvasCard(
                                  node: node,
                                  zoom: _viewport.zoom,
                                  selected: _selected.contains(node.id),
                                ),
                              ),
                        ],
                      ),
                    ),
                    // 正在编辑的那张单独一层，而且**吃指针**：输入框要自己
                    // 收点击和光标。
                    if (editing != null)
                      _positioned(editing, _cardWithEditor(p, editing)),
                    IgnorePointer(
                      child: CustomPaint(
                        painter: CanvasConnectDotsPainter(
                          rect: _hoveredRect(),
                          viewport: _viewport,
                          fill: p.accent,
                          ring: p.surface,
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: CustomPaint(
                        painter: CanvasHandlesPainter(
                          rect: _singleSelection?.rect,
                          viewport: _viewport,
                          fill: p.accent,
                          ring: p.surface,
                        ),
                      ),
                    ),
                    if (editingEdge != null)
                      _edgeLabelEditor(p, editingEdge),
                    if (doc == null || doc.isEmpty)
                      _EmptyHint(style: style, canCreate: doc != null),
                    IgnorePointer(
                      child: CustomPaint(
                        painter: CanvasMarqueePainter(
                          rect: _marqueeRect,
                          style: style,
                        ),
                      ),
                    ),
                    Positioned(
                      right: AppSpace.md,
                      bottom: AppSpace.md,
                      child: CanvasToolbar(
                        zoom: _viewport.zoom,
                        onZoomIn: zoomIn,
                        onZoomOut: zoomOut,
                        onResetZoom: resetZoom,
                        onFit: fitToContent,
                        onCreateCard: doc == null ? null : createCard,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 连线预览：从出发卡片的某条边画到光标。
  CanvasEdgeGeometry? _connectPreview() {
    final Offset? cursor = _connectCursor;
    final String? fromId = _connectFromId;
    if (cursor == null || fromId == null) return null;
    final CanvasNode? node = _doc?.nodeById(fromId);
    if (node == null) return null;
    return connectPreview(
      fromRect: _viewport.rectToScreen(node.rect),
      side: _connectSide,
      cursor: cursor,
    );
  }

  /// 要显示连线圆点的那张卡片：拖连线时是出发的那张，否则是悬停的那张。
  Rect? _hoveredRect() {
    final String? id = _connectFromId ?? _hoverNodeId;
    if (id == null || _readOnly) return null;
    return _doc?.nodeById(id)?.rect;
  }

  /// 边标签的输入框：一条压在线上、居中的小输入框。
  ///
  /// 不做成「贴着线走的一段文字」是因为 `TextField` 的宽度由布局决定，
  /// 跟着贝塞尔排会一直在跳；给它一块固定的位置反而好点。
  Widget _edgeLabelEditor(AppPalette p, CanvasEdgeVisual visual) {
    final Offset center = visual.geometry.pointAt(0.5);
    const double width = 132;
    const double height = 26;
    return Positioned(
      left: center.dx - width / 2,
      top: center.dy - height / 2,
      width: width,
      height: height,
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
          decoration: InputDecoration.collapsed(
            hintText: '边标签',
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

  /// 把世界坐标的矩形摆到屏幕上。
  Widget _positioned(CanvasNode node, Widget child) {
    final Rect r = _viewport.rectToScreen(node.rect);
    return Positioned(
      left: r.left,
      top: r.top,
      width: r.width,
      height: r.height,
      child: child,
    );
  }

  Widget _cardWithEditor(AppPalette p, CanvasNode node) {
    final CellColor? color = canvasCellColor(node.color);
    return CanvasCard(
      node: node,
      zoom: _viewport.zoom,
      selected: true,
      editing: true,
      editor: TextField(
        controller: _editor,
        focusNode: _editorFocus,
        maxLines: null,
        cursorWidth: math.max(1, 1.6 * _viewport.zoom),
        cursorColor: p.accent,
        style: TextStyle(
          fontSize: AppText.ui * _viewport.zoom,
          height: 1.6,
          color: canvasCardInk(p, color),
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
        decoration: InputDecoration.collapsed(
          hintText: '输入文字…',
          hintStyle: TextStyle(
            fontSize: AppText.ui * _viewport.zoom,
            color: p.textTertiary,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
          ),
        ),
        onChanged: (String value) => _writeText(node, value),
        onTapOutside: (_) => _commitEdit(),
        onSubmitted: (_) => _commitEdit(),
      ),
    );
  }
}

/// 换色菜单里的一个小圆点。
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
        color: canvasCardFill(p, color),
        shape: BoxShape.circle,
        border: Border.all(color: canvasCardBorder(p, color)),
      ),
    );
  }
}

/// 空板提示。居中、只读、不挡指针。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.style, required this.canCreate});

  final CanvasStyle style;
  final bool canCreate;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '这块白板还是空的',
              style: TextStyle(
                fontSize: AppText.ui,
                color: style.emptyHint,
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              canCreate ? '双击空白处新建一张卡片' : '滚轮平移，Ctrl + 滚轮缩放',
              style: TextStyle(
                fontSize: AppText.caption,
                color: style.emptyHint.withValues(
                  alpha: style.emptyHint.a * 0.75,
                ),
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
