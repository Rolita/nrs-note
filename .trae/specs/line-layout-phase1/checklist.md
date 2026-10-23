# 校验清单：按行排版编辑器（阶段 1 — fork EditableText）

## 文件与结构

- [x] `lib/ui/editor/line_layout/line_editable_text.dart` 存在，文件头注明 fork 自 Flutter 3.38.6。
- [x] 该文件内不再定义 `TextEditingController` / `ToolbarOptions` / `ContentInsertionConfiguration`。

## 渲染对象

- [x] `RenderLineEditable` 的 `performLayout` 先跑 `super.performLayout()`，再用行布局覆盖 `size` 与滚动范围。
- [x] `preferredLineHeight` 取的是视觉行高度，折行的列表行不会让光标跨行。
- [x] `paint` 依次绘制选区、行文本、composing 下划线、光标。

## 行为

- [x] 纯文本渲染正常，空文档有正行高。
- [x] 点击第二行，光标落在第二行。
- [x] 跨行拖选得到 ≥2 块几何，反向拖选方向相反。
- [x] IME composing 文本与区间可写入，且能取到几何。
- [x] 方向键 / Home / End 不越界。
- [x] 有序列表长行折行后，第二条视觉行 caret 左边缘等于正文列（悬挂缩进成立）。
- [x] 列表槽位内点击时光标吸附到正文列。

## 校验

- [x] `flutter analyze` 零问题。
- [x] `flutter test` 全量通过（既有 531 + 新增 10 = 541）。
- [x] 现网编辑器未接线，行为零变化。
