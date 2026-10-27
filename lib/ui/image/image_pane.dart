/// 主区里的图片页。
///
/// 和「查看大图」那个浮层（`ui/editor/image_viewer.dart`）不是一回事，别合并：
///
/// | | 浮层 | 这一页 |
/// |---|---|---|
/// | 出现在 | 笔记正文之上 | 标题栏下面那一整块 |
/// | 怎么退 | `Esc`、点图外空白 | tab 上的 ×，或者去看笔记 |
/// | 底色 | 半透明黑（要压住正文） | 主题画布色（它就是内容） |
/// | 翻页 | 有（同一篇里的几张图） | 没有（文件树一次点开一张） |
///
/// 交互只留桌面看图的三个基本动作：滚轮缩放、拖动平移、双击在「适配」和
/// 「原图 1:1」之间跳。百分比的算法与浮层同一套口径（相对**原图**，不是相对
/// 适配），理由写在那边的文件头里。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/note_image.dart';

class ImagePane extends StatefulWidget {
  const ImagePane({
    super.key,
    required this.source,
    required this.absolutePath,
    this.onOpenExternal,
  });

  /// 引用本身（vault 相对路径）。`imageProviderFor` 用它分辨远程图。
  final String source;

  /// 磁盘上的绝对路径。
  final String absolutePath;

  /// 交给系统看图程序。为空时状态栏不显示那枚按钮。
  final VoidCallback? onOpenExternal;

  @override
  State<ImagePane> createState() => _ImagePaneState();
}

class _ImagePaneState extends State<ImagePane> {
  /// 能放到「原图 1:1」的几倍。
  static const double _maxPixelRatio = 3;

  static const double _statusHeight = 32;

  final TransformationController _transform = TransformationController();

  /// 相对「适配窗口」的倍数。由 [_transform] 的 listener 同步，手势缩放也要
  /// 反映到底栏。
  double _scale = 1;

  /// 视口尺寸。`LayoutBuilder` 在 layout 阶段写入，首帧还是零。
  Size _viewport = Size.zero;

  /// 当前这张的原图尺寸，读不出来是 null。
  ({int width, int height})? _size;

  ImageProvider? _provider;

  @override
  void initState() {
    super.initState();
    _load();
    _transform.addListener(_onTransformChanged);
  }

  @override
  void didUpdateWidget(ImagePane old) {
    super.didUpdateWidget(old);
    // 所有图片共用一页：换图走的是这里，不是新建 State。矩阵、百分比、
    // 原图尺寸都要跟着重来一遍——留着上一张的 300%，新图凭空是糊的。
    if (old.absolutePath == widget.absolutePath &&
        old.source == widget.source) {
      return;
    }
    setState(() {
      _load();
      _scale = 1;
      _size = null;
    });
    _transform.value = Matrix4.identity();
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    super.dispose();
  }

  void _load() {
    _provider = imageProviderFor(widget.absolutePath, widget.source);
    _probeSize();
  }

  void _onTransformChanged() {
    final double next = _transform.value.getMaxScaleOnAxis();
    // 阈值 guard 不能省：`_setScale` 里先算矩阵再通知，不 guard 就是白重建。
    if ((next - _scale).abs() < 0.001) return;
    setState(() => _scale = next);
  }

  Future<void> _probeSize() async {
    final String path = widget.absolutePath;
    final size = await imageSizeAt(path);
    // 读完可能已经换了图——别把上一张的尺寸贴到这一张上。
    if (!mounted || path != widget.absolutePath) return;
    setState(() => _size = size);
  }

  // ── 尺寸口径 ────────────────────────────────────────────────────────────

  /// 「原图 1:1」对应的倍数，也就是状态栏显示 `100%` 的那一档。
  ///
  /// = `原图宽 / 图在视口里的显示宽`。上限、双击落点、百分比三处都从它推。
  double get _baseScale {
    final size = _size;
    if (size == null || _viewport.isEmpty) return 1;

    final double aspect = size.width / size.height;
    // `Image` 在 loose 约束下按自身尺寸排布，装不下才等比缩到装得下。
    final double shown = math.min(
      math.min(_viewport.width, size.width.toDouble()),
      _viewport.height * aspect,
    );
    if (shown <= 0) return 1;
    return size.width / shown;
  }

  /// 能放到的最大倍数 = `1:1 × 3`。
  ///
  /// ⛔ 外面那层 `max(1.0, …)` 不能省：小图的 `_baseScale` 可能小于 1，乘 3
  /// 仍不到 1——而 `minScale` 是 1，`InteractiveViewer` 有
  /// `assert(maxScale >= minScale)`，会当场抛断言。
  double get _maxScale => math.max(1.0, _baseScale * _maxPixelRatio);

  /// 状态栏那个百分比——**相对原图**，不是相对「适配」。
  double get _pixelPercent => _scale / _baseScale;

  // ── 动作 ────────────────────────────────────────────────────────────────

