# 白板（Canvas）· 实施方案

> 状态：**待确认。** 本文只出方案，不动代码。
> 目标：在 nrs-v5 里复刻 Obsidian 的白板，文件格式与 Obsidian **双向兼容**。
> 面向：接手的实施 AI / 工程师。文中路径均对应仓库 `c:\Users\Kotori\Desktop\nrs-v5`。

---

## 0. 一句话

白板是一块**无限画布**：往上面扔卡片（文字 / 笔记 / 网页链接），用箭头把卡片连起来，
所有东西存成一个 `.canvas` 文件（JSON Canvas 1.0），Obsidian 能直接打开，反过来也成立。

---

## 1. 范围

### 1.1 做（按 P0–P6 分阶段，见 §11）

| # | 行为 |
|---|------|
| C1 | 功能栏（最左那条 `AppRail`）多一颗「白板」按钮；点击开白板：有 `.canvas` 就弹出选择器（含「新建」），没有就直接新建一块。 |
| C2 | 主区多一个「白板」视图，与「图谱」并列在页签条末尾。 |
| C3 | 画布可以**平移**（拖空白 / 滚轮）和**缩放**（Ctrl+滚轮 / 触控板捏合），缩放以光标为锚点。无限大，没有边界。 |
| C4 | 背景是点阵网格，随缩放变化疏密；缩得太小时网格淡出，不糊成一片。 |
| C5 | 双击空白 = 新建一张文字卡片，直接进入编辑。 |
| C6 | 卡片可以拖动、八向缩放（四角 + 四边中点），最小 40×40。 |
| C7 | 卡片有六种预设颜色（JSON Canvas 的 `"1"`–`"6"`），右键菜单换色。 |
| C8 | 从卡片四边中点的小圆点拖出，落到另一张卡片上 = 建一条边；边是贝塞尔曲线，可带箭头、可带文字标签。 |
| C9 | 框选（拖空白）、Shift 点选、多选后整组拖动 / 删除。 |
| C10 | 键盘：`Delete` 删除、`Ctrl+Z` / `Ctrl+Shift+Z` 撤销重做、`Ctrl+A` 全选、`Ctrl+D` 复制选中、`方向键` 微调 1px（Shift 10px）。 |
| C11 | 卡片吸附：拖到离网格 6px 内自动对齐网格（20px）；拖到与另一张卡片边缘差 < 8px 时对齐边缘。 |
| C12 | 「适应窗口」`Ctrl+Shift+H`：把全部内容装进视口并居中。 |
| C13 | 自动保存：改动后 300ms 落盘（`AtomicFileWriter.replace`），不做成功提示。 |
| C14 | 文件卡片：卡片引用库里的一篇笔记（`type: "file"`），显示标题 + 摘要，双击跳转到那篇笔记。 |
| C15 | 链接卡片：`type: "link"`，显示标题 + 域名，双击用系统浏览器打开。 |
| C16 | 分组节点（`type: "group"`）：一个大矩形框住若干卡片，可加标题；拖动分组带走里面的卡片。 |

### 1.2 不做（本期明确不碰，避免扩张）

- ❌ **网页卡片内嵌真实网页**（Obsidian 用 webview）。Flutter 桌面端要引 `webview_flutter`，还要处理进程崩溃、CSP、登录态。一期只显示标题 + 域名 + 外链打开。
- ❌ **卡片的完整 Markdown 渲染**。一期：纯文本 + 行内样式（粗体/斜体/代码/链接/标签），图片、表格、代码块二期。
- ❌ **多块白板同时开**（多页签）。一期白板是**单实例主区视图**，切白板等于换文件。理由见 §8.2。
- ❌ **移动端 / 触屏双指手势**。桌面优先。
- ❌ 协作、版本历史、导出图片 / PDF。

### 1.3 与已有功能的关系

- 白板**不是笔记**：不进 `_openIds`、不进 `allNotes`、不参与关系图谱抽边、不进回收站（一期）。
- 白板**引用**笔记：文件卡片存的是笔记的 `relativePath`（`Note.relativePath`），笔记改名/移动后卡片会失效——一期只在打开白板时提示「N 张卡片指向的笔记不存在」，不做自动重写（见 §12 风险）。

---

## 2. 交互规格

### 2.1 平移 / 缩放（**待确认，见 §13.3**）

