import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/theme/app_palette.dart';
import 'core/theme/app_theme.dart';
import 'state/notes_controller.dart';
import 'state/settings_controller.dart';
import 'ui/shell/app_shell.dart';

class NrsApp extends StatelessWidget {
  const NrsApp({super.key, required this.settings, required this.notes});

  final SettingsController settings;
  final NotesController notes;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsController>.value(value: settings),
        ChangeNotifierProvider<NotesController>.value(value: notes),
      ],
      child: Consumer<SettingsController>(
        builder: (BuildContext context, SettingsController s, Widget? _) {
          return MaterialApp(
            title: 'NRS · Markdown 笔记',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.build(AppPalette.light),
            darkTheme: AppTheme.build(AppPalette.dark),
            themeMode: s.theme.mode,
            scrollBehavior: const _DesktopScrollBehavior(),
            home: const AppShell(),
          );
        },
      ),
    );
  }
}

/// Desktop-friendly scrolling: drag anywhere with the mouse, and no Android
/// overscroll glow leaking into a productivity app.
class _DesktopScrollBehavior extends MaterialScrollBehavior {
  const _DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
