# 白板（Canvas）· 架构与实施方案

> 状态：**已实现并验收通过（2026-10-27 重构完成；同日二轮视觉换成 graphif 风，见 §14.3；
> 2026-10-28 九轮卡片正文与编辑器逐项对齐，见 §14.10 / §16.7；十一轮修好「拖进白板
> 卡片落在拖拽起点」，见 §14.12 / §16.8；十二轮选择操作照 graphif 规格补齐，见
> §14.13 / §16.9；十三轮连线创建（右键拖拽 / 选中后右键另一张）上线并补上「选中边按
> `Enter` 写标签」，见 §14.14 / §16.10；十四轮定下**文件格式仍是纯 JSON**、图片走库内
> 引用，见 §14.15 / §16.11；十五轮图片卡真的画出图来并能拖角改大小，见 §14.16 / §14.17 /
> §16.12；十六轮多连一与 `Ctrl+T` 反转，见 §14.18 / §16.13；十七轮劈砍 / 切割线，
> 见 §14.19 / §16.14；十八轮图片节点四条规格（拖入 / 粘贴 / Ctrl+滚轮 / 绿手柄），
> 见 §14.20 / §16.15；十九轮 `Tab` 从选中卡往右生成新卡并连上，见 §14.21 / §16.16；
> 二十轮同一节点连按 `Tab` 孩子从上往下排，见 §14.22 / §16.17；二十一轮编辑态
> `Tab` 也能生孩子，见 §14.23 / §16.18；二十二轮 Section 框基础操作（`Ctrl+G` 打包 /
> `Ctrl+Shift+G` 转框 / 右键打包 / `Alt+左键` 跳跃 / 双击标题与内部空白分流），
> 见 §14.24 / §16.19；二十三轮打包出的组**始终自动包裹成员**、只有 `Alt` 拖到框外
> 才能脱离，见 §14.25 / §16.20；二十四轮文件列表里**除文件夹外的任何文件**都能
> `Shift+左键` 连选，见 §14.26 / §16.21）**。
> `flutter analyze lib test` 无问题（唯一 issue 是 `test/widget_test.dart` —— Flutter
> 模板残留，引用不存在的 `MyApp`，与白板无关），`flutter test --exclude-tags perf`
> **1622 条通过**，其中白板相关 **325 条**（canvas_board 183）。
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
| C4 | 坐标网格随缩放走 1/2/5 阶梯（屏幕步长恒在 64–640px），整数坐标写在世界原点的两条轴上 |
| C5 | 双击空白 = 新建文字卡片，直接进入编辑（卡片中心落在双击处） |
| C6 | 卡片可拖动；尺寸跟着内容自动贴合（**没有缩放手柄**），默认 250×120 |
| C7 | 六种预设色（`"1"`–`"6"`），右键菜单换色 |
| C8 | 连线：贝塞尔曲线，可带箭头与文字标签（可选中 / 改标签 / 删除）。**新建**：右键从卡片拖到另一张（端点按轨迹定边），或选中一张后右键另一张（中心到中心）；拖到空白处则新建一张卡并连上（§14.14） |
| C9 | 框选（拖空白）、`Ctrl` 点选、多选整组拖动 / 删除 |
| C10 | 键盘：`Delete` / `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` / `Ctrl+A` / `Ctrl+C` / `Ctrl+V` / `Ctrl+D` / 方向键微调 / `Ctrl+0` / `Ctrl+Shift+H`；视野：`[` `]` / `PageUp` `PageDown` / `Home` `End` / `F` |
| C11 | **不吸附**：坐标是自由浮点，落盘只压三位小数 |
| C12 | 「重置视野」（`F`）：没选中 = 按全部内容包围盒自适应并居中；有选中 = 只框住选中那一块 |
| C13 | 自动保存：改动后 900ms 防抖落盘；切走 / 关闭前 `flush()` |
| C14 | 文件卡片 `type: "file"`：显示标题 + 路径，双击打开那篇笔记；指向图片时是一张**图片引用卡**（图标换成图片、点标题不展开、双击用图片页打开），存的是库内路径，板子不拷贝字节（§14.15） |
| C15 | 链接卡片 `type: "link"`：显示标题 + 域名，双击用系统浏览器打开 |
| C16 | 分组 `type: "group"`：底板框住若干卡片，可加标题；拖动带走框内卡片，支持嵌套 |

### 2.2 不做

- ❌ 网页卡片内嵌真实网页（只显示标题 + 域名 + 外链打开）。
- ❌ 卡片里的**图片渲染**（图片行只显示替代文字；其余 markdown 已与编辑器逐项一致，见 §14.10 #92）。
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
| 拖空白（向右 / 竖直） | **碰撞框选**（虚线框，存的是**世界坐标**：平移 / 缩放时框贴着内容走）——碰到就算 |
| 拖空白（**向左**） | **完全覆盖框选**——整张卡都在框里才算，框只骑上去一半的不选 |
| `Shift` + 拖空白 | 加选：框中的并进现有选中，旧的不清 |
| `Ctrl` + 拖空白 | 反选：框里已选的取消、未选的选中，框外不动 |
| 中键拖 / 空格 + 左键拖 | 平移 |
| 滚轮 | **缩放**：往上放大、往下缩小，以光标为锚点（目标 `zoom × exp(-dy / 320)`） |
| 双击空白 | 新建文字卡片并进编辑 |
| 右键空白 | 菜单：新建卡片 / 粘贴 / 适应窗口 |

> 按键读的是**松手那一下**：拖到一半再按 `Shift` 也是合法操作。框选只能从空白处
> 发起（优先级见 §14.13 #106）。

### 4.2 卡片

| 操作 | 行为 |
|---|---|
| 单击卡片 | 选中（外圈 accent 粗描边）。点**已选中**的卡不清别人——多选还得整组拖。**没有缩放手柄**：卡片尺寸只由内容决定 |
| `Ctrl` + 单击 | 加选 / 减选（锚点不动） |
| `Shift` + 单击 | **范围选择**：从上次点中的那张（锚点）到这张，两个矩形撑起的包围框里**碰到就算**。锚点不动，可连续换对角扩展；没有锚点时退化为单选 |
| 双击卡片 | 文字 / 分组 → 进编辑；文件 / 链接 → 打开 |
| `Ctrl` + 双击卡片 | **打开详细信息面板**（任何类型的卡片都一样，文件/链接看到的是路径/网址） |
| 点选中卡片右上角的小图标 | 同上（那个小图标骑在右上角上，一半在卡片外） |
| `Enter`（单选时） | 进编辑（文件 / 链接卡片没有可编辑文字，不响应） |
| 拖动卡片本体 | 移动（多选时整组）；**不吸附**。拖角 / 拖边也是移动，不会改宽高 |
| 点文件卡片标题条 | 展开 / 收起（展开 = 标题 + 整篇正文；收起 = 一行文件名）。**图片引用卡不展开**——它没有正文，展开只会变成一个空框 |
| 拖图片进白板 | 两条路都行（§14.20）：从**文件列表**拖图片行，或从**桌面**把 PNG / JPG / JPEG / WEBP 直接拖到板上（自动导入库里再引用）。落成一张**图片卡**，卡片只存库内相对路径，改图就是改库里那张 |
| `Ctrl+V`（板内剪贴板空时） | 把系统剪贴板里的**截图**存进库里并落成图片卡（指针位置）。板内复制过卡片时 `Ctrl+V` 仍是贴卡片 |
| 悬浮在图片上 `Ctrl+滚轮` | 等比缩放这张图（画布不缩放）。滚轮是一串密集事件，**700ms 内算一阵、只记一步撤销** |
| 悬浮在别的卡片上 `Ctrl+滚轮` | 照旧缩放画布——那些卡片的尺寸是内容的函数，改了也会被贴合顶回去 |
| 文件卡片尺寸 | 收起：一行标题；展开：整篇正文，宽上限 `canvasTextMaxWidth` = 420，**高度没有上限**——内容全部显示 |
| `Delete` | 删除选中卡片，连带删掉它的边 |
| 右键卡片 | 换色 / 复制 / 删除 / 置顶置底 |
| 悬停卡片 | 光标变手；不再浮出连线圆点（2026-10-28 七轮移除） |
| **拖图片卡右下角** | 改宽高，**保持原图比例**，左上角钉死（§14.17）。**只有图片卡有这颗手柄**，其余卡片拖右下角仍然是移动整张卡 |

### 4.2.1 浮层（搜索 / 详细信息）

两个浮层都画在画布的 `Stack` 里，指针落上去时 `_onPointerDown` 提前返回，
**不传给底下的画布**——否则点搜索框会清掉选中，点面板里的输入框会把正在
编辑的卡片收掉。

| 浮层 | 位置 | 行为 |
|---|---|---|
| 搜索（`Ctrl+F`） | 贴着画布上边（12px）、水平居中，360×42 | 边打边跳：命中第一张就选中并把镜头移过去（只移不改缩放）。`Enter` 下一个、`Shift+Enter` 上一个（循环）、`Esc` 关掉 |
| 详细信息 | 默认贴舞台右下角，296×352 | 文字 / 颜色 / X / Y / 宽 / 高；**右下角握把能拖大小**（240–620 × 220–720）。`Esc` 关掉 |

面板**没有自己的目标节点**：它永远显示当前那一张单选，选中没了就收起。
比再存一个 id 再去各处同步省事，也不会出现「面板显示的是上一张卡」。

### 4.3 连线

| 操作 | 行为 |
|---|---|
| **右键从卡片拖到另一张卡片** | 建一条边；`fromSide` = 起点卡朝指针那一侧，`toSide` = 指针进入目标卡那一侧（「端点按鼠标轨迹定」）。途中画虚线预览 + 箭头，指针下的目标卡套一圈高亮 |
| **右键从卡片拖到空白处** | **在松手处新建一张卡片并连上**（中心发出 / 中心接收，两端都不写边信息）。新建卡片和建边是**一步**撤销 |
| **选中若干卡片 → 右键另一张卡片** | 每一张选中的都连到它（**中心到中心**，两端边信息留空）。选中一张就是单连，多张就是多连一——不用拖，点一下就成 |
| 拉到一半按 `Esc` | 作废，什么都不建 |
| 单击边 | 选中（变粗 + 端点圆点） |
| 双击边 | 编辑标签（一行文字，居中压线，带底色描边） |
| 选中边按 `Enter` | 编辑标签（和双击同一个编辑框）；清空提交 = 删标签 |

### 4.3.1 劈砍（切割线）

| 操作 | 行为 |
|---|---|
| **右键从空白处拖出一刀** | 划出一条刀锋，**松手时**把切到的卡片和连线一起砍掉（§14.19）。拖的时候切中的东西先标红，看得见会掉什么 |
| 右键从**卡片**起手 | 不是劈砍，是拉线（§14.14）——同一个右键，靠起手位置分家 |
| 划到一半按 `Esc` | 这一刀作废 |

> 砍断节点的口径等同 `Delete`：节点没了，它身上的边也一起走。**一刀只记一步撤销**。
| 选中边按 `Delete` | 只删边 |

> **自连不建**（松手回到自己身上 = 反悔），**同向重复边不叠第二条**（改成选中已有那条）。
> 右键卡片的规则：选中若干张时右键**选中集之外**的卡 = 建连线（一张连一条、多张连一束）；
> 右键**选中集里**的卡、或什么都没选中 = 原来的上下文菜单（换色 / 复制 / 删除 / 置顶置底）。
> 菜单的入口保留在「点选中的那张」上——不然多选之后就没法给这些卡弹菜单了。
> 四边中点的连线圆点仍然是删掉的状态（§14.8 #74）——新建走上面这两条路，不回到圆点。

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
| `Ctrl+T` | **反转选中边的方向**（方向 / 端点对调，箭头跟槽位走；没选中边就忽略） |
| `Tab` | **往右生成节点**（§14.21 / §14.22 / §14.23）：恰好选中一张卡时，右侧生成一张普通文字卡并连上一条边，新卡直接进编辑态；连按几次时孩子**从上往下排**（第一个垂直居中，后面接在最低孩子下面，被挪走的右侧孩子不算数）；**编辑态按 `Tab` 也行**——先收下正在打的字，再从这张卡长孩子（编辑笔记正文时不生、也不打断）；一步撤销。没选 / 多选 / 选中边时不动；`Shift` / `Ctrl` / `Alt` + `Tab` 不占用 |
| `Ctrl+G` | **打包成框**（§14.24）：选中的 ≥2 张卡包进一个新分组（包围盒外扩内边距 + 顶部留标题条），组压最底层、进选中，一步撤销 |
| `Ctrl+Shift+G` | **单节点转成框**（§14.24）：恰好选中一张时，框正好包住它 |
| `Alt+左键点组` | **跳跃式移动**（§14.24）：选中的卡整队平移进组（相对排布不动），组装不下强行撑开；Alt 点普通卡照常单选 |
| `Alt+拖成员` | **允许离开**打包组（§14.25）：只有把成员真的拖到组框外松手才脱离，框内挪动仍算成员。不按 Alt 时成员移到哪组跟到哪 |
| `Enter` | 单选时进编辑（分组标题是单行，编辑中按 `Enter` 就是「改完了」）；单选**边** = 改标签 |
| `Ctrl+=` / `Ctrl+-` | 选中卡片**调字号**（`canvasResizeStep` = 1.25，**锚在中心**，不会往右下角爬）。文字卡片随之重新贴合，看起来是整张卡变大；**没有上下限**。文件卡片没有可调的框，按内容重贴（等于不变） |
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

### 5.1 画布：坐标网格 + 轴上数字

| 元素 | 值 |
|---|---|
| 背景 | `p.canvas`（「凹陷的工作台」） |
| 主格 | `canvasGridMajorStep(zoom)` 走 1/2/5 阶梯（`10…100000`），1px `gridMajor`（`textPrimary`@8.5%），**轴上写坐标数字** |
| 次格 | **没有**。一格就是轴上相邻两个数字之间的距离，格子里不再切小格（2026-10-27 按用户要求去掉，`canvasGridMinorStep` / `gridMinor` 已删） |
| 阶梯规则 | 主格屏幕步长恒落在 `[64, 640)`：`zoom=1` 时 100，缩到 8% 时 1000，放到 800% 时 10。所以坐标数字永远是整数，也不会缩小时画上百万条线。缩放本身**没有上下限**（见 §3.1），阶梯走完（`< 8px` 一格）就不再画网格 |
| 原点十字 | `x=0` / `y=0` 两条，`axis`（accent@24%） |
| 坐标数字 | 10px `axisLabel`（`textTertiary`）。x 的数字**居中压在水轴上方** 3px（`canvasAxisLabelGap`），y 的数字**贴在竖轴右侧**、垂直居中；两根轴都在屏幕里时原点只写一个 `0`（x 那组），y 那组跳过 |
| 数字的显隐 | 数字是轴的刻度：那根轴滚出屏幕，那一组数字一起离开。主格屏幕步长 `< 32px` 时数字会互相压住，整组不写 |
| 线的锐度 | 网格线统一压在 `.5` 像素上，1px 不抗锯齿成两像素灰边 |
| 选区框 | 1px 虚线 accent@70%，内部 `accentSoft`@40% |

数字画在**内容之前**：它是背景的一部分，卡片压上去就盖住，不会像界面
chrome 一样浮在卡片上面（2026-10-28 八轮从画布边上的标尺带改过来）。

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
| 文字（渲染态） | **与打开的正文编辑器同一份排版**：`layoutLines` + `LiveLineStyle` + `LiveTableBlocks`，标题阶梯、高亮、分隔线、序号槽位、代码底片、表格网格逐项一致。在参考字号 15.5px 下排版，绘制时整体缩放到卡片字号 `AppText.ui × scale`（默认 13px），固定像素（圆点 5、复选框 15、内缩 16）按同一比例缩放 |
| 文字（编辑态） | 输入框里是**源码**：`AppText.ui`（13px）、行高 1.6，在世界坐标排；退出编辑再按渲染结果重贴 |
| 空卡片 | 正中三个点「•••」（不写「空卡片」这种说明书）。**编辑态也是这三个点**，输入框只出一根光标——两边都画就成了两层占位，位置也一定会差一点点 |
| 贴合内容 | 文字卡片跟着文字走，**宽高都双向**：字多了变宽、删了字缩回来，删光回到三个点的宽度。宽度上限 `canvasTextMaxWidth` = 420，超了按上限折行、高度增长。宽度额外留 `canvasTextFitSlack` = 1px，避免正好卡在折行临界点 |
| 最小尺寸 | 40×40（`canvasMinSize`）**只管链接卡片键盘改框和落卡兜底，不管贴合**。文字卡片没有自己的尺寸常量——它和打完字的卡片走同一套贴合：宽 = `canvasEmptyDots`（`•••`）量出来的宽 + 内边距，高 = 一行正文；**贴合没有下限**，字号缩一半卡片就窄一半。链接卡片仍按 `canvasDefaultWidth` = 250 |
| 文件卡片尺寸 | 全自动：收起 = 图标 + 文件名一行；展开 = 标题 + **整篇正文**。宽 = 正文最长一行（上限 `canvasTextMaxWidth` = 420）+ 内边距，高 = 正文排出来多高 + 标题行，**没有上限**。笔记改了就跟着重贴（正文长一行、卡片长一行），不存在裁剪 |
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

