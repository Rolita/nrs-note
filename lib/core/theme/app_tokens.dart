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

/// Corner radii. Deliberately restrained: a 26px list row or a 30px field wants
/// a corner it barely notices, not a pill.
abstract final class AppRadius {
  static const double xs = 3;
  static const double sm = 5;
  static const double md = 7;
  static const double lg = 10;
  static const double xl = 14;
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

  /// Hover: short enough that the row feels like it is under the pointer, not
  /// fading in behind it.
  static const Duration fast = Duration(milliseconds: 120);

  /// Selection and mode changes.
  static const Duration base = Duration(milliseconds: 160);
  static const Duration slow = Duration(milliseconds: 220);

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

/// The type scale for everything that is *not* the note body.
///
/// One rung per job. Before this existed the chrome had drifted into 9.5 / 10 /
/// 10.5 / 11 / 11.5 / 12 / 12.5 / 13 / 13.5 for what were really four jobs, and
/// two panels could sit side by side with visibly different "small" text.
///
/// Anything *smaller* than [caption] is deliberate and stays a literal: a key
/// cap, a counter or an `H1` glyph inside a 20px box is metering, not prose, and
/// a rung for it would only invite the next panel to use it for a label.
/// The editor's own body size is outside this list — it is a user preference.
abstract final class AppText {
  /// Dates, counts, shortcut glyphs, hints — the smallest thing worth reading.
  static const double caption = 11.5;

  /// Section headers, secondary metadata, shortcut labels.
  static const double label = 12;

  /// Rows, buttons, menu items, form labels.
  static const double ui = 13;

  /// Dialog and settings body copy.
  static const double body = 13.5;

  /// Panel headers, dialog sub-titles, the palette's search line.
  static const double title = 15;

  /// The heading of a dialog.
  static const double display = 17;

  /// Code, file paths and tabular figures.
  static const double mono = 11.5;
}

/// Icon sizes.
///
/// Four rungs, and only four. Before this existed the chrome used nine
/// (11 / 12 / 13 / 14 / 14.5 / 15 / 16 / 16.5 / 17) for what were really three
/// jobs, which is why two adjacent panels could carry icons of visibly
/// different weight.
abstract final class AppIconSize {
  /// Inline: inside a chip, a row's trailing affordance.
  static const double xs = 14;

  /// A list row, a toolbar button.
  static const double sm = 16;

  /// Navigation: the rail, a panel header.
  static const double md = 18;

  /// The title bar's window controls.
  static const double lg = 20;
}

/// Sizes used by the four-region shell.
///
/// Every rung is a multiple of four — the shell's one grid unit — so two
/// regions can be stacked and still agree on where their edges fall. The only
/// exceptions are the 1px hairlines and the optical nudges inside a single
/// glyph.
abstract final class AppLayout {
  /// Far-left icon rail: buttons only.
  ///
  /// 44 = 4 + 32 + 4 + 4: a 32px button with room for a hover square and the
  /// 2px selection bar that sits against its left edge.
  static const double railWidth = 44;

  /// The switchable file / search / tags sidebar.
  static const double listMinWidth = 236;
  static const double listDefaultWidth = 288;
  static const double listMaxWidth = 420;

  /// Far-right document outline.
  static const double outlineWidth = 232;
  static const double outlineMinWidth = 200;
  static const double outlineMaxWidth = 420;

  /// Below this width the outline yields to the editor.
  static const double outlineMinShellWidth = 980;

  /// The draggable strip between two panes.
  ///
  /// The title bar measures with it as well: the editor's left edge — and so
  /// the first tab — starts one strip *after* the sidebar ends.
  static const double resizeHandleWidth = 5;

  /// The app's own caption. Tall enough for a 32px control plus 4px of air on
  /// each side, which is what makes the tabs read as sitting *in* the bar
  /// rather than being squeezed by it.
  static const double titleBarHeight = 40;

  /// Below this width the shell degrades gracefully to a single pane.
  static const double compactBreakpoint = 900;
  static const double narrowBreakpoint = 620;

  /// Comfortable measure for prose (~72 characters).
  static const double proseMaxWidth = 720;

  // ------------------------------------------------------------- density
  //
  // The shell is dense on purpose: a file tree that shows eight notes instead
  // of five is worth more than the breathing room those three rows would need.

  /// One row of the file tree, the tag list, or a search result.
  ///
  /// 28 rather than 26: a 16px icon needs 6px above and below before the row
  /// stops looking like it is swallowing the glyph, and 26 is not a multiple of
  /// the shell's 4px unit, so it could never line up with the panels beside it.
  static const double rowHeight = 28;

  /// One nesting level inside the file tree.
  static const double rowIndent = 14;

  /// The icon strip above a sidebar panel (new note, new folder, search…).
  static const double toolbarHeight = 40;

  /// The `标签 · 12` header a panel carries instead of a toolbar.
  static const double panelHeaderHeight = 32;

  /// The search field, and every input that has to match its weight.
  static const double fieldHeight = 32;

  /// The thin status line under a panel.
  static const double footerHeight = 28;

  /// Square icon button, and the height of a text button beside it.
  static const double buttonHeight = 30;
}
