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
Future<void> setupWindow() async {
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
    await windowManager.show();
    await windowManager.focus();
    BootTrace.mark('window shown');
  });
}
