# 关系图谱 · 实施方案

> 状态：**待确认**（确认后按 §10 分四步落地）
> 设计稿：`design/graph-view-mock.html`（可交互，直接双击打开）
> 参考：Obsidian Graph View

---

## 0. 一句话

从全库笔记的 `[[双链]]` 里抽出边，用同一套力导向参数在 `CustomPainter` 上画出来；
图谱是**主区的一个视图页签**，不是侧边栏；单击选中、双击跳转。

---

## 1. 范围

### 做

| # | 能力 |
|---|---|
| 1 | 标题栏新增「图谱」视图页签，占满正文区 |
| 2 | 全局图谱 / 局部图谱（以当前笔记为中心） |
| 3 | 局部图谱的**深度滑块** 1–4 跳 |
| 4 | 单击选中、双击跳转到那篇笔记 |
| 5 | 悬停高亮：本节点 + 直接邻居 + 相连的线，其余淡出 |
| 6 | 拖拽节点（其余节点被弹簧带着动）、拖空白平移、滚轮缩放 |
| 7 | 筛选：搜索框、文件夹图例、孤立笔记开关、连线箭头开关 |
| 8 | 显示标签开关（开 = 全部显示，关 = 全部不显示） |
| 9 | 显示：节点大小 / 连线距离 两个滑块 |
| 10 | 缩放 HUD：`−` / 百分比 / `+` / 适应窗口 |

### 不做（本期）

- **不画 `#标签` 节点**（已确认）。标签只用于搜索匹配和气泡里的展示。
- **不画死链幽灵节点**。`[[还没写的标题]]` 在正文里可点、会创建，但图谱里不出现——
  图谱表示「已经存在的结构」，画一堆幽灵节点会把真实结构淹掉。二期再考虑。
- 不做时间轴、不做 3D、不做导出图片。
- 不做「固定/钉住节点」、不做手动布局保存。

---

## 2. 交互规格

### 2.1 入口

标题栏标签条末尾、`+` 按钮之前，多一个**带图标的视图页签**：

```
[📄 开发进度 ×] [📄 日记 · 10月23日 ×] [🕸 图谱 ×] [+]
```

- 它不是笔记页签：不参与 `_openIds`，重启后不恢复（会话级状态）。
- 点页签 → 主区切到图谱；再点一次或点 `×` → 切回**上一篇打开的笔记**。
- 快捷键 `Ctrl+G` 开/关。
- 一篇笔记都没有时打开图谱：画布中央一句「还没有笔记」。

### 2.2 全局 / 局部

顶部分段控件：

| 模式 | 节点集合 |
|---|---|
| 全局 | 库里所有笔记 |
| 局部 | 以 `notes.selectedNote` 为心，BFS `depth` 跳以内的笔记 |

局部模式的标题栏右侧显示：`开发进度 · 2 跳内 · 19 篇笔记 · 40 条连接`。

### 2.3 深度滑块（局部模式才有）

范围 1–4，默认 1。

| 深度 | 含义 | 以「开发进度」为例（26 篇的示例库） |
|---|---|---|
| 1 | 只有直接邻居 | 10 篇 / 19 条边 |
| 2 | 连邻居的邻居 | 19 篇 / 40 条边 |
| 3 | 三跳 | 23 篇 / 47 条边 |
| 4 | 四跳（基本等于全库） | 24 篇 / 49 条边 |

滑块只在「局部」下出现在设置面板第一段；切回「全局」时整段收起。

> 实现注意：BFS 必须基于**全局邻接**。子图构建会就地截断邻居表，
> 所以每次建图前先按全量重算一遍邻接，否则第二次拖滑块就扩不动了
> （这个坑在 HTML 原型里已经踩过并修好）。

### 2.4 单击 / 双击

| 操作 | 结果 |
|---|---|
| 单击节点 | 选中（白环加深），邻居保持高亮；不跳转 |
| 双击节点 | `notes.select(id)` + 切回正文视图 |
| 单击空白 | 取消选中 |
| 拖拽节点 | 拖动，松开后其余节点回弹 |
| 悬停节点 | 邻居高亮 + 气泡（标题 / 文件夹 / 出链·入链 / 标签） |

