/// 「查看大图」那一层。
///
/// 从 `markdown_editor.dart` 搬出来单独成文件，顺带补齐：原来只有「铺满 +
/// 点哪儿都退」，一张长截图想看清某个角落就只能干瞪眼。
///
/// | | 功能 | 落在哪 |
/// |---|---|---|
/// | ① | 缩放 / 平移 | `InteractiveViewer` + 滚轮 + 底栏百分比 |
/// | ② | 双击在「适配」和「原图 1:1」之间跳 | `_toggleZoom` |
/// | ③ | 旋转 90° | 顶栏两枚按钮 + `R` `⇧R` `Q` `E` |
/// | ④ | 上一张 / 下一张 | 底栏胶片条 + 两侧箭头 + `←` `→` `A` `D` |
/// | ⑤ | 原图尺寸 | 顶栏副行，读文件头拿（不解码） |
/// | ⑥ | 加载态 | `frameBuilder` 转圈 + 淡入 |
/// | ⑦ | 位置徽标 `3 / 12` | 顶栏 |
///
/// ## ⛔ 百分比是「相对原图」，不是「相对适配」
///
/// 底栏那个数字 = `_scale / _baseScale`，其中 `_baseScale` 是「原图 1:1 时该放
/// 多大」。适配窗口时显示 `33%`（还能放 3 倍到 1:1），双击放到 1:1 是 `100%`。
/// 换成「相对适配」的话，用户会以为「都 400% 了怎么还这么小」——系统看图工具
/// 一律是前者。
///
/// 拿不到原图尺寸（远程图、WebP 之外认不出的格式）时 `_baseScale` 退回 1，
/// 百分比就是相对适配的倍数。不知道原图多大，这是唯一诚实的说法。
///
/// ## ⛔ 双击跳到 1:1，不是跳到上限
///
/// 上限是 `1:1 × 3`。双击一下糊成色块不是「看细节」该有的样子——要看更大
/// 按 `+`。EPUB Reader 那边同一条口径。
///
/// ## ⛔ 点图片本身不关，点图片外面才关
///
/// 手指落下去是想看细节，不是想退出。靠的是 `Image` 在 `Center` 里按自身
/// 尺寸排布（`BoxFit.contain` 在 loose 约束下的行为），`GestureDetector` 因此
/// 只盖住图的实际矩形——四周留白落到最外层那个 `onTap: onClose` 上。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_tokens.dart';
import '../../core/utils/note_image_io.dart';

/// 大图浮层里的一张图。
class NoteImageView {
  const NoteImageView({
    required this.source,
    required this.alt,
    required this.provider,
    this.absolutePath,
  });

  /// 笔记里写的那串引用（相对路径 / URL / data URI）。
  final String source;

  /// 源码里的 alt。
  final String? alt;

  final ImageProvider provider;

  /// 解析到磁盘上的绝对路径；远程图是 null（读不出尺寸，也不能另存）。
  final String? absolutePath;

  /// 文件名：`assets/截图.png` → `截图.png`。
  String get fileName {
    final String tail = source.split(RegExp(r'[/\\]')).last;
    return tail.isEmpty ? source : tail;
  }

  /// 顶栏那行大字：有 alt 用 alt，没有退回文件名。
  String get title {
    final String? text = alt?.trim();
    return text == null || text.isEmpty ? fileName : text;
  }
}

/// 打开这张图（[images] 里的第 [index] 张）。
///
/// 单张也要传列表——浮层里「有没有上一张下一张」全看这个列表的长度，
/// 不为「只有一张」另开一条分支。
class NoteImageViewer extends StatefulWidget {
  const NoteImageViewer({
    super.key,
    required this.images,
    required this.index,
    required this.onClose,
  });

  final List<NoteImageView> images;
  final int index;
  final VoidCallback onClose;

  @override
  State<NoteImageViewer> createState() => _NoteImageViewerState();
}

