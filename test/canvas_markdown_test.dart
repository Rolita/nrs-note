import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/core/theme/highlight_colors.dart';
import 'package:nrs/core/utils/canvas_document.dart' show canvasTextMaxWidth;
import 'package:nrs/ui/canvas/canvas_markdown.dart';
import 'package:nrs/ui/canvas/canvas_style.dart' show canvasTextFitSlack;
import 'package:nrs/ui/editor/code_block_painter.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart' show editorProseStyle;

const AppPalette palette = AppPalette.midnight;

CanvasMarkdownDocument docOf(
  String text, {
  double scale = 1,
  double maxWidth = canvasTextMaxWidth,
}) => CanvasMarkdownDocument.measure(
  text: text,
  scale: scale,
  maxWidth: maxWidth,
  palette: palette,
);

/// 有墨迹的行（零高的围栏/隐藏行不算）。
List<LaidOutLine> inkOf(CanvasMarkdownDocument doc) => <LaidOutLine>[
  for (final LaidOutLine line in doc.layout.laidOut)
    if (line.height > 0) line,
];

/// 把 span 树拍平成「一段文字 + 它最终拿到的样式」。
///
/// 直接断言 `TextSpan` 的树形结构太脆（换个嵌套方式就全红），而用户看到的
/// 是「这段字是什么样子」——所以按文字找样式，正是要验的那件事。
List<({String text, TextStyle style})> runsOf(InlineSpan root) {
  final List<({String text, TextStyle style})> out =
      <({String text, TextStyle style})>[];
  void walk(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) return;
    // `merge` 是「参数优先」：后套上去的样式盖掉前面的，和排版时的
    // `pushStyle` 一个顺序。
    final TextStyle style = span.style == null
        ? inherited
        : inherited.merge(span.style);
    final String? text = span.text;
    if (text != null && text.isNotEmpty) out.add((text: text, style: style));
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  walk(root, const TextStyle());
  return out;
}

/// 所有落墨行里的 span，按行拼起来再找 [text] 的样式。
TextStyle styleIn(CanvasMarkdownDocument doc, String text) {
  for (final LaidOutLine line in inkOf(doc)) {
    if (line.block != null) continue;
    for (final ({String text, TextStyle style}) run in runsOf(
      line.painter.text!,
    )) {
      if (run.text.trim() == text) return run.style;
    }
  }
  fail('排版结果里找不到「$text」');
}