### 2.5 筛选

| 控件 | 行为 |
|---|---|
| 搜索框 | 标题或标签命中才亮，其余淡到 16%（**不隐藏**，避免每敲一个字重排一次） |
| 文件夹图例 | 点一项 → 其他文件夹淡出；再点取消。图例上的数字是该文件夹的笔记数 |
| 孤立笔记 | 开 = 画；关 = **真删掉并重排**（结构性选择，不能只是变淡） |
| 连线箭头 | 开 = 有向（`[[A]] → B`）；关 = 无向细线（默认） |

### 2.6 显示标签（已确认：开关，开就显示）

一个开关，两种确定的结果，不做「缩放自动隐藏」那种聪明事：

- **开**：所有可见节点的标题都画出来（被筛选淡出的节点标签也一起淡到 14%）。
- **关**：一个标签都不画。此时靠白环认出当前笔记，靠气泡认出鼠标下的节点。

### 2.7 视图操作

| 操作 | 结果 |
|---|---|
| 拖空白 | 平移 |
| 滚轮 | 以光标为锚点缩放，范围 22%–320% |
| `−` / `+` | 以画布中心缩放 1.22 倍 |
| 适应窗口 | 重新计算包围盒并居中（缩放上限 150%，小图不会放得过大） |
| 重新布局 | 重新撒点 + 重新收敛（图形难看时的手动出口） |

---

## 3. 视觉规格

全部取自 `AppPalette.dark`（石墨素白），**不新增色相**。

| 元素 | 取值 |
|---|---|
| 画布 | 径向渐变 `#1D1D20 → #141416 → #101012`（比 `surface` 更深：正文是亮起的纸，图谱是凹陷的画布） |
| 连线 | `rgba(255,255,255,.085)`，1px；高亮 `.62` / 1.4px；淡出 `opacity .12` |
| 节点半径 | `3.4 + √度 × 1.85`（度 0 → 3.4，度 9 → 8.9）；滑块可整体 ×0.6–1.6 |
| 节点色 | 按**顶层文件夹**分组，取 `table_colors.dart` 的 `_darkInks`：灰 `#C2C5CC` / 琥珀 `#F2C35C` / 绿 `#6CDEA0` / 蓝 `#7FC4F0` / 紫 `#C3A6ED` |
| 当前笔记 | 常驻一圈 `--t1` 环（`opacity .55`） |
| 选中 | 环加深（`opacity .95`，1.8px） |
| 标签 | 10.5px `--t2`，节点右侧 5px，描边 2.6px 画布色（压在连线上也读得清） |
| 设置面板 | 左上，212px，`rgba(38,38,38,.86)` + `blur(14)` |
| 图例 | 左下，点选可过滤 |
| 缩放 HUD | 右下，26px 按钮 |

---

## 4. 数据层 · `lib/core/utils/note_graph.dart`（新增）

### 4.1 类型

```dart
/// 一个节点 = 一篇笔记。边用下标存，省内存也省得每帧查 Map。
class GraphNode {
  final int index;
  final String id;        // note.id，双击跳转用
  final String title;
  final String folder;    // 顶层文件夹，'' = 根目录
  final List<String> tags;
  int outDegree;          // 出链数
  int inDegree;           // 入链数
  int get degree;         // 无向度（去重后），决定半径
  final List<int> neighbours;
}

class GraphEdge { final int a, b; }

class NoteGraph {
  final List<GraphNode> nodes;
  final List<GraphEdge> edges;
  int get orphanCount;
  int? indexOfTitle(String target);   // 与 openOrCreateByTitle 同一条规则
  Set<int> neighbourhood(int from, int depth);   // BFS，深度滑块用
}

NoteGraph buildNoteGraph(List<Note> notes);
```

### 4.2 边的判定（三条硬规则）

1. **同一个扫描器**：只用 `wikilinkRuns(line)`（`lib/ui/editor/live_markdown/inline.dart`）。
   它和渲染、点击命中共用一个正则，所以反引号里的 `[[x]]` 天然不算——
   不会出现「正文里没画成链接，图谱里却有一条边」。