class _NoteImageViewerState extends State<NoteImageViewer> {
  /// 底栏高度。要装得下 `TextButton`（Material 的最小高度 48），别按胶片条
  /// 的 20 来设——设小了「复位」会把底栏撑破。
  static const double _footerHeight = 52;

  /// 每次按 `+` / `-` 的倍数。
  static const double _zoomStep = 2;

  /// 能放到「原图 1:1」的几倍。3 = 底栏最多到 300%。
  static const double _maxPixelRatio = 3;

  /// 胶片条每一项的槽宽（图 26 + 缝 4）。
  ///
  /// ⛔ 必须是定值并交给 `ListView.itemExtent`——自动定位靠 `index × 槽宽` 算，
  /// 交给 `itemExtent` 才和真实布局对齐。
  static const double _stripSlot = 30;
  static const double _stripThumbWidth = 26;
  static const double _stripThumbHeight = 20;

  late int _index;
  final TransformationController _transform = TransformationController();
  final ScrollController _strip = ScrollController();

  /// 当前缩放倍数，相对「适配窗口」的 1x。由 [_transform] 的 listener 同步，
  /// 手势捏合 / 滚轮缩放也要反映到底栏。
  double _scale = 1;

  /// 视口尺寸。`LayoutBuilder` 在 layout 阶段写入，首帧时还是零。
  Size _viewport = Size.zero;

  /// 顺时针 90° 的次数（0..3）。
  ///
  /// ⚠️ 只改显示，不动字节。⚠️ 跨图保留：侧着的往往是同一批截图，逐张重转
  /// 是纯受罪，转错了再点两下就回去。
  int _quarterTurns = 0;

  /// 当前这张的原图尺寸，读不出来是 null。
  ({int width, int height})? _size;

  /// 已探过的尺寸，切回来不用再读一次盘。
  final Map<String, ({int width, int height})?> _sizeCache =
      <String, ({int width, int height})?>{};

  @override
  void initState() {
    super.initState();
    _index = widget.index.clamp(0, math.max(0, widget.images.length - 1));
    _transform.addListener(_onTransformChanged);
    _probeSize();
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    _strip.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final double next = _transform.value.getMaxScaleOnAxis();
    // 阈值 guard 不能省：`_go` 里先 setState 再复位矩阵，复位会触发这里，
    // 不 guard 就是连着两次重建。
    if ((next - _scale).abs() < 0.001) return;
    setState(() => _scale = next);
  }

  // ── 当前这张 ────────────────────────────────────────────────────────────

  NoteImageView? get _image =>
      _index >= 0 && _index < widget.images.length
      ? widget.images[_index]
      : null;

  bool get _stripVisible => widget.images.length > 1;
  bool get _hasPrev => _stripVisible && _index > 0;
  bool get _hasNext => _stripVisible && _index < widget.images.length - 1;

  String? get _position =>
      _stripVisible ? '${_index + 1} / ${widget.images.length}' : null;

  /// 顶栏副行：`1920 × 1080`。读不出来就不显示，不拿「未知」占位。
  String? get _dimensions {
    final size = _size;
    if (size == null) return null;
    return '${size.width} × ${size.height}';
  }

  Future<void> _probeSize() async {
    final NoteImageView? image = _image;
    if (image == null) return;

    final String? path = image.absolutePath;
    if (path == null) {
      if (_size != null) setState(() => _size = null);
      return;
    }

    if (_sizeCache.containsKey(path)) {
      final cached = _sizeCache[path];
      if (cached != _size) setState(() => _size = cached);
      return;
    }

    final size = await imageSizeAt(path);
    _sizeCache[path] = size;
    if (!mounted) return;
    // 读完可能已经翻到下一张了——别把上一张的尺寸贴到这一张上。
    if (_image?.absolutePath != path) return;
    setState(() => _size = size);
  }

  // ── 尺寸口径 ────────────────────────────────────────────────────────────

