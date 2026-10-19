# 文件列表：右键删除 + Shift 多选删除

## Context（为什么要改）

需求：左侧「文件」列表里可以用**右键菜单删除文件**，并且可以**按住 Shift + 左键跨行选中多个文件后一次性删除**。

探查结论：这两件事的"骨架"其实已经存在于**未提交**的新文件里，但**没接上线**，所以现在功能不可用：

- [vault_tree.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/shell/vault_tree.dart)（未跟踪的新文件，真实文件夹树）已经实现：右键菜单（打开 / 置顶 / 收藏 / 删除）、`Shift+点击` 按可见行做范围选择（`_selectRangeTo`）、折叠文件夹里的隐藏项不会被误删（`_pruneToVisible`）。
- [notes_controller.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/state/notes_controller.dart#L452-L511) 已有 `deleteNotes(List<Note>)` 批量删除、`restoreNotes(List<DeletedNote>)` 撤销、`DeletedNote` 记录类型。
- 缺口一：`NoteListPanel` 构造 `VaultTree` 时**没有传必需的 `onDeleteNotes`**，`flutter analyze` 目前就报这 1 个 error（`note_list_panel.dart:169 missing_required_argument`）——也就是说树视图现在跑不起来。
- 缺口二：[app_shell.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/lib/ui/shell/app_shell.dart#L95-L175) 只有单篇的 `_confirmDelete(Note)`，没有多篇删除的确认弹窗。

所以本次是**接线 + 补一个多篇确认弹窗**，而不是重写选区逻辑。

## 改动清单

### 1. `lib/ui/shell/note_list_panel.dart`
- `NoteListPanel` 新增参数 `required this.onDeleteNotes;`（类型 `void Function(List<Note> notes)`）。
- 文件视图里补上：`VaultTree(key: _treeKey, notes: notes, onOpenNote: ..., onDeleteNotes: widget.onDeleteNotes)`。
- 搜索视图 `NoteListTile.onDelete` 继续走单篇的 `widget.onDeleteNote`，行为不变。

### 2. `lib/ui/shell/app_shell.dart`
- 新增 `Future<void> _confirmDeleteMany(List<Note> targets)`：
  - 空列表直接返回；`targets.length == 1` 时复用现有 `_confirmDelete(note)`（保留现有单篇弹窗里的相对路径展示）。
  - 多篇时弹确认框：标题「删除这 N 篇笔记?」，正文列出前 5 个标题 + 「…还有 N 篇」，取消 / 删除（危险色按钮），风格沿用现有 `AlertDialog`（`barrierColor: 0x44000000`、`p.surface`）。
  - 确认后 `await notes.deleteNotes(targets)`；先按 `DeletedNote`（`raw: n.toMarkdown(), fileName, folderPath`）逐个备份，再 `_toast('已删除 N 篇笔记', actionLabel: '撤销', onAction: () => notes.restoreNotes(backups))`。重名冲突由 `IoNoteStore.writeNewMarkdown` 的 `_freeName` 自动加 ` 2`，无需额外处理。
- `NoteListPanel(...)` 处传 `onDeleteNotes: _confirmDeleteMany`。
- `EditorPane.onDelete: _confirmDelete`（编辑区删除当前笔记）保持不变。

### 3. `lib/ui/shell/vault_tree.dart`（一处小修）
- `_tapFile` 现在无论是否按 Shift 都会 `onOpenNote`，编辑器会跟着跳到被点的那一篇。改为：**Shift+点击只扩展选区**（并更新 `notes.setActiveFolder`），不切换编辑器；普通点击仍是"选中 + 打开"。
- 其余逻辑保持：右键点在选区外时先把选区收敛到该行（资源管理器语义）；删除目标 = 选区 ∩ 当前可见行；右键菜单文案在多于 1 篇时显示「删除 N 篇笔记」。

### 明确不做（本次未要求）
- Ctrl+点击加减选、橡皮筋框选、拖拽移动。
- 右键菜单里的重命名 / 移动到文件夹。
- 搜索视图卡片列表的多选删除（它已有行内删除按钮）。

## 验证方式
1. `flutter analyze` —— 当前那 1 个 `missing_required_argument` 报错应消失，0 issue。
2. `flutter test` —— 既有测试（`test/shell_layout_test.dart`、`test/nrs_test.dart`、`test/notes_controller_test.dart` 等）通过。
3. 在 [shell_layout_test.dart](file:///c:/Users/Kotori/Desktop/nrs-v5/test/shell_layout_test.dart) 里补两条 widget 测试（复用现有 `_VaultStore` 内存库，fixture 改成 2 篇以上笔记）：
   - 右键删除：用 `tester.startGesture(位置, buttons: kSecondaryMouseButton)`（或等价右键手势）→ 断言出现「删除笔记」菜单项 → 点它 → 确认框点「删除」→ 断言该笔记不再出现在树里。
   - Shift 多选删除：`sendKeyDownEvent(LogicalKeyboardKey.shiftLeft)` 后点击第二行 → 断言两行同时处于选中态 → 右键 → 菜单文案为「删除 2 篇笔记」→ 确认删除 → 两篇都消失，且 SnackBar 出现「撤销」。
4. 手动：`flutter run -d windows`，在文件视图右键任意笔记删除、Shift+左键跨行选择后右键批量删除。

## 涉及文件
- `lib/ui/shell/note_list_panel.dart`（接线）
- `lib/ui/shell/app_shell.dart`（多篇删除确认 + 撤销）
- `lib/ui/shell/vault_tree.dart`（Shift+点击不打开笔记）
- `test/shell_layout_test.dart`（新增两条测试）