2. **排除嵌入**：`run` 在行内的起始字符是 `!` 时跳过（`![[图片.png]]` 是嵌入，不是链接）。
3. **目标解析与点击一致**：`indexOfTitle` 用
   `title.trim().toLowerCase()` 全等匹配、**先出现的赢**，与
   `NotesController.openOrCreateByTitle` 完全同一条规则。
   这样「图上这条边」和「点一下会跳到哪」永远是同一件事。

   推论（现状，不是新引入的）：`[[标题|别名]]` 的目标会被当成完整标题 `标题|别名`。
   编辑器目前就是这个行为，图谱跟着它走，不单独发明一套。

### 4.3 其它规则

- 死链（目标笔记不存在）→ 不产生边，也不产生节点。
- 自环（`[[自己]]`）→ 丢弃。
- A→B 与 B→A 同时存在 → **只画一条**（无向），但 `outDegree` / `inDegree` 各算各的。
- 重复 `[[A]]` 出现多次 → 只算一条边，但出链数按出现次数？**不**：按唯一目标数算，
  否则一句话里重复五次就会把节点撑大，误导人。

### 4.4 性能

| 库规模 | 建图耗时（估） | 说明 |
|---|---|---|
| 26 篇 | < 1 ms | |
| 300 篇 | ~10 ms | 每行只在含 `[[` 时才跑正则 |
| 1000 篇 | ~40 ms | 需要缓存 |

缓存策略：`_GraphRegion` 记住上次的 `(笔记数, 正文总长度)` 签名，签名不变就复用。
（`allNotes` 每次返回新 List，用不了 `identical`。）

**本期目标上限 300 篇**。超过 300 篇时斥力改成网格分桶（只对同格与邻格算精确斥力），
放到二期。

---

## 5. 物理层 · `lib/ui/graph/graph_physics.dart`（新增）

### 5.1 状态

```dart
class GraphLayout {
  final Float64List x, y, vx, vy;   // 按节点下标平铺，不用对象数组
  final Float64List radius;
  double alpha;                      // 0 = 静止
  void seed(NoteGraph g, {int seed = 1});
  void settle(NoteGraph g, int ticks);
  void step(NoteGraph g, double alpha);
  Rect bounds();
}
```

### 5.2 常量（已在原型里验算过）

| 参数 | 值 | 作用 |
|---|---|---|
| `rep` | 9200 | 斥力，与 d² 成反比 |
| `spring` | 0.021 | 边上弹簧系数 |
| `rest` | 74 | 弹簧自然长度（× 连线距离滑块 0.6–1.6） |
| `grav` | 0.0125 | 向心引力，防止整张图无限扩散 |
| `damp` | 0.80 | 速度衰减 |
| `vmax` | 14 | 单帧位移上限，防止初始乱飞 |

**验算结果**（用 node 直接跑同一段代码，不靠看图）：

- 26 节点 / 49 条边：包围盒 **440×533**，圆间最小间隙 **43.5px**（无重叠），
  800 tick 后漂移 **4.1**（已收敛），无 NaN。
- 局部子图（10 节点 / 19 边）：包围盒 210×288，间隙 50.6，漂移 0.0。

### 5.3 首屏不抖动

打开图谱时**同步** `settle(700)` 再 `fit()`，所以第一帧就是稳定布局，
不会「先炸开再收拢」。26 篇约 16 ms（一帧的量）。

tick 数按规模递减，避免大库卡住首帧：

```
n ≤ 120  → 700
n ≤ 300  → 260
n > 300  → 120，且丢进 compute() 隔离
```

### 5.4 什么时候跑

`Ticker` 只在需要时开：

- 拖节点 / 松开后回弹 / 拖「连线距离」滑块 → `alpha` 置 0.5–0.9 并启动
- `alpha < 0.005` → **停 Ticker**（静止时零开销，不烧电）

> 测试注意：因为静止时 Ticker 是停的，`pumpAndSettle()` 不会被卡住。
> 拖拽中的测试必须用 `pump(Duration)`，不能用 `pumpAndSettle`。

