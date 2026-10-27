import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/state/settings_controller.dart';

void main() {
  Future<({SettingsController settings, SharedPreferences prefs})> load([
    Map<String, Object>? seed,
  ]) async {
    SharedPreferences.setMockInitialValues(seed ?? <String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (settings: SettingsController(prefs), prefs: prefs);
  }

  group('色板', () {
    test('无论 prefs 里写了什么，色板恒为午夜靛', () async {
      final (:settings, :prefs) = await load(<String, Object>{
        // 老版本留下的键：现在一概不认，也不改写存储。
        'nrs.theme': 'light',
        'nrs.themePreset': 'obsidian',
        'nrs.themeOverride.midnight': '{"light":{"canvas":4278190335}}',
      });
      expect(settings.palette, AppPalette.midnight);
      expect(prefs.getString('nrs.theme'), 'light');
    });

    test('午夜靛是深色板，关键令牌与设计稿一致', () async {
      final (:settings, :prefs) = await load();
      final AppPalette p = settings.palette;
      expect(p.brightness, Brightness.dark);
      expect(p.canvas, const Color(0xFF0E0F13));
      expect(p.sidebar, const Color(0xFF131419));
      expect(p.surface, const Color(0xFF17181E));
      expect(p.accent, const Color(0xFF8B94F2));
      expect(p.textPrimary, const Color(0xFFE6E8EF));
      // 半透明的只有选区 / 阴影 / 遮罩三处，其它必须实色。
      expect(p.selection.a, lessThan(1.0));
      expect(p.shadow.a, lessThan(1.0));
      expect(p.overlay.a, lessThan(1.0));
      expect(p.canvas.a, 1.0);
      expect(p.surfaceRaised.a, 1.0);
      expect(p.textPrimary.a, 1.0);
      expect(p.accent.a, 1.0);
    });

    test('正文压得住画布：对比度够 7:1，不是灰字堆', () async {
      final AppPalette p = AppPalette.midnight;
      expect(
        AppPalette.contrastRatio(p.textPrimary, p.canvas),
        greaterThan(7.0),
      );
      expect(
        AppPalette.contrastRatio(p.textSecondary, p.canvas),
        greaterThan(4.5),
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

  group('表格面板', () {
    test('默认关闭，宽度取最右栏的默认值', () async {
      final (:settings, :prefs) = await load();
      expect(settings.tablePanelVisible, isFalse);
      expect(settings.rightPanelWidth, AppLayout.rightPanelWidth);
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

  });

  group('图片面板', () {
    test('默认关闭，宽度取最右栏的默认值', () async {
      final (:settings, :prefs) = await load();
      expect(settings.imagePanelVisible, isFalse);
      expect(settings.rightPanelWidth, AppLayout.rightPanelWidth);
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

  });

  group('最右栏宽度', () {
    test('三块面板共用一份宽度，拖哪一块都是同一个值', () async {
      final (:settings, :prefs) = await load();
      expect(settings.rightPanelWidth, AppLayout.rightPanelWidth);

      int notifications = 0;
      settings.addListener(() => notifications++);

      settings.rightPanelWidth = 1000;
      expect(settings.rightPanelWidth, AppLayout.rightPanelMaxWidth);
      expect(notifications, 1);

      settings.rightPanelWidth = 10;
      expect(settings.rightPanelWidth, AppLayout.rightPanelMinWidth);
      expect(notifications, 2);

      settings.rightPanelWidth = AppLayout.rightPanelMinWidth;
      expect(notifications, 2, reason: '同值不再通知');
      expect(
        prefs.getDouble('nrs.rightPanelWidth'),
        AppLayout.rightPanelMinWidth,
      );
      // 只有一条记录：不再按面板各存一份。
      expect(prefs.containsKey('nrs.outlineWidth'), isFalse);
      expect(prefs.containsKey('nrs.tablePanelWidth'), isFalse);
      expect(prefs.containsKey('nrs.imagePanelWidth'), isFalse);
    });

    test('第一次读取时把旧的三条宽度捡回来', () async {
      // 升级前用户把大纲拖到 300：合并之后那一列不该跳回默认值。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'nrs.outlineWidth': 300.0,
        'nrs.tablePanelWidth': 260.0,
      });
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final SettingsController settings = SettingsController(prefs);
      expect(settings.rightPanelWidth, 300);

      // 写过一次之后就以新键为准，旧键不再参与。
      settings.rightPanelWidth = 240;
      expect(settings.rightPanelWidth, 240);
    });
  });
}
