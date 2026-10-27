# 白板（Canvas）· 架构与实施方案

> 状态：**已实现并验收通过（2026-10-27 重构完成；同日二轮视觉换成 graphif 风，见 §14.3）**。
> `flutter analyze lib test` 无问题，`flutter test --exclude-tags perf` **1483 条全绿**，
> 其中白板相关 **201 条**。
> 目标：在 nrs-v5 里做一块**无限画布**白板。文件后缀 **`.nrs`**，内容是我们自己的 **NRS v1** 格式。
> 面向：接手的实施 AI / 工程师。文中路径均对应仓库 `c:\Users\Kotori\Desktop\nrs-v5`。

---

## 0. 一句话

白板是一块**坐标化**的无限画布：摄像机（世界中心 + 缩放）决定看到哪一块，
所有内容都画在**世界坐标系**里，整块画布只有**一个 `CustomPaint`**，
节点、文字、连线、手柄全部 Dart 自绘；所有东西存成一个 `.nrs` 文件。

---

## 1. 本轮重构做了什么（旧 → 新）

| 维度 | 旧实现 | 新实现 |
|---|---|---|
| 视口 | `CanvasViewport(offset, zoom)`：屏幕左上角对应的世界坐标 | `CanvasCamera(center, zoom)`：**画面正中央**对准的世界坐标（对齐 Project Graph 的 Camera） |
| 缩放 | 立即生效，无过渡 | **逐帧指数逼近**目标缩放；光标（或画面中心）为锚点；`fit` / 适应窗口走 240ms `easeOutCubic` 缓动 |
| 平移 | 滚轮 / 中键 / 空格 | **中键拖 / 空格拖 / WASD 惯性平移**（加速 + 摩擦滑停）；滚轮改做缩放 |
| 卡片 | 每张卡片一个 `Positioned` Widget | **全部自绘**：只有一个 `CustomPaint`，没有卡片 Widget / 布局 / 命中重叠 |
| 数据坐标 | 松手吸附网格（20px）+ 边缘对齐 | **自由浮点坐标**，不吸附、不对齐 |
| 分组 | 拖动分组跳过其他分组 | 按几何包含关系带走子节点，**支持嵌套** |
| 文件格式 | 「后缀 `.nrs`，内容照 JSON Canvas 1.0」 | **NRS v1**：`version: 1`、边用 `from`/`to`、分组只留 `label`；旧数据不迁移 |
| 文字编辑 | 卡片 Widget 内含 `TextField` | 自绘显示；编辑时在卡片位置盖一个真 `TextField` 浮层（保住 IME / 光标 / 选区） |
| 拆分画笔 | `canvas_grid_painter` / `canvas_edge_painter` / `canvas_card` | 合并为 `canvas_painter.dart`（三个文件已删除） |

摄像机**不落盘**：`.nrs` 只存内容。打开文件时自动按内容包围盒适应窗口。

---

## 2. 范围

### 2.1 做

| # | 行为 |
|---|------|
| C1 | 功能栏多一颗「白板」按钮：**直接新建**一块 `.nrs` 并切过去 |
| C2 | 主区多一个「白板」视图，与「图谱」并列在页签条末尾（单实例） |
| C3 | 平移：中键拖 / 空格 + 左键拖 / `WASD`；缩放：**滚轮**（往上放大、往下缩小，以光标为锚点，平滑过渡） |
| C4 | 坐标网格随缩放走 1/2/5 阶梯（屏幕步长恒在 64–640px），上 / 左两条标尺带写整数刻度 |
| C5 | 双击空白 = 新建文字卡片，直接进入编辑（卡片中心落在双击处） |
| C6 | 卡片可拖动、八向缩放（四角 + 四边中点），最小 40×40，默认 250×120 |
| C7 | 六种预设色（`"1"`–`"6"`），右键菜单换色 |
| C8 | 从卡片四边中点圆点拖出落到另一张卡片 = 建边；贝塞尔曲线，可带箭头与文字标签 |
| C9 | 框选（拖空白）、`Ctrl` 点选、多选整组拖动 / 删除 |
| C10 | 键盘：`Delete` / `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` / `Ctrl+A` / `Ctrl+C` / `Ctrl+V` / `Ctrl+D` / 方向键微调 / `Ctrl+0` / `Ctrl+Shift+H`；视野：`[` `]` / `PageUp` `PageDown` / `Home` `End` / `F` |
| C11 | **不吸附**：坐标是自由浮点，落盘只压三位小数 |
| C12 | 「重置视野」（`F`）：没选中 = 按全部内容包围盒自适应并居中；有选中 = 只框住选中那一块 |
| C13 | 自动保存：改动后 900ms 防抖落盘；切走 / 关闭前 `flush()` |
| C14 | 文件卡片 `type: "file"`：显示标题 + 路径，双击打开那篇笔记 |
| C15 | 链接卡片 `type: "link"`：显示标题 + 域名，双击用系统浏览器打开 |
| C16 | 分组 `type: "group"`：底板框住若干卡片，可加标题；拖动带走框内卡片，支持嵌套 |

### 2.2 不做

- ❌ 网页卡片内嵌真实网页（只显示标题 + 域名 + 外链打开）。
- ❌ 卡片内的完整 Markdown 渲染（一期纯文本 + 基础行内样式）。
- ❌ 多块白板同时开（多页签）。白板是单实例主区视图。
- ❌ 移动端 / 触屏双指手势。
- ❌ 吸附 / 对齐辅助线 / 分布对齐（本轮明确删掉）。
- ❌ 协作、版本历史、导出图片 / PDF。
- ❌ **旧格式迁移**：`.nrs` 直接一步到位换成 NRS v1（用户确认没有旧数据）。

### 2.3 与已有功能的关系

- 白板**不是笔记**：不进 `_openIds`、不进 `allNotes`、不参与关系图谱与大纲。
- 删除白板进回收站（和笔记共用 `.nrs-trash/`）；恢复是把文件搬回原位。
- 文件卡片存笔记的 `relativePath`；笔记改名 / 移动后卡片失效，本期不做自动重写。
- 删文件夹时若还有白板，提示「文件夹里还有 N 块白板」（`NotesController.canvasCountOf`）。

---

## 3. 坐标模型 · `CanvasCamera`

### 3.1 定义

```dart
class CanvasCamera {
  const CanvasCamera({this.center = Offset.zero, this.zoom = 1});

  /// 画面正中央对准的**世界坐标**。
  final Offset center;
  final double zoom;

  /// 只有数值下限（挡 0 / Infinity），**没有上限**：放到多少倍都行。
  static const double minZoom = 1e-6;

  /// 适应窗口时四周留的空白（屏幕像素）。
  static const double fitPadding = 90;
}
```

全局只有这一套换算：

```
screen = (world - center) * zoom + stage.center
world  = (screen - stage.center) / zoom + center
```

配套纯函数（全部可单测）：

| 方法 | 语义 |
|---|---|
| `stageCenter(stage)` | 舞台中心 `Size / 2` |
| `toScreen` / `toWorld` | 点换算 |
| `rectToScreen` / `rectToWorld` | 矩形换算 |
| `visibleWorld(stage)` | 当前可见的世界矩形（画笔裁剪 / 测试探针用） |
| `pannedBy(delta)` | `center -= delta / zoom`（内容跟手） |
| `movedTo(next)` | 只改中心 |
| `zoomedAt(screenAnchor, factor, stage)` | 以屏幕点为锚点按比例缩放，**锚点下的世界坐标不动** |
| `withZoomAt(screenAnchor, value, stage)` | 同上，直接给目标缩放值（避免 `zoom * (1/zoom)` 的浮点误差） |
| `fit(content, stage, padding)` | 内容包围盒装进舞台并居中；空内容退化为「中心对准原点」，舞台为 0 不炸 |

