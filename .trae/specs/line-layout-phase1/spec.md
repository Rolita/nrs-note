# 规格：按行排版编辑器（阶段 1 — fork EditableText）

## 1. 背景与已确认结论

- 需求：四种列表（无序 / 有序 / 无序任务 / 有序任务）实现**悬挂缩进**，续行与「标记之后第一个字」左对齐。
- 已确认技术约束：
  - Flutter 的 `ParagraphStyle` 无 `textIndent`。
  - `RenderEditable` 整篇只持有一个 `TextPainter`（`rendering/editable.dart:780`），段落内软换行必然回到段落左边缘。
  - `_Editable.createRenderObject` 在 `widgets/editable_text.dart:6002` 硬编码 `RenderEditable`，没有替换渲染对象的钩子。
- 用户已选定路线：**按行排版 + fork `EditableText`**（复用输入法 / 选区 / 剪贴板 / 撤销），并已完成阶段 0。

## 2. 阶段 0 产物（已完成，本次不修改）

| 文件 | 作用 |
| --- | --- |
| `lib/ui/editor/line_layout/line_layout_model.dart` | `scanSourceLines`、`SourceLine`、`VisualLine`、`MarkerSlot`、`CaretGeometry`、`LineLayoutMetrics` |
| `lib/ui/editor/line_layout/line_layout_engine.dart` | `layoutLines(...)` → `LineDocumentLayout`（每行一个 `TextPainter`） |
| `test/line_layout_test.dart` | 23 项几何测试，已全绿 |

阶段 1 只消费 `layoutLines` / `LineDocumentLayout` 的现有公开 API，不修改这两个文件。

## 3. 阶段 1 目标与边界

**目标**：fork 出可编译、可运行的 `LineEditableText`，把渲染对象换成按行渲染的 `RenderLineEditable`，让**纯文本**场景跑通：渲染、点击定位、拖选、方向键、IME 输入与 composing、光标绘制。

**不在本阶段**：
- 不接入 `lib/ui/editor/markdown_editor.dart`（现网编辑器继续走 `TextField`）。
- 不做 markdown 样式（阶段 2）、不做列表标记绘制（阶段 3）、不迁移 `selection_wash` / `code_block_painter` / 表格命中 / 右键菜单（阶段 4）。
- 不支持 `WidgetSpan` 内联子节点与 `obscureText`（阶段 1 明确忽略，代码中留注释）。

## 4. 文件变更清单

### 4.1 新建 `lib/ui/editor/line_layout/line_editable_text.dart`

由 SDK `C:\A\flutter_windows_3.38.6-stable\flutter\packages\flutter\lib\src\widgets\editable_text.dart`（280,145 B，约 6900 行）机械复制后做以下**唯一**允许的变换：

1. **导入区替换**（第 17–68 行）为公开库：
   - `dart:async`、`dart:math as math`、`dart:ui as ui hide TextStyle`
   - `package:characters/characters.dart`
   - `package:flutter/foundation.dart` / `gestures.dart` / `rendering.dart` / `scheduler.dart` / `services.dart` / `widgets.dart`
   - `package:flutter/material.dart' show kMinInteractiveDimension`（该常量在 `widgets/constants.dart`，`widgets.dart` 未导出）
   - 删除 `_web_browser_detection_io.dart` 条件导入（全文件仅 import，无符号使用）
   - 相对导入删除：`constants.dart`（仅用 `kMinInteractiveDimension`，改由 material 提供）；其余相对导入（actions、basic、focus_*、scroll_*、text_selection 等）全部删掉，统一由 `widgets.dart` 提供。
2. **删除重复的公开类**（这些类 SDK 已通过 `widgets.dart` 导出，重复定义会全项目类型冲突）：
   - `class TextEditingController`（原 221–400 行）
   - `class ToolbarOptions`（原 401–452 行）
   - `class ContentInsertionConfiguration`（原 453–510 行）
   - `const kDefaultContentInsertionMimeTypes`（原 118–126 行，删除上面类后无引用）
