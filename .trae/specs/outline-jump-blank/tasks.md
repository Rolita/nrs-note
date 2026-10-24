# 任务清单：大纲跳转后空白

> 对应 spec：[spec.md](file:///c:/Users/Kotori/Desktop/nrs-v5/.trae/specs/outline-jump-blank/spec.md)
> 状态：已完成（符合「点击即第一帧可见」验收）

## T0 判定实验 ✅

- 已完成：真实 app 内 `full=0`、`ensureUs ≤ 4.86ms`，确认不是整篇重排；空白源于收尾帧画空/被跳过且无后续帧。

## T1 瞬时跳转，替代动画 ✅

- 文件：`lib/ui/editor/editor_pane.dart`
- 改动：`_jumpToLine` 改用 `pos.jumpTo(target)`；`_settleJump()` 在 post-frame 复位 `_jumping`，不再依赖 `await animateTo` 完成。
- 结果：动画期间的逐帧 band 抖动与收尾空帧消失；`_jumping` 不会残留。

## T2 跳转收尾强制一次排版 + 重绘 ✅

- 文件：`lib/ui/editor/editor_pane.dart`、`lib/ui/editor/markdown_editor.dart`
- 改动：`EditorPane._settleJumpRepaint` 由 `MarkdownEditor.onJumpSettled` 注册 `_forceRepaint`（`markNeedsLayout + markNeedsPaint`），`_settleJump()` 无条件调用一次。
- 结果：走增量缓存命中路径，`debugFullLayouts` 保持 0。

## T3 `visibleDocumentBounds` 退化兜底 ✅

- 文件：`lib/ui/editor/line_layout/render_line_editable.dart`
- 改动：`bottom - top <= 0` 时回退为 `[offset.pixels, offset.pixels + 视口高]`，并夹到文档高度内；正常路径数值不变。

## T4 回归测试 ✅

- 文件：`test/outline_jump_repaint_test.dart`
- 覆盖：跳转后**第一帧**即 `debugPaintedLines > 0`、band 覆盖目标行且非空、`debugFullLayouts == 0`、1 帧后 `jumping == false`、跳到最后一行仍有效。

## T5 验收 ✅

- `flutter analyze lib test`：No issues found。
- 非 perf 全量：889 项通过。
- perf 单独运行：`live_markdown_perf_test.dart`、`live_markdown_reuse_perf_test.dart` 全部通过。
- 手动验收：`flutter run -d windows`，`使用说明书.md` 点标题，点击后第一帧即见正文，鼠标全程不动。

## T6 清理 ✅

- 删除 `editor_pane.dart`、`render_line_editable.dart` 内全部 `TEMP-PROBE` 插桩、临时字段与 import。
- 删除 `test/tmp_outline_jump_probe_test.dart`、`test/tmp_shell_outline_jump_probe_test.dart`。
- `render_line_editable.dart` 开头仅保留一个 BOM。
