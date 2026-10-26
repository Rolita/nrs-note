import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/platform/boot_trace.dart';
import 'core/platform/close_guard.dart';
import 'core/platform/window_setup.dart';
import 'data/storage/canvas_store_factory.dart';
import 'state/canvas_controller.dart';
import 'state/notes_controller.dart';
import 'state/settings_controller.dart';

Future<void> main() async {
  BootTrace.mark('main() entered');
  WidgetsFlutterBinding.ensureInitialized();
  BootTrace.watchFrames();

  // On the web the browser's own right-click menu wins by default, and Flutter
  // then never delivers the right-click to the app — which would leave the
  // editor with no formatting surface at all, since the ribbon is gone.
  // Turning the browser menu off is what makes the editor's menu the only one
  // there, exactly as on the desktop build.
  if (kIsWeb) {
    unawaited(BrowserContextMenu.disableContextMenu());
  }

  final SettingsController settings = await SettingsController.load();
  BootTrace.mark('settings loaded');
  final NotesController notes = NotesController()..sortMode = settings.sort;
  // 上次关窗口时开着的标签和选中的那一页；vault 读完后才兑现。
  notes.restoreSession(
    tabs: settings.sessionTabs,
    selected: settings.sessionSelectedTab,
  );

  // ⏱ 启动时有三件事互不依赖，串着做等于把三份等待相加（实测值，859 篇）：
  //
  //   1. 读盘（`bootstrap`）：160ms 上下；
  //   2. 建窗口（`setupWindow`）：`waitUntilReadyToShow` 要连做十几次原生
  //      窗口调用（去掉系统标题栏、定尺寸、居中、设最小尺寸……），110~220ms；
  //   3. 画第一帧（`runApp`）：建树 + 首次光栅化，60ms 上下。
  //
  // 所以顺序是：先把读盘甩出去 → `runApp` 让引擎开始画 → 最后才做窗口那串
  // 调用。三份等待重叠之后，从 `main()` 到内容就绪从 410ms 降到 160ms。
  //
  // ⛔ 别把 `setupWindow` 放回 `runApp` 前面：那样引擎要等窗口调完才开始画，
  // 白等两百毫秒。也别在显示窗口前等第一帧（`endOfFrame`）——窗口隐藏时
  // 引擎不保证出帧，实测那一等是 500ms 起步。
  final Future<void> booting = notes.bootstrap();

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

  void saveSession() => settings.saveSession(notes.openIds, notes.selectedId);

  // 读盘在窗口准备期间就已经跑起来了（见上面的 `booting`）。标签栏要等
  // 读盘成功后才能保存：加载失败时拿空列表写回去，会把上次的会话抹掉。
  unawaited(
    booting.then((_) {
      BootTrace.mark('bootstrap done');
      // 首屏那几帧画完再决定要不要留记录：慢的时候，光看 Dart 的读盘时间
      // 分不清是建树慢还是光栅化慢。
      Timer(const Duration(milliseconds: 900), BootTrace.flushIfSlow);
      if (notes.error != null) return;
      // 白板清单要等 vault 路径就绪才能读（`init()` 之后），所以挂在读盘
      // 完成之后，不占启动的关键路径。
      unawaited(canvas.refreshCanvases());
      saveSession();
      notes.addListener(saveSession);
    }),
  );

  runApp(NrsApp(settings: settings, notes: notes, canvas: canvas));
  BootTrace.mark('runApp returned');
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => BootTrace.mark('first frame'),
  );

  // 窗口那串原生调用排在 `runApp` 之后：它们只决定「什么时候看得见」，
  // 不决定「看得见什么」。
  await setupWindow();

  // 关闭窗口前把去抖窗口里的最后一次编辑落盘；桌面端拦截关闭事件，
  // 浏览器端为空实现（见 close_guard_web.dart）。标签变化在发生时就已写进
  // 偏好，这里不用再补。
  //
  // 放在 `setupWindow` 之后：它要调 window_manager，而窗口插件是在那里面
  // 初始化的。此时窗口刚显示出来，用户不可能已经点到关闭。
  await guardCloseBeforeExit(() async {
    await notes.saveNow();
    BootTrace.mark('notes saved');
    await canvas.flush();
    BootTrace.mark('canvas flushed');
  });
}