**渲染态的 markdown 正文不染色**：它和打开的笔记是同一份排版，字色、高亮、
标签底片都取编辑器的那一套（`textPrimary` / `highlightColors` / `accentSoft`）。
给正文再套一层卡片色，就等于「同一段字在白板里变了个颜色」——那正是这一轮
要消灭的不一致。彩色卡片染的是边框和标题/图标那一行。

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

> **`.nrs` 永远是纯 JSON**（2026-10-28 十四轮定案，§14.15）。曾经考虑过学 graphif 的
> `.prg` 做成 zip 工程文件（里面放 `board.json` + `images/`），最后否掉了：白板进 git，
> zip 是二进制，每次保存的 diff 都不可读、冲突也没法合。图片**不进文件**，只存库内
> 相对路径（和引用 `.md` 笔记同一个模型）。

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
坐标网格：主格 → 原点十字 → 轴上的坐标数字（屏幕坐标）
  ↓ save；translate(舞台中心) → scale(zoom) → translate(-center)   ← 进入世界坐标
连线 + 箭头 + 边标签（世界坐标，标签字号 ×1/zoom）
分组框（按面积从大到小：外层先画）
节点（文档顺序正序；文字、图标都在世界坐标排）
  ↓ restore                                                        ← 回到屏幕坐标
详情小图标 / 框选框 / 空板提示（屏幕坐标，尺寸恒定）
```

### 8.2 三条关键约定

1. **内容画在世界坐标**：一次 canvas 变换，几何直接写世界坐标。文字也在世界坐标排，
   Skia 按当前矩阵栅格化字形到设备分辨率，所以放大**不会糊**。
2. **装饰件画在屏幕坐标**：详情小图标、框选、边标签、线宽、箭头、边框粗细，都按
   `_px = 1 / zoom` 折算——屏幕上永远这么多像素，不跟着缩放变胖变细。
3. **文字排版要缓存**：渲染态正文走 `CanvasMarkdownCache`，按「节点 id + 用途」缓存整份
   排版，文字 / 倍率 / 宽度 / 主题变了才重排，**量尺寸和绘制共用同一份终稿**；标题、图标、
   边标签等零散文字走 `CanvasTextCache`，按节点 id 缓存 `TextPainter`，内容 / 宽度 / 颜色 /
   对齐 / 最大行数变了才重排。清理统一交给 State 的 `dispose()`。

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

不用嵌套 `GestureDetector`（卡片 / 边 / 空白会互相抢手势）。
一层 `Listener` 收全部原始指针事件，自己命中测试：

```
idle ──down on 卡片────→ maybeDrag ──move > 3px──→ dragging
     ──down on 边──────→ 选中边（等双击判标签）
     ──down on 空白────→ marquee / panning（看中键 / 空格）
