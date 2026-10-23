import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/theme_presets.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/ui/theme/preset_picker.dart';
import 'package:nrs/ui/theme/screen_eyedropper.dart';
import 'package:nrs/ui/theme/theme_editor_dialog.dart';

void main() {
  late SettingsController settings;

  /// 一条假的屏幕取样：颜色 + 左键 / Esc 的当前状态。
  Map<String, Object> sampleAt(
    int color, {
    bool down = false,
    bool escape = false,
  }) => <String, Object>{'color': color, 'down': down, 'escape': escape};

  void clearScreenMock() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ScreenSampler.channel, null);
  }

  /// 记录原生通道收到的每一条命令，用来断言「start / stop 成对出现」。
  late List<String> screenCalls;

  /// 假的原生屏幕取样：按 [samples] 顺序回放，播完之后一直重复最后一个。
  /// 同时记下 start / stop 的调用，鼠标有没有还给系统就靠它。
  void mockScreenSamples(List<Map<String, Object>> samples) {
    int index = 0;
    screenCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ScreenSampler.channel, (
          MethodCall call,
        ) async {
          screenCalls.add(call.method);
          if (call.method != 'sample') return true;
          final Map<String, Object> next =
              samples[index < samples.length ? index : samples.length - 1];
          index++;
          return next;
        });
    addTearDown(clearScreenMock);
  }

  /// 模拟「平台根本没有这个通道」：它会回一个 MissingPluginException，
  /// 而不是一直挂着不回 —— 后者在测试里会永远等下去。
  void mockScreenUnsupported() {
    screenCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ScreenSampler.channel, (
          MethodCall call,
        ) async {
          screenCalls.add(call.method);
          throw MissingPluginException('${call.method} 没有实现');
        });
    addTearDown(clearScreenMock);
  }

  /// A host that mirrors `app.dart`: the palette comes from the controller, and
  /// the theme tween is switched off while the editor is open.
  Future<void> pumpHost(
    WidgetTester tester, {
    Map<String, Object>? prefs,
  }) async {
    SharedPreferences.setMockInitialValues(prefs ?? <String, Object>{});
    settings = SettingsController(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsController>.value(
        value: settings,
        child: Consumer<SettingsController>(
          builder: (BuildContext context, SettingsController s, Widget? _) {
            return MaterialApp(
              themeMode: ThemeMode.light,
              theme: AppTheme.build(s.paletteFor(Brightness.light)),
              themeAnimationDuration: s.themeEditing
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              home: Scaffold(
                body: Center(
                  child: Builder(
                    builder: (BuildContext context) => TextButton(
                      onPressed: () => showThemeEditorDialog(context),
                      child: const Text('打开编辑器'),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> openEditor(
    WidgetTester tester, {
    Map<String, Object>? prefs,
  }) async {
    await pumpHost(tester, prefs: prefs);
    await tester.tap(find.text('打开编辑器'));
    await tester.pumpAndSettle();
  }

  List<AppPaletteToken> visibleTokens(WidgetTester tester) => <AppPaletteToken>[
    for (final AppPaletteToken t in AppPaletteToken.values)
      if (find.byKey(Key('token-${t.name}')).evaluate().isNotEmpty) t,
  ];

  Future<void> selectTier(
    WidgetTester tester,
    ThemeEditorTier tier,
  ) async {
    await tester.tap(find.text(tier.label));
    await tester.pumpAndSettle();
  }

  Future<void> openToken(WidgetTester tester, AppPaletteToken token) async {
    final Finder row = find.byKey(Key('token-${token.name}'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  Future<void> typeHex(
    WidgetTester tester,
    AppPaletteToken token,
    String hex,
  ) async {
    final Finder field = find.descendant(
      of: find.byKey(Key('picker-${token.name}')),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget, reason: '${token.name} 的取色器应该已经展开');
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, hex);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  /// 按下吸管，并把盖在窗口上的提示层渲染出来。
  ///
  /// 之后**不能**再用 pumpAndSettle：轮询定时器还活着，它会一直等到超时。
  /// 用 [pollEyedrop] 一帧一帧地推。
  Future<void> startEyedrop(WidgetTester tester) async {
    final Finder pipette = find.byKey(const Key('eyedropper'));
    await tester.ensureVisible(pipette);
    await tester.pumpAndSettle();
    await tester.tap(pipette);
    await tester.pump();
  }

  Future<void> pollEyedrop(WidgetTester tester, int frames) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('进入编辑器就编辑当前那一套，且不会凭空造出覆盖层', (WidgetTester tester) async {
    await openEditor(
      tester,
      prefs: <String, Object>{'nrs.themePreset': 'midnight'},
    );

    expect(settings.themeEditing, isTrue);
    expect(settings.themePreset, ThemePresetId.midnight);
    expect(settings.overrideFor(ThemePresetId.midnight), isNull);
    // 种子就是刚才那套方案，所以进去这一步不该有任何颜色跳变。
    expect(
      settings.paletteFor(Brightness.light).accent,
      ThemePresets.of(ThemePresetId.midnight).light.accent,
    );
    expect(find.text('编辑「午夜靛」'), findsOneWidget);
  });

  testWidgets('三档：默认简单 6 行，普通 12 行，高级 25 行', (WidgetTester tester) async {
    await openEditor(tester);

    expect(visibleTokens(tester), AppPaletteToken.simple);
    expect(visibleTokens(tester).length, 6);

    await selectTier(tester, ThemeEditorTier.normal);
    expect(visibleTokens(tester), AppPaletteToken.normal);
    expect(visibleTokens(tester).length, 12);

    await selectTier(tester, ThemeEditorTier.advanced);
    expect(visibleTokens(tester).length, 25);

    // 再退回简单，仍然只有那 6 个。
    await selectTier(tester, ThemeEditorTier.simple);
    expect(visibleTokens(tester).length, 6);
  });

  testWidgets('浅色 / 深色 tab 各自编辑自己的那一面', (WidgetTester tester) async {
    await openEditor(tester);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    await openToken(tester, AppPaletteToken.canvas);
    await typeHex(tester, AppPaletteToken.canvas, 'ff101010');

    expect(
      settings.paletteFor(Brightness.dark).canvas,
      const Color(0xFF101010),
    );
    expect(
      settings.paletteFor(Brightness.light).canvas,
      AppPalette.light.canvas,
      reason: '暗色那一面被改了，亮色那一面不该跟着动',
    );
  });

  testWidgets('改强调色会连同它的 5 个伴随令牌一起推导', (WidgetTester tester) async {
    await openEditor(tester);

    await openToken(tester, AppPaletteToken.accent);
    await typeHex(tester, AppPaletteToken.accent, 'f5e050');

    const Color accent = Color(0xFFF5E050);
    final AppPalette light = settings.paletteFor(Brightness.light);
    expect(light.accent, accent);
    // 曜石的 onAccent 是白色，这里必须翻成黑色，否则主按钮读不出。
    expect(light.onAccent, AppPalette.readableOn(accent));
    expect(light.onAccent, isNot(AppPalette.light.onAccent));
    expect(light.accentHover, isNot(AppPalette.light.accentHover));
    expect(light.accentSoft, isNot(AppPalette.light.accentSoft));
    expect(light.selectionEdge, selectionEdgeFor(accent, Brightness.light));
    expect(light.selectionEdge, isNot(AppPalette.light.selectionEdge));
    expect(light.selection.a, closeTo(0.20, 0.01));
    expect(light.selection, isNot(AppPalette.light.selection));
  });

  testWidgets('alpha 令牌：alpha 走独立通道，不动色相', (WidgetTester tester) async {
    await openEditor(tester);
    await selectTier(tester, ThemeEditorTier.advanced);

    final Color before = settings.paletteFor(Brightness.light).selection;
    await openToken(tester, AppPaletteToken.selection);
    await typeHex(tester, AppPaletteToken.selection, '802f6feb');

    final Color after = settings.paletteFor(Brightness.light).selection;
    expect(after.a, closeTo(128 / 255, 0.002));
    // HSV 三滑杆不认识 alpha；这一轮往返不能把 rgb 弄丢或弄歪。
    expect(after.r, before.r);
    expect(after.g, before.g);
    expect(after.b, before.b);
  });

  testWidgets('8 位 hex 直接生效（含 alpha 字节）', (WidgetTester tester) async {
    await openEditor(tester);
    await selectTier(tester, ThemeEditorTier.advanced);

    await openToken(tester, AppPaletteToken.overlay);
    await typeHex(tester, AppPaletteToken.overlay, '33b45309');

    expect(
      settings.paletteFor(Brightness.light).overlay,
      const Color(0x33B45309),
    );
  });

  testWidgets('非法 hex 不生效，并留下一行提示', (WidgetTester tester) async {
    await openEditor(tester);

    await openToken(tester, AppPaletteToken.canvas);
    await typeHex(tester, AppPaletteToken.canvas, 'zzz');

    expect(find.text('请输入 #RGB / #RRGGBB / #AARRGGBB'), findsOneWidget);
    expect(
      settings.paletteFor(Brightness.light).canvas,
      AppPalette.light.canvas,
    );
  });

  testWidgets('取消：预设、覆盖层与颜色一起退回进入前，不留残留', (WidgetTester tester) async {
    await openEditor(tester); // 进入前是曜石，且这一套没有覆盖层

    await openToken(tester, AppPaletteToken.canvas);
    await typeHex(tester, AppPaletteToken.canvas, 'ff010203');
    await openToken(tester, AppPaletteToken.textPrimary);
    await typeHex(tester, AppPaletteToken.textPrimary, 'ff040506');
    expect(
      settings.paletteFor(Brightness.light).canvas,
      const Color(0xFF010203),
    );

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(ThemeEditorDialog), findsNothing);
    expect(settings.themeEditing, isFalse);
    expect(settings.themePreset, ThemePresetId.obsidian);
    expect(settings.overrideFor(ThemePresetId.obsidian), isNull);
    expect(
      settings.paletteFor(Brightness.light).canvas,
      AppPalette.light.canvas,
    );
    expect(
      settings.paletteFor(Brightness.light).textPrimary,
      AppPalette.light.textPrimary,
    );

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('nrs.themeOverride.obsidian'), isFalse);
  });

  testWidgets('完成：覆盖层落盘，重启后仍然读得到', (WidgetTester tester) async {
    await openEditor(tester);

    await openToken(tester, AppPaletteToken.canvas);
    await typeHex(tester, AppPaletteToken.canvas, 'ff010203');

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.byType(ThemeEditorDialog), findsNothing);
    expect(settings.themeEditing, isFalse);
    expect(settings.themePreset, ThemePresetId.obsidian);

    // 「重启」：拿同一份 prefs 重新造一个控制器。
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final SettingsController restarted = SettingsController(prefs);
    expect(restarted.themePreset, ThemePresetId.obsidian);
    expect(
      restarted.paletteFor(Brightness.light).canvas,
      const Color(0xFF010203),
    );
    // 另外两套一点没被动过。
    expect(restarted.overrideFor(ThemePresetId.midnight), isNull);
  });

  testWidgets('重置回当前这一套的出厂色，且只有「完成」才清掉覆盖层', (WidgetTester tester) async {
    await openEditor(
      tester,
      prefs: <String, Object>{'nrs.themePreset': 'vivid'},
    );
    await openToken(tester, AppPaletteToken.canvas);
    await typeHex(tester, AppPaletteToken.canvas, 'ff010203');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('nrs.themeOverride.vivid'), isTrue);

    await tester.tap(find.text('重置为内置'));
    await tester.pumpAndSettle();

    // 重置回的是高对比自己的出厂色，不是曜石。
    expect(
      settings.paletteFor(Brightness.light).canvas,
      ThemePresets.of(ThemePresetId.vivid).light.canvas,
    );
    expect(
      prefs.getString('nrs.themeOverride.vivid'),
      isNotNull,
      reason: '重置只改草稿，落盘留给「完成」',
    );

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(prefs.containsKey('nrs.themeOverride.vivid'), isFalse);
    expect(
      settings.paletteFor(Brightness.light).canvas,
      ThemePresets.of(ThemePresetId.vivid).light.canvas,
    );
  });

  testWidgets('吸管：屏幕上取到的颜色直接落在当前令牌上', (WidgetTester tester) async {
    mockScreenSamples(<Map<String, Object>>[
      sampleAt(0, down: true), // 按下吸管按钮的那一下还没松手
      sampleAt(0), // 松手，上膛
      sampleAt(0xFF112233, down: true), // 单击确认
    ]);
    await openEditor(tester);
    await openToken(tester, AppPaletteToken.canvas);

    await startEyedrop(tester);
    expect(find.text('单击取色 · Esc 取消'), findsOneWidget);

    await pollEyedrop(tester, 4);

    expect(
      settings.paletteFor(Brightness.light).canvas,
      const Color(0xFF112233),
    );
    // 命中之后提示层自己摘掉，界面重新点得动。
    expect(find.text('单击取色 · Esc 取消'), findsNothing);
    // 鼠标必须还回去，否则整个应用以后都点不动别的窗口。
    expect(screenCalls.first, 'start');
    expect(screenCalls.last, 'stop');
  });

  testWidgets('吸管：带 alpha 的令牌取色后保留原来的透明度', (WidgetTester tester) async {
    mockScreenSamples(<Map<String, Object>>[
      sampleAt(0),
      sampleAt(0xFF112233, down: true),
    ]);
    await openEditor(tester);
    await selectTier(tester, ThemeEditorTier.advanced);
    await openToken(tester, AppPaletteToken.selection);

    await startEyedrop(tester);
    await pollEyedrop(tester, 3);

    final Color picked = settings.paletteFor(Brightness.light).selection;
    expect(picked.withValues(alpha: 1), const Color(0xFF112233));
    // 屏幕像素不透明，但选区不能因此变成实心块。
    expect(picked.a, closeTo(AppPalette.light.selection.a, 0.002));
  });

  testWidgets('吸管：取色途中跟着光标走，Esc 之后退回原色', (WidgetTester tester) async {
    mockScreenSamples(<Map<String, Object>>[
      sampleAt(0xFF112233),
      sampleAt(0xFF445566),
      sampleAt(0xFF445566, escape: true),
    ]);
    await openEditor(tester);
    await openToken(tester, AppPaletteToken.canvas);

    await startEyedrop(tester);
    // 提示条要落在正常的正文样式上：这一层没有 Scaffold，一旦漏了 Material，
    // 就会继承 MaterialApp 的恐慌样式（48px 红字 + 黄双下划线）。
    final BuildContext hint = tester.element(find.text('单击取色 · Esc 取消'));
    final TextStyle inherited = DefaultTextStyle.of(hint).style;
    expect(inherited.fontSize, isNot(48.0));
    expect(inherited.decoration, isNot(TextDecoration.underline));

    await pollEyedrop(tester, 1);
    expect(find.text('#112233 · 单击取色 · Esc 取消'), findsOneWidget);
    await pollEyedrop(tester, 1);
    expect(find.text('#445566 · 单击取色 · Esc 取消'), findsOneWidget);
    expect(
      settings.paletteFor(Brightness.light).canvas,
      const Color(0xFF445566),
      reason: '窗口只剩底部一条时，提示条就是唯一的预览',
    );

    await pollEyedrop(tester, 1);
    expect(find.textContaining('单击取色'), findsNothing);
    expect(
      settings.paletteFor(Brightness.light).canvas,
      AppPalette.light.canvas,
      reason: 'Esc 取消要把实时预览退回去，不能留下没人确认过的颜色',
    );
  });

  testWidgets('吸管：Esc 取消取色，但不关掉编辑器', (WidgetTester tester) async {
    mockScreenSamples(<Map<String, Object>>[sampleAt(0, escape: true)]);
    await openEditor(tester);
    await openToken(tester, AppPaletteToken.canvas);

    await startEyedrop(tester);
    await pollEyedrop(tester, 2);

    expect(find.text('单击取色 · Esc 取消'), findsNothing);
    expect(find.byType(ThemeEditorDialog), findsOneWidget);
    expect(
      settings.paletteFor(Brightness.light).canvas,
      AppPalette.light.canvas,
    );
    expect(screenCalls.last, 'stop', reason: '取消了也要把鼠标还回去');
  });

  testWidgets('吸管：原生没实现就说清楚，而不是闪一下就没了', (WidgetTester tester) async {
    mockScreenUnsupported();
    await openEditor(tester);
    await openToken(tester, AppPaletteToken.canvas);

    await startEyedrop(tester);
    await pollEyedrop(tester, 2);

    expect(find.text('单击取色 · Esc 取消'), findsNothing);
    expect(
      find.textContaining('当前进程没有回应'),
      findsOneWidget,
      reason: '取不到色要说清原因，否则用户只看到闪一下',
    );
    expect(find.byType(ThemeEditorDialog), findsOneWidget);
    expect(
      settings.paletteFor(Brightness.light).canvas,
      AppPalette.light.canvas,
    );
    expect(
      screenCalls.contains('stop'),
      isTrue,
      reason: '原生没实现这一枪也得把 start 撤回来',
    );
  });

  testWidgets('吸管：Esc 取消不弹任何提示', (WidgetTester tester) async {
    mockScreenSamples(<Map<String, Object>>[sampleAt(0, escape: true)]);
    await openEditor(tester);
    await openToken(tester, AppPaletteToken.canvas);

    await startEyedrop(tester);
    await pollEyedrop(tester, 2);

    expect(find.textContaining('当前进程没有回应'), findsNothing);
  });

  testWidgets('配色方案：点格子只切方案，每格右上角的铅笔才打开编辑', (WidgetTester tester) async {
    ThemePresetId? switched;
    ThemePresetId? edited;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.light),
        home: Scaffold(
          body: ThemePresetPicker(
            value: ThemePresetId.obsidian,
            brightness: Brightness.light,
            overrides: (ThemePresetId _) => null,
            onChanged: (ThemePresetId v) => switched = v,
            onEdit: (ThemePresetId v) => edited = v,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('preset-vivid')));
    await tester.pumpAndSettle();
    expect(switched, ThemePresetId.vivid);
    expect(edited, isNull, reason: '点格子只是切到那一套配色，不该弹面板');

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('preset-midnight')),
        matching: find.byIcon(LucideIcons.squarePen),
      ),
    );
    await tester.pumpAndSettle();
    expect(edited, ThemePresetId.midnight, reason: '铅笔编辑的是它自己那一格');
  });
}
