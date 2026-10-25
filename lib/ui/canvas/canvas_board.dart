import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/canvas_document.dart';
import '../../core/utils/canvas_geometry.dart';
import 'canvas_grid_painter.dart';
import 'canvas_style.dart';
import 'canvas_toolbar.dart';

/// 白板。一块可以无限平移缩放的画布，卡片和连线都摆在上面。
///
/// 三条设计约束，改之前先读：
///
/// * **只有一层 [Listener]**。卡片、手柄、连线圆点、空白，四类目标全在
///   这一个入口里按顺序做命中测试，再用 [_Interaction] 记「现在在干什么」。
///   用嵌套 `GestureDetector` 会互相抢手势，最后变成「拖卡片时画布跟着
///   平移」这种经典 bug。
/// * **点阵在屏幕坐标里算**。世界坐标铺满再整体变换，缩放越小画得越多，
///   0.1 倍时要画几十万个点。
/// * **空白处左键拖是框选，不是平移**。平移交给滚轮、中键、空格。白板的
///   主要动作是整理内容，不是浏览。
///
/// 指针事件一律读**原始** `PointerEvent`，不做手势识别——只有「双击空白
/// 新建卡片」需要判断双击，那个自己数时间戳（见 [_lastTap]），比引一个
/// `DoubleTapGestureRecognizer` 省事，也不会在测试里留下 40ms 的挂起计时器。
class CanvasBoard extends StatefulWidget {
  const CanvasBoard({
    super.key,
    required this.document,
    this.onCreateCard,
    this.onViewportChanged,
  });

  /// 要画的文档。null 或空文档时显示空板提示。
  final CanvasDocument? document;

  /// 双击空白 / 点工具条加号。null 表示这一阶段还不能建卡片（P1）。
  final VoidCallback? onCreateCard;

  /// 视口变了（缩放或平移）。外壳不需要它，测试和「记住上次位置」需要。
  final ValueChanged<CanvasViewport>? onViewportChanged;

  @override
  State<CanvasBoard> createState() => CanvasBoardState();
}

/// 现在在干什么。一次只有一个。
///
/// P2 起会补上 `dragging` / `resizing` / `connecting`，P5 补 `marquee` 的
/// 多选语义。多一个状态就多一条 `switch` 分支，别提前加。
enum _Interaction { idle, panning, marquee }

class CanvasBoardState extends State<CanvasBoard> {
  final FocusNode _focus = FocusNode(debugLabel: 'nrs-canvas');

  CanvasViewport _viewport = const CanvasViewport();
  Size _stage = Size.zero;
  bool _didInitialFit = false;

  _Interaction _mode = _Interaction.idle;

  /// 平移：上一次指针位置（屏幕坐标）。
  Offset _lastPointer = Offset.zero;

  /// 框选：起点与当前点（**世界**坐标）。
  ///
  /// 存世界坐标而不是屏幕坐标，是为了「框着框着滚一下滚轮」时框还贴在
  /// 内容上——存屏幕坐标的话滚轮一滚，框就跟着画布跑了。
  Offset? _marqueeStart;
  Offset? _marqueeEnd;

  /// 空格按住 = 临时切换成抓手。
  bool _spaceHeld = false;

  /// 上一次点击的位置，和一个「双击窗口」的计时器。
  ///
  /// 自己数双击而不用 `DoubleTapGestureRecognizer`：那个识别器会往手势竞技场
  /// 里塞一个长按分支，和「拖空白 = 框选」抢同一串指针；而且它在测试里会留下
  /// 一个 40ms 的挂起计时器。这里就是一个 `Timer`，[dispose] 里能干净地取消。
  Timer? _tapWindow;
  Offset _lastTapAt = Offset.zero;

  /// 触控板：上一帧的累计缩放，用来算增量。
  double _panZoomScale = 1;

  CanvasViewport get viewport => _viewport;

  /// 让白板拿到键盘。外壳切到白板时调它——`autofocus` 只在挂载那一次
  /// 生效，切回来时不会重来一遍。
  void requestFocus() => _focus.requestFocus();

  // 测试探针。`CustomPaint` 不进语义树，界面上也问不出「现在缩放多少」，
  // 所以把状态摊开给测试看，和 `graph_view.dart` 的 `debug*` 一个路子。
  double get debugZoom => _viewport.zoom;
  Offset get debugOffset => _viewport.offset;
  Size get debugStage => _stage;
  bool get debugPanning => _mode == _Interaction.panning;
  Rect? get debugMarquee => _marqueeRect;

  @override
  void dispose() {
    _tapWindow?.cancel();
    _focus.dispose();
    super.dispose();
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
    final CanvasDocument? doc = widget.document;
    if (doc == null || doc.isEmpty) return Rect.zero;
    return unionOf(doc.nodes.map((CanvasNode n) => n.rect));
  }

  // ------------------------------------------------------------- pointers

  void _onPointerDown(PointerDownEvent e) {
    _focus.requestFocus();
    _lastPointer = e.localPosition;

    // 中键、右键一律当抓手：这两个键在白板上没有别的用途。
    // 不用 Ctrl / Alt 当抓手，是因为 Ctrl+点击 后面要留给「加选」。
    final bool panButton =
        e.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0;
    if (panButton || _spaceHeld) {
      setState(() => _mode = _Interaction.panning);
      return;
    }
    if (e.buttons & kPrimaryMouseButton == 0) return;

    // 空白处左键：框选。双击则新建卡片。
    final Offset world = _viewport.toWorld(e.localPosition);
    if (_isDoubleTap(e.localPosition)) {
      widget.onCreateCard?.call();
      return;
    }
    setState(() {
      _mode = _Interaction.marquee;
      _marqueeStart = world;
      _marqueeEnd = world;
    });
  }

  /// 自己数双击：同一处、上一个「双击窗口」还没关，就算。
  ///
  /// 用 [Timer] 而不是比时间戳，是因为时间戳在测试里推不动——`pump(700ms)`
  /// 推的是假时钟，`DateTime.now()` 一动不动。计时器走的就是假时钟。
  ///
  /// 双击之后把窗口清掉：连点三下只建一张卡片，不是两张。
  bool _isDoubleTap(Offset at) {
    final bool doubled =
        (_tapWindow?.isActive ?? false) && (at - _lastTapAt).distance <= 6;
    _tapWindow?.cancel();
    _tapWindow = null;
    _lastTapAt = at;
    if (doubled) return true;
    _tapWindow = Timer(kDoubleTapTimeout, () => _tapWindow = null);
    return false;
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
    }
  }

  void _onPointerUp(PointerEvent e) {
    if (_mode == _Interaction.idle) return;
    // 框选的选择集要到 P5 才有住户，现在只把框收掉。
    setState(() {
      _mode = _Interaction.idle;
      _marqueeStart = null;
      _marqueeEnd = null;
    });
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

  // ------------------------------------------------------------- keyboard

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

        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: MouseRegion(
            cursor: _mode == _Interaction.panning
                ? SystemMouseCursors.grabbing
                : (_spaceHeld ? SystemMouseCursors.grab : SystemMouseCursors.basic),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerUp,
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
                    if (widget.document?.isEmpty ?? true)
                      _EmptyHint(
                        style: style,
                        canCreate: widget.onCreateCard != null,
                      ),
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
                        onCreateCard: widget.onCreateCard,
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