`CanvasCamera` 实现了 `==` / `hashCode`（画笔 `shouldRepaint` 与测试断言都依赖它）。

### 3.2 平滑缩放

- 滚轮只改 `_targetZoom`（只有下限 `1e-6`，**不设上限**）并记录 `_zoomAnchor`；`Ticker` 每帧：

  ```
  zoom += (target - zoom) * (1 - exp(-dt * 18))
  ```

  每一步都走 `withZoomAt(anchor, zoom)`，所以**整个过程**锚点都不漂。
- `Ctrl+0` 也走同一条路径（锚点 = 舞台中心）。
- `fitToContent` 与打开文件的自适应走 `_CameraTween`（center + zoom 同时插值，240ms，`easeOutCubic`）。
- 空闲时（无缩放差、无 tween、无惯性、无按键）`_ticker.stop()`，不空转。

### 3.3 WASD 惯性平移

| 参数 | 值 |
|---|---|
| 加速度 | 2600 px/s² |
| 速度上限 | 2200 px/s |
| 摩擦 | `v *= exp(-dt * 5.5)` |
| 停止阈值 | `|v| < 6` |

方向由按住的键合成（`W/S` 纵向、`A/D` 横向），对角线归一化；松手后不带按键时仍按摩擦滑停。

---

## 4. 交互规格

### 4.1 指针

| 操作 | 行为 |
|---|---|
| 拖空白 | **框选**（虚线框，存的是**世界坐标**：平移 / 缩放时框贴着内容走） |
| 中键拖 / 空格 + 左键拖 | 平移 |
| 滚轮 | **缩放**：往上放大、往下缩小，以光标为锚点（目标 `zoom × exp(-dy / 320)`） |
| 双击空白 | 新建文字卡片并进编辑 |
| 右键空白 | 菜单：新建卡片 / 粘贴 / 适应窗口 |

### 4.2 卡片

| 操作 | 行为 |
|---|---|
| 单击卡片 | 选中（外圈 accent 粗描边 + 八向手柄） |
| `Ctrl` + 单击 | 加选 / 减选 |
| 双击卡片 | 文字 / 分组 → 进编辑；文件 / 链接 → 打开 |
| `Ctrl` + 双击卡片 | **打开详细信息面板**（任何类型的卡片都一样，文件/链接看到的是路径/网址） |
| 点选中卡片右上角的小图标 | 同上（那个小图标骑在右上角上，一半在卡片外） |
| `Enter`（单选时） | 进编辑（文件 / 链接卡片没有可编辑文字，不响应） |
| 拖动卡片本体 | 移动（多选时整组）；**不吸附** |
| 拖手柄 | 缩放；最小 40×40，撞到最小尺寸时对面边不动 |
| `Delete` | 删除选中卡片，连带删掉它的边 |
| 右键卡片 | 换色 / 复制 / 删除 / 置顶置底 |
| 悬停卡片 | 四边中点浮出四个连线圆点；右侧出现「⋯」 |

### 4.2.1 浮层（搜索 / 详细信息）

两个浮层都画在画布的 `Stack` 里，指针落上去时 `_onPointerDown` 提前返回，
**不传给底下的画布**——否则点搜索框会清掉选中，点面板里的输入框会把正在
编辑的卡片收掉。

| 浮层 | 位置 | 行为 |
|---|---|---|
| 搜索（`Ctrl+F`） | 上边标尺下方、水平居中，360×42 | 边打边跳：命中第一张就选中并把镜头移过去（只移不改缩放）。`Enter` 下一个、`Shift+Enter` 上一个（循环）、`Esc` 关掉 |
| 详细信息 | 默认贴舞台右下角，296×352 | 文字 / 颜色 / X / Y / 宽 / 高；**右下角握把能拖大小**（240–620 × 220–720）。`Esc` 关掉 |

面板**没有自己的目标节点**：它永远显示当前那一张单选，选中没了就收起。
比再存一个 id 再去各处同步省事，也不会出现「面板显示的是上一张卡」。

### 4.3 连线

| 操作 | 行为 |
|---|---|
| 从圆点拖出 | 跟随光标的贝塞尔预览 |
| 松手在卡片上 | 建边，`fromSide` = 出发圆点所在边 |
| 松手在空白 / 自己身上 | 取消（不建自环） |
| 单击边 | 选中（变粗 + 端点圆点） |
| 双击边 | 编辑标签（一行文字，居中压线，带底色描边） |
| 选中边按 `Delete` | 只删边 |

### 4.4 键盘

| 键 | 行为 |
|---|---|
| `Delete` / `Backspace` | 删除选中的卡片和边 |
| `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` | 撤销 / 重做 |
| `Ctrl+A` | 全选 |
| `Ctrl+C` / `Ctrl+V` | 复制 / 粘贴（偏移 +20,+20） |
| `Ctrl+D` | 原地复制 |
| `方向键` | 微调 1px；`Shift` 10px |
| `Ctrl+0` | 缩放回 100%（以画面中心为锚点） |
| `Ctrl+Shift+H` | 适应窗口 |
| `Ctrl+F` | 打开搜索框（见 §4.2.1） |
| `Ctrl+Enter` | 打开详细信息面板 |
| `Enter` | 单选时进编辑（分组标题是单行，编辑中按 `Enter` 就是「改完了」） |
| `Ctrl+=` / `Ctrl+-` | 选中卡片**调字号**（`canvasResizeStep` = 1.25，**锚在中心**，不会往右下角爬）。文字卡片随之重新贴合，看起来是整张卡变大；**没有上下限** |
| `Esc` | 退出编辑 / 关浮层 / 清空选择 |
| `空格`（按住） | 抓手模式 |
| `W/A/S/D` | 惯性平移 |
| `PageUp` / `PageDown` | 视野上 / 下翻一屏（`canvasPagePanRatio` = 0.9 屏，留一点重叠） |
| `Home` / `End` | 视野左 / 右翻一屏 |
| `[` / `]` | 缩小 / 放大，以画面中心为锚点（和滚轮同一条平滑路径） |
| `F` | **重置视野**：没选中 = 适应全部内容；有选中 = 只框住选中那一块（「框一片 → 按 F」铺满屏幕） |

> 只有本板拿到焦点时才响应。切进白板视图时外壳 `requestFocus` 后再
> `CanvasBoardState.requestFocus()` 一次（`autofocus` 只在挂载那一次生效）。

---

## 5. 视觉规格

> 2026-10-27 二轮：视觉基准换成 **graphif**（坐标纸 + 描边卡片），见 §14.3。
> 一句话差别：**白板是一块坐标系，不是一张点阵纸；卡片靠一根描边立住，
> 不靠色块和投影。**

### 5.1 画布：坐标网格 + 标尺

