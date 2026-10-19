import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop window sizing. Runs before the first frame so the app never flashes
/// at the wrong size.
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
  });
}
