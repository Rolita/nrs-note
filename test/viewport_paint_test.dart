import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/editor/code_block_painter.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// P3：绘制视口裁剪与几何缓存。
///
/// 护栏分三层：引擎的区间/备忘（纯函数）、绘制行数计数器（一帧只画可见行）、
/// 几何缓存按引用复用（指针移动不再全篇重建）。
const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
const double width = 680;

LineDocumentLayout layoutOf(String text) =>
    layoutLines(text: text, baseStyle: base, contentWidth: width);

String manyLines(int count) =>
    List<String>.generate(count, (int i) => '第 $i 行').join('\n');

void main() {
  group('引擎几何', () {
    test('lineRangeBetween 只覆盖与区间相交的行', () {
      final LineDocumentLayout layout = layoutOf(manyLines(300));
      expect(layout.laidOut.length, 300);

      final double top = layout.laidOut[120].top;
      // 上界略小于下一行顶部，避免把恰好首尾相接的下一行算进来。
      final double bottom = layout.laidOut[140].bottom - 1;
      final ({int from, int to}) range = layout.lineRangeBetween(top, bottom);
      expect(range.from, 120);
      expect(range.to, 141);

      // 顶部之前的空区间收敛到第一行。
      final ({int from, int to}) first = layout.lineRangeBetween(-32, 120);
      expect(first.from, 0);
      expect(first.to, greaterThan(0));
    });

    test('selectionRects 按可见区间裁剪且结果不变形', () {
      final String text = manyLines(200);
      final LineDocumentLayout layout = layoutOf(text);
      final List<Rect> full = layout.selectionRects(0, text.length);
      final Rect visible = Rect.fromLTRB(
        0,
        layout.laidOut[50].top,
        width,
        layout.laidOut[60].bottom,
      );
      final List<Rect> clipped = layout.selectionRects(
        0,
        text.length,
        visible: visible,
      );

      expect(full, isNotEmpty);
      expect(clipped, isNotEmpty);
      expect(clipped.length, lessThan(full.length));
      expect(clipped.length, lessThan(16));
      for (final Rect rect in clipped) {
        expect(
          rect.bottom >= visible.top && rect.top <= visible.bottom,
          isTrue,
          reason: '裁剪后的矩形必须落在可见行范围内：$rect',
        );
      }
    });

    test('blockRect 同一区间只做一次全行扫描', () {
      const String text = '```dart\nvoid main() {}\n```\n\n正文\n\n```py\nprint(1)\n```';
      final LineDocumentLayout layout = layoutOf(text);
      expect(layout.debugBlockRectComputes, 0);

      final Rect? first = layout.blockRect(0, text.length);
      final Rect? second = layout.blockRect(0, text.length);
      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
      expect(layout.debugBlockRectComputes, 1);

      layout.blockRect(0, 10);
      expect(layout.debugBlockRectComputes, 2);
    });
  });

  group('渲染层视口', () {
    Future<RenderLineEditable> pumpEditor(
      WidgetTester tester,
      String text,
      ScrollController scroll,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppPalette.midnight),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 720,
                height: 300,
                child: MarkdownEditor(
                  controller: MarkdownSourceController(text: text),
                  focusNode: FocusNode(),
                  scrollController: scroll,
                  fontSize: 15.5,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.allRenderObjects.whereType<RenderLineEditable>().first;
    }

    testWidgets('一帧只画可见行，滚动后行数不随总行数增长', (WidgetTester tester) async {
      final ScrollController scroll = ScrollController();
      addTearDown(scroll.dispose);
      final RenderLineEditable field = await pumpEditor(
        tester,
        manyLines(600),
        scroll,
      );

      expect(field.lineLayout!.laidOut.length, 600);
      final int visibleRows =
          (300 / field.preferredLineHeight).ceil() + 2;
      expect(
        field.debugPaintedLines,
        lessThanOrEqualTo(visibleRows + 4),
        reason: '首帧只该画视口内的行',
      );
      expect(field.debugPaintedLines, greaterThan(0));

      scroll.jumpTo(4000);
      await tester.pump();
      expect(
        field.visibleDocumentTop,
        greaterThan(1000),
        reason: '外层滚动视图的偏移要反映到可见区间',
      );
      expect(
        field.debugPaintedLines,
        lessThanOrEqualTo(visibleRows + 4),
        reason: '滚动到中部后仍然只画可见行',
      );
      expect(field.debugPaintedLines, greaterThan(0));
    });

    testWidgets('折叠箭头几何在布局与滚动不变时复用同一列表', (WidgetTester tester) async {
      final ScrollController scroll = ScrollController();
      addTearDown(scroll.dispose);
      final RenderLineEditable field = await pumpEditor(
        tester,
        '- 父项\n  - 子项\n- 另一项\n收尾',
        scroll,
      );

      final List<ListFoldHandle> first = field.foldHandles();
      expect(first, isNotEmpty);
      expect(identical(first, field.foldHandles()), isTrue);
      expect(identical(field.taskCheckboxRects(), field.taskCheckboxRects()), isTrue);

      field.markNeedsPaint();
      await tester.pump();
      expect(
        identical(first, field.foldHandles()),
        isTrue,
        reason: '重绘但没有滚动时不该重建箭头几何',
      );
    });

    testWidgets('滚动重绘不再重扫围栏块', (WidgetTester tester) async {
      final ScrollController scroll = ScrollController();
      addTearDown(scroll.dispose);
      CodeBlockPainter.debugRangeScans = 0;
      final String text =
          '```dart\nvoid main() {}\n```\n${manyLines(600)}';
      await pumpEditor(tester, text, scroll);
      final int scans = CodeBlockPainter.debugRangeScans;
      expect(scans, greaterThan(0), reason: '首次绘制要扫描一次');

      scroll.jumpTo(4000);
      await tester.pump();
      expect(
        CodeBlockPainter.debugRangeScans,
        scans,
        reason: '文本没变时滚动不该重扫围栏块',
      );
    });
  });
}