| 元素 | 值 |
|---|---|
| 背景 | `p.canvas`（「凹陷的工作台」） |
| 主格 | `canvasGridMajorStep(zoom)` 走 1/2/5 阶梯（`10…100000`），1px `gridMajor`（`textPrimary`@8.5%），**带刻度数字** |
| 次格 | **没有**。一格就是标尺上相邻两个数字之间的距离，格子里不再切小格（2026-10-27 按用户要求去掉，`canvasGridMinorStep` / `gridMinor` 已删） |
| 阶梯规则 | 主格屏幕步长恒落在 `[64, 640)`：`zoom=1` 时 100，缩到 8% 时 1000，放到 800% 时 10。所以刻度永远是整数，也不会缩小时画上百万条线。缩放本身**没有上下限**（见 §3.1），阶梯走完（`< 8px` 一格）就不再画网格 |
| 原点十字 | `x=0` / `y=0` 两条，`axis`（accent@24%） |
| 上标尺 | 高 20px（`canvasRulerThickness`）的不透明带，`canvas` 底色 + 内侧 1px `rulerEdge`；每个主格一根 4px 小刻度 + 居中数字（10px `rulerText`） |
| 左标尺 | 宽 32px（`canvasRulerSideWidth`），数字**右对齐**——`-2000` 这种五位数在 20px 带子里放不下 |
| 线的锐度 | 网格线统一压在 `.5` 像素上，1px 不抗锯齿成两像素灰边 |
| 选区框 | 1px 虚线 accent@70%，内部 `accentSoft`@40% |

标尺画在**内容之上**（`_paintScene` 里 restore 之后），内容滚到带子下面会被
截断——像尺子压着纸，而不是浮在纸上的水印。

### 5.2 卡片（全部自绘）

| 元素 | 值 |
|---|---|
| 圆角 | 10px（`canvasCardRadius`，世界坐标） |
| 底色 | `p.surfaceRaised` @72%（`CanvasStyle.cardFill`），**半透明**，网格能透出来 |
| 边框 | 1px `textPrimary`@30%（= graphif 那根「纸边」）；选中时边框换 `p.accent`（除以 zoom 保持屏幕粗细） |
| 选中 | 卡片**外面**再套一圈 3px 粗描边（偏移 3px）。不是把原边框加粗——加粗会往里吃，卡片看起来像被换了张 |
| 编辑中 | 那圈实线换成**虚线**（1.5px，6/4 间距）：实线说「选中」，虚线说「这张卡在吃键盘」 |
| 投影 | **没有**。卡片靠边线立住 |
| 内边距 | 12px（`canvasCardPadding`） |
| 文字 | `AppText.ui`（13px）、行高 1.6，在世界坐标排 |
| 空卡片 | 正中三个点「•••」（不写「空卡片」这种说明书）。**编辑态也是这三个点**，输入框只出一根光标——两边都画就成了两层占位，位置也一定会差一点点 |
| 贴合内容 | 文字卡片跟着文字走，**宽高都双向**：字多了变宽、删了字缩回来，删光回到三个点的宽度。宽度上限 `canvasTextMaxWidth` = 420，超了按上限折行、高度增长。宽度额外留 `canvasTextFitSlack` = 1px，避免正好卡在折行临界点 |
| 最小尺寸 | 40×40（`canvasMinSize`）**只管手拖和键盘改框，不管贴合**。文字卡片没有自己的尺寸常量——它和打完字的卡片走同一套贴合：宽 = `canvasEmptyDots`（`•••`）量出来的宽 + 内边距，高 = 一行正文；**贴合没有下限**，字号缩一半卡片就窄一半。文件 / 链接卡片仍按 `canvasDefaultWidth` = 250 |
| 缩放手柄 | 6×6 圆点，`p.accent` + 1px `p.surface` 描边；只在选中时画（屏幕尺寸恒定） |
| 详情小图标 | 16×16 圆角方框骑在右上角上（`canvasDetailsIconRect`），画和命中测试共用它 |
| 文件 / 链接图标 | Lucide 图标字形（14px）由 `TextPainter` 画 |

> ⚠️ **画布上的输入框必须是隐形的**。全局 `inputDecorationTheme` 是
> `filled: true` + `OutlineInputBorder`（给搜索框和表单用的），
> `InputDecoration.collapsed` 只把 `border` 置成 none、`filled` 会从主题漏进来
> ——那样画布上就会冒出一个带底色和描边的「节点面板」。所以
> `_editorOverlay` / `_edgeLabelEditor` 都自己写全 `InputDecoration`
> （`filled: false`、五个 border 全 none、`contentPadding: zero`）。

### 5.3 六种预设色：只染描边与文字

| NRS | 语义 | 项目色名 |
|---|---|---|
| `"1"` | 红 | `red` |
| `"2"` | 橙 | `amber` |
| `"3"` | 黄 | `amber`（撞色，存的值仍是 `"3"`） |
| `"4"` | 绿 | `green` |
| `"5"` | 青 | `blue` |
| `"6"` | 紫 | `purple` |
| 不写 | 灰 | 无（`textPrimary` 描边 + 正文色文字） |

**底色永远是中性半透明面**，颜色只出现在两处：描边（`canvasCardBorder`，
`tableInkColor`@80%）和文字（`canvasCardInk`）。这样一屏摆二十张卡片也不会
变成一块调色盘，但换色仍然一眼看得出来。换色菜单里的色点用
`canvasSwatchFill`（实心 `tableFillColor`）——菜单里必须是实色块，否则六个
选项长得一模一样。

### 5.4 分组：Section 框

| 元素 | 值 |
|---|---|
| 底色 | **不填**（graphif 的 Section 只有框） |
| 边框 | 1px `textPrimary`@22%（`groupOutline`） |
| 圆角 | 12px（`canvasGroupRadius`） |
| 内边距 | 14px（`canvasGroupPadding`） |
| 标题 | `AppText.title`（15px）、`textPrimary`@90%，左上角内侧；编辑时浮层用同一套字号与内边距 |

### 5.5 连线

| 元素 | 值 |
|---|---|
| 线宽 | 1.2px（屏幕像素，绘制时 ×`1/zoom`）；选中 2px |
| 颜色 | 未设色 → `textPrimary`@30%（`edge`）；设色 → 预设色；选中 → accent |
| 形状 | 三次贝塞尔，控制点沿端点法线伸出 `min(96, 距离 × 0.4)` |
| 箭头 | 8px 长、半角 0.36rad；`toEnd` 缺省 `arrow`，`fromEnd` 缺省 `none` |
| 标签 | 11.5px，`p.textSecondary`，居中压线，背后 3px 画布色描边（`labelHalo` 同款） |

---

## 6. 数据层 · `lib/core/utils/canvas_document.dart`

### 6.1 `.nrs` = NRS v1（自有格式）

后缀 `.nrs`，内容是我们自己的 JSON。**不是** JSON Canvas 1.0——只借了它的字段语义
（节点四类、六色、`fromSide`、`subpath`），键名与容器都换成自己的：

```json
{
  "version": 1,
  "nodes": [
    {
      "id": "4f2c9a1b8e3d5c07",
      "type": "text",
      "x": 12.345,
      "y": -8.5,
      "width": 250,
      "height": 120,
      "color": "1",
      "text": "内容"
    }
  ],
  "edges": [
    {
      "id": "9ab34cd56ef70812",
      "from": "4f2c9a1b8e3d5c07",
      "to": "…",
      "fromSide": "right",
      "toSide": "left",
      "toEnd": "arrow",
      "label": "依赖"
    }
  ]
}
```

为什么自己做格式：旧方案「后缀不同、内容照 Obsidian 规范」，结果只能兼容一半
（互通要靠导出），还要为规范里我们用不到的字段（`background`、`backgroundStyle`）
预留通道。现在直接一步到位，字段少、语义直白、后续加字段不用绕。

### 6.2 模型