```

双击判定用手写 `Timer` + `_tapWindow(target)`：同一目标、间隔 ≤ 300ms、位移 ≤ 6px。
不用 `DoubleTapGestureRecognizer`（留 40ms 挂起计时器还抢手势）。

### 9.2 命中测试（内容用世界坐标，装饰件用屏幕坐标）

从**上到下**问，第一个命中的赢：

1. 节点：矩形 `contains`，**倒序**遍历（后画的在上）；悬停时容差 `1/zoom`（`Rect.contains` 不含右 / 下边界）；
2. 边：点到贝塞尔的距离 < 6px / zoom（20 段折线近似）；
3. 空白。

（缩放手柄与连线圆点已在 2026-10-28 七轮移除，命中测试里不再有这两档。）

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
| `lib/core/utils/canvas_geometry.dart` | 重写 | `CanvasCamera`、贝塞尔、命中工具、插值（缩放手柄 API 已删） |
| `lib/ui/canvas/canvas_painter.dart` | **新增** | `CanvasScenePainter`（全画布单层自绘，正文用注入的 `CanvasMarkdownCache` 绘制）+ `CanvasTextCache`（图标、标题、边标签等零散文字）+ 边视觉 |
| `lib/ui/canvas/canvas_board.dart` | 重写 | 摄像机 / Ticker / `Listener` 状态机 / 编辑浮层 / 键盘 / 选择操作 / 连线创建 |
| `lib/ui/canvas/canvas_style.dart` | 重写 | 网格 / 坐标数字 / 描边卡片的配色令牌 + 主格阶梯（`canvasGridMajorStep`）+ 坐标文案（`canvasCoordinateLabel`）+ `canvasCardTextStyle`（要渲染态的正文不用它，见 `canvas_markdown.dart`） |
| `lib/ui/canvas/canvas_markdown.dart` | **重写** | 卡片正文的排版与绘制：`CanvasMarkdownDocument`（`measure` / `atWidth` / `paint` / `visibleText`）+ `CanvasMarkdownCache`（贴合与绘制共用一份终稿）。内部走编辑器的 `layoutLines` + `LiveLineStyle` + `LiveTableBlocks` |
| `lib/state/notes_controller.dart` | 改 | `referenceMarkdownFiles`（拖进来的文件 → 库内相对路径）+ `relativeVaultPath`；`importMarkdownFiles` 顺带返回导入出来的路径 |
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
| `test/canvas_document_test.dart` | 43 | 解析 / 序列化 / 三位小数 / 未知键 / 容错 / id / `expanded` |
| `test/canvas_geometry_test.dart` | 33 | 摄像机换算 / 锚点缩放 / fit / 插值 / 贝塞尔 |
| `test/canvas_board_test.dart` | 183 | 交互全链路（widget 测试 + 探针断言）+ 坐标网格阶梯 + markdown 贴合 / 拖入 / 引用卡片 + 选择操作规格（框选方向与按键 / Shift 范围选择）+ 连线创建（右键拖拽 / 选中后右键另一张 / Enter 写标签）+ `Tab` 右生节点（含连按往下排、编辑态）+ Section 框（打包 / 转框 / Alt 跳跃 / 双击分流）+ 自动包裹与 Alt 逃逸（§14.21–§14.25） |
| `test/canvas_markdown_test.dart` | 19 | 基础样式/标题阶梯与编辑器同源 + 分隔线/列表/引用/围栏/表格的块级表现 + 行内底片（代码/高亮/标签）+ 两遍贴合 + 缓存复用与失效 + 整篇落画布的冒烟 |
| `test/canvas_controller_test.dart` | 14 | 打开 / 新建 / 防抖 / 写失败 / 坏 JSON |
| `test/canvas_history_test.dart` | 6 | 撤销栈边界 |
| `test/canvas_pickers_test.dart` | 9 | 文件 / 链接选择、URL 归一化 |
| `test/canvas_store_test.dart` | 16 | 文件名、路径安全、真文件读写 |
| `test/shell_layout_test.dart` | +4 | **从文件列表拖进白板：卡片落在松手处**（真外壳 + 真手势，见 §14.12）；`Shift` 连选跨图片 / pdf / 笔记 / 白板、图片当锚点、文件夹不参与连选（§14.26） |

### 12.2 关键断言点

- **摄像机**：屏幕／世界互逆、`zoomedAt` 锚点世界坐标不变、`fit` 把内容装进 `舞台 - 2×90`、
  `fit` 空内容 / 零舞台不炸、值相等。
- **网格阶梯**：`canvasGridMajorStep` 的屏幕步长恒在 `[64, 640)`、放大单调不增、
  `canvasGridLineOffsets` 负原点不漏线、`canvasCoordinateLabel` 不外泄浮点噪声。
- **数据**：坐标末位无浮点噪声、整数落盘仍是 `int`、round-trip 幂等、旧键 `fromNode` 兼容。
- **连线创建**（§14.14）：右键从 A 拖到 B，`fromSide` / `toSide` 按松手点定（拖到 B 左
  边缘 → `right` → `left`）；拖到空白处新建一张卡并连上，两端留空；选中 A 后右键 B 建
  中心连线且不弹菜单；右键自己仍是菜单；拖回自己什么都不建；同向重复边不叠；`Esc` 作废。
- **多连一 / 一连多**（§14.18）：多选后右键从其中一张拖到目标（或**直接右键点目标**），每张都连过去（预览是一束线）；
  拖到空白处新建一张卡全连上；整批一步撤销、同向去重；`Ctrl+T` 反转选中边（方向 / 端点
  对调、箭头跟槽位走、再按复原）。
- **选择操作**（§14.13）：向左框选只留完全被盖住的、向右（同一批卡片）骑框的也算；
  Shift 框选加选、Ctrl 框选反选（框外不动）；Shift 点击从锚点撑框、锚点不动可再扩展、
  无锚点退化单选；无键点已选中的卡不清别人（组拖动）。
- **交互**：拖动 16 世界单位就停在 16（**不再吸附到 20**）、框选框是世界坐标（框选途中
  缩放，世界矩形一个数都不变、只是屏幕位置跟着动）、分组嵌套带走、WASD 惯性滑停后
  `debugTicking == false`、滚轮往上放大往下缩小。
- **markdown 卡片**：正文基础样式逐项等于 `editorProseStyle`（字号/行高/字距）、标题阶梯 1.74×→0.91×
  半粗、分隔线不落减号只落一条线、有序列表序号进槽位、高亮/代码/标签的圆角与内边距取编辑器常量、
  代码块计入末尾底片留白、表格行走自绘块；短句按内容收窄、长句顶到上限、倍率翻倍宽高一起翻倍；
  `fit` 的终稿就是 `get` 返回的同一份，文字变了旧排版不再冒充新文字。编辑时按源码贴合、退出编辑
  按渲染结果重贴；装不下的旧卡片在打开时重贴而装得下的原样不动。
- **拖拽落点**：从文件列表拖到白板，卡片左上角的**屏幕位置**等于松手点（走真外壳，
  回算 `camera.toScreen(topLeft) + 画布全局原点`）。拖拽途中树会重建、载荷会换对象，
  所以这条断言实际守的是「指针记在树 State 上」这个修法（§14.12）。
- **引用卡片**：拖 `.md` 落的是 `FileNode`（不是装着正文的 `TextNode`）、卡片上画的是那篇笔记
  渲染后的正文、换一份 `noteBodies` 再画一遍正文就跟着换、笔记不在了就没有正文、长笔记按正文
  排满**没有高度上限**（两百行 > 200 × 行高）、正文变长卡片跟着长高。
- **尺寸固定**：卡片没有缩放手柄，选中后拖右下角也只是移动（宽高不变）；卡片边上没有连线圆点，
  按在边上就是拖动卡片；`Ctrl+=` 对文件卡片不改框。
- **引用解析**：库内的路径原样返回（不复制）、大小写不同也算库内、库外的先导入再返回、顺序
  不变、`/vaultx` 不算在 `/vault` 里。
- **测试探针**：`CanvasBoardState` 暴露 `debugCamera` / `debugZoom` / `debugCenter` /
  `debugTargetZoom` / `debugStage` / `debugVisibleWorld` / `debugMarquee`（世界坐标）/
  `debugSelection` / `debugEditing` / `debugEditingEdge` / `debugColorOf` / `debugEdgeCount` /
  `debugLabelOf` / `debugPanning` / `debugDragging` / `debugTicking` / `debugEmptyHint`，
  以及文件卡片探针 `debugFileBody` / `debugFileExpanded` / `debugEditingFileBody` /
  `debugFileTitleRect`。

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
| 每帧重排文字吃帧率 | 渲染态正文由 `CanvasMarkdownCache` 按节点复用整份排版（`fit` 的终稿就是 `get` 的同一份）；图标、标题、边标签由 `CanvasTextCache` 复用，输入不变就不重排 |
| 卡片正文与编辑器两套样式漂移 | 卡片不再自己解析 markdown：直接走编辑器的 `layoutLines` + `LiveLineStyle` + `LiveTableBlocks`，基础样式取 `editorProseStyle`，固定像素常量与编辑器共用；`canvas_markdown_test.dart` 逐项对照编辑器断言 |
| 卡片多了卡顿 | 没有 Widget 树与布局，只有绘制；网格按屏幕步长排（恒 ≥ 64px 一格），轴上的坐标数字每帧现排十几条 10px 短串 |
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
| 12 | 背景是点阵还是坐标系 | **坐标网格 + 轴上的坐标数字**。主格 1/2/5 阶梯恒落在 64–640px 之间，数字永远整数。~~上 20px / 左 32px 不透明标尺带压在内容上~~（2026-10-28 八轮改成写在原点两条轴上，见 #79–#81） |
| 13 | 卡片长什么样 | **描边式**：中性半透明底（`surfaceRaised`@72%）+ 1px `textPrimary`@30%，**去掉投影** |
| 14 | 六种预设色还要不要 | 要，但**只染描边与文字**，不染底色。换色菜单的色点仍是实心色块 |
| 15 | 分组 | 改成 graphif 的 **Section 框**：不填底、12px 圆角、15px 标题 |
| 16 | 连线 | 变细变淡：1.2px `textPrimary`@30%，箭头 8px（原 2px / 10px） |
| 17 | 旧的点阵令牌 | `canvasGridSize` / `canvasGridStep` / `canvasGridOpacity` / `gridDot*` / `cardShadow` 全删，别再加回来 |
| 18 | 格子里还要不要小格 | **不要**。只有主格一层，一格 = 轴上相邻两个坐标数字的距离 |
| 19 | 右下角工具条 | **整颗删掉**（`canvas_toolbar.dart` 已移除）。缩放用滚轮、平移用中键拖——右下角那一小块留给画布本身 |
| 20 | 视野操作照 graphif 补齐 | 缩放：滚轮 + `[` `]`；平移：中键拖 / 空格拖 / `WASD` / `PageUp` `PageDown` `Home` `End`；重置：`F`（有选中就框住选中） |
| 21 | 缩放要不要上下限 | **没有上限**（2026-10-28）。原来的 `0.08 / 8` 是随手定的墙，一放大就撞。现在只留 `minZoom = 1e-6` 挡 0 和 Infinity；收敛判据改成相对值；缩到 `1e-5` 以下整块板子不到一像素，`_paintScene` 直接不画 |

### 14.4 2026-10-28（三轮：节点操作照 graphif 补齐）

参考 graphif 的「文本节点」操作说明图。这一轮补的是**键盘 / 浮层**，架构仍然不动。

| # | 问题 | 决定 |
|---|---|---|
| 22 | `Ctrl+F` 干什么 | **搜索节点**。贴着画布上边、水平居中（2026-10-28 八轮起不再避让标尺），边打边跳：命中第一张就选中 + 移镜头（**只移不改缩放**——搜索问的是「这张卡在哪」）。`Enter` / `Shift+Enter` 循环、`Esc` 关 |
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

### 14.6 2026-10-28（五轮：卡片支持 markdown + 拖入 .md）

用户：「让这个节点输入框支持 .md。也支持直接把 .md 文件拖入白板里。」

| # | 问题 | 决定 |
|---|---|---|
| 45 | 「节点输入框支持 .md」是什么 | 卡片正文按 markdown **渲染**：标题变大、`**粗**` 变粗、标记（`#` `**` `` ` `` `-` `>`）不占地方。存进 `.nrs` 的仍然是**源码**（`TextNode.text`），不是渲染结果——所以老文件不用迁移，纯文本照样显示 |
| 46 | 渲染放哪、怎么和量尺寸对齐 | `canvas_markdown.dart` 负责整篇排版与绘制。**画和量共用同一份终稿**：`_measureBlock` 走 `CanvasMarkdownCache.fit`，画笔走 `CanvasMarkdownCache.get`（九轮起，见 §14.10 #82–#92）。各写一套就会出现「画出来一行、量出来两行」 |
| 47 | 行内语法要不要另写正则 | **不写**。`**粗**` / `` `代码` `` / `[[双链]]` / `[文字](地址)` 全走 `core/utils/inline_syntax.dart` 的 `markdownInlinePattern`——和正文编辑器、图谱抽边是同一个扫描器，否则会出现「笔记里是链接、卡片上却是几个星号」 |
| 48 | 编辑时显示源码还是渲染结果 | **源码**。输入框里就是原文（所见即所打），卡片同时按**源码**贴合；退出编辑再按渲染结果重贴一次。两边量出来的宽高不一样（源码多两个井号、渲染后字号大一圈），贴着显示的那一种量，才不会一进编辑就把字挤出去。实现是 `_fitTextNode(node, {bool? rendered})`，缺省值按「是不是正在编辑的那张」判 |
| 49 | 打开旧板子时怎么办 | 文件里存的是**尺寸**不是「怎么算出来的尺寸」。旧尺寸是按纯文本量的，现在标题渲染更大就可能装不下、被卡片裁掉。所以 `initState` + `didUpdateWidget` 里跑一次 `_refitAllTextNodes()`：**只在装不下的时候**重贴（宽高都放得下就四个数原样放回去，在详细信息面板里改大过的尺寸不会被抹掉）。静默执行，不标脏、不进撤销栈。**（#76 起打开板子时全部重贴，尺寸收回内容大小——卡片已不能手动拖大）** |
| 50 | 拖进来的 .md 变成什么卡片 | **引用卡片（`FileNode`），不是拷贝**。用户原话：「更接近于白板引用了这篇 .md，它们是有关联的，并不是把 .md 移动到白板里……而且 .md 修改后，白板里的也同步修改」。所以 `.md` 还留在文件列表里，卡片只存相对路径（`file`），正文由 `CanvasBoard.noteBodies` 现取。一次拖几份就排几张，从上往下一张一张排（整摞以落点为中心，**#98 起改为指针 = 左上角**），只记一步撤销 |
| 51 | 卡片上显示什么 | 标题一行（图标 + 文件名去掉 `.md`，那**就是**笔记标题，见 `Note.title`），下面是被引用笔记的**正文**，按 markdown 渲染（和文字卡片同一套 `canvas_markdown.dart`）。正文排在标题下面 `canvasFileHeaderHeight` 处。**（#75 起展开态整篇全画，不按卡片高度截断，也没有 `maxLines`）** |
| 52 | 卡片多高多宽 | 拖进来时按正文贴一次：宽 = 最长一行（上限 `canvasTextMaxWidth`），高 = 正文 + 标题行（上限 `canvasFileMaxHeight` = 480）。**之后不跟着正文重贴**：卡片是一扇窗，笔记长长了就裁掉，想看自己拖大——不然用户拖过的尺寸会被每次改字顶回去。笔记被删/改名（正文取不到）就退回「标题 + 路径」的老样子，至少还看得出指向哪儿。**（已被 #75 / #76 取代）** |
| 53 | 库外的文件怎么办 | 白板存的是**库内相对路径**，所以库外的 `.md`（桌面、下载目录）要先变成库里的笔记——这一步是 `NotesController.referenceMarkdownFiles`：在库里的**原样返回相对路径**（不复制、不改名），库外的导入成新笔记再返回。前缀比较大小写不敏感（Windows 上 `C:\` 和 `c:\` 是同一个目录），且必须停在目录分隔符上（`/vaultx` 不算在 `/vault` 里） |
| 54 | 为什么画布不直接调 NotesController | 画布只认识 `document` / `files` / `noteBodies` 和几个回调。引用要读库、要导入，那是控制器的活，所以留一个 `onReferenceMarkdown` 回调由外壳接——`ui/canvas` 里没有 `NotesController`，也没有 `dart:io` |
| 55 | 拖放区域为什么套在最外层 | `DropRegion` 和画布**同大小**，`event.position.local` 直接就是画布坐标，卡片才会落在松手的地方。`flutter test` 里没有原生拖放层（建起来会异步抛异常），所以用 `systemDragAndDropAvailable` 把整块区域关掉 |
| 56 | 拖进来别的格式 | 只认 `.md` / `.markdown`。`docx` / `pdf` 进不了库也读不出结构——失败路径给一句提示（沿用「只报失败，不报成功」的老规矩） |

### 14.7 2026-10-28（六轮：从文件列表拖入 + 收起/展开 + 卡片里改正文）

用户：「我拖 .md 进入白板的时候没反应，检查一下。」「拖进去后直接显示 .md 文件名
就行了，就是白板里的一个普通节点。默认收起，可以点击文件名展开/收缩，看到 .md
里面的内容。」「（展开后）卡片里直接改。」「被拖入白板的 .md 文件修改后，文件列表
里的 .md 也是同步修改。」

根因一句话：**左侧文件列表的拖拽走 Flutter 自己的 `Draggable`，白板只挂了操作
系统的 `DropRegion`**。`Draggable` 只认 `DragTarget`，白板上一个都没有——松手
什么都不发生，连「拒绝」都没有。这一轮把第二条拖放通道接上，并把文件卡片改成
「一张可以展开的笔记节点」。

涉及文件：`vault_tree.dart`（payload 公开 + 指针）、`app_shell.dart`（`DragTarget`
+ `onEditFileBody`）、`canvas_document.dart`（`expanded`）、`canvas_board.dart`
（落卡 / 切换 / 正文编辑）、`canvas_painter.dart`（收起态 / 编辑态不画正文）、
`notes_controller.dart`（`writeNoteBody`）。

| # | 问题 | 决定 |
|---|---|---|
| 57 | 为什么拖进去没反应 | **两套拖放系统，只接了一套**。桌面 Explorer 拖进来走原生 OLE（`DropRegion`）；从左侧文件列表拖出来是 Flutter 的 `Draggable`，它只往 `DragTarget` 上落。白板上没有 `DragTarget`，于是松手什么都不发生——不是处理器写错了，是**根本没有接收方** |
| 58 | 怎么接 | 在 `app_shell` 里给 `CanvasBoard` 套一层 `DragTarget<VaultDragPayload>`（同一块区域、同一尺寸）。私有 `_DragPayload` 改名公开的 `VaultDragPayload`；笔记拖拽带的是**落点那一刻**的选中笔记（`tree._dragTargets()`，和文件夹行同一个口径），转成 `relativePath` 列表。文件夹拖拽（`folder != null`）在白板上直接拒绝。`DropRegion` 原样保留：桌面拖进来的文件仍然先导入成笔记，再落到同一个入口 |
| 59 | 落点怎么算 | `DragTargetDetails.offset` 是**反馈卡片的左上角**（`pointer - dragStartPoint`），不是指针——按它算，卡片会落在离鼠标一行高、半个面板宽的地方。所以指针单独记一份，`Draggable.onDragUpdate` 每帧写 `details.globalPosition`（~~写在 payload 的 `pointer` 字段上~~ → **十一轮改成写在树 State 上**，`payload.pointer` 只是一个转发到 `tree._dragPointer` 的 getter，见 §14.12）；落点由 `CanvasBoardState.addReferencedNotesFromGlobal(paths, globalPointer)` 内部 `globalToLocal` → `_toWorld`。原生那一路的 `event.position.local` 不动 |
| 60 | 拖进去先长什么样 | **收起**：一张只显示图标 + 文件名（去掉 `.md`，那就是笔记标题）的小卡。宽 = 那行文字量出来的宽 + 内边距（上限 `canvasTextMaxWidth`），高 = 一行正文 + 内边距；不画正文、不画所在目录。用户原话：「就是白板里的一个普通节点」。所有新建文件卡的入口（拖放 / 选择器 / 右键菜单）都从收起开始，不是只有拖放 |
| 61 | 怎么展开 / 收起 | **点标题条切换**。展开时把**左上角钉住**（标题停在原处，卡片往下长），收起时同样从左上角缩回去——按中心贴会把标题拽跑，用户点了三次都不知道自己点到哪了。切换时贴合一次：展开按正文、收起按标题。尺寸写回节点照常落盘，切换 = 一步撤销（复用按下时已记的那一步，不重复记） |
| 62 | 展开后多大 | 沿用五轮的 `_fitFileNode`：宽按正文最长行（上限 `canvasTextMaxWidth` = 420），高 = 正文 + 标题行（上限 `canvasFileMaxHeight` = 480）。**只在切换的那一下贴**，之后笔记再改只换内容、不动尺寸——卡片是那篇笔记的一扇窗，用户拖过的框不该被每次改字顶回去。**（已被 #75 / #76 取代）** |
| 63 | 展开状态存不存盘 | 存。`FileNode.expanded` 默认 `false`，只在 `true` 时写 JSON（和 `scale` 同一个规矩）。老白板没有这个键 = 收起——用户要的就是默认收起，文件卡片本身是今天才有的功能，没有需要保住的历史。五轮的 `_pendingFileFit` / `_settlePendingFileFits` 一并删掉：收起卡不需要等正文到手才能量 |
| 64 | 双击现在是什么意思 | 卡片分成两块：**标题条双击 = 打开那篇笔记**（沿用五轮）；**正文区双击 = 就地编辑正文**（和文字卡片双击进编辑一致）。单击正文只选中，不改展开状态——在展开的大卡片上点一下正文就收起来，那是灾难。收起状态整张卡都是标题条 |
| 65 | 单击标题和双击标题打架吗 | 单击在**松手**时切换，而且要求按下到松手没挪动（和拖动的 3px 死区同一个判据）；双击的第一下会先切一次，第二下按下去识别成双击就去打开笔记、松手不再切。结果：双击收起卡 = 展开 + 打开笔记。打开笔记会切走视图，回来时卡片是展开的——给单击加 300ms 延迟更难受，这个结果可以接受 |
| 66 | 卡片里怎么改正文 | 正文区盖一层隐形 `TextField`（和文字卡片同一套全手写 `InputDecoration`：不带底色、不带描边）。编的是**源码**、多行、`expands: true` 自己滚；标题行照画（它是展开/收起按钮，不是正文）。编辑中的那张卡**不画正文**，免得两层字叠在一起。`Esc` / 点别处 / 失焦都提交 |
| 67 | 改完写到哪 | 新回调 `CanvasBoard.onEditFileBody(path, body)`，外壳接到 `NotesController.writeNoteBody`：**正开着的那篇** → `updateBody` + `saveNow`（编辑器面板靠 `_syncBoundBody` 换过来）；**没开着的** → 照 `applyBodyIfEmpty` 的写法（`await _writing` → `_replace` → `notifyListeners` → `_store.save` → 记基线 / 刷时间戳），失败走 `_error`。这就是用户要的「文件列表里的 .md 同步修改」 |
| 68 | 反向同步还要写什么 | 不用。卡片读的一直是 `noteBodies[file]`，外壳每帧从 `allNotes` 现取——编辑器里改一个字，卡片下一帧就是新正文（五轮已经验过） |
| 69 | 正文编辑进不进白板的撤销栈 | **不进**。白板的撤销栈是 `.nrs` 的 JSON 快照，正文在 `.md` 里，压进去也回不去。笔记正开着时它的撤销栈按「外部覆盖」处理（`_bodyEpoch++`），是既有行为 |
| 70 | 右键菜单补什么 | 文件卡片加两项：`展开 / 收起`（按当前状态换文案）、`打开笔记`。其它卡片不变 |
| 71 | 拖拽提示给哪一层 | `DragTarget` 悬停复用 OS 拖放那层 `_dropping` 提示（`setExternalDropHover`）；`onLeave` / `onAccept` 都收掉。两条通道共用一层提示，用户看到的是同一件事。**（已被 #77 取代：整层提示删除）** |
| 72 | 落卡之后选中谁 | 新落的这一摞（沿用 `addFileCards`：从上往下一张一张排、整摞以落点为中心、只记一步撤销）。一次拖五篇进来至少看得见最后一张，不是五张叠成一摞 |

**测试**（§12 同步补）：

- 文档：`expanded` round-trip；缺键 = `false`；只在 `true` 时落盘。
- 白板：`addReferencedNotesFromGlobal` 落的是收起卡（尺寸 ≈ 标题一行）；点标题展开
  （尺寸变大、正文画出来、`expanded` 为 true）、再点收起；拖着标题移动 16 世界单位
  不会切换；`Ctrl` + 单击不切换；双击标题条走 `onOpenFile`；双击正文进编辑、提交后
  `onEditFileBody` 收到路径和源码；编辑中画笔不画正文。
- 控制器：`writeNoteBody` 对开着的草稿（body 改 + 写盘）和没开的笔记（改列表 + 写盘）
  各一条；笔记不存在返回 false。
- 接线：`VaultDragPayload.notePaths()` 取的是落点那一刻的选中；`folder` 拖拽不被白板接受。

### 14.8 2026-10-28（七轮：去掉手柄和连线圆点，文件卡片全部显示）

用户：「不允许拖拽边缘改变节点宽度和高度！不显示四周中间的那个圆点！」「我从文件
列表的 .md 拖放到白板里的时候，我的鼠标在哪里松手，就把 .md 文件放到哪里！！不需要
显示松手引用这篇笔记！」「节点不需要高度限制！我拖拽进去的 .md 里面有很多内容！全部
显示出来！」（AskUserQuestion 补充：缩放手柄「全都去掉」，连线圆点「晚点会重构新的」，
宽度上限沿用 420，高度不要上限。）

| # | 问题 | 决定 |
|---|---|---|
| 73 | 缩放手柄 | **四角 + 四边中点全部删掉**。`_Interaction.resizing`、`_handle` / `_resizeId` / `_resizeStart`、`_resizeTo`、`_handleAt`、`_cursorFor`、`_paintHandles`、`CanvasResizeHandle` / `resizeRect` 一并删除。卡片尺寸只由内容决定，拖角 / 拖边回到「移动卡片」 |
| 74 | 连线圆点 / 从圆点建边 | 全部删除：四边中点不再画圆点，`_connectDotAt` / `_finishConnect` / `connectPreview` 删除。**文档层保留**（`fromSide` / `toSide` / 箭头 / 标签），已有的边照常渲染、命中、改标签、删除；~~新建连线的交互等用户重新设计一版再做~~（**十三轮补上了：右键拖拽 + 选中后右键另一张，见 §14.14**，`_Interaction.connecting` / `CanvasConnectPreview` 以新语义回来了） |
| 75 | 文件卡片高度 | 删除 `canvasFileMaxHeight`。展开态高 = 正文排出来多高 + 标题行，**没有上限**；`_paintReferenceBody` 不再按卡片高度算 `maxLines`，整篇都画。「一篇五千字笔记拉成几千像素」是预期行为，不是 bug |
| 76 | 笔记改了尺寸怎么办 | `didUpdateWidget` 里比较展开卡片引用的正文实例（`oldWidget.noteBodies[file]` vs 新的）——变了就把文件卡片全部重贴（`_fitFileNodes`）。打开板子时也全部重贴一次，把历史尺寸收回内容大小。之前「展开态尺寸归用户」的前提（用户能拖大）已经不存在了 |
| 77 | 拖放提示 / 落点 | `_DropHint`（「松手引用这篇笔记」）、`_dropping`、`setExternalDropHover`、外壳的 `onMove` / `onLeave` 全部删除。落点仍然是指针：`Draggable.onDragUpdate` 每帧记指针 → `addReferencedNotesFromGlobal` → `_toWorld(globalToLocal(pointer))`，原生拖放走 `DropRegion` 的 `event.position.local`（它和画布同大小）。**（指针改记在树 State 上，见 §14.12 #99）** |
| 78 | `Ctrl+=` 对文件卡片 | 没有可调的框，`resizeSelectionBy` 对它只调 `_fitFileNode`（通常等于不变）。文字卡片仍然改字号，链接卡片仍然改框 |

**删掉的 API**：`CanvasResizeHandle`、`resizeRect`、`connectPreview`、
`CanvasBoardState.setExternalDropHover`、`debugResizing`、`canvasFileMaxHeight`、
`canvasCardMinSide`。`CanvasSide` / `anchorOf` / `nearestSide` / `edgeGeometry` 保留
（边还在用）。

**测试**：几何里「缩放卡片」整组删除；白板里「缩放手柄」「从圆点建边」几组换成
「尺寸固定」和「卡片边上没有圆点」；高度上限断言改成「两百行 > 200 × 行高」；
新增「笔记改了，展开卡上的正文跟着改，卡片跟着长高」。

### 14.9 2026-10-28（八轮：坐标数字挪到轴上）

用户：「把上方和左侧的坐标数字，移到中间，类似图2里的样子。」参考图是一块
画布应用（izoa）的截图：数字不贴屏幕边，而是跟着**世界原点的两条轴**走——
x 的数字压在水轴上方，y 的数字贴在竖轴右侧，原点共用一个 `0`。

| # | 问题 | 决定 |
|---|---|---|
| 79 | 上 / 左标尺带 | **整条删除**：`_paintRulers` / `_paintRulerText`、`canvasRulerThickness` / `canvasRulerSideWidth`、`rulerBackground` / `rulerTick` / `rulerEdge` 令牌一并删。搜索框不再避让标尺，改贴画布上边 12px（`_searchRect`），内容也不再被两条不透明带截断 |
| 80 | 坐标数字画在哪 | 世界原点是两条轴：x 的数字**居中压在水轴上方** 3px（`canvasAxisLabelGap`），y 的数字**贴在竖轴右侧**、垂直居中，都是 10px `axisLabel`（`textTertiary`）。数字是**背景**（`_paintAxisLabels` 在内容之前画），卡片压上去就盖住，不像界面 chrome 浮在最上面 |
| 81 | 轴滚出屏幕了怎么办 | 数字跟着轴走：那根轴不在视口里，那一组数字就不写——数字是轴的刻度，不是常驻边栏。两根轴都在屏幕里时原点只写一个 `0`（x 那组），y 那组跳过 `k == 0`；主格屏幕步长 `< 32px` 时数字互相压，整组不写 |

**删掉的 API**：`canvasRulerThickness`、`canvasRulerSideWidth`、`canvasRulerLabel`
（改名 `canvasCoordinateLabel`）、`CanvasStyle.rulerBackground` / `rulerText` /
`rulerTick` / `rulerEdge`，顺手清掉手柄遗留的 `CanvasStyle.handle` / `handleRing`。

**测试**：「坐标网格」组里的文案断言改名 `canvasCoordinateLabel`；条数不变
（画布 201 条、全量 1567 条全绿）。

### 14.10 2026-10-28（九轮：卡片正文与编辑器逐项对齐）

用户：「白板里的 .md 要对标打开的 .md……高亮和分割线、序号也是。检查还有
没有其他不一致的地方，改为一致。」盘点下来不是一处两处，是两**套渲染器**：

| # | 问题 | 决定 |
|---|---|---|
| 82 | 卡片有一份「简易 markdown 渲染器」 | **整份删掉**。卡片不再自己解析/排版，直接调用编辑器的 `layoutLines` + `LiveLineStyle` + `LiveTableBlocks`；同一条管线、同一份常量，才谈得上「逐项一致」 |
| 83 | 字号/行高/字距 1.6 / 0 对不上编辑器 | 在**参考字号 15.5**（编辑器默认 `proseSize`）下排版，基础样式直接取 `editorProseStyle(p, 15.5)`；绘制时整块 `scale(AppText.ui × node.scale / 15.5)`，圆点、复选框、代码内缩这些固定像素按同一比例缩 |
| 84 | 分隔线画成 `──────` 字形 | 与编辑器同一个 `_paintMarkers`：1px 线落在像素栅格上、横贯正文列 |
| 85 | 有序序号留在正文里 | 序号进槽位、强调色半粗等宽数字、按正文首行基线对齐；无序圆点 5px、复选框 15px、嵌套导轨全部照抄编辑器几何（`canvas_markdown.dart` 的 `_paintMarkers` / `_paintRails`） |
| 86 | 行内代码/高亮/标签是硬边矩形 | 与编辑器同一套圆角底片：代码 `surfaceSunken` r3、标签 `accentSoft` r5 padX6 padY1、高亮 `HighlightColors.darkFill` r4 padX1.5 rowBox（纵向内缩 16%）；分组仍走 `groupFillBoxesByLine`（为此去掉它的 `@visibleForTesting`，两处生产代码共用） |
| 87 | 代码块是一行一块灰底，没有语言标签 | 整块圆角底片 + 右上角语言标签 + 左右 16px 内缩；末块把 `kCodeSlabBottomPad` 算进卡片高度，圆角不被裁 |
| 88 | 表格画成原始竖线 | 表格行走 `LiveTableBlocks` 的自绘块（网格、合并、列宽、纸面）。卡片是半透明的，`paper` 传「卡片底色合成到画布上」的结果，否则卡片里会浮出一块更暗的矩形 |
| 89 | 量尺寸和绘制各排一遍 | 新增 `CanvasMarkdownCache`：`fit` 把两遍贴合的终稿留在缓存里，`get` 按「文字 + 倍率 + 宽 ±0.5px + 主题」判重后直接复用；文字变了旧排版立刻失效（`matches` / `visibleText` 都按当前文字核对） |
| 90 | 卡片颜色染正文 | **不再染**：正文按编辑器配色画。彩色卡片染边框和标题/图标（见 §5.3） |
| 91 | 双链别名 | 跟随编辑器：按行排版显示 `wikilinkTarget` 的原样内部文本（`目标|别名`），不自作主张只留别名 |
| 92 | 图片 | **仍未渲染成图**：图片块要图片提供者 + 异步解码 + 行失效重排，卡片只显示替代文字。这是已知差距，不算「样式不一致」；下一步接 `LiveImageBlocks` 时一起补 |

**已知取舍**：编辑器默认 `proseSize` 可以被用户改（15.5 起步），卡片固定用
15.5 作参考再整体缩放——比例始终一致，只差 `snapLineHeight` 取整的一点量化。

### 14.11 2026-10-28（十轮：桌面文件不再直接落成卡片）

用户：「移除从桌面文件拖拽 `.md` 到白板里的功能。只能从桌面拖进文件列表，然后
从文件列表里拖入 `.md` 到白板。不能直接从桌面拖入白板。」

| # | 问题 | 决定 |
|---|---|---|
| 93 | 桌面来的文件还落不落卡 | **不落**。`CanvasBoard._onDropFiles` 整份删掉，画布那层 `DropRegion` 只负责把桌面文件挡回去 |
| 94 | 为什么不让它「自动导入再引用」 | 那条路（#53 / #54 的 `onReferenceMarkdown`）会让同一份文件有**两个入口**，而一个入口会悄悄往库里写新笔记。用户要的是「先入库、再引用」这条单向流程：桌面 → 文件列表（导入，看得见结果）→ 白板（引用，只存相对路径） |
| 95 | 挡住了要不要吭声 | **要**。`onDropOver` 仍返回 `copy`——返回 `none` 后 `onPerformDrop` 根本不会触发，用户看到的就是「拖了没反应」（和 #56 的老毛病一样）。落下来弹一句「文件请先拖到左侧文件列表」，光标在拖放途中会短暂显示成可复制，这是有意的取舍 |
| 96 | 库外导入那套代码留着吗 | `NotesController.referenceMarkdownFiles` **删掉**：唯一调用方就是这条被移除的通道，留着只会让人以为功能还在。`relativeVaultPath` 保留（库根前缀比较的工具函数，大小写不敏感 + 停在目录分隔符，有独立测试），测试组随之改名为 `relativeVaultPath` |
| 97 | 文件列表那条通道受不受影响 | 不受。`NoteListPanel` 的 `DropRegion` + `importMarkdownFiles` 原样；外壳那层 `DragTarget<VaultDragPayload>` 变成**唯一**的落卡入口 |
| 98 | 松手的地方到底落在卡片的哪个角 | **左上角**。原来整摞以指针为**中心**摆（`x = anchor.dx - width/2`），卡片 250 宽就等于整体左移 125——手感上就是「没落在鼠标处」。现在指针 = 第一张的左上角，整摞左对齐往下排，和跟着指针走的预览片同一个角，松手不跳；只有不给落点的调用（视口正中那种）才按整摞居中 |

### 14.12 2026-10-28（十一轮：拖进白板的卡片落回拖拽起点）

用户：「我从文件列表里拖拽 `.md` 文件到白板里的时候，我鼠标在哪里松开，这个 `.md`
文件就落在哪里。目前的情况是，我松开后，文件并不在我的鼠标落点，而是在左侧很远的地方。」

「左侧很远」= **拖拽的起点**（列表里那一行）。#98 的「指针 = 左上角」没写错，
错的是这个「指针」压根没更新过。

| # | 问题 | 决定 |
|---|---|---|
| 99 | 指针为什么停在起点 | **`Draggable.data` 是拖拽开始那一刻取下的那一份**（`_startDrag` 里 `data: widget.data` 交给 `_DragAvatar`），松手时 `DragTarget` 拿到的就是它。但拖拽期间文件树一直在重建（`_beginDrag` → `_selectOnly` 的选中态、指针经过文件夹时的 `_hoverFolder` 高亮），而 `_fileRow` 每次 build 都 `new VaultDragPayload(...)`。`onDragUpdate` 的闭包引用的是**当前** widget，写进的是**重建后的新载荷**；被交出去的旧载荷只在第一次 update 时拿到过值，而那次的值正好是按下点。于是 `payload.pointer` 永远是拖拽起点 |
| 100 | 怎么修 | 指针**挪到 `VaultTreeState._dragPointer`**：`onDragUpdate` 写、`_beginDrag` 清、`onDragEnd` 清。`VaultDragPayload.pointer` 从字段改成 `get pointer => tree._dragPointer`——和 `notePaths()` 完全同一个思路（按**松手那一刻**的状态现算，而不是按拖拽开始那一刻的快照）。载荷重建多少次都不影响 |
| 101 | 为什么不给载荷加「共享槽」、也不用 `onDragEnd` 回填 | 共享槽就是 State 那一个字段，绕一圈没区别。`onDragEnd` 回填太晚：`_DragAvatar.finishDrag` 先调 `didDrop`（目标方的 `onAcceptWithDetails`）再调 `onDragEnd`，回填时落点已经算完了 |
| 102 | 坐标换算本身有没有问题 | **没有**。`addReferencedNotesFromGlobal` 的 `box.globalToLocal` + `_toWorld` 是对的：隔离用例里「列表 280 宽 + 画布」松手 `(700, 320)` 落在 `(700, 320)`。诊断方法是打日志比对 `identityHashCode(payload)`——三份载荷交替出现、松手交的是第一份，一眼就看得出来 |
| 103 | 为什么原来的测试没抓到 | `canvas_board_test.dart` 里那条 `addReferencedNotesFromGlobal` 用例把**全局坐标当本地坐标**用（harness 的 canvas 在 `(0,0)`，两者恰好相等），所以 `globalToLocal` 那一段等于没测；而且它是直接调 state 方法，绕开了 `Draggable` / `DragTarget` 的整套拖拽。新用例必须走**真外壳 + 真手势**，并且逐帧 `moveTo`，中途的树重建才会真的发生 |

**改动的文件**：`lib/ui/shell/vault_tree.dart`（`_dragPointer` + 载荷 getter）、
`test/shell_layout_test.dart`（新增 1 条，真外壳拖拽）。

**测试**：「从文件列表把笔记拖进白板：卡片落在松手的地方，不是拖拽的起点」——
修复前卡片落在 `(196.5, 119)`（拖拽起点），修复后落在 `(737, 340)`（松手点）。
用例末尾推 2 秒把自动保存的定时器走完，否则报「A Timer is still pending」。

### 14.13 2026-10-28（十二轮：选择操作照 graphif 规格补齐）

用户给了 graphif 的「选择操作」思维导图（`design/` 那套参考的一部分）：**框选**
按方向分碰撞 / 完全覆盖、按按键分替换 / 加选 / 反选；**左键点击**分单选 /
Shift 范围选择 / Ctrl 加选；另有一条没展开的「特性A：框选优先级问题」。

| # | 问题 | 决定 |
|---|---|---|
| 104 | 框选方向决定什么 | **向右拖（含竖直）= 碰撞**：矩形相交就算选中。**向左拖 = 完全覆盖**：整张卡的矩形都得在框里，骑在框边上的不选。从右下往左上拖的人心里想的是「只留被我整个框住的」，判据要更严。覆盖判定用手写比较而不用 `Rect.containsRect`——后者不含边界，紧贴框边的那张卡会漏；这里的语义是「盖住」，边贴边也算 |
| 105 | 框选按键决定什么 | **不按键 = 替换**（按下空白时已清空，松手时框到谁就是谁）；**`Shift` = 加选**（框中的并进现有选中，旧的不清）；**`Ctrl` = 反选**（框里已选的取消、未选的选中，框外不动）。键读**松手那一下**的 `HardwareKeyboard`——拖到一半再按 Shift 也是合法操作。`Shift+Ctrl` 一起按未定义，按 Shift 口径（加选）处理 |
| 106 | 特性A：框选的优先级 | **按在卡片 / 边上永远是选中或拖动，框选只能从空白处发起**。框选起手碰不到内容——不然想拖一张卡的第一帧就变成拉框，两头都是灾难。这条是现状的书面化，不是改动 |
| 107 | `Shift` 点击是什么 | **范围选择**：锚点 = 上次**无键**点中的那张卡，`Shift` 点另一张，两张卡的矩形撑起的包围框里**碰到就算**（和向右框选同一个判据）。选中是**替换**不是叠加——语义是「这两角之间的都要」。**锚点不动**：再点第三个对角还是从原来的角撑框。没有锚点（没点过 / 被删了 / 框选过 / 全选过）时退化为单选，那张卡顺便当起新锚点 |
| 108 | 「单击 = 单选」要不要字面执行 | **点已选中的卡不清别人**。字面执行的话，多选之后「按住其中一张拖」的第一帧就把选中清成一张，组永远拖不动。Figma / Excalidraw 都是这么折中的：点没选中的 = 单选；点已选中的 = 选中保持。锚点无论如何都换成这张卡 |
| 109 | 边怎么办 | `Shift` 点击边 = 加选（和 `Ctrl` 同）；没有范围选择——两角撑框的语义只对卡片成立。框选照旧不选边 |

改动：`canvas_board.dart`（`_rangeAnchorId`、`_selectInMarquee` 重写、`_marqueeHit`、
`_selectRangeFrom`、卡片 / 边 / 空白三处按键分支、`deleteSelection` / `selectAll` 清锚点）。

**测试**（+7，全在 `框选与全选` 组）：向左覆盖 / 向右碰撞（同一批卡片两种结果）、
Shift 框选加选、Ctrl 框选反选、Shift 点击范围选择（含锚点不动再扩展）、Shift 点击
无锚点退化单选、点已选中的卡不清别人。

### 14.14 2026-10-28（十三轮：连线创建）

用户给了 graphif 的「创建连线」思维导图，两条路：**拖拽式**（右键从卡片拖出去）和
**点击式**（框选一张，右键另一张）。图上有两处没写死，先问过用户：

- 「在空白处松开」只写了「连线自动是中心发出 / 中心接收」，没说目标是谁
  → 用户选 **A：在松手处新建一张卡片并连上**；
- 「框选后右键另一张」和现有的右键上下文菜单抢同一个手势
  → 用户选 **A：右键另一张卡就是建连线**（只在恰好选中一张、且点的是别的卡时）。

| # | 问题 | 决定 |
|---|---|---|
| 110 | 右键怎么同时干三件事 | **全部推到松手时判**：按下只记「按在哪张卡上 / 按在什么位置」。走够 3px = 拉线；没走 = 一次「点」，再按选中状态决定是建连线还是弹菜单。按下就弹菜单的话，右键拖拽永远走不到（§16.3 第 17 条） |
| 111 | 端点怎么「按轨迹定」 | `fromSide` = 源卡片**朝指针那一侧**（`nearestSide(from.rect, 松手点)`），`toSide` = 目标卡片**朝指针那一侧**（指针压在左边缘就是 `left`）。不记「进入那一瞬」——那要逐帧记历史，而松手点本身就带着轨迹的结果 |
| 112 | 空白处为什么新建卡片而不是取消 | 图上那条分支写的是「中心发出 / 中心接收」——**先有一条边**才谈得上端点。没有目标时唯一说得通的解释就是「松手处长出一张新卡」，这也是 Obsidian Canvas / tldraw 的手感。用户确认选 A |
| 113 | 新建卡片要不要进编辑 | **不进**。建完选中那条**边**——这一下的主语是「连线」，不是「一张新卡片」。想写字就双击那张卡 |
| 114 | 新卡和边记几步撤销 | **一步**。`_mutate` 里一次加卡 + 加边；撤销一次就回到拉线之前 |
| 115 | 右键菜单怎么办 | 选中**恰好一张**、且右键点的是**别的**卡 → 建连线（不弹菜单）。右键自己、多选、没选中 → 原来的菜单。代价：选中 A 之后想给 B 弹菜单，得先点空白清掉选中——这是用户明确接受的取舍 |
| 116 | 自连 / 重复边 | 自连不建（松手回到自己身上 = 反悔，**也不走「空白落卡」**——判据用矩形包含，不是 id）。同向重复边不叠第二条：两条完全重合的线谁也点不中，改成选中已有那条 |
| 117 | 预览长什么样 | 一条 accent 虚线 + 箭头（8px、半角 0.36rad，和真边同款），指针下有卡片时给它套一圈 2px 高亮。画在**世界坐标**里、尺寸按 `1/zoom` 折算，所以缩放时线跟着内容走但粗细不变。预览压在卡片**上面**画——被卡片盖住就看不见指针了 |

改动：`canvas_board.dart`（`_Interaction.connecting`、`_connectFromId` / `_connectTo` /
`_connectTargetId`、`_rightDown*`、`_onSecondaryDown` 改为只记位置、`_onPointerMove`
的拉线分支、`_finishRightGesture`、`_updateConnectPreview`、`_connectPreview`、
`_connectNodes`、`_connectToBlank`、`_singleSelectedNode`、`Esc` 取消、探针
`debugConnecting` / `debugConnectTarget`）、`canvas_painter.dart`（`CanvasConnectPreview`
+ `_paintConnectPreview`）。

**测试**（+7，新组 `连线创建（右键）`）：轨迹定边（`right` → `left`）、空白处新建卡
并连上（两端留空）、选中后右键另一张（不弹菜单、两端留空）、右键自己仍是菜单、拖回
自己什么都不建、同向重复边不叠、`Esc` 作废。

### 14.15 2026-10-28（十四轮：文件格式仍是纯 JSON，图片走库内引用）

用户先给了 graphif 的 `.prg` 规格（「本质是 zip，改后缀就能解压，里面是所有引用图片，
解压改图只要文件名不变就还认得」），要求 `.nrs` 也这样。我按这个方向起了 zip 容器
（`archive` 依赖 + `canvas_bundle.dart`），然后用户问了一句「**保留 json 是不是更好？**」
——这一问是对的，方案当场翻掉。

| # | 问题 | 决定 |
|---|---|---|
| 118 | `.nrs` 要不要做成 zip | **不做，保持纯 JSON**。白板进 git，zip 是二进制：每次保存的 diff 变成一坨不可读的字节，冲突没法合，`git log -p` 也看不出「这周白板改了什么」。§6.4 当初为 diff 做的稳定键序，会跟着一起白费 |
| 119 | 那图片怎么跟着白板走 | **只存库内相对路径**，图片本身留在 vault 里（`FileNode.file`，和引用 `.md` 笔记同一个模型 #50）。改图 = 改库里那张，白板下一帧就是新的；不会出现「库里一份、板子里一份，改了一处另一处不知道」 |
| 120 | 代价是什么 | **白板不再是自包含的单文件**：把 `.nrs` 拷给别人，图片不会跟着走。用户接受——他要的是 git 友好，不是可携带 |
| 121 | zip 那套代码怎么办 | **整份撤掉**：删 `canvas_bundle.dart`、去掉 `archive` 依赖、`pubspec.lock` 复原、删掉确认文档。不留半成品，也不留「以后可能用得上」的死代码 |
| 122 | 图片卡片怎么表示 | 复用 `FileNode`（`type: "file"`，`file` = 库内路径），**不新增节点类型、不动文件格式**。渲染上分两支：后缀是图片 → 图标换成图片图标、**点标题不展开**（它没有正文，展开只是个空框）、双击交给图片页 |
| 123 | 图片像素什么时候画 | **下一轮**。这一轮先把「引用」这条通道打通（能拖进来、存路径、看得见是一张图）；画布上真正画出图片需要异步解码 + 缓存 + 首帧重排（§14.10 #92 说的那套），等「图片节点」的规格一起做 |

改动：`vault_tree.dart`（`VaultDragPayload.image` + `referencePaths()`、图片行可拖）、
`app_shell.dart`（`DragTarget` 收 `referencePaths()`）、`canvas_board.dart`
（`_isImagePath` + 展开护栏）、`canvas_painter.dart`（图片卡用图片图标）。

**测试**（+2）：图片拖进白板存路径不拷贝（真外壳 + 真手势）、图片卡点标题不展开。

### 14.16 2026-10-28（十五轮：图片卡真的把图画出来）

用户：「图片拖进白板里后，在白板里显示出来啊，只显示一个图片文件名干嘛」。

上一轮只做到「引用」，卡片上还是文件名 + 图标。这一轮把它变成一张**图**。

| # | 问题 | 决定 |
|---|---|---|
| 124 | 画笔怎么拿到图片 | **外壳读字节、画布解码**。画布是一支 `CustomPainter`，要的是 `ui.Image`，用不上 Widget 那套图片管线；而 `dart:io` 不能进 `ui/`（Web 也要编译这一份）。所以新增 `CanvasBoard.imageBytesOf` 回调，外壳用 `imageBytesAt('$vault/$path')` 读盘 |
| 125 | 解码是异步的，画笔是同步的 | **先画占位、到了就换**。`_ensureImages()` 在 build 里给没加载的图片排队（`_imagesLoading` 去重），解码完 `setState` 重画；字节读不出来就留在「图标 + 文件名」的样子，**不弹错**——一张图打不开不该盖住用户正在做的事 |
| 126 | 卡片多大 | **长边 320 世界单位，按原图比例**（`canvasImageCardSide`）。不按原图像素铺开：4K 截图落下来就是四千世界单位，比整屏还大。解码前给 320×198 的占位框，图到了再按真实比例贴，避免「先瘦成一条再撑开」 |
| 127 | 图片和文件名画哪个 | **画图，就不画文件名**。卡片上唯一的正文就是那张图；文件名在详细信息面板和右键菜单里都看得到。图没加载出来时才退回「图标 + 文件名」 |
| 128 | 内存在哪释放 | `dispose()` 里把所有 `ui.Image` 逐个 `dispose()`。解码出来的图占的是原生内存，不还回去会跟着每块打开过的板子累积 |

### 14.17 2026-10-28（十五轮：图片卡可以拖右下角改大小）

用户：「白板里的图片节点，可以拖拽右下角改变大小。**仅图片节点可以，其他的不允许**」。

§14.8 #73 当初把缩放手柄**全部删掉**，理由是「卡片尺寸只由内容决定」。图片卡是
这个前提的例外：它显示的不是内容排版，是一张有原始像素尺寸的图，用户当然想调大小。

| # | 问题 | 决定 |
|---|---|---|
| 129 | 谁有手柄 | **只有图片节点**。文字卡尺寸是排版结果、文件卡是正文长度、分组是用户圈的区域——给它们手柄等于开一个「拖完又被贴合顶回去」的玩笑。判据用后缀（`kImageExtensions`），和文件树共用一份 |
| 130 | 手柄什么时候出现 | **只有选中时**。平时不画：一屏十几张图每张都挂个角，看着像一堆控制点。命中判定也只在选中集里找，所以「没选中时拖右下角」仍然是移动整张卡，行为和以前一致 |
| 131 | 手柄多大 | 视觉 12px、命中 14px，**屏幕像素**（`/zoom` 折算）。世界坐标的话缩到 20% 就只剩两像素，按不中 |
| 132 | 拖角保不保比例 | **保**。不保的话一张 2:1 的图能被拉成任意形状——用户拖的还是同一张图，只是画变形了。实现取「按宽算」和「按高算」两个结果里变化更大的那个，横拖听宽、竖拖听高，跟手又不走形 |
| 133 | 哪个角钉住 | **左上角**。和「拖进白板时指针 = 左上角」同一个约定：卡片从左上往右下长，位置不跳 |
| 134 | 撤销 / 落盘 | 按下时记一步（和拖动同一个规矩），松手 `onChanged` 标脏。不会拖一下记几十步 |

改动：`canvas_painter.dart`（`canvasImageHandleSize` / `canvasImageHandleRect` /
`_paintImageHandles`，画在 `restore()` 之后的屏幕坐标里）、`canvas_board.dart`
（`_Interaction.resizingImage`、`_imageHandleAt`、`_resizeImageTo`、悬停光标、
探针 `debugResizingImage`）。

**测试**（+3）：拖右下角变大且宽高比仍是 2:1、左上角不动；非图片卡片右下角没有
手柄（拖那一下仍是移动）；图片读不出来时退回文件名不崩。

### 14.18 2026-10-28（十六轮：多连一 + `Ctrl+T` 反转）

用户给了 graphif 的「多连一」规格图：框选多个节点 → 从其中任意一个节点开始右键
拖拽 → 松手后**每一张**都连到目标；配上第 1–4 步演示图（17 / 25 / 26 三张选中，
拖到 27，三条线；`ctrl+T` 之后箭头整批掉头）。另一支「在空白位置松开」和单节点的
规则对齐：空白处**新建一张卡**，所有选中的都连到它。

| # | 问题 | 决定 |
|---|---|---|
| 135 | 多选拖拽的源头是谁 | **拖的起点卡在选中集里 → 选中集就是源头**；不在 → 就它自己（单连，十三轮行为不变）。选中集里混进来的边 id 会被 `nodeById` 过滤掉 |
| 136 | 预览画几条 | **每个源头一条**（`CanvasConnectPreview.froms` 变成列表）。只画被拖的那张，用户会以为只连一张——预览撒谎比没有预览更糟 |
| 137 | 批量怎么记撤销 | **一批一步**。新卡 + 一束边也是一步（和 #114 同一个规矩）；撤销一次回到拉线之前 |
| 138 | 同向边去重 | 延续 #116：已有的跳过不叠。批量时**已有的也进选中**——全都没得建时选中已有那束，用户至少知道自己没白拖 |
| 139 | 空白处松开（多选） | 和单选对齐：松手处**新建一张卡**，所有选中的都连到它（不是每张选中的各建一张新卡）。两端留空走自动选边 |
| 140 | `Ctrl+T` 反转什么 | `from` / `to` 和两侧端点对调；**两端箭头不换**——`fromEnd` / `toEnd` 是位置属性，跟着「起点 / 终点」槽位走，反转之后箭头本来就该出现在线的另一端（a ──▶ b 变 b ──▶ a，箭头从 b 的头上挪到 a 的头上）。label / 颜色不动。选中集里混着的卡片原样不动；没选中任何边时 `Ctrl+T` 落回 ignored |
| 141 | 反转怎么落盘 | `fromNode` / `toNode` 是 `final`，换方向只能换一个新对象（id 不变，选中和引用都还认得）；一次 `Ctrl+T` 记一步撤销 |
| 142 | 多选时**不拖**，直接右键目标行不行 | **行**（用户明确要求：拖拽和点击两条路都要能多连一）。原规则「恰好选中一张」放宽成「选中若干张、且点的是**选中集之外**的卡」→ 每张都连过去；点的是选中集**里**的卡 → 仍是菜单。菜单的入口必须留一处，否则多选之后这些卡再也弹不出菜单 |

### 14.19 2026-10-28（十七轮：劈砍 / 切割线）

用户：「接下来做右键画线劈砍功能，劈砍功能可以砍断线、砍断节点。」给了 graphif 的
`https://graphif.dev/docs/prg` 文档作参考。查过原文（`entity/connectable-entity/text-node`）：