3. **重命名**（顺序执行，均为单词边界匹配）：
   - `EditableTextState` → `LineEditableTextState`
   - `EditableTextContextMenuBuilder` → `LineEditableTextContextMenuBuilder`
   - `EditableText` → `LineEditableText`（含构造函数、`groupId` 默认值、`EditableText.defaultSelectionHeightStyle` 等静态引用、文档注释）
   - **不重命名** `EditableTextTapOutsideIntent`、`EditableTextTapUpOutsideIntent`（定义在 SDK `text_editing_intents.dart`，属于外部类型）。
   - 私有类 `_Editable` 保持原名。
4. **`_Editable.createRenderObject`（6087 行起）** 改为构造 `RenderLineEditable(...)`，参数列表与 SDK 完全一致；`updateRenderObject` 的形参类型改为 `RenderLineEditable`，级联 setter 保持不变。
5. 注释、文档、`@template` 文案不改写；仅新增文件头注释说明 fork 来源与同步时机。

### 4.2 新建 `lib/ui/editor/line_layout/render_line_editable.dart`

```dart
class RenderLineEditable extends RenderEditable {
  RenderLineEditable({ /* 与 RenderEditable 构造参数逐一对应，全部 super 转发 */ });
}
```

只覆盖以下成员，其余全部继承：

| 成员 | 实现要点 |
| --- | --- |
| 影响排版的 setter（`text`、`textScaler`、`textAlign`、`textDirection`、`strutStyle`、`maxLines`、`minLines`、`expands`、`obscuringCharacter`、`obscureText`、`locale`、`textHeightBehavior`、`textWidthBasis`） | 先 `_markLineLayoutDirty()`，再 `super.<setter> = v` |
| `preferredLineHeight` | 用 `_ensureLineLayout()` 后取首行 `height`；无行时回落 `super.preferredLineHeight` |
| `computeDryLayout` | 用与 `performLayout` 相同的布局算法，返回 `Size(width, height)`，不写状态 |
| `performLayout` | 先 `layoutInlineChildren(...)` 定位内联子节点（沿用 SDK 调用）；以 `constraints.maxWidth` 为 `contentWidth` 调 `layoutLines(...)`；`size = Size(width, constraints.constrainHeight(layout.height))`；同步 `offset.applyViewportDimension/applyContentDimensions` 与 `_maxScrollExtent`（复用 `super` 的 `_getMaxScrollExtent` 不可见，改为按 `layout.height` 直接设置） |
| `getBoxesForSelection` | `_lineLayout.selectionRects(selection.start, selection.end)` → `TextBox.fromLTRBD(..., textDirection)`，叠加 `_paintOffset` |
| `getEndpointsForSelection` | 用 `caretGeometryAt(selection.extentOffset)` 与 `offsetAtPoint` 反推端点，返回 `(start, end)` 两个 `Offset` |
| `getRectForComposingRange` | 用 `selectionRects(range.start, range.end)` 求并集 |
| `getPositionForPoint` | `_lineLayout.offsetAtPoint(point - _paintOffset)` → `TextPosition(offset: ...)` |
| `getLocalRectForCaret` | `caretGeometryAt(position.offset)` → `caretPrototype.shift(origin)`，再叠加 `_paintOffset` |
| `getLineAtOffset` | 按 `caretGeometryAt(offset).lineIndex` 取行 top/bottom，返回 `TextRange(start: line.source.start, end: line.source.end)` |
| `paint` | 依次：背景 `_backgroundRenderObject` → 选区矩形（`selectionColor`，`selection` 有效且非空时）→ 每行 `painter.paint(canvas, Offset(gutter, top))` → composing 下划线矩形（`textSelectionDelegate.textEditingValue.composing`，颜色取 `cursorColor.withOpacity(0.5)`）→ 光标（`hasFocus && showCursor.value`，`_caretPrototype` 平移到 `caretGeometryAt(selection.extentOffset)`）→ `_foregroundRenderObject`；全部受 `_paintOffset` 平移 |
| `dispose` | 先 `_lineLayout?.dispose()`，再 `super.dispose()` |