```dart
class CanvasDocument {
  final List<CanvasNode> nodes;   // 顺序即 z-index：先画在下，后画在上
  final List<CanvasEdge> edges;
  final Map<String, Object?> extra;   // 顶层未知键原样保留
}

sealed class CanvasNode {
  final String id;
  final double x, y, width, height;
  final String? color;                // "1".."6" 或 "#RRGGBB"
  final Map<String, Object?> extra;
}
class TextNode  extends CanvasNode { final String text; }
class FileNode  extends CanvasNode { final String file; final String? subpath; }
class LinkNode  extends CanvasNode { final String url; }
class GroupNode extends CanvasNode { final String? label; }   // 只剩 label

class CanvasEdge {
  final String id;
  final String fromNode, toNode;      // JSON 里是 from / to
  final String? fromSide, toSide;     // top|right|bottom|left，null = 自动
  final String fromEnd, toEnd;        // none|arrow
  final String? color;
  final String? label;
  final Map<String, Object?> extra;
}

CanvasDocument parseCanvas(String source);   // 容错，见 6.5
String encodeCanvas(CanvasDocument doc);     // 键顺序稳定
String newCanvasId([Random? random]);        // 16 位小写十六进制
```

常量：`canvasExtension = '.nrs'`、`canvasFormatVersion = 1`、`canvasDefaultWidth = 250`、
`canvasDefaultHeight = 120`、`canvasMinSize = 40`。

### 6.3 坐标：自由浮点，落盘三位小数

- 内存里 `double` 原值，拖动不吸附、不取整。
- 落盘 `_wireNumber`：`round(×1000) / 1000`，整数输出成 `int`（文件里不出现 `250.0`）。
- 理由：不留浮点噪声，也不写 `249.99999`；同时拖动全程不受量化影响。

### 6.4 键顺序

`encodeCanvas` 用 `JsonEncoder.withIndent('  ')`，键按固定顺序：
`id`、`type`、`x`、`y`、`width`、`height`、`color`，再按类型追加专有字段，最后展开 `extra`。
白板文件会进 git，键顺序抖动会让每次保存都产生整文件 diff。

### 6.5 容错（有测试）

| 坏输入 | 处理 |
|---|---|
| 不是 JSON / 顶层不是对象 | 抛 `CanvasFormatException`，UI 提示，**不覆盖原文件** |
| `nodes` / `edges` 缺失 | 空数组 |
| `version` 缺失或不是 1 | 照 1 读（预留升级位） |
| 节点缺 `id` | 生成 16 位十六进制 |
| 节点缺 `x/y/width/height` | `0 / 0 / 250 / 120` |
| `width/height < 40` | 抬到 40 |
| 坐标是小数 | 原样保留（落盘三位小数） |
| `type` 不认识 | 跳过该节点，连同引用它的边 |
| 边引用不存在节点 / 自环 | 丢弃该边 |
| 同一对节点多条边 | 保留 |
| 重复节点 `id` | 只留第一个 |
| `color` 非法 | `null` |
| `fromSide` / `toSide` 非法 | `null`（自动选边） |
| `fromEnd` / `toEnd` 非法 | 缺省值（`none` / `arrow`） |
| `subpath` 不带 `#` | 补上 |
| 分组 `label` 全空白 | `null` |
| 旧键 `fromNode` / `toNode` | 兼容读取（写入一律 `from` / `to`） |
| 未知键（顶层 / 节点 / 边） | 原样保留在 `extra` |

---

## 7. 存储层 · `lib/data/storage/`

沿用既有实现，格式变化不影响接口：

```dart
abstract class CanvasStore {
  Future<void> init();
  String get location;
  bool get supportsNativeFiles;
  Future<List<CanvasRef>> list();
  Future<String> read(String relativePath);
  Future<void> write(String relativePath, String contents);
  Future<String> create(String folderPath, {String? title});
  Future<TrashEntry?> delete(String relativePath);
  Future<bool> restoreTrash(String entryId);
}
```

- **io**：真 `.nrs` 文件、原子写（`.tmp` → rename）、`list()` 跳过 `.nrs-trash` / `.nrs-history`。
- **web**：`localStorage`，前缀 `nrs/v1/canvas/`。
- 白板是**普通文件**：可放 vault 任意文件夹；新建默认落在当前笔记所在文件夹（没有就根目录）。
- 新建重名自动加 ` 2`、` 3`；文件名规则见 `canvasFileName`（去掉非法字符，空名退化成「未命名白板」）。

自动保存：`CanvasController.markDirty()` → 900ms 防抖 → `write`；切走 / 关闭前 `flush()`。
写入失败才提示（项目硬约束：成功不提示）。

---

## 8. 渲染层 · `lib/ui/canvas/canvas_painter.dart`

### 8.1 全画布一支画笔

整块白板只有**一个** `CustomPaint`。绘制顺序：

```
坐标网格：次格 → 主格 → 原点十字（屏幕坐标）
  ↓ save；translate(舞台中心) → scale(zoom) → translate(-center)   ← 进入世界坐标
连线 + 箭头 + 边标签（世界坐标，标签字号 ×1/zoom）
分组框（按面积从大到小：外层先画）
节点（文档顺序正序；文字、图标都在世界坐标排）
  ↓ restore                                                        ← 回到屏幕坐标
坐标标尺：上 20px / 左 32px 的不透明带（压在内容上）
连线圆点 / 缩放手柄 / 框选框 / 空板提示（屏幕坐标，尺寸恒定）
```

### 8.2 三条关键约定

1. **内容画在世界坐标**：一次 canvas 变换，几何直接写世界坐标。文字也在世界坐标排，
   Skia 按当前矩阵栅格化字形到设备分辨率，所以放大**不会糊**。
2. **装饰件画在屏幕坐标**：手柄、圆点、框选、边标签、线宽、箭头、边框粗细，都按
   `_px = 1 / zoom` 折算——屏幕上永远这么多像素，不跟着缩放变胖变细。
3. **文字排版要缓存**：`CanvasTextCache` 按节点 id 缓存 `TextPainter`，内容 / 宽度 /
   颜色 / 对齐 / 最大行数变了才重排；`prune()` 丢掉已删节点，`dispose()` 由 State 负责。

`shouldRepaint => true`：文档是**原地修改**的（拖动直接改 `node.x`），拿引用比会漏判。

### 8.3 为什么不再用卡片 Widget

卡片 Widget 要布局、要主题、要命中测试，几百张时 Widget 树和语义树都重；而白板上的
卡片本质就是一块圆角矩形加几行字。改成自绘后：

- 缩放 / 平移只是矩阵变换，没有 `Positioned` 重排；
- 命中测试由我们自己按世界坐标顺序问（见 9.2），不会出现「拖卡片时画布跟着动」；
- 代价是**文字编辑**要自己解决 → 见 9.5 的浮层方案。

### 8.4 编辑浮层

编辑时在画笔里**跳过该节点的正文**，同时在 `Stack` 里用
`Positioned.fromRect(world→screen 的卡片矩形)` 盖一个真 `TextField`：

- 字号 `AppText.ui × zoom`、内边距 `12 × zoom`、行高 1.6；
- 保留 IME、光标、选区、左右方向键；
- 边标签的编辑框固定 132×26 屏幕像素，居中压在曲线上。

---

## 9. 交互层 · `lib/ui/canvas/canvas_board.dart`

### 9.1 单层 `Listener` + 显式状态机

不用嵌套 `GestureDetector`（卡片 / 手柄 / 圆点 / 边 / 空白会互相抢手势）。
一层 `Listener` 收全部原始指针事件，自己命中测试：