---

## 6. 渲染层 · `lib/ui/graph/graph_view.dart`（新增）

### 6.1 结构

```
GraphView (StatefulWidget)
├── 顶部 38px 头：分段控件（全局/局部）+ 统计 + 重新布局/更多
└── Stack
    ├── Listener + GestureDetector + CustomPaint   ← 画布
    ├── 设置面板（左上，可收起）
    ├── 图例（左下）
    └── 缩放 HUD（右下）
```

### 6.2 绘制顺序

1. **连线**：按「普通 / 邻居 / 高亮」分三桶，各自拼成一条 `Path`，
   三次 `drawPath` 画完——不是逐条 `drawLine`。
2. **节点**：实心圆，一次 `drawCircle` 一个。
3. **标签**：`TextPainter` 缓存（key = 标题），只对「开关打开且通过筛选」的节点画。

视口变换用 `canvas.translate + scale`，节点坐标全部在世界坐标里，命中测试反变换回去。

### 6.3 命中测试

反变换到世界坐标 → 线性扫描找最近的、距离 < `radius + 6` 的节点。
300 个节点一次扫描 ≈ 微秒级，不需要空间索引。

### 6.4 颜色

`GraphStyle` 由 `AppPalette` + 筛选状态算出来，painter 只吃 `GraphStyle`，
不碰 `context`。这样单测可以直接构造 style 断言。

---

## 7. 状态与接线

### 7.1 视图状态放哪

`app_shell.dart` 里已经有一个 `SidebarView _view`；旁边加：

```dart
enum MainView { note, graph }
MainView _mainView = MainView.note;
```

会话级，**不持久化**（重启回到上次的笔记，不回到图谱）。
不新建 controller，避免为两个值开一个状态类。

### 7.2 改动点

| 文件 | 改动 |
|---|---|
| `lib/ui/shell/app_shell.dart` | 加 `_mainView`；`Expanded` 里 `_mainView == MainView.graph ? GraphView(...) : EditorPane(...)`；传给 `AppTitleBar` |
| `lib/ui/shell/title_bar_content.dart` | 新增 `_ViewTab`（复用 `_TitleTab` 的尺寸与配色，图标换成 `LucideIcons.gitFork`）；`AppTitleBar` 加 `mainView` / `onSelectMainView` 两个参数 |
| `lib/core/theme/app_tokens.dart` | `AppLayout.graphPanelWidth = 212`、`graphPanelMinShellWidth`（窗口太窄时面板折叠成一条） |
| `spec.md` | 新增 G14（关系图谱）、§4.y（边的判定表） |
| `tasks.md` | T14 |

### 7.3 与右侧三面板的关系

图谱打开时，大纲 / 表格 / 图片三个面板**保持原样、不隐藏**。
理由：隐藏会让标题栏那三颗开关凭空消失，位置还会跳；而大纲点一下就能跳回正文，
并排看并不冲突。

（如果你更想要「图谱是全屏，右侧栏让位」，说一声，改动就是多一个 `&& _mainView == MainView.note`。）

### 7.4 局部图谱的中心

`notes.selectedNote`。选中的笔记被删掉时，局部图谱退化成空画布 + 一句
「没有选中的笔记，切到全局看看」。

---

## 8. 文件清单

**新增**

```
lib/core/utils/note_graph.dart          数据层：抽边、度数、BFS
lib/ui/graph/graph_physics.dart         物理层：撒点、步进、收敛、包围盒
lib/ui/graph/graph_view.dart            画布 + 交互 + 头
lib/ui/graph/graph_panel.dart           左上设置面板（筛选/显示/局部深度）
lib/ui/graph/graph_legend.dart          左下文件夹图例
lib/ui/graph/graph_style.dart           从 AppPalette 算出的绘制参数
test/note_graph_test.dart
test/graph_physics_test.dart
test/graph_view_test.dart
```

**修改**

```
lib/ui/shell/app_shell.dart
lib/ui/shell/title_bar_content.dart
lib/core/theme/app_tokens.dart
spec.md
tasks.md
```

---

## 9. 测试计划