| 操作 | 行为 |
|---|---|
| 拖空白 | **框选**（虚线框） |
| 中键拖 / 空格 + 左键拖 | 平移 |
| 滚轮 | 上下平移；`Shift` + 滚轮 → 左右平移 |
| `Ctrl` + 滚轮 | 以光标为锚点缩放 |
| 触控板双指 | 平移；捏合 → 缩放 |
| 双击空白 | 新建文字卡片 |
| 右键空白 | 菜单：新建卡片 / 粘贴 / 适应窗口 |

> 之所以「拖空白 = 框选」而不是平移：白板的主要动作是**整理内容**，不是浏览。
> 平移交给滚轮和中键，符合 Figma / Miro 的习惯。若你更习惯 Obsidian 那种
> 「拖空白 = 平移」，改成平移只需把框选挂到 `Shift` 上，是一行判断。

### 2.2 卡片

| 操作 | 行为 |
|---|---|
| 单击卡片 | 选中（边框变 accent，显示八向手柄） |
| 双击卡片 | 进入编辑（`TextField` 覆盖在卡片上，字号随缩放走） |
| 拖动卡片本体 | 移动；多选时整组移动 |
| 拖手柄 | 缩放；四角保比例（按 `Shift` 反向：自由缩放） |
| 选中时按 `Delete` | 删除卡片，同时删掉连着它的边 |
| 右键卡片 | 菜单：换色 / 复制 / 删除 / 置顶置底 |
| 卡片右上角 | 悬停时出现一个「⋯」菜单入口（与右键同功能） |

### 2.3 连线

| 操作 | 行为 |
|---|---|
| 悬停卡片 | 四边中点浮出四个小圆点（半径 5px） |
| 从圆点拖出 | 一条跟随光标的贝塞尔；落点合法时目标卡片描边高亮 |
| 松手在卡片上 | 建边，`fromSide` = 出发圆点所在边 |
| 松手在空白 | 取消 |
| 单击边 | 选中边（变粗 + 端点圆点） |
| 双击边 | 编辑边标签（一行文字，居中压在线上，带底色描边） |
| 选中边按 `Delete` | 删除边 |

### 2.4 键盘

| 键 | 行为 |
|---|---|
| `Delete` / `Backspace` | 删除选中的卡片和边 |
| `Ctrl+Z` / `Ctrl+Shift+Z` | 撤销 / 重做 |
| `Ctrl+A` | 全选 |
| `Ctrl+C` / `Ctrl+V` | 复制 / 粘贴（粘贴到光标处，偏移 +20,+20） |
| `Ctrl+D` | 原地复制（偏移 +20,+20） |
| `方向键` | 微调 1px；`Shift` 10px |
| `Ctrl+0` | 缩放回 100% |
| `Ctrl+Shift+H` | 适应窗口 |
| `Esc` | 退出编辑 / 取消选中 |
| `Ctrl+Shift+B` | 打开白板（全局快捷键，见 §8.3） |

---

## 3. 视觉规格

### 3.1 画布

| 元素 | 值 |
|---|---|
| 背景 | `p.canvas`（和左栏最深处同一级，白板是「凹陷的工作台」） |
| 点阵 | 点半径 1.1px，间距 20px（世界坐标），`p.textPrimary` @ 8%（深色）/ 12%（浅色） |
| 网格淡出 | `zoom < 0.35` 时整体透明度 → 0；`zoom > 2` 时间距翻倍显示，避免过密 |
| 选区框 | 1px 虚线 `p.accent` @ 70%，内部填充 `p.accentSoft` @ 40% |

### 3.2 卡片

| 元素 | 值 |
|---|---|
| 圆角 | `AppRadius.md`（7px） |
| 默认底色 | `p.surfaceRaised` |
| 边框 | 1px `p.outline`；选中时 1.5px `p.accent` |
| 阴影 | `p.shadow`，blur 12 / offset (0,2)；选中时 blur 20 |
| 内边距 | 12px |
| 文字 | `AppText.ui`（13px），`p.textPrimary`，行高 1.6 |
| 最小尺寸 | 40 × 40；新建卡片默认 250 × 120 |
| 缩放手柄 | 6×6 圆点，`p.accent` 实心 + 1px `p.surface` 描边；只在选中或悬停时画 |

### 3.3 六种预设色

JSON Canvas 的 `color` 是 `"1"`–`"6"` 或十六进制，且规范**故意不定义**这六个值具体是什么色。
我们的映射（`"3"` 是黄、`"5"` 是青，这两点最容易记错）：

