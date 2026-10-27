# NRS

[![CI](https://github.com/Rolita/nrs-note/actions/workflows/ci.yml/badge.svg)](https://github.com/Rolita/nrs-note/actions/workflows/ci.yml)

**NRS — a beautiful local-first Markdown note-taking app**

NRS 是一个本地优先的 Markdown 笔记应用：每篇笔记就是磁盘上的一个 `.md` 文件。没有私有数据库，没有云端锁定——用别的编辑器打开、用文件管理器移动、用 Git 备份，都和 NRS 里看到的一致。界面面向中文写作，实时渲染 Markdown，同时保留纯文本编辑的确定性。

## 特性

- **四区工作台**：功能栏、文件 / 搜索 / 标签侧边栏、编辑器、大纲；面板宽度可拖动，窗口变窄时大纲自动让位。
- **实时 Markdown**：标题、粗体 / 斜体 / 删除线 / 高亮、行内代码、围栏代码块（内置语法高亮）、链接与图片、`[[维基链接]]`、`#标签`、引用、嵌套列表、任务列表、表格、分隔线。光标碰到记号时才显形为源码。
- **拖放即写**：从浏览器拖一个链接进来，直接写成 `[标题](地址)`；拖一段文字或一段富文本进来，按纯文本落在落点，和 `Ctrl + V` 走同一条路。
- **真实文件夹树**：侧边栏显示磁盘上的真实目录，笔记可在文件夹之间拖动；标题即文件名，改名就是改文件名。
- **多标签页**：同时打开多篇笔记，`Ctrl + Tab` 切换；关系图谱和图片各占一页，**所有图片共用同一页**——从文件树点第二张图只是换内容，标题栏上那一页不动。
- **搜索与标签**：全文搜索标题和正文，标签视图按使用次数汇总所有 `#标签`。
- **表格编辑**：单元格点选与区域选择、Tab 导航、行 / 列增删与移动、列宽拖拽、向下 / 向右填充、矩形复制粘贴、TSV 与电子表格互通、合并居中与拆分、单元格底色与文字色、输入法组字与撤销。
- **本地优先的数据安全**：300 ms 自动保存 + `Ctrl + S`；写盘采用临时文件 + 原子替换，重命名不覆盖已有文件，写操作串行排队。
- **外部改动同步**：窗口重新获得焦点时对比磁盘指纹。干净稿自动载入磁盘版本；有未保存改动时显示冲突条，可「载入磁盘版本」或「保留我的」，冲突未决期间暂停自动保存。
- **写作模式**：专注模式、打字机模式、可调正文字号；界面固定为深色的午夜靛色板，没有明暗切换，也没有自定义配色。
- **跨平台**：Windows 桌面为主目标，同时提供浏览器预览版本。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| Flutter | 3.44.0 stable（Dart 3.12.0），CI 与 `.metadata` 均固定此版本 |
| Windows 构建 | Windows 10 及以上；Visual Studio 2022，勾选「使用 C++ 的桌面开发」与 Windows 10/11 SDK |
| Web 运行 | Chrome 或 Edge，无需额外工具链 |

仓库只包含 Windows / Web 运行目标，没有 Android / iOS 工程。

## 快速开始

```bash
flutter --version        # 确认 3.44.0
flutter pub get

flutter run -d windows   # 桌面
flutter run -d chrome    # 浏览器预览
```

构建发布版：

```bash
flutter build windows --release
# 产物：build\windows\x64\runner\Release\nrs.exe
```

首次启动会在系统「文档」目录下创建 `NRS Notes` 笔记库，并写入一篇欢迎笔记。

## 数据存放与文件格式

### 位置

| 平台 | 位置 |
| --- | --- |
| Windows | `%USERPROFILE%\Documents\NRS Notes`（系统「文档」目录下的 `NRS Notes`） |
| Web | 浏览器 `localStorage`，key 前缀 `nrs/v1/file/`，文件夹列表在 `nrs/v1/folders` |

主题、字号、面板宽度等视图偏好由 `shared_preferences` 单独保存，与笔记内容无关。

### 文件格式

每个 `.md` 文件由 YAML front matter 和原样保留的 Markdown 正文组成：

```markdown
---
id: lq3k9x0a1b
title: 欢迎使用 NRS
tags: [入门]
created: 2026-10-20T09:00:00.000
updated: 2026-10-20T09:30:00.000
---

# 欢迎使用 NRS

正文就是普通的 Markdown。
```

约定：

- **标题 = 文件名**。`写作计划.md` 显示为「写作计划」；`title` 字段只是写给其他工具看的派生信息。
- **`id` 稳定不变**，用于改名、移动后保持标签页与选中状态。
- **标签由正文派生**。在正文里写 `#标签` 即可，保存时会同步写进 front matter，方便其他工具读取。
- **文件夹就是真实目录**。笔记库会递归扫描所有 `.md` 文件，其他程序新建或移入的文件同样可见。

## 快捷键

### 全局

| 快捷键 | 动作 |
| --- | --- |
| `Ctrl + N` | 新建笔记 |
| `Ctrl + ,` | 打开设置 |
| `Ctrl + \` | 收起 / 展开侧边栏 |
| `Ctrl + Shift + F` | 专注模式 |
| `Ctrl + Shift + O` | 显示 / 隐藏大纲 |
| `Ctrl + Alt + ↑ / ↓` | 上一篇 / 下一篇笔记 |
| `Ctrl + Tab` / `Ctrl + Shift + Tab` | 下一个 / 上一个标签页 |
| `Esc` | 退出专注模式 |

### 编辑

| 快捷键 | 动作 |
| --- | --- |
| `Ctrl + B` / `Ctrl + I` | 粗体 / 斜体 |
| `Ctrl + E` | 行内代码 |
| `Ctrl + Shift + E` | 代码块 |
| `Ctrl + K` | 插入链接 |
| `Ctrl + 1 / 2 / 3` | 一级 / 二级 / 三级标题 |
| `Ctrl + 0` | 正文段落 |
| `Ctrl + Shift + 7 / 8` | 有序 / 无序列表 |
| `Ctrl + Shift + Q` | 引用 |
| `Ctrl + Shift + T` | 插入表格 |
| `Tab` / `Shift + Tab` | 列表缩进 / 反缩进（在表格内是切换单元格） |
| `Ctrl + S` | 立即保存 |
| `Ctrl + Z` / `Ctrl + Shift + Z` 或 `Ctrl + Y` | 撤销 / 重做 |

### 表格

| 快捷键 | 动作 |
| --- | --- |
| `Tab` / `Shift + Tab` | 下一个 / 上一个单元格 |
| `Enter` | 在当前行下方新增一行 |
| `F2` | 编辑当前单元格 |
| `Ctrl + D` / `Ctrl + R` | 将当前单元格向下 / 向右填充 |
| `Ctrl + C` / `Ctrl + X` / `Ctrl + V` | 以矩形区域复制 / 剪切 / 粘贴 |
| `Ctrl + Shift + C` | 复制为 TSV（可直接粘贴进电子表格） |

超过 500 行或 20 000 个单元格的粘贴会被拒绝并提示，以避免界面长时间卡住。

#### 列宽

拖动任意两列之间的竖线可以调整列宽：表格先向正文右沿生长，长满后由右列让位，两列都不窄于 64px。拖动过程中只画一条落点线，松手时才写一次文档，一步撤销即可回到拖动前。

第一次拖动会把整张表的可见列宽冻结为手动宽度，写在第一行第一格的指令里；此后各列不再按内容伸缩，内容变长时在格内换行。删掉 `w=` 就回到自动列宽。

```markdown
| <!--nrs w=180,240-->指标 | 本周 |
| --- | ---: |
| 新增 | 42 |
```

列宽以 15.5 号字下的设计像素存储，字号或系统文字缩放变化时等比缩放。合并块内部的边界没有手柄，需要先拆分。

### 单元格格式

选中矩形区域后，在右侧「表格」面板的「外观」组里：

- **合并居中 / 拆分单元格**：合并把区域内文字按行优先并入左上角，覆盖格清空；拆分只去掉跨度，文字仍留在左上角。合并块在显示上是一个格——点它任何位置都落到左上角，Tab 跳过被覆盖的格子。
- **填充颜色 / 文字颜色**：六个预设色名（灰 / 琥珀 / 绿 / 蓝 / 紫 / 红），或「自定义…」取色（填充支持透明度，文字色不透明）；「无填充 / 无颜色」清掉对应通道。按钮下沿的一条细线就是当前格的颜色。

格式写在单元格开头的 HTML 注释里，GitHub、Obsidian 等阅读视图会隐藏它，显示为未合并、无颜色的普通表格，文字不丢：

```markdown
| <!--nrs c=2-->年度汇总 |  |
| --- | --- |
| <!--nrs r=2 bg=blue-->华东 | 12 |
| 7 |
| <!--nrs bg=amber fg=red-->注意 | 3 |
```

移动行 / 列、排序、去重、转置会拆掉合并并保留颜色；清空内容、改对齐、插入行 / 列会保留合并。拆合并与命令本身是同一笔编辑，一次撤销即可。

## 架构

### 目录地图

```text
lib/
├── main.dart              入口：加载设置、后台启动笔记库
├── app.dart               MaterialApp、主题与 Provider 装配
├── data/
│   ├── models/note.dart   Note 模型、front matter、标签派生、命名规则
│   └── storage/           NoteStore 接口、IO / Web 实现、原子写
├── state/
│   ├── notes_controller.dart   笔记列表、标签页、自动保存队列、冲突状态
│   ├── settings_controller.dart 视图偏好
│   └── vault_reconciler.dart    磁盘与内存的纯策略对账
├── core/
│   ├── platform/          窗口、外部链接、窗口聚焦同步（IO / Web 条件导出）
│   ├── theme/             调色板与尺寸令牌
│   └── utils/             Markdown 动作、大纲、表格模型与选择
└── ui/
    ├── shell/             功能栏、文件树、笔记列表、标签页、设置
    ├── editor/            编辑区、Markdown 编辑器、live_markdown/*、大纲
    └── preview/           代码配色与语法高亮
```

### 数据流

```text
                    ┌─ SharedPreferences（主题 / 字号 / 布局）
main.dart ──────────┤
                    └─ NotesController ── NoteStore ── IoNoteStore ── AtomicFileWriter ── *.md
                           │                        └─ WebNoteStore ── localStorage
                           ├─ 300 ms 自动保存（串行写队列）
                           └─ VaultSync（窗口聚焦）── VaultReconciler ── 重载 / 冲突条

AppShell ── FunctionRail / VaultTree / NoteList / TitleBar（标签页）
    └─ EditorPane ── MarkdownEditor ── buildTextSpan() ── live_markdown/*
                  └─ OutlinePanel
```

### 三条必须知道的约束

1. **文件即标题**：重命名标题会重命名文件；文件名冲突用 ` 2`、` 3` 递增解决，绝不把 `id` 藏进文件名。
2. **span 树长度必须等于源码长度**：实时渲染仍是同一个 `TextEditingController`。装饰若替换多个源码字符，必须用零宽文本补齐；一个 `WidgetSpan` 只占一个 `U+FFFC` 位置。否则光标、选区和输入法会整体错位。
3. **写盘串行且原子**：自动保存、手动保存、切换笔记都进入同一条写队列；每次提交先写 `.nrs-tmp-*` 再替换目标文件，启动时清理残留与恢复 `.nrs-bak`。

编辑器渲染按 `part` 文件分层：`block_syntax → typography → widgets → table_model → table_measure / table_render → spans`。各 `part` 共享同一个库的私有作用域，这一箭头是约定而非编译器保证。

## 测试与 CI

```bash
flutter analyze
flutter test                          # 全量单元 / 组件测试
flutter test --exclude-tags perf      # 与 CI 相同，排除性能基准
flutter test --tags perf              # 本地性能基准（100×10 表格、5000 行文档）
```

重点测试：

- `test/table_p0_test.dart`：表格撤销矩阵、矩形粘贴、输入法组字、转义闭环、结构边界、表外文本不变、大粘贴拒绝。
- `test/live_markdown_structure_test.dart`：全语法文档的 span 树长度、`WidgetSpan` 数量与关键样式。
- `test/atomic_file_test.dart`、`test/note_store_io_test.dart`、`test/vault_reconciler_test.dart`：原子写、残留恢复、改名冲突、外部改动对账。
- `test/notes_controller_test.dart`：自动保存、冲突状态、标签页与选择行为。

新增行为应补在对应的 `test/*_test.dart`；性能测试必须带 `@Tags(['perf'])`，避免拖慢 CI。

CI 在 `windows-latest` 上运行 `flutter analyze` 与 `flutter test --exclude-tags perf`，每次 push 到 `main` 或提交 PR 时触发，配置见 [`.github/workflows/ci.yml`](.github/workflows/ci.yml)。

## 文档

- [工程加固方案.md](工程加固方案.md)：数据安全、表格 P0、编辑器拆分与 CI 的实施记录与验收清单。
- [重构表格方案.md](重构表格方案.md)：表格渲染与交互的设计背景。
- [表格合并与颜色方案.md](表格合并与颜色方案.md)：合并居中、单元格底色 / 文字色的语法、渲染、侧栏与验收记录。
- [design/ui-preview.html](design/ui-preview.html)：界面视觉基准（浏览器直接打开）。

## 已知限制

- Windows 是主要目标；macOS / Linux 的 IO 代码路径存在但未纳入 CI，仓库不含移动端工程。
- Web 版使用 `localStorage`，容量有限（通常约 5 MB），且每次保存会重写存储；适合预览与轻量使用，不建议作为主力笔记库。
- 外部文件变更只在窗口重新获得焦点时检测，没有常驻文件监听；在 NRS 一直位于前台时，其他程序的修改不会立即出现。
- 冲突未解决期间该笔记暂停自动保存，需要显式选择「载入磁盘版本」或「保留我的」。
- 超大表格粘贴（超过 500 行或 20 000 格）会被拒绝，而不是异步分块导入。

## License

仓库目前未附带 `LICENSE` 文件。在补充许可证之前，默认保留所有权利；如需开源或对外分发，请先添加合适的许可证。
