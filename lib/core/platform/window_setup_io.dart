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
    titleBarStyle: TitleBarStyle.normal,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}