| JSON Canvas | 语义 | 落到项目色名（`table_colors.dart`） |
|---|---|---|
| `"1"` | red 红 | `red` |
| `"2"` | orange 橙 | `amber` |
| `"3"` | yellow 黄 | `amber`（撞色，见下） |
| `"4"` | green 绿 | `green` |
| `"5"` | cyan 青 | `blue` |
| `"6"` | purple 紫 | `purple` |
| 不写 | — | `gray` |

**关于 `"2"` 和 `"3"` 撞到同一个 `amber`**：项目只有六个色名（灰/琥珀/绿/蓝/紫/红），
没有独立的「橙」和「黄」。两个按钮看起来接近，但**存的是 `"2"` / `"3"` 这两个规范值**，
信息不会丢——读回来还是原来那个。要彻底分开有两个选择，二期再定：
(a) 给 `"3"` 用 `amber` 的更亮一档；(b) 加一个自定义色（JSON Canvas 允许写 `#RRGGBB`）。

卡片换色时，**卡片底色 = 该色的 `tableFillColor`，边框 = `tableInkColor` @ 45%**。
这样深色主题下是深底亮边，浅色主题下是浅底深边，不用为两套主题各写一份。

### 3.4 连线

| 元素 | 值 |
|---|---|
| 线宽 | 2px（世界坐标），选中 2.8px |
| 颜色 | 未设色 → `p.outline` @ 100%；设色 → 对应预设色 |
| 形状 | 三次贝塞尔，控制点沿端点法线伸出 `min(96, 距离 × 0.4)` |
| 箭头 | `toEnd` 默认就是 `"arrow"`（规范如此），`"none"` 才不画；`fromEnd` 默认 `"none"`。三角边长 10px，颜色同线 |
| 标签 | 11.5px，`p.textSecondary`，居中压线，背后 3px 画布色描边（`labelHalo` 的做法，和图谱一致） |

---

## 4. 数据层 · `lib/core/utils/canvas_document.dart`（新增）

### 4.1 为什么严格照 JSON Canvas 1.0

Obsidian 的白板文件就是 JSON Canvas，公开规范、字段少、语义清晰。照抄有三个好处：

1. 用户在 Obsidian 里画的白板能直接拖进库里用；
2. 反过来也能拿去 Obsidian 打开；
3. 不用自己发明格式，省掉一轮设计评审。

### 4.2 结构

```dart
/// 一个白板文件。字段与 JSON Canvas 1.0 一一对应，不多不少。
class CanvasDocument {
  final List<CanvasNode> nodes;
  final List<CanvasEdge> edges;

  /// 规范之外的键原样保留——用户在 Obsidian 里用的新字段不能被我们吃掉。
  final Map<String, Object?> extra;
}

sealed class CanvasNode {
  final String id;
  final double x, y, width, height;
  final String? color;          // "1".."6" 或 "#RRGGBB"
  final Map<String, Object?> extra;
}

class TextNode  extends CanvasNode { final String text; }
class FileNode  extends CanvasNode { final String file; final String? subpath; }
class LinkNode  extends CanvasNode { final String url; }
class GroupNode extends CanvasNode { final String? label; final String? background; final String? backgroundStyle; }

class CanvasEdge {
  final String id;
  final String fromNode, toNode;
  final String? fromSide, toSide;   // top|right|bottom|left，null = 自动
  final String? fromEnd, toEnd;     // none|arrow
  final String? color;
  final String? label;
  final Map<String, Object?> extra;
}

CanvasDocument parseCanvas(String json);      // 容错，见 4.4
String encodeCanvas(CanvasDocument doc);      // 键顺序稳定，便于 diff
```

### 4.3 规范里三个容易写错的地方（已核对 jsoncanvas.org/spec/1.0）

1. **`toEnd` 默认是 `arrow`，`fromEnd` 默认是 `none`。** 两个默认值**不一样**。
   所以 `toEnd` 为 `null` 时按 `arrow` 画，`fromEnd` 为 `null` 时按 `none` 画。
   写反了会导致「每条边都没有箭头」，或者「每条边两头都有箭头」。
2. **`x/y/width/height` 在规范里是 integer（像素）。**
   内部用 `double` 保证拖拽平滑，**落盘时 `round()`**。既符合规范，也不会因为
   拖动产生 `249.99999` 这种垃圾值把文件搞脏。
3. **节点数组顺序就是 z-index**：第一个在最底层，最后一个在最上层。
   所以命中测试必须**倒序**遍历，绘制必须**正序**遍历。

另外：`subpath` 必须 `#` 开头；`backgroundStyle` 只能是 `cover|ratio|repeat`；
规范的预设色**故意不定义具体色值**，由各应用自定（所以下面 §3.3 的映射是我们自己的选择）。

