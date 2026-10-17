import 'dart:math';

/// A single Markdown note.
///
/// A note is the in-memory representation of exactly one `.md` file inside the
/// vault. The Markdown body is stored *verbatim* — NRS never rewrites the prose
/// a user typed — while the bookkeeping (tags, pin state, timestamps) lives in a
/// small YAML front-matter block that is stripped before the body is handed to
/// the editor and re-attached on save.
class Note {
  Note({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    this.tags = const <String>[],
    this.pinned = false,
    this.favorite = false,
    String? fileName,
  }) : fileName = fileName ?? buildFileName(title, id);

  /// Stable identity. Survives renames so the UI can keep a selection.
  final String id;

  final String title;
  final String body;
  final List<String> tags;
  final bool pinned;
  final bool favorite;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// File name inside the vault, e.g. `写作计划-a1b2c3.md`.
  final String fileName;

  bool get isEmpty =>
      body.trim().isEmpty && title.trim().isEmpty && tags.isEmpty;

  Note copyWith({
    String? title,
    String? body,
    List<String>? tags,
    bool? pinned,
    bool? favorite,
    DateTime? updatedAt,
    String? fileName,
  }) => Note(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    tags: tags ?? this.tags,
    pinned: pinned ?? this.pinned,
    favorite: favorite ?? this.favorite,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    fileName: fileName ?? this.fileName,
  );