> 「**删除**：使用切割线切节点来删除」（节点文档的删除章节，第一句）
> 「删除涂鸦：可以直接用右键斩断涂鸦笔画，也可以选中后按 Delete 删除。」

也就是说 graphif 里「切割」首先是**删除**手段（等价于我们的 `Delete`），右键就是那把
刀。这决定了语义：砍断 = 删掉，不是「切成两段」。

| # | 问题 | 决定 |
|---|---|---|
| 143 | 右键已经有三件事了，劈砍怎么进来 | **靠起手位置分家**：按在**卡片**上 = 拉线（§14.14）；按在**空白**上 = 划刀。空白处右键本来就是弹菜单，现在「点」还是菜单、「拖」变成刀——和 #110 同一个思路（把决定推到松手 / 走没走够 3px） |
| 144 | 砍断节点是什么语义 | **删掉它**，连带它身上的边，和 `Delete` 一个口径。不切成两个节点——白板没有「半个节点」这种东西，graphif 的原文也是「切节点来**删除**」 |
| 145 | 砍断连线是什么语义 | **删掉那条边**。§4.3 说过「选中的边按 Delete 只删边」，砍断就是它的手势版 |
| 146 | 一刀砍多个怎么记撤销 | **一步**。网格里划一刀穿过五张卡，撤销一次全回来，不是退五次 |
| 147 | 「切到」怎么判 | 卡片：**线段穿矩形**（端点在内 / 穿过四条边之一，`segmentHitsRect`）。连线：贝塞尔按 **16 段折线**近似，和刀锋折线做线段相交（`polylineCrossesSegment`）。命中包含擦边——刀正好从线头切过也该算 |
| 148 | 拖的时候看得见吗 | **看得见**：刀锋画 accent 2px 实线；被切到的卡片套一圈 `danger` 红框、被切到的连线在原曲线上再描一道红。松手前就知道会掉什么，比砍完才发现砍错了强 |
| 149 | 什么时候扫命中 | **升级成劈砍的那一帧就扫一次**（起手点 → 当前点），之后每次移动接一点再扫。只在「下一次移动」时扫的话，用户快划一下松手，这一刀一个东西都切不到——这是实际踩到的坑（§16.3 第 20 条） |

