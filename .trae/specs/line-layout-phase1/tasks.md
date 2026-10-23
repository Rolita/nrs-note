# 任务：按行排版编辑器（阶段 1 — fork EditableText）

> 依赖：`spec.md` 第 4 节。所有任务完成前不提交、不接入现网编辑器。

## T1 拷贝并机械改写 SDK `editable_text.dart`

- [x] 复制 `C:\A\flutter_windows_3.38.6-stable\flutter\packages\flutter\lib\src\widgets\editable_text.dart`
      到 `lib/ui/editor/line_layout/line_editable_text.dart`。
- [x] 替换导入区（第 17–68 行为公开库；material 仅取 `kMinInteractiveDimension`；删除 `_web_browser_detection_*`）。
- [x] 删除 `TextEditingController`（221–400）、`ToolbarOptions`（401–452）、`ContentInsertionConfiguration`（453–510）、
      `kDefaultContentInsertionMimeTypes`（118–126）。
- [x] 依次重命名 `EditableTextState` → `LineEditableTextState`、
      `EditableTextContextMenuBuilder` → `LineEditableTextContextMenuBuilder`、
      `EditableText` → `LineEditableText`。
- [x] 保留 `EditableTextTapOutsideIntent` / `EditableTextTapUpOutsideIntent` 原名（SDK 外部类型）。
- [x] 添加文件头注释（fork 来源、SDK 版本、同步约定）。

**验收**：文件内不再定义 `TextEditingController` / `ToolbarOptions` / `ContentInsertionConfiguration`；
`grep -n "class LineEditableText"` 恰好命中 1 处。

## T2 新建 `lib/ui/editor/line_layout/render_line_editable.dart`

- [x] `class RenderLineEditable extends RenderEditable`，构造函数逐参 `super` 转发。
- [x] 维护 `LineDocumentLayout? _lineLayout`、`_layoutText`、`_layoutStyle`、`_layoutWidth`、自有 `_paintOffset`（`_linePaintOffset`）。
- [x] 覆盖影响排版的 setter，置脏。
- [x] 实现 `_ensureLineLayout()`：`plainText` + `text.style` + `constraints.maxWidth` 调 `layoutLines`。
- [x] 覆盖 `performLayout` / `computeDryLayout` / `preferredLineHeight`。
- [x] 覆盖 `getBoxesForSelection` / `getEndpointsForSelection` / `getRectForComposingRange` /
      `getPositionForPoint` / `getLocalRectForCaret` / `getLineAtOffset` / `selectPositionAt`。
- [x] 覆盖 `paint`（选区 → 行文本 → composing 下划线 → 光标）。
- [x] 覆盖 `dispose` 释放 `LineDocumentLayout`。
- [x] 不支持项（`WidgetSpan`、`obscureText`）写明确注释。

**验收**：`flutter analyze` 对该文件零问题。

## T3 接线 `_Editable`

- [x] `_Editable.createRenderObject` 返回 `RenderLineEditable`，参数与 SDK 完全一致。
- [x] `_Editable.updateRenderObject` 形参改为 `RenderLineEditable`。
- [x] 全文搜索确认 `LineEditableText` 内部无遗留 `RenderEditable(` 直接构造。

## T4 组件测试 `test/line_editable_text_test.dart`

- [x] 搭最小宿主（MaterialApp + SizedBox(width: 360)，字体 Ahem、`fontSize: 16, height: 1.5`）。
- [x] 渲染 / 光标 x 单调 / 点击第 2 行 / 跨行拖选 / 反向拖选。
- [x] IME composing（`tester.testTextInput.updateEditingValue`）。
- [x] 方向键、Home、End 不越界。
- [x] 长有序列表行折行后第 2 条视觉行 caret x == `gutter`。
- [x] 50 行总高度 == 各行高度之和（±0.5）。
- [x] 列表槽位点击吸附正文列。

**验收**：新增用例全绿。

## T5 全量校验与汇报

- [x] `flutter analyze`（未新增任何依赖，`characters` 由 `widgets.dart` 提供）。
- [x] `flutter test` 全量（541 项全绿 = 既有 531 + 新增 10）。
- [x] `git status --short` 核对改动范围，**不提交**。
- [x] 汇报：新增文件、测试数量、遗留风险、阶段 2 入口条件。

## 阻塞与回滚

- 若 fork 文件在公开导入下出现无法替代的 SDK 私有依赖（>3 处），停止实现，向用户汇报并给出「改用私有 import」或「缩小 fork 范围」两个选项。
- 回滚方式：删除 `line_layout/line_editable_text.dart`、`line_layout/render_line_editable.dart`、
  `test/line_editable_text_test.dart`，撤销 `pubspec.yaml` 增量；阶段 0 文件保持不动。

## 实现备注（与规格的偏差）

- `paint` 未绘制 `_backgroundRenderObject` / `_foregroundRenderObject`：阶段 1 未使用这两个 painter，等阶段 4 迁移
  `selection_wash` / `code_block_painter` 时一并接回。
- `preferredLineHeight` 取的是首行的**视觉行**高度而不是整条源码行高度：折行的列表行整行高 96px，
  拿它当光标高度会让光标跨行（实测 `Rect(48, -12, 50, 84)`）。
- 裸 `LineEditableText` 不带拖选识别器（SDK 里由 `TextField` 的 `TextSelectionGestureDetectorBuilder` 提供），
  测试改为直接调用手势层最终入口 `selectPositionAt`。
- `tester.showKeyboard` 依赖 `EditableTextState` 类型，fork 后不可用；测试改为 `focusNode.requestFocus()`。
