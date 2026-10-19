import 'package:flutter/material.dart';

/// Layout / motion constants shared by every widget.
abstract final class AppSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double xxxl = 40;
}

abstract final class AppRadius {
  static const double xs = 5;
  static const double sm = 8;
  static const double md = 11;
  static const double lg = 14;
  static const double xl = 20;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(
    Radius.circular(pill),
  );
}

abstract final class AppMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve emphasis = Curves.easeOutBack;
}

/// A deliberate three-font strategy: UI chrome, prose, and code.
abstract final class AppFonts {
  /// Chrome: labels, buttons, navigation.
  static const String ui = 'Segoe UI Variable Text';

  static const List<String> uiFallback = <String>[
    'Segoe UI',
    'Microsoft YaHei UI',
    'PingFang SC',
    'Noto Sans SC',
    'Helvetica Neue',
    'Arial',
  ];

  /// Long-form reading in the rendered preview.
  static const String prose = 'Segoe UI Variable Text';

  static const List<String> proseFallback = <String>[
    'Segoe UI',
    'Charter',
    'Georgia',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Serif SC',
    'serif',
  ];

  static const String mono = 'Cascadia Code';

  static const List<String> monoFallback = <String>[
    'Cascadia Mono',
    'JetBrains Mono',
    'Consolas',
    'SF Mono',
    'Menlo',
    'monospace',
  ];
}

/// Sizes used by the four-region shell.
abstract final class AppLayout {
  /// Far-left icon rail: buttons only.
  static const double railWidth = 52;

  /// The switchable file / search / tags sidebar.
  static const double listMinWidth = 264;
  static const double listDefaultWidth = 316;
  static const double listMaxWidth = 460;

  /// Far-right document outline.
  static const double outlineWidth = 248;

  /// Below this width the outline yields to the editor.
  static const double outlineMinShellWidth = 980;

  static const double titleBarHeight = 40;

  /// Below this width the shell degrades gracefully to a single pane.
  static const double compactBreakpoint = 900;
  static const double narrowBreakpoint = 620;

  /// Comfortable measure for prose (~72 characters).
  static const double proseMaxWidth = 720;
}
