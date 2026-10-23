import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/app_enums.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/theme_presets.dart';
import 'package:nrs/state/settings_controller.dart';

void main() {
  Future<({SettingsController settings, SharedPreferences prefs})> load([
    Map<String, Object>? seed,
  ]) async {
    SharedPreferences.setMockInitialValues(seed ?? <String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (settings: SettingsController(prefs), prefs: prefs);
  }

  group('默认值', () {
    test('空 prefs → 石墨素白 / 跟随系统 / 没有自定义层', () async {
      final (:settings, :prefs) = await load();
      expect(settings.themePreset, ThemePresetId.graphite);
      expect(settings.theme, ThemePreference.system);
      expect(settings.customPalette, isNull);
      expect(settings.paletteFor(Brightness.light).accent, AppPalette.light.accent);
      expect(settings.paletteFor(Brightness.dark).canvas, AppPalette.dark.canvas);
    });

    test('老用户的明暗偏好留着，退役的琥珀色板一点都不留', () async {
      final (:settings, :prefs) = await load(<String, Object>{'nrs.theme': 'dark'});
      expect(settings.theme, ThemePreference.dark);
      expect(settings.themePreset, ThemePresetId.graphite);
      // 25 个令牌逐个等于石墨素白 —— 比「不等于某个琥珀值」更强的检查。
      for (final AppPaletteToken t in AppPaletteToken.values) {
        expect(
          settings.paletteFor(Brightness.light).colorOf(t),
          AppPalette.light.colorOf(t),
          reason: t.name,
        );
        expect(
          settings.paletteFor(Brightness.dark).colorOf(t),
          AppPalette.dark.colorOf(t),
          reason: t.name,
        );
      }
    });
  });

  group('themePreset', () {
    test('set / get 往返，同值不再通知', () async {
      final (:settings, :prefs) = await load(<String, Object>{});

      int notifications = 0;
      settings.addListener(() => notifications++);

      settings.themePreset = ThemePresetId.graphite; // 已经是它
      expect(notifications, 0);
      expect(prefs.containsKey('nrs.themePreset'), isFalse);

      settings.themePreset = ThemePresetId.midnight;
      expect(notifications, 1);
      expect(prefs.getString('nrs.themePreset'), 'midnight');
      expect(settings.paletteFor(Brightness.light).accent,
          ThemePresets.of(ThemePresetId.midnight).light.accent);
    });

    test('认不出的串兜底，且不改写存储（好让降级仍然读得懂）', () async {
      final (:settings, :prefs) =
          await load(<String, Object>{'nrs.themePreset': 'amber'});
      expect(settings.themePreset, ThemePresetId.graphite);
      expect(prefs.getString('nrs.themePreset'), 'amber');
    });
  });

  group('自定义层的预览 / 提交分工', () {
    test('preview 立刻生效但不落盘，commit 才写', () async {
      final (:settings, :prefs) = await load();
      settings.themePreset = ThemePresetId.custom;

      final CustomPalette board = ThemePresets.seed(ThemePresetId.vivid);
      settings.previewCustomPalette(board);

      expect(settings.paletteFor(Brightness.light).canvas,
          ThemePresets.of(ThemePresetId.vivid).light.canvas);
      expect(settings.customPalette!.light.canvas, board.light.canvas);
      expect(prefs.getString('nrs.themeCustom'), isNull);

      settings.commitCustomPalette(board);
      expect(prefs.getString('nrs.themeCustom'), board.raw);
    });

    test('commit 同一个 raw 不写盘也不再通知', () async {
      final (:settings, :prefs) = await load();
      settings.themePreset = ThemePresetId.custom;
      final CustomPalette board = ThemePresets.seed(ThemePresetId.vivid);
      settings.commitCustomPalette(board);

      int notifications = 0;
      settings.addListener(() => notifications++);
      settings.commitCustomPalette(board);
      expect(notifications, 0);
      expect(prefs.getString('nrs.themeCustom'), board.raw);
    });

    test('preview 的草稿压过盘上的值，直到 commit 把它清掉', () async {
      final (:settings, :prefs) = await load();
      settings.themePreset = ThemePresetId.custom;

      final CustomPalette stored = ThemePresets.seed(ThemePresetId.vivid);
      settings.commitCustomPalette(stored);

      final CustomPalette draft = stored.withToken(
        Brightness.light,
        AppPaletteToken.canvas,
        const Color(0xFF010203),
      );
      settings.previewCustomPalette(draft);
      expect(settings.paletteFor(Brightness.light).canvas, const Color(0xFF010203));
      expect(prefs.getString('nrs.themeCustom'), stored.raw);

      settings.commitCustomPalette(draft);
      expect(prefs.getString('nrs.themeCustom'), draft.raw);
      expect(settings.paletteFor(Brightness.light).canvas, const Color(0xFF010203));
    });

    test('themeSignature 跟着草稿与落盘一起变', () async {
      final (:settings, :prefs) = await load();
      final String before = settings.themeSignature;

      final CustomPalette board = ThemePresets.seed(ThemePresetId.midnight);
      settings.previewCustomPalette(board);
      expect(settings.themeSignature, isNot(before));

      settings.commitCustomPalette(board);
      expect(
        settings.themeSignature,
        '${ThemePresetId.graphite.name}|${board.raw}',
      );
    });
  });

  group('标签会话', () {
    test('没存过 → null，和「标签全关了」的空列表区分开', () async {
      final (:settings, :prefs) = await load();
      expect(settings.sessionTabs, isNull);
      expect(settings.sessionSelectedTab, isNull);
    });

    test('四个标签和选中的第四个一起往返，空标签栏也原样记住', () async {
      final (:settings, :prefs) = await load();

      settings.saveSession(<String>['a', 'b', 'c', 'd'], 'd');
      expect(settings.sessionTabs, <String>['a', 'b', 'c', 'd']);
      expect(settings.sessionSelectedTab, 'd');

      settings.saveSession(const <String>[], null);
      expect(settings.sessionTabs, isEmpty);
      expect(
        prefs.containsKey('nrs.sessionSelected'),
        isFalse,
        reason: '没有选中页就删掉 key，别留个空串冒充选中',
      );
    });
  });

  group('restoreTheme', () {
    test('两个 key 一起回滚，一颗残留都不留', () async {
      final (:settings, :prefs) = await load();
      final ({ThemePresetId preset, CustomPalette? custom}) snapshot =
          (preset: settings.themePreset, custom: settings.customPalette);

      settings.themePreset = ThemePresetId.custom;
      settings.commitCustomPalette(ThemePresets.seed(ThemePresetId.midnight));
      expect(prefs.containsKey('nrs.themeCustom'), isTrue);
      expect(prefs.getString('nrs.themePreset'), 'custom');

      settings.restoreTheme(snapshot);

      expect(settings.themePreset, ThemePresetId.fallback);
      // 默认值不写盘：删掉 key 而不是写 'graphite'。
      expect(prefs.containsKey('nrs.themePreset'), isFalse);
      expect(prefs.containsKey('nrs.themeCustom'), isFalse);
      expect(settings.customPalette, isNull);
      expect(settings.paletteFor(Brightness.light).accent, AppPalette.light.accent);
    });

    test('回滚到「进入前就有一套自定义层」的那一支', () async {
      final (:settings, :prefs) = await load();
      final CustomPalette original = ThemePresets.seed(ThemePresetId.vivid);
      settings.themePreset = ThemePresetId.custom;
      settings.commitCustomPalette(original);

      final ({ThemePresetId preset, CustomPalette? custom}) snapshot =
          (preset: settings.themePreset, custom: settings.customPalette);
      settings.commitCustomPalette(original.withToken(
        Brightness.dark,
        AppPaletteToken.canvas,
        const Color(0xFF010203),
      ));
      expect(settings.paletteFor(Brightness.dark).canvas, const Color(0xFF010203));

      settings.restoreTheme(snapshot);
      expect(settings.themePreset, ThemePresetId.custom);
      expect(prefs.getString('nrs.themeCustom'), original.raw);
      expect(settings.paletteFor(Brightness.dark).canvas, original.dark.canvas);
    });

    test('草稿也会被回滚清掉——preview 之后取消不应该留下内存里的层', () async {
      final (:settings, :prefs) = await load();
      final ({ThemePresetId preset, CustomPalette? custom}) snapshot =
          (preset: settings.themePreset, custom: settings.customPalette);
      settings.previewCustomPalette(ThemePresets.seed(ThemePresetId.vivid));
      settings.restoreTheme(snapshot);
      expect(settings.customPalette, isNull);
    });
  });
}
