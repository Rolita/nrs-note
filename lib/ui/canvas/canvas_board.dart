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
import 'canvas_grid_painter.dart';
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
  });

  /// 要画的文档。null = 只读空板（还不能编辑），此时不响应任何修改。
  final CanvasDocument? document;

  /// 文档被改过（新建 / 移动 / 缩放 / 改文字 / 换色 / 删除）。
  /// P6 会用它触发自动保存。
  final VoidCallback? onChanged;

  /// 视口变了（缩放或平移）。
  final ValueChanged<CanvasViewport>? onViewportChanged;

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

  void _beginEdit(CanvasNode node) {
    if (node is! TextNode) return;
    _editor.text = node.text;
    _editor.selection = TextSelection.collapsed(offset: node.text.length);
    setState(() => _editingId = node.id);
    // 输入框这一帧才建出来，等它挂上再要焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingId == node.id) _editorFocus.requestFocus();
    });
  }

  void _commitEdit() {
    final CanvasDocument? doc = _doc;
    final String? id = _editingId;
    if (id == null) return;
    if (doc != null) {
      final CanvasNode? node = doc.nodeById(id);
      if (node is TextNode) node.text = _editor.text;
    }
    setState(() => _editingId = null);
    widget.onChanged?.call();
    _focus.requestFocus();
  }

  // ---------------------------------------------------------- hit testing

  /// 最上面的那张卡片。后加的在上，所以倒着找。
  CanvasNode? _nodeAt(Offset world) {
    final CanvasDocument? doc = _doc;
    if (doc == null) return null;
    for (int i = doc.nodes.length - 1; i >= 0; i--) {
      final CanvasNode node = doc.nodes[i];
      if (hitsRect(node.rect, world)) return node;
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

  // ------------------------------------------------------------- pointers

  void _onPointerDown(PointerDownEvent e) {
    _focus.requestFocus();
    _lastPointer = e.localPosition;

    // 点别处就先把正在编辑的卡片收掉。
    if (_editingId != null) _commitEdit();

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

    // 2. 卡片
    final CanvasNode? node = _nodeAt(world);
    if (node != null) {
      if (_isDoubleTap(e.localPosition, node.id)) {
        _beginEdit(node);
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
      });
      return;
    }

    // 3. 空白
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
    final MouseCursor next = handle != null
        ? _cursorFor(handle)
        : (_spaceHeld
              ? SystemMouseCursors.grab
              : (_nodeAt(_viewport.toWorld(e.localPosition)) != null
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic));
    if (next != _cursor) setState(() => _cursor = next);
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
        value: 'new',
        height: 34,
        child: Text('新建卡片', style: TextStyle(fontSize: AppText.ui)),
      ),
      const PopupMenuItem<String>(
        value: 'fit',
        height: 34,
        child: Text('适应窗口', style: TextStyle(fontSize: AppText.ui)),
      ),
    ]);
    if (!mounted || picked == null) return;
    if (picked == 'new') {
      final RenderBox? box = context.findRenderObject() as RenderBox?;
      final Offset local = box?.globalToLocal(global) ?? global;
      createCard(at: _viewport.toWorld(local));
    } else if (picked == 'fit') {
      fitToContent();
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
      if (_editingId != null) {
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
                        painter: CanvasHandlesPainter(
                          rect: _singleSelection?.rect,
                          viewport: _viewport,
                          fill: p.accent,
                          ring: p.surface,
                        ),
                      ),
                    ),
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
        onChanged: (String value) {
          if (node is TextNode) node.text = value;
        },
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