y 轴方向规范**没有规定**。实践上（Obsidian 的输出）y 向下增长，我们照这个来。

### 4.4 键顺序与格式

`encodeCanvas` 用 `JsonEncoder.withIndent('  ')`，键按固定顺序写（`id`、`type`、`x`、`y`、
`width`、`height`、`color`，再按类型追加）。理由：白板文件会进 git，
键顺序抖动会让每次保存都产生整文件 diff。

### 4.5 容错（必须有测试）

| 坏输入 | 处理 |
|---|---|
| 整个文件不是 JSON | 抛 `CanvasFormatException`，UI 提示「这个文件不是合法的白板」，**不覆盖原文件** |
| `nodes` / `edges` 缺失 | 当作空数组 |
| 节点缺 `id` | 生成 16 位十六进制 id（与 Obsidian 同长度） |
| 节点缺 `x/y/width/height` | 默认 `0/0/250/120` |
| `width/height ≤ 0` | 抬到最小值 40 |
| 坐标是小数 | 读入时保留，保存时 `round()` |
| `type` 不认识 | 跳过该节点（连同引用它的边），**不报错**——Obsidian 未来加类型时我们不该炸 |
| 边引用不存在的节点 | 丢弃该边 |
| `fromNode == toNode` | 丢弃该边（自环） |
| 同一对节点多条边 | **保留**（规范允许，每条边是独立的） |
| `color` 是非法值 | 当 `null` |
| `fromSide` / `toSide` 非法 | 当 `null`（走自动选边） |
| `fromEnd` / `toEnd` 非法 | 当默认值（`none` / `arrow`） |

### 4.6 id 生成

`String canvasId()`：16 位小写十六进制，`Random.secure()`。测试里注入固定种子。

---

## 5. 存储层 · `lib/data/storage/canvas_store.dart`（新增）

### 5.1 为什么不塞进 `NoteStore`

`NoteStore` 的每个方法都以 `Note` 为参数（`save(Note)`、`delete(Note)`、`stampOf(relativePath)`…）。
白板不是 `Note`，硬塞进去会让 `NoteStore` 的每个实现（io / web）都多一堆 `if`。
新开一个窄接口更干净：

```dart
abstract class CanvasStore {
  Future<void> init();
  String get location;

  /// vault 里所有 `.canvas` 的相对路径（相对 vault 根，正斜杠）。
  Future<List<String>> list();

  Future<String?> read(String relativePath);
  Future<void> write(String relativePath, String json);

  Future<bool> exists(String relativePath);
  Future<void> createFolder(String folderPath);   // 新建白板要落盘
}
```

- **io 实现**：复用 `NoteStoreIo` 的 `_walk` 思路，但只收 `.canvas`；跳过 `assets`、
  `.trash`、`.history`（与 `NoteStoreIo` 的 `skipDirectories` 同一批）。
- **写入**：`AtomicFileWriter.replace(file, json)`——已有实现，先写 `.tmp` 再 rename。
- **web 实现**：沿用 `NoteStoreWeb` 的存储键前缀（`nrs:file:` 之类），具体键名对齐现有实现。

### 5.2 文件放哪（**待确认，见 §13.1**）

提案：白板就是普通文件，可以放在 vault 里任何文件夹，扩展名 `.canvas`。
新建时的默认位置 = **当前笔记所在文件夹**；没有当前笔记 → vault 根目录。
文件名 = `白板` + 若重名则 `白板 2`、`白板 3`……

> 不建专门的 `白板/` 目录：Obsidian 里 canvas 和笔记是同级的普通文件，
> 用户会自己按项目分文件夹。强行分目录会让「同一个项目的笔记和白板不在一起」。

### 5.3 自动保存

- 每次改动（拖完、改完文字、换色、连线）→ `Debouncer(300ms)` → `write`。
- 关掉白板 / 切走前 `flush()`，不等防抖。
- 写入失败：底部 toast 报错（**失败才提示**，成功不提示——项目硬约束）。
- 不做「脏」标记进标题，Obsidian 也不做。

---

## 6. 渲染层 · 为什么用 Widget 画卡片

### 6.1 结论：混合

