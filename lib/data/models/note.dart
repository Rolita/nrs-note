import 'dart:math';

/// A single Markdown note.
///
/// A note is the in-memory representation of exactly one `.md` file inside the
/// vault. The Markdown body is stored *verbatim* — NRS never rewrites the prose
/// a user typed — and it is also where a note's tags live, as `#标签` typed into
/// the text itself. The remaining bookkeeping (timestamps, folder) lives in a
/// small YAML front-matter block that is stripped before the body is handed to
/// the editor and re-attached on save.
class Note {
  Note({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    this.folderPath = '',
    String? fileName,
  }) : tags = tagsInBody(body),
       fileName = fileName ?? buildFileName(title);

  /// Stable identity. Survives renames so the UI can keep a selection.
  final String id;

  final String title;
  final String body;

  /// Every `#标签` in [body], in order of first appearance.
  ///
  /// Derived rather than stored, so a tag is added by typing it — in the note,
  /// where the user can see what it applies to — and the sidebar follows along
  /// as the text changes.
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// File name inside the vault, e.g. `写作计划.md`.
  final String fileName;

  /// Folder relative to the vault root, using `/` as the separator. Empty for a
  /// note that sits directly in the vault.
  final String folderPath;

  /// 派生统计的惰性缓存。
  ///
  /// 正文是不可变的，所以同一份正文算一次就够：状态栏一次构建要取六次统计，
  /// 原先会重跑六遍全文正则。`copyWith` 生成新实例时缓存自然从空开始，
  /// 「正文变则统计变」不依赖任何显式失效。
  ({int words, int chars})? _counts;
  ({int total, int done})? _tasks;

  /// 大小写不敏感搜索用的折叠副本（标题、正文各一份）。
  ///
  /// 过滤和命中行定位都会把整篇正文转小写：原先按「每个查询词 × 每条命中」
  /// 重复转换，长笔记下开销随命中数放大。正文不可变，折叠一次就够，同样
  /// 由 `copyWith` 新实例自然失效。
  String? _foldedTitle;
  String? _foldedBody;

  String get foldedTitle => _foldedTitle ??= title.toLowerCase();

  String get foldedBody => _foldedBody ??= body.toLowerCase();

  /// Vault-relative path of the file, always `/`-separated.
  String get relativePath =>
      folderPath.isEmpty ? fileName : '$folderPath/$fileName';

  Note copyWith({
    String? id,
    String? title,
    String? body,
    DateTime? updatedAt,
    String? fileName,
    String? folderPath,
  }) => Note(
    id: id ?? this.id,
    title: title ?? this.title,
    body: body ?? this.body,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    fileName: fileName ?? this.fileName,
    folderPath: folderPath ?? this.folderPath,
  );

  /// Latin words plus CJK ideographs, which is the count Chinese writers expect.
  int get characterCount => (_counts ??= _countBody()).chars;

  int get wordCount => (_counts ??= _countBody()).words;

  /// 一次扫描同时得到字数与字符数：两者去的是同一份围栏文本。
  ({int words, int chars}) _countBody() {
    final String text = body.replaceAll(_fencedBlock, '');
    final int cjk = _cjk.allMatches(text).length;
    final int latin = _latin.allMatches(text.replaceAll(_cjk, ' ')).length;
    return (words: cjk + latin, chars: text.replaceAll(_whitespace, '').length);
  }

  /// Rounded reading time in minutes, never zero for non-empty notes.
  int get readingMinutes {
    final int words = wordCount;
    if (words == 0) return 0;
    return max(1, (words / 300).ceil());
  }

  /// Checkboxes, whether the item is bulleted (`- [ ] 事`) or numbered
  /// (`1. [ ] 事`). The numbered form is a first-class task list — it is what
  /// the toolbar's "ordered task list" writes and what the editor draws.
  static final RegExp _taskLine = RegExp(
    r'^\s*(?:[-*+]|\d{1,9}[.)])\s+\[([ xX])\]',
    multiLine: true,
  );

  int get taskTotal => (_tasks ??= _countTasks()).total;

  int get taskDone => (_tasks ??= _countTasks()).done;

  ({int total, int done}) _countTasks() {
    int total = 0;
    int done = 0;
    for (final RegExpMatch m in _taskLine.allMatches(body)) {
      total++;
      final String mark = m.group(1)!;
      if (mark == 'x' || mark == 'X') done++;
    }
    return (total: total, done: done);
  }

