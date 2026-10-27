import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/app_enums.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'main_view.dart';
import 'title_bar_content.dart';

/// The application draws its own window chrome.
///
/// `window_setup_io.dart` removes the OS caption (`TitleBarStyle.hidden`), so
/// everything the caption used to do is re-implemented here: drag the strip to
/// move the window, double-click it to maximize / restore, and three buttons on
/// the right. The three regions between those buttons come from
/// [TitleBarLayout] — views on the left, open tabs in the middle, the outline
/// toggle on the right.
///
/// ⛔ The buttons and the tabs must stay *outside* [DragToMoveArea]: a gesture
/// detector that starts a window drag swallows every tap underneath it.
class AppTitleBar extends StatefulWidget {
  const AppTitleBar({
    super.key,
    required this.view,
    required this.onSelectView,
    required this.onToggleSidebar,
    required this.onCreateNote,
    required this.mainView,
    required this.onSelectMainView,
    required this.graphOpen,
    required this.onCloseGraph,
    required this.imageTitle,
    required this.onCloseImage,
    required this.canvasTitle,
    required this.onCloseCanvas,
    required this.leftInset,
    required this.rightInset,
  });

  final SidebarView view;
  final ValueChanged<SidebarView> onSelectView;
  final VoidCallback onToggleSidebar;
  final VoidCallback onCreateNote;

  /// Whether the pane under the tabs shows a note or the graph.
  final MainView mainView;
  final ValueChanged<MainView> onSelectMainView;
  final bool graphOpen;
  final VoidCallback onCloseGraph;

  /// 图片页那一页 tab 的标题（当前那张图的文件名），`null` = 没开。
  ///
  /// 所有图片共用这一页：换图时这个字符串换掉，tab 还是同一个。
  final String? imageTitle;
  final VoidCallback onCloseImage;
  final String? canvasTitle;
  final VoidCallback onCloseCanvas;

  /// Distance from the window's left edge to the editor's left edge.
  final double leftInset;

  /// Distance from the window's right edge to the outline's left edge.
  final double rightInset;

  @override
  State<AppTitleBar> createState() => _AppTitleBarState();
}

class _AppTitleBarState extends State<AppTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // The window can already be maximized before this bar is ever built (a
    // hot restart keeps the OS window), so ask once instead of assuming.
    windowManager.isMaximized().then((bool value) {
      if (mounted) setState(() => _maximized = value);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => _setMaximized(true);

  @override
  void onWindowUnmaximize() => _setMaximized(false);

  void _setMaximized(bool value) {
    if (!mounted || _maximized == value) return;
    setState(() => _maximized = value);
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      height: AppLayout.titleBarHeight,
      decoration: BoxDecoration(
        // The rail's colour, so the strip and the rail read as one continuous
        // window edge rather than two stacked bands.
        color: p.canvas,
        border: Border(bottom: BorderSide(color: p.outlineSoft)),
      ),
      child: TitleBarLayout(
        view: widget.view,
        onSelectView: widget.onSelectView,
        onToggleSidebar: widget.onToggleSidebar,
        onCreateNote: widget.onCreateNote,
        mainView: widget.mainView,
        onSelectMainView: widget.onSelectMainView,
        graphOpen: widget.graphOpen,
        onCloseGraph: widget.onCloseGraph,
        imageTitle: widget.imageTitle,
        onCloseImage: widget.onCloseImage,
        canvasTitle: widget.canvasTitle,
        onCloseCanvas: widget.onCloseCanvas,
        leftInset: widget.leftInset,
        rightInset: widget.rightInset,
        grip: const DragToMoveArea(child: SizedBox.expand()),
        captionWidth: 44 * 3,
        caption: <Widget>[
          _CaptionButton(
            glyph: _Glyph.minimize,
            tooltip: '最小化',
            onPressed: windowManager.minimize,
          ),
          _CaptionButton(
            glyph: _maximized ? _Glyph.restore : _Glyph.maximize,
            tooltip: _maximized ? '向下还原' : '最大化',
            onPressed: () => _maximized
                ? windowManager.unmaximize()
                : windowManager.maximize(),
          ),
          _CaptionButton(
            glyph: _Glyph.close,
            tooltip: '关闭',
            danger: true,
            onPressed: windowManager.close,
          ),
        ],
      ),
    );
  }
}

/// One of the three caption buttons.
///
/// 44px wide is the Windows caption metric rounded onto the shell's 4px grid;
/// the close button keeps the system red in both themes, because "the thing
/// that closes the window" is the one place where matching the OS beats
/// matching the palette.
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    this.danger = false,
  });

  final _Glyph glyph;
  final String tooltip;
  final VoidCallback onPressed;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  /// Windows' own convention for the close button — the same red Explorer,
  /// Settings and every other window uses. It is OS chrome, not an app colour,
  /// so it stays hard-coded on purpose: no palette may repaint it.
  static const Color _closeRed = Color(0xFFC42B1C);
  static const Color _closeRedPressed = Color(0xFFB02617);

  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool lit = _hovered || _pressed;

    Color background = Colors.transparent;
    if (widget.danger) {
      if (_pressed) {
        background = _closeRedPressed;
      } else if (_hovered) {
        background = _closeRed;
      }
    } else if (_pressed) {
      background = p.outlineSoft;
    } else if (_hovered) {
      background = p.surfaceRaised;
    }

    final Color foreground = widget.danger && lit
        ? Colors.white
        : (_hovered ? p.textPrimary : p.textSecondary);

    return Tooltip(
      message: widget.tooltip,
      // The default zero delay turns every pass of the mouse into a popup.
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: AppMotion.instant,
            curve: AppMotion.enter,
            width: 44,
            height: double.infinity,
            color: background,
            child: Center(
              child: CustomPaint(
                size: const Size(10, 10),
                painter: _GlyphPainter(widget.glyph, foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

/// Caption glyphs drawn by hand rather than borrowed from Material: at 10px the
/// icon set's own squares and crosses carry too much optical weight and sit off
/// the pixel grid, which next to a 40px strip looks like a rendering bug.
///
/// 1.1px rather than 1: at 10px a hairline disappears into the canvas on a
/// high-DPI screen, and the glyph reads as a smudge instead of a line.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;

    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(const Offset(0, 5.5), const Offset(10, 5.5), paint);
      case _Glyph.maximize:
        canvas.drawRect(const Rect.fromLTWH(0.5, 0.5, 9, 9), paint);
      case _Glyph.restore:
        // The front pane is complete; the back one only shows the L of its top
        // and right edges, which is exactly how the system draws it.
        canvas.drawRect(const Rect.fromLTWH(0.5, 3.5, 6, 6), paint);
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 0.5)
            ..lineTo(9.5, 0.5)
            ..lineTo(9.5, 6.5)
            ..lineTo(6.5, 6.5),
          paint,
        );
      case _Glyph.close:
        canvas.drawLine(const Offset(0.5, 0.5), const Offset(9.5, 9.5), paint);
        canvas.drawLine(const Offset(9.5, 0.5), const Offset(0.5, 9.5), paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
