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
  group('分组配色跟着主题走', () {
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

    test('浅色主题下每个分组色在浅色画布上都读得清', () {
      final GraphStyle style = GraphStyle.from(AppPalette.light);
      expect(AppPalette.light.isDark, isFalse);

      for (final CellColorToken token in GraphStyle.groupTokens) {
        final Color ink = groupColor(AppPalette.light, token);
        // 画布渐变的两端都试一遍：节点可能落在任何位置。
        for (final Color canvas in <Color>[
          style.canvasTop,
          style.canvasBottom,
        ]) {
          expect(
            _contrast(ink, canvas),
            greaterThan(2.4),
            reason: '$token 在 $canvas 上太淡了',
          );
        }
      }
    });

    test('深色主题同样读得清', () {
      final GraphStyle style = GraphStyle.from(AppPalette.dark);

      for (final CellColorToken token in GraphStyle.groupTokens) {
        final Color ink = groupColor(AppPalette.dark, token);
        for (final Color canvas in <Color>[
          style.canvasTop,
          style.canvasBottom,
        ]) {
          expect(
            _contrast(ink, canvas),
            greaterThan(2.4),
            reason: '$token 在 $canvas 上太淡了',
          );
        }
      }
    });

    test('浅色主题的分组色不是深色那一套', () {
      expect(
        groupColor(AppPalette.light, CellColorToken.gray),
        isNot(groupColor(AppPalette.dark, CellColorToken.gray)),
      );
    });

    test('画布在浅色主题下是浅的，在深色主题下是深的', () {
      final GraphStyle light = GraphStyle.from(AppPalette.light);
      final GraphStyle dark = GraphStyle.from(AppPalette.dark);

      expect(
        _luminance(light.canvasTop),
        greaterThan(_luminance(dark.canvasTop)),
      );
      expect(_luminance(light.canvasTop), greaterThan(0.8));
      expect(_luminance(dark.canvasTop), lessThan(0.05));
    });

    test('标签描边和画布同一档亮度，不会出现刺眼白边', () {
      final GraphStyle light = GraphStyle.from(AppPalette.light);
      final GraphStyle dark = GraphStyle.from(AppPalette.dark);

      expect(_contrast(light.labelHalo, light.canvasTop), lessThan(1.3));
      expect(_contrast(dark.labelHalo, dark.canvasTop), lessThan(1.6));
    });
  });
}
