import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/core/utils/markdown_actions.dart';
import 'package:nrs/core/utils/markdown_outline.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/live_line_style.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/preview/code_palette.dart';

/// A document that exercises every block kind and every inline marker the
/// renderer knows. The only thing a `part` split must never change is the
/// **shape** of the tree this produces, so the assertions here are about
/// structure, not pixels.
const String document = r'''# 标题一

正文 **粗体** *斜体* ~~删除~~ ==高亮== `代码` $公式$ %%注释%% [[双链]] ![[嵌入]] [链接](https://example.com) ![图](x.png) #标签

> 引用一行

- 项目一
  - 子项目
- [ ] 待办
- [x] 完成

---

```dart
void main() {}
```

| h1 | h2 |
| --- | ---: |
| a | 1 |
| b | 2 |
''';

void main() {
  const AppPalette palette = AppPalette.midnight;
  const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
  const TextSelection idleSelection = TextSelection.collapsed(offset: -1);

  /// 跑一次生产路径的按行排版；调用方自己释放（扫描大量光标时用）。
  ({LineDocumentLayout layout, LiveTableBlocks blocks}) buildLayout(
    String text, {
    TextSelection selection = idleSelection,
  }) {
    final LiveLineStyle style = LiveLineStyle(
      base: base,
      palette: palette,
      reveal: () => selection,
      source: text,
    );
    final LiveTableBlocks blocks = LiveTableBlocks(
      base: base,
      palette: palette,
      text: () => text,
      selection: () => selection,
    );
    final LineDocumentLayout layout = layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: 680,
      styleFor: style.styleFor,
      heightFor: style.heightFor,
      spanFor: style.spanFor,
      fillFor: style.fillsFor,
      insetFor: style.insetFor,
      blockFor: blocks.blockFor,
    );
    return (layout: layout, blocks: blocks);
  }

  /// 跑一次生产路径的按行排版，并在用例结束时释放。
  LineDocumentLayout layoutOf(
    String text, {
    TextSelection selection = idleSelection,
  }) {
    final ({LineDocumentLayout layout, LiveTableBlocks blocks}) built =
        buildLayout(text, selection: selection);
    addTearDown(built.layout.dispose);
    addTearDown(built.blocks.dispose);
    return built.layout;
  }

  /// 取一棵 span 树里文本为 [text] 的节点。
  TextSpan? spanWith(InlineSpan root, String text) {
    if (root is TextSpan) {
      if (root.text == text) return root;
      for (final InlineSpan child in root.children ?? const <InlineSpan>[]) {
        final TextSpan? found = spanWith(child, text);
        if (found != null) return found;
      }
    }
    return null;
  }

  test('every line paints exactly its own source slice', () {
    final LineDocumentLayout layout = layoutOf(document);
    for (final LaidOutLine line in layout.laidOut) {
      if (line.block != null) continue; // 表格行由自绘内容承担文字
      expect(
        line.painter.plainText,
        layout.text.substring(line.paintedFrom, line.source.end),
        reason: '第 ${line.source.index} 行的排版文字被改写',
      );
    }
  });

  test('task, rule and nested bullet keep their structural markers', () {
    final LineDocumentLayout layout = layoutOf(document);
    final List<LaidOutLine> laidOut = layout.laidOut;

    expect(
      laidOut.where((LaidOutLine l) => l.source.kind == LineBlockKind.task),
      hasLength(2),
    );
    expect(
      laidOut.where((LaidOutLine l) => l.source.kind == LineBlockKind.rule),
      hasLength(1),
    );
    // 一个二级项目：缩进与导轨仍由标记槽位承担。
    expect(laidOut.where((LaidOutLine l) => l.slot.level == 1), hasLength(1));
  });

  test('heading, code and table keep their key styles', () {
    final LineDocumentLayout layout = layoutOf(document);

    final LaidOutLine heading = layout.laidOut.firstWhere(
      (LaidOutLine l) => l.source.kind == LineBlockKind.heading,
    );
    final TextStyle headingStyle = heading.painter.text!.style!;
    expect(headingStyle.fontWeight, FontWeight.w600);
    expect(headingStyle.fontSize!, greaterThan(base.fontSize!));

    final LaidOutLine code = layout.laidOut.firstWhere(
      (LaidOutLine l) => l.source.kind == LineBlockKind.code,
    );
    expect(code.painter.text!.style!.fontFamily, AppFonts.mono);

    // 表格不在段落里排版：整行由 `LiveTableBlocks` 自绘，所以这里断言
    // 同一块被切成「表头 + 两行正文」，且首行仍认作表头。
    final List<LaidOutLine> tableLines = layout.laidOut
        .where((LaidOutLine l) => l.block != null)
        .toList();
    expect(tableLines, hasLength(3));
    expect(tableLines.first.source.kind, LineBlockKind.tableHeader);
    expect(tableLines[1].source.kind, LineBlockKind.table);
  });

  // ------------------------------------------------------------ 行为断言
  //
  // 这些用例原先断言的是段落渲染器 `buildLiveSpans` 的 widget 树（WidgetSpan
  // 的 child、`sourceOffset`）。按行排版没有 widget，等价物是每行的
  // `TextPainter`、`MarkerSlot`、`LineFillRun` 与 `LiveLineStyle`，所以这里
  // 沿着生产路径重写同一批行为。

  group('按行渲染的行为', () {
    test('光标扫过每个字符时不丢也不改一个字符', () {
      for (int caret = -1; caret <= document.length; caret++) {
        final TextSelection sel = caret < 0
            ? idleSelection
            : TextSelection.collapsed(offset: caret);
        final ({LineDocumentLayout layout, LiveTableBlocks blocks}) built =
            buildLayout(document, selection: sel);
        try {
          expect(built.layout.text, document);
          for (final LaidOutLine line in built.layout.laidOut) {
            if (line.block != null) continue;
            expect(
              line.painter.plainText,
              document.substring(line.paintedFrom, line.source.end),
              reason: 'caret=$caret 第 ${line.source.index} 行',
            );
          }
        } finally {
          built.layout.dispose();
          built.blocks.dispose();
        }
      }
    });

    test('首次运行写下的欢迎笔记排版不抛异常', () {
      final String welcome = Note.fromMarkdown(
        Note.welcome().toMarkdown(),
        '欢迎使用 NRS-k15and.md',
        DateTime(2026),
      ).body;
      expect(welcome.startsWith('\n'), isFalse);

      for (int caret = -1; caret <= welcome.length; caret++) {
        final TextSelection sel = caret < 0
            ? idleSelection
            : TextSelection.collapsed(offset: caret);
        final ({LineDocumentLayout layout, LiveTableBlocks blocks}) built =
            buildLayout(welcome, selection: sel);
        try {
          for (final LaidOutLine line in built.layout.laidOut) {
            if (line.block != null) continue;
            expect(
              line.painter.plainText,
              welcome.substring(line.paintedFrom, line.source.end),
              reason: 'welcome caret=$caret 第 ${line.source.index} 行',
            );
          }
        } finally {
          built.layout.dispose();
          built.blocks.dispose();
        }
        // 工具条每一帧都问同一个问题；offset 0 曾经会抛异常。
        expect(
          () => markerAt(
            TextEditingValue(
              text: welcome,
              selection: TextSelection.collapsed(offset: caret < 0 ? 0 : caret),
            ),
          ),
          returnsNormally,
          reason: 'markerAt caret=$caret',
        );
      }
    });

    test('标题缩放，正文保持字号，隐藏的 # 只在光标行显形', () {
      const String text = '# 大标题\n\n正文';
      final List<SourceLine> lines = scanSourceLines(text);
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );
      final TextStyle heading = style.styleFor(lines[0]);
      expect(heading.fontSize!, greaterThan(base.fontSize!));
      expect(heading.fontWeight, FontWeight.w600);
      expect(style.styleFor(lines[2]).fontSize, base.fontSize);

      // 光标不在标题行：`# ` 压成零号，看不见但仍占着偏移。
      final TextSpan idle = spanWith(style.spanFor(lines[0]), '# ')!;
      expect(idle.style!.fontSize, 0);

      // 光标落到标题行：`# ` 重新可读，并跟着标题一起放大。
      final LiveLineStyle onLine = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
        reveal: () => const TextSelection.collapsed(offset: 0),
      );
      final TextSpan shown = spanWith(onLine.spanFor(lines[0]), '# ')!;
      expect(shown.style!.fontSize!, greaterThanOrEqualTo(base.fontSize!));
    });

    test('围栏折叠成卡片头，代码行保留高亮', () {
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: document,
      );
      final List<SourceLine> lines = scanSourceLines(document);
      final SourceLine fence = lines.firstWhere(
        (SourceLine l) => l.kind == LineBlockKind.fence,
      );
      expect(style.styleFor(fence).fontSize, 0);

      final SourceLine code = lines.firstWhere(
        (SourceLine l) => l.kind == LineBlockKind.code,
      );
      final TextSpan span = style.spanFor(code) as TextSpan;
      expect(span.style!.backgroundColor, isNull);
      expect(span.style!.fontFamily, AppFonts.mono);
      expect(
        span.children!.whereType<TextSpan>().any(
          (TextSpan t) => t.style?.color == CodePalette.dark.keyword,
        ),
        isTrue,
        reason: '`void` 应按关键字着色',
      );

      final List<CodeBlockRange> ranges = codeBlockRanges(document);
      expect(ranges, hasLength(1));
      expect(ranges.single.label, 'Dart');
      expect(
        document.substring(ranges.single.start, ranges.single.end),
        '```dart\nvoid main() {}\n```',
      );
    });

    test('没有语言的围栏不标语言名', () {
      final List<CodeBlockRange> ranges = codeBlockRanges('```\nplain\n```');
      expect(ranges, hasLength(1));
      expect(ranges.single.label, isNull);
    });

    test('破折号行是分隔线，等号行才把上一段升级成标题', () {
      final List<SourceLine> dashes = scanSourceLines('标题\n---\n正文');
      expect(dashes.map((SourceLine l) => l.kind), <LineBlockKind>[
        LineBlockKind.paragraph,
        LineBlockKind.rule,
        LineBlockKind.paragraph,
      ]);
      final LiveLineStyle dashStyle = LiveLineStyle(
        base: base,
        palette: palette,
        source: '标题\n---\n正文',
      );
      expect(dashStyle.styleFor(dashes[0]).fontSize, base.fontSize);

      final List<SourceLine> equals = scanSourceLines('大标题\n===');
      expect(equals.map((SourceLine l) => l.kind), <LineBlockKind>[
        LineBlockKind.heading,
        LineBlockKind.setext,
      ]);
      final LiveLineStyle eqStyle = LiveLineStyle(
        base: base,
        palette: palette,
        source: '大标题\n===',
      );
      expect(
        eqStyle.styleFor(equals[0]).fontSize!,
        greaterThan(base.fontSize!),
      );
    });

    test('任务复选框留在标记槽位里，正文从它后面起排', () {
      const String tasks = '- [x] 已完成\n- [ ] 待办\n';
      final LineDocumentLayout layout = layoutOf(tasks);
      // 扫描器在末尾换行后补一个空行，这里只看两条列表。
      final List<LaidOutLine> lines = layout.laidOut.take(2).toList();
      expect(lines.map((LaidOutLine l) => l.source.kind), <LineBlockKind>[
        LineBlockKind.task,
        LineBlockKind.task,
      ]);
      for (final LaidOutLine line in lines) {
        expect(line.slot.marker, greaterThan(0));
        // 复选框是槽位的一部分：正文从 `[x] ` 之后开始。
        expect(line.paintedFrom, line.source.markerEnd);
      }
      // 第二行复选框的点击偏移就是 `- [ ]` 里的 `[`（文档偏移）。
      expect(lines[1].source.markerStart, tasks.indexOf('- [ ]'));
    });

    test('有序任务的序号留在槽位里，编号与复选框分开测量', () {
      const String text = '1. [ ] 一件事\n2. [x] 另一件\n';
      final LineDocumentLayout layout = layoutOf(text);
      final List<LaidOutLine> lines = layout.laidOut.take(2).toList();
      expect(lines.map((LaidOutLine l) => l.source.number), <int?>[1, 2]);
      for (final LaidOutLine line in lines) {
        expect(line.slot.digitWidth, greaterThan(0));
        expect(line.slot.marker, greaterThan(line.slot.digitWidth));
        expect(line.paintedFrom, line.source.markerEnd);
      }
      // 序号仍是可编辑的源码：点击复选框按偏移翻转这一行。
      expect(toggleTaskAt(text, text.indexOf('[')), '1. [x] 一件事\n2. [x] 另一件\n');
    });

    test('勾掉的任务整体划掉，未勾的保持原样', () {
      const String text = '1. [x] 一件事\n2. [ ] 另一件\n';
      final List<SourceLine> lines = scanSourceLines(text);
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );
      final TextStyle done = style.styleFor(lines[0]);
      expect(done.decoration, TextDecoration.lineThrough);
      expect(done.decorationThickness, 2);
      expect(done.color, palette.textSecondary);
      expect(done.decorationColor, done.color);
      expect(
        style.styleFor(lines[1]).decoration,
        isNot(TextDecoration.lineThrough),
      );
      // 槽位里的序号是强调色半粗；勾选时渲染层在它上面再叠删除线。
      expect(style.markers.number.color, palette.accent);
      expect(style.markers.number.fontWeight, FontWeight.w600);

      // 行内 `~~删除~~` 用同一套删除线：线是文字自己的颜色。
      const String inline = '这是 ~~删掉~~ 的字\n';
      final LiveLineStyle tinted = LiveLineStyle(
        base: base.copyWith(color: palette.textPrimary),
        palette: palette,
        source: inline,
      );
      final TextSpan gone = spanWith(
        tinted.spanFor(scanSourceLines(inline).first),
        '删掉',
      )!;
      expect(gone.style!.decoration, TextDecoration.lineThrough);
      expect(gone.style!.decorationThickness, 2);
      expect(gone.style!.decorationColor, palette.textPrimary);
    });

    test('列表标记始终画在槽位里，不跟着光标变成源码', () {
      const String text = '- 一项\n- [ ] 待办';
      for (final int caret in <int>[0, 2, 6]) {
        final LineDocumentLayout layout = layoutOf(
          text,
          selection: TextSelection.collapsed(offset: caret),
        );
        for (final LaidOutLine line in layout.laidOut) {
          expect(line.slot.width, greaterThan(0), reason: 'caret=$caret');
          expect(line.paintedFrom, line.source.markerEnd);
        }
      }
    });

    test('每层嵌套一个固定步长，并为每个祖先画一根导轨', () {
      const String text = '- 一\n  - 二\n    - 三\n';
      final LineDocumentLayout layout = layoutOf(text);
      final List<LaidOutLine> nested = layout.laidOut.take(3).toList();
      expect(nested.map((LaidOutLine l) => l.slot.level), <int>[0, 1, 2]);
      expect(nested.map((LaidOutLine l) => l.slot.indent), <double>[0, 26, 52]);
      expect(
        nested.map((LaidOutLine l) => l.slot.railXs.length),
        <int>[1, 2, 2],
        reason: '每级列表都有自己的导轨，二层给两级、三层给两级',
      );
    });

    test('标签派生底片，光标进入后露出源码', () {
      const String text = '想法 #写作 与 #灵感\n';
      final SourceLine line = scanSourceLines(text).first;
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );
      final List<LineFillRun> runs = style.fillsFor(line);
      expect(runs, hasLength(2));
      expect(text.substring(runs[0].from, runs[0].to), '#写作');
      expect(text.substring(runs[1].from, runs[1].to), '#灵感');
      expect(runs[0].fill, palette.accentSoft);

      // 光标落在第一个标签里：它退回源码，没有底片；另一个仍是胶囊。
      final LiveLineStyle editing = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
        reveal: () => TextSelection.collapsed(offset: text.indexOf('#写作') + 1),
      );
      final List<LineFillRun> remaining = editing.fillsFor(line);
      expect(remaining, hasLength(1));
      expect(text.substring(remaining.single.from, remaining.single.to), '#灵感');

      // `issue#12` 与 `#1` 不是标签。
      const String issues = '修复 issue#12 与 #1 的问题\n';
      final LiveLineStyle issueStyle = LiveLineStyle(
        base: base,
        palette: palette,
        source: issues,
      );
      expect(issueStyle.fillsFor(scanSourceLines(issues).first), isEmpty);
    });

    test('双链只留目标文字，方括号折叠但偏移不丢', () {
      const String text = '看 [[笔记一]] 和 ![[附件]]\n';
      final SourceLine line = scanSourceLines(text).first;
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );
      final TextSpan tree = style.spanFor(line) as TextSpan;
      final TextSpan label = spanWith(tree, '笔记一')!;
      expect(label.style!.color, palette.accent);
      expect(label.style!.decoration, TextDecoration.underline);
      expect(spanWith(tree, '[[')!.style!.fontSize, 0, reason: '未进入编辑时方括号压成零宽');
      expect(tree.toPlainText(), line.text, reason: '压宽不能丢字符');

      final List<({int start, int end, String target})> links = style
          .wikilinksFor(line);
      expect(links.map((l) => l.target), <String>['笔记一', '附件']);
      expect(text.substring(links[0].start, links[0].end), '[[笔记一]]');
      expect(text.substring(links[1].start, links[1].end), '![[附件]]');

      // 光标落进第一个链接：整段源码显形，和别的行内标记同一规则。
      final LiveLineStyle editing = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
        reveal: () => TextSelection.collapsed(offset: text.indexOf('笔记一')),
      );
      expect(
        spanWith(editing.spanFor(line), '[[笔记一]]'),
        isNotNull,
        reason: '编辑态应露出双链源码',
      );
    });

    test('代码里的方括号不是双链', () {
      const String text = '`[[不是]]` 与 [[是]]\n';
      final SourceLine line = scanSourceLines(text).first;
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );
      final List<({int start, int end, String target})> links = style
          .wikilinksFor(line);
      expect(links, hasLength(1));
      expect(links.single.target, '是');
      expect(text.substring(links.single.start, links.single.end), '[[是]]');
    });

    test('行内链接取到能交给浏览器的地址，代码与相对路径都不算', () {
      const String text =
          '看 [站点](https://example.com/a) 与 [短](www.example.org) '
          '和 `[代码](https://code.dev)` 与 [本地](./note.md)\n';
      final SourceLine line = scanSourceLines(text).first;
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );

      final List<({int start, int end, String url})> links = style.linksFor(
        line,
      );
      expect(links.map((l) => l.url), <String>[
        'https://example.com/a',
        'https://www.example.org',
      ]);
      expect(
        text.substring(links[0].start, links[0].end),
        '[站点](https://example.com/a)',
      );
      expect(
        text.substring(links[1].start, links[1].end),
        '[短](www.example.org)',
      );
    });

    test('编辑态的链接保持链接配色，只有括号退回标记色', () {
      const String source = '[必应](https://bing.com)';
      final InlineSpan tree = buildLiveInlineSpan(
        source,
        base: base,
        p: palette,
        caretA: 0,
        caretB: 0,
      );
      final List<TextSpan> runs = <TextSpan>[];
      tree.visitChildren((InlineSpan span) {
        if (span is TextSpan && span.text != null) runs.add(span);
        return true;
      });
      Color? colourOf(String text) =>
          runs.firstWhere((TextSpan run) => run.text == text).style?.color;

      expect(
        runs.map((TextSpan run) => run.text).join(),
        source,
        reason: '拆成几段也好，拼起来必须逐字符等于源码',
      );
      expect(colourOf('必应'), palette.accent, reason: '标签保持链接色');
      expect(
        colourOf('https://bing.com'),
        palette.accent,
        reason: '地址也保持链接色，不能一进编辑就掉成源码灰',
      );
      expect(
        colourOf(']('),
        isNot(palette.accent),
        reason: '方括号与圆括号是标记，退回标记色',
      );
    });

    test('引用的竖线恰好占住它藏起来的标记宽度', () {
      const String text = '> 引用\n';
      final SourceLine line = scanSourceLines(text).first;
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );
      final TextSpan tree = style.spanFor(line) as TextSpan;
      final TextSpan prefix = spanWith(tree, '> ')!;
      expect(prefix.style!.color!.a, 0, reason: '未揭示时前缀不落墨');

      double widthOf(TextStyle style) {
        final TextPainter tp = TextPainter(
          text: TextSpan(text: '> ', style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final double width = tp.width;
        tp.dispose();
        return width;
      }

      // 前缀压成零宽后，它原来的宽度由左内边距顶着：竖线画在这段空位里，
      // 软换行的续行也从这一列起排，不会退回竖线上。
      expect(
        style.insetFor(line).left,
        closeTo(widthOf(base), 0.001),
        reason: '未揭示时前缀宽度由内边距顶上',
      );

      // 光标落进这一行时前缀恢复占宽、内边距收回，正文起点仍是同一列。
      final LiveLineStyle revealed = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
        reveal: () => const TextSelection.collapsed(offset: 2),
      );
      expect(revealed.insetFor(line), EdgeInsets.zero);
      expect(
        spanWith(revealed.spanFor(line) as TextSpan, '> ')!.style!.color!.a,
        greaterThan(0),
      );
    });

    test('行内代码是一颗带底片的胶囊，编辑时退回源码', () {
      const String text = 'a `x = 1` b';
      final SourceLine line = scanSourceLines(text).first;
      final LiveLineStyle style = LiveLineStyle(
        base: base,
        palette: palette,
        source: text,
      );
      final List<LineFillRun> runs = style.fillsFor(line);
      expect(runs, hasLength(1));
      expect(text.substring(runs.single.from, runs.single.to), '`x = 1`');
      expect(runs.single.fill, palette.surfaceSunken);

      final TextSpan tree = style.spanFor(line) as TextSpan;
      final TextSpan run = spanWith(tree, 'x = 1')!;
      expect(run.style!.fontFamily, AppFonts.mono);
      expect(run.style!.fontSize!, lessThan(base.fontSize!));
      expect(run.style!.color, palette.textPrimary);
      // 底片由渲染层铺，span 自己不带背景，否则只会得到贴字的直角矩形。
      expect(run.style!.backgroundColor, isNull);

      // 光标落在代码里 / 整段被选中：胶囊撤掉，露出反引号。
      for (final TextSelection sel in <TextSelection>[
        const TextSelection.collapsed(offset: 5),
        const TextSelection(baseOffset: 0, extentOffset: text.length),
      ]) {
        final LiveLineStyle editing = LiveLineStyle(
          base: base,
          palette: palette,
          source: text,
          reveal: () => sel,
        );
        expect(editing.fillsFor(line), isEmpty);
        expect(
          (editing.spanFor(line) as TextSpan).toPlainText(),
          text,
          reason: '编辑态仍逐字符等于源码',
        );
      }
    });
  });
}
