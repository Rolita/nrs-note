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
            scrollBehavior: const NrsScrollBehavior(),
            home: const AppShell(),
          );
        },
      ),
    );
  }
}

/// Desktop scrolling: no Android overscroll glow, and **no drag-to-scroll with
/// the mouse**.
///
/// A mouse button is not a finger. Holding the left button and moving is, on a
/// desktop, the gesture for *selecting text* — and in the blank strip to the
/// right of the text column it used to do something no desktop app does: drag
/// the whole page up and down. That is a touch convention (APK), so `mouse` is
/// deliberately absent from [dragDevices]; the wheel still scrolls, and a
/// finger or a stylus still drags on hardware that has a screen for it.
///
/// ⛔ Do not add [PointerDeviceKind.mouse] back here "to make dragging work":
/// it makes every scrollable in the app — the editor, the note list, every
/// panel — grab left-button drags away from text selection.
class NrsScrollBehavior extends MaterialScrollBehavior {
  const NrsScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    // Two-finger pan on a trackpad is a real desktop gesture and arrives as
    // `trackpad`, never as a held mouse button — so it stays.
    PointerDeviceKind.trackpad,
  };

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
