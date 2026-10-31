import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/app_enums.dart';
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

    test('石墨色板是深色板，关键令牌与视觉稿一致', () async {
      final (:settings, :prefs) = await load();
      final AppPalette p = settings.palette;
      expect(p.brightness, Brightness.dark);
      expect(p.canvas, const Color(0xFF0F0F10));
      expect(p.sidebar, const Color(0xFF1E1F21));
      expect(p.surface, const Color(0xFF151516));
      expect(p.accent, const Color(0xFF8B94F2));
      expect(p.textPrimary, const Color(0xFFECEDEF));
      // 选中是一层中性淡底，比悬停再亮一档；强调色只留给正文。
      expect(p.rowSelected, const Color(0xFF34353A));
      expect(p.surfaceRaised, const Color(0xFF28292C));
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

  group('窗口不透明度', () {
    test('默认 90%，改过之后读回来', () async {
      final (:settings, :prefs) = await load();
      expect(settings.windowOpacity, 0.9);

      settings.windowOpacity = 0.75;
      expect(settings.windowOpacity, 0.75);
      expect(prefs.getDouble('nrs.windowOpacity'), 0.75);
    });

    test('夹在 50%–100% 之间；同值不再通知', () async {
      final (:settings, :prefs) = await load();
      int notifications = 0;
      settings.addListener(() => notifications++);

      // 下限 50%：再往下透到看不清，不给出那个选项。
      settings.windowOpacity = 0.2;
      expect(settings.windowOpacity, SettingsController.windowOpacityMin);
      expect(SettingsController.windowOpacityMin, 0.5);
      settings.windowOpacity = 2;
      expect(settings.windowOpacity, SettingsController.windowOpacityMax);
      expect(notifications, 2);

      settings.windowOpacity = 1;
      expect(notifications, 2, reason: '同值再设一遍不该通知');
    });
  });

  group('外观', () {
    test('默认实色石墨；切到壁纸会落盘', () async {
      final (:settings, :prefs) = await load();
      expect(settings.appearance, ShellAppearance.graphite);

      settings.appearance = ShellAppearance.wallpaper;
      expect(settings.appearance, ShellAppearance.wallpaper);
      expect(prefs.getString('nrs.shellAppearance'), 'wallpaper');

      settings.appearance = ShellAppearance.graphite;
      expect(settings.appearance, ShellAppearance.graphite);
      expect(prefs.getString('nrs.shellAppearance'), 'graphite');
    });

    test('面层不透明度默认 90%，夹在 50%–100%', () async {
      final (:settings, :prefs) = await load();
      expect(settings.surfaceOpacity, 0.9);

      settings.surfaceOpacity = 0.7;
      expect(settings.surfaceOpacity, 0.7);
      expect(prefs.getDouble('nrs.surfaceOpacity'), 0.7);

      settings.surfaceOpacity = 0.2;
      expect(settings.surfaceOpacity, SettingsController.surfaceOpacityMin);
      settings.surfaceOpacity = 2;
      expect(settings.surfaceOpacity, SettingsController.surfaceOpacityMax);
    });

    test('壁纸外观把原生窗口 alpha 钉在 100%，切回去原值还在', () async {
      final (:settings, :prefs) = await load();
      expect(settings.effectiveWindowOpacity, 0.9);

      settings.windowOpacity = 0.75;
      expect(settings.effectiveWindowOpacity, 0.75);

      settings.appearance = ShellAppearance.wallpaper;
      expect(settings.effectiveWindowOpacity, 1);
      expect(settings.windowOpacity, 0.75, reason: '原值留着，切回默认外观还要用');

      settings.appearance = ShellAppearance.graphite;
      expect(settings.effectiveWindowOpacity, 0.75);
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

  group('白板会话', () {
    test('没开过白板 → 路径和「正在看白板」都是空的', () async {
      final (:settings, :prefs) = await load();
      expect(settings.sessionCanvasPath, isNull);
      expect(settings.sessionCanvasActive, isFalse);
    });

    test('路径和「当时正看着它」一起往返', () async {
      final (:settings, :prefs) = await load();

      settings.saveCanvasSession(path: '笔记/未命名白板.nrs', active: true);
      expect(settings.sessionCanvasPath, '笔记/未命名白板.nrs');
      expect(settings.sessionCanvasActive, isTrue);

      // 白板页开着但用户在写笔记：路径留着，激活标记要撤掉。
      settings.saveCanvasSession(path: '笔记/未命名白板.nrs', active: false);
      expect(settings.sessionCanvasPath, '笔记/未命名白板.nrs');
      expect(settings.sessionCanvasActive, isFalse);

      // 关掉白板页：两个键一起消失，别留个孤零零的 active。
      settings.saveCanvasSession(path: null, active: true);
      expect(settings.sessionCanvasPath, isNull);
      expect(
        settings.sessionCanvasActive,
        isFalse,
        reason: '没有白板就没有「正在看白板」这回事',
      );
      expect(prefs.containsKey('nrs.sessionCanvas'), isFalse);
      expect(prefs.containsKey('nrs.sessionCanvasActive'), isFalse);
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

  group('右栏开合', () {
    test('显式钉住整列之后，三颗面板开关落下也不收起', () async {
      final (:settings, :prefs) = await load();
      // 没存过：按老规矩由「大纲默认开着」推出来。
      expect(settings.rightSidebarVisible, isTrue);
      expect(prefs.containsKey('nrs.rightSidebarVisible'), isFalse);

      // 右栏上格要换成文件 / 搜索 / 标签之前，外壳先把整列钉住。
      settings.rightSidebarVisible = true;
      expect(prefs.getBool('nrs.rightSidebarVisible'), isTrue);

      settings.clearRightViewFlags();
      expect(settings.outlineVisible, isFalse);
      expect(
        settings.rightSidebarVisible,
        isTrue,
        reason: '三颗开关只代表上格停在哪一页，不代表整列开不开',
      );

      // 收起整列：开关和可见性一起落下。
      settings.closeRightPanels();
      expect(settings.rightSidebarVisible, isFalse);
      expect(prefs.getBool('nrs.rightSidebarVisible'), isFalse);

      // 再从顶栏打开任意一颗：整列跟着回来。
      settings.outlineVisible = true;
      expect(settings.outlineVisible, isTrue);
      expect(settings.rightSidebarVisible, isTrue);
      expect(prefs.getBool('nrs.rightSidebarVisible'), isTrue);
    });

    test('再点一次已经亮着的面板开关 = 打开整列，不会因为同值而没反应', () async {
      final (:settings, :prefs) = await load();
      // 大纲默认亮着，但整列可能被别的路径合上（比如上格停在文件页后
      // 整列收起）。这时再点大纲，意思是「把大纲拿回来」。
      expect(settings.outlineVisible, isTrue);
      settings.rightSidebarVisible = false;
      expect(settings.rightSidebarVisible, isFalse);

      settings.outlineVisible = true;
      expect(settings.rightSidebarVisible, isTrue);
      expect(prefs.getBool('nrs.rightSidebarVisible'), isTrue);
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