```
idle ──down on 手柄────→ resizing
     ──down on 圆点────→ connecting
     ──down on 卡片────→ maybeDrag ──move > 3px──→ dragging
     ──down on 边──────→ 选中边（等双击判标签）
     ──down on 空白────→ marquee / panning（看中键 / 空格）
```

双击判定用手写 `Timer` + `_tapWindow(target)`：同一目标、间隔 ≤ 300ms、位移 ≤ 6px。
不用 `DoubleTapGestureRecognizer`（留 40ms 挂起计时器还抢手势）。

### 9.2 命中测试（内容用世界坐标，装饰件用屏幕坐标）

从**上到下**问，第一个命中的赢：

1. 缩放手柄：**单选**节点的 8 个，容差 7px（屏幕坐标，卡片屏幕边短于 12px 时不出手柄）；
2. 连线圆点：仅当该卡片正在悬停，四条边中点 7px（屏幕坐标）；
3. 节点：矩形 `contains`，**倒序**遍历（后画的在上）；悬停时容差 `1/zoom`（`Rect.contains` 不含右 / 下边界）；
4. 边：点到贝塞尔的距离 < 6px / zoom（20 段折线近似）；
5. 空白。

拖动分组时按**中心包含**判断子节点归属（`group.rect.contains(child.rect.center)`），
嵌套分组也一起带走。

### 9.3 无吸附

拖动只把屏幕增量除以 zoom 加到世界坐标上，松手不再对齐网格 / 边缘，也不画辅助线。
坐标就是浮点，文件里压三位小数。

### 9.4 撤销 / 重做

`CanvasHistory`：**整份文档的字符串快照**，上限 50 步。

- 每次改动**之前** `push(encodeCanvas(doc))`；一次拖动只在按下时记一格；
- 撤销 / 重做会换一批新节点对象——测试只能看文档里那张，不能留旧引用；
- 存字符串而不是对象：省掉深拷贝，且和落盘用的是同一个序列化器。

### 9.5 编辑态

- 双击文字卡片 / 分组 → `_editingId` + 浮层 `TextField`（autofocus）；
- `onChanged` 直接写 `node.text`（文档模型可变）；
- 提交：点外部 / `Esc` / 失焦；边标签留空存 `null`；
- 只读板（`document == null`）不给编辑、不给新建，空板提示改为「中键拖动平移，滚轮缩放」。

### 9.6 剪贴板

`Ctrl+C` 把选中的节点 + **两端都在选区里**的边序列化成 JSON 串；`Ctrl+V` 重新发 id
（`toJson → 改 id → parseCanvas`，因为 `id` / `fromNode` / `toNode` 都是 `final`），
整体偏移 +20,+20；`Ctrl+D` = 复制 + 粘贴连做。

---

## 10. 状态与接线

### 10.1 `CanvasController`

```dart
class CanvasController extends ChangeNotifier {
  CanvasDocument? _document;
  String? get path;              // 相对 vault 的 .nrs 路径
  String? get error;
  bool get hasDocument;

  Future<void> open(String relativePath);
  Future<bool> createNew(String folderPath, {String? title});
  void markDirty();              // 900ms 防抖落盘
  Future<void> flush();
  Future<({bool ok, TrashEntry? entry})> deleteCanvas(...);
  Future<bool> restoreTrash(String entryId);
  Future<void> refreshCanvases();
}
```

挂在 `app_shell` 的 `MultiProvider` 上（和 `NotesController` 平级）。
**选中集 / 摄像机 / 历史 / 编辑态都在 `CanvasBoardState`**，不进控制器：
它们是一次会话的观感，不需要跨视图共享，也不落盘。

> 旧方案把 `zoom` / `offset` / `selection` 放在控制器里；改为摄像机后这层没必要了——
> 摄像机依赖舞台尺寸，只有画布自己知道。

### 10.2 主区接线

与 `GraphView` 同构：

1. `MainView` 加 `canvas`；
2. `app_shell.dart` 的 `Stack` 加第三个 `Offstage`（`_canvasOpened` 懒建）；
3. 页签条里加「白板」那一页（`_TitleTab`，key 固定为 `canvas-tab`）；
4. 功能栏白板按钮 = 新建一块（不弹选择器）；
5. 文件树里点 `.nrs` → `_openCanvasFile` → `open()` + 切视图；
6. `Ctrl+Shift+B` 挂进 `_globalShortcuts()`。

**白板那一页和图片页同构**：只有一页，标题 = 那块白板的名字
（`canvasTitleOf(path)`），从文件树换一块只是换名字；点 × 才关掉（`close()`
会先落盘）。标签在不在，看的是 `CanvasController.path` 是不是 null——不另存
一个布尔，否则删掉当前那块之后会剩一个点不动的空标签。

**跨重启恢复**：`nrs.sessionCanvas`（路径）+ `nrs.sessionCanvasActive`
（当时是不是正看着它）两个键。恢复分两段，因为 `open()` 要等 vault 读完：
`main.dart` 在 `bootstrap` 完成后按路径重开（失败就清掉会话，不在启动时弹
错），`AppShell` 只负责「文档来了就切过去」（`_pendingCanvasActivate`）。
只存路径不存 active 是不够的：白板页开着但人在写笔记时，下次该回到那篇笔记。

### 10.3 与右侧三面板

白板是主区视图，右侧面板（大纲 / 表格 / 图片）对它没意义。
切过去时保持面板原样、按「无当前笔记」处理，不强行关闭（免得切回来发现面板没了）。

---

## 11. 文件清单（当前真实状态）

| 文件 | 状态 | 说明 |
|---|---|---|
| `lib/core/utils/canvas_document.dart` | 重写 | NRS v1 模型 + `parseCanvas` / `encodeCanvas` / `newCanvasId` |
| `lib/core/utils/canvas_geometry.dart` | 重写 | `CanvasCamera`、贝塞尔、手柄、命中工具、插值 |
| `lib/ui/canvas/canvas_painter.dart` | **新增** | `CanvasScenePainter`（全画布单层自绘）+ `CanvasTextCache` + 边视觉 |
| `lib/ui/canvas/canvas_board.dart` | 重写 | 摄像机 / Ticker / `Listener` 状态机 / 编辑浮层 / 键盘 |
| `lib/ui/canvas/canvas_style.dart` | 重写 | 网格 / 标尺 / 描边卡片的配色令牌 + 主格阶梯（`canvasGridMajorStep`）+ 刻度文案 |
| `lib/ui/canvas/canvas_toolbar.dart` | **已删除** | 右下角工具条整个移掉；缩放改滚轮、平移改中键拖 |
| `lib/ui/canvas/canvas_history.dart` | 保留 | 50 步字符串快照栈 |
| `lib/ui/canvas/canvas_pickers.dart` | 保留 | 文件选择器、链接对话框、URL 归一化 |
| `lib/ui/canvas/canvas_card.dart` | **已删除** | 并入 `canvas_painter.dart` |
| `lib/ui/canvas/canvas_edge_painter.dart` | **已删除** | 并入 `canvas_painter.dart` |
| `lib/ui/canvas/canvas_grid_painter.dart` | **已删除** | 并入 `canvas_painter.dart` |
| `lib/state/canvas_controller.dart` | 保留 | 打开 / 新建 / 防抖保存 / 回收站 |
| `lib/data/storage/canvas_store*.dart` | 保留 | `.nrs` 存取（io / web / factory） |
| `lib/ui/shell/` 若干 | 保留 | `MainView.canvas`、页签、快捷、文件树 |