| 层 | 技术 | 理由 |
|---|---|---|
| 点阵网格 | `CustomPainter`（最底） | 纯线条，Widget 做不了 |
| 连线 | `CustomPainter`（网格之上、卡片之下） | 纯曲线 + 箭头；被卡片遮住是对的 |
| 卡片 | **Widget**（`Positioned` + `Transform`） | 要能选中文字、要能用 `TextField` 编辑、要能显示图片 |
| 手柄 / 选框 / 悬停圆点 | `CustomPainter`（最上） | 只在选中时画，不进语义树 |

### 6.2 为什么不用「一个 CustomPainter 画所有卡片」

编辑器的 `RenderLineEditable` 是按行自绘的，看着像可以复用，但它绑定了
`TextEditingController` + 光标 + IME + 选区，塞进一张 250×120 的小卡片里，
焦点、滚动、IME 候选框定位全要重做。**卡片用真 Widget，编辑用真 `TextField`**，
这些问题一个都不用解决。

代价是卡片多了以后 Widget 树重。对策（P5 再做，一期先不做）：
**视口裁剪**——只 build 与视口相交的卡片（留 200px 余量）。26 张卡片时完全不需要。

### 6.3 坐标变换（全局只有这一处）

```dart
// 世界 → 屏幕
Offset toScreen(Offset world) => world * _zoom + _offset;
// 屏幕 → 世界
Offset toWorld(Offset screen) => (screen - _offset) / _zoom;
```

与 `graph_view.dart` 的 `_toWorld` / `_offset` 完全同构，**不要发明第二套**。

卡片 Widget 的摆放：

```dart
Positioned(
  left: node.x * zoom + offset.dx,
  top:  node.y * zoom + offset.dy,
  width:  node.width * zoom,
  height: node.height * zoom,
  child: CardSurface(...),   // 内部字号 × zoom
)
```

> 为什么不用 `Transform.scale` 包整个 Stack：那样卡片内的 `TextField` 光标、
> 命中测试、`MediaQuery` 都得反算，坑比收益多。逐张算位置，字号乘 `zoom`，
> 结果一样，代码简单得多。
> **例外**：`zoom < 0.4` 时不渲染卡片内容，只画一个色块——字太小已是噪点，
> 还能顺带把这一档的性能救回来。

### 6.4 视口变换的边界

- `zoom ∈ [0.1, 4.0]`。
- `offset` 不做边界限制（无限画布）。
- 缩放以光标为锚点：`offset = cursor - (cursor - offset) * k`（与 `_zoomAt` 同一行公式）。

---

## 7. 交互层

### 7.1 指针事件的归属

白板的指针处理**不能**用一堆嵌套 `GestureDetector`——卡片、手柄、连线圆点、空白，
四类目标互相抢手势，最后会变成「拖卡片时画布跟着平移」这种经典 bug。

做法：**一层 `Listener` 收全部原始指针事件**，自己做命中测试和状态机：

```
idle ──down on 手柄──→ resizing
     ──down on 卡片──→ maybeDrag ──move>3px──→ dragging
     ──down on 边圆点→ connecting
     ──down on 边────→ maybeSelectEdge
     ──down on 空白──→ marquee（或 panning，看修饰键）
```

和 `graph_view.dart` 的 `_onPointerDown/Move/Up` 是同一套路子，照抄即可。

### 7.2 命中测试

从**上到下**依次问，第一个命中的赢：

1. 缩放手柄（选中卡片的 8 个，容差 8px / zoom）
2. 连线端点圆点（悬停卡片的 4 个）
3. 边（点到贝塞尔的最近距离 < 6px / zoom —— 用二次采样 20 段折线近似，够准且便宜）
4. 卡片（矩形，后画的在上，所以**倒序**遍历）
5. 空白

### 7.3 贝塞尔控制点

```dart
/// 从卡片某条边伸出，方向沿该边法线。
Offset controlPoint(CanvasNode n, String side, Offset toward) {
  final Rect r = n.rect;
  final Offset anchor = switch (side) {
    'top'    => r.topCenter,
    'bottom' => r.bottomCenter,
    'left'   => r.centerLeft,
    _        => r.centerRight,
  };
  final Offset dir = switch (side) {
    'top'    => const Offset(0, -1),
    'bottom' => const Offset(0, 1),
    'left'   => const Offset(-1, 0),
    _        => const Offset(1, 0),
  };
  final double reach = math.min(96, (toward - anchor).distance * 0.4);
  return anchor + dir * reach;
}
```

`fromSide` / `toSide` 为 `null` 时自动选：算四个锚点到对方矩形中心的距离，取最近的那个。

### 7.4 吸附

拖动结束（`pointerUp`）时一次性吸附，拖动过程中**不吸**——过程中吸会让人感觉「拽不动」。

