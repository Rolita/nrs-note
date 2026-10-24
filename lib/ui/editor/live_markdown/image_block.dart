part of '../live_markdown.dart';

/// 图片行的自绘内容：一整个段落只有一张图时，把源码行换成一幅画。
///
/// 与表格一样，这一行不再交给 `TextPainter`：图片的尺寸来自文件本身、宽度
/// 来自源码里的 `w=`，两者都要等解码完成才知道，而且拖动改宽时行高要跟着
/// 实时变。引擎只负责把块放在正确的 y 上，绘制、命中、光标落点都由这里回答。
class LiveImageBlocks {
  LiveImageBlocks({
    required this.palette,
    required this.text,
    required this.selection,
    required this.imageProviderFor,
    required this.onLineInvalidated,
  });

  final AppPalette palette;

  /// 当前源码，调用时才读。
  final String Function() text;

  /// 当前的揭示选区（拖动期间可能是冻结的那一份）。
  final TextSelection? Function() selection;

  /// 把图片引用解析成可绘制的图片；null 表示这一行画不出来。
  final ImageProvider? Function(String source)? imageProviderFor;

  /// 图片尺寸变化后请求只重排这一行；参数是行首偏移。
  final ValueChanged<int> onLineInvalidated;

  /// 源码行首偏移 → 这一行的图片块。行被复用时不重建，图片流也就不用重挂。
  final Map<int, ImageLineBlock> _blocks = <int, ImageLineBlock>{};

  /// 拖拽中的预览宽度，不写源码。
  final Map<int, double> previewWidths = <int, double>{};

  LineBlockView? blockFor(SourceLine line, LineBlockContext context) {
    if (line.kind != LineBlockKind.paragraph) {
      _blocks.remove(line.start)?.dispose();
      return null;
    }

    final ImageMarkup? markup = ImageMarkup.parseLine(line.text);
    if (markup == null) {
      _blocks.remove(line.start)?.dispose();
      return null;
    }

    final TextSelection? sel = selection();
    final bool revealed =
        sel != null &&
        sel.isValid &&
        sel.start <= line.end &&
        sel.end >= line.start;

    ImageLineBlock? block = _blocks[line.start];
    // 同一行换了内容（宽度、alt、引用）就换一个块：图片流要跟着新引用走。
    if (block != null && block.lineText != line.text) {
      block.dispose();
      block = null;
    }
    if (block == null) {
      block = ImageLineBlock(
        markup: markup,
        lineStart: line.start,
        lineEnd: line.end,
        lineText: line.text,
        palette: palette,
        contentWidth: context.contentWidth,
        textScaler: context.textScaler,
        previewWidth: previewWidths[line.start],
        imageProviderFor: imageProviderFor,
        onLineInvalidated: onLineInvalidated,
      );
      _blocks[line.start] = block;
    } else {
      block
        ..lineStart = line.start
        ..lineEnd = line.end
        ..configure(
          palette: palette,
          contentWidth: context.contentWidth,
          textScaler: context.textScaler,
          previewWidth: previewWidths[line.start],
        );
    }

    return revealed ? null : block;
  }

  /// 拖拽预览：只覆盖显示宽度，源码保持不动。
  void setPreviewWidth(int lineStart, double? width) {
    if (width == null) {
      previewWidths.remove(lineStart);
    } else {
      previewWidths[lineStart] = width;
    }
  }

  double? previewWidthOf(int lineStart) => previewWidths[lineStart];

  void dispose() {
    for (final ImageLineBlock block in _blocks.values) {
      block.dispose();
    }
    _blocks.clear();
    previewWidths.clear();
  }
}

/// 一张图片的自绘行。
///
/// 尺寸规则见方案 §10.3：显式宽度用户说了算，没有宽度时按固有尺寸缩进正文
/// 列，并用 640 逻辑像素给自然高度设一个软上限——一张长截图不该吞掉整屏。
class ImageLineBlock implements LineBlockView, ImageBlockChrome {
  ImageLineBlock({
    required this.markup,
    required this.lineStart,
    required this.lineEnd,
    required this.lineText,
    required this.palette,
    required this.contentWidth,
    required this.textScaler,
    required this.previewWidth,
    required this.imageProviderFor,
    required this.onLineInvalidated,
  }) {
    _resolve();
    _computeSize();
  }

  final ImageMarkup markup;
  final ImageProvider? Function(String source)? imageProviderFor;
  final ValueChanged<int> onLineInvalidated;

  int lineStart;
  int lineEnd;

  /// 建块时的源码行；只有内容变了才需要重新解析与重新挂图片流。
  final String lineText;

  AppPalette palette;
  double contentWidth;
  TextScaler textScaler;
  double? previewWidth;

  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;
  bool _failed = false;
  bool _disposed = false;
  bool _invalidateScheduled = false;

  double _naturalWidth = 0;
  double _aspect = 1;
  double _width = 0;
  double _height = 0;
  Offset _chromeOrigin = Offset.zero;

  @override
  double get width => _width;

  @override
  double get height => _height;

  @override
  int get imageSourceStart => lineStart;

  /// 加载失败时也要有手柄：宽度是源码里的属性，图片坏没坏都得能改。
  bool get failed => _failed;

  void configure({
    required AppPalette palette,
    required double contentWidth,
    required TextScaler textScaler,
    required double? previewWidth,
  }) {
    final bool changed =
        palette != this.palette ||
        contentWidth != this.contentWidth ||
        this.textScaler != textScaler ||
        this.previewWidth != previewWidth;
    this.palette = palette;
    this.contentWidth = contentWidth;
    this.textScaler = textScaler;
    this.previewWidth = previewWidth;
    if (changed) _computeSize();
  }