  /// What the list shows underneath the title.
  String get snippet {
    final String flat = body
        .replaceAll(RegExp(r'^---[\s\S]*?---'), '')
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'`[^`]*`'), ' ')
        .replaceAllMapped(
          RegExp(r'!?\[([^\]]*)\]\([^)]*\)'),
          (Match m) => m.group(1) ?? '',
        )
        .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '')
        .replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s{0,3}\d+\.\s+', multiLine: true), '')
        .replaceAll(RegExp(r'[*_~]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return flat;
  }

  /// Heading extracted from the body — used when the user clears the title.
  String get derivedTitle {
    for (final String line in body.split('\n')) {
      final Match? m = RegExp(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(line);
      if (m != null) return m.group(1)!.trim();
      if (line.trim().isNotEmpty) break;
    }
    return '';
  }

  /// Latin words plus CJK ideographs, which is the count Chinese writers expect.
  int get characterCount {
    final String text = body.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    return text.replaceAll(RegExp(r'\s'), '').length;
  }

  int get wordCount {
    final String text = body.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    final int cjk = RegExp(
      r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF]',
    ).allMatches(text).length;
    final int latin = RegExp(r"[A-Za-z0-9\u00C0-\u024F']+")
        .allMatches(text.replaceAll(
          RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF]'),
          ' ',
        ))
        .length;
    return cjk + latin;
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
  static const String _taskLead = r'^\s*(?:[-*+]|\d{1,9}[.)])\s+\[[ xX]\]';

  int get taskTotal =>
      RegExp(_taskLead, multiLine: true).allMatches(body).length;

  int get taskDone => RegExp(
    r'^\s*(?:[-*+]|\d{1,9}[.)])\s+\[[xX]\]',
    multiLine: true,
  ).allMatches(body).length;

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

  static List<String> _parseList(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    final String cleaned = raw.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    if (cleaned.isEmpty) return const <String>[];
    return cleaned
        .split(',')
        .map((String e) => _unquote(e.trim()))
        .where((String e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static bool _parseBool(String? raw) =>
      raw != null && RegExp(r'^(true|yes|on|1)$', caseSensitive: false).hasMatch(raw.trim());

  static DateTime _parseDate(String? raw, DateTime fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    return DateTime.tryParse(_unquote(raw))?.toLocal() ?? fallback;
  }

  /// Parses a whole `.md` file, falling back to the file name when the note has
  /// no front matter or title (so hand-written Markdown still shows up nicely).
  static Note fromMarkdown(String raw, String fileName, DateTime fileModified) {
    final ({Map<String, String> meta, String body}) parts = splitFrontMatter(raw);
    final Map<String, String> meta = parts.meta;
    final String id = meta['id']?.isNotEmpty == true
        ? _unquote(meta['id']!)
        : _idFromFileName(fileName);
    final DateTime created = _parseDate(meta['created'] ?? meta['date'], fileModified);
    final DateTime updated = _parseDate(meta['updated'], fileModified);
    final String title = meta['title']?.isNotEmpty == true
        ? _unquote(meta['title']!)
        : _titleFromBody(parts.body, fileName);

    return Note(
      id: id,
      title: title,
      body: parts.body,
      tags: _parseList(meta['tags']),
      pinned: _parseBool(meta['pinned']),
      favorite: _parseBool(meta['favorite'] ?? meta['starred']),
      createdAt: created,
      updatedAt: updated.isBefore(created) ? created : updated,
      fileName: fileName,
    );
  }

  static String _titleFromBody(String body, String fileName) {
    for (final String line in body.split('\n')) {
      final Match? m = RegExp(r'^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(line);
      if (m != null) return m.group(1)!.trim();
      if (line.trim().isNotEmpty) break;
    }
    return fileName.replaceAll(RegExp(r'\.md$', caseSensitive: false), '');
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
    if (pinned) b.writeln('pinned: true');
    if (favorite) b.writeln('favorite: true');
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

  /// Human-readable, shell-safe file name: slug + short id for uniqueness.
  static String buildFileName(String title, String id) {
    final String slug = slugify(title);
    final String short = id.length >= 6 ? id.substring(id.length - 6) : id;
    return slug.isEmpty ? '$short.md' : '$slug-$short.md';
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
  factory Note.blank({String title = ''}) {
    final DateTime now = DateTime.now();
    final String id = newId();
    return Note(
      id: id,
      title: title,
      body: '',
      createdAt: now,
      updatedAt: now,
      fileName: buildFileName(title, id),
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
      tags: const <String>['入门'],
      pinned: true,
      createdAt: now,
      updatedAt: now,
      fileName: buildFileName('欢迎使用 NRS', id),
      body: '''
# 欢迎使用 NRS

> NRS 是一款**本地优先**的 Markdown 笔记应用:你写下的每一个字,都以纯 `.md`
> 文件的形式存在磁盘上,没有私有格式,也没有云端锁定。这篇笔记本身就是一份教程
> —— 读完它,你就已经会用了。

## 一、认识界面

NRS 从左到右只有三栏:

| 区域 | 你能在这里做的事 |
| --- | --- |
| 侧栏 | 按 **全部笔记 / 置顶 / 收藏 / 含待办 / 标签** 筛选 |
| 笔记列表 | 搜索、置顶、收藏;拖中间的竖线可调整宽度 |
| 编辑器 | 边写边成形;窗口够宽时右侧还会展开大纲 |

## 二、写下第一篇

- [x] 按 `Ctrl + N` 新建一篇笔记
- [ ] 在标题或正文里直接打字 —— 所见即所得
- [ ] 按 `Ctrl + S` 保存(平时也会自动保存)
- [ ] 按 `Ctrl + P` 快速打开别的笔记,或运行命令
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

- 点标题下方的「＋ 添加标签」就能给笔记打标签,标签会出现在左侧栏,点一下即可筛选
- 正文里直接写 #入门 也会渲染成可点击的标签
- 用双方括号可以连到另一篇笔记,例如 [[我的新笔记]]

## 五、写得更安静

- `Ctrl + Shift + F` 专注模式:藏起侧栏与列表,只剩正文
- `Ctrl + Shift + O` 打开右侧大纲,`#` 标题就是目录
- `Ctrl + \\` 收起或展开左侧栏
- `Ctrl + ,` 打开设置:浅色 / 深色主题、正文字号、打字机模式

---

这篇笔记也是一颗种子 —— 删掉它,换成你自己的笔记就好。
''',
    );
  }
}