- 网格：`x` / `y` 各自就近取 20 的倍数，若偏差 < 6px 则吸。
- 边缘对齐：对每张其他卡片，若 `|x - other.x| < 8` 或 `|x + w - (other.x + other.w)| < 8` 则对齐，
  并画一条贯穿视口的辅助线（`p.accent` @ 40%，1px）。

### 7.5 撤销 / 重做

白板**不复用**编辑器的撤销栈（那套是绑在 `TextEditingController` 上的）。

自己维护一个快照栈：

```dart
class CanvasHistory {
  final List<String> _snapshots = <String>[];   // 存 encodeCanvas 的结果
  int _cursor = -1;

  void push(CanvasDocument doc) { ... }   // 同类操作 300ms 内合并
  bool get canUndo => _cursor > 0;
  CanvasDocument? undo() { ... }
}
```

- 存**序列化后的字符串**而不是对象：白板不大（典型 < 100KB），存字符串省掉深拷贝的正确性问题。
- 栈上限 50 步。
- 合并规则：连续的拖动（同一批选中、间隔 < 300ms）算一步；连续输入算一步。

### 7.6 编辑态

双击卡片 → 卡片上盖一个 `TextField`（`maxLines: null`，`expands`），
`autofocus`，`Esc` / 点外部提交。提交时写回 `TextNode.text` 并 push 一次历史。

**不做**实时双向同步：编辑中不往文档写，避免每敲一个字都触发自动保存和历史。

---

## 8. 状态与接线

### 8.1 状态放哪

```dart
class CanvasController extends ChangeNotifier {
  CanvasDocument? _doc;
  String? _path;                 // 相对 vault 的 .canvas 路径
  final Set<String> _selected;   // 选中的 node id + edge id
  final CanvasHistory _history;
  double zoom = 1;
  Offset offset = Offset.zero;

  Future<void> open(String relativePath);
  Future<void> createNew(String folderPath);
  void mutate(void Function(CanvasDocument) f);   // 改完自动 push 历史 + 触发保存
  Future<void> flush();
}
```

挂在 `app_shell` 的 `MultiProvider` 上（和 `NotesController` 平级），**不放进 `NotesController`**：
白板不参与笔记的任何索引（`allNotes` / 标签 / 图谱 / 大纲）。

### 8.2 为什么一期只开一块白板

页签列表 `NotesController._openIds` 是 `List<String>`，每处使用都假设「id 是一篇笔记」
（`notes.byId(id)`、`note.title`、`note.folderPath`…）。要支持「笔记页签 + 白板页签」混排，
得把它泛化成 `List<DocTab>`，并同步改 `main.dart` 的 `saveSession(notes.openIds, ...)`
（会话恢复也得认得白板页签）。

**一期**：`MainView { note, graph, canvas }`，白板是**单实例主区视图**，页签固定一颗
（和现在的「图谱」一模一样）。切白板 = 换文件，不新开页签。
**二期**（若你确认要）：把页签泛化，白板像笔记一样多开。

### 8.3 功能栏按钮

`lib/ui/shell/function_rail.dart` 的 `AppRail`，在「插入模板」下面加一颗：

```dart
_RailButton(
  icon: LucideIcons.squareDashed,      // 虚线方框最像「画布」；备选 frame / layoutDashboard
  tooltip: '白板',
  shortcut: 'Ctrl+Shift+B',
  onPressed: onOpenCanvas,
),
```

点击行为：

```
有 .canvas 文件？
├─ 有  → 弹「打开白板」选择器（列表 + 「新建白板」按钮）
└─ 没有 → 直接在当前笔记的文件夹里新建一块，打开
```

选择器复用现有弹窗风格（`data_safety_dialogs.dart` 里的对话框是现成样板）。

### 8.4 主区接线

和 `GraphView` 完全同构，照抄那三处：

1. `MainView` 加 `canvas`；
2. `app_shell.dart` 的 `Stack` 里加第三个 `Offstage`，`_canvasOpened` 懒建；
3. `title_bar_content.dart` 页签条末尾，在「图谱」旁边加「白板」。

`Ctrl+Shift+B` 挂进 `app_shell` 的 `_globalShortcuts()`（`CallbackShortcuts`，`Ctrl+G` 就在那儿）。

### 8.5 与右侧三面板的关系

白板是**主区视图**，右侧面板（大纲 / 表格 / 图片）对它没有意义。
切到白板时：右侧面板保持原样但内容按「无当前笔记」处理（现有逻辑已经处理了
`selectedId == null` 的情况），不强行关闭——强行关闭会让用户切回笔记时发现面板没了。

