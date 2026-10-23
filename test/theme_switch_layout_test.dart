import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/theme/theme_presets.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// 一篇两百行的普通正文：切换主题时，排版是否被反复重排，用行数放大差值。
String _doc() => List<String>.generate(
  200,
  (int i) => '第 ${i + 1} 行正文，主题切换时这段排版不该跟着补间逐帧重来。',
).join('\n');

void main() {
  testWidgets('切换配色时正文只重排一次，不跟着补间逐帧重排', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = SettingsController(
      await SharedPreferences.getInstance(),
    );
    final MarkdownSourceController controller = MarkdownSourceController(
      text: _doc(),
    );
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);

    // 镜像 `app.dart`：主题跟着设置的配色走，并保留 180ms 的补间。
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsController>.value(
        value: settings,
        child: Consumer<SettingsController>(
          builder: (BuildContext context, SettingsController s, Widget? _) {
            return MaterialApp(
              theme: AppTheme.build(s.paletteFor(Brightness.light)),
              themeAnimationDuration: const Duration(milliseconds: 180),
              home: Scaffold(
                body: MarkdownEditor(
                  controller: controller,
                  focusNode: focus,
                  scrollController: scroll,
                  fontSize: 15.5,
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    field.debugFullLayouts = 0;

    settings.themePreset = ThemePresetId.midnight;
    await tester.pump();
    expect(
      field.debugFullLayouts,
      1,
      reason: '换配色只需要整篇重排一次',
    );

    // 补间期间的每一帧 `ThemeData` 都在换 AppPalette：正文排版必须原地不动。
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      field.debugFullLayouts,
      1,
      reason: '补间逐帧换配色，正文不该跟着逐帧重排',
    );

    // 排完用的是目标配色，不是补间中间值。
    final TextSpan first =
        field.lineLayout!.laidOut.first.painter.text! as TextSpan;
    expect(
      first.style!.color,
      settings.paletteFor(Brightness.light).textPrimary,
      reason: '正文应直接采用目标配色的文字色',
    );
  });

  test('同一套配色在多次读取之间复用同一个实例', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = SettingsController(
      await SharedPreferences.getInstance(),
    );

    final AppPalette first = settings.paletteFor(Brightness.light);
    expect(
      identical(first, settings.paletteFor(Brightness.light)),
      isTrue,
      reason: '按行排版用实例身份判断主题是否变化，重复读取不能换对象',
    );

    settings.themePreset = ThemePresetId.midnight;
    final AppPalette next = settings.paletteFor(Brightness.light);
    expect(identical(first, next), isFalse, reason: '换预设应给出新配色');
    expect(identical(next, settings.paletteFor(Brightness.light)), isTrue);
  });
}