  void _resolve() {
    final ImageProvider? provider = imageProviderFor?.call(markup.source);
    if (provider == null) {
      _failed = true;
      return;
    }
    try {
      final ImageStream stream = provider.resolve(ImageConfiguration.empty);
      _stream = stream;
      _listener = ImageStreamListener(_onImage, onError: _onError);
      stream.addListener(_listener!);
    } catch (_) {
      _failed = true;
    }
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (_disposed) {
      info.dispose();
      return;
    }
    final ImageInfo? previous = _info;
    if (previous != null && info.isCloneOf(previous)) {
      info.dispose();
      return;
    }
    previous?.dispose();
    _info = info;
    final double logicalWidth = info.image.width / info.scale;
    final double logicalHeight = info.image.height / info.scale;
    if (logicalWidth > 0 && logicalHeight > 0) {
      _naturalWidth = logicalWidth;
      _aspect = logicalWidth / logicalHeight;
    }
    _failed = false;
    _computeSize();
    // 同步回调发生在排版期间，直接 markNeedsLayout 会撞上「layout 中再请求
    // 布局」；推后一帧只重排这一行。
    _scheduleInvalidate();
  }

  void _onError(Object error, StackTrace? stackTrace) {
    if (_disposed) return;
    _failed = true;
    _computeSize();
    _scheduleInvalidate();
  }

  void _scheduleInvalidate() {
    if (_invalidateScheduled || _disposed) return;
    _invalidateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _invalidateScheduled = false;
      if (!_disposed) onLineInvalidated(lineStart);
    });
    // 没有这一句，回调只等到「下一帧」才跑，而空闲时根本没有下一帧：
    // 图片在用户停手后解码完成会一直停在 360×120 的占位。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _computeSize() {
    final double room = contentWidth > 0 ? contentWidth : 0;
    if (_info == null) {
      _width = math.min(360.0, room);
      _height = 120;
      return;
    }

    final double? declared = previewWidth ?? markup.width;
    double w;
    if (declared != null) {
      w = declared.clamp(96.0, math.max(96.0, room));
    } else {
      w = math.min(_naturalWidth, room);
      if (_aspect > 0 && w / _aspect > 640) {
        w = 640 * _aspect;
      }
    }
    if (!w.isFinite || w <= 0) w = math.min(360.0, room);
    _width = w;
    _height = _aspect > 0 ? w / _aspect : 120;
  }

  @override
  void chromeSourceRange(int start, int end) {
    lineStart = start;
    lineEnd = end;
  }

  @override
  set chromeOrigin(Offset value) => _chromeOrigin = value;

  @override
  Rect chromeImageBounds() =>
      Rect.fromLTWH(_chromeOrigin.dx, _chromeOrigin.dy, _width, _height);

  @override
  ImageResizeHandle? chromeResizeHandle() {
    final Rect bounds = chromeImageBounds();
    const double size = 14;
    return ImageResizeHandle(
      Rect.fromCenter(
        center: bounds.bottomRight,
        width: size,
        height: size,
      ),
    );
  }

  @override
  void paint(Canvas canvas, Offset origin, Offset globalOrigin) {
    _chromeOrigin = globalOrigin;
    final Rect rect = Rect.fromLTWH(origin.dx, origin.dy, _width, _height);
    final RRect rounded = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(4),
    );

    final ImageInfo? info = _info;
    if (info != null) {
      canvas.save();
      canvas.clipRRect(rounded);
      canvas.drawImageRect(
        info.image,
        Rect.fromLTWH(
          0,
          0,
          info.image.width.toDouble(),
          info.image.height.toDouble(),
        ),
        rect,
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    } else {
      canvas.drawRRect(rounded, Paint()..color = palette.surfaceSunken);
      if (_failed) _paintFailure(canvas, rect);
    }

    canvas.drawRRect(
      rounded,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = palette.outlineSoft,
    );
  }

  void _paintFailure(Canvas canvas, Rect rect) {
    final IconData icon = LucideIcons.imageOff;
    final TextPainter glyph = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: 24,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: palette.textTertiary,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();

    final String name = _fileNameOf(markup.source);
    final TextPainter label = TextPainter(
      text: TextSpan(
        text: name,
        style: TextStyle(
          fontSize: 12,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
          color: palette.textTertiary,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
      ellipsis: '…',
    );
    label.layout(maxWidth: math.max(1, rect.width - 32));

    final double gap = 8;
    final double total = glyph.height + gap + label.height;
    final double top = rect.top + (rect.height - total) / 2;
    glyph.paint(
      canvas,
      Offset(rect.center.dx - glyph.width / 2, top),
    );
    label.paint(
      canvas,
      Offset(rect.center.dx - label.width / 2, top + glyph.height + gap),
    );
    glyph.dispose();
    label.dispose();
  }

  static String _fileNameOf(String source) {
    final String tail = source.split(RegExp(r'[/\\]')).last;
    return tail.isEmpty ? source : tail;
  }

  @override
  int offsetAt(Offset local) => local.dx < _width / 2 ? lineStart : lineEnd;

  @override
  Rect caretRectAt(int offset) {
    final double x = offset >= lineEnd ? math.max(0, _width - 2) : 0;
    return Rect.fromLTWH(x, 0, 2, _height);
  }

  @override
  List<Rect> highlightRects(int from, int to) {
    if (to <= from || to < lineStart || from > lineEnd) return const <Rect>[];
    return <Rect>[Rect.fromLTWH(0, 0, _width, _height)];
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _listener = null;
    _stream = null;
    _info?.dispose();
    _info = null;
  }
}
