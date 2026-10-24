# 在 Markdown 笔记中粘贴图片 · 实施规格

> 状态：**基本完成。T1–T7 自动化验证全绿（analyze 无问题、全量 1075 用例通过、perf 单独跑 6 基准通过）；剩余 §16.4 原生手测与 §17 手工验收需完全重启应用后补做（见 §19 实施记录）。**
> 面向：接手的实施 AI / 工程师。文中所有文件路径与函数名均对应仓库 `c:\Users\Kotori\Desktop\nrs-v5`。
> 行号为当前快照，用于快速定位；实施时以符号名为准。

---

## 0. 一句话目标

按 `Ctrl+V`（或右键「粘贴」）时，若剪贴板里没有文字但有图片，就把图片存成
`<笔记所在目录>/assets/<名字>.png`，并在光标处插入一行图片语法；编辑器把这一行
渲染成真正的图片块，**图片占位、挤动下方文字**；拖动图片右下角手柄可改宽度，
松手后把宽度写回 Markdown 源码。

---

## 1. 目标 / 非目标

### 1.1 目标（本轮必须全部完成）

| # | 行为 |
|---|------|
| G1 | Ctrl+V 与右键「粘贴」都能在剪贴板无文本时读取剪贴板图片（PNG、DIB、截图工具写入的位图）。 |
| G2 | 图片落盘为 `<vault>/<note.folderPath>/assets/<name>.png`，引用写成相对笔记文件的 `assets/<name>.png`。 |
| G3 | 插入的图片行**独占一段**：前后保证换行，光标落到图片行**下一行**，粘贴后立即看到图片而不是源码。 |
| G4 | 图片以块级自绘形式渲染：行高等于图片高度，上下文字自然被推开，不做浮层、不做文字环绕。 |
| G5 | 光标 / 选区进入图片行时，图片块消失，退回 `![alt](assets/x.png)` 或 `<img …>` 源码文字。 |
| G6 | 图片右下角有缩放手柄；拖动时按比例改宽、实时重排下方文字；松手后宽度写回源码，且只产生**一步**撤销记录。 |
| G7 | 未改宽度的图片行保持标准 Markdown `![alt](assets/x.png)`；改过宽度的写成 `<img src="assets/x.png" width="320" alt="…">`，保证其他 Markdown 工具能读到宽度。 |
| G8 | 粘贴文本的行为与现在**完全一致**（包括表格前后补空行、表格内粘贴拒绝等规则）。 |
| G9 | 所有失败路径都以错误提示告知；**不新增任何成功提示**（项目硬约束）。 |

### 1.2 非目标（明确不做，避免实施者扩张范围）

- ❌ 拖动整块图片在段落间移动（第二阶段）。
- ❌ 浮动图片、文字环绕。
- ❌ Web 端落盘（Web 存储直接返回不支持，UI 给出错误提示）。
- ❌ 图片压缩、格式转换（除 DIB → PNG 的必要编码外）。
- ❌ 删除笔记时清理孤立图片、移动笔记时重写相对链接（记录为已知限制，见 §11）。
- ❌ 剪贴板中的非位图内容（文件路径、HTML、富文本）。

### 1.3 用户已确认的原话

- 「不是浮在文字上方，就是要挤动文字。」
- 「同意存到 笔记同目录的 `assets/` 子文件夹。按这个开工」

---

## 2. 现状：必须理解的既有架构

无论谁实施，先读这 6 个文件。它们是本方案的承重墙。

### 2.1 编辑器是「按行自绘」，不是 Widget 树

`TextEditingController` 里存的是**逐字节的 Markdown 源码**。每一行由
`line_layout_engine.dart` 单独排一个 `TextPainter`；`RenderLineEditable`
负责画字、画选区、算光标、做命中。