  static final RegExp _fencedBlock = RegExp(r'```[\s\S]*?```');
  static final RegExp _whitespace = RegExp(r'\s');
  static final RegExp _cjk = RegExp(
    r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF]',
  );
  static final RegExp _latin = RegExp(r"[A-Za-z0-9\u00C0-\u024F']+");

  // ---------------------------------------------------------------- front matter

  static final RegExp _frontMatter = RegExp(
    r'^\uFEFF?---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)',
  );

  /// Splits raw file contents into (metadata, body).
  ///
  /// The blank line between the closing `---` and the first line of prose is a
  /// *separator*, not content: [toMarkdown] writes it and strips any leading
  /// newlines the body had, so the reader has to strip it back off. Leaving it
  /// in puts a phantom empty line at the top of every note — the editor shows
  /// it, the outline counts it, and the caret sitting at offset 0 is then
  /// *inside* the second line.
  static ({Map<String, String> meta, String body}) splitFrontMatter(
    String raw,
  ) {
    final Match? m = _frontMatter.firstMatch(raw);
    if (m == null) return (meta: const <String, String>{}, body: raw);
    return (
      meta: parseSimpleYaml(m.group(1)!),
      body: raw.substring(m.end).replaceFirst(RegExp(r'^(?:\r?\n)+'), ''),
    );
  }

  /// Parses the flat `key: value` subset of YAML that NRS writes, while staying
  /// tolerant of front matter produced by other tools.
  ///
  /// A key is only written back to the map once we know whether it was a scalar
  /// (`title: x`) or the head of a block list (`tags:\n  - a\n  - b`) — flushing
  /// eagerly used to overwrite the previous scalar with an empty string.
  static Map<String, String> parseSimpleYaml(String source) {
    final Map<String, String> out = <String, String>{};
    final List<String> pendingList = <String>[];
    String? pendingKey;

    void flush() {
      final String? key = pendingKey;
      if (key == null) return;
      if (pendingList.isNotEmpty) out[key] = pendingList.join(', ');
      pendingKey = null;
      pendingList.clear();
    }

    for (final String rawLine in source.split('\n')) {
      final String line = rawLine.replaceAll('\r', '');
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;

      final Match? item = RegExp(r'^\s*-\s*(.+)$').firstMatch(line);
      if (item != null && pendingKey != null) {
        pendingList.add(_unquote(item.group(1)!.trim()));
        continue;
      }

      final Match? kv = RegExp(
        r'^([A-Za-z0-9_\-]+)\s*:\s*(.*)$',
      ).firstMatch(line);
      if (kv == null) continue;

      flush();
      final String key = kv.group(1)!.toLowerCase();
      final String value = kv.group(2)!.trim();
      pendingKey = key;
      if (value.isNotEmpty && value != '|' && value != '>') {
        out[key] = value;
      }
    }
    flush();
    return out;
  }

  static String _unquote(String v) {
    if (v.length >= 2 &&
        ((v.startsWith('"') && v.endsWith('"')) ||
            (v.startsWith("'") && v.endsWith("'")))) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }

  /// The `#标签` a body carries, in order of first appearance.
  ///
  /// The rules match the ones the editor draws chips with: a tag has to start a
  /// word (`C#`, `issue#1` are not tags) and may not be all digits (`#1` is an
  /// issue reference). Fenced code blocks are skipped, so a shell comment inside
  /// a snippet cannot mint one.
  static List<String> tagsInBody(String body) {
    final List<String> found = <String>[];
    final Set<String> seen = <String>{};
    bool fenced = false;
    for (final String line in body.split('\n')) {
      final String trimmed = line.trimLeft();
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        fenced = !fenced;
        continue;
      }
      if (fenced) continue;
      for (final RegExpMatch m in _tagRe.allMatches(line)) {
        final String tag = m.group(1)!;
        if (m.start > 0 && !_tagBoundary.hasMatch(line[m.start - 1])) continue;
        if (_allDigits.hasMatch(tag)) continue;
        if (!seen.add(tag.toLowerCase())) continue;
        found.add(tag);
      }
    }
    return found;
  }

  /// `#tag` — the same characters the editor accepts, minus the `#`.
  static final RegExp _tagRe = RegExp(
    r'#([A-Za-z0-9_\u4e00-\u9fff][A-Za-z0-9_\u4e00-\u9fff\-/\.]*)',
  );

  /// A break a tag may follow: the start of the line, a space, an open bracket.
  static final RegExp _tagBoundary = RegExp(r'[\s([{>（【「]');

  static final RegExp _allDigits = RegExp(r'^[0-9]+$');

  static DateTime _parseDate(String? raw, DateTime fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    return DateTime.tryParse(_unquote(raw))?.toLocal() ?? fallback;
  }

  /// Parses a whole `.md` file, falling back to the file name when the note has
  /// no front matter or title (so hand-written Markdown still shows up nicely).
  static Note fromMarkdown(
    String raw,
    String fileName,
    DateTime fileModified, {
    String folderPath = '',
  }) {
    final ({Map<String, String> meta, String body}) parts = splitFrontMatter(raw);
    final Map<String, String> meta = parts.meta;
    final String folder = normalizeFolderPath(folderPath);
    final String relative = folder.isEmpty ? fileName : '$folder/$fileName';
    final String id = meta['id']?.isNotEmpty == true
        ? _unquote(meta['id']!)
        : _idFromFileName(relative);
    final DateTime created = _parseDate(meta['created'] ?? meta['date'], fileModified);
    final DateTime updated = _parseDate(meta['updated'], fileModified);
    final String title = titleOfFileName(fileName);

    return Note(
      id: id,
      title: title,
      body: parts.body,
      createdAt: created,
      updatedAt: updated.isBefore(created) ? created : updated,
      fileName: fileName,
      folderPath: folder,
    );
  }

  /// Cleans a vault-relative folder path: one separator, no empty segments, no
  /// `.` or `..`. A path that tries to climb out of the vault collapses to the
  /// root instead of resolving outside it.
  static String normalizeFolderPath(String raw) {
    final List<String> parts = <String>[];
    for (final String segment in raw.split(RegExp(r'[\\/]'))) {
      final String s = segment.trim();
      if (s.isEmpty || s == '.') continue;
      if (s == '..') return '';
      parts.add(s);
    }
    return parts.join('/');
  }

  /// The stem of [fileName], which *is* the note's title.
  ///
  /// One name, two places, never out of step: renaming the title renames the
  /// file (see [buildFileName]), and renaming the file renames the note on the
  /// next load. The front matter still carries a `title:` line for other
  /// tools, but it is derived — never consulted, or the two could disagree.
  ///
  /// `未命名.md` therefore shows up as 「未命名」 with no metadata at all.
  ///
  /// Public because a *new* note is handed a free file name before it exists —
  /// `未命名 2.md` must show up as 「未命名 2」 from the first frame.
  static String titleOfFileName(String fileName) {
    final String stem = fileName
        .replaceAll(RegExp(r'\.md$', caseSensitive: false), '')
        .trim();
    return stem.isEmpty ? '未命名' : stem;
  }

  static String _idFromFileName(String fileName) {
    final String stem = fileName.replaceAll(
      RegExp(r'\.md$', caseSensitive: false),
      '',
    );
    final Match? m = RegExp(r'-([0-9a-z]{6})$').firstMatch(stem);
    return m?.group(1) ?? stem.hashCode.toRadixString(36);
  }

  // ---------------------------------------------------------------- serialise

  /// Full file contents including the front-matter block.
  String toMarkdown() {
    final StringBuffer b = StringBuffer()
      ..writeln('---')
      ..writeln('id: $id')
      ..writeln('title: ${_quote(title)}');
    if (tags.isNotEmpty) {
      b.writeln('tags: [${tags.map(_quote).join(', ')}]');
    }
    b
      ..writeln('created: ${createdAt.toIso8601String()}')
      ..writeln('updated: ${updatedAt.toIso8601String()}');
    b
      ..writeln('---')
      ..writeln();
    final String trimmed = body.replaceFirst(RegExp(r'^\n+'), '');
    b.write(trimmed);
    return b.toString();
  }

  static final RegExp _needsQuote = RegExp(
    '^[\\s#\\[\\]{}>&*!|%@`"\']|: |:\$|\\n',
  );

  static String _quote(String v) => _needsQuote.hasMatch(v)
      ? '"${v.replaceAll('"', r'\"')}"'
      : v;

  // ---------------------------------------------------------------- factories

  static final Random _rng = Random();

  static String newId() {
    final int ms = DateTime.now().millisecondsSinceEpoch;
    return '${ms.toRadixString(36)}${_rng.nextInt(1 << 20).toRadixString(36)}';
  }

  /// The file a title lives in: the title itself, made safe for a file system.
  ///
  /// ⛔ No id suffix. The name of the file *is* the name of the note — that is
  /// the contract this app is built on. Two notes can therefore never be told
  /// apart by their file names; a clash is resolved by whoever writes the file
  /// appending ` 2`, ` 3` … (the way Obsidian does), never by hiding an id in
  /// the name.
  static String buildFileName(String title) {
    final String slug = slugify(title);
    return slug.isEmpty ? '未命名.md' : '$slug.md';
  }

  static String slugify(String input) {
    String s = input
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'[#\[\]{}()!@$%^&+="`~;,]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    s = s.replaceAll(RegExp(r'[.\s]+$'), '');
    if (s.length > 48) s = s.substring(0, 48).trim();
    return s.replaceAll(RegExp(r'[.\s]+$'), '');
  }

  /// A brand-new, empty note ready to be edited.
  factory Note.blank({String title = '', String folderPath = ''}) {
    final DateTime now = DateTime.now();
    final String id = newId();
    return Note(
      id: id,
      title: title,
      body: '',
      createdAt: now,
      updatedAt: now,
      fileName: buildFileName(title),
      folderPath: normalizeFolderPath(folderPath),
    );
  }

  /// The first-run onboarding note.
  ///
  /// It is a short Markdown tutorial written *in* Markdown, so reading it is
  /// also a tour of everything the live renderer knows how to draw — headings,
  /// tables, task lists, inline tags and wikilinks included. Keeping the body
  /// dense in supported syntax is deliberate: it is the only document guaranteed
  /// to be opened on day one.
  factory Note.welcome() {
    final DateTime now = DateTime.now();
    final String id = newId();
    return Note(
      id: id,
      title: '欢迎使用 NRS',
      createdAt: now,
      updatedAt: now,
      fileName: buildFileName('欢迎使用 NRS'),
      body: '''
# 欢迎使用 NRS

> NRS 是一款**本地优先**的 Markdown 笔记应用:你写下的每一个字,都以纯 `.md`
> 文件的形式存在磁盘上,没有私有格式,也没有云端锁定。这篇笔记本身就是一份教程
> —— 读完它,你就已经会用了。

## 一、认识界面

NRS 从左到右分为四块:

| 区域 | 你能在这里做的事 |
| --- | --- |
| 功能栏 | 最左边的图标栏:切换文件 / 搜索 / 标签,或者收起侧边栏 |
| 侧边栏 | 文件视图是一棵真实的文件夹树;搜索与标签各是一个独立视图 |
| 编辑器 | 边写边成形;标题下方会显示这篇笔记在笔记库里的相对路径 |
| 大纲 | 最右侧;点 `#` 标题即可跳转,窗口太窄时会自动让位给正文 |

文件列表顶部可以新建笔记、新建文件夹、切换排序,以及全部展开 /
全部收起。文件夹就是磁盘上的真实目录。

## 二、写下第一篇

- [x] 按 `Ctrl + N` 新建一篇笔记
- [ ] 在标题或正文里直接打字 —— 所见即所得
- [ ] 按 `Ctrl + S` 保存(平时也会自动保存)
- [ ] 最后删掉这篇,写下你自己的第一行

## 三、最常用的语法

| 想要 | 就写 | 快捷键 |
| --- | --- | --- |
| **加粗** | `**文字**` | `Ctrl + B` |
| *斜体* | `*文字*` | `Ctrl + I` |
| ~~删除线~~ | `~~文字~~` | — |
| 高亮 | `==文字==` | — |
| 行内代码 | `` `code` `` | `Ctrl + E` |
| 链接 | `[标题](https://)` | `Ctrl + K` |

> 小技巧:光标**碰到**某个记号时,它才显形为源码;移开后立刻变回成品 ——
> 所以正在编辑的那一行,看起来也几乎是成品。

### 标题

`#` 的数量决定标题级别(一到六级),也可以点工具栏最左边的 `H`。

### 列表与任务

列表用 `-` 或 `1.` 开头,按 `Tab` / `Shift + Tab` 缩进,回车会自动接续下一项。

- 这是一个无序列表
  - 多按一次 `Tab` 就能嵌套
- [ ] 方框点一下即可勾选
- [x] 完成的条目会整体变灰并划掉

### 引用与代码块

> 写作,是把混乱的思绪整理成别人读得懂的样子。

```dart
void main() {
  // 代码高亮由 NRS 自己实现:纯 Dart,零依赖
  print('Hello, NRS!');
}
```

## 四、把笔记连起来

- 正文里直接写 #入门 就能给笔记打标签,标签会出现在左侧栏,点一下即可筛选
- 用双方括号可以连到另一篇笔记,例如 [[我的新笔记]]

## 五、写得更安静

- `Ctrl + Shift + F` 专注模式:藏起功能栏、侧边栏与大纲,只剩正文
- `Ctrl + Shift + O` 打开最右侧的大纲,`#` 标题就是目录
- `Ctrl + \\` 收起或展开侧边栏(最左边功能栏顶部的按钮也可以)
- `Ctrl + ,` 打开设置:浅色 / 深色主题、正文字号、打字机模式

---

这篇笔记也是一颗种子 —— 删掉它,换成你自己的笔记就好。
''',
    );
  }
}