---

## 9. 文件清单

| 文件 | 动作 | 说明 |
|---|---|---|
| `lib/core/utils/canvas_document.dart` | 新增 | 数据模型 + `parseCanvas` / `encodeCanvas` + 容错 |
| `lib/core/utils/canvas_geometry.dart` | 新增 | 坐标变换、贝塞尔控制点、命中测试、吸附（纯函数，好测） |
| `lib/data/storage/canvas_store.dart` | 新增 | 抽象接口 |
| `lib/data/storage/canvas_store_io.dart` | 新增 | 桌面实现（`.canvas` 枚举 + 原子写） |
| `lib/data/storage/canvas_store_web.dart` | 新增 | Web 实现 |
| `lib/state/canvas_controller.dart` | 新增 | 文档 + 选中 + 视口 + 历史 + 自动保存 |
| `lib/ui/canvas/canvas_board.dart` | 新增 | 主区画布：`Listener` 状态机、层叠、框选 |
| `lib/ui/canvas/canvas_grid_painter.dart` | 新增 | 点阵网格 |
| `lib/ui/canvas/canvas_edge_painter.dart` | 新增 | 连线 + 箭头 + 边标签 |
| `lib/ui/canvas/canvas_chrome_painter.dart` | 新增 | 手柄、选框、悬停圆点、对齐辅助线 |
| `lib/ui/canvas/canvas_card.dart` | 新增 | 单张卡片 Widget（只读态 + 编辑态） |
| `lib/ui/canvas/canvas_toolbar.dart` | 新增 | 悬浮工具条（缩放百分比 / 适应窗口 / 新建卡片） |
| `lib/ui/canvas/canvas_picker.dart` | 新增 | 「打开白板」选择器 |
| `lib/ui/shell/function_rail.dart` | 改 | 加白板按钮 |
| `lib/ui/shell/main_view.dart` | 改 | `MainView` 加 `canvas` |
| `lib/ui/shell/app_shell.dart` | 改 | 第三个 `Offstage` + 懒建 + `Ctrl+Shift+B` |
| `lib/ui/shell/title_bar_content.dart` | 改 | 页签条加「白板」 |
| `lib/ui/shell/title_bar_io.dart` / `title_bar_web.dart` | 改 | 同步参数 |

约 **11 个新文件 + 5 处改动**。比图谱（9 新 + 9 改）大，主要大在交互状态机。

---

## 10. 测试计划

### 10.1 `test/canvas_document_test.dart`（约 27 条）

| 组 | 条数 | 覆盖 |
|---|---|---|
| 解析 | 6 | 四类节点、边、缺省字段、空文档 |
| 序列化 | 5 | round-trip 全等、键顺序稳定、坐标落盘取整、`toEnd` 缺省补 `arrow`、缩进 |
| 未知字段 | 3 | 顶层 / 节点 / 边上的未知键都保留 |
| 容错 | 12 | 坏 JSON、缺 id、负宽高、小数坐标、未知 type、边引用不存在、自环、非法 color、非法 side、非法 end |
| id | 2 | 长度 16、十六进制 |

### 10.2 `test/canvas_geometry_test.dart`（约 18 条）

坐标往返、缩放锚点不变、贝塞尔控制点在正确的法线方向、命中测试优先级、吸附阈值边界。

### 10.3 `test/canvas_board_test.dart`（约 22 条，widget 测试）

| 组 | 条数 | 覆盖 |
|---|---|---|
| 打开 | 3 | 空白板给提示、有内容能画出来、缩放百分比显示 |
| 卡片 | 6 | 双击新建、拖动改坐标、八向缩放、最小尺寸、删除连带边、换色 |
| 连线 | 5 | 从圆点拖出建边、落空白取消、fromSide 正确、删除边、边标签 |
| 多选 | 4 | 框选、Shift 点选、整组拖动、全选删除 |
| 视图 | 4 | 滚轮缩放锚点、适应窗口、撤销重做、自动保存被调用 |

### 10.4 `test/canvas_store_test.dart`（约 8 条）

写入→读出、原子写（中途失败不留半个文件）、只枚举 `.canvas`、跳过 `assets` / `.trash`。

### 10.5 验证命令

```bash
flutter analyze lib test
flutter test test/canvas_document_test.dart test/canvas_geometry_test.dart \
             test/canvas_board_test.dart test/canvas_store_test.dart
flutter test --exclude-tags perf          # 全量回归
```

