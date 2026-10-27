import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/utils/table_model.dart' show CellColorToken;
import 'package:nrs/ui/graph/graph_style.dart';

/// WCAG 相对亮度。
double _luminance(Color c) {
  double lin(double v) {
    final double s = v;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('分组配色', () {
    test('色名按名字排序分配，根目录固定拿第一个', () {
      final Map<String, CellColorToken> tokens = assignFolderTokens(
        <String>['项目', '', '日记'],
      );

      expect(tokens[''], GraphStyle.groupTokens.first, reason: '空串排最前');
      expect(tokens['日记'], GraphStyle.groupTokens[1]);
      expect(tokens['项目'], GraphStyle.groupTokens[2]);
    });

    test('同一批文件夹每次分配结果一样', () {
      final Map<String, CellColorToken> a = assignFolderTokens(
        <String>['b', 'a', 'c'],
      );
      final Map<String, CellColorToken> b = assignFolderTokens(
        <String>['c', 'a', 'b', 'a'],
      );

      expect(a, b);
    });

    test('文件夹多于六个就循环取色，不抛异常', () {
      final Map<String, CellColorToken> tokens = assignFolderTokens(
        List<String>.generate(9, (int i) => 'f$i'),
      );

      expect(tokens.length, 9);
      expect(tokens['f0'], tokens['f6']);
    });

    test('每个分组色在午夜靛的画布上都读得清', () {
      final GraphStyle style = GraphStyle.from(AppPalette.midnight);

      for (final CellColorToken token in GraphStyle.groupTokens) {
        expect(
          _contrast(groupColor(AppPalette.midnight, token), style.canvas),
          greaterThan(2.4),
          reason: '$token 在深色画布上太淡了',
        );
      }
    });

    test('六个分组色互不相同，灰度那档不跟节点灰撞色', () {
      final Set<Color> seen = <Color>{
        for (final CellColorToken token in GraphStyle.groupTokens)
          groupColor(AppPalette.midnight, token),
      };
      expect(seen, hasLength(GraphStyle.groupTokens.length));
    });
  });

  group('图谱就是一张灰度结构图', () {
    test('画布是深的，不是白底', () {
      final GraphStyle style = GraphStyle.from(AppPalette.midnight);
      expect(_luminance(style.canvas), lessThan(0.05));
    });

    test('默认的节点灰在画布上看得见，但不刺眼', () {
      final GraphStyle s = GraphStyle.from(AppPalette.midnight);
      final double c = _contrast(s.node, s.canvas);
      expect(c, greaterThan(3.5), reason: '太淡就看不出是颗点');
      expect(c, lessThan(9), reason: '太白就变成一片灯泡');
    });

    test('连线五档逐级递减，焦点那档明显跳出来', () {
      expect(
        GraphStyle.edgeFocus,
        greaterThan(GraphStyle.edgeBase * 3),
        reason: '焦点边要比常态亮好几倍，否则「通了电」看不出来',
      );
      // 邻居那档比常态亮：悬停一个节点时，它邻居之间的连线也该跟着亮一点，
      // 否则「这一圈是它的邻居」只在节点上看得到，连线还是灰的。
      expect(GraphStyle.edgeNear, greaterThan(GraphStyle.edgeBase));
      expect(GraphStyle.edgeBase, greaterThan(GraphStyle.edgeFar));
      expect(GraphStyle.edgeFar, greaterThan(GraphStyle.edgeDim));
      expect(GraphStyle.edgeFocus, lessThan(1));
    });

    test('标签投影和画布同一档亮度，不会出现刺眼白边', () {
      final GraphStyle s = GraphStyle.from(AppPalette.midnight);
      expect(_contrast(s.labelHalo, s.canvas), lessThan(1.6));
    });
  });
}
