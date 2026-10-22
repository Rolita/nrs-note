import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';

/// 一次屏幕取样的结果。
@immutable
class ScreenSample {
  const ScreenSample({
    required this.color,
    required this.buttonDown,
    required this.escapeDown,
  });

  /// 光标下那一个像素。屏幕像素永远是不透明的。
  final Color color;

  /// 左键此刻是否按着。
  final bool buttonDown;

  /// Esc 此刻是否按着。
  final bool escapeDown;
}

/// 屏幕吸管的原生接口，对应 windows/runner 里注册的 `nrs/screen` 通道。
///
/// 只有 Windows 端实现了它。其它平台（网页端、`flutter test`）每次调用都会
/// 拿到 null —— 吸管安静收工，而不是抛异常打断界面。
abstract final class ScreenSampler {
  static const MethodChannel channel = MethodChannel('nrs/screen');

  /// 向原生发一条命令。原生不在（非 Windows、测试环境）或这一枪失败都当没发生，
  /// 让调用方各自决定怎么收场。
  static Future<Object?> _call(String method) async {
    try {
      return await channel.invokeMethod<Object?>(method);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// 取一次当前屏幕状态；原生不在或这一帧读不到时返回 null。
  static Future<ScreenSample?> sample() async {
    final Object? raw = await _call('sample');
    if (raw is! Map) return null;

    final Object? color = raw['color'];
    if (color is! int) return null;
    return ScreenSample(
      // 原生侧是有符号 int64，掩一下再交给 Color，免得高位符号位被当成 alpha。
      color: Color(color & 0xFFFFFFFF),
      buttonDown: raw['down'] == true,
      escapeDown: raw['escape'] == true,
    );
  }

  /// 取色开始：让原生把鼠标抓住。
  ///
  /// 抓住之后，确认取色的那一下会落在本进程上，而不是落在指针底下的那个窗口
  /// 上 —— 否则对方会被激活、抢到前面来，把编辑器和提示层盖住，看着就像「点了
  /// 没反应」。顺带也不用担心误触对方界面。
  static Future<void> begin() => _call('start');

  /// 取色结束：还回鼠标。命中、取消、原生不可用，每条路都要走到。
  static Future<void> end() => _call('stop');
}

/// 轮询式的吸管状态机。
///
/// 为什么要有「上膛」这一步：点吸管按钮的那一下本身就是一个左键按下。不等它
/// 抬起就开始判定，第一次轮询就会把这一下当成「确认取色」。
class ScreenEyedropper {
  ScreenEyedropper({
    required this.onPicked,
    required this.onDismissed,
    this.onSample,
    this.interval = const Duration(milliseconds: 16),
  });

  /// 取到了颜色。调用之后本对象已经停止，不会再有任何回调。
  final ValueChanged<Color> onPicked;

  /// 取消（Esc），或者原生根本没得取（非 Windows）。
  final VoidCallback onDismissed;

  /// 每一帧光标下的颜色，还没点下去也会报。取色期间窗口只剩底部一条，
  /// 「现在指着的是什么颜色」全靠它显示出来。
  final ValueChanged<Color>? onSample;

  /// 轮询间隔。约等于一个 60Hz 的帧。
  final Duration interval;

  Timer? _timer;
  bool _armed = false;
  bool _polling = false;

  /// 原生通道根本没回应（没挂上 / 平台没有实现）。
  ///
  /// 和「用户按 Esc」必须分开：一个该提示，一个不该。两者最终都是「没取到
  /// 颜色」，只有这里能说清是哪一种。
  bool unavailable = false;

  void start() {
    if (_timer != null) return;
    _armed = false;
    // 先抢鼠标再轮询。抓住鼠标不等它回来：晚一两个帧不影响取色（用户还要
    // 把指针挪过去），但不抢的话，第一下点击就会落到别的窗口上。
    unawaited(ScreenSampler.begin());
    _timer = Timer.periodic(interval, (Timer _) => _poll());
  }

  /// 幂等：命中、Esc、原生不可用之后都会走到这里。
  void stop() {
    final bool wasRunning = _timer != null;
    _timer?.cancel();
    _timer = null;
    if (wasRunning) unawaited(ScreenSampler.end());
  }

  Future<void> _poll() async {
    // 上一枪还没回来就别堆请求了 —— 通道是异步的，定时器不是。
    if (_polling) return;
    _polling = true;
    ScreenSample? sample;
    try {
      sample = await ScreenSampler.sample();
    } finally {
      _polling = false;
    }
    if (_timer == null) return; // 这一枪回来之前已经收工了

    if (sample == null) {
      // 原生不在（网页端 / 测试环境），或者这一帧真的读不到：没什么可做的，
      // 但要记下原因，好让界面说一句人话，而不是闪一下就没了。
      unavailable = true;
      stop();
      onDismissed();
      return;
    }
    if (sample.escapeDown) {
      stop();
      onDismissed();
      return;
    }
    // 先报颜色再判单击：确认的那一下也要让预览停在最终颜色上。
    onSample?.call(sample.color);
    if (!_armed) {
      if (!sample.buttonDown) _armed = true;
      return;
    }
    if (sample.buttonDown) {
      stop();
      onPicked(sample.color);
    }
  }
}

/// 一次屏幕取色会话：窗口上盖一层提示，轮询到命中或被取消为止。
class EyedropSession {
  EyedropSession._();

  final Completer<Color?> _completer = Completer<Color?>();

  /// 覆盖层与轮询器都是 [_start] 里挂上的；[end] 允许在它们之前就被调用，
  /// 所以这里都用可空类型。
  OverlayEntry? _entry;
  ScreenEyedropper? _eyedropper;

  /// 光标此刻指着的颜色，null 表示还没读到第一帧。
  ///
  /// 提示条和取色器都听它：取色时窗口被压成底部一条，界面里唯一还看得见
  /// 的反馈就是这条里的颜色，跟手才有「吸管在工作」的感觉。
  final ValueNotifier<Color?> live = ValueNotifier<Color?>(null);

  /// 取到的颜色；取消或原生不可用时是 null。
  Future<Color?> get done => _completer.future;

  /// 这次没取到颜色，是因为原生通道没回应（而不是用户按了 Esc）。
  bool get unavailable => _eyedropper?.unavailable ?? false;

  /// 结束会话。重复调用无副作用 —— 焦点拦截、原生 Esc 和调用方主动收回
  /// 可以随便抢着调。
  void end({Color? color}) {
    if (_completer.isCompleted) return;
    _eyedropper?.stop();
    _entry?.remove();
    _completer.complete(color);
  }

  void _start(OverlayState overlay) {
    _eyedropper = ScreenEyedropper(
      onPicked: (Color color) => end(color: color),
      onDismissed: () => end(),
      onSample: (Color color) => live.value = color,
    );
    // 盖在对话框之上：取色的目标可能是应用自己的任意一块界面，
    // 提示层挡在中间会连它一起取走。
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext _) => _EyedropLayer(
        onDismiss: () => end(),
        live: live,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _eyedropper?.start();
  }
}

/// 开一次屏幕取色，结果从 [EyedropSession.done] 拿。
///
/// 连 Overlay 都找不到（理论上不会发生）时返回 null，调用方当作没按下。
EyedropSession? startScreenEyedrop(BuildContext context) {
  final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;
  return EyedropSession._().._start(overlay);
}

/// 取色期间盖住整窗的一层：吃掉所有指针事件（免得顺手点到底下的界面），
/// 把光标换成十字，并在底部说明怎么用。
///
/// 它自己不取色 —— 颜色由原生通道读屏幕，因此指针跑到窗口外面也照样算数。
class _EyedropLayer extends StatefulWidget {
  const _EyedropLayer({required this.onDismiss, required this.live});

  final VoidCallback onDismiss;

  /// 光标下这一帧的颜色，来自 [EyedropSession.live]。
  final ValueListenable<Color?> live;

  @override
  State<_EyedropLayer> createState() => _EyedropLayerState();
}

class _EyedropLayerState extends State<_EyedropLayer> {
  final FocusNode _focus = FocusNode(debugLabel: 'nrs-eyedrop');

  @override
  void initState() {
    super.initState();
    // 必须真的拿到焦点：否则 Esc 会一路传到对话框，把整个编辑器关掉，
    // 而不是取消这一枪取色。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // 底片式的一枚药丸：亮色主题下深底浅字，深色主题下反过来，保证在
    // 任何屏幕内容之上都读得出来。
    final Color chip = p.textPrimary.withValues(alpha: 0.92);
    final Color onChip = p.canvas;

    // 原生会在取色开始时把窗口压成屏幕底部的一条。那时整块铺上底色 ——
    // 否则露出来的是被裁掉一半的界面，像窗口坏了。
    // 窗口没被压（原生没动，例如非 Windows）就保持透明，应用照旧可见。
    final bool collapsed = MediaQuery.sizeOf(context).height < 220;

    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      // Material 不是为了画东西，而是为了给这层里的 Text 一个正常的
      // DefaultTextStyle：OverlayEntry 挂在 Navigator 之上、Material 之下，
      // 少了它 Text 会继承 MaterialApp 的恐慌样式 —— 红字加黄双下划线。
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox.expand(
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: AbsorbPointer(
              child: Stack(
                children: <Widget>[
                  if (collapsed)
                    Positioned.fill(child: ColoredBox(color: p.canvas)),
                  Align(
                    alignment: collapsed
                        ? Alignment.center
                        : Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: collapsed ? 0 : AppSpace.xxl,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: chip,
                          borderRadius: AppRadius.pillAll,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpace.lg,
                            vertical: AppSpace.sm,
                          ),
                          child: ValueListenableBuilder<Color?>(
                            valueListenable: widget.live,
                            builder: (
                              BuildContext context,
                              Color? live,
                              Widget? _,
                            ) => Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                _LivePreview(color: live, ring: onChip),
                                const SizedBox(width: AppSpace.sm),
                                Text(
                                  live == null
                                      ? '单击取色 · Esc 取消'
                                      : '${_hexLabel(live)} · 单击取色 · Esc 取消',
                                  // decoration 显式写死：这一层不在 Scaffold
                                  // 里，别让任何继承来的下划线/删除线漏进来。
                                  style: TextStyle(
                                    fontSize: AppText.ui,
                                    color: onChip,
                                    decoration: TextDecoration.none,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 药丸左边那枚跟手的色块：还没读到颜色时退回吸管图标。
class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.color, required this.ring});

  final Color? color;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    const double size = 16;
    final Color? color = this.color;
    if (color == null) {
      return Icon(LucideIcons.pipette, size: size, color: ring);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: ring.withValues(alpha: 0.35)),
      ),
    );
  }
}

/// `#RRGGBB`，和取色器里的十六进制框同一个写法。
///
/// 这里没有复用 `app_color_picker.dart` 的 `hexText`：那个文件已经 import 了
/// 本文件，回头 import 会绕成一个圈。
String _hexLabel(Color c) {
  String two(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${two(c.r)}${two(c.g)}${two(c.b)}'.toUpperCase();
}