改动：`canvas_geometry.dart`（`segmentsCross` / `segmentHitsRect` /
`polylineCrossesSegment`）、`canvas_board.dart`（`_Interaction.slashing`、
`_slashPoints` / `_slashNodes` / `_slashEdges`、`_updateSlash` / `_slashHits` /
`_cutAlongSlash`、`Esc` 取消、探针 `debugSlashing` / `debugSlashNodes` /
`debugSlashEdges`）、`canvas_painter.dart`（`slash` / `slashNodes` / `slashEdges`
+ `_paintSlash`）。

**测试**（+6）：一刀划断连线（两头卡片留着）、一刀砍掉卡片（连带它的边，只横穿自己
不误伤旁边那张）、只有擦边不进屋的留着、一刀只记一步撤销、从卡片起手是拉线不是劈砍、
`Esc` 作废。

### 14.20 2026-10-28（十八轮：图片节点的四条规格）

用户给了 graphif 的「图片节点」规格图：创建（拖 PNG/JPG/JPEG/WEBP 进舞台、截图
`Ctrl+V`）、缩放（悬浮 `Ctrl+滚轮`、或拖右下角**绿色**块）。还提了一句：粘贴后删掉
卡片，`prg` 里那张图仍然占体积，要用「文件 > 附件管理器」清理。

| # | 问题 | 决定 |
|---|---|---|
| 150 | 桌面图片能直接拖到白板吗 | **能**（推翻 #93 的一半）。#93 定的是「`.md` 必须先走文件列表导入」，理由是不让白板绕过「导入成库里的笔记」这一步。图片不一样：它没有正文、没有索引，直接拖进来就是「存一份到库里 + 引用它」。非图片文件仍然劝一句「请先拖到左侧文件列表」 |
| 151 | 拖进来的图存在哪 | **那块白板所在的文件夹**，文件名 `image_年月日_时分秒_毫秒.png`（`NotesController.saveCanvasImage`）。带毫秒是因为同一秒连粘两张会互相覆盖。图进库之后卡片只存相对路径，和拖文件列表进来的图完全同构 |
| 152 | `Ctrl+V` 粘贴谁 | **板内剪贴板空着才去问系统要图**。反过来的话，「复制一张卡再粘贴」会变成「粘出一张截图」。粘出来的图同样先落库再引用，落在指针位置 |
| 153 | `Ctrl+滚轮` 缩放什么 | **只对图片生效**，压在别的卡片上仍然是缩放画布。文字卡的尺寸是排版结果、文件卡是正文长度，改了也会被贴合顶回去——给它们「改大小」是骗人（#129 同一个理由） |
| 154 | 滚轮缩放怎么记撤销 | **700ms 算一阵，一阵只记第一步**。滚轮一秒能发十几次事件，每格记一步的话滚两下要按十几次 `Ctrl+Z`。窗口定时器在 `dispose` 里取消 |
| 155 | 手柄为什么是绿的 | graphif 的图上是绿块；而且 `accent` 在卡片上已经表示「选中」，再拿它画手柄，两个语义就混了。绿色取 `tableInkColor(green)`，主题换了也跟着走 |
| 156 | 「附件管理器」要不要做 | **不要**，这是 B 方案（§14.15）白送的好处：图片本来就在库里、是用户自己的文件，删卡片不会删它，也就不存在「文件里躺着没人用的图占体积」。反过来，删卡片也不该顺手删库里的图——那可能是笔记也在用的同一张 |

改动：`canvas_board.dart`（`onSaveImage` / `onDropImageFiles` / `readClipboardImage`
三个回调、`pasteImageFromClipboard`、`_scaleImageBy` + `_imageScaleWindow`、
`Ctrl+滚轮` 分支、`_onDesktopDrop` 收图片）、`canvas_painter.dart`（手柄改绿）、
`notes_controller.dart`（`saveCanvasImage`）、`app_shell.dart`（接三个回调）。

**测试**（+3）：悬浮图片上 `Ctrl+滚轮` 改图不改画布且等比、压在文字卡上仍是缩放画布、
粘贴图片先存库再落成引用卡。

