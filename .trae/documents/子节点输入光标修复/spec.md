# 子节点（嵌套列表）输入光标跑到左侧 — 修复规格

## 1. 现象

在嵌套列表（子节点）里开始输入时，偶发文字被插入到列表标记**左侧**。

截图证据：上一行是 `2. ☑ 先改另外…`，下一行显示 `qie'huan3. [ ]`——输入法的组合串
`qie'huan` 出现在 `3. [ ]` 之前，说明光标（caret）停在 `markerStart`（`3.` 的起点），
而不是内容起点 `paintStart`（`3. [ ] ` 之后）。随后输入（含 IME 组合）全部插进标记前面，
把 `  3. [ ] ` 变成 `  qie'huan3. [ ] `，这一行不再是合法列表项。

## 2. 根因（已确认，代码证据）

关键几何（`lib/ui/editor/line_layout/line_layout_model.dart:218-222`）：

```dart
double get width => revealedMarkers ? indent : indent + marker;
```

即：标记隐藏时槽位宽 = 缩进 + 标记；标记摊开（revealed）时槽位只让出缩进。
`LaidOutLine.gutter = insets.left + slot.width`（`line_layout_engine.dart:219`）。

### 路径 A：未摊开状态下点了缩进槽 —— 主因

1. `RenderLineEditable.listMarkerAt`（`render_line_editable.dart:1523-1569`）只按
   `local.dx < line.gutter` 判定“点在标记区”，而隐藏态的 gutter 覆盖了**整个缩进 + 标记**。
   所以点在嵌套行左侧的空白缩进里，也算“点了标记”。
2. 该函数用 `_markerCaretAt`（`render_line_editable.dart:1576-1599`）把落点换算成标记内偏移；
   缩进区被 `clamp(from, to)` 夹回 `markerStart`。
3. `MarkdownEditor._onPointerDown`（`markdown_editor.dart:2655-2667`）在 `!marker.revealed`
   分支直接 `at = marker.caret`、`_markerCaret = marker.caret`，抬手时
   `_setMarkerReveal` 把标记摊进正文、`_restoreMarkerCaret` 再把光标还给 `markerStart`。
4. 结果：标记摊开后 `3.` 从缩进处开始画，光标恰在 `3.` 之前；接着输入就插到标记左侧。

嵌套层级越深、缩进越宽，这条件“误中”的概率越大，与用户说的“有概率”一致。

### 路径 B：已摊开状态下点了缩进槽

`LineDocumentLayout.offsetAtPoint`（`line_layout_engine.dart:382-383`）：

```dart
final double localX = point.dx - line.gutter;
if (localX < 0) return line.paintedFrom;
```

摊开态 `gutter = insets.left + indent`、`paintedFrom = source.markerStart`
（`line_layout_engine.dart:975`）。点缩进区 → `localX < 0` → 返回 `markerStart`，
同样把光标放到标记前面。`_onPointerDown` 的 revealed 分支不做任何夹取，直接落位。

## 3. 修复方案（决策完整）

两个文件、共三处小改，不改动标记点击的既有语义。

### 3.1 `lib/ui/editor/line_layout/render_line_editable.dart` — `listMarkerAt`

缩进槽里没有字形，不算“点开标记”。把命中区下限从 `0` 收紧到 `line.slot.indent`：

```dart
final bool revealed = line.slot.revealedMarkers;
double markerWidth = line.slot.indent + line.slot.marker;
if (revealed) {
  // ……原文不动：按 paintStart 前的字形量出真实宽度
}
// 缩进槽不是标记字形：点在它上面等于点在正文左侧的空白，必须让给正文定位。
if (local.dx < line.slot.indent) continue;
if (local.dx >= (revealed ? markerWidth : line.gutter)) continue;
```

- 隐藏态：`listMarkerAt` 返回 `null` → `_onPointerDown` 走“点正文”路径，
  `_pendingMarker = null`、不触发 `_setMarkerReveal`、不设 `_markerCaret`；
  `positionAt` 得到 `paintStart`（内容起点）。
- 摊开态：同样返回 `null`，配合 3.2 得到 `paintStart`。
- 标记字形区（`dx >= slot.indent`）行为完全不变：仍返回标记命中，隐藏态按落点换算
  `marker.caret`，摊开态交给 `positionAt` 落在标记字间（既有测试依赖此语义）。

同步修正该方法的文档注释，写明“缩进槽不算标记命中”。

### 3.2 `lib/ui/editor/line_layout/line_layout_engine.dart` — `offsetAtPoint`

缩进区（槽位左边）统一落到本行正文起点：

```dart
final double localX = point.dx - line.gutter;
if (localX < 0) {
  // 标记摊进正文后槽位只剩缩进；缩进不是字形，落在它上面应归到正文起点。
  // 若沿用 paintedFrom（摊开时为 markerStart），光标会停在 `3. ` 之前，
  // 接着输入就把文字插进标记里（`qie'huan3. [ ]`）。
  return line.slot.revealedMarkers
      ? line.source.paintStart
      : line.paintedFrom;
}
```

- 隐藏态 `paintedFrom == paintStart`，结果与现状一致（不改行为）。
- 非列表行 `revealedMarkers == false`，结果与现状一致。
- 顶层列表 `slot.indent == 0`，`localX < 0` 只在行框外出现，实际不受影响；
  只有嵌套层级（`indent > 0`）的缩进点击会从 `markerStart` 改为 `paintStart`。

### 3.3 不改的部分

- 标记字形的点击 / 摊开 / `_markerCaret` 微任务归还：保持不变。
- `_visibleEdgeOffset`、`indentLines`（Tab 缩进）、`ListContinuationFormatter`（回车续列表）：
  本次不改。截图证据指向“点击落点”，不是 Tab / 回车路径；若回归用例发现它们仍能把
  光标写到 `markerStart` 之前，再单独立项。
- 不新增任何设置项、不改变文件中已保存的 Markdown 语义。

## 4. 验收与回归

新增 widget 用例（放入 `test/live_editor_widget_test.dart`，复用现有 fixture）：

1. 文档 `- 父条目\n  3. [ ] 子条目`，在子行**缩进槽中点 `x = slot.indent / 2`**（标记带纵向高度内）：
   - 断言 `controller.selection.isCollapsed`；
   - 断言 `selection.baseOffset == 子行 paintStart`（`3. [ ] ` 之后），且 `> markerStart`；
   - 断言该行 `revealedMarkers == false`（缩进点击不再摊开标记）。
2. 同上位置，但先让该行标记摊开（点一次标记字形）后再点缩进槽：
   - 断言光标仍为 `paintStart`，不得回到 `markerStart`。
3. 输入验证：在 1 的落点后以 IME 组合方式写入 `qie`（`composing` 覆盖新插入区间），
   断言该行仍以缩进 + `3. [ ] ` 开头，组合串位于标记之后。
4. 既有用例必须全绿：`live_editor_widget_test.dart` 的
   :916（点标记展开）、:980（点嵌套序号留在缩进上）、:1033（点序号字间落光标）。

验证命令：

```
flutter analyze lib test
flutter test
```
基线：当前 866 项全部通过，改后应保持 866 + 新增用例全绿。
