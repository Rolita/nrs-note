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

## T8. 拖动整块搬家（原「第二阶段」，已提前实现）

- [x] `lib/core/utils/image_markup.dart`
  - 新增纯逻辑 `moveSourceLine({text, lineStart, lineEnd, insertAt})`：
    整行（连着自己的换行；文末那行改吃上一行的）搬到落点，返回新全文、
    新光标与位移差；落点在自己身上 / 越界一律返回 `null`。
- [x] `lib/ui/editor/line_layout/render_line_editable.dart`
  - 新增 `dropTargetAt(Offset globalPosition)`：把指针 y 吸附到最近的行边界
    （上半 → 这一行之前，下半 → 之后；超出正文 → 最后一行之后），
    返回插入线矩形（全局坐标）与文档偏移。
- [x] `lib/ui/editor/markdown_editor.dart`
  - `_ImageMove`（`lineStart` / `origin` / `active` / `target` / `dropLine`），
    按在图片本体上先记候选，走过 `kTouchSlop` 才 `active`（否则松手仍是点选）。
  - `_dragImageMove`：只更新插入线，**不写 controller**；
    `_finishImageMove`：一次 `moveSourceLine` 落成 + `breakMerge()` + `_selectImage`；
    `_cancelImageMove`：Esc / 指针取消丢掉插入线。
  - `_ImageDropLine`：1px `accent` 圆角实线，`IgnorePointer` 包住不抢命中。
- [x] 测试
  - `test/image_markup_test.dart`：`group('moveSourceLine')` 6 条
    （往下 / 往上 / 搬到文末 / 落在自己身上返回 null / 越界 / 搬完仍是整行）。
  - `test/image_resize_test.dart`：3 条 widget 用例
    （拖到正文下方整行跟着走且只写一次、拖动途中文档不动且 Esc 作废、
    拖回原处等于没拖）。
- 验证：`flutter analyze` 无问题；`flutter test --exclude-tags perf` **1156 个用例全绿**。

## T9. 任意移动：贴边浮动 + 右上角「移动」按钮

- [x] `lib/core/utils/image_markup.dart`
  - 新增 `enum ImageAlign { left, right }` 与 `ImageMarkup.align`；
    `toMarkdown` 在 `width` 之后写 `align="…"`，有 align 时强制标签形式
    （`![…](…)` 放不下属性）；`parseLine` 认大小写/单双引号，认不出的值当没写。
- [x] `lib/ui/editor/line_layout/line_block_view.dart`
  - `ImageBlockChrome` 增加 `chromeAlign` / `chromeFloatWidth`。
- [x] `lib/ui/editor/line_layout/line_layout_engine.dart`
  - `layoutLines` 维护一段 `_FloatRun`：浮动图片那一行高度算 0，后面几行按
    `extraInsets` 让出一侧宽度，越过图片底部即恢复；整篇高度取
    `max(行累积高度, 浮动底部)`。
  - `_measureOneLine` 新增 `extraInsets`（与 `insetFor` 的卡片内边距相加）。
  - `LineDocumentLayout.hasFloats`；`relayoutLines` / `relayoutOnEdit` 遇到
    浮动（或文本里出现 `align`）一律交回全量重排。
  - `lineRangeBetween` 往回捞一把零高的浮动行：滚到图片中间时不能整张消失。
- [x] `lib/ui/editor/line_layout/render_line_editable.dart`
  - `_paintBlocks` 不再跳过零高的浮动图片行；`imageBlocks()` 按块自身高度判可见。
- [x] `lib/ui/editor/live_markdown/image_block.dart`
  - `chromeAlign`（改源码时不浮动）、`chromeFloatWidth`（宽 + 18px 间距）、
    `_floatDx`（贴右时整块右移）；浮动宽度上限取正文列 62%。
- [x] `lib/ui/editor/markdown_editor.dart`
  - `_ImageMove` 增加 `fromHandle` / `align` / `ghost` / `size`；
    `_dragImageMove` 同时算行边界与左/中/右三档对齐；`_finishImageMove` 把
    「搬家」与「改对齐」合成**一次**写入。
  - `_beginImageMoveFromHandle` + `_ImageDragButton`（`Listener`，按下即搬）。
  - `_ImageActions` 三颗按钮；`_kImageActionsEditWidth`。
  - `_ImageDropGhost` 落位预览；指针压在自己图上算「原地」（可改贴边）。
- [x] 测试
  - `image_markup_test`：`group('靠边浮动')` 3 条（属性顺序 / 解析容错 / 回读）。
  - `line_layout_test`：`group('靠边浮动')` 4 条（高度 0 与绕排范围 / 左浮动 /
    文末撑高 / 无对齐照旧独占一行）。
  - `image_resize_test`：拖到左、右三分之一各一条，拖回中间取消浮动，
    悬停出「移动」按钮并按住拖成右浮动。
- 验证：`flutter analyze lib test` 无问题；`flutter test --exclude-tags perf`
  **1167 个用例全绿**。



## T10. 改源码改成浮窗，不再动版面

- [x] `lib/ui/editor/live_markdown/image_block.dart`
  - `showSource` 不再改 `_height` / `_width` / `_imageTop`：行高恒等于图片高，
    图片永不被顶下去。只算出浮窗的 `_sourceWidth` / `_sourceHeight`。
  - `chromeAlign` / `chromeFloatWidth` 不再因为「正在编辑」而变——浮动图片改源码
    时照样贴边，旁边的正文照样绕排。
  - `chromeSourceBounds()`：图片左上角内侧 12px，宽度夹在正文列里。
  - `paint`：编辑时把整张图压暗 20%。