改动：`canvas_board.dart`（`_connectSources`、`_connectNodes` → `_connectMany`、
`_connectToBlank` → `_connectManyToBlank`、预览多起点、`_reverseSelectedEdges`、
`Ctrl+T` 键位）、`canvas_painter.dart`（`CanvasConnectPreview.froms` + 预览按源头逐条画）。

**测试**（+7）：多连一两条边全建出来并进选中、整批一步撤销、已连过的跳过且已有的
进选中、多选拖到空白只新建一张卡且全连上（两端留空）、**多选后直接右键目标也能连**
（不拖）、**多选后右键选中集里的那张仍是菜单**、`Ctrl+T` 反转 / 端点对调 / 箭头跟槽位
走 / 再按复原。

### 14.21 2026-10-28（十九轮：`Tab` 往右生成节点）

用户：选中节点后按 `Tab`，往右生成一个普通节点。这是 graphif 的「生孩子」键——
思维导图式的骨架：`Tab` 长出右孩子，连打字都不用换地方。

| # | 问题 | 决定 |
|---|---|---|
| 157 | `Tab` 生什么、生在哪 | **普通文字卡**，排在选中卡**右侧**（右边缘 + 48 间距）、**垂直居中**对齐；一条边从选中卡指向新卡（两端留空，走自动选边）。生成后新卡进选中并**直接进编辑态**——接着打字就是在写新卡，和双击新建同一个手感 |
| 158 | 什么情况才响应 | **恰好选中一张卡**：没选、选了多张、选中的是边，`Tab` 都不动。它是「生孩子」的键，不是泛用的「往下加」；多选该连哪张没有不言自明的答案，先不给 |
| 159 | 撤销怎么记 | 一张卡加一条边是**一步**撤销（`_mutate` 一次），`Ctrl+Z` 整个收回 |
| 160 | 组合键让不让路 | `Shift+Tab` / `Ctrl+Tab` / `Alt+Tab` 全部不占用——切焦点、切窗口是别的软件的地盘，只认光杆 `Tab` |

改动：`canvas_board.dart`（`_createRightFromSelection`、`_onKey` 挂 `Tab` 分支，放在
`Ctrl+T` 后面、方向键前面）。

**测试**（+5）：选中卡按 `Tab` 右侧出卡且边指向新卡（垂直居中）、新卡进选中并直接
进编辑态、一步撤销卡边一起消失、没选中时不动、选中的是边时不动。

### 14.22 2026-10-28（二十轮：连按 `Tab` 孩子从上往下排）

用户：同一个节点连按 `Tab` 生好几个孩子时，别全部叠在正右方——叠成一摞只能看见
最上面那张，要**自动从上往下排**（graphif 图上的样子：一列孩子整整齐齐）。

| # | 问题 | 决定 |
|---|---|---|
| 161 | 连按怎么排 | **往下排**：第一个孩子仍贴着选中卡垂直居中，第二个接在最低孩子的底边 + 24 下面，以此类推；x 都在同一列（右边缘 + 48）。只做「往下长」不做「对称重排」——对称意味着每次都要挪已有的卡，用户手摆过的位置会被打乱 |
| 162 | 哪些孩子算数 | 只数**还在右侧**的（`child.rect.left ≥ source.rect.right`）。孩子被用户挪到左边或很远的地方去了，就不该再把新孩子顶到很远的下面；这时新孩子从原位（垂直居中）重新开始排 |

改动：`canvas_board.dart`（`_createRightFromSelection`：先 `_fitTextNode` 贴出真实
高度，再数右侧孩子的最低底边定 y——顺序反了垂直居中会差半个身高）。

**测试**（+2）：连按三次 `Tab` 三个孩子从上往下排且同列（第一个垂直居中）、被挪到
左侧的孩子不算数（新孩子从原位垂直居中重新排）。

### 14.23 2026-10-28（二十一轮：编辑态按 `Tab` 也生孩子）

用户：正在编辑的节点按 `Tab` 也要直接生成节点（而不是只在「选中但没进编辑」时管用）。

| # | 问题 | 决定 |
|---|---|---|
| 163 | 编辑态 `Tab` 的次序 | **先收字，再长孩子**：`_commitEdit` 把输入框里的文字落到卡片上，然后从**正在编辑的那张卡**（`_editingId`，不是选中集）往右生一个节点并连上，新卡接着进编辑态。一段话没打完就按 `Tab`，等于「这段就到这里，下一个」。源卡走 id 而不是 `_selected`：编辑态下选中集可能不是它 |
| 164 | 焦点怎么交接 | 提交时**不把键盘抢回白板**（`_commitEdit(restoreFocus: false)`）。`requestFocus` 是排队生效的：先请求白板焦点、再让新卡输入框拿焦点，白板那次会晚一步落地，输入框失焦又触发一次提交，新卡的编辑态当场被抹掉（§16.3 #22） |
| 165 | 编辑笔记正文时 `Tab` | **吃掉，什么都不做**：文件卡片展开编辑的是整篇 `.md` 正文，`Tab` 不该凭空长出一张卡；但也不能放行——放行就轮到焦点遍历，`Tab` 会把焦点跳到别处、顺手提交掉编辑，等于打一半被打断 |

改动：`canvas_board.dart`（`_createRightFromSelection` 拆出 `_createRightFromNode(id)`、
`_onKey` 在「输入框吃键盘」那道闸**前面**加编辑态 `Tab` 分支、`_commitEdit` 加
`restoreFocus` 开关）。

**测试**（+2）：编辑态打「父节点」后按 `Tab`——字收下了、新卡从这张出发连上、新卡
接着进编辑态；编辑笔记正文时 `Tab` 不生卡、也不打断编辑。

### 14.24 2026-10-28（二十二轮：Section 框基础操作）

用户给了 graphif 的「Section 框基础操作」规格图：创建（多选 `Ctrl+G` / 右键菜单 /
单节点 `Ctrl+Shift+G`）、改组名（双击标题）、移动（拖标题或边框，宏观视野拖内部
空白）、换色（和节点相同）、Alt 跳跃进出、组内双击建卡。

| # | 问题 | 决定 |
|---|---|---|
| 166 | 双击组怎么分工 | **标题条改组名、内部空白建卡**。以前双击组任何位置都是改组名，想在组里建卡只能先建到组外再拖进来。标题条 = 组框顶部 `canvasGroupTitleHeight(scale)` 那一条（画笔和命中测试共用同一个函数，两边对不上是不可能的）。双击内部空白 = `createCard` 落在指针处——成员是几何包含，卡自动归组、拖组带走，不需要任何归组代码 |
| 167 | `Ctrl+G` 打包什么 | 选中 **≥2** 张卡 → 新组 = 选中卡的包围盒外扩一圈内边距、顶部再多留一条放标题；组压到最底层、进选中；**一步**撤销。成员是几何包含，所以打包不改任何卡片的任何字段——插一个框进去事情就完成了。没选够两张不动（单张走 `Ctrl+Shift+G`） |
| 168 | `Ctrl+Shift+G` | **单张直接转成框**：恰好选中一张时，框正好包住它。和 `Ctrl+G` 共用键位，Shift 切换语义；张数不对就落回 ignored |
| 169 | 右键菜单 | 选中集里有 ≥2 张卡时，卡片菜单最上面多一项**「打包成框」**（和 `Ctrl+G` 同一个动作）。名字跟着 graphif 叫「框」 |
| 170 | `Alt+左键` 跳跃 | 跨层级的跳跃式移动：**选中的卡整队平移进按住的组**——选中集包围盒中心挪到组中心，卡之间的相对排布不动（图上第三步「移动到合适位置」留给用户）；组框装不下就**强行撑开**（扩到把跳进来的卡连同内边距都装下）。只认组：Alt 点普通卡不拦，照常单击选中——组才收孩子。选中集为空、或选中的本来全在这个组里（中心都在框内）也不折腾。Alt 不与 Ctrl / Shift 组合 |

已有的不用再做：拖标题 / 边框 / **内部空白**都是拖整组（组是节点、矩形命中，子卡靠
中心包含跟着走）；换色与节点同一个菜单；宏观视野下拖内部空白同样是拖组。

改动：`canvas_painter.dart`（`canvasGroupTitleHeight(scale)`：标题条高度，画笔与命中
共用）、`canvas_board.dart`（`_groupTitleRect` / `_inGroupTitle` + 探针
`debugGroupTitleRect`、双击组分流、`_groupSelection`、`_jumpSelectionIntoGroupAt`、
`_onPointerDown` 挂 Alt 分支、`_onKey` 挂 `Ctrl+G`、`_showCardMenu` 加「打包成框」）。

**测试**（+7）：`Ctrl+G` 打包（组压底 / 框住两张 / 选中组 / 一步撤销）、没选够两张
不动、`Ctrl+Shift+G` 单张转框、右键菜单「打包成框」、双击组内空白建卡（组名不动）、
`Alt+点组` 跳入 + 强行撑开 + 一步撤销、`Alt+点普通卡` 照常单选。旧的「双击分组改
标签」「分组标题是单行 Enter 收下」两条改走标题条双击。

### 14.25 2026-10-28（二十三轮：打包的组始终包裹成员，Alt 拖到框外才脱离）

用户：打包出来的组，成员**移到哪组跟到哪**、框的宽高跟着变、**始终包裹**成员；
只有按住 `Alt` 拖拽把它拖到组**外面**，才算离开组。

| # | 问题 | 决定 |
|---|---|---|
| 171 | 哪些组会长大 | 只有**打包 / 转框造出来的**组（`GroupNode.autoFit = true`）。手动「新建分组」的框是用户圈的一块固定区域，不参与自动贴合——不然用户画一个大框想把远处的东西收进来，框自己缩成一小团就没法用了 |
| 172 | 成员怎么算 | 中心在**判据框**里的节点。判据框**不能**用刚贴出来的那个：贴合每帧都跑，框越贴越紧，拿它判成员会一路缩水（移出过一次的卡永远回不来）。所以判据框在**按下时冻结**（`_groupJudge`），整段击键 / 拖动 / 松手都拿这一份；撤销 / 换文档时清空（快照里的是真值） |
| 173 | 普通拖动 | 被拖的成员**永远算成员**，框跟着它跑（不然拖一下就被判成「离开」）。框是**紧贴包裹**：成员包围盒 + 内边距 + 顶部标题条，所以往右拖的时候左缘也会收进来 |
| 174 | `Alt` 拖动 | `Alt` 只是**允许**离开，不是立刻离开：这一段拖动里被拖的卡按「中心在不在判据框内」判——在框内挪两下**不算**离开（松手还是成员，框重新包住它），真拖到框外才脱离，框缩回去包剩下的 |
| 175 | 松手判一次 | 松手就是判决时刻，判完丢掉判据缓存；下一段操作重新以当时的框为起点 |
| 176 | 还有哪些操作会喂大框 | 双击建卡 / `Tab` 生孩子 / 粘贴 / 拖文件进来（落点在框内就归组）、删除成员（框缩回去）、字号 `Ctrl+=`、文件卡展开、图片缩放、`Alt` 方向键微调。全部走同一个 `_refitAutoGroups` |

改动：`canvas_document.dart`（`GroupNode.autoFit` + 写盘 / 解析，只在 true 时写）、
`canvas_board.dart`（`_groupJudge` / `_dragOriginsGroupBox` / `_dragEscape`、
`_refitAutoGroups({escape})`、`_forgetGroupJudges`、`_dragTo` / `nudgeSelection` /
`createCard` / `_createRightFromNode` / `_pasteFrom` / `addFileCards` /
`deleteSelection` / `resizeSelectionBy` / `_toggleFileExpanded` / `_scaleImageBy` /
`_loadImage` / `_restore` / `_onPointerDown` / `_onPointerUp` 各挂一次）。

**测试**（+5）：拖成员组跟着走（右缘贴最右成员）、`Alt` 拖到框外才脱离（框缩回去）、
`Alt` 只在框内挪不算脱离、手动新建的框固定不动、删除成员框缩回去。

### 14.26 2026-10-28（二十四轮：文件列表里除文件夹外的任何文件都能 `Shift` 连选）

用户：文件列表里的文件，不管是 `.md`、`.nrs`、图片还是别的什么，除了文件夹，
都要能 `Shift+左键` 连选。

| # | 问题 | 决定 |
|---|---|---|
| 177 | 以前为什么选不上 | 树里只把**笔记**和**白板**算进「可选中行」（`_selectableRows`），图片 / 附件虽然画出来了，但点了只打开、不记选中，`Shift` 连选的范围里也就没有它们 |
| 178 | 怎么改 | 加第三套选中集合 `_selectedAssets`（附件相对路径）和第三个锚点 `_anchorAssetPath`；`_selectableRows` 把附件也放进去，`Shift` 连选的范围自然覆盖三种类型。三套集合仍**分开存**——批量删除各走各的（笔记删正文、白板搬文件），附件暂时没有批量操作，但高亮和连选是同一套。文件夹不进可选中行：点它是展开 / 收起，不参与连选 |

改动：`vault_tree.dart`（`_selectedAssets` / `_anchorAssetPath` / `_Pickable` 记录类型、
`_selectableRows` 收附件、`_visibleAssets`、`_anchorIndex` 认附件锚点、
`_selectRangeTo` 三套一起填、`_tapRow({file})`、`_selectOnlyAsset`、
`_pruneToVisible` / `didUpdateWidget` 清理、附件行的 `selected` 高亮）。

**测试**（+3，在 `shell_layout_test.dart`）：`Shift` 从图片连选到白板（中间的 pdf /
笔记 / 白板全亮、不顺手打开白板）、图片当锚点往回连选到笔记、`Shift` 点文件夹只
展开 / 收起、选中不变。

---

## 15. 验收清单

