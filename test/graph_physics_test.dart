import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/note_graph.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/ui/graph/graph_physics.dart';

Note note(String title, {String body = ''}) {
  final DateTime t = DateTime(2026, 1, 1);
  return Note(
    id: 'id:$title',
    title: title,
    body: body,
    createdAt: t,
    updatedAt: t,
  );
}

/// 一个 12 条辐条的星形：中心节点被 12 个邻居同时拽，是斥力最容易塌的地方。
NoteGraph star({int spokes = 12}) => buildNoteGraph(<Note>[
  note('hub', body: <String>[for (int i = 0; i < spokes; i++) '[[s$i]]'].join(' ')),
  for (int i = 0; i < spokes; i++) note('s$i'),
]);

/// 20 个节点的环，每个连下一个。
NoteGraph ring({int count = 20}) => buildNoteGraph(<Note>[
  for (int i = 0; i < count; i++) note('r$i', body: '[[r${(i + 1) % count}]]'),
]);

double minGap(GraphLayout l) {
  double worst = double.infinity;
  for (int i = 0; i < l.length; i++) {
    for (int j = i + 1; j < l.length; j++) {
      final double d = math.sqrt(
        math.pow(l.x[i] - l.x[j], 2) + math.pow(l.y[i] - l.y[j], 2),
      );
      final double gap = d - (l.radius[i] + l.radius[j]);
      if (gap < worst) worst = gap;
    }
  }
  return worst;
}

double driftAfter(GraphLayout l, NoteGraph g, int ticks) {
  final List<double> before = <double>[];
  for (int i = 0; i < l.length; i++) {
    before
      ..add(l.x[i])
      ..add(l.y[i]);
  }
  l.settle(g, ticks);
  double worst = 0;
  for (int i = 0; i < l.length; i++) {
    final double dx = l.x[i] - before[i * 2];
    final double dy = l.y[i] - before[i * 2 + 1];
    worst = math.max(worst, math.sqrt(dx * dx + dy * dy));
  }
  return worst;
}

