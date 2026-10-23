# 任务清单：子节点输入光标跑到左侧

- [x] 1. `lib/ui/editor/line_layout/render_line_editable.dart` · `listMarkerAt`
      在 `if (local.dx >= (revealed ? markerWidth : line.gutter)) continue;` 前插入
      `if (local.dx < line.slot.indent) continue;`，并更新方法注释（缩进槽不算标记命中）。
- [x] 2. `lib/ui/editor/line_layout/line_layout_engine.dart` · `offsetAtPoint`
      把 `if (localX < 0) return line.paintedFrom;` 改为
      `return line.slot.revealedMarkers ? line.source.paintStart : line.paintedFrom;`，
      附根因注释。
- [x] 3. `test/live_editor_widget_test.dart` 新增用例：
      嵌套列表缩进槽点击（隐藏态）→ 光标 = `paintStart`、标记不摊开；
      嵌套列表缩进槽点击（摊开态）→ 光标 = `paintStart`；
      IME 组合串写入后标记仍在本行开头。
- [x] 4. 回归既有标记用例 :916 / :980 / :1033；同时把 `line_layout_test.dart`
      「摊开嵌套列表时，缩进仍由槽位保留」的旧预期（缩进点 → `markerStart`）
      更新为新语义（→ `paintStart`）。
- [x] 5. `flutter analyze lib test` 无问题；`flutter test` 全绿。
