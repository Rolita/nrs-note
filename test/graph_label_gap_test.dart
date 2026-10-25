import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/note_graph.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/ui/graph/graph_painter.dart';
import 'package:nrs/ui/graph/graph_physics.dart';

Note _note(String title, String body) {
  final DateTime t = DateTime(2026, 1, 1);
  return Note(
    id: 'id:$title',
    title: title,
    body: body,
    folderPath: 'f${title.hashCode % 4}',
    createdAt: t,
    updatedAt: t,
  );
}

/// 造一张 n 篇的图，收敛后返回布局。
GraphLayout _layout(int n) {
  final List<Note> notes = <Note>[
    for (int i = 0; i < n; i++)
      _note('n$i', '[[n${(i + 1) % n}]] [[n${(i * 7) % n}]]'),
  ];
  final NoteGraph g = buildNoteGraph(notes);
  final GraphLayout l = GraphLayout.of(g);
  l.settle(g, settleTicksFor(n));
  return l;
}

/// 和 `GraphView._fitToStage` 同一套算法，把整张图装进 900×600。
double _fit(GraphLayout l) {
  final Rect b = l.bounds();
  const double pad = 74;
  final double fit = math.min(
    (900 - pad * 2) / math.max(b.width, 1),
    (600 - pad * 2) / math.max(b.height, 1),
  );
  return fit.clamp(0.2, 1.5);
}

void main() {
  group('标签写不写，只看屏幕上放不放得下', () {
    test('几百篇铺满画布时一个标签都不写', () {
      final GraphLayout l = _layout(400);
      final double gap = screenGap(l, _fit(l));

      expect(
        gap,
        lessThan(GraphPainter.labelGapMin),
        reason: '挤成这样还写标签，就是满屏小字互相压',
      );
    });

    test('放大之后间距够了，标签才出来', () {
      final GraphLayout l = _layout(400);
      final double fit = _fit(l);

      expect(
        screenGap(l, fit * 3),
        greaterThan(GraphPainter.labelGapMin),
        reason: '放大三倍还不写标签，那这个自动就永远不生效了',
      );
    });

    test('小图铺满画布时就写得下', () {
      final GraphLayout l = _layout(20);

      expect(
        screenGap(l, _fit(l)),
        greaterThan(GraphPainter.labelGapMin),
        reason: '二十篇的库一打开就该看得到标题',
      );
    });

    test('门槛是「先无后有」的一段，不是硬切', () {
      expect(GraphPainter.labelGapFull, greaterThan(0));
      expect(GraphPainter.labelGapMin, greaterThan(0));
    });
  });
}
