import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/utils/inline_syntax.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/markdown_outline.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';
import 'package:nrs/ui/preview/syntax_highlighter.dart';

void main() {
  group('Note front matter', () {
    test('round-trips metadata and body', () {
      final Note note = Note(
        id: 'abc123',
        title: '写作计划',
        body: '# 标题\n\n正文内容。\n\n#写作 #计划\n',
        createdAt: DateTime(2026, 1, 2, 9, 30),
        updatedAt: DateTime(2026, 1, 3, 10, 0),
        fileName: '写作计划.md',
      );

      final Note parsed = Note.fromMarkdown(
        note.toMarkdown(),
        note.fileName,
        DateTime(2026, 5, 1),
      );

      expect(parsed.id, 'abc123');
      expect(parsed.title, '写作计划');
      expect(parsed.tags, <String>['写作', '计划']);
      expect(parsed.body.trim(), '# 标题\n\n正文内容。\n\n#写作 #计划');
      expect(parsed.createdAt, note.createdAt);
      expect(parsed.updatedAt, note.updatedAt);
    });

    test('tags are the #标签 typed in the body', () {
      expect(Note.tagsInBody('# 标题\n\n见 #写作/计划 和 #写作,还有 (入门)\n'), <String>[
        '写作/计划',
        '写作',
      ]);
      // Issues, code blocks and other people's `#`: none of these are tags.
      expect(
        Note.tagsInBody(
          'issue #1, C# 语言, 标题 #\n\n```sh\n# build the thing\n```\n',
        ),
        isEmpty,
      );
    });

    test('the blank line after the front matter is a separator, not content', () {
      // What actually sits on disk: `---`, the metadata, `---`, one blank line,
      // then the prose. The blank line belongs to the *file format*, so the body
      // must not start with a newline — otherwise every note opens with a
      // phantom empty first line (and the caret at offset 0 lands on it).
      const String raw = '---\nid: a\ntitle: 标题\n---\n\n# 标题\n\n正文\n';
      final Note note = Note.fromMarkdown(raw, '标题-a.md', DateTime(2026));
      expect(note.body, '# 标题\n\n正文\n');
      expect(note.body.startsWith('\n'), isFalse);

      // …and writing it back has to be a fixed point, or the file grows a blank
      // line every time it is saved.
      final Note again = Note.fromMarkdown(
        note.toMarkdown(),
        note.fileName,
        DateTime(2026),
      );
      expect(again.body, note.body);
    });

    test('leaves a body with no front matter completely alone', () {
      const String raw = '\n  # 缩进的标题\n';
      expect(Note.fromMarkdown(raw, 'x.md', DateTime(2026)).body, raw);
    });

    test('the title is the file name, not the front matter or a heading', () {
      // One name in two places: renaming the file renames the note, so a file
      // called `周报.md` must not claim another title just because its
      // metadata — or its first heading — says so.
      final Note parsed = Note.fromMarkdown(
        '---\ntitle: 旧标题\n---\n\n# 另一个标题\n\n内容',
        '周报.md',
        DateTime(2026, 3, 4),
      );
      expect(parsed.title, '周报');
      expect(parsed.tags, isEmpty);
      expect(parsed.createdAt, DateTime(2026, 3, 4));

      // A file with no metadata at all still gets a usable title…
      expect(
        Note.fromMarkdown('# 我的第一篇\n\n内容', '我的第一篇.md', DateTime(2026)).title,
        '我的第一篇',
      );
      // …and the untitled placeholder reads as its file name, too.
      expect(Note.fromMarkdown('', '未命名.md', DateTime(2026)).title, '未命名');
    });

    test('slugify keeps CJK and strips filesystem-hostile characters', () {
      expect(Note.slugify('我的笔记 / 2026: 计划?'), '我的笔记 2026 计划');
      expect(Note.slugify('   '), '');
      // The file name is the title: no id suffix, and an empty title lands in
      // 「未命名」 rather than in a hash.
      expect(Note.buildFileName('写作计划'), '写作计划.md');
      expect(Note.buildFileName(''), '未命名.md');
      expect(Note.buildFileName('   '), '未命名.md');
    });

    test('counts CJK characters and latin words together', () {
      final Note note = Note(
        id: 'x',
        title: 't',
        body: '你好世界 hello world',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(note.wordCount, 6);
      // Whitespace is stripped before counting, including the space。
      expect(note.characterCount, 14);
    });

    test('counts task list progress', () {
      final Note note = Note(
        id: 'x',
        title: 't',
        body: '- [x] done\n- [ ] todo\n- [X] also done\n',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect(note.taskTotal, 3);
      expect(note.taskDone, 2);
    });

    Note counted(String body) => Note(
      id: 'x',
      title: 't',
      body: body,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    test('derived counts keep their edge-case results', () {
      final Note empty = counted('');
      expect(empty.wordCount, 0);
      expect(empty.characterCount, 0);
      expect(empty.readingMinutes, 0);

      final Note cjk = counted('你好世界');
      expect(cjk.wordCount, 4);
      expect(cjk.characterCount, 4);
      expect(cjk.readingMinutes, 1);

      final Note latin = counted('hello world');
      expect(latin.wordCount, 2);
      expect(latin.characterCount, 10);

      // 闭合围栏整块不计入统计。
      final Note fenced = counted('正文\n```dart\nvoid main() {}\n```\n');
      expect(fenced.wordCount, 2);
      expect(fenced.characterCount, 2);

      // 未闭合围栏没有「整块」可去：里面的文字照常计入，与旧扫描一致。
      final Note open = counted('前的文字\n```\ncode here');
      expect(open.wordCount, 6);
    });

    test('derived caches follow copyWith and repeated reads', () {
      final Note note = counted('- [x] done\n- [ ] todo\n- [X] also done\n');
      expect(note.taskTotal, 3);
      expect(note.taskDone, 2);
      expect(note.taskTotal, 3);
      expect(note.taskDone, 2);

      final Note rewritten = note.copyWith(body: '新正文');
      expect(rewritten.wordCount, 3);
      expect(rewritten.taskTotal, 0);
      expect(rewritten.taskDone, 0);
    });

    test('folded copies are built once and follow copyWith', () {
      final Note note = counted('MiXeD 正文');
      final String folded = note.foldedBody;
      expect(folded, 'mixed 正文');
      expect(identical(note.foldedBody, folded), isTrue, reason: '重复读取复用同一副本');
      expect(identical(note.foldedTitle, note.foldedTitle), isTrue);

      final Note rewritten = note.copyWith(title: 'T', body: 'OTHER');
      expect(rewritten.foldedBody, 'other');
      expect(rewritten.foldedTitle, 't');
    });
  });

  group('Outline', () {
    test('skips headings inside fenced code blocks', () {
      const String source = '''
# 一级标题

```bash
# 这不是标题
```

## 二级标题

Setext 标题
===
''';
      final List<Heading> headings = extractHeadings(source);
      expect(headings.map((Heading h) => h.plainText).toList(), <String>[
        '一级标题',
        '二级标题',
        'Setext 标题',
      ]);
      expect(headings.map((Heading h) => h.level).toList(), <int>[1, 2, 1]);
    });

    test('a run of dashes is a rule, never a setext heading', () {
      // The renderer draws `---` as a horizontal rule, so the outline has to
      // agree — otherwise a note "has" a heading that is nowhere on screen.
      expect(extractHeadings('标题\n---\n'), isEmpty);
    });

    test('strips inline markup from outline labels', () {
      final List<Heading> h = extractHeadings('## **加粗** 与 `代码` 与 [链接](u)');
      expect(h.single.plainText, '加粗 与 代码 与 链接');
    });
  });

  group('Task toggle', () {
    test('toggles by offset, which is all the click handler knows', () {
      const String source = '开头\n\n- [ ] 一二三\n- [ ] 四五六\n';
      // The offset of the box on the second task line is somewhere inside it.
      final int second = source.lastIndexOf('[');
      expect(toggleTaskAt(source, second), '开头\n\n- [ ] 一二三\n- [x] 四五六\n');
      // Toggling again flips it back — one character either way.
      final String once = toggleTaskAt(source, second);
      expect(toggleTaskAt(once, second), source);
      // Offsets 0 and past-the-end must not throw or change anything.
      expect(toggleTaskAt(source, 0), source);
      expect(toggleTaskAt(source, source.length), source);
    });
  });

  group('Editing actions', () {
    TextEditingValue value(String text, int start, [int? end]) =>
        TextEditingValue(
          text: text,
          selection: TextSelection(
            baseOffset: start,
            extentOffset: end ?? start,
          ),
        );

    test('wraps and unwraps the selection', () {
      final MarkdownEditFn bold = wrapSelection('**', '**');
      final TextEditingValue wrapped = bold(value('hello', 0, 5));
      expect(wrapped.text, '**hello**');
      expect(wrapped.selection.textInside(wrapped.text), 'hello');
      expect(bold(wrapped).text, 'hello');
    });

    test('formats the word under the caret when nothing is selected', () {
      final TextEditingValue out = wrapSelection('*', '*')(value('say hi', 5));
      expect(out.text, 'say *hi*');
    });

    test('清除格式 strips every inline marker, and leaves the blocks alone', () {
      final MarkdownEditFn clear = clearFormatting();

      expect(
        clear(value('**粗**、*斜*、~~删~~、==亮==、`码`', 0, 28)).text,
        '粗、斜、删、亮、码',
      );
      // Links keep their text, wikilinks keep their target, comments their note.
      expect(
        clear(value('[标题](https://a.b) 与 [[笔记]] 与 %%旁注%%', 0, 35)).text,
        '标题 与 笔记 与 旁注',
      );
      // Structure is not inline formatting: bullets, boxes and headings stay.
      expect(clear(value('- [ ] 事', 0, 7)).text, '- [ ] 事');
      expect(clear(value('## 标题', 0, 5)).text, '## 标题');
      // Nothing to do: text and selection come back exactly as they went in.
      final TextEditingValue untouched = clear(value('普通正文', 0, 4));
      expect(untouched.text, '普通正文');
      expect(
        untouched.selection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
    });

    test('清除格式 with no selection cleans the line under the caret', () {
      const String text = '上文\n**加粗** 与 `代码`\n下文';
      final TextEditingValue out = clearFormatting()(value(text, 12));
      expect(out.text, '上文\n加粗 与 代码\n下文');
    });

    test('reads the caret line without slicing past the start of the text', () {
      // The crash that turned a freshly opened note into a red box: a body that
      // begins with a blank line (what the front-matter split used to leave
      // behind) put offset 0 on a "line" that started at 1 while it still ended
      // at 0, and the toolbar sliced `substring(1, 0)`.
      const String body = '\n# 标题\n\n- [ ] 事\n';
      for (int caret = 0; caret <= body.length; caret++) {
        expect(
          () => markerAt(value(body, caret)),
          returnsNormally,
          reason: 'caret=$caret',
        );
      }
      expect(markerAt(value(body, 0)).kind, LineMarkerKind.paragraph);
      final LineMarker first = markerAt(value(body, 1));
      expect(first.kind, LineMarkerKind.heading);
      expect(first.level, 1);
      // A caret parked *on* the trailing newline still belongs to the line that
      // newline ends; only the empty line after it is a paragraph.
      expect(markerAt(value(body, body.length - 1)).kind, LineMarkerKind.task);
      expect(markerAt(value(body, body.length)).kind, LineMarkerKind.paragraph);
    });

    test('toggles a heading prefix on all touched lines', () {
      final MarkdownEditFn h2 = applyBlockStyle(BlockStyle.h2);
      final TextEditingValue one = h2(value('alpha\nbeta', 0, 10));
      expect(one.text, '## alpha\n## beta');
      expect(h2(one).text, 'alpha\nbeta');
    });

    test('numbers ordered lists', () {
      final TextEditingValue out = applyBlockStyle(BlockStyle.ordered)(
        value('a\nb\nc', 0, 5),
      );
      expect(out.text, '1. a\n2. b\n3. c');
    });

    // The marker a line already carries is stripped before the new one goes on.
    // Without that, `# 标题` + "bullet list" produced `- # 标题` — the old `# `
    // survived as literal text because nothing recognised it as a marker.
    test('replaces the old block marker instead of stacking it', () {
      expect(applyBlockStyle(BlockStyle.bullet)(value('# 标题', 3)).text, '- 标题');
      expect(applyBlockStyle(BlockStyle.h1)(value('- 项', 2)).text, '# 项');
      expect(applyBlockStyle(BlockStyle.quote)(value('1. 项', 2)).text, '> 项');
      // A rule *is* its whole line, so replacing it takes the dashes with it.
      expect(applyBlockStyle(BlockStyle.h1)(value('---', 2)).text, '# ');
    });

    // The EPUB Reader's note panel spells this out: turning a numbered list into
    // a task list must not throw the number away.
    test('keeps the number when a task list is applied', () {
      expect(
        applyBlockStyle(BlockStyle.task)(value('1. 事', 3)).text,
        '1. [ ] 事',
      );
      // …and clicking again takes the box off, not the whole marker.
      expect(
        applyBlockStyle(BlockStyle.task)(value('1. [ ] 事', 5)).text,
        '1. 事',
      );
      expect(applyBlockStyle(BlockStyle.task)(value('- 事', 2)).text, '- [ ] 事');
      expect(applyBlockStyle(BlockStyle.task)(value('- [ ] 事', 5)).text, '- 事');
    });

    test('converts to an ordered task list from any block', () {
      expect(
        applyBlockStyle(BlockStyle.orderedTask)(value('事', 1)).text,
        '1. [ ] 事',
      );
      expect(
        applyBlockStyle(BlockStyle.orderedTask)(value('- [ ] 事', 5)).text,
        '1. [ ] 事',
      );
      // Toggling off leaves the ordered list behind.
      expect(
        applyBlockStyle(BlockStyle.orderedTask)(value('1. [ ] 事', 5)).text,
        '1. 事',
      );
      // Two lines numbered from the sequence, not from the old numbers.
      expect(
        applyBlockStyle(BlockStyle.orderedTask)(value('9. a\nb', 0, 6)).text,
        '1. [ ] a\n2. [ ] b',
      );
    });

    test('keeps nesting through a style change', () {
      expect(applyBlockStyle(BlockStyle.h1)(value('  - 项', 4)).text, '  # 项');
      expect(applyBlockStyle(BlockStyle.bullet)(value('  - 项', 4)).text, '  项');
    });

    test('turns a browser of paragraphs into one list without gaps', () {
      final TextEditingValue out = applyBlockStyle(BlockStyle.bullet)(
        value('a\n\nb', 0, 4),
      );
      // The blank line is left alone instead of sprouting an empty bullet.
      expect(out.text, '- a\n\n- b');
    });

    test('leaves the caret after the marker, not before it', () {
      final TextEditingValue out = applyBlockStyle(BlockStyle.h2)(
        value('alpha\nbeta', 3),
      );
      expect(out.text, '## alpha\nbeta');
      // End of the first line — the next keystroke has to land after `## `.
      expect(out.selection.baseOffset, 8);
      expect(out.selection.isCollapsed, isTrue);
    });

    test('does not touch the inside of a fenced code block', () {
      const String doc = '```dart\nfinal x = 1;\n```\n正文';
      final int inside = doc.indexOf('final') + 2;
      expect(
        applyBlockStyle(BlockStyle.bullet)(value(doc, inside)).text,
        doc,
        reason: 'a fence holds code, and prefixing `- ` would put it inside',
      );
      // …but a line outside the fence is fair game again.
      expect(
        applyBlockStyle(BlockStyle.bullet)(value(doc, doc.length)).text,
        '```dart\nfinal x = 1;\n```\n- 正文',
      );
    });

    test('selects the URL so it can be pasted straight in', () {
      final TextEditingValue labelled = insertLink()(value('官网', 0, 2));
      expect(labelled.text, '[官网](https://)');
      expect(labelled.selection.textInside(labelled.text), 'https://');

      // No selection: a placeholder label, and the URL still selected.
      final TextEditingValue bare = insertLink()(value('', 0));
      expect(bare.text, '[标题](https://)');
      expect(bare.selection.textInside(bare.text), 'https://');
    });

    test('a selection that is exactly one wikilink can be unlinked', () {
      const String doc = '看 [[笔记]] 这里';
      final int from = doc.indexOf('[[');
      final int to = from + '[[笔记]]'.length;
      final TextEditingValue out = removeWikilink()(value(doc, from, to));
      expect(out.text, '看 笔记 这里');
      // 光标停在拆出来的文字后面，接着就能改。
      expect(out.selection.isCollapsed, isTrue);
      expect(out.selection.baseOffset, from + '笔记'.length);

      // 前后带空白也算「只有这一个双链」，替换时空白原地保留。
      final ({int start, int end, String label})? padded = soleWikilink(
        ' [[笔记]] ',
      );
      expect(padded?.label, '笔记');
      expect(padded?.start, 1);
      expect(removeWikilink()(value(' [[笔记]] ', 1, 7)).text, ' 笔记 ');

      // 只有整整一个双链才算：多一个字、嵌入、两个双链都不算。
      expect(soleWikilink('[[笔记]]'), isNotNull);
      expect(soleWikilink('看 [[笔记]]'), isNull);
      expect(soleWikilink('![[图片.png]]'), isNull, reason: '嵌入不是双链');
      expect(soleWikilink('[[甲]] [[乙]]'), isNull);
      // 选区不是双链时动作原样返回，菜单也不会挂上它。
      expect(removeWikilink()(value(doc, 0, 1)).text, doc);
    });

    test('inserts a divider on a line of its own', () {
      expect(insertDivider()(value('', 0)).text, '---\n');
      expect(insertDivider()(value('上文', 2)).text, '上文\n---\n');
      expect(insertDivider()(value('上文\n', 3)).text, '上文\n---\n');
      // A selected range is replaced, not appended to.
      expect(insertDivider()(value('上文', 0, 2)).text, '---\n');
    });

    test('inserts a well formed table and lands in its first cell', () {
      const String expected = '|  |  |\n| --- | --- |\n|  |  |\n';
      final TextEditingValue empty = insertTable()(value('', 0));
      expect(empty.text, expected);
      // The caret goes into the first cell, so typing starts in the table
      // rather than after it.
      expect(empty.selection.baseOffset, 2);

      // Mid-paragraph: a newline is added first, so the header row is not
      // glued to the sentence above it.
      final TextEditingValue mid = insertTable()(value('上文', 2));
      expect(mid.text, '上文\n$expected');
      expect(mid.selection.baseOffset, 5);

      // The table must be one the renderer will actually recognise: header,
      // divider, body — and every row the same width.
      final List<String> rows = empty.text.split('\n')..removeLast();
      expect(rows, hasLength(3));
      for (final String row in rows) {
        expect(
          row.split('|').length - 2,
          2,
          reason: 'row is not 2 cells: $row',
        );
      }
    });

    test('Tab walks the cells, then grows the table', () {
      const String table = '| a | b |\n| --- | --- |\n| c | d |\n';
      // From the first cell, Tab selects the second cell's content — so typing
      // replaces it instead of appending to it.
      final TextEditingValue second = tableCellStep(
        value(table, 1),
        forward: true,
      )!;
      expect(
        table.substring(second.selection.start, second.selection.end),
        'b',
      );
      // …and Shift+Tab comes back.
      final TextEditingValue back = tableCellStep(second, forward: false)!;
      expect(table.substring(back.selection.start, back.selection.end), 'a');
      // Tab off the end of a row crosses the divider into the next row.
      final TextEditingValue nextRow = tableCellStep(
        value(table, table.indexOf('b')),
        forward: true,
      )!;
      expect(
        nextRow.text.substring(nextRow.selection.start, nextRow.selection.end),
        'c',
      );
      // Tab off the very last cell appends a row of the same width.
      final TextEditingValue grown = tableCellStep(
        value(table, table.indexOf('d')),
        forward: true,
      )!;
      expect(grown.text, '$table|  |  |\n');
      expect(grown.selection.isCollapsed, isFalse, reason: '新行第一格被选中');
      expect(
        grown.text.substring(grown.selection.start, grown.selection.end),
        '  ',
      );
    });

    test('Tab outside a table is still indentation', () {
      expect(tableCellStep(value('- 一', 2), forward: true), isNull);
      expect(tableCellStep(value('正文', 1), forward: true), isNull);
      expect(tableRowBelow(value('正文', 1)), isNull);
      // A paragraph directly under a table must not be sucked into the grid,
      // and a pipe-led line inside a fence is code, not a row.
      const String below = '| a | b |\n| --- | --- |\n正文';
      expect(tableCellStep(value(below, below.length), forward: true), isNull);
      const String fence = '```\n| a | b |\n```';
      expect(tableCellStep(value(fence, 8), forward: true), isNull);
    });

    test('Enter in a table adds a row in the same column', () {
      const String table = '| a | b |\n| --- | --- |\n| c | d |\n';
      final TextEditingValue next = tableRowBelow(
        value(table, table.indexOf('d')),
      )!;
      expect(next.text, '$table|  |  |\n');
      // The caret lands in the second column of the new row, not its first.
      final String row = next.text.substring(next.text.lastIndexOf('\n|'));
      expect(
        next.selection.start - next.text.lastIndexOf('\n|'),
        inInclusiveRange(row.indexOf('|') + 3, row.length),
      );
    });

    test('a part of a row is still one cell list', () {
      // The renderer and Tab share one parser, so a row whose trailing pipe
      // was never typed must be read the same way by both.
      expect(tableCellsOf('| a | b |').length, 2);
      expect(tableCellsOf('| a | b').length, 2);
      // Text before the first pipe is not a cell — that line is not a table.
      expect(isTableLine('a | b'), isFalse);
      expect(tableCellsOf('no pipes here'), isEmpty);
    });

    test('a Backspace may not delete out of its cell', () {
      // `| 区域 | 你能在这里 |` — editing a cell happens in place, so the caret
      // can sit right before `你`; one Backspace too many used to eat the pipe
      // (and, once the cell was empty, the text of the cell to its left).
      const String table = '| 区域 | 你能在这里 |';
      final int start = table.indexOf('你');
      expect(tableCellBarrier(table, start), isFalse, reason: '这里删的是内容');
      // The padding space in front of the cell belongs to the table.
      expect(tableCellBarrier(table, start - 1), isTrue, reason: '首格内边距');
      // …and the pipe is the wall itself.
      expect(tableCellBarrier(table, start - 2), isTrue, reason: '管道');
      // Deleting inside the cell is never restricted.
      expect(tableCellBarrier(table, table.indexOf('能')), isFalse);

      // An empty cell blocks everything: there is nothing left in it to delete.
      const String empty = '| 区域 |  |';
      expect(tableCellBarrier(empty, empty.indexOf('|  |') + 3), isTrue);

      // Prose has no barrier at all.
      expect(tableCellBarrier('你能在这里', 3), isFalse);
      // …and neither does the newline before a row, so lines still join.
      const String two = '上文\n| a | b |';
      expect(tableCellBarrier(two, 2), isFalse);
    });

    test('a row can be dragged to another slot in its block', () {
      const String table =
          '| h | H |\n| --- | --- |\n| a | A |\n| b | B |\n| c | C |';
      final TextEditingValue v = value(table, table.indexOf('b'));
      // The divider is not a row: `a`,`b`,`c` are 0,1,2 and the header is 0 too.
      // Dragging `b` above `a` puts it directly under the divider…
      final String up = moveTableRow(v, v.selection.start, 2, 1)!.text;
      expect(up, '| h | H |\n| --- | --- |\n| b | B |\n| a | A |\n| c | C |');
      // …and dragging `b` to the very top makes *it* the header, with the
      // divider following it. The old header stays a body row.
      final String top = moveTableRow(v, v.selection.start, 2, 0)!.text;
      expect(top, '| b | B |\n| --- | --- |\n| h | H |\n| a | A |\n| c | C |');
      // The caret rides along with its text.
      final TextEditingValue moved = moveTableRow(v, v.selection.start, 2, 1)!;
      expect(moved.selection.baseOffset, moved.text.indexOf('b'));
      // A no-op stays a no-op, and prose is untouched.
      expect(moveTableRow(v, v.selection.start, 2, 2), isNull);
      expect(moveTableRow(value('正文', 1), 1, 0, 1), isNull);
    });

    test('a column can be dragged to another slot in its table', () {
      const String table = '| h | H | x |\n| --- | --- | --- |\n| a | A | y |';
      final TextEditingValue v = value(table, table.indexOf('A'));
      final String left = moveTableColumn(v, v.selection.start, 1, 0)!.text;
      expect(left, '| H | h | x |\n| --- | --- | --- |\n| A | a | y |');
      // …and the caret stays on the character it was on, in its new column.
      final TextEditingValue moved = moveTableColumn(
        v,
        v.selection.start,
        1,
        0,
      )!;
      expect(moved.text.substring(moved.selection.start), startsWith('A'));
      // A divider with alignment markers moves with its column.
      const String aligned = '| a | b |\n| :-- | --: |\n| c | d |';
      final String swapped = moveTableColumn(
        value(aligned, aligned.indexOf('b')),
        aligned.indexOf('b'),
        1,
        0,
      )!.text;
      expect(swapped, '| b | a |\n| ---: | :--- |\n| d | c |');
      expect(moveTableColumn(v, v.selection.start, 1, 1), isNull);
    });

    test('the divider is a row without cells', () {
      expect(isTableDivider('| --- | --- |'), isTrue);
      expect(isTableDivider('| :--- | :-: | ---: |'), isTrue);
      expect(isTableDivider('| a | b |'), isFalse);
      expect(isTableDivider('| --- | date |'), isFalse);
      // Tab steps over it rather than selecting the dashes.
      const String table = '| a | b |\n| --- | --- |\n| c | d |\n';
      final TextEditingValue down = tableCellStep(
        value(table, table.indexOf('b')),
        forward: true,
      )!;
      expect(
        down.text.substring(down.selection.start, down.selection.end),
        'c',
      );
      // A caret parked on the hidden divider still moves into the table.
      final TextEditingValue off = tableCellStep(
        value(table, table.indexOf('---') + 1),
        forward: true,
      )!;
      expect(off.text.substring(off.selection.start, off.selection.end), 'c');
    });

    test('a column is added to every row, divider included', () {
      const String table = '| a | b |\n| --- | --- |\n| c | d |';
      final TextEditingValue right = editTable(
        value(table, table.indexOf('b')),
        TableEdit.columnRight,
      )!;
      expect(right.text, '| a | b |  |\n| --- | --- | --- |\n| c | d |  |');
      // The caret stays on 'b' — adding a column must not move the user's work.
      expect(right.selection.start, right.text.indexOf('b'));

      final TextEditingValue left = editTable(
        value(table, table.indexOf('b')),
        TableEdit.columnLeft,
      )!;
      expect(left.text, '| a |  | b |\n| --- | --- | --- |\n| c |  | d |');
      expect(left.selection.start, left.text.indexOf('b'));
    });

    test('a deleted column leaves no empty pipe behind', () {
      const String table = '| a | b |\n| --- | --- |\n| c | d |';
      expect(
        editTable(
          value(table, table.indexOf('b')),
          TableEdit.deleteColumn,
        )!.text,
        '| a |\n| --- |\n| c |',
      );
      // Deleting the first column keeps a leading pipe, so it is still a table.
      expect(
        editTable(
          value(table, table.indexOf('a')),
          TableEdit.deleteColumn,
        )!.text,
        '| b |\n| --- |\n| d |',
      );
    });

    test('rows are added above and removed, keeping the divider', () {
      const String table = '| a | b |\n| --- | --- |\n| c | d |';
      final TextEditingValue above = editTable(
        value(table, table.indexOf('b')),
        TableEdit.rowAbove,
      )!;
      expect(above.text, '|  |  |\n| --- | --- |\n| a | b |\n| c | d |');
      expect(
        above.text.substring(above.selection.start, above.selection.end),
        '  ',
        reason: '新行里选中的是光标所在那一列',
      );

      final TextEditingValue gone = editTable(
        value(table, table.indexOf('d')),
        TableEdit.deleteRow,
      )!;
      expect(gone.text, '| a | b |\n| --- | --- |');
      // The divider is the table's skeleton and cannot be deleted.
      expect(
        editTable(value(table, table.indexOf('---')), TableEdit.deleteRow),
        isNull,
      );
      // Neither can the last remaining column.
      const String single = '| only |\n| --- |';
      expect(editTable(value(single, 3), TableEdit.deleteColumn), isNull);
    });

    test('table edits are refused outside a table and inside a fence', () {
      expect(editTable(value('正文', 1), TableEdit.columnRight), isNull);
      const String fence = '```\n| a | b |\n```';
      expect(editTable(value(fence, 8), TableEdit.columnRight), isNull);
    });

    test('keeps the caret inside an inserted code block', () {
      final TextEditingValue out = codeBlock(language: 'dart')(value('', 0));
      expect(out.text.trim(), '```dart\n\n```');
      expect(out.selection.baseOffset, greaterThan(0));
      expect(out.selection.baseOffset, lessThan(out.text.length));
    });

    test('indents and outdents the selected lines', () {
      final TextEditingValue indented = indentLines(
        value('a\nb', 0, 3),
        outdent: false,
      );
      expect(indented.text, '  a\n  b');
      expect(indentLines(indented, outdent: true).text, 'a\nb');
    });

    test('a caret is not turned into a line selection', () {
      final TextEditingValue indented = indentLines(
        value('a\n- b', 5),
        outdent: false,
      );
      expect(indented.text, 'a\n  - b');
      expect(indented.selection, const TextSelection.collapsed(offset: 7));

      final TextEditingValue outdented = indentLines(indented, outdent: true);
      expect(outdented.text, 'a\n- b');
      expect(outdented.selection, const TextSelection.collapsed(offset: 5));
    });

    test('renumbers the ordered list it indents into', () {
      final TextEditingValue indented = indentLines(
        value('1. a\n2. b\n3. c\n4. d', 12),
        outdent: false,
      );
      expect(indented.text, '1. a\n2. b\n  1. c\n3. d');

      final TextEditingValue back = indentLines(indented, outdent: true);
      expect(back.text, '1. a\n2. b\n3. c\n4. d');
      expect(back.selection, const TextSelection.collapsed(offset: 12));
    });

    test('renumbers an ordered task list', () {
      final TextEditingValue next = indentLines(
        value('1. [ ] a\n2. [ ] b\n3. [ ] c', 26),
        outdent: false,
      );
      expect(next.text, '1. [ ] a\n2. [ ] b\n  1. [ ] c');
    });

    test('keeps the caret beside the digits when a number narrows', () {
      final TextEditingValue next = indentLines(
        value('1. a\n   10. b', 13),
        outdent: true,
      );
      expect(next.text, '1. a\n 1. b');
      expect(next.selection, const TextSelection.collapsed(offset: 10));
    });

    test('a paragraph is indented but never renumbered', () {
      final TextEditingValue next = indentLines(
        value('1. a\n1. b\ntext', 14),
        outdent: false,
      );
      expect(next.text, '1. a\n1. b\n  text');
    });
  });

  group('Syntax highlighter', () {
    test('classifies comments, strings, numbers and keywords', () {
      final List<List<CodeToken>> lines = highlightCode(
        '// note\nfinal x = "hi";\nvar n = 42;',
        'dart',
      );
      expect(lines.length, 3);

      final List<CodeToken> first = lines.first;
      expect(first.single.kind, TokenKind.comment);

      final Set<TokenKind> secondKinds = lines[1]
          .map((CodeToken t) => t.kind)
          .toSet();
      expect(secondKinds, contains(TokenKind.keyword));
      expect(secondKinds, contains(TokenKind.string));

      expect(
        lines[2].any(
          (CodeToken t) => t.kind == TokenKind.number && t.text == '42',
        ),
        isTrue,
      );
    });

    test('never loses characters, whatever the language', () {
      const String code = 'a = "x\\ny" + `tpl` /* c */ # h\nend';
      for (final String lang in <String>[
        'dart',
        'python',
        'shell',
        '',
        'zsh',
      ]) {
        final List<List<CodeToken>> lines = highlightCode(code, lang);
        final String rebuilt = lines
            .map((List<CodeToken> l) => l.map((CodeToken t) => t.text).join())
            .join('\n');
        expect(rebuilt, code, reason: 'language "$lang" lost characters');
      }
    });

    test('maps aliases onto real grammars', () {
      expect(normaliseLanguage('ts'), 'javascript');
      expect(normaliseLanguage('yml'), 'yaml');
      expect(normaliseLanguage('未知语言'), '');
    });
  });

  /// Pressing Enter at the end of a list item has to keep the list going: a new
  /// bullet for a bullet, the *next number* for an ordered item, a fresh empty
  /// box for a task. An empty item steps *out*: one level to its parent while a
  /// nested one is open, and off the list entirely at the top.
  ///
  /// The rule table here mirrors `EPUB Reader V7`'s `MarkdownListContinueFormatter`
  /// (the reference the user pointed at), including the detail that a checked
  /// box continues unchecked and that `1)` keeps its parenthesis.
  group('List continuation on Enter', () {
    final ListContinuationFormatter fmt = ListContinuationFormatter();

    /// The exact old/new pair the platform hands a formatter for one Enter press:
    /// one newline inserted at the caret, caret after it. Going through this
    /// shape rather than calling a helper is the point — the formatter is only
    /// allowed to act on this shape and has to stay inert for every other.
    TextEditingValue enter(
      String text,
      int caret, {
      TextRange composing = TextRange.empty,
      int? extent,
    }) {
      final TextEditingValue old = TextEditingValue(
        text: text,
        selection: extent == null
            ? TextSelection.collapsed(offset: caret)
            : TextSelection(baseOffset: caret, extentOffset: extent),
        composing: composing,
      );
      final TextEditingValue next = TextEditingValue(
        text: '${text.substring(0, caret)}\n${text.substring(caret)}',
        selection: TextSelection.collapsed(offset: caret + 1),
      );
      return fmt.formatEditUpdate(old, next);
    }

    test('a bullet continues with the bullet the user chose', () {
      for (final String mark in <String>['-', '*', '+']) {
        final TextEditingValue out = enter('$mark 甲', 3);
        expect(out.text, '$mark 甲\n$mark ', reason: mark);
        expect(
          out.selection.baseOffset,
          out.text.length,
          reason: 'the caret belongs after the new marker',
        );
      }
    });

    test('an ordered item continues with the next number', () {
      expect(enter('1. 甲', 4).text, '1. 甲\n2. ');
      expect(enter('9. 甲', 4).text, '9. 甲\n10. ');
      // The separator is the user's choice and survives: `3)` is not `3.`.
      expect(enter('3) 甲', 4).text, '3) 甲\n4) ');
    });

    test('a task continues unchecked, however it was checked', () {
      expect(enter('- [ ] 甲', 7).text, '- [ ] 甲\n- [ ] ');
      expect(enter('- [x] 甲', 7).text, '- [x] 甲\n- [ ] ');
      expect(enter('* [X] 甲', 7).text, '* [X] 甲\n* [ ] ');
    });

    test('an ordered task keeps both its numbering and its box', () {
      expect(enter('6. [ ] 事', 8).text, '6. [ ] 事\n7. [ ] ');
    });

    test('a nested item keeps its indentation', () {
      expect(enter('   - 甲', 6).text, '   - 甲\n   - ');
      expect(enter('\t- 甲', 4).text, '\t- 甲\n\t- ');
      expect(enter('  - [ ] 甲', 9).text, '  - [ ] 甲\n  - [ ] ');
    });

    test('an empty top-level item ends the list instead of nesting deeper', () {
      // The realistic shape: content above, an empty item under it. Enter there
      // clears the marker out and leaves a plain blank line, so the next thing
      // typed is a paragraph again.
      expect(enter('- 甲\n- ', 6).text, '- 甲\n\n');
      expect(enter('1. 甲\n2. ', 8).text, '1. 甲\n\n');
      expect(enter('- [x] 甲\n- [ ] ', 14).text, '- [x] 甲\n\n');
      // Standalone, the marker simply disappears and the caret rides along.
      for (final String empty in <String>['- ', '* ', '1. ', '- [ ] ']) {
        final TextEditingValue out = enter(empty, empty.length);
        expect(out.text.trim(), isEmpty, reason: empty);
        expect(out.selection.baseOffset, out.text.length, reason: empty);
      }
    });

    test('an empty nested item steps out to its parent level', () {
      const String text = '- 甲\n  - 乙\n  - ';
      final TextEditingValue out = enter(text, text.length);
      expect(out.text, '- 甲\n  - 乙\n- ');
      expect(
        out.selection.baseOffset,
        out.text.length,
        reason: 'the caret belongs after the parent-level marker',
      );

      // One rung at a time: a grandchild steps out to its own parent, not to
      // the top. The indent is whatever the parent line used.
      const String deep = '- 甲\n  - 乙\n    - 丙\n    - ';
      expect(enter(deep, deep.length).text, '- 甲\n  - 乙\n    - 丙\n  - ');
      const String tabbed = '- 甲\n\t- 乙\n\t- ';
      expect(enter(tabbed, tabbed.length).text, '- 甲\n\t- 乙\n- ');
    });

    test('stepping out keeps the kind of item the user was writing', () {
      const String task = '- [ ] 甲\n  - [x] 乙\n  - [ ] ';
      expect(enter(task, task.length).text, '- [ ] 甲\n  - [x] 乙\n- [ ] ');
      // The bullet character is the user's and survives the step out.
      const String star = '- 甲\n  * 乙\n  * ';
      expect(enter(star, star.length).text, '- 甲\n  * 乙\n* ');
    });

    test('stepping out of an ordered child takes the parent next number', () {
      const String one = '1. 甲\n   1. 乙\n   2. ';
      expect(enter(one, one.length).text, '1. 甲\n   1. 乙\n2. ');

      // The child's own number counts children, not siblings of its parent.
      const String three = '1. 甲\n   1. 乙\n   2. 丙\n   3. ';
      expect(enter(three, three.length).text, '1. 甲\n   1. 乙\n   2. 丙\n2. ');

      const String task = '6. [ ] 事\n   1. [ ] 次\n   2. [ ] ';
      expect(enter(task, task.length).text, '6. [ ] 事\n   1. [ ] 次\n7. [ ] ');
    });

    test('stepping out pushes the parent numbers below it down', () {
      // 出列表不增减行数，但仍然改了列表结构：新父项后面的同级序号必须跟着后移。
      const String text = '1. 甲\n   1. 子\n   2. \n2. 乙\n3. 丙';
      final TextEditingValue out = enter(text, text.indexOf('\n2. 乙'));
      expect(out.text, '1. 甲\n   1. 子\n2. \n3. 乙\n4. 丙');
      expect(
        out.selection.baseOffset,
        '1. 甲\n   1. 子\n2. '.length,
        reason: 'the caret stays after the new item\'s marker',
      );

      // The outer list's first number is the user's and survives the renumber.
      const String fromFifteen = '15. 甲\n    1. 子\n    2. \n16. 乙';
      final TextEditingValue out2 = enter(
        fromFifteen,
        fromFifteen.indexOf('\n16. 乙'),
      );
      expect(out2.text, '15. 甲\n    1. 子\n16. \n17. 乙');
    });

    test('stepping out consumes the Enter instead of leaving a blank line', () {
      // 空子项出列表的那一下回车只负责“上一级”，不该在下面再留一行空白；
      // 原本就在下面的内容仍留在下一行。
      const String text = '- 甲\n  - 乙\n  - \n- 丙';
      final TextEditingValue out = enter(text, text.indexOf('\n- 丙'));
      expect(out.text, '- 甲\n  - 乙\n- \n- 丙');
      expect(out.selection.baseOffset, '- 甲\n  - 乙\n- '.length);
    });

    test('an indented empty item with no parent above ends the list', () {
      // Indentation alone does not make a parent: with a paragraph above there
      // is no level to step out to, so Enter takes the marker away as at the top.
      const String plain = '正文\n  - ';
      expect(enter(plain, plain.length).text, '正文\n\n');
      const String alone = '  - ';
      final TextEditingValue out = enter(alone, alone.length);
      expect(out.text.trim(), isEmpty);
      expect(out.selection.baseOffset, out.text.length);
    });

    test('a parent cut off by other content starts the sequence over at 1', () {
      // 父级序号和这个子列表之间隔着正文 / 分割线：退出来的那一条接的是新
      // 列表，不是上面那串被隔断的序号。
      const String paragraph = '5. 甲\n6. 乙\n\n正文\n\n   1. 子\n   2. ';
      expect(
        enter(paragraph, paragraph.length).text,
        '5. 甲\n6. 乙\n\n正文\n\n   1. 子\n1. ',
      );

      const String rule =
          '5. [ ] 甲\n6. [ ] 乙\n\n---\n\n   1. [ ] 子\n   2. [ ] ';
      expect(
        enter(rule, rule.length).text,
        '5. [ ] 甲\n6. [ ] 乙\n\n---\n\n   1. [ ] 子\n1. [ ] ',
      );

      // The separator the user writes survives, as it does within one level.
      const String paren = '5. 甲\n\n正文\n\n   1. 子\n   2) ';
      expect(enter(paren, paren.length).text, '5. 甲\n\n正文\n\n   1. 子\n1) ');
    });

    test('a bullet steps out across content without taking a number', () {
      const String text = '5. 甲\n6. 乙\n\n正文\n\n   - 子\n   - ';
      expect(enter(text, text.length).text, '5. 甲\n6. 乙\n\n正文\n\n   - 子\n- ');
    });

    test('blank lines between the levels keep the parent sequence going', () {
      // 被回车隔开（空行）不算：父级序号照常接续。
      const String text = '6. 乙\n\n   1. 子\n   2. ';
      expect(enter(text, text.length).text, '6. 乙\n\n   1. 子\n7. ');
    });

    test('an item continues even when more text follows it', () {
      // The regression: the guard used to ask "does the rest of the text contain
      // a newline", which is true for every line but the last — so continuation
      // only ever worked at the very bottom of a document.
      final TextEditingValue out = enter('- 甲\n乙\n丙', 3);
      expect(out.text, '- 甲\n- \n乙\n丙');
      expect(out.selection.baseOffset, 6);
    });

    test('Enter in the middle of an item splits it into two items', () {
      // 后半段不是一条没有标记的裸行：它接着成为同一个列表的下一条。
      expect(enter('- 甲乙', 3).text, '- 甲\n- 乙');
    });

    test('an empty quote ends the quote', () {
      expect(enter('> 引用\n> ', 7).text, '> 引用\n\n');
    });

    test('ordinary lines, headings, quotes and rules are left alone', () {
      for (final String line in <String>[
        '正文',
        '# 标题',
        '---',
        '> 引用',
        '-不是列表',
      ]) {
        expect(enter(line, line.length).text, '$line\n', reason: line);
      }
    });

    test('a newline committed by an IME continues nothing', () {
      // While a composition is open, Enter is the IME's to consume — reacting to
      // it would inject a bullet into text the user never finished typing.
      final TextEditingValue out = enter(
        '- 甲',
        3,
        composing: const TextRange(start: 0, end: 3),
      );
      expect(out.text, '- 甲\n');
    });

    test('an Enter that replaces a selection continues nothing', () {
      final TextEditingValue old = const TextEditingValue(
        text: '- 甲',
        selection: TextSelection(baseOffset: 0, extentOffset: 2),
      );
      const TextEditingValue next = TextEditingValue(
        text: '\n 甲',
        selection: TextSelection.collapsed(offset: 1),
      );
      expect(fmt.formatEditUpdate(old, next).text, '\n 甲');
    });

    test('Enter in a table adds a row instead of slicing the row', () {
      // A bare newline inside `| c | d |` splits it into two lines, only one of
      // which still starts with a pipe — half the table would vanish mid-keystroke.
      const String table = '| a | b |\n| --- | --- |\n| c | d |';
      final TextEditingValue out = enter(table, table.length);
      expect(out.text, '$table\n|  |  |');
      expect(
        out.text.substring(out.selection.start, out.selection.end),
        '  ',
        reason: '新行里选中的是第一格的内容',
      );
      // Mid-cell Enter grows the table too, rather than breaking the line.
      expect(enter(table, table.indexOf('c') + 1).text, '$table\n|  |  |');
    });

    test('Enter in a fenced block is still a line break', () {
      // Pipes inside ``` are code samples, not a table.
      expect(enter('```\n| a | b |\n```', 13).text, '```\n| a | b |\n\n```');
    });
  });

  /// 增删整行之后，有序列表的序号必须自己接上：删掉 16 那一条，下面的 17
  /// 变回 16；在 15 后面回车插一条，后面的序号依次后移。
  ///
  /// 这里按输入框里真实的 formatter 顺序调用（续行 → 重编号），old/new 的形状
  /// 也和平台送来的一致：前者是编辑前的值，后者是续行格式化器处理后的值。
  group('Ordered list renumbering after a line change', () {
    final ListContinuationFormatter enter = ListContinuationFormatter();
    final OrderedListRenumberFormatter renumber =
        OrderedListRenumberFormatter();

    TextEditingValue after(TextEditingValue old, TextEditingValue next) =>
        renumber.formatEditUpdate(old, enter.formatEditUpdate(old, next));

    TextEditingValue enterAt(String text, int caret) => after(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      ),
      TextEditingValue(
        text: '${text.substring(0, caret)}\n${text.substring(caret)}',
        selection: TextSelection.collapsed(offset: caret + 1),
      ),
    );

    /// 删掉 [text] 里从 [start] 到 [end]（含行尾换行）的一整行。
    TextEditingValue deleteRange(String text, int start, int end) => after(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: end),
      ),
      TextEditingValue(
        text: text.substring(0, start) + text.substring(end),
        selection: TextSelection.collapsed(offset: start),
      ),
    );

    test('Enter in the middle of a list pushes the numbers below down', () {
      const String text = '15. [ ] 甲\n16. [ ] 乙\n17. [ ] 丙';
      final TextEditingValue out = enterAt(text, text.indexOf('\n'));
      expect(out.text, '15. [ ] 甲\n16. [ ] \n17. [ ] 乙\n18. [ ] 丙');
      expect(
        out.text.substring(0, out.selection.baseOffset),
        endsWith('16. [ ] '),
        reason: 'caret belongs after the new item\'s marker',
      );
    });

    test('行中回车把后半段拆成下一个序号', () {
      const String text = '15. [ ] 序号排列问题\n16. [ ] 乙';
      final TextEditingValue out = enterAt(text, text.indexOf('问题'));
      expect(out.text, '15. [ ] 序号排列\n16. [ ] 问题\n17. [ ] 乙');
      expect(
        out.text.substring(0, out.selection.baseOffset),
        endsWith('16. [ ] '),
        reason: 'caret belongs after the new item\'s marker',
      );
    });

    test('deleting an item closes the gap it left', () {
      const String text = '15. [ ] 甲\n16. [ ] 乙\n17. [ ] 丙';
      final TextEditingValue out = deleteRange(
        text,
        text.indexOf('16.'),
        text.indexOf('\n17.') + 1,
      );
      expect(out.text, '15. [ ] 甲\n16. [ ] 丙');
    });

    test('stepping an empty child out renumbers the parent list', () {
      // 真实输入框里的顺序：续行格式化器先出列表，再由重编号器接手。出列表
      // 不增减行数，所以重编号是续行格式化器自己强制触发的。
      const String text = '1. 甲\n   1. 子\n   2. \n2. 乙';
      final TextEditingValue out = enterAt(text, text.indexOf('\n2. 乙'));
      expect(out.text, '1. 甲\n   1. 子\n2. \n3. 乙');
      expect(out.selection.baseOffset, '1. 甲\n   1. 子\n2. '.length);
    });

    test('a plain ordered list renumbers the same way', () {
      const String text = '15. 甲\n16. 乙\n17. 丙';
      final TextEditingValue out = deleteRange(
        text,
        text.indexOf('16.'),
        text.indexOf('\n17.') + 1,
      );
      expect(out.text, '15. 甲\n16. 丙');
    });

    test('the block keeps the number it starts at', () {
      // 15 是用户自己的起始序号，不能被重排成 1。
      const String text = '15. 甲\n16. 乙';
      final TextEditingValue out = deleteRange(
        text,
        text.indexOf('\n16.'),
        text.length,
      );
      expect(out.text, '15. 甲');
    });

    test('a narrower number pulls the caret back with it', () {
      const String text = '8. 甲\n9. 乙\n10. 丙';
      final TextEditingValue out = deleteRange(
        text,
        text.indexOf('9.'),
        text.indexOf('\n10.') + 1,
      );
      expect(out.text, '8. 甲\n9. 丙');
      expect(out.selection.baseOffset, '8. 甲\n'.length);
    });

    test('typing inside an item does not renumber', () {
      const String text = '15. 甲\n16. 乙';
      final TextEditingValue next = TextEditingValue(
        text: '15. 甲乙\n16. 乙',
        selection: TextSelection.collapsed(offset: 5),
      );
      expect(
        renumber
            .formatEditUpdate(
              TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: 4),
              ),
              next,
            )
            .text,
        next.text,
      );
    });

    test('a paragraph next to a list is not renumbered', () {
      const String text = '15. 甲\n16. 乙\n\n正文';
      final TextEditingValue next = TextEditingValue(
        text: '15. 甲\n16. 乙\n\n正',
        selection: TextSelection.collapsed(offset: text.length - 1),
      );
      expect(
        renumber
            .formatEditUpdate(
              TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              ),
              next,
            )
            .text,
        next.text,
      );
    });

    test('pasting several lines keeps the numbers it brought', () {
      const String text = '15. 甲';
      const String pasted = '15. 甲\n1. x\n2. y';
      expect(
        renumber
            .formatEditUpdate(
              const TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: 5),
              ),
              const TextEditingValue(
                text: pasted,
                selection: TextSelection.collapsed(offset: 16),
              ),
            )
            .text,
        pasted,
      );
    });

    test('numbers inside a fence are code, not a list', () {
      const String text = '```\n1. 甲\n2. 乙\n3. 丙\n```';
      final TextEditingValue out = deleteRange(
        text,
        text.indexOf('2. '),
        text.indexOf('\n3.') + 1,
      );
      expect(out.text, '```\n1. 甲\n3. 丙\n```');
    });
  });

  group('Line height', () {
    // A paragraph steps by `(fontSize * height).round()` but paints a line's
    // highlight box `fontSize * height` tall. Whatever fraction is left over
    // comes out as a hairline of paper between the lines of a selection, so
    // every ratio the renderer emits is snapped to a whole-pixel line height.
    test('snapLineHeight leaves a whole number of pixels', () {
      for (final double size in <double>[
        12,
        13,
        14.5,
        15.5,
        16,
        17.5,
        20,
        22,
      ]) {
        final double line = size * snapLineHeight(size, 1.78);
        expect(
          line,
          closeTo(line.roundToDouble(), 1e-9),
          reason: '$size px 的行高不是整数：$line',
        );
        expect(
          (line - size * 1.78).abs(),
          lessThanOrEqualTo(0.5),
          reason: '$size px 的行高偏离设计值超过半个像素',
        );
      }
    });

    test('a zero or negative size is left alone', () {
      expect(snapLineHeight(0, 1.78), 1.78);
    });
  });

  group('Text above a line', () {
    // The pane puts a line at a given height on screen — "jump to heading",
    // scrolling the caret line into view — from this number. Counting headings
    // as body rows used to land every jump short by the headings it had passed.
    const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
    const AppPalette palette = AppPalette.midnight;
    const int target = 6;

    double above(String text) =>
        textHeightAbove(text: text, base: base, p: palette, line: target);

    test('body rows above the line measure one row each', () {
      expect(above('a\n\nb\n\nc\n\ntarget'), closeTo(6 * 28, 1e-6));
    });

    test('a fenced block counts its own shorter rows', () {
      // The opening fence is a 16px header row, each code row is 20px, and the
      // closing fence collapses to nothing. The measuring pass sees body rows
      // for all of them, so each has to be corrected to its real box.
      expect(
        above('```\na\nb\n```\n\n\ntarget'),
        closeTo(16 + 2 * 20 + 2 * 28, 1e-6),
      );
    });

    test('an H1 above the line is measured as its own line box', () {
      // Six lines again, but the first is a heading: five body rows plus the
      // heading's 39px box — not six rows of 28.
      expect(above('# 一\n\nb\n\nc\n\ntarget'), closeTo(5 * 28 + 39, 1e-6));
    });

    test('a heading below the line is not counted', () {
      expect(above('a\n\nb\n\nc\n\ntarget\n\n# 二'), closeTo(6 * 28, 1e-6));
    });

    test('a # inside a fence is code, not a heading', () {
      // None of the rows above the target is a heading — the `#` sits inside
      // the fence: header 16, one code row at 20, a collapsed closing fence,
      // then three body rows. Counting the `#` as a heading would add the H1
      // box on top.
      expect(
        above('```\n# 一\n```\na\n\nb\ntarget'),
        closeTo(16 + 20 + 3 * 28, 1e-6),
      );
    });
  });

  group('Table', () {
    const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
    const AppPalette palette = AppPalette.midnight;
    // `| a | b |` forms; the divider makes the row above it the header.
    const String doc = '| 想要 | 就写 |\n| --- | --- |\n| **加粗** | `Ctrl + B` |\n';
    // 表格几何由 `LiveTableBlocks` 自绘承担：直接读它交给渲染层的行/列矩形
    // 与单元格文本，不再走已退役的段落级 `measureTables`。
    ({LineDocumentLayout layout, List<TableRowChrome> rows}) tableOf(
      String text, {
      TextSelection selection = const TextSelection.collapsed(offset: -1),
    }) {
      final LiveTableBlocks blocks = LiveTableBlocks(
        base: base,
        palette: palette,
        text: () => text,
        selection: () => selection,
      );
      addTearDown(blocks.dispose);
      final LineDocumentLayout layout = layoutLines(
        text: text,
        baseStyle: base,
        contentWidth: 680,
        blockFor: blocks.blockFor,
      );
      addTearDown(layout.dispose);
      return (
        layout: layout,
        rows: <TableRowChrome>[
          for (final LaidOutLine line in layout.laidOut)
            if (line.block is TableRowChrome) line.block! as TableRowChrome,
        ],
      );
    }

    test('a table block is measured once, with every row', () {
      final ({LineDocumentLayout layout, List<TableRowChrome> rows}) t =
          tableOf(doc);
      // The divider line is not a row; header plus one body row are.
      expect(t.rows, hasLength(2));
      expect(t.layout.laidOut[0].source.kind, LineBlockKind.tableHeader);
      expect(t.layout.laidOut[1].source.kind, LineBlockKind.tableDivider);
      expect(t.layout.laidOut[2].source.kind, LineBlockKind.table);
    });

    test('columns line up across rows', () {
      final ({LineDocumentLayout layout, List<TableRowChrome> rows}) t =
          tableOf(doc);
      final List<Rect> header = t.rows.first.chromeCells();
      expect(header, hasLength(2));
      for (int c = 0; c < 2; c++) {
        final Rect first = header[c];
        for (final TableRowChrome row in t.rows) {
          final Rect cell = row.chromeCells()[c];
          expect(cell.left, first.left, reason: 'column $c is not aligned');
          expect(cell.width, first.width, reason: 'column $c is not one width');
        }
      }
      // Cells tile: no gap, no overlap, and the table is exactly as wide as
      // its last cell is far.
      expect(header.first.left, 0);
      expect(header[1].left, header.first.width);
      expect(t.rows.first.chromeBounds().width, header.last.right);
      expect(
        t.rows.first.chromeBounds().width,
        lessThanOrEqualTo(679),
        reason: 'the row must not wrap',
      );
    });

    test('a cell knows the source characters it holds', () {
      final ({LineDocumentLayout layout, List<TableRowChrome> rows}) t =
          tableOf(doc);
      expect(
        t.rows.last.chromeCellSpans().first.toPlainText().trim(),
        '**加粗**',
        reason: 'the cell span covers everything between the pipes',
      );
    });

    test('a squeezed cell fits its column', () {
      // Three wide columns cannot fit 680px without shrinking.
      const String wide = '| 一列很长的文字内容 | 另一列也很长的文字内容 | 第三列照样长 |';
      final ({LineDocumentLayout layout, List<TableRowChrome> rows}) t =
          tableOf('$wide\n| --- | --- | --- |\n');
      for (final TableRowChrome row in t.rows) {
        for (final Rect cell in row.chromeCells()) {
          expect(cell.width, greaterThan(0));
        }
      }
      expect(t.rows.first.chromeBounds().width, lessThanOrEqualTo(679));
    });

    test('a caret in a cell leaves the table rendered', () {
      // Obsidian never turns a table back into `| 侧栏 | 全部笔记 |` because the
      // caret is inside it. 按行排版把整行交给自绘块：光标停在格子里时，
      // 每一行仍然是一个块，没有一行退回源码文本。
      final LiveTableBlocks blocks = LiveTableBlocks(
        base: base,
        palette: palette,
        text: () => doc,
        selection: () => const TextSelection.collapsed(offset: 2),
      );
      addTearDown(blocks.dispose);
      final LineDocumentLayout layout = layoutLines(
        text: doc,
        baseStyle: base,
        contentWidth: 680,
        blockFor: blocks.blockFor,
      );
      addTearDown(layout.dispose);
      final List<LaidOutLine> rows = layout.laidOut
          .where(
            (LaidOutLine l) =>
                l.source.kind == LineBlockKind.table ||
                l.source.kind == LineBlockKind.tableHeader,
          )
          .toList();
      expect(rows, hasLength(2));
      expect(
        rows.every((LaidOutLine l) => l.block != null),
        isTrue,
        reason: 'no row may fall back to its source',
      );
    });

    test('a selection across cells leaves the table rendered', () {
      final LiveTableBlocks blocks = LiveTableBlocks(
        base: base,
        palette: palette,
        text: () => doc,
        selection: () =>
            TextSelection(baseOffset: 2, extentOffset: doc.indexOf('加粗') + 2),
      );
      addTearDown(blocks.dispose);
      final LineDocumentLayout layout = layoutLines(
        text: doc,
        baseStyle: base,
        contentWidth: 680,
        blockFor: blocks.blockFor,
      );
      addTearDown(layout.dispose);
      final List<LaidOutLine> rows = layout.laidOut
          .where(
            (LaidOutLine l) =>
                l.source.kind == LineBlockKind.table ||
                l.source.kind == LineBlockKind.tableHeader,
          )
          .toList();
      expect(
        rows.where((LaidOutLine l) => l.block != null).length,
        2,
        reason: 'both rows stay rendered under a range',
      );
    });

    // ------------------------------------------------------- what copy takes
    //
    // A table is selected by the cell, so what leaves the table for the
    // clipboard is the **cells**, not the characters between them. Dragging
    // from `收藏` down to `展开` used to copy the pipes, the divider row and the
    // `| 侧栏 |` prefix of every row in between — user:
    // 「在表格里是选中格子，选中文字只能选中同一格的文字」.
    const String note =
        '| 区域 | 能做的事 |\n'
        '| --- | --- |\n'
        '| 笔记列表 | 搜索、置顶、收藏 |\n'
        '| 侧栏 | 按标签筛选 |\n'
        '| 编辑器 | 右侧展开大纲 |\n';

    int at(String needle) => note.indexOf(needle);

    test('a drag across one column copies that column as a table', () {
      final String? out = tableSelectionMarkdown(
        note,
        TextSelection(baseOffset: at('收藏'), extentOffset: at('展开') + 2),
      );
      // ⛔ No pipes of the *original* rows and no `| --- | --- |` divider from
      // the source: what comes out is a table of its own, whose header is the
      // first row the drag touched.
      expect(
        out,
        '| 搜索、置顶、收藏 |\n'
        '| --- |\n'
        '| 按标签筛选 |\n'
        '| 右侧展开大纲 |',
      );
    });

    test('a block of cells copies as a table with both columns', () {
      final String? both = tableSelectionMarkdown(
        note,
        TextSelection(baseOffset: at('笔记列表'), extentOffset: at('展开') + 2),
      );
      expect(
        both,
        '| 笔记列表 | 搜索、置顶、收藏 |\n'
        '| --- | --- |\n'
        '| 侧栏 | 按标签筛选 |\n'
        '| 编辑器 | 右侧展开大纲 |',
      );
    });

    test('a drag inside one cell is ordinary text selection', () {
      // ⛔ Not a cell selection: copying part of a cell has to copy exactly the
      // characters under the pointer, or selecting a word would grab the cell.
      expect(
        tableSelectionMarkdown(
          note,
          TextSelection(baseOffset: at('搜索'), extentOffset: at('搜索') + 2),
        ),
        isNull,
      );
    });

    test('a range that starts in prose or leaves the table is prose', () {
      const String withProse = '开场白，写一点东西。\n\n$note';
      expect(
        tableSelectionMarkdown(
          withProse,
          TextSelection(
            baseOffset: withProse.indexOf('写一点'),
            extentOffset: withProse.indexOf('收藏') + 2,
          ),
        ),
        isNull,
        reason: 'starts outside the table, so there is no block to hand back',
      );
      // The block's final newline belongs to the last row: a drag that ends
      // after it still covers the cells the wash shows. Anything past that is
      // prose.
      expect(
        tableSelectionMarkdown(
          note,
          TextSelection(baseOffset: at('收藏'), extentOffset: note.length),
        ),
        '| 搜索、置顶、收藏 |\n'
        '| --- |\n'
        '| 按标签筛选 |\n'
        '| 右侧展开大纲 |',
      );
      expect(
        tableSelectionMarkdown(
          '$note尾巴',
          TextSelection(baseOffset: at('收藏'), extentOffset: note.length + 2),
        ),
        isNull,
        reason: 'runs past the block, so it is no longer a block',
      );
      expect(
        tableSelectionMarkdown(note, const TextSelection.collapsed(offset: 4)),
        isNull,
        reason: 'a caret selects nothing',
      );
    });

    // ------------------------------------------------------ pasting a block
    //
    // Markdown has no end-of-table token, so a block pasted on the line under a
    // table used to become four more rows of it — user:
    // 「如果是在表格的下一行粘贴的话，会把两个表格连在一起」.
    const String block = '| 区域 |\n| --- |\n| 笔记列表 |';

    test('a table pasted under a table gets a blank line first', () {
      // The caret sits on the empty line right below the table — the case the
      // user hit: the pasted block would otherwise read as four more rows.
      final TextEditingValue v = pasteValue(
        const TextEditingValue(
          text: note,
          selection: TextSelection.collapsed(offset: note.length),
        ),
        block,
      );
      expect(v.text, '$note\n$block');
      expect(v.selection.baseOffset, v.text.length);
    });

    test('a table pasted on a fresh line needs no padding', () {
      final TextEditingValue v = pasteValue(
        const TextEditingValue(
          text: '正文\n\n',
          selection: TextSelection.collapsed(offset: 4),
        ),
        block,
      );
      expect(v.text, '正文\n\n$block');
    });

    test('a table pasted above a table gets a blank line after it', () {
      final TextEditingValue v = pasteValue(
        const TextEditingValue(
          text: note,
          selection: TextSelection.collapsed(offset: 0),
        ),
        block,
      );
      expect(v.text, '$block\n\n$note');
    });

    test('prose pasted under a table is left alone', () {
      final TextEditingValue v = pasteValue(
        const TextEditingValue(
          text: note,
          selection: TextSelection.collapsed(offset: note.length),
        ),
        '随便一句话',
      );
      expect(v.text, '$note随便一句话');
    });

    test('a table pasted into an empty row replaces the row', () {
      // The row `Enter` leaves behind at the end of a table. Pouring the block
      // into its first cell used to append the pasted header and every pasted
      // row as more rows of the table above — user:
      // 「我在输入光标这个位置粘贴…变成了这样，这是错误的」.
      const String withEmptyRow = '$note|  |  |  |';
      final TextEditingValue v = pasteValue(
        const TextEditingValue(
          text: withEmptyRow,
          selection: TextSelection.collapsed(offset: withEmptyRow.length - 2),
        ),
        block,
      );
      expect(v.text, '$note\n$block');
      expect(v.selection.baseOffset, v.text.length);
    });

    test('an empty row in the middle keeps a blank line on both sides', () {
      const String withEmptyRow = '$note|  |  |  |\n尾巴\n';
      final TextEditingValue v = pasteValue(
        const TextEditingValue(
          text: withEmptyRow,
          selection: TextSelection.collapsed(offset: note.length + 3),
        ),
        block,
      );
      expect(v.text, '$note\n$block\n\n尾巴\n');
    });

    test('a table pasted inside a filled cell moves below the table', () {
      // A cell is one line; pouring a multi-line table into it can only shear
      // the row. The pasted block becomes a table of its own under the host.
      final TextEditingValue v = pasteValue(
        TextEditingValue(
          text: note,
          selection: TextSelection.collapsed(offset: at('侧栏') + 1),
        ),
        block,
      );
      expect(v.text, '$note\n$block');
    });

    // ------------------------------------------------------- joining a table
    //
    // A copy of the same table pasted under it is how rows get duplicated, and
    // what comes out is **one** table: the copy's header cannot survive, because
    // markdown has exactly one header and a second would land as a data row —
    // user: 「还是两个表格啊？应该连在一起变成一个表格」.
    const String sheet =
        '| 功能 | 快捷键 | 写法 |\n'
        '| --- | --- | --- |\n'
        '| 加粗 | Ctrl + B | **文字** |\n'
        '| 斜体 | Ctrl + I | *文字* |\n';
    const String sheetCopy =
        '| 功能 | 快捷键 | 写法 |\n'
        '| --- | --- | --- |\n'
        '| 加粗 | Ctrl + B | **文字** |\n'
        '| 斜体 | Ctrl + I | *文字* |';
    const String sheetTail =
        '| 加粗 | Ctrl + B | **文字** |\n'
        '| 斜体 | Ctrl + I | *文字* |';

    test('a block of the same width joins the empty row it lands in', () {
      final TextEditingValue v = pasteValue(
        TextEditingValue(
          text: '$sheet|  |  |  |',
          selection: TextSelection.collapsed(offset: sheet.length + 4),
        ),
        sheetCopy,
      );
      expect(v.text, '$sheet$sheetTail');
      expect(
        RegExp(
          r'^\| --- \| --- \| --- \|$',
          multiLine: true,
        ).allMatches(v.text),
        hasLength(1),
        reason: '一张表只能有一条分隔行',
      );
      expect(v.selection.baseOffset, v.text.length);
    });

    test('a block pasted on the line under a table joins it', () {
      final TextEditingValue v = pasteValue(
        const TextEditingValue(
          text: sheet,
          selection: TextSelection.collapsed(offset: sheet.length),
        ),
        sheetCopy,
      );
      expect(v.text, '$sheet$sheetTail');
    });

    test('a narrower block stays a table of its own', () {
      // ⛔ Three columns cannot take a one-column row: joining would shear the
      // grid, so the block is kept apart instead.
      final TextEditingValue v = pasteValue(
        TextEditingValue(
          text: '$sheet|  |  |  |',
          selection: TextSelection.collapsed(offset: sheet.length + 4),
        ),
        block,
      );
      expect(v.text, '$sheet\n$block');
    });
  });
}