  /// 图**自己那一侧**看到的视口——旋转 90° / 270° 时宽高互换。
  ///
  /// ⛔ 少了这一步，横过来看时百分比就会和眼睛看到的不一致：`RotatedBox` 把
  /// 约束转置之后才交给 `Image`。
  Size get _imageViewport => _quarterTurns.isOdd
      ? Size(_viewport.height, _viewport.width)
      : _viewport;

  /// 「原图 1:1」对应的倍数，也就是底栏显示 `100%` 的那一档。
  ///
  /// = `原图宽 / 图在视口里的显示宽`。这是唯一的锚点：上限、双击落点、底栏
  /// 百分比三处都从它推，别各自算一套。
  double get _baseScale {
    final size = _size;
    if (size == null || _viewport.isEmpty) return 1;

    final Size viewport = _imageViewport;
    if (viewport.isEmpty) return 1;

    final double aspect = size.width / size.height;
    // `Image` 在 loose 约束下按自身尺寸排布，装不下才等比缩到装得下。
    final double shown = math.min(
      math.min(viewport.width, size.width.toDouble()),
      viewport.height * aspect,
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

  /// 底栏那个百分比——**相对原图**，不是相对「适配」。
  ///
  /// = `_scale / _baseScale`（⛔ 是除不是乘）。
  double get _pixelPercent => _scale / _baseScale;

  // ── 动作 ────────────────────────────────────────────────────────────────

  void _go(int delta) {
    final int next = _index + delta;
    if (next < 0 || next >= widget.images.length) return;

    setState(() {
      _index = next;
      // 换了图就回适配——不重置的话，一张放到 300% 的图切过去，新图凭空
      // 也从 300% 开始，多半是糊的。
      // ⚠️ 旋转刻意不重置，同一批图一个朝向。
      _scale = 1;
      _size = _sizeCache[widget.images[next].absolutePath];
    });
    _transform.value = Matrix4.identity();
    _centerStrip(next);
    _probeSize();
  }

  /// 把胶片条滚到第 [index] 项居中。
  void _centerStrip(int index) {
    if (!_strip.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_strip.hasClients) return;
      final double target =
          index * _stripSlot -
          (_strip.position.viewportDimension - _stripSlot) / 2;
      _strip.animateTo(
        target.clamp(0.0, _strip.position.maxScrollExtent),
        duration: AppMotion.fast,
        curve: AppMotion.enter,
      );
    });
  }