void main() {
  group('与编辑器同一份排版', () {
    test('正文的基础样式就是编辑器画正文的那一份', () {
      final TextStyle style = styleIn(docOf('正文'), '正文');
      final TextStyle editor = editorProseStyle(palette, 15.5);
      expect(style.fontSize, editor.fontSize);
      expect(style.height, editor.height, reason: '行高要和编辑器逐像素一致');
      expect(style.letterSpacing, editor.letterSpacing);
      expect(style.fontFamily, AppFonts.prose);
    });

    test('标题阶梯同编辑器：H1 是 1.74 倍、H6 是 0.91 倍，半粗', () {
      double size(String markdown, String text) =>
          styleIn(docOf(markdown), text).fontSize!;

      final double h1 = size('# 一', '一');
      final double h2 = size('## 二', '二');
      final double h3 = size('### 三', '三');
      final double h6 = size('###### 六', '六');
      expect(h1, closeTo(15.5 * 1.74, 1e-6));
      expect(h6, closeTo(15.5 * 0.91, 1e-6));
      expect(h1, greaterThan(h2));
      expect(h2, greaterThan(h3));
      expect(h3, greaterThan(h6));
      expect(styleIn(docOf('# 一'), '一').fontWeight, FontWeight.w600);
    });

    test('标题的井号不进正文，行比正文高', () {
      final CanvasMarkdownDocument doc = docOf('# 标题');
      expect(doc.visibleText, '标题');
      expect(
        inkOf(doc).single.height,
        greaterThan(inkOf(docOf('标题')).single.height),
      );
    });

    test('分隔线画成一条线：不留减号，但占住一行', () {
      final CanvasMarkdownDocument doc = docOf('上\n---\n下');
      expect(doc.visibleText, '上\n\n下', reason: '减号被线代替了');
      final LaidOutLine rule = inkOf(doc)[1];
      expect(rule.source.kind, LineBlockKind.rule);
      expect(rule.height, greaterThan(0), reason: '线本身要有地方画');
    });

    test('有序列表：序号不进正文，槽位留给渲染层', () {
      final CanvasMarkdownDocument doc = docOf('1. 第一步');
      final LaidOutLine line = inkOf(doc).single;
      expect(doc.visibleText, '第一步');
      expect(line.source.kind, LineBlockKind.ordered);
      expect(
        line.gutter,
        greaterThan(line.insets.left),
        reason: '序号占的是正文列左边的槽位',
      );
      expect(doc.markers.number.fontWeight, FontWeight.w600);
    });

    test('无序列表与任务项：标记同样由槽位承担', () {
      expect(docOf('- 第一条').visibleText, '第一条');
      expect(inkOf(docOf('- 第一条')).single.source.kind, LineBlockKind.bullet);
      expect(docOf('- [ ] 没做').visibleText, '没做');
      expect(inkOf(docOf('- [ ] 没做')).single.source.kind, LineBlockKind.task);
    });

    test('引用：尖括号被压掉，字色降一档，左边留出竖线的位置', () {
      final CanvasMarkdownDocument doc = docOf('> 一句引用');
      expect(doc.visibleText, '一句引用');
      expect(styleIn(doc, '一句引用').color, palette.textSecondary);
      expect(inkOf(doc).single.insets.left, greaterThan(0));
    });

    test('围栏代码：围栏行隐去，代码行等宽，底片留出下沿', () {
      const String text = '```dart\nfinal int a = 1;\n```';
      final CanvasMarkdownDocument doc = docOf(text);
      expect(doc.visibleText, 'final int a = 1;');
      expect(doc.codeRanges.single.label, 'Dart', reason: '语言标签按编辑器规则归一');
      final CodeBlockRange range = doc.codeRanges.single;
      final Rect? rows = doc.layout.blockRect(range.start, range.end);
      expect(rows, isNotNull);
      // 代码行按 token 着色，span 被拆成好几段，所以样式按整行根节点读。
      final LaidOutLine codeLine = inkOf(doc).last;
      expect(codeLine.source.kind, LineBlockKind.code);
      expect(codeLine.painter.text!.style!.fontFamily, AppFonts.mono);
      expect(
        codeLine.painter.text!.style!.fontSize,
        closeTo(15.5 * 0.84, 1e-6),
      );
      expect(
        doc.height,
        closeTo((rows!.bottom + kCodeSlabBottomPad) * doc.renderScale, 0.01),
        reason: '末块代码的圆角底片不能被卡片下沿裁掉',
      );
    });

    test('表格行改成自绘：没有原始竖线，格子由块行承担', () {
      const String text = '| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |';
      final CanvasMarkdownDocument doc = docOf(text);
      expect(
        doc.layout.laidOut.any((LaidOutLine line) => line.block != null),
        isTrue,
      );
      expect(doc.visibleText, '', reason: '表格的文字由自绘行负责，不在按行文字里');
      expect(doc.width, greaterThan(0));
      expect(doc.height, greaterThan(0));
    });

    test('整篇画一遍不崩：标题、列表、高亮、代码、表格、引用都能落到画布上', () {
      final CanvasMarkdownDocument doc = docOf(
        '# 标题\n\n正文 ==高亮== 和 `代码`\n\n- 列表\n1. 序号\n- [x] 完成\n\n'
        '> 引用\n\n---\n\n```dart\nfinal a = 1;\n```\n\n'
        '| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |',
      );
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, 600, 600),
      );
      doc.paint(canvas, const Offset(10, 10));
      recorder.endRecording().dispose();
      expect(doc.height, greaterThan(0));
    });
  });

  group('行内底片与字色', () {
    test('行内代码：反引号不见，铺一块圆角底片', () {
      final CanvasMarkdownDocument doc = docOf('跑 `flutter test` 就行');
      expect(doc.visibleText, '跑 flutter test 就行');
      final LineFillRun run = inkOf(doc).single.fills.single;
      expect(run.fill, palette.surfaceSunken);
      expect(run.radius, 3);
      expect(run.rowBox, isFalse);
      expect(styleIn(doc, 'flutter test').fontFamily, AppFonts.mono);
    });

    test('高亮：底片按视觉行铺满、字压深', () {
      final CanvasMarkdownDocument doc = docOf('==高亮==');
      expect(doc.visibleText, '高亮');
      final LineFillRun run = inkOf(doc).single.fills.single;
      expect(run.fill, HighlightColors.darkFill);
      expect(run.radius, kHighlightRadius);
      expect(run.padX, kHighlightPadX);
      expect(run.rowBox, isTrue, reason: '高亮铺的是整条视觉行，不是字形盒');
      expect(styleIn(doc, '高亮').color, HighlightColors.darkInk);
    });

    test('标签：井号留着，字缩进胶囊、铺强调底', () {
      final CanvasMarkdownDocument doc = docOf('这条属于 #项目 ');
      expect(doc.visibleText, '这条属于 #项目 ');
      final LineFillRun run = inkOf(doc).single.fills.single;
      expect(run.fill, palette.accentSoft);
      expect(run.radius, kTagRadius);
      expect(run.padX, kTagPadX);
      expect(run.padY, kTagPadY);
      expect(styleIn(doc, '#项目').fontWeight, FontWeight.w600);
    });

    test('粗体、删除线、链接：和编辑器同一套字面', () {
      final TextStyle bold = styleIn(docOf('前 **重点** 后'), '重点');
      expect(bold.fontWeight, FontWeight.w700);

      final TextStyle struck = styleIn(docOf('~~作废~~'), '作废');
      expect(struck.decoration, TextDecoration.lineThrough);
      expect(struck.decorationThickness, 2);

      final TextStyle link = styleIn(
        docOf('见 [文档](https://example.com) 一节'),
        '文档',
      );
      expect(link.color, palette.accent);
      expect(link.decoration, TextDecoration.underline);
      expect(
        link.decorationStyle ?? TextDecorationStyle.solid,
        TextDecorationStyle.solid,
      );

      // 按行排版拿的是 `wikilinkTarget` 的原样内部文本（含别名那一段），
      // 卡片照抄这一份——和编辑器里看到的一样。
      final TextStyle wiki = styleIn(docOf('看 [[目标|别名]] 那篇'), '目标|别名');
      expect(wiki.color, palette.accent);
      expect(wiki.decorationStyle, TextDecorationStyle.dotted);
    });
  });

  group('贴合尺寸', () {
    test('短句按内容收窄，长句顶到折行上限', () {
      expect(docOf('短句', maxWidth: 200).width, lessThan(200));
      final CanvasMarkdownDocument long = docOf('很长' * 200, maxWidth: 120);
      expect(long.width, closeTo(120, 0.01));
    });

    test('只有一条分隔线时占满上限：线不能缩成一个点', () {
      expect(docOf('---', maxWidth: 100).width, closeTo(100, 0.01));
    });

    test('倍率翻倍，宽高一起翻倍（整张纸缩放，不是只放大字）', () {
      final CanvasMarkdownDocument one = docOf('一行字');
      final CanvasMarkdownDocument two = docOf('一行字', scale: 2);
      // 那 1px 的贴合余量是**世界坐标**的固定值，不随倍率放大，所以这里留
      // 出它的容差。
      expect(two.width, closeTo(one.width * 2, canvasTextFitSlack + 0.01));
      expect(two.height, closeTo(one.height * 2, 0.01));
    });
  });

  group('缓存', () {
    CanvasMarkdownCache cache() => CanvasMarkdownCache();

    test('贴合后的终稿就是画笔拿到的同一份', () {
      final CanvasMarkdownCache c = cache();
      final ({double width, double height}) fit = c.fit(
        'node-a',
        text: '标题\n正文',
        scale: 1,
        maxWidth: 300,
        palette: palette,
      );
      final CanvasMarkdownDocument first = c.get(
        'node-a',
        text: '标题\n正文',
        scale: 1,
        width: fit.width,
        palette: palette,
      );
      expect(first.width, closeTo(fit.width, 0.5), reason: '没有重排一遍');
      expect(first.height, closeTo(fit.height, 0.5));
      expect(
        identical(
          first,
          c.get(
            'node-a',
            text: '标题\n正文',
            scale: 1,
            width: fit.width,
            palette: palette,
          ),
        ),
        isTrue,
      );
      c.dispose();
    });

    test('文字变了：旧排版不再冒充新文字，重贴后换一份', () {
      final CanvasMarkdownCache c = cache();
      c.fit('k', text: '旧的', scale: 1, maxWidth: 300, palette: palette);
      expect(c.visibleText('k', '旧的'), '旧的');
      expect(c.visibleText('k', '新的'), isNull);
      c.fit('k', text: '新的', scale: 1, maxWidth: 300, palette: palette);
      expect(c.visibleText('k', '新的'), '新的');
      c.dispose();
    });
  });
}
