# 粘贴图片 · 实施任务清单

> 依据 [spec.md](file:///c:/Users/Kotori/Desktop/nrs-v5/spec.md)。
> 按顺序执行；每一步做完都要能运行、能自测，再进入下一步。
> 提交前验证：`flutter analyze lib test`、`flutter test`、perf 测试**单独**运行。

---

## T1. `ImageMarkup` 与插入算法（纯 Dart）

- [x] 新建 `lib/core/utils/image_markup.dart`
  - `ImageMarkup.parseLine(String lineText)`：只认「整行单个图片」；
    支持 `![alt](src)`、`![alt](<src>)`、`![alt](src "title")`、
    `<img src="…" width="…" alt="…">`（属性乱序、单双引号、大小写不敏感）。
  - `ImageMarkup.toMarkdown({double? width})`：无宽度输出 `![alt](src)`；
    有宽度输出固定属性顺序的 `<img src="…" width="N" alt="…">`。
  - `insertImageBlock({required text, required at, required end, required imageLine})`
    → `({String text, int caret})`：前后补 `\n` 使图片独占一段；
    文末追加 `\n`；`caret` 落在图片行下一行行首。
- [x] 新建 `test/image_markup_test.dart`，覆盖 spec §16.1 列出的全部点。
- 验证：`flutter test test/image_markup_test.dart`。
  **进度（2026-10-24）**：T1 完成，26 个用例全部通过。

## T2. 存储层：落盘与路径解析

- [x] `lib/data/storage/note_store.dart`
  - 加 `Future<String?> saveAsset(String folderPath, String fileName, Uint8List bytes)`
    默认返回 null。
  - 加 `String? assetPath(String folderPath, String source)` 默认返回 null。
- [x] `lib/data/storage/note_store_io.dart`
  - 实现 `saveAsset`：建 `assets/`、清洗文件名、`stem.png` → `stem_2.png` 去重、
    `.tmp` + rename 原子写、返回 `assets/<name>`。
  - 实现 `assetPath`：拒绝远程/绝对/`..`/越界，`Uri.decodeComponent` 后复查。
  - `listFolders` 过滤任何名为 `assets` 的目录。
- [x] `lib/state/notes_controller.dart`
  - `Future<String?> saveAsset(Uint8List pngBytes)`（取 `_draft ?? selectedNote`）。
  - `String? assetPathFor(String source)`。
  - 私有 `_imageAssetName(DateTime)` → `image_yyyyMMdd_HHmmss.png`。
- [x] 扩展 `test/note_store_io_test.dart`，新增 `test/note_image_test.dart`。
- 验证：`flutter test test/note_store_io_test.dart test/note_image_test.dart`。
  **进度（2026-10-24）**：T2 完成，29 个用例全部通过；`listFolders` 隐藏 `assets`
  另有专门用例。

## T3. Windows 原生剪贴板通道

- [x] `windows/runner/flutter_window.h`：`RegisterClipboardChannel()` +
      `clipboard_channel_` 成员。
- [x] `windows/runner/flutter_window.cpp`：
  - `RegisterClipboardChannel()`：`nrs/clipboard` / `readImage`；
    `CF_PNG` 优先，其次 `CF_DIBV5`、`CF_DIB`；
    手工解析 DIB（24/32bpp、BI_RGB/BI_BITFIELDS、底向上/顶向下、stride、BGRA→RGBA）；
    4000 万像素上限；所有分支都 `CloseClipboard`；无图返回空。
  - `OnCreate` 在 `RegisterScreenChannel()` 之后调用；
    `OnDestroy` 置空 `clipboard_channel_`。
- [x] 新建 `lib/core/utils/clipboard_image.dart`：`ClipboardImage.readPng()`，
  PNG 直通、RGBA 编码 PNG（`ImmutableBuffer` + `ImageDescriptor.raw`）、异常返回 null。
- [x] 新建 `test/clipboard_image_test.dart`（mock method channel）。
- [ ] **完全退出应用**后手测三种剪贴板来源（截图 / 画图 / 浏览器复制图片）。
- 注：`CMakeLists.txt` 无需改动。
  **进度（2026-10-24）**：T3 代码与 8 个 Dart 用例完成，`flutter analyze lib test`
  无问题。原生手测依赖重启应用，留待 T7 统一验证。

## T4. 粘贴接线

- [x] `lib/core/utils/note_image.dart` + `note_image_io.dart` + `note_image_web.dart`
      条件导出，提供 `ImageProvider? imageProviderFor(String? abs, String source)`。
- [x] `lib/ui/editor/markdown_editor.dart`
  - 构造加 `savePastedImage`、`imageProviderFor`。
  - `_pasteFromClipboard`：文本优先；空文本时走 `_pasteImageFromClipboard()`。
  - `_pasteImageFromClipboard()`：围栏/表格拒绝 → 读图 → 校验 `documentId`
    → 存盘 → `insertImageBlock` → 经既有写值入口提交（一步撤销）→ `onChanged`。
  - 失败/不支持用 `showNotice(..., kind: NoticeKind.error)`；**不加成功提示**。
- [x] `lib/ui/editor/editor_context_menu.dart`
  - `buildEditorMenu` / `pasteIntoEditor` 加 `Future<bool> Function()? onPasteImage`；
    仅「粘贴」行传，纯文本粘贴永不传。
- [x] `lib/ui/editor/editor_pane.dart`
  - 注入 `savePastedImage: notes.saveAsset`、
    `imageProviderFor: (src) => imageProviderFor(notes.assetPathFor(src), src)`。
- [x] 新建 `test/paste_image_test.dart`。
- 阶段验收：图片文件真的落盘；编辑器暂时显示源码行属正常。
  **进度（2026-10-24）**：T4 完成，8 个用例通过（文本优先、纯文本菜单不碰图片、
  围栏/表格拒绝、切换笔记中止、保存异常/不支持提示）。`_EditHistory` 新增
  `breakMerge()`，粘贴固定为独立一步撤销。`flutter analyze lib test` 无问题。

## T5. 图片块渲染

- [x] `lib/ui/editor/live_markdown.dart`：`part 'live_markdown/image_block.dart';`
- [x] `lib/ui/editor/line_layout/line_block_view.dart`：
  `ImageResizeHandle`、`ImageBlockChrome`。
- [x] 新建 `lib/ui/editor/live_markdown/image_block.dart`：
  - `LiveImageBlocks`（缓存按行首偏移、`setPreviewWidth`、`dispose`）。
  - `blockFor`：paragraph + 整行单图 + 选区不命中本行，否则 null。
  - `ImageLineBlock`：尺寸规则（§10.3）、加载/失败占位、`paint`、
    `offsetAt` / `caretRectAt` / `highlightRects`、实现 `ImageBlockChrome`。
  - 解码完成 → `onLineInvalidated(lineStart)`（延后一帧，避免布局期 setState）。
- [x] `lib/ui/editor/line_layout/render_line_editable.dart`
  - `invalidateImageLine(int sourceStart)`：加入 `_pendingRevealDirty` + `markNeedsLayout`。
  - `imageBlocks()`：仿 `tableRows()` 的缓存与 `chromeOrigin` 写法，仅视口内。
  - `_adoptPooledLayout` 中与表格行一起重建图片行。
- [x] `lib/ui/editor/markdown_editor.dart`
  - `_LineBlockResolver`（tables → images），作为 State 字段稳定持有，
    仅 palette/documentId 变化时重建并 dispose 旧实例。
  - `lineBlockFor: _lineBlocks.blockFor`（替换原 `tableBlocks.blockFor`）。
  - `_invalidateImageLine` 转发到 `_editable()?.invalidateImageLine`。
- [x] 扩展 `test/live_editor_widget_test.dart`（像素探针：图片显示、下方文字下移、
      光标进入退回源码）；新建 `test/image_block_test.dart`。
- 验证：`flutter test test/image_block_test.dart test/live_editor_widget_test.dart`。
  **进度（2026-10-24）**：T5 完成。新增 `test/image_block_test.dart` 12 个用例
  （整行单图判定、排除列表/标题/引用/代码、选区边界揭示、自然尺寸与 640 软上限、
  显式宽度夹取且不受高度上限约束、预览宽度、失败占位、解码/失败只重排本行、
  手柄几何、光标与选区、块复用）；`test/live_editor_widget_test.dart` 增 5 个
  用例（块渲染并挤动下方文字、光标进入退回源码、失败占位、解码完成只重排本行、
  像素探针），该文件 78 个用例全过。实施中发现并修复：`_scheduleInvalidate`
  只挂 `addPostFrameCallback` 不会请求新帧，空闲时解码完成可能一直停在占位，
  已补 `WidgetsBinding.instance.ensureVisualUpdate()`。`flutter analyze lib test`
  无问题。

## T6. 拖拽改宽

- [x] `markdown_editor.dart` 指针层：
  - 悬停命中手柄 → `SystemMouseCursors.resizeUpLeftDownRight`。
  - 按下优先判定手柄，命中则吞手势（不进选区拖动、不丢焦点）。
  - 拖动：`_imageBlocks.setPreviewWidth(...)` + `invalidateImageLine(...)`，
    clamp 96–`contentWidth`，**不写 controller**。
  - 松手：整行一次替换为 `toMarkdown(width: w.round())`，选区按 delta 平移，
    清预览，`onChanged`。
  - Esc / `onPanCancel`：清预览、重排、不写。
- [x] 新建 `test/image_resize_test.dart`。
- 验收：拖动实时重排、松手持久化、Ctrl+Z 一次回退。
  **进度（2026-10-24）**：T6 完成。`_imageResize` 记录按下时的行首、起始宽度、
  指针 x 与列宽上限；`_imageHandleAt` 走渲染对象的 `imageBlocks()` 命中 14×14
  手柄，悬停与按下共用它，`_ChromeShield` 同时拦下手柄上的按压，输入框的选区
  手势收不到。拖动只 `setPreviewWidth` + `invalidateImageLine`，不动 controller；
  松手 `_finishImageResize` 清预览后用 `breakMerge()` 断开合并，把整行按
  `ImageMarkup.parseLine(...).toMarkdown(width:)` 一次替换，选区按长度差平移，
  一次 `onChanged`。Esc 与 pointer cancel 都丢掉预览。新增
  `test/image_resize_test.dart` 6 个用例（悬停光标、预览期零写入/零 onChanged、
  下方行 painter 不变、一次写入、Ctrl+Z 一步回退、96/720 夹取、Esc 取消、失败
  图片仍可改宽），全过；`image_block_test`、`live_editor_widget_test`、
  `table_chrome_test`、`paste_image_test` 共 129 个用例全过；
  `flutter analyze lib test` 无问题。撤销后 `_historyCaretOffset` 会把光标落在
  图片行行尾（揭示源码），测试已按这一既有行为断言。

## T7. 回归与性能

- [x] `flutter analyze lib test`（无问题）。
- [x] `flutter test --exclude-tags perf`（全量 1075 个用例全绿）。
- [x] `flutter test --tags perf test/live_markdown_perf_test.dart`（单独跑，6 个基准全过；
      本机满载时曾有两个既有基准超 1000ms 阈值，空载重跑恢复，属环境噪声）。
- [x] 在 `test/live_markdown_perf_test.dart` 增加 1000 行 + 20 图的打字基线：
      `one-character edits in a 1000-line document with 20 images`，
      本机实测 334.58 ms/build（阈值 <1000ms，与同文件其他基准一致）。
- [ ] 手测清单（spec §16.4）全部过一遍；原生改动后**完全重启**再测。
      **待用户执行**：需完全退出并重启应用（§16.4 第 6 条），包含截图 / 画图 /
      浏览器复制、纯文本与文件复制原行为、真实落盘 `assets/image_*.png`、
      重启后宽度持久化等 §17 DoD 手工项。
- [x] 对照 spec §14 确认没有"顺手修复"超出范围的行为：
      T6/T7 只动 `markdown_editor.dart` 指针层（§12 范围内）、新增/扩展测试与文档；
      唯一无关改动是 `test/table_chrome_paint_test.dart` 删掉两个未使用的 import
      （analyze 门槛要求的纯清理，无行为变化）。
