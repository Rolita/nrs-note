import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'boot_trace.dart';

/// Desktop window sizing.
///
/// ⏱ 调用点在 `runApp` **之后**：这串原生调用（去掉系统标题栏、定尺寸、居中、
/// 设最小尺寸……实测 110~220ms）只决定「什么时候看得见」，不决定「看得见
/// 什么」。放在 `runApp` 前面，引擎要等它做完才开始画；放在后面，引擎一边画
/// 一边等窗口准备好，用户早一点看到窗口。
///
/// ⛔ 也别在显示之前等「第一帧画完」（`SchedulerBinding.endOfFrame`）：窗口
/// 还隐藏的时候引擎不保证出帧，实测这一等是 500ms 起步，比不等还慢。
///
/// [opacity] 是设置里存下的窗口不透明度（0.6–1.0）；由调用方读偏好后传进来，
/// 平台层不碰存储。
Future<void> setupWindow({required double opacity}) async {
  await windowManager.ensureInitialized();
  const WindowOptions options = WindowOptions(
    size: Size(1360, 880),
    minimumSize: Size(900, 580),
    center: true,
    title: 'NRS · Markdown 笔记',
    // The caption is drawn by the app itself (`ui/shell/title_bar_io.dart`).
    // `hidden` keeps the native resize border and the DWM shadow; only the
    // 36px strip of system chrome goes away.
    titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    // 先把 alpha 设好再显示：第一帧起就是用户存下的透明度，不会先实一帧
    // 再变淡。
    await applyWindowOpacity(opacity);
    try {
      // 窗口此刻才第一次出现在屏幕上。runner 里那句「第一帧就 Show」已经
      // 去掉（见 windows/runner/flutter_window.cpp）：窗口刚创建时还在
      // (10, 10)，而真正的尺寸和居中要等上面这串调用做完才知道，第一帧就
      // 显示会先在左上角闪一下再跳到中间。
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // 显示失败也只能继续往下走：这里没有第二种办法让窗口出现。
    }
    BootTrace.mark('window shown');
  });
}

/// 把整扇窗设成 [opacity]——设置里的「窗口不透明度」实时调它。
///
/// ⛔ 这是**整个窗口**的 alpha（原生 `SetLayeredWindowAttributes`），不是逐像素
/// 透明：Flutter 的 Windows 嵌入层没有逐像素透明通道，`Theme` 里再叠一层
/// 只会把两层 alpha 相乘（0.9 × 0.9 = 0.81），纸面比视觉稿暗一截。所以调色板
/// 保持原色，透明度只设在窗口上。
Future<void> applyWindowOpacity(double opacity) async {
  try {
    await windowManager.setOpacity(opacity.clamp(0.0, 1.0));
  } on Object {
    // 纯观感：设不上就当不透明，别挡住启动或调设置。
  }
}