**布局缓存失效**：除上述 setter 外，`_lineLayout` 在 `constraints` 宽度变化时也要重建——在 `performLayout` 内比较 `_lastLayoutWidth`，不同则重建。

**样式来源（阶段 1）**：`baseStyle` 取 `text.style ?? const TextStyle()`，`styleFor` 传 `null`（所有行同一字号）；`heightFor` 传 `null`。阶段 2 再把 `buildLiveSpans` 的样式解析迁入。

**绘制偏移**：SDK 的 `_paintOffset` 是私有字段，fork 文件与 `render_line_editable.dart` 属不同库，需在 `RenderLineEditable` 内维护自己的 `_paintOffset`（由 `offset.pixels` 与 `size` 计算，公式照抄 `RenderEditable._paintOffset` 的 getter）。

### 4.3 新建 `test/line_editable_text_test.dart`

组件测试，最小宿主：

```dart
MaterialApp(home: Scaffold(body: SizedBox(width: 360, child: LineEditableText(
  controller: c, focusNode: f, style: const TextStyle(fontSize: 16, height: 1.5, fontFamily: 'Ahem'),
))))
```

用例（≥8 项）：
1. 空文档渲染不抛异常，`preferredLineHeight` 有限且 > 0。
2. 输入 `abc` 后 `getLocalRectForCaret(3)` 的 x 大于 `getLocalRectForCaret(0)`。
3. 点击第 2 行，`selection.extentOffset` 落在第 2 行范围内。
4. 拖选第 1–2 行，`getBoxesForSelection` 返回 ≥2 个矩形且矩形 y 递增。
5. 反向拖选得到 `start > end` 的选区但矩形覆盖正确。
6. IME：`tester.testTextInput.updateEditingValue(...)` 带 `composing`，文本与选区正确，composing 区间可查询。
7. 方向键 / Home / End 移动光标不越界。
8. 长列表行（`'1. ' + 长文本`）在 200px 宽度下折行后，第 2 条视觉行首字符的 caret x 等于 `gutter`（≥ 序号宽度），即悬挂缩进几何成立。
9. 连续 50 行文档，总高度 = 各行 `height` 之和（±0.5）。
10. 列表行内点击「序号槽位」时 cursor 吸附到正文列（不回退到 x=0）。

### 4.4 可能改动 `pubspec.yaml`

仅当 `flutter analyze` 报 `depend_on_referenced_packages`：在 `dependencies` 增加 `characters: ^1.4.0`（Flutter SDK 已锁定同版本，不增加实际包体）。不新增其它依赖。

## 5. 验证

1. `flutter analyze` 零 error / 零 warning（新文件允许保留 SDK 原有 ignore 注释）。
2. `flutter test` 全量通过（含既有 531 项 + 本次新增用例）。
3. 不执行 `flutter build windows`、不接入现网编辑器。
4. `git status` 仅包含本规格所列新增文件（以及可能的 `pubspec.yaml`/`pubspec.lock`），**不提交**，等用户确认。

## 6. 风险与对策

| 风险 | 对策 |
| --- | --- |
| SDK 私有符号在公开导入下不可见（如 `kMinInteractiveDimension`） | 逐个改为公开等价物；无等价物则在本文件内定义同名私有常量并注释来源 |
| `RenderEditable` 内部私有 `_textPainter` 仍被 `selectPositionAt` / `getWordBoundary` 使用 | 纯文本下其几何与行引擎一致；列表续行差异留到阶段 3 处理 |
| `TextField` 等 SDK 组件与 fork 类型交互 | 本阶段 fork 组件完全独立，无交叉引用 |
| 文件过大难以维护 | 文件头注明 fork 自 Flutter 3.38.6，升级 SDK 时需重新同步；实体逻辑集中在 `render_line_editable.dart` |

## 7. 验收标准

- 阶段 1 四个新文件（含测试）落地，`flutter analyze` + `flutter test` 全绿。
- 在独立测试宿主中，纯文本输入、点击、拖选、IME、光标绘制、列表续行 caret 缩进全部符合预期。
- 现网编辑器行为零变化（未接线）。
- 用户确认后再进入阶段 2。
