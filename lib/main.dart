import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/platform/close_guard.dart';
import 'core/platform/window_setup.dart';
import 'data/storage/canvas_store_factory.dart';
import 'state/canvas_controller.dart';
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
  // 白板自己一份状态：它不参与笔记的任何索引。
  final CanvasController canvas = CanvasController(
    vaultPathOf: () => notes.vaultPath,
  );
  // 删文件夹时白板会把它挡住（白板不进回收站，不能跟着删），至少要把名字
  // 说清楚，别让用户对着「还有不是笔记的文件」发呆。
  notes.canvasCountOf = (String folder) async {
    final List<CanvasRef> boards = await canvas.list();
    return boards
        .where(
          (CanvasRef board) => board.relativePath.startsWith('$folder/'),
        )
        .length;
  };
  // 上次关窗口时开着的标签和选中的那一页；vault 读完后才兑现。
  notes.restoreSession(
    tabs: settings.sessionTabs,
    selected: settings.sessionSelectedTab,
  );

  void saveSession() => settings.saveSession(notes.openIds, notes.selectedId);

  // 关闭窗口前把去抖窗口里的最后一次编辑落盘；桌面端拦截关闭事件，
  // 浏览器端为空实现（见 close_guard_web.dart）。标签变化在发生时就已写进
  // 偏好，这里不用再补。
  await guardCloseBeforeExit(() async {
    await notes.saveNow();
    await canvas.flush();
  });

  // Load the vault in the background so the shell paints immediately and shows
  // its own loading state instead of a blank window. 标签栏要等读盘成功后才
  // 能保存：加载失败时拿空列表写回去，会把上次的会话抹掉。
  unawaited(
    notes.bootstrap().then((_) {
      if (notes.error != null) return;
      saveSession();
      notes.addListener(saveSession);
    }),
  );

  runApp(NrsApp(settings: settings, notes: notes, canvas: canvas));
}