### 9.1 数据层 `note_graph_test.dart`

1. A→B 与 B→A 只产生一条边，但出/入链各算各的
2. `![[图片.png]]` 不产生边
3. 死链（目标不存在）不产生边、不产生节点
4. `[[自己]]` 不产生边
5. 标题匹配不区分大小写、忽略首尾空格
6. 同名标题取**先出现的**那篇（与 `openOrCreateByTitle` 一致）
7. 反引号里的 `[[x]]` 不算（`wikilinkRuns` 的回归）
8. 代码块里的 `[[x]]` 不算
9. 一句话里重复 `[[A]]` 三次 → 一条边、度数为 1
10. `[[标题|别名]]` 的目标是 `标题|别名`（锁住现状，改了会红）
11. 度数 / 孤立数统计
12. BFS：深度 1 / 2 / 3 的节点集合（用固定的小图断言精确集合）
13. 空库、单篇、全孤立

### 9.2 物理层 `graph_physics_test.dart`

1. 300 tick 后无 NaN / Infinity
2. 圆之间无重叠（最小间隙 > 0）
3. 800 tick 后漂移 < 6（收敛）
4. `seed` 用固定种子 → 结果可复现（测试不能随机）

### 9.3 交互 `graph_view_test.dart`

1. 点标题栏「图谱」→ 画布出现、正文消失
2. 再点一次 → 回到上一篇笔记
3. 单击节点 → `selectedIndex` 变了、正文没变
4. 双击节点 → 切回正文，且那篇笔记被选中
5. 深度滑块 1→2 → 可见节点数变多
6. 关掉「显示标签」→ `debugLabelCount == 0`
7. 关掉「孤立笔记」→ 节点数减少
8. 搜索框输入 → `debugLitCount` 减少
9. 空库 → 空态文案

> `CustomPainter` 的内容不进语义树，所以 `GraphViewState` 上挂
> `@visibleForTesting` 的 `debugSnapshot`（可见节点数 / 亮着的节点数 / 画了几个标签），
> 断言读它，不去截图比对。

### 9.4 性能（`@Tags(['perf'])`）

- 500 篇 / 1200 条边：建图 < 200ms、首屏收敛 < 500ms
- 拖拽时单帧 `step` < 8ms

---

## 10. 分四步落地

| 步 | 内容 | 完成标准 |
|---|---|---|
| **P1** | `note_graph.dart` + `note_graph_test.dart` | 13 条单测全绿，`flutter analyze` 干净 |
| **P2** | `graph_physics.dart` + `graph_physics_test.dart` | 4 条单测全绿（含无重叠、收敛） |
| **P3** | `graph_view.dart` 画布 + 交互；页签接线 | 能打开、能看、能选中、能双击跳转；`graph_view_test` 1–4 绿 |
| **P4** | 设置面板 / 图例 / HUD / 局部深度 + 剩余测试 + `spec.md` | 全部测试绿；`flutter test --exclude-tags perf` 不回归 |

每步一个提交，做完一步给你看一次。

---

## 11. 风险与待确认

### 风险

| 风险 | 应对 |
|---|---|
| 大库（>300 篇）首屏卡顿 | tick 数按规模递减；>300 丢 `compute()`；二期上网格分桶 |
| 标签互相压字 | 标签带画布色描边；密集区域靠缩放看；二期可加「标签避让」 |
| 用户库里双链很少，图谱是一盘散点 | 空态提示「还没有双链」+ 一句怎么写 `[[笔记名]]` |

### 待你确认

1. **右侧栏**：图谱打开时保留（我倾向）还是让位？
2. **重启后**是否回到图谱？（我倾向不回到，回到上次的笔记）
3. `[[标题|别名]]` 现在会被当成完整标题——要不要顺手在**编辑器**里支持别名？
   （这属于双链的另一个话题，不建议塞进本期）
4. 图谱页签的图标：`gitFork`（分叉）还是 `network`（三点连线）？

---

## 12. 验收清单