---

## 12. 测试

### 12.1 现状（全绿）

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `test/canvas_document_test.dart` | 38 | 解析 / 序列化 / 三位小数 / 未知键 / 容错 / id |
| `test/canvas_geometry_test.dart` | 40 | 摄像机换算 / 锚点缩放 / fit / 插值 / 手柄 / 贝塞尔 |
| `test/canvas_board_test.dart` | 78 | 交互全链路（widget 测试 + 探针断言）+ 坐标网格阶梯 |
| `test/canvas_controller_test.dart` | 14 | 打开 / 新建 / 防抖 / 写失败 / 坏 JSON |
| `test/canvas_history_test.dart` | 6 | 撤销栈边界 |
| `test/canvas_pickers_test.dart` | 9 | 文件 / 链接选择、URL 归一化 |
| `test/canvas_store_test.dart` | 16 | 文件名、路径安全、真文件读写 |

### 12.2 关键断言点

- **摄像机**：屏幕／世界互逆、`zoomedAt` 锚点世界坐标不变、`fit` 把内容装进 `舞台 - 2×90`、
  `fit` 空内容 / 零舞台不炸、值相等。
- **网格阶梯**：`canvasGridMajorStep` 的屏幕步长恒在 `[64, 640)`、放大单调不增、
  `canvasGridLineOffsets` 负原点不漏线、`canvasRulerLabel` 不外泄浮点噪声。
- **数据**：坐标末位无浮点噪声、整数落盘仍是 `int`、round-trip 幂等、旧键 `fromNode` 兼容。
- **交互**：拖动 16 世界单位就停在 16（**不再吸附到 20**）、框选框是世界坐标（框选途中
  缩放，世界矩形一个数都不变、只是屏幕位置跟着动）、分组嵌套带走、WASD 惯性滑停后
  `debugTicking == false`、滚轮往上放大往下缩小。
- **测试探针**：`CanvasBoardState` 暴露 `debugCamera` / `debugZoom` / `debugCenter` /
  `debugTargetZoom` / `debugStage` / `debugVisibleWorld` / `debugMarquee`（世界坐标）/
  `debugSelection` / `debugEditing` / `debugEditingEdge` / `debugColorOf` / `debugEdgeCount` /
  `debugLabelOf` / `debugPanning` / `debugDragging` / `debugResizing` / `debugTicking` /
  `debugEmptyHint`。

### 12.3 验证命令

```powershell
flutter analyze lib test
flutter test test/canvas_document_test.dart test/canvas_geometry_test.dart `
             test/canvas_board_test.dart test/canvas_controller_test.dart