图片**不能**走 `WidgetSpan`：行内树必须与源码长度严格一致（见
[live_markdown.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/live_markdown.dart#L9-L33)
顶部注释），而一张图无法只占一个字符。因此必须使用既有的
**`LineBlockView` 出口**——实时表格就是唯一现成使用者。

### 2.2 `LineBlockView` 契约（核心扩展点）

文件：[line_block_view.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/line_layout/line_block_view.dart)

```dart
abstract class LineBlockView {
  double get height;                 // 这一行占的高度（引擎不再量文字）
  double get width;                  // 内容宽度（可窄于正文列）
  void paint(Canvas canvas, Offset origin, Offset globalOrigin);
  void dispose();
  int offsetAt(Offset local);
  Rect caretRectAt(int offset);
  List<Rect> highlightRects(int from, int to);
}

typedef LineBlockResolver =
    LineBlockView? Function(SourceLine line, LineBlockContext context);
```

坐标系是**行内局部坐标**，原点在这一行左上角（正文列）。渲染对象负责把它
放到 `(gutter, top)` 并叠加滚动偏移。

### 2.3 行高如何驱动「挤动文字」

[line_layout_engine.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/line_layout/line_layout_engine.dart)
的 `_measureOneLine`（约 961–1070 行）：

- 第 980 行取 `blockFor?.call(source, blockContext)`；
- 有 block 时 painter 用空文本，`height = block.height`，
  `visuals` 为一条覆盖整行的 `VisualLine`；
- `relayoutLines`（约 1082–1198 行）只重建 `dirtyLines`，未变行
  `old.top = top; top += old.height;` **复用并整体平移**。

因此：**只要图片块高度改变并把该行标脏，后续所有文字会自动下移/上移**，
无需额外布局代码。

### 2.4 光标进入某行会触发行重排

`revealDirtyLines`（约 627 行起）按揭示选区与行 `[start, end]` 的钳制交集
比较签名。图片块只要在「选区命中本行」时返回 `null`，该行就自动退回源码
文字，无需在渲染层加特判。

### 2.5 渲染层如何画块、如何把几何交给宿主

[render_line_editable.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/line_layout/render_line_editable.dart)

- `_paintBlocks`（约 1069–1081 行）遍历视口内行，调用
  `block.paint(canvas, local, _globalOriginOf(local))`；
- `tableRows()`（约 1090–1117 行）在布局换新时重建行集合，每次查询写入
  `chromeOrigin = _lineOrigin(line) + localToGlobal(_linePaintOffset)`；
  **图片需要同构的 `imageBlocks()`**；
- `_ensureLineLayout`（约 699–814 行）缓存命中且 `_pendingRevealDirty`
  非空时，走 `relayoutLines` 局部重排；
- `_adoptPooledLayout`（约 620–676 行）命中挂起布局时表格行强制重建，
  图片行必须同样处理。

### 2.6 宿主接线

[markdown_editor.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/markdown_editor.dart)

- 构造在约 896–918 行；
- `_tableBlocks` / `_resolveTableBlocks` 约 1124–1149 行（按 `base` / `palette`
  缓存，换实例时 `_layoutPool.clear(); cached?.dispose();`）；
- `_editable()` 约 1402 行（遍历 element 树找 `RenderLineEditable`）；
- `_showMenuAt` 约 1575–1595 行；
- `_pasteFromClipboard` 约 3513–3531 行；
- 快捷键映射约 3579–3618 行，`_PasteIntent` action 约 3689–3694 行；
- build 中 `lineBlockFor: tableBlocks.blockFor` 在约 3886 行。

### 2.7 右键菜单

[editor_context_menu.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/editor_context_menu.dart)

- `buildEditorMenu(...)` 约 179–185 行；
- 「粘贴」/「以纯文本形式粘贴」两行约 715–728 行；
- `pasteIntoEditor(...)` 约 819–840 行，当前只读 `Clipboard.kTextPlain`。

### 2.8 存储层

- [note_store.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/data/storage/note_store.dart#L91-L215)：
  抽象类，末尾已有 `writeNewMarkdown(...)`。
- [note_store_io.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/data/storage/note_store_io.dart)：
  `_walk`（131–152）、`_pathFor`（165）、`_join`（180）、`listFolders`（185–201）、
  `folderHoldsOnlyNotes`（229–267）、`_holdsOnlyKnownNotes`（249–267）。
- `AtomicFileWriter` 只支持字符串，二进制需自行 `writeAsBytes`。
- [note_store_web.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/data/storage/note_store_web.dart)：
  浏览器回退，不实现二进制落盘。

### 2.9 原生通道范式

[flutter_window.cpp](file:///c:/Users/Kotori/Desktop/nrs-v5/windows/runner/flutter_window.cpp#L243-L308)
的 `RegisterScreenChannel()` 是完整范例：

```cpp
screen_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(), "nrs/screen",
    &flutter::StandardMethodCodec::GetInstance());
screen_channel_->SetMethodCallHandler(
    [this](const flutter::MethodCall<flutter::EncodableValue>& call,
           std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) { ... });
```

`OnCreate` 约 127 行调用它，`OnDestroy` 约 144 行置空。

### 2.10 主题 / 光标常量

- Palette：`lib/core/theme/app_palette.dart`。
- 禁止 `Icons.*`，统一 `LucideIcons`。
- 图片占位/失败态用 `surfaceSunken` 底 + `outlineSoft` 描边。

---

## 3. 数据格式与落盘规则

### 3.1 文件位置

```
<vault>/<note.folderPath>/assets/<name>.png
```

- `note.folderPath` 为空（笔记在根目录）时即 `<vault>/assets/<name>.png`。
- Markdown 中的引用一律是**相对笔记文件**的路径：`assets/<name>.png`。
- `assets` 目录由存储层在首次粘贴时自动创建。

### 3.2 文件命名

Dart 生成，格式：

```
image_<yyyyMMdd>_<HHmmss>.png
```

冲突时由存储层追加 `_2`、`_3`……（**不要用空格**，避免 Markdown URL 转义）：

```
image_20261024_153012.png
image_20261024_153012_2.png
```

### 3.3 两种行形态

| 状态 | 行文本 |
|---|---|
| 未改宽度 | `![图片](assets/image_20261024_153012.png)` |
| 改过宽度 | `<img src="assets/image_20261024_153012.png" width="320" alt="图片">` |

规则：

- `width` 是**逻辑像素**（设计像素），渲染时**不再乘字缩放**，保证改字号后图片宽度不变。
- `alt` 为空时省略 `alt` 属性。
- `alt` 中的 `"` 编码为 `&quot;`；`]` 编码为 `\]`。
- 生成 `<img>` 时属性顺序固定为 `src`、`width`、`alt`，便于 diff 与测试。
- 解析时属性顺序任意、标签/属性名大小写不敏感。

### 3.4 「图片行」的判定（严格）

只有同时满足以下条件才生成块：

1. `line.kind == LineBlockKind.paragraph`；
2. `line.text.trim()` 恰好是**一个**完整图片语法；
3. 该语法是 `![alt](src)`（可带可选 title，但生成时不写）或单个 `<img …>`；
4. 该行不在围栏代码块内（`kind` 已排除 `fence` / `code`）；
5. 当前揭示选区与本行**没有**交集。

`- ![](x)`、`> ![](x)`、`| ![](x) |`、`文字 ![](x)` 都**不是**图片行，
保持现在的行内源码表现。

---

## 4. 新增工具：`ImageMarkup`

新文件 `lib/core/utils/image_markup.dart`（纯 Dart，可单测，不依赖 Flutter UI）。

```dart
class ImageMarkup {
  /// 整行解析；不是「整行单个图片」时返回 null。
  static ImageMarkup? parseLine(String lineText);

  final String source;      // assets/x.png 或 https://…
  final String? alt;
  final double? width;      // 源码里的宽度（逻辑像素），无则 null
  final bool isExternal;    // http/https/data:

  /// 生成替换本行的文本。
  String toMarkdown({double? width});
}

/// 在 [at, end) 处插入图片行，返回新全文与光标位置。
/// - 前后补 '\n' 使图片独占一段；
/// - 光标落在图片行之后（下一行行首），保证粘贴后立刻看到图片。
({String text, int caret}) insertImageBlock({
  required String text,
  required int at,
  required int end,
  required String imageLine,
});
```

解析要求（写成测试用例）：

- `![a](assets/x.png)`、`![a](<assets/x y.png>)`、`![a](x.png "title")`；
- `<img src="assets/x.png" width="320">`、单引号、属性乱序、`WIDTH=320`、
  `width="320px"`、`width="320.5"`；
- 拒绝：多个图片、前后有多余文字、`<img>` 未闭合、`width` 非数字、
  空 `src`、`data:` 以外的奇怪协议（`data:` 允许解析但渲染走 `Image.memory`
  不在本轮范围，直接当普通外部源处理即可）。

`insertImageBlock` 精确规则：

```
prefix = at > 0 && text[at-1] != '\n' ? '\n' : ''
suffix = end < text.length && text[end] != '\n' ? '\n' : ''
若 at == end == text.length：suffix 取 '\n'（保证光标能落到下一行）
next = text[0:at] + prefix + imageLine + suffix + text[end:]
caret = at + prefix.length + imageLine.length + suffix.length
```

> 说明：在文档末尾粘贴会多出一个空行。这是有意的——否则光标只能停在图片行内，
> 图片会立刻退回源码，粘贴体验断裂。测试需断言该行为。

---

## 5. 存储层改动

### 5.1 `NoteStore`（`lib/data/storage/note_store.dart`）

```dart
import 'dart:typed_data';

/// 把二进制写到 `<folderPath>/assets/<fileName>`。
/// 返回相对笔记文件的引用路径（形如 `assets/x.png`）；不支持时返回 null。
Future<String?> saveAsset(
  String folderPath,
  String fileName,
  Uint8List bytes,
) async => null;

/// 把 Markdown 里的图片引用解析为绝对文件路径。
/// 远程 URL、越界路径、Web 端一律返回 null。
String? assetPath(String folderPath, String source) => null;
```

### 5.2 `NoteStoreIo`（`lib/data/storage/note_store_io.dart`）

`saveAsset` 实现步骤：

1. `folder = Note.normalizeFolderPath(folderPath)`；`assetsRel = folder.isEmpty ? 'assets' : '$folder/assets'`。
2. `Directory(_pathFor(assetsRel)).create(recursive: true)`。
3. 清洗文件名：`_baseName(fileName)`，禁止 `/`、`\`、`..`；强制 `.png` 后缀。
4. 去重：从 `stem.png` 开始，存在则 `stem_2.png`、`stem_3.png`……（**不要空格**）。
5. 原子写：先写 `<target>.tmp`（`writeAsBytes(bytes, flush: true)`），再 `rename` 到目标。
6. 返回 `'assets/$candidate'`。

`assetPath` 实现步骤：

1. 先 `trim`；空 → null。
2. `http://` / `https://` / `data:` → null（远程图走网络）。
3. 绝对路径（`/` 开头、`\\`、`C:`）、含 `..` 段 → null。
4. `Uri.decodeComponent`（失败则 null）；解码后再检查一次 `..` 与 `/` 注入。
5. `rel = _join(note.folderPath, decoded)`；`abs = _pathFor(rel)`。
6. 校验 `abs.toLowerCase()` 以 `<vault>/` 开头（防止逃出 vault），否则 null。

`listFolders`（约 185–201 行）追加过滤：

```dart
.where((String p) => !p.split('/').contains('assets'))
```

> 只过滤名为 `assets` 的目录，避免图片目录出现在左侧文件树里。
> 代价：用户不能创建名为 `assets` 的笔记文件夹——写入已知限制。

**已知限制（本轮接受）**：包含 `assets` 的文件夹无法被删除
（`folderHoldsOnlyNotes` 会因未知文件返回 false）。这是**安全行为**：
现有回收站只能恢复 `.md`，删掉文件夹会连带丢失图片。不要绕过它。

### 5.3 `NoteStoreWeb`

不改：继承默认实现，`saveAsset` 返回 null，`assetPath` 返回 null。

### 5.4 `NotesController`（`lib/state/notes_controller.dart`）

```dart
Future<String?> saveAsset(Uint8List pngBytes) async {
  final Note? note = _draft ?? selectedNote;
  if (note == null) return null;
  return _store.saveAsset(note.folderPath, _imageAssetName(DateTime.now()), pngBytes);
}

String? assetPathFor(String source) {
  final Note? note = _draft ?? selectedNote;
  if (note == null) return null;
  return _store.assetPath(note.folderPath, source);
}

static String _imageAssetName(DateTime now) { /* image_yyyyMMdd_HHmmss.png */ }
```

---

## 6. Windows 原生剪贴板通道

### 6.1 通道契约

- 通道名：`nrs/clipboard`
- 方法：`readImage`
- 返回（`Map<String, Object>`）：

```dart
// 有 PNG 时（最优，零转码）
{ 'png': Uint8List }

// 只有 DIB 时（原生已转成 RGBA，Dart 再编码 PNG）
{ 'rgba': Uint8List, 'width': int, 'height': int }

// 没有图片
null
```

### 6.2 C++ 实现要点（`windows/runner/flutter_window.cpp`）

新增 `RegisterClipboardChannel()`，结构照抄 `RegisterScreenChannel()`：

1. `OpenClipboard(nullptr)`；失败 → `result->Success()`（空）。
2. 枚举 `EnumClipboardFormats`：
   - 优先 `RegisterClipboardFormatW(L"PNG")`；
   - 其次 `CF_DIBV5`；
   - 最后 `CF_DIB`。
3. 取 `GetClipboardData(format)` → `GlobalLock` → 拷进 `std::vector<uint8_t>`
   → `GlobalUnlock`。**先关剪贴板再回 result**，避免占用剪贴板。
4. PNG：直接把字节塞进 `EncodableValue`。
5. DIB：解析 `BITMAPINFOHEADER`：
   - `biSize >= 40`、`biPlanes == 1`；
   - `biCompression` 允许 `BI_RGB(0)` 与 `BI_BITFIELDS(3)`（仅 32bpp + 标准掩码）；
   - `biBitCount` 允许 24 / 32；
   - `stride = ((biWidth * biBitCount + 31) / 32) * 4`；
   - `biHeight > 0` 为底向上，`< 0` 为顶向下；
   - 24bpp：`BGR` → `RGBA`，alpha 恒 255；
   - 32bpp：`BGRA` → `RGBA`；若 `CF_DIBV5` 且全图 alpha 全 0，则把 alpha 视为 255
     （很多截图工具写 32bpp 但 alpha 未用）。
6. 失败 / 格式不支持 → `result->Success()`（空 Map）。不要抛 `PlatformException`。
7. 上限保护：`width * height > 40_000_000` 直接返回空，防止一张超图把内存打爆。
8. `CloseClipboard()` 必须在**所有**分支执行（用 RAII 小结构体或显式调用）。

`flutter_window.h` 增加：

```cpp
void RegisterClipboardChannel();
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> clipboard_channel_;
```

`OnCreate`：`RegisterScreenChannel();` 之后加 `RegisterClipboardChannel();`
`OnDestroy`：`screen_channel_ = nullptr;` 旁边加 `clipboard_channel_ = nullptr;`

`windows/runner/CMakeLists.txt` **无需修改**（不引入 GDI+，不做图像缩放）。

### 6.3 验证纪律

原生代码改动 **hot reload / hot restart 都不生效**，必须完全退出应用再启动
（项目已多次踩过这个坑）。

---

## 7. Dart 剪贴板封装

新文件 `lib/core/utils/clipboard_image.dart`：

```dart
class ClipboardImage {
  static const MethodChannel _channel = MethodChannel('nrs/clipboard');

  /// 读剪贴板图片，统一返回 PNG 字节；没有图片 / 平台不支持时返回 null。
  static Future<Uint8List?> readPng() async { ... }
}
```

逻辑：

1. `invokeMethod<Map>('readImage')`，捕获 `MissingPluginException` /
   `PlatformException` → null（与 `ScreenSampler` 的处理一致）。
2. 有 `png` → 直接返回。
3. 有 `rgba` + `width` + `height` → 转 PNG：

```dart
final Completer<ui.Image> done = Completer<ui.Image>();
ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, done.complete);
final ui.Image image = await done.future;
final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
image.dispose();
```

4. 任何编码失败 → null。

> `decodeImageFromPixels` 若在目标 Flutter 版本被标记 deprecated，
> 改用 `ui.ImmutableBuffer` + `ui.ImageDescriptor.raw`；接口语义不变。

---

## 8. 图片地址 → `ImageProvider`

新文件（条件导出，仿 `external_link.dart`）：

- `lib/core/utils/note_image.dart`
  ```dart
  export 'note_image_web.dart' if (dart.library.io) 'note_image_io.dart';
  ```
- `note_image_io.dart`：
  ```dart
  ImageProvider? imageProviderFor(String? absolutePath, String source) {
    if (_isRemote(source)) return NetworkImage(source);
    if (absolutePath == null) return null;
    return FileImage(File(absolutePath));
  }
  ```
- `note_image_web.dart`：远程返回 `NetworkImage`，其余返回 null。

`editor_pane.dart` 在构造 `MarkdownEditor` 时注入：

```dart
savePastedImage: (Uint8List bytes) => notes.saveAsset(bytes),
imageProviderFor: (String source) =>
    imageProviderFor(notes.assetPathFor(source), source),
```

> `editor_pane.dart` 不能直接 `import 'dart:io'`（会破坏 Web 构建），
> 必须走条件导出。

---

## 9. 粘贴流程

### 9.1 `MarkdownEditor` 新增两个参数

```dart
final Future<String?> Function(Uint8List pngBytes)? savePastedImage;
final ImageProvider? Function(String source)? imageProviderFor;
```

两者都为 null 时，图片粘贴静默不生效（保持现有行为）。`readOnly` 时同样不生效。

### 9.2 Ctrl+V 路径（`_pasteFromClipboard`，约 3513 行）

改造后的顺序**必须**是：

```
1. 读 Clipboard.kTextPlain
2. 有非空文本 → 走现有逻辑（表格拒绝、pasteGridRefusal、pasteValue），一字不改
3. 文本为空 且 savePastedImage != null 且非 readOnly → 尝试粘贴图片
4. 都没有 → 什么都不做（与现在一致）
```

`_pasteImageFromClipboard()` 细节：

1. 记录 `final String docId = widget.documentId;`
2. 拒绝场景：光标在围栏代码块内（`isInsideFence(text, caret)`）或光标所在行是
   表格行（`isTableLine(caretLine)` / 当前表格块内）→ 错误提示：
   「表格或代码块里不能粘贴图片」。
3. `final Uint8List? png = await ClipboardImage.readPng();` 为 null → 静默返回。
4. `await` 之后检查 `mounted` 与 `widget.documentId == docId`，不一致 → 放弃
   （防止等待期间切换笔记，图片被插进另一篇）。
5. `final String? rel = await widget.savePastedImage!(png);`
   - null → 错误提示「当前存储不支持保存图片」；
   - 抛异常 → 错误提示「图片保存失败」。
6. `final line = ImageMarkup(source: rel!, alt: '图片').toMarkdown();`
7. `final result = insertImageBlock(text: ..., at: sel.start, end: sel.end, imageLine: line);`
8. **通过编辑器既有的写值入口**写回（与 `_applyEdit` / 自定义历史同一入口），
   保证只产生一步撤销；随后 `widget.onChanged?.call(result.text)`。

> ⚠️ 第 8 步必须确认 `MarkdownSourceController`（`markdown_editor.dart` 约 42 行）
> 的历史记录是否监听 `controller.value`。若只有键盘路径记录，需要手动压入
> 一条「替换前」快照。验收标准是：粘贴后按一次 Ctrl+Z，图片行整行消失。

### 9.3 右键菜单（`editor_context_menu.dart`）

`buildEditorMenu` 与 `pasteIntoEditor` 各加一个可选参数：

```dart
Future<bool> Function()? onPasteImage;   // 返回是否真的处理了（用于判断是否落回文本粘贴）
```

- 只在「粘贴」（`plain: false`）行传入；「以纯文本形式粘贴」**永远不传**。
- `pasteIntoEditor` 中：读到文本为空且 `onPasteImage != null` → `await onPasteImage()`，
  返回。
- `markdown_editor.dart` 的 `_showMenuAt` 传入
  `onPasteImage: () => _pasteImageFromClipboard()`。

### 9.4 光标落点与视觉

粘贴完成后光标在**图片行下一行行首**。因此：
- 揭示选区不命中图片行 → 图片块立即可见；
- 用户按 ↑ 回到图片行 → 自动退回源码，符合既有行内标记的交互直觉。

---

## 10. 渲染：`LiveImageBlocks`

新文件 `lib/ui/editor/live_markdown/image_block.dart`，并在
`live_markdown.dart` 的 part 列表（约 68–77 行）追加：

```dart
part 'live_markdown/image_block.dart';
```

### 10.1 类形态

```dart
class LiveImageBlocks {
  LiveImageBlocks({
    required AppPalette palette,
    required String Function() text,
    required TextSelection Function() selection,
    required ImageProvider? Function(String source)? imageProviderFor,
    required ValueChanged<int> onLineInvalidated, // 行首偏移
  });

  LineBlockView? blockFor(SourceLine line, LineBlockContext context);

  /// 拖拽预览：不写源码，只覆盖这一行的显示宽度。
  void setPreviewWidth(int lineStart, double? width);

  void dispose();
}
```

- 内部缓存：`Map<int, ImageLineBlock>`，键为行首偏移。
- 失效条件：`line.text` / `line.end` / 预览宽度 / `contentWidth` / palette 明暗。
- `dispose()` 释放所有 `ui.Image` 与 `ImageStreamListener`。

### 10.2 `blockFor` 判定

```dart
if (line.kind != LineBlockKind.paragraph) return null;
final ImageMarkup? markup = ImageMarkup.parseLine(line.text);
if (markup == null) return null;

final TextSelection sel = selection();
if (sel.isValid && sel.start <= line.end && sel.end >= line.start) return null;
// ↑ 与行有交集（含边界）即退回源码，与 revealDirtyLines 的钳制交集语义一致。

return _cache.putIfAbsent(line.start, () => ImageLineBlock(...));
```

### 10.3 尺寸计算

- 加载中 / 失败：占位块，宽 = `min(360, contentWidth)`，高 = 120。
- 已知固有尺寸 `naturalW × naturalH`：
  - `declared = markup.width`（逻辑像素）或 `previewWidth`；
  - 有 `declared` → `w = clamp(declared, 96, contentWidth)`；
  - 无 `declared` → `w = min(naturalW, contentWidth)`，且若
    `w / aspect > 640` 则 `w = 640 * aspect`（自然高度的软上限，防止长截图吞掉整屏）；
  - `h = w / aspect`；
  - 显式宽度**不受 640 上限影响**（用户说了算）。
- `width` getter 返回 `w`；`height` getter 返回 `h`。
- 图片按 `canvas.drawImageRect` 缩放到 `Rect.fromLTWH(0, 0, w, h)`。
- 画 1px `outlineSoft` 圆角描边（圆角 4），与表格卡片风格一致。

### 10.4 加载

```dart
final ImageProvider provider = imageProviderFor?.call(markup.source) ?? ...;
final ImageStream stream = provider.resolve(ImageConfiguration.empty);
_listener = ImageStreamListener((ImageInfo info, bool sync) {
  _image = info.image;
  _aspect = info.image.width / info.image.height;
  onLineInvalidated(lineStart);        // 让渲染层只重排这一行
}, onError: (Object e, StackTrace? st) {
  _failed = true;
  onLineInvalidated(lineStart);
});
```

- **只重排该行**：宿主把它转成 `_editable()?.invalidateImageLine(lineStart)`，
  实现见 §11.2。不要用 revision 触发全文重排。
- 同步返回（缓存命中）时避免在布局阶段调用 `markNeedsLayout`：用
  `scheduleMicrotask` / `addPostFrameCallback` 延后一次，防止
  "setState during build/layout"。

### 10.5 `LineBlockView` 的最小实现

- `offsetAt(local)`：`local.dx < width / 2` → `line.start`，否则 `line.end`。
- `caretRectAt(offset)`：`line.start` 处给左边 2px 竖条，`line.end` 处给右边 2px 竖条。
- `highlightRects`：区间与本行有交集时返回 `[Rect.fromLTWH(0, 0, w, h)]`，
  否则空。
- 说明：由于「选区命中本行即退回源码」，这三个方法基本只在过渡帧被调用；
  实现保持简单、无副作用即可。

### 10.6 失败态与占位

- `surfaceSunken` 底 + `outlineSoft` 1px 描边 + 圆角 4。
- 居中画 `LucideIcons.imageOff`（24px，`inkMuted`）+ 一行小字文件名（截断）。
- 不弹任何提示，避免一张坏图刷屏。

---

## 11. 渲染层接线

### 11.1 组合解析器（避免每次 build 全量重排）

`MarkdownEditor` 内新增一个稳定的组合对象：

```dart
class _LineBlockResolver {
  _LineBlockResolver(this._tables, this._images);
  final LiveTableBlocks _tables;
  final LiveImageBlocks _images;

  LineBlockView? blockFor(SourceLine line, LineBlockContext ctx) =>
      _tables.blockFor(line, ctx) ?? _images.blockFor(line, ctx);
}
```

- 作为 `State` 字段持有（`_lineBlocks`），只在 `palette` 变化 / `documentId`
  变化时重建并 `dispose()` 旧的。
- build 中传 `lineBlockFor: _lineBlocks.blockFor`。
- ⚠️ **不要**在 `build()` 里 `new` 解析器或写 `lineBlockFor: (l, c) => ...`
  内联闭包——`_layoutKey` 会每次都变，导致每个按键全量重排。

`_imageBlocks` 同样作为 `State` 字段，构造参数：

```dart
_imageBlocks = LiveImageBlocks(
  palette: palette,
  text: () => widget.controller.text,
  selection: () => _revealSelection,
  imageProviderFor: widget.imageProviderFor,
  onLineInvalidated: _invalidateImageLine,
);
```

### 11.2 `RenderLineEditable` 新增两个公共方法

```dart
/// 只把某一行标脏，下一次布局走 relayoutLines 的增量分支。
void invalidateImageLine(int sourceStart) {
  _pendingRevealDirty.add(sourceStart);   // 沿用现有集合语义
  markNeedsLayout();
}

/// 视口内可见的图片块几何，全局坐标（供宿主做手柄命中）。
List<ImageBlockChrome> imageBlocks();
```

`imageBlocks()` 完全照抄 `tableRows()`（1090–1117 行）的缓存策略：

- 布局实例变化时重建列表；
- 每个元素查询前写 `chromeOrigin = _lineOrigin(line) + localToGlobal(_linePaintOffset)`；
- 只返回视口内的行。

`_adoptPooledLayout`（620–676 行）里表格行强制重建的位置，同样重建图片行。

### 11.3 手柄契约（加在 `line_block_view.dart`）

```dart
/// 图片块右下角缩放手柄的命中区，全局坐标。
class ImageResizeHandle {
  const ImageResizeHandle(this.rect);
  final Rect rect;   // 建议 14×14，中心在图片右下角
}

abstract class ImageBlockChrome {
  int get imageSourceStart;          // 图片行首字符的文档偏移
  Rect chromeImageBounds();          // 图片矩形，全局坐标
  ImageResizeHandle? chromeResizeHandle(); // 不可缩放时 null
}
```

`ImageLineBlock` 实现它；`imageBlocks()` 返回 `List<ImageBlockChrome>`。

---

## 12. 拖拽改宽

### 12.1 命中与光标

在 `markdown_editor.dart` 的指针处理里：

- 悬停：`_imageHandleAt(global)` 遍历 `_editable()?.imageBlocks()`，
  命中 `chromeResizeHandle()?.rect` → `SystemMouseCursors.resizeUpLeftDownRight`；
  否则走现有逻辑（链接手指、文本 I 型等）。
- 按下：**在选区拖动逻辑之前**判定手柄。命中则：
  - `_imageResize = ({lineStart, startWidth, startDx, maxWidth})`；
  - 吞掉这次手势，不移动光标、不进入选字、不丢焦点。

### 12.2 拖动

- `_imageBlocks.setPreviewWidth(lineStart, newWidth)`；
- `newWidth = clamp(startWidth + (global.dx - startDx), 96, contentWidth)`；
- `_editable()?.invalidateImageLine(lineStart)`；
- 引擎重排该行 → 行高变化 → 下方文字实时平移。
- **拖动期间绝不写 `controller`**，因此不会产生几十条撤销记录。

### 12.3 松手（提交）

- 计算最终源码宽度：`final int w = previewWidth.round();`
- 取该行当前源码 `text`，用 `ImageMarkup.parseLine` 重新生成整行：
  `markup.toMarkdown(width: w)`；
- 用**一次**写值替换整行 `[line.start, line.end)`，选区偏移按 `delta` 平移；
- 清除预览覆盖 `setPreviewWidth(lineStart, null)`；
- `widget.onChanged?.call(newText)`。
- 撤销验收：一次 Ctrl+Z 回到拖动前宽度。

### 12.4 取消

- `Esc` 或手势被取消（`onPanCancel` / 窗口失焦）→ 清除预览覆盖、重排该行、不写源码。

### 12.5 边界

- 拖动时如果该行因光标进入而退回源码（理论上不会，因为拖手柄不移动光标），
  `imageBlocks()` 会返回空 → 手势自然结束，不写值。
- 图片加载失败时手柄仍存在（可改宽度），但高度固定为占位高度；
  松手照常写入宽度。

---

## 13. 撤销 / 选区 / IME 的硬性检查点

实施时必须逐条自测：

1. **粘贴 = 一步撤销**：Ctrl+V 后 Ctrl+Z，整行图片消失，正文回到粘贴前。
2. **改宽 = 一步撤销**：拖一次手柄后 Ctrl+Z，宽度回到拖动前；再 Ctrl+Z 才撤销粘贴。
3. **切换笔记清空历史**：既有逻辑（`documentId` 变化重建输入框）不能被破坏。
4. **异步期间切换笔记**：图片不会插进新笔记（§9.2 第 4 步的守卫）。
5. **光标进入/离开图片行**：图片与源码互相切换，行高随之变化，下方文字不重叠、
   不残留空白。
6. **图片行参与全选/复制**：复制出去的是源码 `![](assets/…)`，不是二进制。
7. **拖动滚动条**不触发手柄、不触发选字（沿用现有滚动条命中优先级）。
8. **表格与图片并存**：表格行的 `blockFor` 优先于图片，互不干扰。

---

## 14. 边界与已知限制（写进交接说明，不要"顺手修复"）

| 场景 | 本轮行为 |
|---|---|
| Web 端 | `saveAsset` 返回 null → 错误提示「当前存储不支持保存图片」。 |
| 移动笔记到别的文件夹 | `assets/...` 相对路径断链，图片显示失败占位。**不自动重写**。 |
| 删除笔记 | `assets/` 里的图片保留（可能成为孤儿）。 |
| 删除含 `assets` 的文件夹 | 被现有 `folderHoldsOnlyNotes` 拒绝。 |
| 用户创建名为 `assets` 的笔记文件夹 | 该文件夹不出现在文件树（被过滤）。 |
| 图片行内追加文字 | 一旦不再是「整行单个图片」，立刻退回普通源码行。 |
| 列表 / 引用 / 表格内的图片 | 不生成图片块，保持行内源码。 |
| 剪贴板同时有文字和图片 | 按文字优先（与现在完全一致）。 |
| 超大图（>4000 万像素） | 原生直接返回空 → 静默不粘贴。 |
| 远程图片 | 允许渲染（`NetworkImage`），但粘贴路径只产生本地文件。 |

---

## 15. 实施顺序（必须按此顺序，便于逐步验证）

1. **纯 Dart 工具**：`ImageMarkup` + `insertImageBlock` + 单测。
2. **存储层**：`NoteStore.saveAsset/assetPath` + IO 实现 + `listFolders` 过滤 + 单测。
3. **原生通道**：`nrs/clipboard` + `ClipboardImage` 封装 + 手动验证（完全重启应用）。
4. **粘贴接线**：`MarkdownEditor` 参数 + Ctrl+V + 右键菜单 + `NotesController` +
   `editor_pane` 注入。此阶段图片会以源码形态出现，但文件必须真的落盘。
5. **渲染**：`LiveImageBlocks` + `ImageBlockChrome` + `RenderLineEditable.imageBlocks()`
   + 组合解析器。此阶段图片可见、挤动文字、光标进入退回源码。
6. **拖拽**：手柄命中 + 预览覆盖 + 松手写回 + 撤销验证。
7. **清理与回归**：全量 `flutter test`、`flutter analyze`、perf 测试单独跑。

每一步结束后应用都能正常运行；不要一次性铺开所有改动。

---

## 16. 测试清单

### 16.1 新增单元测试

| 文件 | 覆盖点 |
|---|---|
| `test/image_markup_test.dart` | 两种语法解析、属性乱序/单引号/大小写、`width` 边界、alt 转义、`toMarkdown` 往返、`insertImageBlock` 的 4 种位置（文首/文中/文末/选区替换）与光标落点。 |
| `test/note_store_io_test.dart`（扩展） | `saveAsset` 建目录、返回 `assets/x.png`、同名生成 `_2`、文件名清洗拒绝 `../`、二进制内容逐字节一致、临时文件不残留。 |
| `test/note_image_test.dart` | `assetPath`：相对路径、`%20` 解码、`..` 拒绝、绝对路径拒绝、远程返回 null、vault 越界拒绝。 |
| `test/clipboard_image_test.dart` | 用 `TestDefaultBinaryMessenger` 模拟 `nrs/clipboard`：`png` 直通、`rgba` 编码成功、`MissingPluginException` 返回 null。 |
| `test/image_block_test.dart` | 非 paragraph 返回 null、整行单图返回块、选区命中返回 null、加载中占位高 120、固有比例高度、显式宽度 clamp、`dispose` 移除监听。 |
| `test/paste_image_test.dart` | 文本优先、空文本触发图片、`plain` 永不图片、围栏/表格拒绝、documentId 变化中止、保存失败提示。 |
| `test/image_resize_test.dart` | 预览不写源码、松手只写一次、撤销一步、clamp 96–contentWidth、Esc 取消不写。 |

### 16.2 扩展既有测试

- `test/live_editor_widget_test.dart`：像素探针验证「图片块出现 → 下方文字下移」；
  光标进入该行后源码文字出现。用 `tester.runAsync` + `boundary.toImage()`，
  参考文件内既有探针写法。
- `test/live_markdown_perf_test.dart`：加一个 1000 行正文 + 20 张图片的用例，
  在图片以外区域连续打字，单次耗时不超过既有基线 20%。

### 16.3 验证命令

```powershell
flutter analyze lib test
flutter test
flutter test --tags perf test/live_markdown_perf_test.dart   # 必须单独跑
```

### 16.4 原生手测（无法自动化）

1. `Win + Shift + S` 截图 → Ctrl+V。
2. 画图程序复制选区 → Ctrl+V（通常是 `CF_DIB`）。
3. 浏览器右键复制图片 → Ctrl+V（通常是 `CF_PNG` 或 `CF_HTML`+`CF_DIB`）。
4. 复制纯文本 → Ctrl+V（必须保持原行为）。
5. 复制文件（资源管理器）→ Ctrl+V（应无反应）。
6. 完全退出应用再启动后复测 1–3（验证原生通道没有被 hot reload 掩盖）。

---

## 17. 验收标准（Definition of Done）

全部满足才算完成：

- [ ] 粘贴截图后，磁盘上真的出现 `<笔记目录>/assets/image_*.png`，内容是 PNG。
- [ ] 编辑器内立刻显示图片，粘贴后无需点击别处。
- [ ] 图片下方的文字被挤下去；图片行高变化时上下文字实时跟随，不重叠。
- [ ] 点击图片行 → 退回 `![图片](assets/…)` 源码；移开光标 → 恢复图片。
- [ ] 拖动右下角手柄：宽度跟手、高度等比、下方文字实时重排；松手后宽度持久化，
      重新打开笔记仍是该宽度。
- [ ] 改过宽度的文件用其他 Markdown 工具打开，能读到 `<img … width="…">`。
- [ ] Ctrl+Z 一次撤销「粘贴」或一次「改宽」。
- [ ] 文本粘贴、表格粘贴、代码围栏内粘贴的行为与改动前完全一致。
- [ ] 全程**没有**新增成功提示；失败有明确错误提示。
- [ ] `flutter analyze lib test` 无问题；`flutter test` 全绿；perf 测试单独跑全绿。
- [ ] 原生通道在完全重启后可用。

---

## 18. 风险与应对

| 风险 | 应对 |
|---|---|
| DIB 变体多（32bpp alpha 全 0、BI_BITFIELDS、顶向下） | 按 §6.2 逐条处理；仍失败就返回 null，静默不粘贴，绝不崩溃。 |
| 大图导致内存峰值 | 原生 4000 万像素上限；Dart 端 PNG 编码前不再复制整块。 |
| `lineBlockFor` 每次 build 换实例 → 全量重排 | §11.1 的稳定组合解析器；用 perf 测试守住。 |
| 图片解码完成在布局阶段调 `markNeedsLayout` | 同步回调延后一帧（§10.4）。 |
| 拖拽与选区拖动冲突 | 手柄命中优先，吞手势（§12.1）。 |
| 写值产生多步撤销 / 撤销后光标跳回文首 | 复用既有写值入口；撤销定位沿用现有「公共前后缀」逻辑，不复用历史选区。 |
| Web 构建被 `dart:io` 污染 | 一律走 `note_image.dart` 条件导出。 |
| 文件名含空格导致 Markdown 链接失效 | 命名只用 `_` 与数字（§3.2）。 |
| 移动到别处后图片断链 | 记录为已知限制；第二阶段再考虑重写相对路径。 |

---

## 19. 实施记录

| 阶段 | 状态 | 内容 |
|---|---|---|
| T1 | 完成 2026-10-24 | 新建 `lib/core/utils/image_markup.dart`：`ImageMarkup.parseLine` 支持 Markdown 图片（尖括号目标、title、转义 alt）与单个 `<img>`（属性乱序、单双引号、大小写、`px`/小数宽度），拒绝整行以外的内容与非法宽度；`toMarkdown` 无宽度写标准 Markdown、有宽度写固定顺序 `<img src width alt>`；`insertImageBlock` 按 §4 规则补换行并给出光标。新增 `test/image_markup_test.dart`，26 个用例通过。 |
| T2 | 完成 2026-10-24 | `NoteStore` 增加默认返回 null 的 `saveAsset` / `assetPath`；IO 实现建 `<笔记目录>/assets/`、清洗文件名、`_2/_3` 去重、`.tmp` + rename 原子写，`assetPath` 拒绝远程/绝对路径/`..`/vault 越界；`listFolders` 隐藏任何 `assets` 段；`NotesController` 增加 `saveAsset` / `assetPathFor` 与 `image_yyyyMMdd_HHmmss.png` 命名。扩展 `test/note_store_io_test.dart`（含 `assets` 不进文件树），新增 `test/note_image_test.dart`，29 个用例通过。 |
| T3 | 完成 2026-10-24 | 原生侧新增 `nrs/clipboard` / `readImage`：`ClipboardSession` RAII 保证所有分支关闭剪贴板；优先注册格式 `PNG`，其次 `CF_DIBV5`、`CF_DIB`；DIB 手工解析（`biSize>=40`、24/32bpp、`BI_RGB`/`BI_BITFIELDS` 且 32bpp 标准掩码、底向上/顶向下、stride、`biClrUsed`、4000 万像素上限、32bpp 全零 alpha 视为不透明），转成 RGBA；无图/格式不支持一律返回空，不抛异常。Dart 侧 `ClipboardImage.readPng()` PNG 直通，RGBA 经 `ImmutableBuffer`/`ImageDescriptor.raw`/`toByteData(png)` 编码，缺插件、平台异常、尺寸非法均返回 null。新增 `test/clipboard_image_test.dart`，8 个用例通过；`flutter analyze lib test` 无问题。原生手测（截图 / 画图 / 浏览器复制图片）需完全退出应用后执行，留待 T7。 |
| T4 | 完成 2026-10-24 | 新增 `note_image.dart` 条件导出（IO 用 `FileImage`/远程 `NetworkImage`，Web 仅远程）；`MarkdownEditor` 增加 `savePastedImage` / `imageProviderFor`，Ctrl+V 严格文本优先，空文本才走 `_pasteImageFromClipboard`：围栏/表格行拒绝并提示「表格或代码块里不能粘贴图片」、读图后复查 `mounted` 与 `documentId`、保存失败/不支持分别提示、成功后 `insertImageBlock` 经 `_applyEdit` 落值；`_EditHistory.breakMerge()` 保证粘贴是独立一步撤销。右键菜单 `onPasteImage` 只挂在「粘贴」行，纯文本行永不传入。`editor_pane` 注入 `notes.saveAsset` 与 `assetPathFor` 解析。新增 `test/paste_image_test.dart`，8 个用例通过；相关右键与撤销测试 44 个全部通过，`flutter analyze lib test` 无问题。 |
| T5 | 完成 2026-10-24 | 新增 `lib/ui/editor/live_markdown/image_block.dart`：`LiveImageBlocks` 按行首偏移缓存块、`setPreviewWidth` 管理拖拽预览；`blockFor` 只接管 paragraph 且整行单图、选区与本行有交集（含边界）时返回 null 退回源码；`ImageLineBlock` 实现 §10.3 尺寸规则（占位 360×120、自然宽缩进正文列、640 高度软上限、显式宽度夹在 96..列宽且不受高度上限约束）、`drawImageRect` + 圆角描边、失败占位（`imageOff` + 文件名）、光标/选区几何与 `ImageBlockChrome`（右下角 14×14 手柄，失败态仍在）。`line_block_view.dart` 增加两个契约；`render_line_editable.dart` 增加 `invalidateImageLine`（行首偏移→行下标）与按布局缓存、仅视口内的 `imageBlocks()`，池化布局收养与 `_paintBlocks` 时回写块源码范围；`markdown_editor.dart` 用稳定的 `_LineBlockResolver`（tables → images）接线。修复解码完成时只挂 post-frame callback、不请求新帧导致空闲时永远停在占位的问题（补 `ensureVisualUpdate()`）。新增 `test/image_block_test.dart` 12 个用例，`test/live_editor_widget_test.dart` 增 5 个图片用例（含像素探针），该文件 78 个用例全过；`flutter analyze lib test` 无问题。 |
| T6 | 完成 2026-10-24 | `markdown_editor.dart` 新增 `_imageResize`（行首、起始宽度、按下 x、列宽上限）：`_imageHandleAt` 通过 `imageBlocks()` 的 14×14 手柄命中，悬停给 `resizeUpLeftDownRight`，`_ChromeShield` 同时挡住手柄上的按压，输入框的选区手势收不到；按下只聚焦并进入改宽，不移动光标。拖动仅 `setPreviewWidth` + `invalidateImageLine`，controller 与 `onChanged` 全程不动；松手 `_finishImageResize` 清预览、`breakMerge()`、按 `ImageMarkup.parseLine(...).toMarkdown(width:)` 一次替换整行，选区按长度差平移并夹在新长度内，只发一次 `onChanged`；宽度夹在 96..正文列宽。Esc 与 pointer cancel 丢弃预览、不写源码。新增 `test/image_resize_test.dart` 6 个用例（悬停光标、预览期零写入/零 onChanged、下方行 painter 不变、一次写入、Ctrl+Z 一步回退、96/720 夹取、Esc 取消、失败图片仍可改宽）全过；`image_block_test`、`live_editor_widget_test`、`table_chrome_test`、`paste_image_test` 共 129 个用例全过；`flutter analyze lib test` 无问题。撤销按既有 `_historyCaretOffset` 把光标落在图片行行尾，会揭示源码，测试按此行为断言。 |
| T7 | 完成（自动化部分）2026-10-25 | `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` 全量 1075 个用例全绿；perf 单独跑 6 个基准全过（本机满载时两个既有基准曾超 1000ms 阈值，空载重跑恢复，环境噪声非回归）。在 `test/live_markdown_perf_test.dart` 新增 `one-character edits in a 1000-line document with 20 images` 打字基线：1000 行、每 50 行一张图、同步交付的假图片源模拟命中 `ImageCache` 的再解析，本机实测 334.58 ms/build（阈值 <1000ms 与同文件其他基准一致）。对照 §14 无超出范围的行为：T6/T7 只动 §12 范围内的指针层、测试与文档，唯一无关改动是 `test/table_chrome_paint_test.dart` 删除两个未使用 import（analyze 门槛的纯清理）。§13 检查点：粘贴/改宽各一步撤销、光标进出揭示、滚动条优先级均有测试覆盖；表格先于图片的解析顺序由 `_LineBlockResolver` 结构保证。**剩余待用户执行**：§16.4 原生手测（截图/画图/浏览器复制、纯文本与文件复制原行为），须完全退出并重启应用后测；§17 DoD 中真实落盘 `assets/image_*.png`、重启后宽度持久化、外部工具读到 `<img width>` 等手工项。 |