- [ ] 26 篇示例库：打开即稳定布局，无重叠、无飞出去的节点
- [ ] 悬停任何一个节点，邻居和线亮起，其余淡出，气泡信息正确
- [ ] 拖节点，松手后整张图回弹且不散架
- [ ] 滚轮缩放以光标为锚点，缩放百分比正确
- [ ] 局部 + 深度 1/2/3/4 节点数依次增加
- [ ] 单击选中不跳转；双击跳转并切回正文
- [ ] 显示标签开关：开全有、关全无
- [ ] 孤立笔记关掉后，孤立节点真的消失且重新排布
- [ ] 搜索「图谱」只留下标题/标签命中的节点
- [ ] 空库、单篇笔记、全部孤立三种极端输入都不崩

---

## 13. 实施记录（P1–P4 已完成）

### 13.1 落地文件

| 文件 | 状态 | 说明 |
|---|---|---|
| `lib/core/utils/inline_syntax.dart` | 新增 | `markdownInlinePattern` / `fenceLinePattern` / `wikilinkTarget` / `wikilinkRuns` 从 `ui/editor/live_markdown/inline.dart`、`block_syntax.dart` 抽出，渲染、点击命中、图谱抽边三方共用一套扫描器（§4.2 规则 1） |
| `lib/core/utils/note_graph.dart` | 新增 | `GraphNode` / `GraphEdge` / `NoteGraph` / `buildNoteGraph` / `topFolder` |
| `lib/ui/graph/graph_physics.dart` | 新增 | `GraphPhysics` 常量、`graphNodeRadius`、`GraphLayout`、`settleTicksFor` |
| `lib/ui/graph/graph_style.dart` | 新增 | `GraphStyle.from(AppPalette)` + `assignFolderColors` |
| `lib/ui/graph/graph_painter.dart` | 新增 | `GraphPaintData` / `GraphPainter` / `GraphLabelCache` |
| `lib/ui/graph/graph_panel.dart` | 新增 | `GraphScope` / `GraphSettings` / `GraphPanel`（自绘 `_MiniSwitch`，不用 Material `Switch`） |
| `lib/ui/graph/graph_legend.dart` | 新增 | `GraphGroup` / `GraphLegend`（外层 `IntrinsicWidth`，见 13.3） |
| `lib/ui/graph/graph_view.dart` | 新增 | 主区画布：视口、命中、拖拽、Ticker、筛选、HUD、测试探针 |
| `lib/ui/shell/main_view.dart` | 新增 | `enum MainView { note, graph }` |
| `lib/ui/shell/app_shell.dart` | 改 | 主区 `Stack` + 两个 `Offstage`；`Ctrl+G` 切换；从图谱打开笔记会切回正文 |
| `lib/ui/shell/title_bar_content.dart` | 改 | 页签条末尾加「图谱」页签（`LucideIcons.gitFork`） |
| `lib/ui/shell/title_bar_io.dart` / `title_bar_web.dart` | 改 | 同步 `mainView` / `onSelectMainView` |
| `lib/core/theme/app_tokens.dart` | 改 | `AppLayout.graphPanelWidth = 212` |
| `lib/ui/editor/live_markdown/inline.dart` / `block_syntax.dart` / `live_markdown.dart` / `line_layout/live_line_style.dart` | 改 | 改用 core 的扫描器，删掉各自的私有正则 |

### 13.2 测试

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `test/note_graph_test.dart` | 21 | 抽边 13（含围栏代码块、嵌入、死链、自环、重复、大小写）+ 度数 2 + 邻域/子图 6 |
| `test/graph_physics_test.dart` | 13 | 收敛 5 + 可复现 2 + 边界 3 + 半径/帧数 3 |
| `test/graph_view_test.dart` | 15 | 打开即有图 3 + 单击/双击 3 + 局部深度 3 + 筛选 4 + 视图操作 2 |
| `test/graph_style_test.dart` | 8 | 色名分配稳定性 3 + 深浅两套配色各自在画布上的对比度 2 + 画布亮度 1 + 描边不出白边 1 + 浅色不是深色那套 1 |

### 13.3 实施中踩到并修掉的坑

