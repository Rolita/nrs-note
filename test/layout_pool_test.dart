import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_pool.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// P5a：跨笔记复用布局。
///
/// 池的单元测试只看所有权与 LRU；渲染层接线用真实 `MarkdownEditor` 模拟切笔记
/// ——换 `documentId` 会把输入框整块重建，正是生产路径。
const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
const double width = 680;

LineDocumentLayout layoutOf(String text, {LineLayoutCache? cache}) =>
    layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: width,
      cache: cache,
    );

String documentOf(int lines) =>
    List<String>.generate(lines, (int i) => '第 $i 行正文').join('\n');

void main() {
  group('LineLayoutPool 所有权与容量', () {
    test('挂起后取回同一份布局，取走即不再归池所有', () {
      final LineLayoutPool pool = LineLayoutPool();
      final LineLayoutCache cache = LineLayoutCache();
      final LineDocumentLayout layout = layoutOf('甲\n乙\n丙', cache: cache);
      final LineLayoutPoolKey key = (
        document: 'a',
        body: '甲\n乙\n丙',
        width: width,
        textScaler: TextScaler.noScaling,
        style: base,
        folds: '',
        markerRevealLine: null,
      );

      pool.park(key, layout, cache, TextSelection.collapsed(offset: 1));
      expect(pool.length, 1);

      final ParkedLineLayout? taken = pool.take(key);
      expect(taken, isNotNull);
      expect(identical(taken!.layout, layout), isTrue);
      expect(identical(taken.cache, cache), isTrue);
      expect(taken.reveal, const TextSelection.collapsed(offset: 1));
      expect(pool.length, 0);
      expect(pool.take(key), isNull);

      // 已经取走的份归调用方：池再清空时不能释放它。
      pool.clear();
      expect(layout.disposed, isFalse);
      layout.dispose();
      cache.dispose();
    });

    test('超过容量时释放最久未用的那份', () {
      final LineLayoutPool pool = LineLayoutPool(capacity: 2);
      LineLayoutPoolKey keyOf(String doc) => (
        document: doc,
        body: '正文',
        width: width,
        textScaler: TextScaler.noScaling,
        style: base,
        folds: '',
        markerRevealLine: null,
      );

      final List<LineDocumentLayout> layouts = <LineDocumentLayout>[
        layoutOf('正文'),
        layoutOf('正文'),
        layoutOf('正文'),
      ];
      final List<LineLayoutCache> caches = List<LineLayoutCache>.generate(
        3,
        (_) => LineLayoutCache(),
      );
      for (int i = 0; i < 3; i++) {
        pool.park(keyOf('$i'), layouts[i], caches[i], null);
      }

      expect(pool.length, 2);
      expect(pool.debugEvictions, 1);
      expect(layouts[0].disposed, isTrue, reason: '最久未用的那份应被释放');
      expect(layouts[1].disposed, isFalse);
      expect(layouts[2].disposed, isFalse);

      pool.clear();
      expect(layouts[1].disposed, isTrue);
      expect(layouts[2].disposed, isTrue);
    });

    test('同键重复挂起会先释放旧份', () {
      final LineLayoutPool pool = LineLayoutPool();
      final LineLayoutPoolKey key = (
        document: 'a',
        body: '正文',
        width: width,
        textScaler: TextScaler.noScaling,
        style: base,
        folds: '',
        markerRevealLine: null,
      );
      final LineDocumentLayout first = layoutOf('正文');
      final LineDocumentLayout second = layoutOf('正文');
      final LineLayoutCache cacheA = LineLayoutCache();
      final LineLayoutCache cacheB = LineLayoutCache();
      pool.park(key, first, cacheA, null);
      pool.park(key, second, cacheB, null);

      expect(pool.length, 1);
      expect(first.disposed, isTrue);
      expect(second.disposed, isFalse);
      pool.dispose();
      expect(second.disposed, isTrue);
    });
  });

  group('跨笔记复用接线', () {
    late ThemeData theme;
    late FocusNode focus;
    late ScrollController scroll;
    late MarkdownSourceController a;
    late MarkdownSourceController b;

    setUp(() {
      // 同一份 `ThemeData` 跨 pump 复用，换笔记时只有 `documentId` 变；
      // 换一份新的 `ThemeData` 会重放主题过渡，过渡期间 `context.palette`
      // 是 lerp 出来的新实例，编辑器会误判样式变了而清空布局池。
      theme = AppTheme.build(AppPalette.midnight);
      focus = FocusNode();
      scroll = ScrollController();
      a = MarkdownSourceController(text: documentOf(40));
      b = MarkdownSourceController(text: '另一篇笔记\n只有两行');
    });

    tearDown(() {
      focus.dispose();
      scroll.dispose();
      a.dispose();
      b.dispose();
    });

    Widget app(
      MarkdownSourceController controller,
      String documentId, {
      double fieldWidth = 720,
      double fontSize = 15.5,
    }) {
      return MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: fieldWidth,
              height: 500,
              child: MarkdownEditor(
                controller: controller,
                focusNode: focus,
                scrollController: scroll,
                fontSize: fontSize,
                padding: EdgeInsets.zero,
                documentId: documentId,
              ),
            ),
          ),
        ),
      );
    }

    RenderLineEditable fieldOf(WidgetTester tester) =>
        tester.allRenderObjects.whereType<RenderLineEditable>().first;

    Future<RenderLineEditable> pump(
      WidgetTester tester,
      MarkdownSourceController controller,
      String documentId, {
      double fieldWidth = 720,
      double fontSize = 15.5,
    }) async {
      await tester.pumpWidget(
        app(
          controller,
          documentId,
          fieldWidth: fieldWidth,
          fontSize: fontSize,
        ),
      );
      await tester.pumpAndSettle();
      return fieldOf(tester);
    }

    void expectSameGeometry(LineDocumentLayout actual, LineDocumentLayout expected) {
      expect(actual.laidOut.length, expected.laidOut.length, reason: '行数');
      for (int i = 0; i < actual.laidOut.length; i++) {
        final LaidOutLine x = actual.laidOut[i];
        final LaidOutLine y = expected.laidOut[i];
        final String at = '第 $i 行';
        expect(x.source.start, y.source.start, reason: '$at 起偏移');
        expect(x.source.end, y.source.end, reason: '$at 止偏移');
        expect(x.top, y.top, reason: '$at top');
        expect(x.height, y.height, reason: '$at 高度');
        expect(x.hidden, y.hidden, reason: '$at 隐藏位');
      }
      expect(actual.height, expected.height, reason: '总高度');
    }

    testWidgets('切走再切回直接采用挂起的布局，不重排任何行', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final RenderLineEditable first = await pump(tester, a, 'note-a#1');
      expect(first.debugFullLayouts, greaterThanOrEqualTo(1));
      final LineDocumentLayout original = first.lineLayout!;
      final TextPainter tailPainter = original.laidOut.last.painter;
      final double originalHeight = original.height;

      await pump(tester, b, 'note-b#1');
      expect(first.debugLayoutParks, 1, reason: '切走时应把布局挂进池');

      final RenderLineEditable back = await pump(tester, a, 'note-a#1');
      expect(back.debugLayoutPoolHits, 1, reason: '切回应命中挂起的布局');
      expect(back.debugFullLayouts, 0, reason: '命中后不该整篇重排');
      expect(back.lineLayout!.height, originalHeight);
      expectSameGeometry(back.lineLayout!, original);
      // 零重建：未变的行连 painter 都是同一份。
      expect(
        identical(back.lineLayout!.laidOut.last.painter, tailPainter),
        isTrue,
      );
    });

    testWidgets('连续切四篇后，最久未用的那篇被淘汰', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final MarkdownSourceController c = MarkdownSourceController(text: '第三篇');
      final MarkdownSourceController d = MarkdownSourceController(text: '第四篇');

      await pump(tester, a, 'note-a#1');
      await pump(tester, b, 'note-b#1');
      await pump(tester, c, 'note-c#1');
      // 切走 c 时池里是 {a, b}，挂上 c 后超容量，a 被释放。
      await pump(tester, d, 'note-d#1');
      final RenderLineEditable back = await pump(tester, a, 'note-a#1');

      expect(back.debugLayoutPoolHits, 0, reason: 'a 已被挤出池');
      expect(back.debugFullLayouts, greaterThanOrEqualTo(1));
      expect(back.lineLayout!.text, a.text);

      c.dispose();
      d.dispose();
    });

    testWidgets('离开期间正文被改过：切回不命中', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pump(tester, a, 'note-a#1');
      await pump(tester, b, 'note-b#1');
      a.text = '${a.text}\n末尾新增一行';

      final RenderLineEditable back = await pump(tester, a, 'note-a#1');
      expect(back.debugLayoutPoolHits, 0);
      expect(back.debugFullLayouts, greaterThanOrEqualTo(1));
      expectSameGeometry(back.lineLayout!, layoutOf(a.text));
    });

    testWidgets('宽度或字号变化：切回不命中', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pump(tester, a, 'note-a#1');
      await pump(tester, b, 'note-b#1');

      final RenderLineEditable narrow = await pump(
        tester,
        a,
        'note-a#1',
        fieldWidth: 640,
      );
      expect(narrow.debugLayoutPoolHits, 0);
      expect(narrow.debugFullLayouts, greaterThanOrEqualTo(1));

      await pump(tester, b, 'note-b#1', fieldWidth: 640);
      final RenderLineEditable bigger = await pump(
        tester,
        a,
        'note-a#1',
        fieldWidth: 640,
        fontSize: 17.5,
      );
      expect(bigger.debugLayoutPoolHits, 0, reason: '字号变了，布局不能沿用');
      expect(bigger.debugFullLayouts, greaterThanOrEqualTo(1));
    });

    testWidgets('正文字号变了：切回不命中', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await pump(tester, a, 'note-a#1');
      await pump(tester, b, 'note-b#1');
      // 池键里带着 `_baseStyle`：字号一变，旧的几何就不能再沿用。
      // （应用只有一块色板，墨色不会再变，这条键的其余部分靠字号来守。）
      final RenderLineEditable back = await pump(
        tester,
        a,
        'note-a#1',
        fontSize: 17,
      );

      expect(back.debugLayoutPoolHits, 0, reason: '正文样式变了，旧布局不能沿用');
      expect(back.debugFullLayouts, greaterThanOrEqualTo(1));
    });

    testWidgets('带表格的笔记切回：表格行重建且能正常绘制', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      a.text = '前言\n\n| 列一 | 列二 |\n| --- | --- |\n| 甲 | 乙 |\n| 丙 | 丁 |\n\n结束';
      final RenderLineEditable first = await pump(tester, a, 'note-a#1');
      expect(first.lineLayout!.lines.any((SourceLine l) => l.kind == LineBlockKind.table), isTrue);

      await pump(tester, b, 'note-b#1');
      final RenderLineEditable back = await pump(tester, a, 'note-a#1');

      expect(back.debugLayoutPoolHits, 1);
      expect(back.debugFullLayouts, 0);
      // 旧表块已被别的文档释放，表格行必须重建：block 都在且高度有效。
      final List<LaidOutLine> rows = back.lineLayout!.laidOut
          .where((LaidOutLine l) => l.block != null)
          .toList();
      expect(rows, isNotEmpty);
      for (final LaidOutLine row in rows) {
        expect(row.block!.height, greaterThan(0));
        expect(row.block!.width, greaterThan(0));
      }
      // 绘制会读到这些行块；悬空的行块在这里会抛异常。
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