- [x] 功能栏点「白板」能新建并切过去；文件树点 `.nrs` 能打开
- [x] 空白处拖 = 框选：向右 = 碰撞、向左 = 完全覆盖；不按 = 替换、`Shift` = 加选、`Ctrl` = 反选；点击：不按 = 单选、`Shift` = 锚点范围选择、`Ctrl` = 加减选（§14.13）；中键 / 空格拖平移；`WASD` 惯性平移
- [x] 滚轮以光标为锚点**平滑**缩放（往上放大、往下缩小），全程锚点不漂
- [x] 右下角没有工具条；`Ctrl+0` 回 100%；`Ctrl+Shift+H` 适应窗口
- [x] 双击空白出卡片并直接能打字；`Esc` / 点空白退出编辑
- [x] 卡片正文与打开的编辑器同一套 markdown 渲染（标题 / 列表 / 引用 / 高亮 / 分隔线 / 代码 / 表格 / 双链 / 链接）；编辑时回到源码（图片仍只显示替代文字，见 §14.10 #92）
- [x] 白板里 .md 的渲染与打开的编辑器**逐项一致**：标题阶梯、高亮圆角色块、分隔线、序号槽位、圆点、复选框、引用竖线、行内代码、标签胶囊、代码底片与语言标签、表格网格（图片仍只显示替代文字，见 §14.10 #92）
- [x] 文件列表里**除文件夹外的任何文件**（笔记 / 白板 / 图片 / 其它附件）都能 `Shift+左键` 连选，范围跨类型也照选；文件夹 `Shift` 点只展开 / 收起（§14.26）
- [x] 从文件列表把 `.md` 拖到白板上：落成**引用**那张笔记的卡片，**松手的地方就是卡片左上角**（多张时整摞左对齐往下排），没有额外的拖放提示层；拖拽途中无论树重建多少次，落点都跟着指针走（§14.12）；桌面上的 `.md` 直接拖到白板**不落卡**，只提示先去左侧文件列表
- [x] 文件卡片收起 = 一行文件名；点标题展开 = **整篇正文全部显示**（高度没有上限，不裁剪）
- [x] 卡片没有缩放手柄 / 连线圆点：拖角、拖边都是移动；已有连线照常渲染、选中、改标签、删除
- [x] 建连线：右键从卡片拖到另一张（端点按轨迹定边）、拖到空白处新建一张卡并连上、选中一张后右键另一张（中心到中心）；自连不建、同向重复边不叠、`Esc` 作废、一步撤销（§14.14）
- [x] **多连一**：多选后从其中一张右键拖到目标，每张都连过去（拖到空白则新建一张卡全连上），整批一步撤销；**一连多**：框选中所有连线按 `Ctrl+T` 整批反转（§14.18）
- [x] **劈砍**：右键从空白划一刀，松手砍断切到的卡片和连线（拖时先标红）；砍断节点等同删除、连带它的边；一刀一步撤销（§14.19）
- [x] `.nrs` 仍是**纯 JSON**（可 diff、可手改）；图片只存库内相对路径，从文件列表拖图片进白板得到一张图片卡，点标题不展开（§14.15）
- [x] 图片卡把图**画出来**（按原图比例、长边 320）；**只有图片卡**能拖右下角绿色块改大小，且保持比例、左上角钉死；其余卡片右下角拖起来仍是移动（§14.16 / §14.17 / §14.20）
- [x] 图片的另两条路：从**桌面**把 PNG/JPG/JPEG/WEBP 直接拖到板上（自动导入库里再引用）、`Ctrl+V` 粘贴截图；悬浮在图上 `Ctrl+滚轮` 等比缩放（§14.20）
- [x] 选中一张卡按 `Tab`：右侧生成一张普通文字卡并连上一条边，新卡直接进编辑态；连按几次孩子从上往下排不叠在一起（被挪走的右侧孩子不算数）；**编辑态按 `Tab` 同样生效**（先收字再生孩子；编辑笔记正文时不生也不打断）；一步撤销；没选 / 多选 / 选中边时不动；`Shift` / `Ctrl` / `Alt` + `Tab` 不占用（§14.21 / §14.22 / §14.23）
- [x] Section 框：`Ctrl+G` 把 ≥2 张选中的卡打包成组、`Ctrl+Shift+G` 把单张转成框、多选右键菜单有「打包成框」；双击**标题条**改组名、双击**内部空白**在组里建卡（自动归组）；`Alt+左键点组` 把选中的卡跳跃移入并强行撑开；拖标题 / 边框 / 内部空白都是拖整组；换色与节点相同（§14.24）
- [x] 打包出的组**始终自动包裹**成员：成员拖到哪框跟到哪、宽高跟着变；只有按住 `Alt` 把成员拖到框**外**松手才脱离（框内挪动不算），脱离后框缩回去包剩下的；手动「新建分组」的框是固定区域，不自动贴合（§14.25）
- [x] 拖动卡片坐标是自由浮点（拖 16 就停 16）；尺寸只由内容决定
- [x] 多选整组拖动；分组带走框内卡片（含嵌套）；`Ctrl+A` 全选；`Delete` 连带删边
- [x] `Ctrl+Z` / `Ctrl+Shift+Z` / `Ctrl+Y` 能一路退回再走回
- [x] 关掉再打开，坐标（三位小数）、颜色、连线、标签一个不差
- [x] 浅色 / 深色主题下都读得清（卡片底色、连线、网格）
- [x] 坐标数字写在世界原点的两条轴上（x 压在水轴上方、y 贴在竖轴右侧，原点一个 `0`）；轴滚出屏幕数字跟着离开，画布边上不再有标尺带
- [x] 空白板 / 单卡片 / 大坐标三种极端输入都不崩
- [x] `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` 1622 条通过（`test/widget_test.dart` 是模板残留，不计）

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
15. **`Draggable.data` 是拖拽开始时的快照**，松手交出去的就是那一份。可变状态（指针、
    当前选中）**不能存在载荷对象上**——拖拽途中 widget 重建会造出新载荷，`onDragUpdate`
    只往新的那份写，旧的那份冻在起点。要记就记在 State 上，载荷暴露 getter 现读（§14.12）。
    排查手法：打印 `identityHashCode(payload)`，看一次拖拽里到底出现了几份。
16. **widget 测试里手势点必须落在窗口内**（十二轮）。`h.screenOf(world)` 算出来的屏幕
    坐标超出 `pumpBoard` 的窗口（默认 1000×700）时，`startGesture` / `moveTo` 的
    hit-test 落不到画布上，整个手势**悄无声息地什么都没做**，测试还以为自己在测框选。
    写拖拽用例前先估一下相机：fit 之后 `world → screen` 的映射会把远处的内容缩进来，
    框的起终点要挑映射后仍在窗口里的世界坐标。
17. **白板文件不能变成二进制容器**（十四轮）。zip / sqlite 这类「自包含单文件」在
    git 里是灾难：diff 不可读、冲突没法合。判断标准不是「格式先不先进」，是「这份
    文件要不要进版本库」。要自包含就得接受放弃 diff；两者都要，只能把大块内容
    （图片）留在库内、文件里只存路径。
18. **一个键要干两件事时，把决定推到松手**（十三轮）。右键既要弹菜单（点）又要拉线
    （拖），按下就弹菜单的话拖拽永远走不到。做法：按下只记「按在哪」，走够 3px 判成
    拖、没走判成点。同理「选中一张后右键另一张建连线」也只能在松手时判——按下就改
    选中，就再也分不出「点的是别的卡」还是「点的是选中的那张」。
19. **原地改文档之后一定要 `setState`**（十五轮补）。文档是可变对象、画笔的
   `shouldRepaint` 又恒为 `true`，所以「改了模型」不会自己触发重画——不 `setState`
   就没人排帧，用户看到的是「拖的时候不动，松手才跳一下」。拖动那条路包了
   `setState`，拖角那条路漏了，症状一模一样。测法：改完**先别 pump**，断言
   `tester.binding.hasScheduledFrame` 为真——模型改了但没排帧，这条会失败。
20. **「等下一次事件再算」会漏掉最后一帧**（十七轮）。劈砍原本只在 `_updateSlash`
   （指针移动）里扫命中；可升级成劈砍的那一帧已经用「起手点 → 当前点」画好了刀，
   用户紧接着松手时**再没有下一次移动**，于是这一刀扫不到任何东西。规则：状态刚建立
   的那一刻就要把该算的算一遍，别指望下一个回调。同理 `setState` 里提前清空的字段
   要先抄出来再用（收尾时 `_slashPoints` 已被清空，`_cutAlongSlash()` 拿到的是空刀）。
21. **手势起手点必须落在可视区域内**（再踩一次第 16 条）。`screenOf(world)` 算出
   `x = -41` 时 `startGesture` 静默失败，整段测试白跑；而且「起手在卡片里」会走成
   拉线而不是劈砍——测劈砍要从**窗口内的空白**起手。
22. **同一个事件里别「先交焦点再抢回来」**（二十一轮）。编辑态按 `Tab` 的流程是
   「提交当前输入 → 新建卡片 → 新卡进编辑态」，如果提交时照常把焦点还给白板，那次
   `requestFocus` 会**晚于**新卡输入框的请求落地：输入框先失焦 → `_editorFocus` 的
   listener 看到 `_editingId != null` 又提交一次 → 新卡的编辑态当场被抹掉（症状是
   `debugEditing == null`，卡片建出来了但打不了字）。修法：`_commitEdit` 加
   `restoreFocus` 开关，交接链条中间那一环不抢焦点。
23. **「谁在框里」不能用刚贴出来的框算**（二十三轮）。`_refitAutoGroups` 每帧把
   框贴成「成员包围盒 + 内边距」，下一帧再拿这个新框判成员，成员集会一路缩水：
   某张卡移出过一次边界之后，框再也不会包含它的中心，它就被永久踢出成员集（症状
   是「拖一下框就不跟了、甚至框原地不动」）。规则：**判据要用本段操作开始时的
   快照**（按下时冻结进 `_groupJudge`），贴合只负责产出新框，不负责改判据。

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

### 16.5 七轮：去掉手柄 / 圆点，文件卡片全部显示（2026-10-28）

| 步骤 | 结果 |
|---|---|
| `canvas_board.dart` 删交互档位 | `_Interaction.resizing` / `connecting`、`_handle` / `_resizeId` / `_resizeStart`、`_hoverNodeId` / `_connectFromId` / `_connectSide` / `_connectCursor`、`_dropping`，以及 `_handleAt` / `_connectDotAt` / `_finishConnect` / `_resizeTo` / `_cursorFor` / `_setDropping` / `setExternalDropHover` |
| `canvas_board.dart` 卡片尺寸 | `_fitFileNode` 去掉 `math.min(..., canvasFileMaxHeight)`；`_normalizeCollapsedFileNodes` 改成 `_fitFileNodes`（收起 + 展开都重贴）；`didUpdateWidget` 在正文实例变化时重贴；`resizeSelectionBy` 对 `FileNode` 只重贴 |
| `canvas_painter.dart` | 删 `_paintHandles` / `_paintConnectDots` / 预览虚线 / `hoverNodeId` / `connectFromId` / `connectSide` / `connectCursor`；`_paintReferenceBody` 整篇排版，不再算 `maxLines`；删 `canvasFileMaxHeight` / `canvasCardMinSide` / `connectPreview` |
| `canvas_geometry.dart` | 删 `CanvasResizeHandle` / `resizeRect` |
| `app_shell.dart` | `DragTarget` 删 `onMove` / `onLeave`；落点仍走 `VaultDragPayload.pointer` → `addReferencedNotesFromGlobal`（十一轮起 `pointer` 转发到树 State，见 §14.12） |
| 删除拖放提示 | `_DropHint`（「松手引用这篇笔记」）整块移除 |
| 测试调整 | 几何「缩放卡片」8 条删除；白板「缩放手柄」3 条 → 「尺寸固定」1 条；「圆点建边」4 条 → 「边上没有圆点」1 条；「文件卡片 Ctrl+= 改框」→「不改宽高」；高度上限断言改成「两百行 > 200 × 行高」；新增「笔记改后卡片长高」 |
| 回归 | `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` **1567 条全绿**（canvas 201 条） |

### 16.6 八轮：坐标数字挪到轴上（2026-10-28）

| 步骤 | 结果 |
|---|---|
| `canvas_painter.dart` 换绘制层 | 删 `_paintRulers` / `_paintRulerText`；新增 `_paintAxisLabels` / `_axisLabelPainter`：x 数字居中压在水轴上方、y 数字贴竖轴右侧、原点共用一个 `0`；数字跟着轴显隐，画在内容之前（背景层）。`_paintScene` 不再在 restore 之后画标尺 |
| `canvas_style.dart` 清令牌 | 删 `rulerBackground` / `rulerTick` / `rulerEdge`，`rulerText` → `axisLabel`；删 `canvasRulerThickness` / `canvasRulerSideWidth`；`canvasRulerLabel` → `canvasCoordinateLabel`；新增 `canvasAxisLabelGap = 3`；顺手删手柄遗留的 `handle` / `handleRing` |
| `canvas_board.dart` 搜索框 | `_searchRect` 顶部从 `canvasRulerThickness + 10` 改成 12 |
| 测试 | 「坐标网格」组的文案断言改用 `canvasCoordinateLabel`；画布 201 条、全量 1567 条全绿 |
| 回归 | `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` **1567 条全绿**（canvas 201 条） |

### 16.7 九轮：卡片正文改用编辑器的行排版管线（2026-10-28）

| 步骤 | 结果 |
|---|---|
| `canvas_markdown.dart` 重写 | 旧的 `canvasMarkdownLines/Span/Colors` 整份删除；新增 `CanvasMarkdownDocument`（参考 15.5px 排版 + `renderScale` 缩放绘制、两遍贴合、`visibleText`）与 `CanvasMarkdownCache`（`fit` / `get` / `visibleText`）。标记、底片、代码底片、表格的绘制几何逐段抄自 `render_line_editable.dart` |
| `live_markdown/table_block.dart` | `LiveTableBlocks` 新增可选 `paper`：编辑器不传（纸面 = `palette.surface`），卡片传「卡片底色合成到画布」的实色 |
| `line_layout/render_line_editable.dart` | `groupFillBoxesByLine` 去掉 `@visibleForTesting`（卡片的底片分组也用它） |
| `canvas_painter.dart` | `CanvasScenePainter` 新增 `markdownCache`；`_paintTextNode` / `_paintReferenceBody` 改成 `CanvasMarkdownCache.get(...).paint(...)`；删掉只为旧渲染器服务的 `CanvasTextCache.getRich` / `plainTextOf` / `_CachedText.fingerprint` |
| `canvas_board.dart` | 新增 `CanvasMarkdownCache _markdownCache`（`dispose` 里释放）；`_measureBlock` 的 markdown 分支改走 `_markdownCache.fit`（键 `node-…` / `file-body-…`），源码分支保持 13px 原样；`debugFileBody` 改读 `visibleText` |
| 测试 | `canvas_markdown_test.dart` 19 条重写（与编辑器同源、块级/行内表现、贴合、缓存、整篇落画布冒烟）；白板 125 条不动全过（原有「源码贴合 vs 渲染重贴」断言在新字号下仍成立） |
| 回归 | `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` **1563 条全绿**（白板相关 265 条） |

### 16.8 十一轮：拖进白板的落点修回松手处（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 复现 | 写「真外壳 + 真手势」用例（`shell_layout_test.dart`），从列表行拖到画布 `(737, 340)`；卡片落在 `(196.5, 119)` —— 正是拖拽起点 |
| 定位 | 临时代码打印 `identityHashCode(payload)`：一次拖拽里出现三份 payload，`onDragUpdate` 写的是后两份，`onAcceptWithDetails` 拿到的是第一份且指针仍是按下点 |
| `vault_tree.dart` | 新增 `VaultTreeState._dragPointer`；`onDragUpdate` 写它、`_beginDrag` 与 `onDragEnd` 清它；`VaultDragPayload.pointer` 由字段改成 `get pointer => tree._dragPointer` |
| `vault_tree.dart` 注释 | `VaultDragPayload` 类注释与 `_fileRow` 的 `onDragUpdate` 注释同步改写（说明「为什么记在树上而不是载荷里」） |
| 测试 | 新增 1 条落点用例（逐帧 `moveTo` 逼出中途重建；末尾推 2 秒走完自动保存定时器） |
| 未改动 | `canvas_board.dart` 的 `addReferencedNotesFromGlobal`、`addFileCards`、`app_shell.dart` 的 `DragTarget` —— 坐标换算与「指针 = 左上角」本来就是对的 |
| 回归 | `flutter analyze lib test` 无问题；`flutter test --exclude-tags perf` **1576 条通过**（白板相关 266 条）。另一条失败是 `test/widget_test.dart`（模板残留，引用不存在的 `MyApp`），与本次无关 |

### 16.9 十二轮：选择操作照 graphif 规格补齐（2026-10-28）

| 步骤 | 结果 |
|---|---|
| `canvas_board.dart` 框选 | `_selectInMarquee` 重写：方向定判据（向左 = 完全覆盖，向右 = 碰撞）、按键定并入（替换 / Shift 加选 / Ctrl 反选），键读松手那一下；新增 `_marqueeHit`（手写覆盖比较，贴边也算盖住） |
| `canvas_board.dart` 点击 | 新增 `_rangeAnchorId`（Shift 范围选择锚点）与 `_selectRangeFrom`；无键点已选中的卡保持选中（组拖动）；`Ctrl` 点击不动锚点；`Shift` 点击边 = 加选；空白按下时 Shift 也不清选中 |
| `canvas_board.dart` 清锚点 | 框选（任何键）、`deleteSelection`、`selectAll`、无键点空白 / 点边时清掉 `_rangeAnchorId` |
| 测试 | `canvas_board_test.dart` +7 条（覆盖 / 碰撞 / Shift 框选 / Ctrl 框选 / Shift 点击范围 + 锚点不动 / 无锚点退化 / 已选中不清别人），白板相关 **273 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1568 条通过** |

### 16.10 十三轮：连线创建（2026-10-28）

| 步骤 | 结果 |
|---|---|
| `canvas_board.dart` 右键 | `_onSecondaryDown` 只记「按在哪」（`_rightDown` / `_rightDownNodeId` / `_rightDownAt`），菜单与建连线全部推到松手；新增 `_Interaction.connecting`、`_finishRightGesture`（拖 / 点两条路，点再分菜单与建连线） |
| `canvas_board.dart` 拉线 | `_onPointerMove` 加右键分支（3px 死区后升级成 `connecting`）；`_updateConnectPreview` 实时算目标卡；`_connectPreview` 给出画笔要的锚点（起点朝指针、终点朝源卡） |
| `canvas_board.dart` 落边 | `_connectNodes`（轨迹定边 / 中心到中心、同向去重、选中新边、一步撤销）、`_connectToBlank`（新建卡 + 建边，同一步）、`_singleSelectedNode`；`Esc` 中途取消；探针 `debugConnecting` / `debugConnectTarget` |
| `canvas_painter.dart` | 新增 `CanvasConnectPreview` 与 `_paintConnectPreview`（accent 虚线 + 箭头 + 目标卡高亮），画在卡片之后、世界坐标里 |
| 测试 | `canvas_board_test.dart` 新增 `连线创建（右键）` 组 7 条；白板相关 **280 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1575 条通过** |
| 补：边上写文字的键盘路径（前一轮遗留） | 图上「连线上也能写文字」点出的缺口——双击能改标签，但选中边按 `Enter` 进不去（`Enter` 分支只认卡片，边 id 在 `nodeById` 查不到就被忽略）。现在单选边按 `Enter` = 改标签（与双击同一个编辑框），`Ctrl+Enter` 对边仍是忽略。+1 条用例（写标签 / 清空删标签），白板 281 条、全量 1576 条 |