  /// 以视口中心为焦点缩放到 [value]。
  ///
  /// 不做「以鼠标位置为焦点」：`InteractiveViewer` 的边界钳制只发生在手势
  /// 过程里，程序化写 `value` 不会被钳——以任意点为焦点很容易把内容推出
  /// 可视区，用户看到一片空白还得手动拖回来。
  void _setScale(double value) {
    final double next = value.clamp(1.0, _maxScale);
    final double dx = _viewport.width / 2;
    final double dy = _viewport.height / 2;

    // 直接搭「以 (dx, dy) 为焦点缩放 next 倍」的矩阵；焦点代入后不动。
    // ⛔ 别退回 `..translate()..scale()..translate()`：那两个方法在
    //    vector_math 里已标废弃。
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, next)
      ..setEntry(1, 1, next)
      ..setEntry(0, 3, dx * (1 - next))
      ..setEntry(1, 3, dy * (1 - next));
  }

  void _resetZoom() => _setScale(1);

  /// 双击：在「适配」和「原图 1:1」之间跳。
  void _toggleZoom() {
    if (_scale > 1.001) {
      _resetZoom();
    } else {
      _setScale(_baseScale);
    }
  }

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return ColoredBox(
      color: p.canvas,
      child: Column(
        children: <Widget>[
          Expanded(child: _buildStage(p)),
          _buildStatusBar(p),
        ],
      ),
    );
  }

  Widget _buildStage(AppPalette p) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // `LayoutBuilder` 的 builder 在 layout 阶段才跑，状态栏早就 build
        // 过了——首帧算百分比时 `_viewport` 还是零。写完推一帧补上。
        if (constraints.biggest != _viewport) {
          _viewport = constraints.biggest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }

        final ImageProvider? provider = _provider;
        if (provider == null) return _unavailable(p);

        return InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          // ⚠️ 与 `_baseScale` 是一套口径，别改成写死的 4。
          maxScale: _maxScale,
          child: Center(
            child: GestureDetector(
              onDoubleTap: _toggleZoom,
              child: Image(
                image: provider,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                // ⛔ 不加 `gaplessPlayback`：换图时留着上一帧，用户会以为
                //    「点了没反应」。宁可中间几十毫秒是一枚转圈。
                frameBuilder: _buildFrame,
                errorBuilder: (BuildContext context, Object _, _) =>
                    _unavailable(p),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 加载态：解码没回来时给一枚转圈，回来后淡入。
  Widget _buildFrame(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSynchronouslyLoaded,
  ) {
    if (wasSynchronouslyLoaded) return child;
    final bool loaded = frame != null;

    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        if (!loaded)
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.palette.textTertiary,
            ),
          ),
        AnimatedOpacity(
          opacity: loaded ? 1 : 0,
          duration: AppMotion.base,
          curve: AppMotion.enter,
          child: child,
        ),
      ],
    );
  }

  /// 解不了这张图：说清楚，并给一条出路。
  ///
  /// `svg` / `heic` / `tif` 会走到这里（Flutter 没有它们的解码器），文件树
  /// 仍然把这三个当图片——图标是对的，能不能看是另一回事。
  Widget _unavailable(AppPalette p) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(LucideIcons.imageOff, size: 28, color: p.textTertiary),
          const SizedBox(height: AppSpace.md),
          Text(
            '这张图在应用里打不开',
            style: TextStyle(fontSize: AppText.body, color: p.textSecondary),
          ),
          if (widget.onOpenExternal != null) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            _PillButton(
              label: '用系统程序打开',
              icon: LucideIcons.externalLink,
              onTap: widget.onOpenExternal!,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusBar(AppPalette p) {
    final dims = _size;
    final bool canZoom = _provider != null;

    return Container(
      height: _statusHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.outlineSoft)),
      ),
      child: Row(
        children: <Widget>[
          // 读不出来就不显示，不拿「未知」占位。
          if (dims != null)
            Text(
              '${dims.width} × ${dims.height}',
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          const Spacer(),
          if (canZoom) ...<Widget>[
            Text(
              '${(100 * _pixelPercent).round()}%',
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            _TextButton(
              label: '复位',
              // 已经在适配档就没什么可复位的——置灰，而不是点了没反应。
              onTap: _scale > 1.001 ? _resetZoom : null,
            ),
            const SizedBox(width: AppSpace.xs),
          ],
          if (widget.onOpenExternal != null)
            _IconAction(
              icon: LucideIcons.externalLink,
              tip: '用系统程序打开',
              onTap: widget.onOpenExternal!,
            ),
        ],
      ),
    );
  }
}

/// 状态栏里的文字按钮（复位）。
class _TextButton extends StatefulWidget {
  const _TextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_TextButton> createState() => _TextButtonState();
}

class _TextButtonState extends State<_TextButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final bool enabled = widget.onTap != null;
    final Color foreground = !enabled
        ? p.textTertiary.withValues(alpha: 0.5)
        : (_hovered ? p.textPrimary : p.textSecondary);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered && enabled ? p.surfaceRaised : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.xs),
          ),
          child: Text(
            widget.label,
            style: TextStyle(fontSize: AppText.caption, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// 状态栏右侧那枚图标按钮。
class _IconAction extends StatefulWidget {
  const _IconAction({
    required this.icon,
    required this.tip,
    required this.onTap,
  });

  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Tooltip(
      message: widget.tip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(left: AppSpace.xs),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? p.surfaceRaised : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.xs),
            ),
            child: Icon(
              widget.icon,
              size: AppIconSize.xs,
              color: _hovered ? p.textPrimary : p.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 打不开时那条出路：一枚带边框的药丸按钮。
class _PillButton extends StatefulWidget {
  const _PillButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_PillButton> createState() => _PillButtonState();
}

class _PillButtonState extends State<_PillButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceRaised : p.surface,
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: p.outline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                widget.icon,
                size: AppIconSize.xs,
                color: _hovered ? p.textPrimary : p.textSecondary,
              ),
              const SizedBox(width: AppSpace.xs),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: AppText.label,
                  color: _hovered ? p.textPrimary : p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
