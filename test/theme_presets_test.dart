import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/theme_presets.dart';

/// Compares two boards token by token — [AppPalette] has no `==`, and the 25
/// names are what every other test asserts on anyway.
void expectSameBoard(AppPalette actual, AppPalette expected, {String? reason}) {
  expect(actual.brightness, expected.brightness, reason: reason);
  for (final AppPaletteToken t in AppPaletteToken.values) {
    expect(actual.colorOf(t), expected.colorOf(t), reason: '${reason ?? ''}/${t.name}');
  }
}

int countDifferences(AppPalette a, AppPalette b) => AppPaletteToken.values
    .where((AppPaletteToken t) => a.colorOf(t) != b.colorOf(t))
    .length;

void main() {
  group('预设目录', () {
    test('三套内置，顺序即选择器顺序，默认是石墨素白', () {
      expect(ThemePresetId.values.length, 4);
      expect(ThemePresets.builtIn.length, 3);
      expect(ThemePresets.builtIn.first.id, ThemePresetId.fallback);
      expect(ThemePresetId.fallback, ThemePresetId.graphite);
      // 自定义是哨兵而不是一套色板，所以它排在最后且不进目录。
      expect(ThemePresetId.values.last, ThemePresetId.custom);
    });

    test('每套的亮面/暗面 brightness 与命名相符', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        expect(preset.light.brightness, Brightness.light, reason: preset.id.name);
        expect(preset.dark.brightness, Brightness.dark, reason: preset.id.name);
      }
    });

    test('任意两套的 25 个令牌都不全等', () {
      for (int i = 0; i < ThemePresets.builtIn.length; i++) {
        for (int j = i + 1; j < ThemePresets.builtIn.length; j++) {
          final ThemePreset a = ThemePresets.builtIn[i];
          final ThemePreset b = ThemePresets.builtIn[j];
          final String pair = '${a.id.name}/${b.id.name}';
          expect(countDifferences(a.light, b.light), greaterThan(0), reason: '$pair light');
          expect(countDifferences(a.dark, b.dark), greaterThan(0), reason: '$pair dark');
        }
      }
    });

    test('石墨素白就是 AppPalette.light / dark', () {
      expectSameBoard(ThemePresets.of(ThemePresetId.graphite).light, AppPalette.light);
      expectSameBoard(ThemePresets.of(ThemePresetId.graphite).dark, AppPalette.dark);
    });

    test('未知 id 与 custom 都落到石墨素白', () {
      expectSameBoard(ThemePresets.of(ThemePresetId.custom).light, AppPalette.light);
      expectSameBoard(ThemePresets.of(ThemePresetId.custom).dark, AppPalette.dark);
    });
  });

  group('令牌表', () {
    test('25 个，线格式键两两不重复', () {
      expect(AppPaletteToken.values.length, 25);
      final Set<String> names =
          AppPaletteToken.values.map((AppPaletteToken t) => t.name).toSet();
      expect(names.length, 25);
    });

    test('精选 12 个，剩下的 13 个由高级开关放出', () {
      expect(AppPaletteToken.featured.length, 12);
      final Set<AppPaletteToken> rest = AppPaletteToken.values
          .toSet()
          .difference(AppPaletteToken.featured.toSet());
      expect(rest.length, 13);
      // 只有三个带 alpha 的令牌需要 alpha 滑块。
      expect(
        AppPaletteToken.values.where((AppPaletteToken t) => t.hasAlpha).toSet(),
        <AppPaletteToken>{
          AppPaletteToken.selection,
          AppPaletteToken.shadow,
          AppPaletteToken.overlay,
        },
      );
    });

    test('withToken 命中一个，另外 24 个逐一不动', () {
      const Color probe = Color(0xFFFF00FF);
      for (final AppPaletteToken t in AppPaletteToken.values) {
        final AppPalette next = AppPalette.light.withToken(t, probe);
        expect(next.colorOf(t), probe, reason: t.name);
        for (final AppPaletteToken other in AppPaletteToken.values) {
          if (other == t) continue;
          expect(
            next.colorOf(other),
            AppPalette.light.colorOf(other),
            reason: '${t.name} moved ${other.name}',
          );
        }
      }
    });

    test('withTokens 收成一张表再灌回去，25 个令牌全部无损', () {
      final Map<AppPaletteToken, Color> map = <AppPaletteToken, Color>{
        for (final AppPaletteToken t in AppPaletteToken.values)
          t: AppPalette.dark.colorOf(t),
      };
      final AppPalette folded = AppPalette.light.withTokens(map);
      // brightness 不在表里，所以它留在原处。
      expect(folded.brightness, Brightness.light);
      for (final AppPaletteToken t in AppPaletteToken.values) {
        expect(folded.colorOf(t), AppPalette.dark.colorOf(t), reason: t.name);
      }
    });

    test('空表与不完整表都只动给出的令牌', () {
      expect(AppPalette.light.withTokens(<AppPaletteToken, Color>{}).accent,
          AppPalette.light.accent);
      final AppPalette one = AppPalette.light.withTokens(<AppPaletteToken, Color>{
        AppPaletteToken.rule: const Color(0xFF112233),
      });
      expect(one.rule, const Color(0xFF112233));
      expect(one.outline, AppPalette.light.outline);
    });
  });

  group('推导令牌', () {
    test('亮面的选区描边就是强调色本身', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        expect(preset.light.selectionEdge, preset.light.accent, reason: preset.id.name);
      }
    });

    test('暗面的选区描边比强调色更暗（0.86 倍明度）', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        final double edge = HSLColor.fromColor(preset.dark.selectionEdge).lightness;
        final double accent = HSLColor.fromColor(preset.dark.accent).lightness;
        expect(edge, lessThan(accent), reason: preset.id.name);
        expect(edge, closeTo(accent * 0.86, 0.001), reason: preset.id.name);
      }
    });

    test('影子与遮罩按明暗分档', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        expect(preset.light.shadow, const Color(0x14000000), reason: preset.id.name);
        expect(preset.dark.shadow, const Color(0x66000000), reason: preset.id.name);
        expect(preset.light.overlay, const Color(0x33000000), reason: preset.id.name);
        expect(preset.dark.overlay, const Color(0x99000000), reason: preset.id.name);
      }
    });

    test('推导规则是可复用的函数，不藏在构造函数里', () {
      expect(selectionEdgeFor(const Color(0xFF4A56C4), Brightness.light), const Color(0xFF4A56C4));
      expect(shadowFor(Brightness.light), const Color(0x14000000));
      expect(overlayFor(Brightness.dark), const Color(0x99000000));
    });
  });

  group('CustomPalette 编解码', () {
    test('往返后 25×2 全等', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        final CustomPalette seeded = ThemePresets.seed(preset.id);
        final CustomPalette decoded = CustomPalette.decode(seeded.raw)!;
        expectSameBoard(decoded.light, preset.light, reason: preset.id.name);
        expectSameBoard(decoded.dark, preset.dark, reason: preset.id.name);
      }
    });

    test('alpha 字节无损', () {
      final CustomPalette decoded =
          CustomPalette.decode(ThemePresets.seed(ThemePresetId.midnight).raw)!;
      expect(decoded.light.selection, const Color(0x334A56C4));
      expect(decoded.dark.selection, const Color(0x4D8B94F2));
      expect(decoded.light.shadow, const Color(0x14000000));
      expect(decoded.dark.overlay, const Color(0x99000000));
    });

    test('6 位 hex 视为不透明', () {
      final CustomPalette decoded = CustomPalette.decode(
        '{"v":1,"light":{"canvas":"f7f7f5"},"dark":{"canvas":"151514"}}',
      )!;
      expect(decoded.light.canvas, const Color(0xFFF7F7F5));
      expect(decoded.dark.canvas, const Color(0xFF151514));
      // 没写进 JSON 的键兜石墨素白，而不是崩掉。
      expect(decoded.light.rule, AppPalette.light.rule);
      expect(decoded.dark.accent, AppPalette.dark.accent);
    });

    test('前向兼容：未知键忽略、缺失键兜默认、v 只是迁移钩子', () {
      final CustomPalette decoded = CustomPalette.decode(
        '{"v":2,"light":{"canvas":"ff010203","futureToken":"ff040506"},"dark":{}}',
      )!;
      expect(decoded.light.canvas, const Color(0xFF010203));
      expect(decoded.light.rule, AppPalette.light.rule);
      expect(decoded.dark.canvas, AppPalette.dark.canvas);
    });

    test('解不出来就返回 null，不抛异常', () {
      expect(CustomPalette.decode(null), isNull);
      expect(CustomPalette.decode(''), isNull);
      expect(CustomPalette.decode('   '), isNull);
      expect(CustomPalette.decode('not json'), isNull);
      expect(CustomPalette.decode('{}'), isNull);
      expect(CustomPalette.decode('[1,2]'), isNull);
      // light 在但 dark 不是一张表。
      expect(CustomPalette.decode('{"light":{},"dark":4}'), isNull);
    });

    test('withToken 只动指定那一面', () {
      final CustomPalette board = ThemePresets.seed(ThemePresetId.vivid);
      final CustomPalette next =
          board.withToken(Brightness.dark, AppPaletteToken.canvas, const Color(0xFF010203));
      expect(next.dark.canvas, const Color(0xFF010203));
      expect(next.light.canvas, board.light.canvas);
      // raw 必须跟着走，否则备忘键与脏检查都会说谎。
      expect(next.raw, isNot(board.raw));
      expect(CustomPalette.decode(next.raw)!.dark.canvas, const Color(0xFF010203));
    });
  });

  group('resolve', () {
    test('没有自定义层时 custom 也只是石墨素白', () {
      expectSameBoard(
        ThemePresets.resolve(
          preset: ThemePresetId.custom,
          custom: null,
          brightness: Brightness.dark,
        ),
        AppPalette.dark,
      );
    });

    test('选了 built-in 就绝不被残留的自定义层顶掉', () {
      final CustomPalette stale = ThemePresets.seed(ThemePresetId.midnight)
          .withToken(Brightness.light, AppPaletteToken.canvas, const Color(0xFF123456));
      expectSameBoard(
        ThemePresets.resolve(
          preset: ThemePresetId.vivid,
          custom: stale,
          brightness: Brightness.light,
        ),
        ThemePresets.of(ThemePresetId.vivid).light,
      );
    });

    test('custom + 有层 → 用那一层', () {
      final CustomPalette board = ThemePresets.seed(ThemePresetId.midnight);
      expectSameBoard(
        ThemePresets.resolve(
          preset: ThemePresetId.custom,
          custom: board,
          brightness: Brightness.dark,
        ),
        ThemePresets.of(ThemePresetId.midnight).dark,
      );
    });

    test('seed 出来的两块板子与源方案逐令牌相等', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        final CustomPalette seeded = ThemePresets.seed(preset.id);
        expectSameBoard(seeded.paletteFor(Brightness.light), preset.light);
        expectSameBoard(seeded.paletteFor(Brightness.dark), preset.dark);
      }
    });
  });
}
