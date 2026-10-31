import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/app_enums.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/notes_controller.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/ui/shell/settings_page.dart';

class _EmptyStore extends NoteStore {
  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<Note>> loadAll() async => const <Note>[];

  @override
  Future<void> save(Note note, {String? previousPath}) async {}

  @override
  Future<TrashEntry?> delete(Note note) async => null;
}

Future<({SettingsController settings, SharedPreferences prefs})> pumpSettings(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1100, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final SettingsController settings = SettingsController(prefs);
  final NotesController notes = NotesController(store: _EmptyStore());
  addTearDown(notes.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<NotesController>.value(value: notes),
      ],
      child: MaterialApp(
        theme: AppTheme.build(settings.palette),
        // 设置现在是一页，不是一层弹窗：直接把它当成整块内容挂上去。
        home: const Scaffold(body: SettingsPage()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (settings: settings, prefs: prefs);
}

void main() {
  testWidgets('外观里能调窗口不透明度，拖动立即写进偏好', (WidgetTester tester) async {
    final (:settings, :prefs) = await pumpSettings(tester);

    expect(find.text('窗口不透明度'), findsOneWidget);
    expect(find.text('90%'), findsOneWidget);
    final Finder slider = find.byWidgetPredicate(
      (Widget w) => w is Slider && (w.value - 90).abs() < 0.01,
    );
    expect(slider, findsOneWidget);
    // 50%–100% 之间 1% 一档：分 50 格，拖到多少就是多少。
    expect(tester.widget<Slider>(slider).divisions, 50);
    expect(tester.widget<Slider>(slider).min, 50);
    expect(tester.widget<Slider>(slider).max, 100);

    await tester.drag(slider, const Offset(-120, 0));
    await tester.pumpAndSettle();

    expect(settings.windowOpacity, lessThan(0.9));
    expect(
      settings.windowOpacity,
      greaterThanOrEqualTo(SettingsController.windowOpacityMin),
    );
    expect(prefs.getDouble('nrs.windowOpacity'), settings.windowOpacity);
  });

  testWidgets('外观能在默认和壁纸之间切换，壁纸才显示面层不透明度', (WidgetTester tester) async {
    final (:settings, :prefs) = await pumpSettings(tester);

    expect(find.text('窗口不透明度'), findsOneWidget);
    expect(find.text('面层不透明度'), findsNothing);

    final Finder wallpaper = find.byKey(
      const ValueKey<String>('appearance-壁纸'),
    );
    await tester.ensureVisible(wallpaper);
    await tester.pumpAndSettle();
    await tester.tap(wallpaper);
    await tester.pumpAndSettle();

    expect(settings.appearance, ShellAppearance.wallpaper);
    expect(prefs.getString('nrs.shellAppearance'), 'wallpaper');
    expect(find.text('面层不透明度'), findsOneWidget);
    expect(find.text('窗口不透明度'), findsNothing);

    final Finder slider = find.byWidgetPredicate(
      (Widget w) => w is Slider && (w.value - 90).abs() < 0.01,
    );
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(settings.surfaceOpacity, lessThan(0.9));
    expect(prefs.getDouble('nrs.surfaceOpacity'), settings.surfaceOpacity);

    final Finder graphite = find.byKey(const ValueKey<String>('appearance-默认'));
    await tester.ensureVisible(graphite);
    await tester.pumpAndSettle();
    await tester.tap(graphite);
    await tester.pumpAndSettle();

    expect(settings.appearance, ShellAppearance.graphite);
    expect(find.text('窗口不透明度'), findsOneWidget);
    expect(find.text('面层不透明度'), findsNothing);
  });
}