1. **`![[x]]` 是嵌入不是链接**：`wikilinkRuns` 的返回值加了 `embed` 字段，
   `_linkTargets` 跳过 `embed == true` 的 run（§4.2 规则 2）。
2. **围栏代码块里的 `[[x]]`**：`_linkTargets` 逐行扫，一开始不知道围栏。
   把 `fenceLinePattern` 提到 core，逐行翻转 `fenced` 状态。
3. **`NoteGraph.isNotEmpty` 漏写**：`graph_view.dart` 直接用了，补 getter。
4. **图例炸 `BoxConstraints forces an infinite width`**：图例挂在 `Positioned` 里，
   宽度无界，`Row` + `Flexible` 拿到无穷大约束。外层包 `IntrinsicWidth`。
5. **单击节点整张图抖一下**：`_onPointerUp` 原来无条件 `_heat(0.45)`。
   加 `_dragMoved` 标志，只有真拖过才回弹。
6. **悬浮气泡 `Row` 溢出 17px**（`RenderFlex overflowed`）：文件夹名 + `出 N · 入 N`
   在 216px 宽的卡片里放不下。文件夹名改 `Flexible` + 省略号，度数永远看得见。
7. **`DoubleTapGestureRecognizer` 的 40ms 计时器**：测试里点完只 `pump()`
   不推进时间，结束时报 "Pending timers"。测试辅助函数 `tapAndSettle` 点完
   `pump(400ms)` 把双击判定窗口走完。（纯测试问题，不是应用缺陷。）
8. **「有笔记但一条边都没有」没有提示**：原来只有 0 节点才显示空态，
   2 篇无链接笔记时画布上是两个散点，看着像坏了。补一条底部居中的提示条
   （`_hintPill`），不挡节点。
9. **浅色主题下分组色糊在画布上**（真缺陷）：`assignFolderColors` 直接返回
   `table_colors.dart` 的 `_darkInks`——那是给深色画布提亮过的一组值。浅色主题的
   画布是 `#F4F4F2`，灰 `#C2C5CC` 压上去对比度只有 ~1.5，基本看不见。
   改法：`groupPalette(List<Color>)` → `groupTokens(List<CellColorToken>)`，
   `assignFolderTokens` 返回**色名**，新增 `groupColor(palette, token)` 走
   `tableInkColor`（深色给 `_darkInks`，浅色给 `textSecondary/warning/success/
   #2F6690/#6B4E8E/danger`）。建图在 `initState`、那时读不到 `Theme`，所以状态里
   只存色名，颜色在 `build` 里解析——图例、节点、气泡点共用同一份。

### 13.4 相对方案的偏差

- 方案 §7.2 原写「`spec.md` 新增 G14、§4.y 边的判定表」。实际没动 `spec.md`：
  那一篇是「粘贴图片」的规格，G1–G13 全是图片行为，把图谱塞进去会串味。
  边的判定表留在本文 §4.2，验收标准见 §12，实施记录见本节。
- 局部图谱的「没有选中的笔记」和「选中了但这篇没有双链」拆成两句不同提示
  （方案 §2.3 只写了前者）。

### 13.5 后续调整

- 2026-10-27 图谱设置默认值定为：节点大小 75、连线距离 100、旋转速度 20、
  放大减速 170%；标签 225/520、连接长度 70%、远端收拢 120%、弹簧强度 120%、
  斥力 100%、最小间距 9° 沿用原值。默认值仍只在 `GraphSettings` 构造函数维护，
  已存过偏好值的老用户不受影响。
- 2026-10-27 左键单击不再打断自转：点空白只清高亮，点节点照常打开笔记；只有
  拖动旋转或拖节点会清零空闲计时，松手后 1 秒恢复（阈值由 1.4 秒改为 1 秒）。
- 2026-10-27 外圈大气层照 `design/graph-drag-variants.html` 一比一收窄：从
  「0.86R 起、峰值 13%」改成「0.965R 起、峰值 10%（0.75 处 3%）、1.075R 淡出」。
  环只贴轮廓外侧，不再压住最外圈节点；参数见 `orb_painter.dart` 的
  `_paintBackground`，对比页 `design/graph-rim-variants.html` 的 G 方案。
