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
    test('三套内置，顺序即选择器顺序，默认是曜石', () {
      expect(ThemePresetId.values.length, 3);
      expect(ThemePresets.builtIn.length, 3);
      expect(ThemePresets.builtIn.first.id, ThemePresetId.fallback);
      expect(ThemePresetId.fallback, ThemePresetId.obsidian);
      // 目录顺序与枚举顺序一致，选择器不会漏格子。
      expect(
        ThemePresets.builtIn.map((ThemePreset p) => p.id).toList(),
        ThemePresetId.values,
      );
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

    test('曜石就是 AppPalette.light / dark', () {
      expectSameBoard(ThemePresets.of(ThemePresetId.obsidian).light, AppPalette.light);
      expectSameBoard(ThemePresets.of(ThemePresetId.obsidian).dark, AppPalette.dark);
    });

    test('of 按 id 取到对应那一套', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        expect(ThemePresets.of(preset.id).id, preset.id);
      }
    });
  });

  group('令牌表', () {
    test('25 个，线格式键两两不重复', () {
      expect(AppPaletteToken.values.length, 25);
      final Set<String> names =
          AppPaletteToken.values.map((AppPaletteToken t) => t.name).toSet();
      expect(names.length, 25);
    });

    test('三档：简单 6 个、普通 12 个，剩下的由高级放出', () {
      expect(AppPaletteToken.simple.length, 6);
      expect(AppPaletteToken.normal.length, 12);
      // 简单是普通的真子集，普通是全部 25 个的真子集。
      expect(
        AppPaletteToken.normal.toSet().containsAll(AppPaletteToken.simple),
        isTrue,
      );
      final Set<AppPaletteToken> rest = AppPaletteToken.values
          .toSet()
          .difference(AppPaletteToken.normal.toSet());
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

  group('PaletteOverride 编解码', () {
    test('往返后 25×2 全等', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        final PaletteOverride seeded = ThemePresets.seed(preset.id);
        final PaletteOverride decoded = PaletteOverride.decode(
          seeded.raw,
          base: preset.id,
        )!;
        expectSameBoard(decoded.light, preset.light, reason: preset.id.name);
        expectSameBoard(decoded.dark, preset.dark, reason: preset.id.name);
      }
    });

    test('alpha 字节无损', () {
      final PaletteOverride decoded = PaletteOverride.decode(
        ThemePresets.seed(ThemePresetId.midnight).raw,
        base: ThemePresetId.midnight,
      )!;
      expect(decoded.light.selection, const Color(0x334A56C4));
      expect(decoded.dark.selection, const Color(0x4D8B94F2));
      expect(decoded.light.shadow, const Color(0x14000000));
      expect(decoded.dark.overlay, const Color(0x99000000));
    });

    test('6 位 hex 视为不透明', () {
      final PaletteOverride decoded = PaletteOverride.decode(
        '{"v":1,"light":{"canvas":"f7f7f5"},"dark":{"canvas":"151514"}}',
        base: ThemePresetId.obsidian,
      )!;
      expect(decoded.light.canvas, const Color(0xFFF7F7F5));
      expect(decoded.dark.canvas, const Color(0xFF151514));
      // 没写进 JSON 的键兜这一套自己的出厂色，而不是崩掉。
      expect(decoded.light.rule, AppPalette.light.rule);
      expect(decoded.dark.accent, AppPalette.dark.accent);
    });

    test('缺失的键兜的是所属预设的出厂色，不是曜石', () {
      final PaletteOverride decoded = PaletteOverride.decode(
        '{"light":{"canvas":"ff010203"},"dark":{}}',
        base: ThemePresetId.vivid,
      )!;
      expect(decoded.light.canvas, const Color(0xFF010203));
      expect(decoded.light.rule, ThemePresets.of(ThemePresetId.vivid).light.rule);
      expect(decoded.dark.canvas, ThemePresets.of(ThemePresetId.vivid).dark.canvas);
    });

    test('前向兼容：未知键忽略、v 只是迁移钩子', () {
      final PaletteOverride decoded = PaletteOverride.decode(
        '{"v":2,"light":{"canvas":"ff010203","futureToken":"ff040506"},"dark":{}}',
        base: ThemePresetId.obsidian,
      )!;
      expect(decoded.light.canvas, const Color(0xFF010203));
      expect(decoded.light.rule, AppPalette.light.rule);
      expect(decoded.dark.canvas, AppPalette.dark.canvas);
    });

    test('解不出来就返回 null，不抛异常', () {
      for (final String? raw in <String?>[
        null,
        '',
        '   ',
        'not json',
        '{}',
        '[1,2]',
        '{"light":{},"dark":4}',
      ]) {
        expect(
          PaletteOverride.decode(raw, base: ThemePresetId.obsidian),
          isNull,
          reason: raw,
        );
      }
    });

    test('withToken 只动指定那一面', () {
      final PaletteOverride board = ThemePresets.seed(ThemePresetId.vivid);
      final PaletteOverride next = board.withToken(
        Brightness.dark,
        AppPaletteToken.canvas,
        const Color(0xFF010203),
      );
      expect(next.dark.canvas, const Color(0xFF010203));
      expect(next.light.canvas, board.light.canvas);
      // raw 必须跟着走，否则备忘键与脏检查都会说谎。
      expect(next.raw, isNot(board.raw));
      expect(
        PaletteOverride.decode(next.raw, base: ThemePresetId.vivid)!.dark.canvas,
        const Color(0xFF010203),
      );
    });
  });

  group('resolve', () {
    test('没有覆盖层时用内置色板', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        expectSameBoard(
          ThemePresets.resolve(
            preset: preset.id,
            override: null,
            brightness: Brightness.light,
          ),
          preset.light,
          reason: preset.id.name,
        );
        expectSameBoard(
          ThemePresets.resolve(
            preset: preset.id,
            override: null,
            brightness: Brightness.dark,
          ),
          preset.dark,
          reason: preset.id.name,
        );
      }
    });

    test('有覆盖层时那一层说了算', () {
      final PaletteOverride board = ThemePresets.seed(ThemePresetId.midnight);
      expectSameBoard(
        ThemePresets.resolve(
          preset: ThemePresetId.midnight,
          override: board,
          brightness: Brightness.dark,
        ),
        ThemePresets.of(ThemePresetId.midnight).dark,
      );

      final PaletteOverride edited = board.withToken(
        Brightness.light,
        AppPaletteToken.canvas,
        const Color(0xFF123456),
      );
      expect(
        ThemePresets.resolve(
          preset: ThemePresetId.midnight,
          override: edited,
          brightness: Brightness.light,
        ).canvas,
        const Color(0xFF123456),
      );
    });

    test('seed 出来的两块板子与源方案逐令牌相等', () {
      for (final ThemePreset preset in ThemePresets.builtIn) {
        final PaletteOverride seeded = ThemePresets.seed(preset.id);
        expectSameBoard(seeded.paletteFor(Brightness.light), preset.light);
        expectSameBoard(seeded.paletteFor(Brightness.dark), preset.dark);
      }
    });
  });
}