  /// 以视口中心为焦点缩放到 [value]。
  ///
  /// 为什么不做「以鼠标位置为焦点」：`InteractiveViewer` 的边界钳制只发生在
  /// 手势过程里，程序化写 `value` 不会被钳——以任意点为焦点很容易把内容推出
  /// 可视区，用户看到一片空白还得手动拖回来。中心缩放永远不会越界。
  void _setScale(double value) {
    final double next = value.clamp(1.0, _maxScale);
    final double dx = _viewport.width / 2;
    final double dy = _viewport.height / 2;

    // 直接搭「以 (dx, dy) 为焦点缩放 next 倍」的矩阵：
    //
    //     [ next  0     0  dx(1−next) ]
    //     [ 0     next  0  dy(1−next) ]
    //
    // 焦点不动（代入 (dx,dy) 得回 (dx,dy)）——这正是「中心缩放不越界」的由来。
    // ⛔ 别退回 `..translate()..scale()..translate()` 那串链式写法：那两个方法
    //    在 vector_math 里已标废弃，analyze 会平白多出几条 info。
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, next)
      ..setEntry(1, 1, next)
      ..setEntry(0, 3, dx * (1 - next))
      ..setEntry(1, 3, dy * (1 - next));
  }

  void _zoomIn() => _setScale(_scale * _zoomStep);
  void _zoomOut() => _setScale(_scale / _zoomStep);
  void _resetZoom() => _setScale(1);

  /// 双击：在「适配」和「原图 1:1」之间跳。
  void _toggleZoom() {
    if (_scale > 1.001) {
      _resetZoom();
    } else {
      _setScale(_baseScale);
    }
  }

  /// 旋转 90°。[delta] 为 `1` = 顺时针、`-1` = 逆时针。
  ///
  /// 转完视口宽高换了，原来那份平移量会把图推出可视区，所以重新以视口中心
  /// 摆一次矩阵——倍数不动、重新居中。转过来是为了看清细节，转完被打回适配
  /// 档会很难受。
  void _rotate(int delta) {
    setState(() => _quarterTurns = (_quarterTurns + delta) % 4);
    _setScale(_scale);
  }

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // ⛔ 键盘绑定必须在 `Focus` 的**祖先**方向——按键从持有焦点的节点沿
    //    focus 树向上冒泡，`CallbackShortcuts` 内建的那个 `Focus` 得在冒泡
    //    路径上才收得到。写反（`Focus` 在外）会静默失效。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
        // `+` 在美式键盘上是 Shift+`=`，小键盘另有 `add`——三条都绑上，
        // 不然「加号按了没反应」会变成一条玄学 bug。
        const SingleActivator(LogicalKeyboardKey.equal): _zoomIn,
        const SingleActivator(LogicalKeyboardKey.equal, shift: true): _zoomIn,
        const SingleActivator(LogicalKeyboardKey.add): _zoomIn,
        const SingleActivator(LogicalKeyboardKey.numpadAdd): _zoomIn,
        const SingleActivator(LogicalKeyboardKey.minus): _zoomOut,
        const SingleActivator(LogicalKeyboardKey.numpadSubtract): _zoomOut,
        const SingleActivator(LogicalKeyboardKey.digit0): _resetZoom,
        const SingleActivator(LogicalKeyboardKey.numpad0): _resetZoom,
        // 旋转：`R` 向右、`⇧R` 向左；`Q` / `E` 是给用惯看图工具的人的。
        //
        // ⛔ `SingleActivator` 的 `shift: false` 意思是「要求 Shift 没按下」，
        //    所以「R 与 ⇧R 都要触发」必须一个字母绑两条。
        const SingleActivator(LogicalKeyboardKey.keyR): () => _rotate(1),
        const SingleActivator(LogicalKeyboardKey.keyR, shift: true): () =>
            _rotate(-1),
        const SingleActivator(LogicalKeyboardKey.keyE): () => _rotate(1),
        const SingleActivator(LogicalKeyboardKey.keyE, shift: true): () =>
            _rotate(1),
        const SingleActivator(LogicalKeyboardKey.keyQ): () => _rotate(-1),
        const SingleActivator(LogicalKeyboardKey.keyQ, shift: true): () =>
            _rotate(-1),
        // 翻页：`←` `→` 之外的字母版，左手不用离开主键区。
        const SingleActivator(LogicalKeyboardKey.keyA): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.keyA, shift: true): () =>
            _go(-1),
        const SingleActivator(LogicalKeyboardKey.keyD): () => _go(1),
        const SingleActivator(LogicalKeyboardKey.keyD, shift: true): () =>
            _go(1),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: ColoredBox(
              color: const Color(0xE6000000),
              child: SafeArea(
                child: Column(
                  children: <Widget>[
                    _buildHeader(),
                    _hairline(),
                    Expanded(child: _buildStage()),
                    _hairline(),
                    _buildFooter(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hairline() =>
      Container(height: 1, color: const Color(0x1AFFFFFF));

  Widget _buildHeader() {
    final NoteImageView? image = _image;
    final String? position = _position;
    final String? dimensions = _dimensions;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        image?.title ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: AppText.ui,
                          color: Color(0xFFFFFFFF),
                        ),
                      ),
                    ),
                    if (position != null) ...<Widget>[
                      const SizedBox(width: AppSpace.sm),
                      _Badge(text: position),
                    ],
                  ],
                ),
                if (dimensions != null) ...<Widget>[
                  const SizedBox(height: AppSpace.xxs),
                  Text(
                    dimensions,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppText.caption,
                      color: Color(0x8AFFFFFF),
                    ),
                  ),
                ],
              ],
            ),
          ),
          _ViewerButton(
            icon: LucideIcons.rotateCcw,
            tip: '向左旋转 90°（Q）',
            onTap: () => _rotate(-1),
          ),
          _ViewerButton(
            icon: LucideIcons.rotateCw,
            tip: '向右旋转 90°（E）',
            onTap: () => _rotate(1),
          ),
          _ViewerButton(
            icon: LucideIcons.x,
            tip: '关闭（Esc）',
            onTap: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildStage() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // ⚠️ `LayoutBuilder` 的 builder 在 layout 阶段才跑，而 `Column` 里
        //    后面的底栏早就 build 过了——所以首帧算百分比时 `_viewport` 还是
        //    零。写完推一帧重建补上；不做这一步的话，底栏会停在「100%」直到
        //    用户碰一下缩放。
        if (constraints.biggest != _viewport) {
          _viewport = constraints.biggest;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }

        return Stack(
          children: <Widget>[
            Positioned.fill(child: _buildViewer()),
            if (_hasPrev)
              _Arrow(alignment: Alignment.centerLeft, onTap: () => _go(-1)),
            if (_hasNext)
              _Arrow(alignment: Alignment.centerRight, onTap: () => _go(1)),
          ],
        );
      },
    );
  }

  Widget _buildViewer() {
    // ⛔ 双击挂在**图片上**，不是挂在外层。`GestureDetector` 同时有 `onTap` 和
    //    `onDoubleTap` 时，单击要等 `kDoubleTapTimeout`（300ms）才判定——挂在
    //    外层的话「点空白关闭」会慢半拍，点下去像是没反应。
    //    挂在图上，点空白时这条路径上根本没有 doubleTap，tap 立刻赢。
    return InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      // ⚠️ 与 `_baseScale` 是一套口径，别改成写死的 4。
      maxScale: _maxScale,
      child: Center(
        child: GestureDetector(
          // 点图本身不关：手指落下去是想看细节，不是想退出。
          // 它只盖住图的实际矩形，四周留白落到最外层那个 onTap 上。
          onTap: () {},
          onDoubleTap: _toggleZoom,
          child: RotatedBox(
            // ⛔ `quarterTurns: 0` 时也必须留着这一层：一旦按条件把它摘掉，
            //    这个位置的 widget 类型就变了 ⇒ `Image` 的 Element 被重建
            //    ⇒ 重新订阅图像流、加载态闪一下。转回去不该有任何副作用。
            quarterTurns: _quarterTurns,
            child: Image(
              image: _image?.provider ?? const NetworkImage(''),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              // ⛔ 不加 `gaplessPlayback`：这里换的是**另一张图**，留着上一帧
              //    的后果是「按了下一张，画面纹丝不动直到新图解码完」——
              //    用户以为按钮坏了。宁可中间那几十毫秒是一枚转圈。
              frameBuilder: _buildFrame,
              errorBuilder: (BuildContext context, Object _, _) => Padding(
                padding: const EdgeInsets.all(AppSpace.xxl),
                child: Text(
                  _image?.alt ?? '图片打不开',
                  style: const TextStyle(
                    fontSize: AppText.body,
                    color: Color(0x8AFFFFFF),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 加载态：解码没回来时给一枚转圈，回来后淡入。
  ///
  /// 一张 4K 截图解码要几十到几百毫秒，不给这个就是一片空白——用户会以为
  /// 「点了没反应」。`wasSynchronouslyLoaded` 那条是给已在 `imageCache` 里的
  /// 图省掉一次淡入（打开过的图不该再闪一下）。
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
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0x66FFFFFF),
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

  Widget _buildFooter() {
    return SizedBox(
      height: _footerHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        child: Row(
          children: <Widget>[
            if (_stripVisible)
              Expanded(child: _buildStrip())
            else
              const Spacer(),
            const SizedBox(width: AppSpace.md),
            Text(
              '${(100 * _pixelPercent).round()}%',
              style: const TextStyle(
                fontSize: AppText.caption,
                color: Color(0x8AFFFFFF),
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            _FooterButton(
              label: '复位',
              // 已经在适配档就没什么可复位的——置灰而不是让它点了没反应
              onTap: _scale > 1.001 ? _resetZoom : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 胶片条——一眼看到「我在第几张、还剩几张」。
  ///
  /// 缩略图直接用原 provider：nrs 的图本来就是磁盘文件，`FileImage` 自己带
  /// 缓存，再为 26px 的格子造一套降采样解码不值当。
  Widget _buildStrip() {
    return ListView.builder(
      controller: _strip,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
      itemExtent: _stripSlot,
      itemCount: widget.images.length,
      itemBuilder: (BuildContext context, int i) {
        final NoteImageView entry = widget.images[i];
        final bool current = i == _index;

        return Center(
          child: GestureDetector(
            onTap: current ? null : () => _go(i - _index),
            child: Container(
              width: _stripThumbWidth,
              height: _stripThumbHeight,
              decoration: BoxDecoration(
                color: const Color(0x1AFFFFFF),
                borderRadius: BorderRadius.circular(AppRadius.xs),
                border: Border.all(
                  color: current
                      ? const Color(0xFFFFFFFF)
                      : const Color(0x33FFFFFF),
                  width: current ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image(
                image: entry.provider,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                errorBuilder: (BuildContext context, Object _, _) =>
                    const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 顶栏那枚位置徽标（`3 / 12`）。
class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: const Color(0x26FFFFFF),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: AppText.caption, color: Color(0xFFFFFFFF)),
      ),
    );
  }
}

/// 顶栏那几枚图标按钮。
class _ViewerButton extends StatefulWidget {
  const _ViewerButton({
    required this.icon,
    required this.tip,
    required this.onTap,
  });

  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_ViewerButton> createState() => _ViewerButtonState();
}

class _ViewerButtonState extends State<_ViewerButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
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
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(left: AppSpace.xs),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? const Color(0x33FFFFFF) : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(widget.icon, size: AppIconSize.sm, color: const Color(0xFFFFFFFF)),
          ),
        ),
      ),
    );
  }
}

/// 底栏那个文字按钮（复位）。
class _FooterButton extends StatefulWidget {
  const _FooterButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  State<_FooterButton> createState() => _FooterButtonState();
}

class _FooterButtonState extends State<_FooterButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    final Color foreground = !enabled
        ? const Color(0x4DFFFFFF)
        : (_hovered ? const Color(0xFFFFFFFF) : const Color(0xB3FFFFFF));

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered && enabled
                ? const Color(0x1AFFFFFF)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            widget.label,
            style: TextStyle(fontSize: AppText.label, color: foreground),
          ),
        ),
      ),
    );
  }
}

/// 主区两侧那枚切图箭头。
///
/// 底色用半透明黑——图可能是浅底也可能是深底，纯图标会有一半场合看不清。
class _Arrow extends StatefulWidget {
  const _Arrow({required this.alignment, required this.onTap});

  final Alignment alignment;
  final VoidCallback onTap;

  @override
  State<_Arrow> createState() => _ArrowState();
}

class _ArrowState extends State<_Arrow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool isLeft = widget.alignment == Alignment.centerLeft;

    return Align(
      alignment: widget.alignment,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hovered ? const Color(0x40FFFFFF) : const Color(0x1A000000),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x33FFFFFF)),
              ),
              child: Icon(
                isLeft ? LucideIcons.chevronLeft : LucideIcons.chevronRight,
                size: AppIconSize.lg,
                color: const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
