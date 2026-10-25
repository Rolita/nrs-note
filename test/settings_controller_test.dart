import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/app_enums.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
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
    test('空 prefs → 曜石 / 跟随系统 / 三套都没有覆盖层', () async {
      final (:settings, :prefs) = await load();
      expect(settings.themePreset, ThemePresetId.obsidian);
      expect(settings.theme, ThemePreference.system);
      for (final ThemePresetId id in ThemePresetId.values) {
        expect(settings.overrideFor(id), isNull, reason: id.name);
      }
      expect(settings.paletteFor(Brightness.light).accent, AppPalette.light.accent);
      expect(settings.paletteFor(Brightness.dark).canvas, AppPalette.dark.canvas);
    });

    test('老用户的明暗偏好留着，退役的琥珀色板一点都不留', () async {
      final (:settings, :prefs) = await load(<String, Object>{'nrs.theme': 'dark'});
      expect(settings.theme, ThemePreference.dark);
      expect(settings.themePreset, ThemePresetId.obsidian);
      // 25 个令牌逐个等于曜石 —— 比「不等于某个琥珀值」更强的检查。
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

      settings.themePreset = ThemePresetId.obsidian; // 已经是它
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
      expect(settings.themePreset, ThemePresetId.obsidian);
      expect(prefs.getString('nrs.themePreset'), 'amber');
    });
  });

  group('预设覆盖层的预览 / 提交分工', () {
    PaletteOverride edited(ThemePresetId id, Color canvas) =>
        ThemePresets.seed(id).withToken(
          Brightness.light,
          AppPaletteToken.canvas,
          canvas,
        );

    test('preview 立刻生效但不落盘，commit 才写', () async {
      final (:settings, :prefs) = await load();
      settings.themePreset = ThemePresetId.midnight;

      final PaletteOverride board = edited(ThemePresetId.midnight,
          const Color(0xFF010203));
      settings.previewOverride(ThemePresetId.midnight, board);

      expect(settings.paletteFor(Brightness.light).canvas,
          const Color(0xFF010203));
      expect(settings.overrideFor(ThemePresetId.midnight)!.light.canvas,
          const Color(0xFF010203));
      expect(prefs.getString('nrs.themeOverride.midnight'), isNull);

      settings.commitOverride(ThemePresetId.midnight, board);
      expect(prefs.getString('nrs.themeOverride.midnight'), board.raw);
    });

    test('commit 同一个 raw 不写盘也不再通知', () async {
      final (:settings, :prefs) = await load();
      final PaletteOverride board = edited(ThemePresetId.obsidian,
          const Color(0xFF010203));
      settings.commitOverride(ThemePresetId.obsidian, board);

      int notifications = 0;
      settings.addListener(() => notifications++);
      settings.commitOverride(ThemePresetId.obsidian, board);
      expect(notifications, 0);
      expect(prefs.getString('nrs.themeOverride.obsidian'), board.raw);
    });

    test('preview 的草稿压过盘上的值，直到 commit 把它清掉', () async {
      final (:settings, :prefs) = await load();
      settings.themePreset = ThemePresetId.vivid;

      final PaletteOverride stored = edited(ThemePresetId.vivid,
          const Color(0xFF010203));
      settings.commitOverride(ThemePresetId.vivid, stored);

      final PaletteOverride draft = stored.withToken(
        Brightness.light,
        AppPaletteToken.canvas,
        const Color(0xFF040506),
      );
      settings.previewOverride(ThemePresetId.vivid, draft);
      expect(settings.paletteFor(Brightness.light).canvas,
          const Color(0xFF040506));
      expect(prefs.getString('nrs.themeOverride.vivid'), stored.raw);

      settings.commitOverride(ThemePresetId.vivid, draft);
      expect(prefs.getString('nrs.themeOverride.vivid'), draft.raw);
      expect(settings.paletteFor(Brightness.light).canvas,
          const Color(0xFF040506));
    });

    test('三套预设各存各的，改一套绝不串到另一套', () async {
      final (:settings, :prefs) = await load();

      final PaletteOverride board = edited(ThemePresetId.obsidian,
          const Color(0xFF010203));
      settings.commitOverride(ThemePresetId.obsidian, board);
      expect(prefs.getString('nrs.themeOverride.midnight'), isNull);
      expect(settings.overrideFor(ThemePresetId.midnight), isNull);

      settings.themePreset = ThemePresetId.midnight;
      expect(
        settings.paletteFor(Brightness.light).canvas,
        ThemePresets.of(ThemePresetId.midnight).light.canvas,
        reason: '曜石的覆盖层不该出现在午夜靛里',
      );

      settings.themePreset = ThemePresetId.obsidian;
      expect(settings.paletteFor(Brightness.light).canvas,
          const Color(0xFF010203));
    });

    test('clearOverride 只把那一套还原成出厂色', () async {
      final (:settings, :prefs) = await load();
      settings.commitOverride(
        ThemePresetId.midnight,
        edited(ThemePresetId.midnight, const Color(0xFF010203)),
      );
      settings.commitOverride(
        ThemePresetId.vivid,
        edited(ThemePresetId.vivid, const Color(0xFF040506)),
      );

      settings.clearOverride(ThemePresetId.midnight);

      expect(settings.overrideFor(ThemePresetId.midnight), isNull);
      expect(prefs.containsKey('nrs.themeOverride.midnight'), isFalse);
      expect(prefs.containsKey('nrs.themeOverride.vivid'), isTrue);
    });

    test('themeSignature 跟着草稿与落盘一起变', () async {
      final (:settings, :prefs) = await load();
      final String before = settings.themeSignature;

      final PaletteOverride board = edited(ThemePresetId.obsidian,
          const Color(0xFF010203));
      settings.previewOverride(ThemePresetId.obsidian, board);
      expect(settings.themeSignature, isNot(before));

      settings.commitOverride(ThemePresetId.obsidian, board);
      expect(
        settings.themeSignature,
        '${ThemePresetId.obsidian.name}|${board.raw}',
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
    PaletteOverride board(ThemePresetId id, Color canvas) =>
        ThemePresets.seed(id).withToken(
          Brightness.light,
          AppPaletteToken.canvas,
          canvas,
        );

    test('预设与那一套的覆盖层一起回滚，一颗残留都不留', () async {
      final (:settings, :prefs) = await load();
      final ({ThemePresetId preset, PaletteOverride? override}) snapshot =
          (preset: settings.themePreset, override: settings.overrideFor(settings.themePreset));

      settings.commitOverride(
        ThemePresetId.obsidian,
        board(ThemePresetId.obsidian, const Color(0xFF010203)),
      );
      expect(prefs.containsKey('nrs.themeOverride.obsidian'), isTrue);
      expect(settings.paletteFor(Brightness.light).canvas,
          const Color(0xFF010203));

      settings.restoreTheme(snapshot);

      expect(settings.themePreset, ThemePresetId.fallback);
      // 默认值不写盘：删掉 key 而不是写 'obsidian'。
      expect(prefs.containsKey('nrs.themePreset'), isFalse);
      expect(prefs.containsKey('nrs.themeOverride.obsidian'), isFalse);
      expect(settings.overrideFor(ThemePresetId.obsidian), isNull);
      expect(settings.paletteFor(Brightness.light).accent, AppPalette.light.accent);
    });

    test('回滚到「进入前就有一套覆盖层」的那一支', () async {
      final (:settings, :prefs) = await load();
      settings.themePreset = ThemePresetId.vivid;
      final PaletteOverride original =
          board(ThemePresetId.vivid, const Color(0xFF010203));
      settings.commitOverride(ThemePresetId.vivid, original);

      final ({ThemePresetId preset, PaletteOverride? override}) snapshot =
          (preset: settings.themePreset, override: settings.overrideFor(settings.themePreset));
      settings.commitOverride(
        ThemePresetId.vivid,
        original.withToken(
          Brightness.dark,
          AppPaletteToken.canvas,
          const Color(0xFF040506),
        ),
      );
      expect(settings.paletteFor(Brightness.dark).canvas,
          const Color(0xFF040506));

      settings.restoreTheme(snapshot);
      expect(settings.themePreset, ThemePresetId.vivid);
      expect(prefs.getString('nrs.themeOverride.vivid'), original.raw);
      expect(settings.overrideFor(ThemePresetId.vivid)!.dark.canvas,
          original.dark.canvas);
    });

    test('草稿也会被回滚清掉——preview 之后取消不应该留下内存里的层', () async {
      final (:settings, :prefs) = await load();
      final ({ThemePresetId preset, PaletteOverride? override}) snapshot =
          (preset: settings.themePreset, override: settings.overrideFor(settings.themePreset));
      settings.previewOverride(
        ThemePresetId.obsidian,
        board(ThemePresetId.obsidian, const Color(0xFF010203)),
      );
      settings.restoreTheme(snapshot);
      expect(settings.overrideFor(ThemePresetId.obsidian), isNull);
    });
  });

  group('表格面板', () {
    test('默认关闭，宽度取面板默认值', () async {
      final (:settings, :prefs) = await load();
      expect(settings.tablePanelVisible, isFalse);
      expect(settings.tablePanelWidth, AppLayout.tablePanelWidth);
    });

    test('开一个就关掉另一个：大纲与表格共用最右栏', () async {
      final (:settings, :prefs) = await load();
      expect(settings.outlineVisible, isTrue);

      settings.tablePanelVisible = true;
      expect(settings.tablePanelVisible, isTrue);
      expect(settings.outlineVisible, isFalse);
      expect(prefs.getBool('nrs.tablePanelVisible'), isTrue);
      expect(prefs.getBool('nrs.outlineVisible'), isFalse);

      settings.outlineVisible = true;
      expect(settings.outlineVisible, isTrue);
      expect(settings.tablePanelVisible, isFalse);
      expect(prefs.getBool('nrs.tablePanelVisible'), isFalse);
    });

    test('宽度夹在 220–420，同值不再通知', () async {
      final (:settings, :prefs) = await load();
      int notifications = 0;
      settings.addListener(() => notifications++);

      settings.tablePanelWidth = 1000;
      expect(settings.tablePanelWidth, AppLayout.tablePanelMaxWidth);
      expect(notifications, 1);

      settings.tablePanelWidth = 10;
      expect(settings.tablePanelWidth, AppLayout.tablePanelMinWidth);
      expect(notifications, 2);

      settings.tablePanelWidth = AppLayout.tablePanelMinWidth;
      expect(notifications, 2, reason: '同值不再通知');
      expect(prefs.containsKey('nrs.tablePanelWidth'), isTrue);
    });
  });

  group('图片面板', () {
    test('默认关闭，宽度取面板默认值', () async {
      final (:settings, :prefs) = await load();
      expect(settings.imagePanelVisible, isFalse);
      expect(settings.imagePanelWidth, AppLayout.imagePanelWidth);
    });

    test('三个面板共用最右栏：开一个就关掉另外两个', () async {
      final (:settings, :prefs) = await load();
      expect(settings.outlineVisible, isTrue);

      settings.imagePanelVisible = true;
      expect(settings.imagePanelVisible, isTrue);
      expect(settings.outlineVisible, isFalse);
      expect(settings.tablePanelVisible, isFalse);

      settings.tablePanelVisible = true;
      expect(settings.tablePanelVisible, isTrue);
      expect(settings.imagePanelVisible, isFalse);
      expect(prefs.getBool('nrs.imagePanelVisible'), isFalse);

      settings.imagePanelVisible = true;
      expect(settings.imagePanelVisible, isTrue);
      expect(settings.tablePanelVisible, isFalse);

      settings.outlineVisible = true;
      expect(settings.outlineVisible, isTrue);
      expect(settings.imagePanelVisible, isFalse);
      expect(prefs.getBool('nrs.imagePanelVisible'), isFalse);
    });

    test('宽度夹在 220–420，同值不再通知', () async {
      final (:settings, :prefs) = await load();
      int notifications = 0;
      settings.addListener(() => notifications++);

      settings.imagePanelWidth = 1000;
      expect(settings.imagePanelWidth, AppLayout.imagePanelMaxWidth);
      expect(notifications, 1);

      settings.imagePanelWidth = 10;
      expect(settings.imagePanelWidth, AppLayout.imagePanelMinWidth);
      expect(notifications, 2);

      settings.imagePanelWidth = AppLayout.imagePanelMinWidth;
      expect(notifications, 2, reason: '同值不再通知');
      expect(prefs.containsKey('nrs.imagePanelWidth'), isTrue);
    });
  });
}