flutter test
```

---

## 13. 风险与应对

| 风险 | 应对 |
|---|---|
| 自绘文字放大糊 | 文字在世界坐标排版，由 canvas 矩阵栅格化到设备分辨率；缓存只复用 `TextPainter`，不预渲染位图 |
| 每帧重排文字吃帧率 | `CanvasTextCache` 按节点 id 复用，宽度 / 内容 / 颜色变了才重排 |
| 卡片多了卡顿 | 没有 Widget 树与布局，只有绘制；网格按屏幕步长排（恒 ≥ 64px 一格），标尺数字每帧现排十几条 10px 短串 |
| 手势互相抢 | 单层 `Listener` + 显式状态机；命中测试顺序固定 |
| 缩放锚点漂移 | 每一步都调 `withZoomAt(anchor, z)`，不是先改 zoom 再修 center |
| 撤销换对象导致旧引用失效 | 文档原地改、快照回灌；测试与调用方一律按 id 取节点 |
| 摄像机与自动保存冲突 | 摄像机不落盘；打开文件时按内容自适应 |
| 文件卡片指向的笔记改名 / 移动 | 本期不做重写；只保证打开不崩 |
| 删文件夹被白板挡住 | `NotesController.canvasCountOf` 注入白板数量，提示「文件夹里还有 N 块白板」 |
| Web 端持久化容量 | 沿用 `NoteStoreWeb` 的配额错误处理 |

---

## 14. 决策记录

### 14.1 2026-10-25（初版）

| # | 问题 | 决定 |
|---|---|---|
| 1 | 白板文件放哪 | 普通文件，vault 任意文件夹；新建落在当前笔记文件夹 |
| 2 | 一期要不要文件卡片 | 要（`type: "file"`） |
| 3 | 空白处左键拖动 | 框选；平移交给中键 / 空格（2026-10-27 起滚轮改做缩放） |
| 4 | 多选对齐 / 分布 | 不在本期 |
| 5 | 是否严格兼容 JSON Canvas | 当时答：是（未知字段保留、坏数据不覆盖） |
| 6 | 文件后缀 | `.nrs` |

### 14.2 2026-10-27（本轮重构）

| # | 问题 | 决定 |
|---|---|---|
| 7 | 画布坐标模型 | **摄像机坐标模型**：世界中心 + zoom，参考 Project Graph 的 `Camera` |
| 8 | 卡片怎么画 | **全画布单一 `CustomPaint`，Dart 自绘**；卡片不再是 Widget |
| 9 | 数据坐标 | **自由浮点，不吸附**；分组支持嵌套 |
| 10 | 内容格式 | 一步到位换成 **NRS v1**；不做旧数据迁移（用户确认无旧数据） |
| 11 | 编辑怎么办 | 自绘显示 + 编辑时盖真 `TextField` 浮层（保住 IME / 光标 / 选区） |

### 14.3 2026-10-27（二轮：视觉改成 graphif 风）

参考 <https://github.com/graphif> 的截图（`design/canvas-graphif-style.html` 是
1:1 的静态复刻，改视觉前先对着它看）。**架构不动**——摄像机、单画笔、NRS v1、
自由浮点坐标、平滑缩放、WASD 惯性全部沿用；只换视觉层。

| # | 问题 | 决定 |
|---|---|---|
| 12 | 背景是点阵还是坐标系 | **坐标网格 + 标尺**。主格 1/2/5 阶梯恒落在 64–640px 之间，刻度永远整数；上 20px / 左 32px 不透明标尺带压在内容上 |
| 13 | 卡片长什么样 | **描边式**：中性半透明底（`surfaceRaised`@72%）+ 1px `textPrimary`@30%，**去掉投影** |
| 14 | 六种预设色还要不要 | 要，但**只染描边与文字**，不染底色。换色菜单的色点仍是实心色块 |
| 15 | 分组 | 改成 graphif 的 **Section 框**：不填底、12px 圆角、15px 标题 |
| 16 | 连线 | 变细变淡：1.2px `textPrimary`@30%，箭头 8px（原 2px / 10px） |
| 17 | 旧的点阵令牌 | `canvasGridSize` / `canvasGridStep` / `canvasGridOpacity` / `gridDot*` / `cardShadow` 全删，别再加回来 |
| 18 | 格子里还要不要小格 | **不要**。只有主格一层，一格 = 标尺相邻两个数字的距离 |
| 19 | 右下角工具条 | **整颗删掉**（`canvas_toolbar.dart` 已移除）。缩放用滚轮、平移用中键拖——右下角那一小块留给画布本身 |
| 20 | 视野操作照 graphif 补齐 | 缩放：滚轮 + `[` `]`；平移：中键拖 / 空格拖 / `WASD` / `PageUp` `PageDown` `Home` `End`；重置：`F`（有选中就框住选中） |
| 21 | 缩放要不要上下限 | **没有上限**（2026-10-28）。原来的 `0.08 / 8` 是随手定的墙，一放大就撞。现在只留 `minZoom = 1e-6` 挡 0 和 Infinity；收敛判据改成相对值；缩到 `1e-5` 以下整块板子不到一像素，`_paintScene` 直接不画 |

### 14.4 2026-10-28（三轮：节点操作照 graphif 补齐）

参考 graphif 的「文本节点」操作说明图。这一轮补的是**键盘 / 浮层**，架构仍然不动。

| # | 问题 | 决定 |
|---|---|---|
| 22 | `Ctrl+F` 干什么 | **搜索节点**。贴在上边标尺下面，边打边跳：命中第一张就选中 + 移镜头（**只移不改缩放**——搜索问的是「这张卡在哪」）。`Enter` / `Shift+Enter` 循环、`Esc` 关 |
| 23 | 「详细信息」怎么开 | 三条路：`Ctrl` + 双击卡片、单选后 `Ctrl+Enter`、点选中卡片右上角那颗小图标。面板是个**能拖大的子窗口**（右下角握把），改文字 / 颜色 / X / Y / 宽 / 高 |
| 24 | 面板跟着谁走 | **跟着当前那一张单选**。不存自己的目标 id——存了就得在每个改选中的地方同步它，漏一处就会出现「面板显示的是上一张卡」 |
| 25 | `Enter` 是进编辑还是退出编辑 | 文字卡片是**多行**的，`Enter` 必须是换行，退出走 `Esc` / 点别处；**分组标题只有一行**，编辑中按 `Enter` 就是「改完了」（graphif 的「Enter 退出编辑」只在单行里成立） |
| 26 | `Ctrl+=` / `Ctrl+-` 改什么 | 改**字号**（`node.scale` ×1.25 / ÷1.25，锚在中心），不改视野——视野归滚轮和 `[` `]`。用户原话：「调整大小并不是调整输入框大小，而是文字意义上的调整大小」：把框拉大而字不动，得到的是一张卡里空了一大片，那是另一件事 |
| 27 | 新建的卡片多大 | **小**。250×120 那种横幅是「已经装了一段话」的量，新建时还没话可说，空着占小半屏像块空面板。文件 / 链接卡片仍用 250 宽（要放路径）。文字卡片只定宽 120，**高由贴合算**（见 33 / 37） |
| 28 | 空卡片画什么 | 正中三个点「•••」。不写「空卡片」三个字——卡片是内容不是控件 |
| 29 | 选中的样子 | 卡片外面套一圈 3px 粗描边。原来的「边框换成 accent + 加粗」会往里吃，卡片看起来像被换了张 |
| 30 | 浮层和画布抢指针 | 浮层的矩形在 `_onPointerDown` / `_onPointerSignal` / `_onPointerHover` 三处提前拦下：点搜索框不清选中、滚轮不缩放画布、光标不变成抓手 |

### 14.5 2026-10-28（四轮：编辑框隐形 + 卡片贴合内容）

用户：「移除这个节点面板！！双击新增节点就是一张带 ••• 的小卡，参考
`thinks-mindmap` 里导图的双击输入框。」

| # | 问题 | 决定 |
|---|---|---|
| 31 | 画布上的输入框长什么样 | **隐形**。不带底色、不带描边、`contentPadding: 0`——卡片本身就是那个框。原因是一个真实的坑：全局 `inputDecorationTheme` 是 `filled: true` + `OutlineInputBorder`，`InputDecoration.collapsed` 挡不住 `filled`，于是画布上冒出一个带底色和边框的「节点面板」。`_editorOverlay` 和 `_edgeLabelEditor` 现在都自己写全 `InputDecoration` |
| 32 | 空卡片在编辑态显示什么 | 居中的「输入文字」（不是「输入文字…」，也不是左上角）。位置和画笔画的「•••」一致，一进编辑三个点变成占位文字，不会从中间跳到左上角 |
| 33 | 卡片尺寸跟不跟文字走 | **跟**（照 `thinks-mindmap` 的 `_measure`：尺寸 = 文字块 + 内边距）。**宽高都双向**：字多了变宽、删了字缩回来，删光回到三个点的宽度。手拖过的尺寸只在拖的那一刻有效，一改字就以内容为准——文字卡片没有「固定宽度」这个概念。上限 `canvasTextMaxWidth` = 420 |
| 34 | 编辑中的边框 | 选中那圈**实线换成虚线**。实线说「选中」，虚线说「这张卡在吃键盘」，两者不能互相冒充 |
| 35 | 输入框里打 `f` 触发「适应窗口」 | **`_onKey` 开头加一道 `_focus.hasPrimaryFocus` 闸**。判 `hasFocus` 没用——本板的 `Focus` 是输入框的祖先，子节点拿到焦点时它也是 true，只有 `hasPrimaryFocus` 才区分得出谁在吃键盘。`Esc` 收编辑态必须放在这道闸**前面**，否则退不出编辑 |
| 36 | 点编辑框里换光标，编辑被提交掉 | `_onPointerDown` 在 `_focus.requestFocus()` 之前先判「点在不在正在编辑的那张卡 / 边标签框里」（`_edgeLabelRect` 是画和判共用的一份），在就原样交给输入框。抢焦点 = `_editorFocus` 失焦 = `_commitEdit` |
| 37 | 空卡片为什么不该有自己的尺寸 | 这里先后写过 120×160、90×120、120×一行高，每一版都被指出「太大 / 太宽 / 太高」。根因不是数值没调对，是**空卡片被当成了特例**：它有自己的常量，就一定会和它显示的那三个点对不上。现在 `canvasNewTextWidth` / `canvasNewTextHeight` **两个常量都已删除**，空文字走的是和文字卡片同一个算法，只是内容换成了 `canvasEmptyDots` |
| 38 | 空卡片具体怎么量 | **宽 = `•••` 量出来的宽 + 两边内边距**（刚好装下三个点，不多给一个像素）；**高 = 一行正文**（和打完一行字的卡片同高，两张并排才对得齐）。量点和画笔**共用 `canvasEmptyDots` + `canvasEmptyDotsStyle()`**——分开写迟早会差一点点，右边多一条空 |
| 39 | 宽度是「自适应」不是「固定」 | 宽度**双向**跟着文字走：字多了变宽，删了字缩回来，删光回到三个点的宽度。曾经写成「只长不缩」（为了留住手拖的宽度），结果删完文字卡片还摊着——用户原话：「文字多的时候变宽，我删掉了文字后，宽度就变回来啊」。测试断言的是**宽度来自内容**（`closeTo(dots.width + 2 * canvasCardPadding + canvasTextFitSlack)`），不是一个魔法数字 |
| 40 | 不编辑时一行、一编辑变两行 | 两个原因叠在一起：① 贴合出来的宽度**正好等于**文字宽度，落在折行临界点上，亚像素误差就能让它多折一次；② `RenderEditable` 排版前会把可用宽度扣掉「光标宽 + 1」（`editable.dart` 的 `_caretMargin`），输入框比画笔少排几个像素。修法：宽度加 `canvasTextFitSlack` = 1px 推开临界点；`_editorOverlay` 的右内边距减去 `cursorWidth + 1 + canvasTextFitSlack`，把光标余量补回来，让输入框和画笔的可排宽度**严格相等** |
| 41 | 字号倍率存哪、有没有上下限 | 存在 `CanvasNode.scale`（基类，默认 1），只在 `!= 1` 时写进 JSON——没调过大小的卡片不该多一行 diff。**没有上下限**（和画布缩放一致）：只挡 0 / 负数 / NaN，因为 0 会让字彻底消失且再也乘不回来（0 × 1.25 还是 0）。折行上限 `canvasTextMaxWidth` 也跟着倍率放大，否则字放大之后只会往高里堆、不会变宽 |
| 42 | 文件 / 链接卡片也调字号吗 | **不**。它们是固定样式的引用卡，没有「文字即内容」这回事，所以对它们 `Ctrl+=` 仍然改框。分组只放大标题，框不动——分组框是用户圈出来的一块区域 |
| 43 | 贴合要不要留 40px 的底 | **不要**。`canvasMinSize` 只管手拖 / 键盘改框；贴合一旦留底，字缩一半卡片还是 40 宽，看起来就是「宽度是固定的」。用户原话：「文字如果变小的，那么节点也要跟随变得更小」 |
| 44 | 编辑时按 Ctrl+= 没反应 | 键盘在输入框里时白板一个键都不抢（那道闸），但 **Ctrl 组合键不会往输入框里打字**，调字号是编辑时最自然的动作。所以 `Ctrl+` `=` / `-` 的判定放在闸**前面**，用同一个 `_resizeFactorOf` 列键位（主键盘 `=` / `-` 和小键盘都算），两边不会各写一份 |

---

## 15. 验收清单

- [x] 功能栏点「白板」能新建并切过去；文件树点 `.nrs` 能打开
- [x] 空白处拖 = 框选；中键 / 空格拖平移；`WASD` 惯性平移
- [x] 滚轮以光标为锚点**平滑**缩放（往上放大、往下缩小），全程锚点不漂
- [x] 右下角没有工具条；`Ctrl+0` 回 100%；`Ctrl+Shift+H` 适应窗口
- [x] 双击空白出卡片并直接能打字；`Esc` / 点空白退出编辑
- [x] 拖动卡片坐标是自由浮点（拖 16 就停 16）；八向缩放，最小 40×40
- [x] 从圆点拖到另一张卡片能建边；边有箭头和标签；选中能删
- [x] 多选整组拖动；分组带走框内卡片（含嵌套）；`Ctrl+A` 全选；`Delete` 连带删边
- [x] `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` 能一路退回再走回
- [x] 关掉再打开，坐标（三位小数）、颜色、连线、标签一个不差
- [x] 浅色 / 深色主题下都读得清（卡片底色、连线、网格）
- [x] 空白板 / 单卡片 / 大坐标三种极端输入都不崩
- [x] `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` 1483 条全绿

---

## 16. 实施记录

### 16.1 旧架构的提交（保留作历史）

| 提交 | 阶段 | 回归 |
|---|---|---|
| `42b74ff` | P1 点阵 + 平移缩放 + 主区接线 | 1356 |
| `da60f69` | P2 卡片 | 1390 |
| `651198d` | P3 连线 | 1410 |
| `555f9c0` | P4 文件卡 / 链接卡 / 分组 | 1425 |
| `3fa4522` | P5 撤销重做 / 框选 / 剪贴板 / 微调 / 裁剪 | 1444 |
| `c92d73f` | P6 落盘 + 自动保存 + 选择器 | 1470 |

### 16.2 本轮重构（2026-10-27）

| 步骤 | 结果 |
|---|---|
| 重写 `canvas_document.dart`（NRS v1） | 38 条文档测试改完通过 |
| 重写 `canvas_geometry.dart`（`CanvasCamera`） | 40 条几何测试通过 |
| 新增 `canvas_painter.dart`（单层自绘） | 承载网格 / 边 / 卡片 / 手柄 / 框选 / 提示 |
| 重写 `canvas_board.dart`（摄像机 + Ticker + 浮层） | 76 条 board 测试通过 |
| 删除 `canvas_card` / `canvas_edge_painter` / `canvas_grid_painter` | `flutter analyze lib test` 无问题 |
| 全量回归 | **1497 条全绿** |

### 16.3 踩过的坑（写下来免得下次再踩）

1. **`ResizeHandle` 撞名**：`app_widgets.dart` 里已有面板拖拽手柄 → 白板用 `CanvasResizeHandle`。
2. **双击判定不能用 `DateTime.now()`**：假时钟里它不前进；用 `Timer(kDoubleTapTimeout)`。
3. **`zoom * (1 / zoom)` 得到 `0.9999999999999999`**：读数会显示 99%。`withZoomAt` 直接构造相机，不走乘法。
4. **关联点缩放不能先改 zoom 再修 center**：每帧都要用当前 zoom 调 `withZoomAt`，否则锚点整段漂。
5. **连线圆点点不到**：圆点在卡片边界上，而 `Rect.contains` 不含右 / 下边界 → `_nodeAt` 悬停时加 `1/zoom` 容差。
6. **`id` / `fromNode` / `toNode` 都是 `final`**：粘贴换 id 只能在 JSON 层做（`toJson → 改 → parseCanvas`）。
7. **撤销后旧节点引用作废**：`_restore` 会换一批新对象，测试只看 `h.nodes.first`。
8. **点阵必须在屏幕坐标里算**：`startX = origin.dx % screenStep`。换世界坐标后，缩到 0.08 时要点上百万个。
9. **`CanvasCamera` 必须值相等**：画笔与测试都拿它比。
10. **分组排序比较器**：`b.width * b.height.compareTo(...)` 会编译失败，必须先把面积算成局部变量。
11. **`PointMode` 不在 material 导出里**：`import 'dart:ui' as ui` 后用 `ui.PointMode.points`。
12. **`shouldRepaint` 不能比文档引用**：文档原地修改，引用永远不变 → 直接返回 `true`。
13. **缩放没有上限**（2026-10-28 起）。`minZoom = 1e-6` 只是挡住 `1 / zoom` 溢出，不是视觉上的墙。收敛判据必须改成**相对**的（`max(1e-9, target * 1e-3)`），绝对阈值在 1e-6 和 1e6 两头都不对。
14. **条件导出在测试里解析不到**：`canvas_store_test.dart` 直接 import `canvas_store_io.dart`，别走 factory。

### 16.4 二轮：视觉换成 graphif 风（2026-10-27）

| 步骤 | 结果 |
|---|---|
| `canvas_style.dart` 重写 | 令牌换成网格 / 标尺 / 描边卡片三组；新增 `canvasGridMajorStep` / `canvasGridMinorStep` / `canvasGridLineOffsets` / `canvasRulerLabel`；`canvasCardFill` 改签名（不再吃颜色），新增 `canvasSwatchFill` / `canvasGroupInk` |
| `canvas_painter.dart` 重写网格层 | `_paintGrid` 画三层线（次格 / 主格 / 原点十字），`_strokeLines` 合并成一条 path 并压到半像素；新增 `_paintRulers` / `_paintRulerText` |
| `canvas_painter.dart` 重写卡片层 | 去 `drawShadow`、去色块底；分组不填底、圆角 12、标题 15px；连线 1.2px、箭头 8px |
| `canvas_board.dart` | 编辑浮层的字号 / 内边距 / 颜色跟画笔对齐（分组标题进编辑不再跳字号）；`_ColorDot` 改用 `canvasSwatchFill` |
| 测试 | 「点阵」组换成「坐标网格」5 条（阶梯落在 64–640、单调、负原点、刻度文案） |
| 回归 | `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` **1483 条全绿** |

静态复刻：`design/canvas-graphif-style.html`（1120×700，1:1 对应画笔顺序，
换视觉前先对着它看；它不参与构建，只是设计稿）。