---

## 11. 分阶段落地

| 阶段 | 内容 | 可验证的东西 |
|---|---|---|
| **P0** | `canvas_document.dart` + 全部单测 | 纯 Dart，能拿 Obsidian 的真实 `.canvas` 文件做 round-trip |
| **P1** | `canvas_board.dart` + 网格 + 平移缩放 + 工具条 | 能开一块空白板、自由平移缩放 |
| **P2** | 卡片：新建 / 拖动 / 缩放 / 编辑 / 删除 / 换色 | 能做出一块「有卡片的白板」 |
| **P3** | 连线：圆点拖出 / 贝塞尔 / 箭头 / 边标签 | 能把卡片连起来 |
| **P4** | 文件卡片 + 链接卡片 + 分组节点 | 能引用笔记、放外链、框分组 |
| **P5** | 多选 / 吸附 / 撤销重做 / 复制粘贴 / 视口裁剪 | 手感成型 |
| **P6** | 落盘 + 自动保存 + Web 降级 + 选择器 | 关掉再打开，东西还在 |

每个阶段结束都跑一次 `flutter analyze` + 该阶段测试 + 全量回归。

---

## 12. 风险与应对

| 风险 | 应对 |
|---|---|
| 卡片多了 Widget 树重（>200 张） | P5 加视口裁剪；`zoom < 0.4` 时只画色块 |
| 手势互相抢（拖卡片时画布跟着动） | 单层 `Listener` + 显式状态机（§7.1），不用嵌套 GestureDetector |
| 与 Obsidian 互操作出岔子 | P0 用 Obsidian 导出的真实 `.canvas` 做夹具（含 group / 颜色 / 边标签），round-trip 必须全等 |
| 笔记改名后文件卡片失效 | 一期：打开时统计失效卡片并在工具条上标一个警告点；二期做按标题重解析 |
| 撤销栈吃内存 | 存字符串 + 上限 50 步；白板典型 < 100KB，50 步 < 5MB |
| 自动保存和撤销打架 | 只在 `mutate()` 之后保存，撤销/重做本身也是一次 `mutate()` |
| Web 端持久化容量 | 沿用 `NoteStoreWeb` 的配额错误处理（已有实现） |

---

## 13. 待你确认（5 个问题）

### 13.1 白板文件放哪？

- **A（推荐）**：就是普通文件，能放在 vault 任意文件夹；新建时默认落在**当前笔记的文件夹**。
- B：统一放 `白板/` 目录。

### 13.2 一期要不要「把笔记拖进白板」？

- **A（推荐）**：要。`type: "file"` 是白板最有价值的玩法（把几篇笔记摆在一起看）。
- B：一期只做文字卡片，二期再加。

### 13.3 空白处左键拖动 = 框选还是平移？

- **A（推荐）**：框选。平移交给滚轮 / 中键 / 空格。
- B：平移（更像 Obsidian 的默认手感），框选挂到 `Shift`。

### 13.4 多选后的对齐 / 分布工具，一期做吗？

- A：不做（P5 只做吸附）。
- **B（推荐）**：不做，二期。白板初期用不上。

### 13.5 是否严格要求 JSON Canvas 兼容？

- **A（推荐）**：是。未知字段原样保留，坏数据不覆盖原文件。
- B：只要能读能写，不追求逐字节一致。

---

## 14. 验收清单

- [ ] 功能栏点「白板」能新建 / 打开；`Ctrl+Shift+B` 同样有效
- [ ] 空白处拖 = 框选；滚轮平移；`Ctrl`+滚轮以光标为锚点缩放
- [ ] 双击空白出卡片，直接能打字；`Esc` 退出编辑
- [ ] 拖动卡片、八向缩放、最小 40×40、松手吸附网格
- [ ] 从卡片圆点拖到另一张卡片能建边；边有箭头和标签；选中能删
- [ ] 多选整组拖动；`Ctrl+A` 全选；`Delete` 删除并连带删边
- [ ] `Ctrl+Z` / `Ctrl+Shift+Z` 能一路退回去再走回来
- [ ] 关掉白板再打开，坐标、颜色、连线、标签一个不差
- [ ] 拿一个 Obsidian 里做的 `.canvas` 放进来，能正确显示；改完再拿回 Obsidian 能打开
- [ ] 浅色 / 深色主题下都读得清（卡片底色、连线、网格）
- [ ] 空白板、单卡片、200 卡片三种极端输入都不卡不崩