- [x] `lib/ui/editor/markdown_editor.dart`
  - `_ImageSourceLine` 从「纸色一条」改成浮窗：`surfaceRaised` + 描边 + 阴影 + 圆角。
- [x] 测试
  - `image_block_test`：「要改源码时只是浮出一块窗，行高与图片都不动」。
  - `image_resize_test`：点开「编辑这个区块」版面一个像素都不动（图片矩形、整篇
    高度、下一行 top 全等）；浮动图片点开后贴边与绕排不变；关掉之后图片还在原处。
- 验证：`flutter analyze lib test` 无问题；`flutter test --exclude-tags perf`
  **1168 个用例全绿**。


## T11. 从网页拖进来：区分图片与超链接

- [x] `lib/core/utils/dropped_link.dart`
  - 新增 `DroppedImage { url, alt }`、`parseDroppedImage(...)`、`markdownImageFor(...)`。
  - HTML 里找 `<img>`：候选地址按 `src` → `data-src` → `data-original` → `srcset`
    逐个解析，第一个解得出的才算数（懒加载站点的 `src` 常常是 `data:` 占位图）。
  - 相对 `src` 按这次拖放的系统 URL 补全；`data:` / `blob:` / `file://` 不算网页图片。
  - HTML 里没有 `<img>` 时看地址本身：扩展名（`.png/.jpg/.webp/…`）或图床的
    `?format=webp`；但同一地址在 HTML 里是个锚点时判回**链接**。
  - `alt` 走既有的 `_cleanTitle`：像地址就不当标题。
  - 属性正则用 `(?:^|\s)` 而不是 `\b`：`\bsrc` 会把 `data-src` 一起匹配上。
- [x] `lib/ui/editor/markdown_editor.dart`
  - `_readDropped` 返回值扩成 `(image, link, text)`，`_onDrop` 里**图片先判**。
  - 图片走 `insertImageBlock` 单独成段；落点在表格行/代码围栏里时拒绝并提示
    「表格或代码块里不能插入图片」；`_history.breakMerge()` 保证一步撤销。
  - 调试日志多打一行 `NRS drop: image=…`。
- [x] 测试：新增 `test/dropped_image_test.dart` 16 个用例（认图 9、不认成图 5、
  互不抢 2）；`dropped_link_test` 17 + `dropped_text_test` 14 全过。
- 验证：`flutter analyze lib test` 无问题。


## T12. 指针停在图片上时滚轮要能滚

- [x] `lib/ui/editor/markdown_editor.dart`
  - 根因：`_RenderChromeShield.hitTest` 命中图片/抓手就 `return true` 且不再往下问，
    `SingleChildScrollView` 整棵子树被剪掉；`PointerSignalEvent` 只发给命中链上的
    监听者，滚轮到不了 `Scrollable`。
  - 编辑器外层 `Listener` 加 `onPointerSignal: _onPointerSignal`：
    注册到 `pointerSignalResolver`（不是直接滚），增量 `scrollDelta.dy` 交给
    `ScrollPosition.pointerScroll`。正常落在文字上时 `Scrollable` 更深、先注册，
    我们被忽略——不会滚两下。
  - 覆盖：图片本体、改宽手柄、表格抓手与分隔线、折叠箭头（都是被盾牌挡住的那批）。
- [x] 测试：新增 `test/image_scroll_test.dart` 2 条（图上滚得动 / 图上与字上滚一样远）。
  去掉修复后两条都失败（offset 恒 `0.0`，正文上 `120.0`），加上后全过。
- 验证：`image_scroll` + `scroll_behavior` + `table_chrome` + `image_resize` 共 72 条全过；
  `flutter analyze lib test` 无问题。


## T13. 图片右侧边栏

- [x] `lib/core/utils/note_images.dart`（新增）
  - `NoteImage{offset, line, markup}` + `extractImages(body)`：逐行
    `ImageMarkup.parseLine` 判定，和渲染层同一个函数。
  - `label`：alt 优先，否则文件名（远程地址带查询串时截到问号）。
- [x] `lib/ui/editor/image_panel.dart`（新增）
  - 表头「图片 + 张数」；44px 缩略图（加载中/失败都落占位，行高不跳）；
    两行说明 `第 N 行 · 原尺寸|宽 X [· 网络]`；点一行 `onSelect(offset)`。
  - 空态一句话，不留白板。
- [x] `lib/state/settings_controller.dart`
  - `imagePanelVisible` / `imagePanelWidth`；三个面板开关在**设置层互斥**：
    开一个同时关掉另外两个（同一批写入）。
- [x] `lib/ui/shell/app_shell.dart`
  - `showImages` + `_ImageRegion`（按 note id + 正文对象身份缓存，正文没换不重扫，
    和 `_OutlineRegion` 同一条规矩）、拖拽改宽、`rightInset` 三选一。
- [x] `lib/ui/shell/title_bar_content.dart`
  - 第三颗「图片」开关；三颗按钮 32 → 28px、缝 2px（三个 32 + 两道 4px = 104，
    大纲栏最窄时「面板左缘 → 窗口按钮」只有 100，差 4px 就会偏出面板）。
- [x] 测试：`note_images_test` 10 条、`image_panel_test` 4 条、
  `settings_controller_test` +3 条、`shell_layout_test` +1 条（互斥 + 列出图片）。
- 验证：`flutter analyze lib test` 无问题；全量 `--exclude-tags perf` 全绿。
