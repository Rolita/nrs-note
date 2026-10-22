import 'dart:async';

import 'package:window_manager/window_manager.dart';

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
    try {
      await flush().timeout(const Duration(seconds: 3));
    } on Object {
      // 写盘失败也要放行关闭：用户要的是退出，不是被卡在窗口里。
    }
    await windowManager.destroy();
  }
}

Future<void> guardCloseBeforeExit(Future<void> Function() flush) async {
  await windowManager.setPreventClose(true);
  windowManager.addListener(_CloseGuard(flush));
}
