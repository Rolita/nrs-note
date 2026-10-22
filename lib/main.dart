import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/platform/close_guard.dart';
import 'core/platform/window_setup.dart';
import 'state/notes_controller.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On the web the browser's own right-click menu wins by default, and Flutter
  // then never delivers the right-click to the app — which would leave the
  // editor with no formatting surface at all, since the ribbon is gone.
  // Turning the browser menu off is what makes the editor's menu the only one
  // there, exactly as on the desktop build.
  if (kIsWeb) {
    unawaited(BrowserContextMenu.disableContextMenu());
  }

  await setupWindow();

  final SettingsController settings = await SettingsController.load();
  final NotesController notes = NotesController()..sortMode = settings.sort;

  // 关闭窗口前把去抖窗口里的最后一次编辑落盘；桌面端拦截关闭事件，
  // 浏览器端为空实现（见 close_guard_web.dart）。
  await guardCloseBeforeExit(notes.saveNow);

  // Load the vault in the background so the shell paints immediately and shows
  // its own loading state instead of a blank window.
  unawaited(notes.bootstrap());

  runApp(NrsApp(settings: settings, notes: notes));
}
