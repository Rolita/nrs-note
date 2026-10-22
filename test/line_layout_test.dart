import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';

/// 测试字体每个字形都是 [fontSize] 见方，行高 `16 * 1.5 = 24`。
const TextStyle _body = TextStyle(fontSize: 16, height: 1.5);

const double _row = 24;

double _width(String text) {
  final TextPainter painter = TextPainter(
    text: TextSpan(text: text, style: _body),
    textDirection: TextDirection.ltr,
  )..layout();
  final double width = painter.width;
  painter.dispose();
  return width;
}

LineDocumentLayout _layout(
  String text, {
  double width = 200,
  LineStyleResolver? styleFor,
  LineHeightResolver? heightFor,
  LineInsetResolver? insetFor,
  int? markerRevealLine,
  LineLayoutMetrics metrics = const LineLayoutMetrics(),
}) => layoutLines(
  text: text,
  baseStyle: _body,
  contentWidth: width,
  styleFor: styleFor,
  heightFor: heightFor,
  insetFor: insetFor,
  markerRevealLine: markerRevealLine,
  metrics: metrics,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('扫描', () {
    test('块种类与判定顺序', () {
      const String doc =
          '# 标题\n'
          '\n'
          '- 项目\n'
          '1. 编号\n'
          '- [x] 完成\n'
          '> 引用\n'
          '---\n'
          '```dart\n'
          'void main() {}\n'
          '```\n'
          '| a | b |\n'
          '| --- | --- |\n'
          '| 1 | 2 |';
      final List<SourceLine> lines = scanSourceLines(doc);

      expect(lines.map((SourceLine l) => l.kind).toList(), <LineBlockKind>[
        LineBlockKind.heading,
        LineBlockKind.paragraph,
        LineBlockKind.bullet,
        LineBlockKind.ordered,
        LineBlockKind.task,
        LineBlockKind.quote,
        LineBlockKind.rule,
        LineBlockKind.fence,
        LineBlockKind.code,
        LineBlockKind.fence,
        LineBlockKind.tableHeader,
        LineBlockKind.tableDivider,
        LineBlockKind.table,
      ]);
      expect(lines[0].headingLevel, 1);
      expect(lines[7].fenceOpens, isTrue);
      expect(lines[9].fenceOpens, isFalse);
    });

    test('setext 下划线把上一行变成标题', () {
      final List<SourceLine> lines = scanSourceLines('标题\n===\n正文');
      expect(lines[0].kind, LineBlockKind.heading);
      expect(lines[0].headingLevel, 1);
      expect(lines[1].kind, LineBlockKind.setext);
      expect(lines[2].kind, LineBlockKind.paragraph);
    });

    test('列表行记录标记范围、序号与复选框', () {
      final List<SourceLine> lines = scanSourceLines(
        '- 项目\n'
        '1. 编号\n'
        '- [x] 完成\n'
        '6. [ ] 有序任务',
      );

      expect(lines[0].paintStart - lines[0].start, 2);
      expect(lines[0].marker, '- ');
      expect(lines[0].number, isNull);
      expect(lines[0].leadEnd - lines[0].start, 2);

      expect(lines[1].paintStart - lines[1].start, 3);
      expect(lines[1].marker, '1. ');
      expect(lines[1].number, 1);

      expect(lines[2].paintStart - lines[2].start, 6);
      expect(lines[2].marker, '- [x] ');
      expect(lines[2].checked, isTrue);
      expect(lines[2].leadEnd - lines[2].start, 2);

      expect(lines[3].paintStart - lines[3].start, 7);
      expect(lines[3].marker, '6. [ ] ');
      expect(lines[3].number, 6);
      expect(lines[3].leadEnd - lines[3].start, 3);
      expect(lines[3].checked, isFalse);
    });

    test('缩进换层级，与既有 26px 一级的规则一致', () {
      final List<SourceLine> lines = scanSourceLines(
        '- 一级\n'
        '  - 二级\n'
        '    - 三级\n'
        '\t- Tab 缩进',
      );
      expect(lines[0].nestLevel, 0);
      expect(lines[1].nestLevel, 1);
      expect(lines[2].nestLevel, 2);
      expect(lines[3].nestLevel, 1);
      expect(lines[1].markerStart - lines[1].start, 2);
      expect(lines[1].paintStart - lines[1].start, 4);
    });

    test('行偏移首尾相接，空文档也有一行', () {
      const String doc = 'a\n\nb';
      final List<SourceLine> lines = scanSourceLines(doc);
      expect(lines.length, 3);
      expect(lines[0].start, 0);
      expect(lines[0].end, 1);
      expect(lines[1].start, 2);
      expect(lines[1].end, 2);
      expect(lines[2].start, 3);
      expect(lines[2].end, 4);

      final List<SourceLine> empty = scanSourceLines('');
      expect(empty.length, 1);
      expect(empty.single.isEmpty, isTrue);
    });
  });

  group('悬挂缩进', () {
    const String doc =
        '- 这是一个很长的无序列表项目用来测试续行应该从正文列开始而不是行首\n'
        '1. 编号\n'
        '10. 两位数\n'
        '- [ ] 任务\n'
        '6. [ ] 有序任务\n'
        '    - 嵌套';

    test('无序列表的续行从正文列开始', () {
      final LineDocumentLayout layout = _layout(doc, width: 100);
      addTearDown(layout.dispose);
      final LaidOutLine bullet = layout.laidOut[0];

      expect(bullet.gutter, 16);
      expect(bullet.visuals.length, greaterThan(1));
      expect(bullet.visuals[1].start, greaterThan(bullet.visuals[0].start));

      // 第二条视觉行（续行）的第一个字必须落在正文列上。
      final CaretGeometry caret = layout.caretGeometryAt(
        bullet.visuals[1].start,
      );
      expect(caret.origin.dx, closeTo(bullet.gutter, 0.01));
      expect(caret.visualIndex, 1);
    });

    test('有序列表的正文列跟着序号宽度走', () {
      final LineDocumentLayout layout = _layout(doc, width: 200);
      addTearDown(layout.dispose);

      final LaidOutLine one = layout.laidOut[1];
      final LaidOutLine ten = layout.laidOut[2];

      expect(one.gutter, closeTo(_width('1. '), 0.01));
      expect(ten.gutter, closeTo(_width('10. '), 0.01));
      expect(ten.gutter, greaterThan(one.gutter));
    });

    test('两种任务列表的复选框槽位一致', () {
      final LineDocumentLayout layout = _layout(doc, width: 200);
      addTearDown(layout.dispose);

      final LaidOutLine task = layout.laidOut[3];
      final LaidOutLine orderedTask = layout.laidOut[4];

      expect(task.gutter, 26);
      expect(orderedTask.gutter, closeTo(_width('6. ') + 26, 0.01));
    });

    test('嵌套每级 26px，导轨对齐标记列左边缘', () {
      final LineDocumentLayout layout = _layout(doc, width: 200);
      addTearDown(layout.dispose);

      final LaidOutLine nested = layout.laidOut[5];
      expect(nested.slot.level, 2);
      expect(nested.slot.indent, 52);
      expect(nested.gutter, 52 + 16);
      expect(nested.slot.railXs[0], closeTo(_width('6') / 2, 0.01));
      expect(nested.slot.railXs[1], 35.5);
      // 这一层只有它一个，没有同级项可接，所以不画同级自己那一列。
      expect(nested.slot.railXs, hasLength(2));
    });

    test('同级只有一个子项时不画同级那一列', () {
      const String lone = '- 父\n  1. 独子';
      final LineDocumentLayout layout = _layout(lone, width: 200);
      addTearDown(layout.dispose);

      final LaidOutLine child = layout.laidOut[1];
      expect(child.slot.railXs, <double>[4.5]);
    });

    test('带子项的父项自己也画一列，折行和子项都接得上', () {
      const String parent = '- 父\n  1. 子';
      final LineDocumentLayout layout = _layout(parent, width: 120);
      addTearDown(layout.dispose);

      // 父项没有同级，但挂着一个子项：它自己的圆点列要一直连到子项。
      expect(layout.laidOut[0].slot.railXs, <double>[4.5]);
    });

    test('同级有多个子项时都画同级那一列', () {
      const String pair =
          '- 父\n'
          '  1. 甲\n'
          '  2. 乙';
      final LineDocumentLayout layout = _layout(pair, width: 200);
      addTearDown(layout.dispose);

      final double own = 26 + _width('1') / 2;
      expect(layout.laidOut[1].slot.railXs[0], 4.5);
      expect(layout.laidOut[1].slot.railXs[1], closeTo(own, 0.01));
      expect(layout.laidOut[2].slot.railXs[0], 4.5);
      expect(layout.laidOut[2].slot.railXs[1], closeTo(own, 0.01));
    });

    test('二级列表之间隔一个空行，空行仍然延续竖线', () {
      const String loose =
          '- 甲\n'
          '  1. 乙\n'
          '\n'
          '  2. 丙';
      final LineDocumentLayout layout = _layout(loose, width: 200);
      addTearDown(layout.dispose);

      final LaidOutLine blank = layout.laidOut[2];
      expect(blank.source.text, isEmpty);
      expect(blank.slot.railXs[0], 4.5);
      expect(blank.slot.railXs[1], closeTo(26 + _width('1') / 2, 0.01));
    });

    test('带缩进的续行不结束列表，隔开后仍接得上级内竖线', () {
      const String loose =
          '- 甲\n'
          '  1. 乙\n'
          '     续行\n'
          '\n'
          '  2. 丙';
      final LineDocumentLayout layout = _layout(loose, width: 200);
      addTearDown(layout.dispose);

      final LaidOutLine blank = layout.laidOut[3];
      expect(blank.source.text, isEmpty);
      expect(blank.slot.railXs[0], 4.5);
      expect(blank.slot.railXs[1], closeTo(26 + _width('1') / 2, 0.01));
    });

    test('正文列不会因为宽度变化而漂移', () {
      for (final double width in <double>[120, 320, 680]) {
        final LineDocumentLayout layout = _layout(doc, width: width);
        addTearDown(layout.dispose);
        expect(layout.laidOut[0].gutter, 16);
        expect(layout.laidOut[3].gutter, 26);
      }
    });
  });

  group('卡片内边距', () {
    const String doc = '```dart\nabcde\n```';

    LineDocumentLayout laidOut() {
      final LineDocumentLayout layout = _layout(
        doc,
        width: 100,
        insetFor: (SourceLine line) =>
            line.kind == LineBlockKind.code || line.kind == LineBlockKind.fence
            ? const EdgeInsets.symmetric(horizontal: 16)
            : EdgeInsets.zero,
      );
      addTearDown(layout.dispose);
      return layout;
    }

    test('代码行的正文列让出左边距，光标与选区都从这里起', () {
      final LineDocumentLayout layout = laidOut();
      final LaidOutLine code = layout.laidOut[1];

      expect(code.gutter, 16);
      expect(layout.caretGeometryAt(code.source.start).origin.dx, 16);

      // 从行首选起：洗色只洗到正文列，不会涂进卡片的内边距。
      final List<Rect> rects = layout.selectionRects(
        code.source.start,
        code.source.end,
      );
      expect(rects, isNotEmpty);
      expect(rects.first.left, 16);
    });

    test('换行宽度同时扣掉左右内边距，点右侧留白回到行尾', () {
      // 5 个 16px 的字：可用宽度 100 - 32 = 68，必须折成两行；没有内边距时
      // 它本可以挤在一行里（80 < 100）。
      final LineDocumentLayout layout = laidOut();
      final LaidOutLine code = layout.laidOut[1];

      expect(code.visuals.length, 2);
      expect(code.painter.width, lessThanOrEqualTo(68));
      // 点右侧留白：落在最后一条视觉行上时回到行尾，不会被内边距吞掉。
      expect(
        layout.offsetAtPoint(
          Offset(layout.width - 1, code.top + code.visuals.last.top + 4),
        ),
        code.source.end,
      );
    });

    test('普通段落没有内边距，正文列仍在边缘', () {
      final LineDocumentLayout layout = laidOut();
      expect(layout.laidOut[0].gutter, 16, reason: '围栏行也算卡片的一部分');

      final LineDocumentLayout plain = _layout(
        '正文',
        width: 100,
        insetFor: (SourceLine line) =>
            line.kind == LineBlockKind.code || line.kind == LineBlockKind.fence
            ? const EdgeInsets.symmetric(horizontal: 16)
            : EdgeInsets.zero,
      );
      addTearDown(plain.dispose);
      expect(plain.laidOut.single.gutter, 0);
    });
  });

  group('行高与视觉行', () {
    test('空行保留一行高度', () {
      final LineDocumentLayout layout = _layout('第一行\n\n第三行');
      addTearDown(layout.dispose);

      expect(layout.laidOut[1].height, _row);
      expect(layout.laidOut[1].visuals.length, 1);
      expect(layout.height, _row * 3);
      expect(layout.lines[1].isEmpty, isTrue);
    });

    test('中英混排长段落按宽度折行', () {
      final LineDocumentLayout layout = _layout(
        '这是一段中文和 English words 混排的长文本，用来确认软换行只发生在这一行内部，'
        '并且每一条视觉行都记录了自己的源码范围。',
        width: 200,
      );
      addTearDown(layout.dispose);

      final LaidOutLine line = layout.laidOut[0];
      expect(line.visuals.length, greaterThan(2));
      for (int i = 1; i < line.visuals.length; i++) {
        expect(line.visuals[i].top, greaterThan(line.visuals[i - 1].top));
        expect(
          line.visuals[i].start,
          greaterThanOrEqualTo(line.visuals[i - 1].end),
        );
      }
      expect(line.visuals.first.start, line.source.start);
      expect(line.visuals.last.end, line.source.end);
      expect(line.height, closeTo(line.painter.height, 0.01));
    });

    test('标题与代码行各自占自己的行高', () {
      const String doc = '# 标题\n```dart\ncode\n```';
      final LineDocumentLayout layout = _layout(
        doc,
        width: 400,
        styleFor: (SourceLine line) => switch (line.kind) {
          LineBlockKind.heading => const TextStyle(fontSize: 32, height: 1.5),
          LineBlockKind.code => const TextStyle(fontSize: 12, height: 1.5),
          _ => _body,
        },
      );
      addTearDown(layout.dispose);

      expect(layout.laidOut[0].height, 48);
      expect(layout.laidOut[2].height, 18);
      expect(layout.laidOut[1].height, _row);
    });

    test('围栏行可以压成固定高度', () {
      const String doc = '```dart\ncode\n```';
      final LineDocumentLayout layout = _layout(
        doc,
        heightFor: (SourceLine line) => line.kind == LineBlockKind.fence
            ? (line.fenceOpens ? 16 : 0)
            : null,
      );
      addTearDown(layout.dispose);

      expect(layout.laidOut[0].height, 16);
      expect(layout.laidOut[2].height, 0);
      expect(layout.laidOut[1].top, 16);
      expect(layout.height, 16 + _row);
    });
  });

  group('偏移与坐标', () {
    const String doc =
        '# 标题\n'
        '- 列表项目比较长需要换行继续显示才看得清\n'
        '- [x] 已完成的任务\n'
        '普通段落包含 English words 和中文混排。';

    test('正文内每个偏移都能往返', () {
      final LineDocumentLayout layout = _layout(doc, width: 140);
      addTearDown(layout.dispose);

      for (final LaidOutLine line in layout.laidOut) {
        for (int o = line.source.paintStart; o <= line.source.end; o++) {
          final CaretGeometry caret = layout.caretGeometryAt(o);
          expect(
            layout.offsetAtPoint(caret.origin),
            o,
            reason: 'offset $o 在 ${line.source}',
          );
        }
      }
    });

    test('标记区内的偏移吸附到正文列', () {
      final LineDocumentLayout layout = _layout(doc);
      addTearDown(layout.dispose);

      final LaidOutLine bullet = layout.laidOut[1];
      for (final int o in <int>[
        bullet.source.markerStart,
        bullet.source.markerStart + 1,
      ]) {
        final CaretGeometry caret = layout.caretGeometryAt(o);
        expect(caret.origin.dx, 16);
        expect(layout.offsetAtPoint(caret.origin), bullet.source.paintStart);
      }
    });

    test('点击左侧槽位回到正文起点，点击空白回到文末', () {
      final LineDocumentLayout layout = _layout(doc);
      addTearDown(layout.dispose);

      final LaidOutLine bullet = layout.laidOut[1];
      expect(
        layout.offsetAtPoint(Offset(1, bullet.top + 4)),
        bullet.source.paintStart,
      );
      expect(layout.offsetAtPoint(const Offset(10, -5)), 0);
      expect(layout.offsetAtPoint(Offset(10, layout.height + 5)), doc.length);
    });

    test('空行的光标仍然可见', () {
      final LineDocumentLayout layout = _layout('a\n\nb');
      addTearDown(layout.dispose);

      final CaretGeometry caret = layout.caretGeometryAt(2);
      expect(caret.origin, const Offset(0, _row));
      expect(caret.height, _row);
      expect(layout.offsetAtPoint(caret.origin), 2);
    });

    test('行尾空格不改变光标高度', () {
      // 行尾是空格时，量字形得到的是空格自己的盒子，比整行矮一截；
      // 光标高度必须跟整条视觉行走，否则打一个空格光标就缩一下。
      final LineDocumentLayout plain = _layout('nihao');
      final LineDocumentLayout spaced = _layout('nihao ');
      addTearDown(plain.dispose);
      addTearDown(spaced.dispose);
      expect(
        spaced.caretGeometryAt(spaced.laidOut.first.source.end).height,
        plain.caretGeometryAt(plain.laidOut.first.source.end).height,
      );

      final LineDocumentLayout heading = _layout('# 标题');
      final LineDocumentLayout headingSpaced = _layout('# 标题 ');
      addTearDown(heading.dispose);
      addTearDown(headingSpaced.dispose);
      expect(
        headingSpaced
            .caretGeometryAt(headingSpaced.laidOut.first.source.end)
            .height,
        heading.caretGeometryAt(heading.laidOut.first.source.end).height,
      );
    });
  });

  group('选区盒子', () {
    const String doc =
        '- 第一行比较长需要换行才能看清效果\n'
        '第二行\n'
        '\n'
        '第四行';

    test('整行选中时从行首起、贴着字形', () {
      final LineDocumentLayout layout = _layout(doc, width: 100);
      addTearDown(layout.dispose);

      final LaidOutLine first = layout.laidOut[0];
      final List<Rect> rects = layout.selectionRects(
        first.source.start,
        first.source.end + 1,
      );

      expect(rects, isNotEmpty);
      // 从行首选起：第一块把手伸进标记槽位。
      expect(rects.first.left, 0);
      for (final Rect rect in rects) {
        expect(rect.top, greaterThanOrEqualTo(first.top));
        expect(rect.bottom, lessThanOrEqualTo(first.bottom));
      }
    });

    test('高亮贴着字形，不铺满整列', () {
      final LineDocumentLayout layout = _layout('短句\n另一句', width: 400);
      addTearDown(layout.dispose);

      // 连换行符一起选中，宽度也不该被撑到列尾。
      final List<Rect> rects = layout.selectionRects(0, 6);
      expect(rects, hasLength(2));
      expect(rects.first.right, lessThan(100));
      expect(rects.first.right, lessThan(layout.width));
    });

    test('纵向铺满视觉行，上下两行首尾相接', () {
      final LineDocumentLayout layout = _layout('第一行\n第二行');
      addTearDown(layout.dispose);

      final List<Rect> rects = layout.selectionRects(0, 7);
      // 每行一块，块高等于这一行的视觉行高。
      expect(rects.length, 2);
      expect(rects[0].height, layout.laidOut[0].height);
      expect(rects[1].top, rects[0].bottom);
    });

    test('换行之后的选区落在下一行', () {
      final LineDocumentLayout layout = _layout(doc, width: 100);
      addTearDown(layout.dispose);

      final LaidOutLine first = layout.laidOut[0];
      final LaidOutLine second = layout.laidOut[1];
      final List<Rect> rects = layout.selectionRects(0, second.source.end);

      expect(rects.any((Rect r) => r.top < first.bottom), isTrue);
      expect(rects.any((Rect r) => r.top >= second.top), isTrue);
    });

    test('反向选区与正向一致', () {
      final LineDocumentLayout layout = _layout(doc, width: 140);
      addTearDown(layout.dispose);

      expect(layout.selectionRects(3, 20), layout.selectionRects(20, 3));
    });

    test('空行被选中时有可见高亮', () {
      final LineDocumentLayout layout = _layout('a\n\nb');
      addTearDown(layout.dispose);

      final List<Rect> rects = layout.selectionRects(2, 3);
      expect(rects.length, 1);
      expect(rects.single.height, _row);
      expect(rects.single.top, _row);
    });

    test('折叠为空档的光标不产生负高度盒子', () {
      final LineDocumentLayout layout = _layout(
        '```\ncode\n```',
        heightFor: (SourceLine line) => line.kind == LineBlockKind.fence
            ? (line.fenceOpens ? 16 : 0)
            : null,
      );
      addTearDown(layout.dispose);

      final List<Rect> rects = layout.selectionRects(0, 3);
      for (final Rect rect in rects) {
        expect(rect.height, greaterThan(0));
      }
    });
  });

  group('行矩形与行顶', () {
    test('行顶按每行自己的行高累加', () {
      final LineDocumentLayout layout = _layout(
        '# 标题\n正文\n正文',
        styleFor: (SourceLine line) => line.kind == LineBlockKind.heading
            ? const TextStyle(fontSize: 32, height: 1.5)
            : _body,
      );
      addTearDown(layout.dispose);

      expect(layout.lineTop(0), 0);
      expect(layout.lineTop(1), layout.laidOut[0].height);
      expect(
        layout.lineTop(2),
        layout.laidOut[0].height + layout.laidOut[1].height,
      );
      // 标题行确实比正文行高——这正是宿主推算不出来的部分。
      expect(layout.laidOut[0].height, greaterThan(layout.laidOut[1].height));
    });

    test('行号越界夹到首末行', () {
      final LineDocumentLayout layout = _layout('一\n二\n三');
      addTearDown(layout.dispose);

      expect(layout.lineTop(-4), 0);
      expect(layout.lineTop(99), layout.laidOut.last.top);
    });

    test('代码块矩形从开围栏铺到闭围栏，跳过零高行', () {
      final LineDocumentLayout layout = _layout(
        '前\n```\ncode\ncode\n```\n后',
        heightFor: (SourceLine line) => line.kind == LineBlockKind.fence
            ? (line.fenceOpens ? 16 : 0)
            : null,
      );
      addTearDown(layout.dispose);

      final Rect? rect = layout.blockRect(2, 19);
      expect(rect, isNotNull);
      expect(rect!.left, 0);
      expect(rect.right, layout.width);
      expect(rect.top, layout.lineTop(1));
      // 闭围栏压成 0 高，卡片底边停在下一行正文的顶上。
      expect(rect.bottom, layout.lineTop(5));
    });

    test('空区间与全越界返回 null', () {
      final LineDocumentLayout layout = _layout('abc');
      addTearDown(layout.dispose);

      expect(layout.blockRect(2, 2), isNull);
      expect(layout.blockRect(99, 120), isNull);
    });

    test('反向区间与正向一致', () {
      final LineDocumentLayout layout = _layout('前\n```\ncode\n```\n后');
      addTearDown(layout.dispose);

      expect(layout.blockRect(19, 2), layout.blockRect(2, 19));
    });
  });

  group('列表标记摊进正文', () {
    test('只有点开标记的那一行展开', () {
      const String doc = '15. [ ] 甲';
      final SourceLine line = scanSourceLines(doc).single;
      expect(line.isList, isTrue);

      // 没人点它：标记仍在槽位里，正文从 paintStart 起排。
      final LineDocumentLayout body = _layout(doc);
      addTearDown(body.dispose);
      expect(body.laidOut.single.paintedFrom, line.paintStart);
      expect(body.laidOut.single.slot.width, greaterThan(0));
      expect(body.laidOut.single.slot.revealedMarkers, isFalse);

      // 点了这一行的标记：标记摊进正文，槽位让出全部宽度。
      final LineDocumentLayout marker = _layout(
        doc,
        markerRevealLine: line.start,
      );
      addTearDown(marker.dispose);
      expect(marker.laidOut.single.paintedFrom, line.start);
      expect(marker.laidOut.single.slot.width, 0);
      expect(marker.laidOut.single.slot.revealedMarkers, isTrue);
    });

    test('摊开以后，标记槽位里的点映射到序号本身', () {
      const String doc = '15. [ ] 甲';
      final SourceLine line = scanSourceLines(doc).single;
      final LineDocumentLayout layout = _layout(
        doc,
        markerRevealLine: line.start,
      );
      addTearDown(layout.dispose);

      final int at = layout.offsetAtPoint(const Offset(4, 8));
      expect(
        at,
        inInclusiveRange(line.start, line.paintStart),
        reason: '展开后序号是字形，点它就应落在序号里',
      );
    });

    test('只有列表行会摊开，普通段落不受影响', () {
      const String doc = '15. 甲\n普通段落';
      final List<SourceLine> lines = scanSourceLines(doc);
      final LineDocumentLayout layout = _layout(
        doc,
        markerRevealLine: lines.first.start,
      );
      addTearDown(layout.dispose);

      expect(layout.laidOut.first.slot.revealedMarkers, isTrue);
      expect(layout.laidOut.first.paintedFrom, 0);
      expect(layout.laidOut.last.slot.revealedMarkers, isFalse);
    });
  });
}