### 16.11 十四轮：格式定案（纯 JSON）+ 图片引用（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 起过一版 zip | 加了 `archive` 依赖、写了 `lib/core/utils/canvas_bundle.dart`（`board.json` + `images/`、稳定图片名、`PK` 文件头识别、旧 JSON 兼容读）。用户一句「保留 json 是不是更好？」后**整份撤掉** |
| 回退 | 删 `canvas_bundle.dart`、`pubspec.yaml` 去掉 `archive`、`flutter pub get` 复原 `pubspec.lock`（`git diff pubspec.yaml pubspec.lock` 为空）、删掉临时确认文档 |
| `vault_tree.dart` | `VaultDragPayload` 加 `image` + `VaultDragPayload.image(...)` + `referencePaths()`（图片就是它自己，其余按落点那一刻的笔记选中）；`_plainFileRow` 里图片行包一层 `Draggable`（白板、附件不拖） |
| `app_shell.dart` | 白板的 `DragTarget` 改吃 `referencePaths()`——笔记和图片走同一条落卡通道 |
| `canvas_board.dart` | `_isImagePath`（后缀清单和文件树共用 `image_file.dart`）；`_toggleFileExpanded` 对图片直接返回（没有正文可展开） |
| `canvas_painter.dart` | 引用图片的卡片把图标换成 `LucideIcons.image` |
| 测试 | +2：图片拖进白板存路径不拷贝（真外壳）、图片卡点标题不展开；白板相关 **283 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1578 条通过** |

### 16.12 十五轮：图片卡画出图 + 拖角改大小（2026-10-28）

| 步骤 | 结果 |
|---|---|
| `note_image_io.dart` / `_web.dart` | 新增 `imageBytesAt(absolutePath)`：桌面读整张字节，Web 返回 null（浏览器里没有那份文件） |
| `canvas_board.dart` 契约 | 新增 `CanvasBoard.imageBytesOf` 回调——画布只解码、不碰 `dart:io` |
| `canvas_board.dart` 解码 | `_images` / `_imagesLoading` 缓存；`_ensureImages()` 在 build 里排队；`_loadImage` 用 `instantiateImageCodec` 解码后 `setState` 并按原图比例重贴；`dispose()` 逐个释放 `ui.Image` |
| `canvas_board.dart` 尺寸 | `_fitImageNode`：长边 `canvasImageCardSide` = 320、按原图比例；解码前给占位框 |
| `canvas_board.dart` 手柄 | `_Interaction.resizingImage`、`_imageHandleAt`（只在选中集里找）、`_resizeImageTo`（保比例、左上钉死）、松手标脏、悬停换斜向双箭头光标；探针 `debugImageLoaded` / `debugResizingImage` |
| `canvas_painter.dart` | `_paintImageCard`（`paintImage` + `BoxFit.cover`）；`_paintImageHandles`（12px 方块 + 三道白线，画在屏幕坐标） |
| `app_shell.dart` | 接上 `imageBytesOf`：`$vault/$path` → `imageBytesAt` |
| 测试 | +5：图片按原图比例贴（2:1）、拖角变大且仍是 2:1 且左上不动、非图片卡没手柄、图片读不出来不崩；白板相关 **301 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1582 条通过** |
| 补：拖角不实时 | 用户报「改大小的时候没有实时显示，松开鼠标才变」。根因：`_resizeImageTo` 原地改了 `node.width/height` 却**没包 `setState`**——文档是可变对象、`shouldRepaint` 恒为 true，不 `setState` 就没人排帧，只有松手时那次 `setState` 才重画。修好后用例加了「改完先别 pump，断言 `hasScheduledFrame`」，去掉 `setState` 这条会失败（已实测） |

### 16.13 十六轮：多连一 + `Ctrl+T` 反转（2026-10-28）

| 步骤 | 结果 |
|---|---|
| `canvas_board.dart` 源头 | 新增 `_connectSources(draggedId)`：拖的起点在选中集里 → 选中集就是源头（边 id 被 `nodeById` 过滤），不在就它自己 |
| `canvas_board.dart` 批量连 | `_connectNodes` → `_connectMany(sources, target, pointer)`：自连跳过、同向已存在的跳过且**进选中**、一批一步撤销、建出的全进选中；`_connectToBlank` → `_connectManyToBlank`（一张新卡 + 一束边，同一步） |
| `canvas_board.dart` 反转 | `_reverseSelectedEdges()`：`from`/`to` 与两侧端点对调，`fromEnd`/`toEnd` 跟槽位走不换；`fromNode` 是 `final`，换新对象（id 不变）；`Ctrl+T` 键位接进 `_onKey` |
| `canvas_painter.dart` | `CanvasConnectPreview.froms` 变列表，预览按源头逐条画（多连一时是一束线） |
| 测试 | +5：多连一两条边全建并进选中、整批一步撤销、已连过的跳过且已有进选中、多选拖到空白一张新卡全连上、`Ctrl+T` 反转 / 端点对调 / 再按复原 |
| 补：多选直接右键 | 用户要求「选中多个节点后右键点击其他节点也要每张都连过去」——把 #115 的「恰好选中一张」放宽成「选中若干张、且点的是选中集之外的卡」；`_singleSelectedNode` 随之删除。+2 条用例（右键连 / 右键选中的那张仍是菜单），白板相关 **301 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1595 条通过** |

### 16.14 十七轮：劈砍 / 切割线（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 读 graphif 文档 | `curl` 抓 `graphif.dev/docs/prg`（web_fetch 超时，curl 正常）+ 逐页提取正文。关键原文：「删除：使用切割线切节点来删除」 |
| `canvas_geometry.dart` | 新增 `segmentsCross`（叉积判相交，含端点接触）、`segmentHitsRect`（线段穿矩形）、`polylineCrossesSegment`（折线切线段） |
| `canvas_board.dart` 状态 | `_Interaction.slashing`、`_slashPoints` / `_slashNodes` / `_slashEdges`；右键从空白拖 3px 后进入 |
| `canvas_board.dart` 命中 | `_slashHits(stroke)`：卡片走 `segmentHitsRect`、连线贝塞尔按 16 段折线走 `polylineCrossesSegment`；`_updateSlash` 接点并重扫 |
| `canvas_board.dart` 收尾 | `_finishRightGesture` 里**先抄出**命中集合再清状态，`_cutAlongSlash(nodes, edges)` 删节点 + 连带边 + 删边 + 清选中 / 编辑态，一步撤销；`Esc` 中途作废 |
| `canvas_painter.dart` | `_paintSlash`：accent 刀锋 + 被切卡片套 `danger` 红框 + 被切连线描红 |
| 测试 | 新增 `劈砍（右键从空白划刀）` 组 6 条；白板相关 **301 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1595 条通过** |

### 16.15 十八轮：图片节点四条规格（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 读 graphif 图片节点文档 | 原文：「拖拽 PNG/JPG/JPEG/WEBP 文件到舞台」「截图后 Ctrl+V」「按住 Ctrl 滚动滚轮缩放」「图片在当前 json 旁边生成 uuid 命名的 png」——和我们的库内引用模型正好对得上 |
| `canvas_board.dart` 契约 | 新增 `onSaveImage`（PNG → 库内相对路径）、`onDropImageFiles`（绝对路径列表 → 库内相对路径列表）、`readClipboardImage`（缺省真剪贴板，测试可换） |
| `canvas_board.dart` 拖入 | `_onDesktopDrop` 替掉原来的「一律劝回去」：读 `fileUri`、筛图片后缀、交外壳导入、按 `event.position.local` 落卡；非图片仍提示 |
| `canvas_board.dart` 粘贴 | `pasteImageFromClipboard()`；`Ctrl+V` 在板内剪贴板为空时才走它 |
| `canvas_board.dart` 缩放 | `_onPointerSignal` 加 Ctrl 分支（只对图片）；`_scaleImageBy` 等比 + 左上钉死 + 700ms 一阵一步撤销；`dispose` 取消窗口定时器 |
| `canvas_painter.dart` | 图片手柄改绿（`tableInkColor(green)`） |
| `notes_controller.dart` | `saveCanvasImage(canvasPath, png)`：存在那块白板所在文件夹，名字带毫秒 |
| `app_shell.dart` | 接上三个回调（`_notes.saveCanvasImage` / `imageBytesAt` + 存库） |
| 测试 | +3：Ctrl+滚轮改图不改画布、文字卡上仍是缩放画布、粘贴图片落成引用卡；白板相关 **304 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1598 条通过** |

### 16.16 十九轮：`Tab` 往右生成节点（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 需求 | 选中节点后按 `Tab`，往右生成一个普通节点（graphif 的「生孩子」键，思维导图式骨架） |
| `canvas_board.dart` | 新增 `_createRightFromSelection()`：恰好选中一张卡时，在它右边缘 + 48、垂直居中处落一张空文字卡（`canvasMinSize` 起步 + `_fitTextNode` 贴合，锚中心不跑），一条边从选中卡指向新卡（两端留空走自动选边）；新卡进选中并 `_beginEdit` 直接能打字。卡 + 边一次 `_mutate` = 一步撤销 |
| `_onKey` | `Ctrl+T` 分支后面挂 `Tab`：光杆 `Tab` 才响应；`Shift` / `Ctrl` / `Alt` 组合全放行（切焦点 / 切窗口）。没选、多选、选中边时返回 ignored 不吃键 |
| 测试 | +5：右侧出卡且边指向新卡（左边缘 ≥ 原卡右边缘、垂直居中）、新卡进选中且 `debugEditing` 指向它、Esc 后一步撤销卡边一起消失、没选中不动、选中边不动（真点选边中点） |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1603 条通过**，白板相关 **309 条**（canvas_board 167） |

### 16.17 二十轮：连按 `Tab` 孩子从上往下排（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 需求 | 同一个节点连按 `Tab` 生多个孩子时自动从上到下排列，不要全部叠在正右方 |
| `canvas_board.dart` | `_createRightFromSelection` 调整：先 `_fitTextNode` 贴出真实高度，再定位——先扫一遍 `doc.edges` 找该节点「还在右侧」的孩子（`child.rect.left ≥ source.rect.right`）里最低的底边，新孩子排在 `最低底边 + 24`；右侧没有孩子则维持贴着选中卡垂直居中。x 仍是右边缘 + 48，全列对齐 |
| 取舍 | 只做「往下长」，不做对称重排——重排得挪已有卡片，用户手摆过的位置会被打乱 |
| 测试 | +2：连按三次 `Tab` 三个孩子从上往下排且同列（第一个垂直居中）、孩子被挪到左侧后不算数（新孩子从原位重新排）；白板相关 **311 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1605 条通过** |

### 16.18 二十一轮：编辑态按 `Tab` 也生孩子（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 需求 | 正在编辑的节点按 `Tab` 也要直接生成节点，不能只在「选中未编辑」时管用 |
| `canvas_board.dart` | `_createRightFromSelection` 拆出 `_createRightFromNode(String sourceId)`（选中路径传 `_selected.first`，编辑路径传 `_editingId`）；`_onKey` 在「输入框吃键盘」那道闸**前面**加 `Tab` 分支：编辑态先 `_commitEdit(restoreFocus: false)` 收字，再从那张卡生孩子 |
| 踩到的坑 | 提交时若照常 `_focus.requestFocus()`，白板这次请求会晚于新卡输入框的请求落地，输入框失焦又提交一次，新卡编辑态被抹掉（§16.3 #22） |
| 笔记正文 | `_editingFileBody` 时 `Tab` 直接吃掉：不生节点，也不让焦点遍历把编辑跳断 |
| 测试 | +2：编辑态打「父节点」后 `Tab`（字收下 / 边从这张出发 / 新卡进编辑态）、编辑笔记正文时 `Tab` 不生卡也不打断；白板相关 **313 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1607 条通过** |

### 16.19 二十二轮：Section 框基础操作（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 读图 | graphif「Section 框基础操作」：创建（`Ctrl+G` / 右键 / `Ctrl+Shift+G`）、改组名（双击标题）、移动（拖标题 / 边框 / 宏观视野内部空白）、换色同节点、`Alt` 跳跃进出、组内双击建卡 |
| 现状盘点 | 拖组（含内部空白）、换色、嵌套、拖动带走子卡已有；缺 `Ctrl+G` / `Ctrl+Shift+G` / 右键打包 / Alt 跳跃；双击组任何位置都被「改组名」占着 |
| `canvas_painter.dart` | `canvasGroupTitleHeight(scale)`：标题条高度 = 上内边距 + 一行标题 × 1.4，画笔与命中测试共用 |
| `canvas_board.dart` | `_groupTitleRect` / `_inGroupTitle` + 探针 `debugGroupTitleRect`；双击组分流（标题条 → `_beginEdit`，内部空白 → `createCard`）；`_groupSelection(single:)` 打包 / 转框；`_jumpSelectionIntoGroupAt` 整队平移 + 强行撑开；`_onPointerDown` Alt 分支（在卡片命中前拦截）；`_onKey` 挂 `Ctrl+G`（Shift 切换单张语义）；`_showCardMenu` 选中 ≥2 张时加「打包成框」 |
| 成员模型 | 没动：成员永远是几何包含，打包 / 跳入都不改卡片字段，只插框 / 挪位置 |
| 测试 | +7（打包 / 不够两张不动 / 转框 / 菜单 / 组内双击建卡 / Alt 跳入撑开撤销 / Alt 点普通卡）；旧的两条组名用例改走标题条双击；白板相关 **320 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1614 条通过** |

### 16.20 二十三轮：打包的组自动包裹（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 需求 | 打包出的组**始终包裹**成员：成员移到哪框跟到哪、宽高跟着变；只有 `Alt` 拖到框外才脱离（不是一按 Alt 就脱离） |
| `canvas_document.dart` | `GroupNode.autoFit`（默认 false，只在 true 时写盘）+ 解析 `autoFit` 键 |
| `canvas_board.dart` | `_refitAutoGroups({escape})`：成员 = 中心在**判据框**里的节点 + 普通拖动中**被拖的卡永远算成员**；框贴成「成员包围盒 + 内边距 + 标题条」 |
| 判据框 | `_groupJudge`：按下时冻结各 autoFit 组的框，整段操作都拿这一份。**不能用刚贴出来的框**——贴合每帧跑，框越贴越紧，用它会一路缩水（移出过一次的卡永远回不来）。撤销 / 换文档 / 松手时清空 |
| `Alt` 语义 | `_dragEscape`：拖动途中按过 Alt 就记住，被拖的卡改为按「中心在不在判据框内」判；框内挪不算脱离，拖到框外才脱离 |
| 喂大框的入口 | 拖 / 方向键 / 双击建卡 / `Tab` / 粘贴 / 拖文件进来 / 删除 / 字号 / 文件卡展开 / 图片缩放 / 图片解码 / 撤销，全走 `_refitAutoGroups` |
| 测试 | +5：拖成员组跟随（右缘贴最右成员）、Alt 拖到框外才脱离、Alt 框内挪不算脱离、手动框固定不动、删除成员框缩回；白板相关 **325 条**全绿 |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`）；`flutter test --exclude-tags perf` **1619 条通过** |

### 16.21 二十四轮：文件列表的 `Shift` 连选覆盖所有文件（2026-10-28）

| 步骤 | 结果 |
|---|---|
| 需求 | 文件列表里的文件，不管是 `.md`、`.nrs`、图片还是别的什么，除了文件夹，都要能 `Shift+左键` 连选 |
| 现状 | 树里只把笔记和白板算进可选中行；图片 / 附件点一下只打开、不记选中，`Shift` 范围里也没有它们 |
| `vault_tree.dart` | 加 `_selectedAssets`（附件相对路径）和 `_anchorAssetPath`；`_selectableRows` 收附件（用 `_Pickable` 记录类型统一三种行）；`_anchorIndex` / `_selectRangeTo` / `_tapRow` 都认第三种；`_selectOnlyAsset`；`_pruneToVisible` 与 `didUpdateWidget` 同步清理；附件行接上 `selected` 高亮 |
| 保留 | 三套选中集合仍分开存：批量删除各走各的（笔记删正文、白板搬文件），附件暂无批量操作。文件夹不进可选中行 |
| 测试 | +3（`shell_layout_test.dart`）：`Shift` 从图片连选到白板（中间 pdf / 笔记全亮、不顺手打开白板）、图片当锚点往回连选到笔记、`Shift` 点文件夹只展开 / 收起；全量 **1622 条通过** |
| 回归 | `flutter analyze lib test` 无问题（唯一 issue 是模板残留 `widget_test.dart`） |
