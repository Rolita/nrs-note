import 'dart:async';

import 'package:window_manager/window_manager.dart';

import 'boot_trace.dart';

/// 把「关闭窗口」改成「先落盘再关闭」。
///
/// 自动保存有几百毫秒的去抖窗口，直接退出会丢掉最后几个字。这里拦截关闭
/// 事件，等 [flush] 完成再真正销毁窗口；写入卡住或失败也有超时兜底，
/// 不让用户关不掉窗口。
class _CloseGuard with WindowListener {
  _CloseGuard(this.flush);

  final Future<void> Function() flush;
  bool _closing = false;

  @override
  void onWindowClose() {
    if (_closing) return;
    _closing = true;
    unawaited(_finish());
  }

  Future<void> _finish() async {
    BootTrace.restart('close requested');
    try {
      await flush().timeout(const Duration(seconds: 3));
    } on Object {
      // 写盘失败也要放行关闭：用户要的是退出，不是被卡在窗口里。
    }
    BootTrace.mark('flush done');
    // ⏱ `windowManager.destroy()` 只是 `PostQuitMessage(0)`，它不销毁窗口。
    // 窗口是 C++ 那边 `Win32Window` 的析构函数销毁的，而它排在整个引擎之后
    // ——Dart VM、光栅线程、D3D 设备收尾实测两秒。所以直接 destroy 的话，
    // 用户要盯着一个已经没用的窗口发呆两秒。
    //
    // 先 hide：一帧之内窗口就从屏幕上消失（连任务栏一起），引擎在后台慢慢收
    // 自己的尾，用户看不见。
    await windowManager.hide();
    BootTrace.mark('window hidden');
    // 窗口一销毁进程就没了，日志必须赶在那之前落盘。
    await BootTrace.flushNow();
    await windowManager.destroy();
  }
}

Future<void> guardCloseBeforeExit(Future<void> Function() flush) async {
  await windowManager.setPreventClose(true);
  windowManager.addListener(_CloseGuard(flush));
}
