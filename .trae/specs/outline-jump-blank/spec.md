# 大纲跳转后编辑区空白（鼠标不动则一直空白）——根因定位与修复

## 1. 现象与复现

- 在 `使用说明书.md`（37,035 字符 / 1,867 行）右侧大纲点击任意标题。
- 编辑区立即变成空白；**鼠标不移动就永远不出现文字**；鼠标一动（hover）文字马上出现。
- 与「慢」无关：不是等内容慢慢画出来，而是「不重画」。
- 期望行为对齐 Obsidian：**点击即瞬时跳转，第一帧就能看到内容，光标停在目标标题行**。

## 2. 已确认事实（实测）

已排除「整篇重排导致卡顿」：

- 真实 app 的 scan 模式遍历 112 个标题：`full=0` 全部命中，`ensureUs ≤ 4.86ms`，`lineTopUs ≤ 0.19ms`，`fallback=false`。
- 用户 click 模式 6 次点击：`full=0`、`ensureUs 0.8–1.3ms`、`bodyEpoch=0`、点击帧 build 31–49ms、raster 1–2.5ms。
- 唯一的大帧是启动时 build=938ms / raster=27ms（整篇冷布局），与跳转无关。
- 真实字体（Deng.ttf）下：冷布局 1324ms，暖缓存整篇重排 108ms ⇒ 秒级只能来自「按 `_bodyEpoch` 整块重建输入框」，而跳转不触发它。

已确认的机制事实：

- `RenderLineEditable.paint`（[render_line_editable.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/line_layout/render_line_editable.dart)）**只画 `visibleDocumentBounds` 内的行**（`lineRangeBetween`）。绘制结果依赖当前滚动位置，所以「这一帧画空」在屏幕上就是空白，不会残留旧内容。
- `visibleDocumentBounds` 用 `getTransformTo(最近的 RenderAbstractViewport)` 求 `originY`；外层是 `SingleChildScrollView` 的 `_RenderSingleChildViewport`（`isRepaintBoundary=true`），正常时 band = `[pixels, pixels + 视口高]`。
- 动画结束后不再有新帧调度：只要最后一帧画空（band 退化 / 该帧被跳过），就会**永久空白**，直到 hover → `setState` → 重建 → 重排+重绘。
- 旧实现 `_goToHeading` 先写 `_body.selection`，再 `unawaited(_scrollToLine(...))` 做 220ms `animateTo`；写 selection 又会让内嵌 `LineEditableText` 在 post-frame 里调 `showOnScreen` 做 100ms `animateTo`。两个动画抢同一个 `ScrollPosition`，`ScrollPosition.beginActivity` 会 dispose 前一个 activity ⇒ `_scrollToLine` 的 `await` 永不完成，`_jumping` 残留（大纲不再跟随滚动）。
- 动画期间每帧 band 都在变，收尾帧最容易画空；这正是「点到哪都空白」的来源。

## 3. 修复方案（已实施）

目标：点击后**第一帧**即为最终画面，不依赖任何后续帧或鼠标移动。

### 3.1 瞬时跳转，替代动画

[editor_pane.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/editor_pane.dart) `_jumpToLine`：

- 用 `pos.jumpTo(target)` 取代 `animateTo`。只产生一次位置变化 ⇒ 一次重算 ⇒ 一次重绘。
- 目标位置仍按 `contentY - 视口高 * anchor` 计算，大纲/表格索引跳转保持原有落点（`anchor: 0.12`）。

### 3.2 跳转收尾强制一次「排版 + 重绘」

- `EditorPane` 新增 `_settleJumpRepaint`，由 `MarkdownEditor` 在挂载时注册 `_forceRepaint`（[markdown_editor.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/markdown_editor.dart)）：

  ```dart
  void _forceRepaint() {
    final RenderLineEditable? field = _editable();
    if (field == null || !field.attached) return;
    field.markNeedsLayout();
    field.markNeedsPaint();
  }
  ```

- `_settleJump()` 无条件调用它，再在 post-frame 复位 `_jumping`。
- 不用 `setState`：重建出的 `LineEditableText` 属性相同，`didUpdateWidget` 早退，不会触发重排/重绘。

### 3.3 `visibleDocumentBounds` 退化兜底（防御性）

[render_line_editable.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/editor/line_layout/render_line_editable.dart)：区间计算后若 `bottom - top <= 0`，回退为 `[offset.pixels, offset.pixels + 视口高]` 并夹到文档高度内。正常路径数值不变。

### 3.4 已删除的临时插桩

`editor_pane.dart` / `render_line_editable.dart` 内的 `TEMP-PROBE` 计数、日志、Stopwatch、额外 import，以及 `test/tmp_outline_jump_probe_test.dart`、`test/tmp_shell_outline_jump_probe_test.dart` 全部删除。长期保留的测试 API 仅有 `debugPaintedLines`、`debugFullLayouts`。

## 4. 验收标准

1. 手动：`使用说明书.md` 依次点击远近不同的标题，**点击后第一帧即可看到该标题位于视口上方约 12% 处、周围正文完整**，鼠标可以完全不动。
2. 大纲高亮停在被点击的标题；光标停在标题行（与 Obsidian 一致）。
3. 跳转全程 `debugFullLayouts == 0`（不整篇重排）。
4. `_jumping` 在跳转后 1 帧内恢复为 false，之后滚动时大纲能正常跟随。
5. `flutter analyze lib test` 无 issue；非 perf 测试全量通过；perf 测试单独运行通过。

## 5. 测试

`test/outline_jump_repaint_test.dart`：

- 点击标题后 `pump()` **第一帧**：`debugPaintedLines > 0`、`visibleDocumentBounds` 覆盖目标行、band 高度 > 0、`debugFullLayouts == 0`；
- 再 `pump()`：`pane.jumping == false`；
- 跳到最后一行：band 仍非空、仍有绘制。

## 6. 约束与回滚

- 若 3.2 的强制重排带来可测性能回退（跳转收尾帧 > 100ms），回滚 3.2，保留 3.1 + 3.3。
- 纯滚动、打字路径不经过 `_jumpToLine` / `_settleJump`，不受影响。