void main() {
  group('收敛', () {
    test('星形图 300 帧后没有 NaN / Infinity', () {
      final NoteGraph g = star();
      final GraphLayout l = GraphLayout.of(g)..settle(g, 300);

      for (int i = 0; i < l.length; i++) {
        expect(l.x[i].isFinite, isTrue, reason: 'x[$i] = ${l.x[i]}');
        expect(l.y[i].isFinite, isTrue, reason: 'y[$i] = ${l.y[i]}');
      }
    });

    test('星形图收敛后圆与圆不重叠', () {
      final NoteGraph g = star();
      final GraphLayout l = GraphLayout.of(g)..settle(g, 800);

      expect(minGap(l), greaterThan(0));
    });

    test('环形图收敛后圆与圆不重叠', () {
      final NoteGraph g = ring();
      final GraphLayout l = GraphLayout.of(g)..settle(g, 800);

      expect(minGap(l), greaterThan(0));
    });

    test('布局是横的：包围盒明显宽于高', () {
      // 各向同性的斥力 + 向心只能排出一根竖条，四个文件夹会排成一条线，
      // 画布左右全空。横向权重（wide / stretch）就是为了这个。
      for (final NoteGraph g in <NoteGraph>[star(), ring()]) {
        final GraphLayout l = GraphLayout.of(g)..settle(g, 800);
        final b = l.bounds();
        expect(
          b.width / b.height,
          greaterThan(1.25),
          reason: '${g.nodes.length} 个节点的图被排成了竖条',
        );
      }
    });

    test('800 帧之后基本不动了', () {
      final NoteGraph g = star();
      final GraphLayout l = GraphLayout.of(g)..settle(g, 800);

      expect(driftAfter(l, g, 200), lessThan(6));
    });

    test('包围盒包住所有节点和半径', () {
      final NoteGraph g = star();
      final GraphLayout l = GraphLayout.of(g)..settle(g, 400);
      final bounds = l.bounds();

      for (int i = 0; i < l.length; i++) {
        expect(bounds.left, lessThanOrEqualTo(l.x[i] - l.radius[i]));
        expect(bounds.right, greaterThanOrEqualTo(l.x[i] + l.radius[i]));
        expect(bounds.top, lessThanOrEqualTo(l.y[i] - l.radius[i]));
        expect(bounds.bottom, greaterThanOrEqualTo(l.y[i] + l.radius[i]));
      }
      expect(bounds.width, greaterThan(0));
    });
  });

  group('可复现', () {
    test('同一个种子得到同一个布局', () {
      final NoteGraph g = star();
      final GraphLayout a = GraphLayout.of(g, seed: 7)..settle(g, 120);
      final GraphLayout b = GraphLayout.of(g, seed: 7)..settle(g, 120);

      for (int i = 0; i < a.length; i++) {
        expect(a.x[i], b.x[i]);
        expect(a.y[i], b.y[i]);
      }
    });

    test('不同种子得到不同布局', () {
      final NoteGraph g = star();
      final GraphLayout a = GraphLayout.of(g, seed: 1);
      final GraphLayout b = GraphLayout.of(g, seed: 2);

      expect(a.x[0] == b.x[0] && a.y[0] == b.y[0], isFalse);
    });
  });

  group('边界', () {
    test('空图不崩', () {
      final NoteGraph g = buildNoteGraph(<Note>[]);
      final GraphLayout l = GraphLayout.of(g);

      expect(l.isEmpty, isTrue);
      l.settle(g, 10);
      expect(l.bounds().width, 0);
    });

    test('单篇笔记停在自己撒的点上，不发散', () {
      final NoteGraph g = buildNoteGraph(<Note>[note('A')]);
      final GraphLayout l = GraphLayout.of(g)..settle(g, 400);

      expect(l.x[0].isFinite, isTrue);
      // 只有一个节点：斥力与弹簧都没对象，只剩向心引力，必然被拉回原点附近
      expect(l.x[0].abs(), lessThan(60));
      expect(l.y[0].abs(), lessThan(60));
    });

    test('两个点重合时用下标造方向，不会 NaN', () {
      final NoteGraph g = buildNoteGraph(<Note>[note('A'), note('B')]);
      final GraphLayout l = GraphLayout.of(g);
      l
        ..x[0] = 0
        ..y[0] = 0
        ..x[1] = 0
        ..y[1] = 0;
      l.settle(g, 20);

      expect(l.x[0].isFinite, isTrue);
      expect(l.x[1].isFinite, isTrue);
      expect(l.x[0] == l.x[1] && l.y[0] == l.y[1], isFalse);
    });
  });

  group('半径与帧数', () {
    test('半径按度数开平方，压住差异', () {
      expect(graphNodeRadius(0), closeTo(4.6, 1e-9));
      expect(graphNodeRadius(9), closeTo(4.6 + 3 * 2.4, 1e-9));
      // 度 0 → 9 只大 7px 出头，不会变成一颗球
      expect(graphNodeRadius(9) - graphNodeRadius(0), lessThan(8));
      expect(graphNodeRadius(4, scale: 2), closeTo(graphNodeRadius(4) * 2, 1e-9));
    });

    test('节点越多，首屏收敛帧数越少', () {
      expect(settleTicksFor(26), 700);
      expect(settleTicksFor(120), 700);
      expect(settleTicksFor(200), 260);
      expect(settleTicksFor(300), 260);
      expect(settleTicksFor(301), 120);
      expect(settleTicksFor(2000), 120);
    });

    test('scaledRadii 不改原值', () {
      final NoteGraph g = star();
      final GraphLayout l = GraphLayout.of(g);
      final double before = l.radius[0];
      final scaled = l.scaledRadii(2);

      expect(l.radius[0], before);
      expect(scaled[0], closeTo(before * 2, 1e-9));
    });

    test('撒点半径按 √n 走：几百篇也不会散成一片', () {
      // 撒点半径按 n 线性增长的话，四百篇会撒在半径 3600 的圈上，首屏
      // 120 帧根本收不回来（实测包围盒 15000+）。缩进画布后每颗点不到
      // 半个像素，整张图看起来就是一层灰，而不是「很多篇笔记」。
      final List<Note> notes = <Note>[
        for (int i = 0; i < 400; i++)
          note(
            'n$i',
            body: '[[n${(i + 1) % 400}]] [[n${(i * 7) % 400}]]',
          ),
      ];
      final NoteGraph g = buildNoteGraph(notes);
      final GraphLayout l = GraphLayout.of(g);
      l.settle(g, settleTicksFor(notes.length));

      final Rect b = l.bounds();
      expect(
        math.max(b.width, b.height),
        lessThan(2200),
        reason: '收敛后还这么大，说明首屏那些帧根本没把它收回来',
      );
    });
  });
}