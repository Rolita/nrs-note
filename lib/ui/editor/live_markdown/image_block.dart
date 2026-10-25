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
    this.selectedLine,
    this.editingLine,
    this.sourceFontSize = 15.5,
    required this.imageProviderFor,
    required this.onLineInvalidated,
  });

  final AppPalette palette;

  /// 当前源码，调用时才读。
  final String Function() text;

  /// 当前的揭示选区（拖动期间可能是冻结的那一份）。
  final TextSelection? Function() selection;

  /// 被点中的那一行（行首偏移）；新建的块要按它决定自己画不画边框。
  final int? Function()? selectedLine;

  /// 正在编辑源码的那一行（行首偏移）。
  ///
  /// 有它，这一行就为源码**让出一行高度**，图片整体下移——源码是这一行的一部分，
  /// 不是浮在图上的一块面板。
  final int? Function()? editingLine;

  /// 正文的字号，只用来估源码行要占多高。
  final double sourceFontSize;

  /// 把图片引用解析成可绘制的图片；null 表示这一行画不出来。
  final ImageProvider? Function(String source)? imageProviderFor;

  /// 图片尺寸变化后请求只重排这一行；参数是行首偏移。
  final ValueChanged<int> onLineInvalidated;

  /// 源码行首偏移 → 这一行的图片块。行被复用时不重建，图片流也就不用重挂。
  final Map<int, ImageLineBlock> _blocks = <int, ImageLineBlock>{};

  /// 每个块最后一次被要回去的序号，只用来淘汰已经不在文档里的旧块。
  ///
  /// 键是行首偏移，在图片上方插一行它就变了——旧键再也对不上，不解码完的
  /// `ui.Image` 就白攒着了。
  final Map<int, int> _lastUsed = <int, int>{};
  int _tick = 0;

  /// 留够一屏能放下的块。淘汰只发生在明显攒多了的时候——一次排版里，后面的
  /// 行还没轮到自己，这时候把它们刚建好的块丢掉是白费功夫。
  static const int _keepBlocks = 24;

  /// 拖拽中的预览宽度，不写源码。
  final Map<int, double> previewWidths = <int, double>{};

  LineBlockView? blockFor(SourceLine line, LineBlockContext context) {
    if (line.kind != LineBlockKind.paragraph) {
      _blocks.remove(line.start)?.dispose();
      _lastUsed.remove(line.start);
      return null;
    }

    final ImageMarkup? markup = ImageMarkup.parseLine(line.text);
    if (markup == null) {
      _blocks.remove(line.start)?.dispose();
      _lastUsed.remove(line.start);
      return null;
    }

    final TextSelection? sel = selection();
    // 光标停在图片行上**不**退回源码：点一下图片是为了看它，不是为了改它。
    // 只有真的在选字（选区非空、且和这一行有交集）才摊开源码——那是要复制
    // 或删除整行，看不见就没法判断自己选中了什么。
    //
    // 改源码走图片右下角的「编辑这个区块」浮层，那边图片照样留在原地。
    final bool revealed =
        sel != null &&
        sel.isValid &&
        !sel.isCollapsed &&
        sel.start < line.end &&
        sel.end > line.start;

    ImageLineBlock? block = _blocks[line.start];
    // 同一行换了内容（宽度、alt、缩进、列表编号）：只更新，不重建——引用没变
    // 就不该把解码结果丢掉重来一遍，那几帧占位看起来就是「图片黑了一下」。
    if (block != null && block.lineText != line.text) {
      block.updateLine(lineText: line.text, next: markup);
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
        sourceFontSize: sourceFontSize,
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
          sourceFontSize: sourceFontSize,
        );
    }
    // 块会被复用、也会新建：选中态与「正在改源码」一律以编辑器为准。
    block.selected = selectedLine?.call() == line.start;
    block.showSource = editingLine?.call() == line.start;
    _lastUsed[line.start] = ++_tick;
    _trim();

    return revealed && !block.showSource ? null : block;
  }

  /// 只留最近还在用的那些块。图片上方插一行，行首偏移就变了，旧键再也对不上
  /// ——不淘汰的话每编辑一次就白留一张解码好的图。
  void _trim() {
    if (_blocks.length <= _keepBlocks) return;
    final List<int> keys = _blocks.keys.toList()
      ..sort(
        (int a, int b) =>
            (_lastUsed[a] ?? 0).compareTo(_lastUsed[b] ?? 0),
      );
    for (final int key in keys) {
      if (_blocks.length <= _keepBlocks) break;
      _blocks.remove(key)?.dispose();
      _lastUsed.remove(key);
    }
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
    _lastUsed.clear();
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
    required this.sourceFontSize,
    required this.imageProviderFor,
    required this.onLineInvalidated,
  }) {
    _resolve();
    _computeSize();
  }

  ImageMarkup markup;

  final ImageProvider? Function(String source)? imageProviderFor;
  final ValueChanged<int> onLineInvalidated;

  int lineStart;
  int lineEnd;

  /// 建块时的源码行；只有内容变了才需要重新解析与重新挂图片流。
  String lineText;

  AppPalette palette;
  double contentWidth;
  TextScaler textScaler;
  double? previewWidth;

  /// 正文的字号，只用来估源码行要占多高。
  double sourceFontSize;

  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _info;
  bool _failed = false;
  bool _disposed = false;
  bool _invalidateScheduled = false;

  /// 被点中的那张图画一圈边框：图片是自绘的，没有别的办法告诉用户「就是它」。
  bool selected = false;

  /// 正在改这一行的源码：整行**长高一行**，图片整体下移，源码就写在让出来的
  /// 那一行里。不是浮在图上的一块面板。
  bool get showSource => _showSource;
  bool _showSource = false;
  set showSource(bool value) {
    if (value == _showSource) return;
    _showSource = value;
    _computeSize();
  }

  double _naturalWidth = 0;
  double _aspect = 1;

  /// 图片自己的尺寸。
  double _imageWidth = 0;
  double _imageHeight = 0;

  /// 让给源码的那一行有多高（不编辑时是 0）。
  double _sourceHeight = 0;

  /// 源码行浮层的宽度（不编辑时是 0）。
  double _sourceWidth = 0;

  /// 图片相对于行顶的偏移。
  ///
  /// 恒为 0：源码行不再把图片顶下去，它浮在图片上面。
  double _imageTop = 0;

  double _width = 0;
  double _height = 0;
  Offset _chromeOrigin = Offset.zero;

  /// 浮动时图片与正文之间的间距。
  static const double _floatGap = 18;

  /// 图片横向占住的总宽度（含间距）；不浮动时为 0。
  @override
  double get chromeFloatWidth =>
      markup.align == null ? 0 : _imageWidth + _floatGap;

  /// 靠边浮动时贴哪一边；改源码时也照旧浮动。
  @override
  ImageAlign? get chromeAlign => markup.align;

  /// 浮动时整块相对行左边缘的横向偏移：贴右边就整块右移，贴左边不动。
  double get _floatDx => markup.align == ImageAlign.right
      ? math.max(0.0, contentWidth - _imageWidth)
      : 0;

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
    required double sourceFontSize,
  }) {
    final bool changed =
        palette != this.palette ||
        contentWidth != this.contentWidth ||
        this.textScaler != textScaler ||
        this.previewWidth != previewWidth ||
        sourceFontSize != this.sourceFontSize;
    this.palette = palette;
    this.contentWidth = contentWidth;
    this.textScaler = textScaler;
    this.previewWidth = previewWidth;
    this.sourceFontSize = sourceFontSize;
    // 自愈：块被复用而解码结果不知怎么丢了（流被拆过、上一次回调没赶上），
    // 下一次排版就把图片重新挂上，不必等用户去点一下那一行。
    if (_info == null && _stream == null && !_failed) _resolve();
    if (changed) _computeSize();
  }

  /// 同一行换了内容（宽度、alt、缩进）。
  ///
  /// 引用没变就**不重挂图片流**：回车把这一行的缩进或列表编号改掉、或者用户只
  /// 改了 `width=`，重挂等于把解码结果丢掉重来一遍，中间那几帧就是一张占位
  /// ——看起来就是「图片黑了一下」。只有换了图才真的重建。
  void updateLine({
    required String lineText,
    required ImageMarkup next,
  }) {
    this.lineText = lineText;
    final bool newSource = next.source != markup.source;
    markup = next;
    if (newSource) {
      _detachStream();
      _info?.dispose();
      _info = null;
      _naturalWidth = 0;
      _aspect = 1;
      _failed = false;
      _resolve();
    }
    _computeSize();
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

  void _detachStream() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _listener = null;
    _stream = null;
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (_disposed) {
      info.dispose();
      return;
    }
    final ImageInfo? previous = _info;
    // 同一个实例：既不能 dispose 它（那正是我们在用的那一份），也不必换。
    if (identical(info, previous)) return;
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
    // 浮动图片不能把整行吃光：旁边还得留得下正文，否则「左文字右图片」就成
    // 了一句空话。上限取正文列的 62%。
    final double roomCap = markup.align == null
        ? room
        : math.max(96.0, room * 0.62);
    double w;
    double h;
    if (_info == null) {
      w = math.min(360.0, roomCap);
      h = 120;
    } else {
      final double? declared = previewWidth ?? markup.width;
      if (declared != null) {
        w = declared.clamp(96.0, math.max(96.0, roomCap));
      } else {
        w = math.min(_naturalWidth, roomCap);
        if (_aspect > 0 && w / _aspect > 640) {
          w = 640 * _aspect;
        }
      }
      if (!w.isFinite || w <= 0) w = math.min(360.0, roomCap);
      h = _aspect > 0 ? w / _aspect : 120;
    }
    _imageWidth = w;
    _imageHeight = h;

    // 编辑源码时那一行**浮在图片上**，一个像素都不占布局：图片的位置、大小、
    // 贴哪一边全都不动。以前是让出一行高度、图片整体下移，代价是点一下
    // 「编辑这个区块」整个版面就跳一次——浮动图片更糟，贴边会被临时取消，
    // 旁边的正文跟着重排。改源码是「看这一行字」，不该顺手重排整篇。
    if (_showSource) {
      final double fontSize = textScaler.scale(sourceFontSize);
      // 至少 360 宽：一行 `<img src="…" width="…">` 挤在 200px 里要折四行。
      _sourceWidth = math.max(240.0, math.min(room - 24, math.max(w - 24, 360)));
      final int lines = math
          .max(
            1,
            (lineText.length * fontSize * 0.58 / math.max(1.0, _sourceWidth - 20))
                .ceil(),
          )
          .clamp(1, 6);
      _sourceHeight = lines * fontSize * 1.5 + 12;
    } else {
      _sourceWidth = 0;
      _sourceHeight = 0;
    }
    _imageTop = 0;

    _width = w;
    _height = h;
  }

  @override
  void chromeSourceRange(int start, int end) {
    lineStart = start;
    lineEnd = end;
  }

  @override
  set chromeOrigin(Offset value) => _chromeOrigin = value;

  @override
  Rect chromeImageBounds() => Rect.fromLTWH(
    _chromeOrigin.dx + _floatDx,
    _chromeOrigin.dy + _imageTop,
    _imageWidth,
    _imageHeight,
  );

  /// 源码浮窗该摆在哪：图片**左上角内侧**，浮在图上。
  ///
  /// 不再「让出一行」——那会让整篇跳一下。图片太窄时往右借地方，但绝不伸出
  /// 正文列；贴右边时同样夹回来，窗口不会跑出可编辑区。
  @override
  Rect chromeSourceBounds() {
    if (_sourceHeight <= 0 || _sourceWidth <= 0) return Rect.zero;
    const double inset = 12;
    final double left = math.min(
      _floatDx + inset,
      math.max(0.0, contentWidth - _sourceWidth - 4),
    );
    return Rect.fromLTWH(
      _chromeOrigin.dx + math.max(0.0, left),
      _chromeOrigin.dy + inset,
      _sourceWidth,
      _sourceHeight,
    );
  }

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
  set chromeSelected(bool value) => selected = value;

  @override
  bool get chromeSelected => selected;

  @override
  void paint(Canvas canvas, Offset origin, Offset globalOrigin) {
    _chromeOrigin = globalOrigin;
    final Rect rect = Rect.fromLTWH(
      origin.dx + _floatDx,
      origin.dy + _imageTop,
      _imageWidth,
      _imageHeight,
    );
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

    // 选中：再描一圈强调色。往里收 1px，压在细描边上而不是盖到图片外面去。
    if (selected) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(1), const Radius.circular(4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = palette.accent,
      );
    }

    // 正在改这一行的源码：整张图压暗一点。源码行浮在它上沿，图片仍是原尺寸
    // 原位置——压暗只是告诉人「现在动的是这张图的源码」，不是要重排。
    if (_showSource) {
      canvas.drawRRect(rounded, Paint()..color = const Color(0x33000000));
    }
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
  int offsetAt(Offset local) {
    // 整块按左右半边给行首/行尾。源码行让出来之后只是块的上半截变成了字，
    // 规矩不变——按图的一半分，不按行宽分，图缩得比行窄时才对得上眼睛。
    return local.dx < _imageWidth / 2 ? lineStart : lineEnd;
  }

  @override
  Rect caretRectAt(int offset) {
    final double x = offset >= lineEnd ? math.max(0, _imageWidth - 2) : 0;
    return Rect.fromLTWH(
      x + _floatDx,
      0,
      2,
      math.max(_imageHeight, 1),
    );
  }

  @override
  List<Rect> highlightRects(int from, int to) {
    if (to <= from || to < lineStart || from > lineEnd) return const <Rect>[];
    // 整行都被选中：源码行（如果有）和图片一起盖住，不然选中的那一行中间会
    // 留出一条没染色的缝。
    return <Rect>[Rect.fromLTWH(_floatDx, 0, _width, _height)];
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detachStream();
    // **不要在这里立刻释放解码结果**：换行、重排、行复用都会丢块，而行布局可能
    // 还拿着这一块画最后一帧——`ui.Image` 一没，`drawImageRect` 照样画，画出来
    // 就是一整块纯黑。推到下一帧末尾，那时已经没有任何人指着它了。
    final ImageInfo? orphan = _info;
    if (orphan == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_info, orphan)) return;
      _info = null;
      // 万一这一帧之后还有人在画它，至少落回一小块占位，而不是一张大黑图。
      _computeSize();
      orphan.dispose();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
