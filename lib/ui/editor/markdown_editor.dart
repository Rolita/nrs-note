import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show kDoubleTapTimeout, kSecondaryMouseButton, kTouchSlop;
import 'package:flutter/material.dart' hide TableCell;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/markdown_outline.dart';
import '../../core/utils/table_model.dart';
import '../../core/utils/table_selection.dart';
import 'editor_context_menu.dart';
import 'live_markdown.dart';
import 'selection_wash.dart';

/// The one and only NRS editing surface: a plain [TextEditingController] whose
/// text *is* the Markdown, and whose painting makes that Markdown look finished.
///
/// The invariant that matters: the painted span tree is exactly as long as the
/// controller's text — every hidden marker keeps its character slots and every
/// decoration stands in for exactly one of them. Break that and the caret
/// drifts, clicks land a line off, and selection stops matching what you see.
class MarkdownSourceController extends TextEditingController {
  MarkdownSourceController({super.text});

  /// Usable width of the text column, measured by the widget itself. The
  /// renderer needs it for the few places that draw a *real* widget — a code
  /// band, inline images — because a [WidgetSpan] inside a text line cannot ask
  /// for "the rest of the line".
  double contentWidth = AppLayout.proseMaxWidth;

  /// Fired when the user flips a task checkbox from inside the editor, so the
  /// draft — and the debounced auto-save — can pick the new text up.
  void Function(String newText)? onExternalChange;

  /// Fired when a `#tag` pill is clicked.
  void Function(String tag)? onTagTap;

  /// Fired when a `[[wikilink]]` is clicked.
  void Function(String target)? onWikilinkTap;

  /// The selection the *painting* should treat as the caret while a drag is in
  /// flight, instead of the live one.
  ///
  /// Entering a line reveals its Markdown markers (`**`, backticks, a link's
  /// URL), and the line gets wider the moment it does. A gesture would then be
  /// measuring the pointer against a layout the user is no longer looking at:
  /// dragging across 「编辑器」 on a task line selects 「编辑」, because the two
  /// backticks of `` `.md` `` appeared mid-gesture and pushed everything after
  /// them to the right. Holding the reveal still for the whole gesture keeps the
  /// geometry exactly as the user saw it when they pressed.
  TextSelection? revealAs;

  /// The selection the tree currently on screen was built for.
  ///
  /// A pointer-down reaches the field's own recogniser *and* the pane's
  /// [Listener], and the order of the two is not something to rely on — the
  /// caret may already have moved by the time the listener runs. "What the user
  /// was looking at" is therefore read from the painting, not from [value].
  TextSelection? get paintedSelection => _painted;
  TextSelection? _painted;

  /// The rectangle a **grip** selected, held until the document changes.
  ///
  /// Geometry cannot tell a column-grip selection from a cell rectangle that
  /// happens to cover every row, and the two must delete differently. The
  /// gesture is the only thing that knows, so it parks the range here and every
  /// command reads it through [rangeFor]; a plain drag keeps using geometry.
  TableRange? _intendedRange;
  TableRange? get intendedRange => _intendedRange;
  set intendedRange(TableRange? range) {
    if (identical(range, _intendedRange)) return;
    _intendedRange = range;
  }

  /// The intended range, as long as the user has not moved on from it.
  ///
  /// The selection is compared as well as the text: a menu command that reads
  /// the range must never resurrect a gesture the user has since replaced with
  /// an ordinary drag.
  TableRange? rangeFor(String text, TextSelection selection) {
    final TableRange? range = _intendedRange;
    if (range == null || !selection.isValid) return null;
    final TextSelection expected = range.toTextSelection();
    if (selection.baseOffset != expected.baseOffset ||
        selection.extentOffset != expected.extentOffset) {
      return null;
    }
    // `TableBlock.text` is the whole document: editing anywhere invalidates the
    // stored offsets, which is exactly when the intent has to lapse.
    if (range.block.text != text) return null;
    return range;
  }

  @override
  set value(TextEditingValue newValue) {
    if (_intendedRange != null && newValue.text != value.text) {
      _intendedRange = null;
    }
    super.value = newValue;
  }

  /// Re-runs the painter although neither the text nor the selection changed.
  ///
  /// [revealAs] is part of the painting rather than of the value, so the
  /// equality check in `TextEditingController.value` would swallow the update
  /// and leave the editor stuck with frozen markers.
  void repaint() => notifyListeners();

  /// Where a plain click should park the caret, while a click is in flight.
  ///
  /// Flutter counts clicks for us, and the counting is generous: two taps within
  /// [kDoubleTapTimeout] that land within 100 logical pixels select a **word**,
  /// and a third selects the whole **line**. In a Chinese note a "word" is a
  /// character or two, so the highlight appears when the user was only placing
  /// the caret — 点快一点就变成选中、再快一点整行被选走。
  ///
  /// The awkward part is *when* Flutter writes it. The double-tap recogniser
  /// only wins the gesture arena once the pointer has gone **up**, so during
  /// pointer-down — and even during pointer-up — the selection is still a plain
  /// caret and there is nothing to undo. The range shows up afterwards, out of
  /// band, where no pointer handler can see it. This setter is the one place
  /// that does see it, so it folds the range straight back to the caret the
  /// user actually pointed at.
  int? _clickAnchor;
  Timer? _clickGuard;

  /// The document the guard was armed against.
  ///
  /// An edit that changes the text is not a click mis-read: Enter inside a
  /// table returns a whole-cell range for the new row, and a guard that only
  /// looked at the selection would fold that range back to the old click — the
  /// caret then sat in the row above the one the user had just created. A click
  /// that only selects a word changes no text, which is exactly the case this
  /// guard exists for.
  String? _clickGuardText;

  /// Opens the window in which a *range* selection is treated as a mis-read
  /// click and collapsed to [offset].
  ///
  /// Deliberately a little longer than [kDoubleTapTimeout]: the third click of
  /// a triple arrives inside the same window as the second.
  void armClickGuard(int offset) {
    _clickAnchor = offset;
    _clickGuardText = text;
    _clickGuard?.cancel();
    _clickGuard = Timer(const Duration(milliseconds: 400), () {
      _clickAnchor = null;
      _clickGuardText = null;
      _clickGuard = null;
    });
  }

  /// Lets ranges through again — as soon as the pointer travels far enough to
  /// be a drag, and whenever a new gesture starts.
  void disarmClickGuard() {
    _clickGuard?.cancel();
    _clickGuard = null;
    _clickAnchor = null;
    _clickGuardText = null;
  }

  @override
  set selection(TextSelection newSelection) {
    if (_clickAnchor != null && _clickGuardText != text) {
      disarmClickGuard();
    }
    final int? anchor = _clickAnchor;
    // A keyboard extend or a select-all is a deliberate range, and a drag has
    // already disarmed the guard by the time it asks for one.
    if (anchor != null &&
        !newSelection.isCollapsed &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isControlPressed) {
      super.selection = TextSelection.collapsed(
        offset: anchor.clamp(0, text.length),
        affinity: newSelection.base.affinity,
      );
      return;
    }
    super.selection = newSelection;
  }

  @override
  void dispose() {
    _clickGuard?.cancel();
    super.dispose();
  }

  String? _cacheKey;
  TextSpan? _cache;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final TextEditingValue v = value;
    final AppPalette p = context.palette;
    final TextStyle base = style ?? const TextStyle();

    // `buildTextSpan` runs on *every* frame, so keep the last tree. The key
    // covers everything the tree depends on, including the column width (the
    // rule and code band are sized from it) and the palette (colours).
    final bool composingMark =
        withComposing && v.isComposingRangeValid && !v.composing.isCollapsed;
    final TextSelection? frozen = revealAs;
    final String key =
        '${v.text}\u0000'
        '${v.selection.baseOffset}:${v.selection.extentOffset}\u0000'
        '${frozen?.baseOffset}:${frozen?.extentOffset}\u0000'
        '${v.composing.start}:${v.composing.end}\u0000'
        '$composingMark\u0000${base.hashCode}\u0000${p.hashCode}\u0000'
        '$contentWidth';
    final TextSpan? cached = _cache;
    if (cached != null && key == _cacheKey) return cached;

    final TextSelection reveal = frozen ?? v.selection;
    _painted = reveal;
    List<InlineSpan> spans = buildLiveSpans(
      text: v.text,
      base: base,
      p: p,
      selection: reveal,
      // Marker reveal freezes for the gesture, the wash does not: a drag over a
      // table has to keep the table reading as one selected block while the
      // pointer moves.
      liveSelection: v.selection,
      contentWidth: contentWidth,
      onTagTap: onTagTap,
      onWikilinkTap: onWikilinkTap,
    );

    // An open IME composition must **not** knock the document back to raw
    // Markdown. That used to happen because we handed the whole thing to
    // `super.buildTextSpan`, which paints plain text — so the moment you started
    // typing pinyin the styling vanished. Underline the uncommitted range
    // instead, the way the default controller would, and keep painting.
    if (composingMark) {
      spans = _underlineComposing(spans, v.composing, p, base);
    }

    final TextSpan span = TextSpan(style: base, children: spans);
    _cacheKey = key;
    _cache = span;
    return span;
  }
}

/// How many character positions a span occupies in the laid-out paragraph.
///
/// A [WidgetSpan] is one — the object-replacement character `\uFFFC`. That is
/// the whole reason every decoration in `live_markdown.dart` has to consume
/// exactly one source character.
int _spanLength(InlineSpan span) => span.toPlainText().length;

/// Rebuilds [spans] with the IME's in-progress range underlined.
///
/// The span list is a forest of `TextSpan`s with optional children, so the
/// composing range is threaded through it with a running offset and every span
/// that straddles the boundary is split in three.
List<InlineSpan> _underlineComposing(
  List<InlineSpan> spans,
  TextRange composing,
  AppPalette p,
  TextStyle base,
) {
  if (!composing.isValid || composing.isCollapsed) return spans;
  final TextStyle mark = base.copyWith(
    decoration: TextDecoration.underline,
    decorationColor: p.accent.withValues(alpha: 0.9),
  );
  final int start = composing.start;
  final int end = composing.end;

  InlineSpan wrap(InlineSpan span, int at) {
    final int spanEnd = at + _spanLength(span);
    if (spanEnd <= start || at >= end) return span;
    // A widget occupies a slot we can neither split nor restyle.
    if (span is! TextSpan) return span;

    final List<InlineSpan>? kids = span.children;
    if (kids != null) {
      final List<InlineSpan> next = <InlineSpan>[];
      int childAt = at;
      for (final InlineSpan child in kids) {
        next.add(wrap(child, childAt));
        childAt += _spanLength(child);
      }
      return TextSpan(style: span.style, children: next);
    }

    final String? text = span.text;
    if (text == null || text.isEmpty) return span;
    final int a = (start - at).clamp(0, text.length);
    final int b = (end - at).clamp(0, text.length);
    if (a >= b) return span;
    return TextSpan(
      style: span.style,
      children: <InlineSpan>[
        if (a > 0) TextSpan(text: text.substring(0, a), style: span.style),
        TextSpan(
          text: text.substring(a, b),
          style: (span.style ?? base).merge(mark),
        ),
        if (b < text.length)
          TextSpan(text: text.substring(b), style: span.style),
      ],
    );
  }

  final List<InlineSpan> out = <InlineSpan>[];
  int at = 0;
  for (final InlineSpan span in spans) {
    out.add(wrap(span, at));
    at += _spanLength(span);
  }
  return out;
}

/// The range [newText] deleted from [oldText], or `null` when the edit is not a
/// pure deletion.
///
/// Comparing ends instead of trusting lengths matters: the engine also reports
/// replacements and IME updates as a shorter value, and cutting those at a
/// table boundary would silently change what the user typed.
(int, int)? _removedRange(String oldText, String newText) {
  if (newText.length >= oldText.length) return null;
  final int limit = newText.length;
  int prefix = 0;
  while (prefix < limit &&
      oldText.codeUnitAt(prefix) == newText.codeUnitAt(prefix)) {
    prefix++;
  }
  int suffix = 0;
  while (suffix < limit - prefix &&
      oldText.codeUnitAt(oldText.length - 1 - suffix) ==
          newText.codeUnitAt(newText.length - 1 - suffix)) {
    suffix++;
  }
  final int to = oldText.length - suffix;
  if (oldText.replaceRange(prefix, to, '') != newText) return null;
  return (prefix, to);
}

/// Keeps an edit **inside the table's cells**.
///
/// Three jobs, all of which only the formatter can do:
///
/// * a collapsed Backspace/Delete must not eat the pipe that ends the cell —
///   the predicate lives in [tableCellBarrier] — and a multi-character delete
///   that sweeps a pipe is clamped to the cell's own text;
/// * text inserted with the caret parked on a pipe or padding (Ctrl+End,
///   PageDown and other native movements the key handler never sees) is moved
///   into the cell before the edit is applied;
/// * an edit over a multi-cell selection is a **rectangle** edit, not a text
///   splice: deleting clears the cells, typing writes the active cell and
///   clears the rest, and a typed `|` is escaped instead of splitting the row.
///
/// Implemented as an input formatter rather than a key handler because a
/// deletion can arrive three different ways — a key event on desktop, a
/// `ReplaceTextIntent` from the platform shortcut map, or an engine
/// `updateEditingValue` write — and only the formatter sees all three.
/// Rejected edits simply return the old value, exactly like
/// `LengthLimitingTextInputFormatter`, so a blocked key is a no-op instead of
/// a caret jump.
class TableCellBarrierFormatter extends TextInputFormatter {
  TableCellBarrierFormatter({this.suspend, this.resolve});

  /// The gesture's own reading of the selection — a column grip stays a column
  /// when the edit lands. Without it, deleting a whole column would only clear
  /// its cells.
  final TableRangeResolver? resolve;

  /// True while undo / redo is restoring a recorded value.
  ///
  /// History is not typing: the restored [TextEditingValue] has to land exactly
  /// as it was recorded. A cleared rectangle keeps its range lit, so an undo
  /// arrives with `oldValue` holding that rectangle — exactly the shape a
  /// replacement over the range has. Reading it as one wrote the whole
  /// restored document into the active cell.
  final bool Function()? suspend;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (suspend?.call() ?? false) return newValue;
    // A **multi-cell selection** is edited as a rectangle, never as a run of
    // characters: the platform's own replacement would splice text across the
    // pipes. This covers Delete, Backspace, typed text and an IME commit; the
    // helper refuses what it cannot recognise rather than letting it corrupt
    // the block. Composing text over a range is written into the active cell
    // and the composition is closed, so the next update continues in that cell.
    if (!oldValue.selection.isCollapsed) {
      final TextEditingValue? handled = tableSelectionEdit(
        oldValue,
        newValue,
        resolve: resolve,
      );
      if (handled != null) {
        return handled.composing.isValid
            ? handled.copyWith(composing: TextRange.empty)
            : handled;
      }
      // The edit was not a rectangle: the selection is anchored on the hidden
      // divider, or it reaches past the block. If it would cut the divider or a
      // row boundary, there is no safe rewrite — the source is not on screen.
      if (tableSkeletonTouched(
        oldValue.text,
        oldValue.selection.start,
        oldValue.selection.end,
      )) {
        return oldValue;
      }
    }
    // A caret parked on the divider is not standing in content: the line is
    // the table's skeleton, so no keystroke may rewrite it. Blocked before the
    // IME pass-through, which would otherwise commit straight into the dashes.
    if (oldValue.selection.isCollapsed &&
        oldValue.selection.isValid &&
        tableOnDivider(oldValue.text, oldValue.selection.baseOffset) &&
        newValue.text != oldValue.text) {
      return oldValue;
    }
    // Inside one cell the IME owns the text; blocking composition would make
    // typing feel dead.
    if (oldValue.composing.isValid || newValue.composing.isValid) {
      return newValue;
    }
    // A deletion the engine made in one update can be longer than one
    // character (word delete, autocorrect). The cell under the caret owns it;
    // the pipes and padding around that cell are not part of the edit.
    if (newValue.text.length < oldValue.text.length &&
        newValue.selection.isCollapsed) {
      final (int, int)? removed = _removedRange(oldValue.text, newValue.text);
      if (removed != null) {
        final TextEditingValue? clamped = tableClampDeletion(
          oldValue,
          removed.$1,
          removed.$2,
        );
        if (clamped != null) return clamped;
        // A delete the cell clamp did not own and that cuts a divider or a row
        // boundary: Backspace at the start of the row below the divider, say.
        if (tableSkeletonTouched(oldValue.text, removed.$1, removed.$2)) {
          return oldValue;
        }
      }
    }
    // Typing must land inside the cell the caret is in, even when the caret was
    // moved onto a pipe or padding by a route the table key handler does not
    // see (Ctrl+End, PageDown, a word jump). And a `|` typed inside a cell must
    // not end the cell: the table's source is never on screen, so nobody types
    // a pipe meaning “separator” — they mean the character. GFM's escape keeps
    // the row intact; the renderer paints the literal `|` back.
    if (oldValue.selection.isCollapsed &&
        newValue.text.length > oldValue.text.length) {
      final int at = oldValue.selection.baseOffset;
      if (at >= 0 && at <= oldValue.text.length) {
        final String prefix = oldValue.text.substring(0, at);
        final String suffix = oldValue.text.substring(at);
        if (newValue.text.length > prefix.length + suffix.length &&
            newValue.text.startsWith(prefix) &&
            newValue.text.endsWith(suffix)) {
          final String inserted = newValue.text.substring(
            prefix.length,
            newValue.text.length - suffix.length,
          );
          // A real insertion leaves the caret at its end. Undo/redo restores
          // the selection the old value carried, and rewriting *that* text
          // would rewrite the restored document instead of letting it through.
          final bool typedHere =
              newValue.selection.isCollapsed &&
              newValue.selection.baseOffset == at + inserted.length;
          if (typedHere && !inserted.contains('\n')) {
            final int anchor = tableTypingAnchor(oldValue.text, at) ?? at;
            final bool inTable =
                TableBlock.parse(oldValue.text, anchor) != null;
            final String escaped = inTable && inserted.contains('|')
                ? inserted.replaceAll('|', r'\|')
                : inserted;
            if (anchor != at || escaped != inserted) {
              final String next = oldValue.text.replaceRange(
                anchor,
                anchor,
                escaped,
              );
              return TextEditingValue(
                text: next,
                selection: TextSelection.collapsed(
                  offset: (anchor + escaped.length).clamp(0, next.length),
                ),
              );
            }
          }
        }
      }
    }
    if (newValue.text.length != oldValue.text.length - 1) return newValue;
    final int p = newValue.selection.isCollapsed
        ? newValue.selection.baseOffset
        : -1;
    if (p < 0 || p >= oldValue.text.length) return newValue;
    // The character that went away sits exactly where the caret landed.
    if (newValue.text !=
        oldValue.text.substring(0, p) + oldValue.text.substring(p + 1)) {
      return newValue;
    }
    if (tableSkeletonTouched(oldValue.text, p, p + 1)) return oldValue;
    if (!tableCellBarrier(oldValue.text, p)) return newValue;
    return oldValue;
  }
}

/// Keeps list bullets alive when the user presses Enter, and ends the list on an
/// empty item. Implemented as an input formatter so it sits directly in the
/// native newline path instead of fighting the text input system.
class ListContinuationFormatter extends TextInputFormatter {
  static final RegExp _listRe = RegExp(
    r'^(\s{0,})([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?(.*)$',
  );
  static final RegExp _quoteRe = RegExp(r'^(\s{0,3}>)(\s?)(.*)$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Only ever react to "the user typed one newline at the caret, at the end of
    // a line". Anything looser — "the text changed", "one character was added"
    // — would also fire on IME commits, paste and programmatic writes, and
    // start inserting bullets into text nobody was editing.
    if (oldValue.composing.isValid && !oldValue.composing.isCollapsed) {
      return newValue;
    }
    if (!oldValue.selection.isValid || !oldValue.selection.isCollapsed) {
      return newValue;
    }
    if (newValue.text.length != oldValue.text.length + 1) return newValue;
    final int at = oldValue.selection.baseOffset;
    if (at < 0 || at > oldValue.text.length) return newValue;
    if (newValue.text.codeUnitAt(at) != 0x0A) return newValue;
    if (newValue.text.substring(0, at) != oldValue.text.substring(0, at)) {
      return newValue;
    }
    if (newValue.text.substring(at + 1) != oldValue.text.substring(at)) {
      return newValue;
    }
    if (!newValue.selection.isValid ||
        newValue.selection.baseOffset != at + 1) {
      return newValue;
    }
    // Only a **line-end** Enter continues a list. "Is the caret at the end of
    // its line" is `caret == lineEndOf(...)`, *not* "does the rest of the text
    // contain a newline" — the newline that ends the line the caret is on sits
    // at the caret itself, so the looser question answers "yes, mid-line" for
    // every line that has anything after it. That inverted test is why
    // continuation only ever worked on the last line of a document.
    final int lineStart = lineStartOf(oldValue.text, at);
    final int lineEnd = lineEndOf(oldValue.text, at);

    // Enter in a table adds a row; it never breaks the row. A bare newline here
    // would slice `| a | b |` into two lines, and the renderer — which only
    // knows about lines that start with a pipe — would drop half the table on
    // the floor mid-keystroke. Asked *before* the end-of-line guard so Enter
    // mid-cell grows the table too, instead of falling through to a line break.
    final TextEditingValue? row = tableRowBelow(
      TextEditingValue(
        text: oldValue.text,
        selection: TextSelection.collapsed(offset: at),
      ),
    );
    if (row != null) return row;

    if (at != lineEnd) return newValue;
    final String line = oldValue.text.substring(lineStart, at);

    final Match? quote = _quoteRe.firstMatch(line);
    if (quote != null && quote.group(3)!.trim().isEmpty) {
      // Enter on an empty `> ` ends the quote.
      return _dropMarker(newValue, lineStart, at - lineStart, at);
    }

    final Match? m = _listRe.firstMatch(line);
    if (m == null) return newValue;

    final String indent = m.group(1)!;
    final String marker = m.group(2)!;
    final String checkbox = m.group(3) ?? '';
    final String content = m.group(4) ?? '';

    if (content.trim().isEmpty) {
      // An empty item means "I am done with this list" — take the marker back
      // off instead of nesting one level deeper, so the user can leave.
      return _dropMarker(newValue, lineStart, at - lineStart, at);
    }

    // `1. ` becomes `2. `, keeping the separator the user chose (`.` or `)`).
    // `tryParse` rather than `parse`: a run of digits long enough to overflow an
    // int is a typo, not a list, and Enter must never throw.
    String nextMarker = marker;
    final Match? num = RegExp(r'^(\d+)([.)])$').firstMatch(marker);
    if (num != null) {
      final int? n = int.tryParse(num.group(1)!);
      if (n != null) nextMarker = '${n + 1}${num.group(2)}';
    }
    // A task continues as an **unchecked** task, and an ordered task keeps its
    // numbering: `- [x] 事` → `- [ ] `, `6. [ ] 事` → `7. [ ] `.
    final String insert =
        '$indent$nextMarker ${checkbox.isEmpty ? '' : '[ ] '}';
    final String text =
        newValue.text.substring(0, at + 1) +
        insert +
        newValue.text.substring(at + 1);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: at + 1 + insert.length),
    );
  }

  /// Deletes a line's marker (indentation included) and slides the caret left
  /// with it — the way out of a list.
  ///
  /// The work happens on [newValue], not [oldValue], because the newline is
  /// already sitting at [at]: cutting [removeLength] characters starting at
  /// [lineStart] shifts everything at or after the newline back by exactly that
  /// many, so the caret that was parked after the newline lands right after the
  /// now-empty line.
  ///
  /// [removeLength] is the *whole* line — callers only reach here when the item
  /// is empty, so "the marker and its indent" and "the line" are the same thing.
  /// Deriving it as a formula (`indent + marker + one space`) would leave a
  /// stray space behind for `-  ` typed with two, which then survives as
  /// invisible indentation.
  TextEditingValue _dropMarker(
    TextEditingValue newValue,
    int lineStart,
    int removeLength,
    int at,
  ) {
    final String text =
        newValue.text.substring(0, lineStart) +
        newValue.text.substring(lineStart + removeLength);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: (at + 1 - removeLength).clamp(0, text.length),
      ),
    );
  }
}

class _IndentIntent extends Intent {
  const _IndentIntent(this.outdent);
  final bool outdent;
}

/// Ctrl+C on the body.
///
/// Only interesting because of tables: a selection that spans cells has to copy
/// the **cells** — the editor's wash already snaps out to whole cells, so
/// handing the raw range to the clipboard would hand back the pipes and the
/// `| --- | --- |` divider the user never selected. Everywhere else this copies
/// exactly what the field would have copied.
class _CopyIntent extends Intent {
  const _CopyIntent();
}

/// Ctrl+X on the body.
///
/// The same table rule as [_CopyIntent], on the destructive side: what goes to
/// the clipboard is the **cells**, and what leaves the document has to be those
/// same cells. The field's own cut removes the raw range, which starts and ends
/// wherever the pointer did — mid-cell — and leaves the rest of the cell behind
/// as a broken row. See [snapTableSelection].
class _CutIntent extends Intent {
  const _CutIntent();
}

/// Ctrl+V on the body — the same insert as the context menu's paste, so a
/// pasted table gets the blank line that keeps it apart from the table above it.
/// See [padTablePaste].
class _PasteIntent extends Intent {
  const _PasteIntent();
}

/// Ctrl+Z / Ctrl+Y on the body.
///
/// Handled here only so the formatters can be told that the value about to
/// arrive is a recorded state, not one more keystroke: undo restores the
/// rectangle a clear left lit, and re-reading that as an edit corrupted tables.
class _HistoryIntent extends Intent {
  const _HistoryIntent({required this.undo});
  final bool undo;
}

/// Ctrl+D / Ctrl+R inside a table: copy the first row down / column right.
class _FillIntent extends Intent {
  const _FillIntent({required this.down});
  final bool down;
}

/// Ctrl+Shift+C: the selected cells as tab-separated text.
class _TsvIntent extends Intent {
  const _TsvIntent();
}

/// F2: edit the active cell in a floating editor.
class _EditCellIntent extends Intent {
  const _EditCellIntent();
}

/// The single source of truth for the editor's body typography.
///
/// The pane needs it too: mapping a source line onto a scroll offset means
/// measuring with the exact style the editor paints with.
TextStyle editorProseStyle(AppPalette p, double size) => TextStyle(
  fontFamily: AppFonts.prose,
  fontFamilyFallback: AppFonts.proseFallback,
  fontSize: size,
  // 1.78 of air, rounded to a line height the paragraph can step by exactly —
  // see [snapLineHeight]. The table's row chrome and the selection's boxes are
  // measured from this line, so it has to sit on the grid the paragraph
  // advances by.
  height: snapLineHeight(size, 1.78),
  letterSpacing: 0.05,
  color: p.textPrimary,
);

/// Shared spacing so the editor and the pane's status bar line up.
///
/// Lives here rather than with the pane because it is the editor's own measure:
/// the status bar only borrows it to keep the two columns of chrome flush.
const EdgeInsets kEditorChromePadding = EdgeInsets.symmetric(
  horizontal: AppSpace.md,
);

/// The Markdown editing surface.
class MarkdownEditor extends StatefulWidget {
  const MarkdownEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.fontSize,
    required this.hintText,
    this.padding = const EdgeInsets.fromLTRB(40, 28, 40, 200),
    this.maxWidth = AppLayout.proseMaxWidth,
    this.onChanged,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final double fontSize;
  final String hintText;
  final EdgeInsets padding;
  final double maxWidth;
  final ValueChanged<String>? onChanged;
  final bool readOnly;

  @override
  State<MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<MarkdownEditor> {
  /// Lets us walk the field's element tree to find the checkbox shells.
  final GlobalKey _fieldKey = GlobalKey();

  /// Where the caret was before a click that turned out to be on a checkbox.
  TextSelection? _caretBeforeCheckboxTap;

  /// Drives the field's own undo history from the editor's shortcuts.
  final UndoHistoryController _undoHistory = UndoHistoryController();

  /// True inside [_HistoryIntent]'s action, so [TableCellBarrierFormatter]
  /// knows the incoming value is history being restored and must not be read
  /// as a rectangle edit.
  bool _navigatingHistory = false;

  // -------------------------------------------------------------- overlays
  //
  // Two surfaces float above the field: the low-contrast statistics chip under
  // a selected table, and the F2 cell editor. Both are widgets rather than
  // render-object paint because they must be legible, themable and hit-testable
  // — the table's own wash is paint, but a paragraph is no place for real UI.

  /// The chip's text, and the key of the rectangle it describes. The range
  /// itself is not kept: it is re-resolved from the live selection on every
  /// pass, so a stale one can never be shown.
  String? _statsLabel;
  String? _statsKey;

  /// The selected rectangle's bottom-right row in the editor's own
  /// coordinates.
  Rect? _statsAnchor;
  Size _editorSize = Size.zero;

  bool _overlayRefreshScheduled = false;

  /// The open F2 editor, if any.
  _CellEdit? _cellEdit;
  TextEditingController? _cellText;
  FocusNode? _cellFocus;

  // ------------------------------------------------------------ caret layer

  /// Pins the caret **above** the text, over the opaque bands the renderer
  /// paints behind a run.
  ///
  /// Windows (and Android) make [RenderEditable] draw the caret *under* the
  /// glyphs, which is invisible on plain prose but swallows it whole inside an
  /// inline-code band, a `==高亮==` or a code block — 「行内代码挡住了输入光标」.
  /// `EditableText` can paint the caret last, but `TextField` derives that flag
  /// from the platform and writes the platform value back into the render
  /// object on every rebuild; the render object itself is public and mutable,
  /// so the order is re-asserted after each frame.
  void _pinCaretAboveText() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _editable()?.paintCursorAboveText = true;
    });
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_pinCaretAboveText);
    widget.controller.addListener(_scheduleOverlayRefresh);
    widget.scrollController.addListener(_scheduleOverlayRefresh);
    widget.focusNode.addListener(_pinCaretAboveText);
    _pinCaretAboveText();
  }

  @override
  void didUpdateWidget(MarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_pinCaretAboveText);
      oldWidget.controller.removeListener(_scheduleOverlayRefresh);
      widget.controller.addListener(_pinCaretAboveText);
      widget.controller.addListener(_scheduleOverlayRefresh);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_scheduleOverlayRefresh);
      widget.scrollController.addListener(_scheduleOverlayRefresh);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_pinCaretAboveText);
      widget.focusNode.addListener(_pinCaretAboveText);
    }
    _pinCaretAboveText();
    _scheduleOverlayRefresh();
  }

  // ------------------------------------------------------ task checkboxes
  //
  // ⛔ The boxes are deliberately *not* `GestureDetector`s. A widget inside a
  // `WidgetSpan` is hit-tested through the `TextPainter`'s placeholder box, which
  // drifts from where the widget is actually painted as soon as the row wraps or
  // the marker column holds more than one element; the symptom is "the box on
  // the first line works and the others do not". Instead we listen to raw
  // pointers — a `Listener` never joins the gesture arena, so the field's own
  // "click to place the caret" still works — and hit-test each shell's **real
  // paint rect**, which is by definition where the user sees the box.

  /// The source offset of the checkbox under [globalPosition], if any.
  int? _checkboxAt(Offset globalPosition) {
    final BuildContext? root = _fieldKey.currentContext;
    if (root == null) return null;
    int? found;
    void visit(Element element) {
      if (found != null) return;
      final Widget w = element.widget;
      if (w is MarkdownTodoCheckbox) {
        final RenderObject? ro = element.renderObject;
        if (ro is RenderBox && ro.hasSize && ro.attached) {
          final Rect rect = ro.localToGlobal(Offset.zero) & ro.size;
          if (rect.inflate(_kCheckboxTouchSlop).contains(globalPosition)) {
            found = w.sourceOffset;
          }
        }
        return; // The shell only wraps the box; no need to descend.
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return found;
  }

  /// The field's own render object — the only thing that can turn a screen point
  /// into a text offset exactly the way the field itself does.
  RenderEditable? _editable() {
    final BuildContext? root = _fieldKey.currentContext;
    if (root == null) return null;
    RenderEditable? found;
    void visit(Element element) {
      if (found != null) return;
      final RenderObject? ro = element.renderObject;
      if (ro is RenderEditable) {
        found = ro;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    final RenderEditable? re = found;
    return re != null && re.hasSize && re.attached ? re : null;
  }

  /// Where the pointer went down, and whether it has since travelled far enough
  /// to be a drag rather than a click.
  Offset? _downPosition;
  bool _gestureMoved = false;

  /// True while the gesture in flight started with the **secondary** button.
  ///
  /// A right-click is a completely different animal from a left one: it must not
  /// be "collapsed to the caret" on release (that would throw away the
  /// selection 复制 / 剪切 are about to act on) and it drives the context menu
  /// rather than the click guard.
  bool _secondaryGesture = false;

  /// Applies a context-menu action to the field.
  ///
  /// The menu is the editor's only formatting surface now that the ribbon is
  /// gone, so it writes the controller itself and reports through
  /// [MarkdownEditor.onChanged] — the same path a keystroke takes, which keeps
  /// autosave, the status bar and the outline in step for free.
  void _applyEdit(MarkdownEditFn fn) {
    final TextEditingValue next = fn(widget.controller.value);
    widget.controller.value = next;
    widget.onChanged?.call(next.text);
    widget.focusNode.requestFocus();
  }

  /// Parks the caret under [globalPosition].
  ///
  /// [keepSelection] is what a right-click needs: if the pointer landed *inside*
  /// the current selection the selection is the subject of the menu (复制、剪切)
  /// and must survive, so the caret stays where it is.
  void _placeCaret(
    MarkdownSourceController c,
    Offset globalPosition, {
    bool keepSelection = false,
  }) {
    final RenderEditable? editable = _editable();
    if (editable == null) return;
    int offset = editable
        .getPositionForPoint(globalPosition)
        .offset
        .clamp(0, c.text.length);
    final ({TableBlock block, int row, int column, TableCell cell})? cell =
        _paintedCellAt(globalPosition);
    if (cell != null) offset = _caretInCell(cell.cell, offset);
    if (keepSelection) {
      final TextSelection sel = c.selection;
      if (sel.isValid &&
          !sel.isCollapsed &&
          offset >= sel.start &&
          offset <= sel.end) {
        return;
      }
    }
    c.selection = TextSelection.collapsed(offset: offset);
  }

  /// Table caret movement: Home, End and the four arrows.
  ///
  /// A rendered row's line still contains its pipes and padding, and native
  /// caret movement happily walks into them: End parks the caret after the
  /// closing pipe (typing then appends a third cell), and Up from the first body
  /// row lands on the collapsed divider (typing then edits the dashes). The
  /// table's own rules therefore get the first say; `ignored` hands the key back
  /// to the field, which is what happens everywhere outside a table.
  KeyEventResult _onTableKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    final TextEditingValue v = widget.controller.value;
    // Tab is the table's own key: it steps between cells and must be decided
    // *here*, on the node right above the field, so the event never reaches the
    // field's shortcuts and the focus never leaves the editor. The step also
    // clears the composing range — its text is already in the value — so the
    // next keystroke starts composing in the cell that is now selected.
    if (key == LogicalKeyboardKey.tab) {
      final TextEditingValue? cell = tableCellStep(
        v,
        forward: !keys.isShiftPressed,
      );
      if (cell == null) return KeyEventResult.ignored;
      _disarmClickGuard();
      widget.controller.value = cell;
      widget.onChanged?.call(cell.text);
      widget.focusNode.requestFocus();
      return KeyEventResult.handled;
    }
    if (!v.selection.isValid ||
        (v.composing.isValid && !v.composing.isCollapsed)) {
      return KeyEventResult.ignored;
    }
    final bool extend = keys.isShiftPressed;
    final TextEditingValue? next;
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) {
      next = tableCaretToCellEdge(
        v,
        end: key == LogicalKeyboardKey.end,
        extend: extend,
      );
    } else if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      next = tableCaretStepCell(
        v,
        forward: key == LogicalKeyboardKey.arrowRight,
        extend: extend,
      );
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      next = tableCaretVertical(
        v,
        down: key == LogicalKeyboardKey.arrowDown,
        extend: extend,
      );
    } else {
      return KeyEventResult.ignored;
    }
    if (next == null) return KeyEventResult.ignored;
    _disarmClickGuard();
    widget.controller.value = next;
    return KeyEventResult.handled;
  }

  /// The editor is about to move the caret itself, so a click guard armed by the
  /// gesture that put it here must not fold the move back. A Shift+Arrow
  /// extension is a range, and the guard cannot tell it apart from the platform
  /// word selection it exists to cancel.
  void _disarmClickGuard() {
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController) c.disarmClickGuard();
  }

  /// A click is a click: it puts the caret where you pointed and nothing else.
  ///
  /// `TextField` gives us no way to switch off its click counting, and the
  /// counting is generous: two taps within 300 ms that land within **100 logical
  /// pixels** of each other select a **word**, and a third selects the whole
  /// **line**. Two ordinary clicks anywhere near each other qualify, and a
  /// Chinese "word" is a character or two — so the highlight lands when the user
  /// was only placing the caret. 点快一点就变成选中、再快一点整行被选走，就是它。
  ///
  /// The fix leans on *when* each thing happens:
  ///
  /// * Recognisers are routed only after the whole hit-test path has been walked,
  ///   so this handler runs **before** `selectWordAt`/`selectLineAt`. That makes
  ///   the selection readable here the last honest "the user was looking at a
  ///   caret", and it is snapshotted on the way down.
  /// * Because the platform writes *after* us, the undo cannot happen inline. A
  ///   microtask is the right delay: it drains once the event dispatch is over —
  ///   word selected — and before the next frame is painted, so nothing flashes.
  /// * A selection applied on the way *up* (a third click) is caught in
  ///   [_onPointerUp], which is the same test one event later.
  ///
  /// Three gestures are deliberately left alone: dragging (the pointer has moved
  /// by the time a range exists), shift-click (a deliberate extend), and the
  /// checkbox tap, which restores its own caret and never routes through here.
  void _clickCaret(MarkdownSourceController c, Offset globalPosition) {
    if (_gestureMoved) return;
    if (HardwareKeyboard.instance.isShiftPressed) return;
    final ({TableBlock block, int row, int column, TableCell cell})? cell =
        _paintedCellAt(globalPosition);
    if (cell != null) {
      // A click inside a painted cell is resolved against the paint, not the
      // skeleton: the platform writes the skeleton's offset during the same
      // event, after this listener returns, so the correction has to run as a
      // microtask and re-read the caret it finds there.
      final String text = c.text;
      scheduleMicrotask(() {
        if (!mounted) return;
        if (c.text != text) return;
        if (!c.selection.isCollapsed) return;
        final int fixed = _caretInCell(cell.cell, c.selection.start);
        if (fixed != c.selection.start) {
          c.selection = TextSelection.collapsed(offset: fixed);
        }
      });
      // A range here is the platform's word/line reading; the click guard
      // already folds it back to the offset this gesture was armed with.
      return;
    }
    if (c.selection.isCollapsed) return;
    final RenderEditable? editable = _editable();
    if (editable == null) return;
    final TextPosition at = editable.getPositionForPoint(globalPosition);
    c.selection = TextSelection.collapsed(
      offset: at.offset.clamp(0, c.text.length),
      affinity: at.affinity,
    );
  }

  // ---------------------------------------------------------- table chrome
  //
  // The grips and the plus buttons a live table paints around itself are
  // *painted*, not widgets (see `_RenderTableRow`), so they are found the same
  // way the checkbox shells are: by walking the field's element tree for the
  // render objects and asking them where they drew what. A raw `Listener`
  // never joins the gesture arena, so the editor hears every press; a
  // `_ChromeShield` then keeps the ones that land on a control away from the
  // field below, whose own drag recognizer would otherwise start selecting the
  // text behind the grip.

  /// Every rendered table row currently on screen.
  List<TableRowChrome> _tableRows() {
    final BuildContext? root = _fieldKey.currentContext;
    if (root == null) return const <TableRowChrome>[];
    final List<TableRowChrome> rows = <TableRowChrome>[];
    void visit(Element element) {
      final RenderObject? ro = element.renderObject;
      // The cast is not redundant: `TableRowChrome` is an unrelated interface,
      // so `is` cannot promote a `RenderObject?` into it.
      if (ro is TableRowChrome) rows.add(ro as TableRowChrome);
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return rows;
  }

  /// The grip or plus button under [globalPosition], with the row that painted
  /// it.
  ///
  /// The slop is the same one the paint uses, on purpose: a control is only
  /// *drawn* once the pointer is that close, so hit testing must not be any
  /// stricter — otherwise an icon you can see would refuse the click.
  (TableRowChrome, TableChromeTarget)? _chromeAt(
    Offset globalPosition, {
    double slop = kTableChromeSlop,
  }) {
    for (final TableRowChrome row in _tableRows()) {
      for (final TableChromeTarget t in row.chromeTargets()) {
        if (t.rect.inflate(slop).contains(globalPosition)) return (row, t);
      }
    }
    return null;
  }

  /// The painted cell under [globalPosition] — resolved through the rectangles
  /// the pointer sees, not through the text skeleton.
  ({TableBlock block, int row, int column, TableCell cell})? _paintedCellAt(
    Offset globalPosition,
  ) {
    for (final TableRowChrome row in _tableRows()) {
      if (!row.chromeBounds().contains(globalPosition)) continue;
      final List<Rect> cells = row.chromeCells();
      for (int i = 0; i < cells.length; i++) {
        if (!cells[i].contains(globalPosition)) continue;
        final TableBlock? block = TableBlock.parse(
          widget.controller.text,
          row.chromeTableId,
        );
        if (block == null) continue;
        if (row.chromeRowIndex < 0 ||
            row.chromeRowIndex >= block.bodyRows.length) {
          continue;
        }
        final List<TableCell> model = block.bodyRows[row.chromeRowIndex].cells;
        if (i >= model.length) continue;
        return (
          block: block,
          row: row.chromeRowIndex,
          column: i,
          cell: model[i],
        );
      }
    }
    return null;
  }

  /// A caret read off the invisible skeleton, constrained to the cell the
  /// pointer actually landed on.
  ///
  /// The blank ground of a cell is one stretched placeholder standing for the
  /// pipe, and the engine maps any point inside a placeholder to the offset
  /// **after** it. On the right half of a cell that is the next cell's first
  /// character; on the last cell it is the line end past the closing pipe, so
  /// typing edited a neighbour or appended a third cell. The paint is the truth:
  /// clamp to the clicked cell's text, padding trimmed.
  int _caretInCell(TableCell cell, int offset) {
    // The closing pipe is at `end`, and `tableCellAt` already treats it as the
    // next cell. An empty cell has no content range to clamp to — its raw
    // padding is the only ground it owns, and the last padding slot is the
    // rightmost offset that still belongs to it.
    final int floor = cell.isEmpty ? cell.start : cell.contentStart;
    final int ceiling = cell.isEmpty ? cell.end - 1 : cell.contentEnd;
    if (offset <= floor) return floor;
    if (offset >= cell.end || offset > ceiling) return ceiling;
    return offset;
  }

  /// Which row / column a drop at [globalPosition] would land on.
  int _dropIndex(TableRowChrome grabbed, bool column, Offset globalPosition) {
    final List<TableRowChrome> rows =
        _tableRows()
            .where(
              (TableRowChrome r) => r.chromeTableId == grabbed.chromeTableId,
            )
            .toList()
          ..sort(
            (TableRowChrome a, TableRowChrome b) =>
                a.chromeRowIndex.compareTo(b.chromeRowIndex),
          );
    if (rows.isEmpty) return 0;
    if (column) {
      final List<Rect> cells = grabbed.chromeCells();
      for (int i = 0; i < cells.length; i++) {
        if (globalPosition.dx < cells[i].right) return i;
      }
      return cells.isEmpty ? 0 : cells.length - 1;
    }
    for (final TableRowChrome r in rows) {
      if (globalPosition.dy < r.chromeBounds().bottom) return r.chromeRowIndex;
    }
    return rows.last.chromeRowIndex;
  }

  /// The grip being dragged, if any: `null` when the pointer is not on one.
  TableRowChrome? _grabbedRow;
  TableChromeTarget? _grabbed;

  /// Where the drag would drop right now.
  int _dropAt = 0;

  /// The rectangle that was selected when a grip went down.
  ///
  /// A Shift+click extends this to the grip; a drag of a grip that lies inside
  /// it moves the whole block. Captured on the way down because the field's own
  /// click handling rewrites the selection before the button comes up.
  TableRange? _rangeBeforeChromeTap;

  /// What the pointer looks like over the chrome: the plain arrow on a grip,
  /// `click` on a `+`.
  ///
  /// A plain `MouseCursor`, not a `MouseRegion.cursor` computed inline: the
  /// region has to be rebuilt for the cursor to change, and rebuilding the
  /// editor on every mouse move is exactly what the painted chrome exists to
  /// avoid. It only changes when the *kind* of thing under the pointer changes.
  MouseCursor _chromeCursor = MouseCursor.defer;

  MouseCursor _cursorAt(Offset? position) {
    if (position == null) return MouseCursor.defer;
    final (TableRowChrome, TableChromeTarget)? hit = _chromeAt(position);
    if (hit == null) return MouseCursor.defer;
    return switch (hit.$2.kind) {
      TableChromeKind.rowHandle ||
      TableChromeKind.columnHandle => SystemMouseCursors.basic,
      TableChromeKind.addRow ||
      TableChromeKind.addColumn => SystemMouseCursors.click,
    };
  }

  void _setCursor(MouseCursor next) {
    if (next == _chromeCursor) return;
    setState(() => _chromeCursor = next);
  }

  /// The whole point of the chrome's visibility: nothing is drawn unless the
  /// pointer is at the table's edge, so the editor has to tell the render
  /// objects where the pointer is.
  void _onPointerHover(PointerHoverEvent event) {
    tablePointerPosition.value = event.position;
    if (_grabbedRow != null) return; // a drag owns the cursor until release
    _setCursor(_cursorAt(event.position));
  }

  void _onPointerExit(PointerExitEvent event) {
    if (_grabbedRow != null) return;
    tablePointerPosition.value = null;
    _setCursor(MouseCursor.defer);
  }

  /// Runs whatever the chrome control meant. Returns whether an edit landed.
  bool _applyChrome(TableRowChrome row, TableChromeTarget target, bool moved) {
    final TextEditingValue v = widget.controller.value;
    final TextEditingValue? next = switch (target.kind) {
      TableChromeKind.addRow => editTableAt(
        v,
        row.chromeSourceStart,
        TableEdit.rowBelow,
      ),
      TableChromeKind.addColumn => editTableAt(
        v,
        row.chromeSourceStart,
        TableEdit.columnRight,
      ),
      TableChromeKind.rowHandle =>
        moved
            ? moveTableRow(v, row.chromeSourceStart, target.index, _dropAt)
            : null,
      TableChromeKind.columnHandle =>
        moved
            ? moveTableColumn(v, row.chromeSourceStart, target.index, _dropAt)
            : null,
    };
    if (next == null) return false;
    widget.controller.value = next;
    widget.onChanged?.call(next.text);
    return true;
  }

  /// The multi-row / multi-column block a grip drag would move, if the grip the
  /// pointer grabbed lies inside one.
  TableRange? _grabbedBlock(TableRowChrome row, TableChromeTarget target) {
    final TableRange? base = _rangeBeforeChromeTap;
    if (base == null || base.block.start != row.chromeTableId) return null;
    final bool column = target.kind == TableChromeKind.columnHandle;
    // The kind matters: a column selection spans every *row*, but dragging a
    // row grip then must move that one row, not "all rows" (which is a no-op).
    // Only a gesture along the selection's own axis moves the block.
    if (column ? base.isRows : base.isColumns) return null;
    final int first = column ? base.firstColumn : base.firstRow;
    final int last = column ? base.lastColumn : base.lastRow;
    if (last <= first) return null;
    return target.index >= first && target.index <= last ? base : null;
  }

  int _blockCount(TableRange block, bool column) =>
      column ? block.columnCount : block.rowCount;

  /// Where the block's first row/column would land: the row under the pointer,
  /// minus the grip's own offset inside the block. Dragging the *third* of five
  /// selected rows keeps the other two above it where they are.
  int _blockTop(TableRange block, TableChromeTarget target) {
    final bool column = target.kind == TableChromeKind.columnHandle;
    final int first = column ? block.firstColumn : block.firstRow;
    final int total = column
        ? block.block.columns
        : block.block.bodyRows.length;
    final int limit = math.max(0, total - _blockCount(block, column));
    return (_dropAt - (target.index - first)).clamp(0, limit);
  }

  /// What the drag preview should paint for [target] at the current [_dropAt].
  TableDragPreview _previewFor(TableRowChrome row, TableChromeTarget target) {
    final bool column = target.kind == TableChromeKind.columnHandle;
    final TableRange? block = _grabbedBlock(row, target);
    return TableDragPreview(
      tableId: row.chromeTableId,
      column: column,
      index: block == null ? _dropAt : _blockTop(block, target),
      count: block == null ? 1 : _blockCount(block, column),
    );
  }

  /// Moves every selected row/column so its first one lands at [top].
  ///
  /// The grid command moves by one slot, so a block drag is that command in a
  /// loop. Going through the same command keeps alignments, pipes and row
  /// widths identical to the menu's movement; only the destination is new.
  bool _applyBlockDrag(TableRowChrome row, TableChromeTarget target) {
    final TableRange? blockRange = _grabbedBlock(row, target);
    if (blockRange == null) return false;
    final bool column = target.kind == TableChromeKind.columnHandle;
    final int count = _blockCount(blockRange, column);
    final int start = column ? blockRange.firstColumn : blockRange.firstRow;
    final int top = _blockTop(blockRange, target);
    final TextEditingValue v = widget.controller.value;
    TableBlock? block = TableBlock.parse(v.text, row.chromeTableId);
    if (block == null) return false;

    String text = v.text;
    int first = start;
    while (first != top) {
      final int delta = top > first ? 1 : -1;
      final TableEditResult? moved = column
          ? TableCommands.moveColumns(
              block!,
              from: first,
              to: first + count - 1,
              delta: delta,
              row: 0,
              column: first,
            )
          : TableCommands.moveRows(
              block!,
              from: first,
              to: first + count - 1,
              delta: delta,
              row: first,
              column: 0,
            );
      if (moved == null) break;
      text = moved.text;
      block = TableBlock.parse(text, row.chromeTableId);
      if (block == null) break;
      first += delta;
    }

    final TableBlock? fresh = TableBlock.parse(text, row.chromeTableId);
    if (fresh == null) return false;
    final TableRange kept = column
        ? TableRange.columnsOf(fresh, first, first + count - 1)
        : TableRange.rowsOf(fresh, first, first + count - 1);
    final bool changed = text != v.text;
    final TextEditingController c = widget.controller;
    c.value = TextEditingValue(text: text, selection: kept.toTextSelection());
    if (c is MarkdownSourceController) c.intendedRange = kept;
    if (changed) widget.onChanged?.call(text);
    widget.focusNode.requestFocus();
    return true;
  }

  /// Re-selects the single row / column a drag has just moved, where it landed.
  ///
  /// A drag is still a grip gesture: ending it as a bare caret inside whatever
  /// cell the pointer happened to leave makes the drop look like it threw the
  /// selection away. What was being carried stays selected at its new home.
  void _selectMoved(TableRowChrome row, TableChromeTarget target) {
    final TextEditingController c = widget.controller;
    final TableBlock? block = TableBlock.parse(c.text, row.chromeTableId);
    if (block == null) return;
    final bool column = target.kind == TableChromeKind.columnHandle;
    final int last = column
        ? math.max(0, block.columns - 1)
        : math.max(0, block.bodyRows.length - 1);
    final int index = _dropAt.clamp(0, last);
    final TableRange range = column
        ? TableRange.columnsOf(block, index, index)
        : TableRange.rowsOf(block, index, index);
    c.value = c.value.copyWith(
      selection: range.toTextSelection(),
      composing: TextRange.empty,
    );
    if (c is MarkdownSourceController) c.intendedRange = range;
  }

  /// A grip **click**: select the whole row/column it belongs to, or extend the
  /// existing block to it when Shift is held.
  void _selectGrip(
    TableRowChrome row,
    TableChromeTarget target, {
    required bool extend,
  }) {
    final TextEditingController c = widget.controller;
    final TableBlock? block = TableBlock.parse(c.text, row.chromeTableId);
    if (block == null) return;
    final bool column = target.kind == TableChromeKind.columnHandle;
    final TableRange? base = extend ? _rangeBeforeChromeTap : null;
    final TableRange range;
    if (column) {
      final int last = math.max(0, block.columns - 1);
      final int index = target.index.clamp(0, last);
      final int a = base == null ? index : math.min(base.firstColumn, index);
      final int b = base == null ? index : math.max(base.lastColumn, index);
      range = TableRange.columnsOf(block, a, b);
    } else {
      final int last = math.max(0, block.bodyRows.length - 1);
      final int index = target.index.clamp(0, last);
      final int a = base == null ? index : math.min(base.firstRow, index);
      final int b = base == null ? index : math.max(base.lastRow, index);
      range = TableRange.rowsOf(block, a, b);
    }
    _setRangeSelection(range);
  }

  /// Puts [range] on the controller as the selection, and remembers *what kind*
  /// of selection it is — a column block has to stay a column for Delete, copy
  /// and the menu.
  void _setRangeSelection(TableRange range) {
    // The field's own click handling runs after this listener; setting the
    // range in a microtask makes it the last word.
    scheduleMicrotask(() {
      if (!mounted) return;
      final TextEditingController c = widget.controller;
      if (c.text != range.block.text) return;
      if (c is MarkdownSourceController) c.disarmClickGuard();
      widget.focusNode.requestFocus();
      c.value = c.value.copyWith(
        selection: range.toTextSelection(),
        composing: TextRange.empty,
      );
      if (c is MarkdownSourceController) c.intendedRange = range;
    });
  }

  /// Recorded on *down*: the field moves the caret on pointer-down, so reading
  /// the selection on up would already be too late.
  void _onPointerDown(PointerDownEvent event) {
    final bool secondary = event.buttons & kSecondaryMouseButton != 0;
    if (!secondary) {
      final (TableRowChrome, TableChromeTarget)? hit = _chromeAt(
        event.position,
      );
      if (hit != null) {
        // The chrome shield keeps this press out of the field, so focusing is
        // ours to do — otherwise a grip or `+` clicked from an unfocused
        // editor would act without giving the keyboard anywhere to go.
        widget.focusNode.requestFocus();
        _grabbedRow = hit.$1;
        _grabbed = hit.$2;
        _dropAt = hit.$2.index < 0 ? 0 : hit.$2.index;
        _downPosition = event.position;
        _gestureMoved = false;
        final bool grip =
            hit.$2.kind == TableChromeKind.rowHandle ||
            hit.$2.kind == TableChromeKind.columnHandle;
        if (grip) {
          final TextEditingController c = widget.controller;
          if (c is MarkdownSourceController) {
            // A grip is a selection gesture, not a caret one: the click guard
            // that folds fast clicks back to a caret must not eat the range.
            c.disarmClickGuard();
            _rangeBeforeChromeTap = tableRangeOf(
              c.value,
              resolve: _resolveRange,
            );
          }
          // Pressing a grip selects the row / column it would move, before a
          // single pixel of movement. That selection *is* the "picked up"
          // feedback; the drop preview only appears once the pointer actually
          // travels, so it cannot wash over the selection's edge on press.
          _setCursor(_cursorAt(event.position));
          // Select on press, not on release: the grip is a selection control
          // first and a drag handle second, and what is about to move has to be
          // visible from the moment the button goes down. Shift extends from the
          // block recorded above; a plain press inside a multi-row/column
          // selection keeps that whole block lit, because that is what the drag
          // would move.
          if (HardwareKeyboard.instance.isShiftPressed) {
            _selectGrip(hit.$1, hit.$2, extend: true);
          } else if (_grabbedBlock(hit.$1, hit.$2) == null) {
            _selectGrip(hit.$1, hit.$2, extend: false);
          }
        }
        return;
      }
    }
    _caretBeforeCheckboxTap = _checkboxAt(event.position) == null
        ? null
        : widget.controller.selection;
    _downPosition = event.position;
    _gestureMoved = false;
    _secondaryGesture = secondary;
    final TextEditingController c = widget.controller;
    if (c is! MarkdownSourceController) return;

    // A right-click that lands outside the selection moves the caret *before*
    // the menu is built, so every row acts on what the pointer is on. Flutter
    // only does this when the field is unfocused, which is the rare half of the
    // cases — the menu is opened while editing, with the field already focused.
    if (secondary) {
      c.revealAs = null;
      c.disarmClickGuard();
      _placeCaret(c, event.position, keepSelection: true);
      return;
    }

    // Freeze the reveal for the whole gesture. A tap and a drag both start here,
    // and what the user is aiming at is what was painted a moment ago — letting
    // the markers appear the instant the button goes down reflows the line under
    // a hand that has not moved yet, which is how a drag over 「编辑器」 ends up
    // selecting 「编辑」. The reveal catches up on release.
    c.revealAs = c.paintedSelection ?? c.selection;
    // A click must stay a click. The guard has to live in the controller rather
    // than here — see [MarkdownSourceController.armClickGuard] — and the anchor
    // is taken *now*, while the reveal is still frozen, so it refers to the
    // layout the user is actually pointing at.
    c.disarmClickGuard();
    if (_checkboxAt(event.position) != null) return;
    final RenderEditable? editable = _editable();
    if (editable == null) return;
    int at = editable
        .getPositionForPoint(event.position)
        .offset
        .clamp(0, c.text.length);
    final ({TableBlock block, int row, int column, TableCell cell})? cell =
        _paintedCellAt(event.position);
    if (cell != null) at = _caretInCell(cell.cell, at);
    c.armClickGuard(at);
    if (cell != null && !HardwareKeyboard.instance.isShiftPressed) {
      // The field's own tap handler writes the skeleton offset on the way down;
      // a microtask is the last word on the event. A drag then extends from
      // here, and a fast second click's word selection is folded back to this
      // same offset by the guard.
      scheduleMicrotask(() {
        if (!mounted) return;
        if (widget.controller.text != c.text) return;
        if (!c.selection.isCollapsed) return;
        if (c.selection.start == at) return;
        c.selection = TextSelection.collapsed(offset: at);
      });
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final TableRowChrome? grabbed = _grabbedRow;
    final TableChromeTarget? target = _grabbed;
    if (grabbed != null && target != null) {
      final bool column = target.kind == TableChromeKind.columnHandle;
      final bool rowDrag = target.kind == TableChromeKind.rowHandle;
      if (!column && !rowDrag) return; // the plus buttons are clicks, not drags
      tablePointerPosition.value = event.position;
      if ((event.position - (_downPosition ?? event.position)).distance >
          kTouchSlop) {
        _gestureMoved = true;
      }
      if (!_gestureMoved) return;
      _dropAt = _dropIndex(grabbed, column, event.position);
      tableDragPreview.value = _previewFor(grabbed, target);
      return;
    }
    final Offset? from = _downPosition;
    if (from == null || _gestureMoved) return;
    if ((event.position - from).distance <= kTouchSlop) return;
    _gestureMoved = true;
    // It turned out to be a drag, and a range is exactly what a drag means:
    // let the guard go before the first move asks for one.
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController) c.disarmClickGuard();
  }

  void _onPointerUp(PointerUpEvent event) {
    final TableRowChrome? grabbed = _grabbedRow;
    final TableChromeTarget? target = _grabbed;
    if (grabbed != null && target != null) {
      final bool moved = _gestureMoved;
      _grabbedRow = null;
      _grabbed = null;
      _downPosition = null;
      _gestureMoved = false;
      tableDragPreview.value = null;
      tablePointerPosition.value = event.position;
      _setCursor(_cursorAt(event.position));
      // A grip is a selection control as much as a drag handle: a plain click
      // picks the whole row/column, Shift extends the block, and a drag that
      // started inside a multi-row/column selection moves the whole thing.
      final bool grip =
          target.kind == TableChromeKind.rowHandle ||
          target.kind == TableChromeKind.columnHandle;
      if (grip && !moved) {
        _selectGrip(
          grabbed,
          target,
          extend: HardwareKeyboard.instance.isShiftPressed,
        );
      } else if (grip && _applyBlockDrag(grabbed, target)) {
        // The block is selected at its new home.
      } else if (_applyChrome(grabbed, target, moved) && grip && moved) {
        // A single row / column was carried: keep it selected where it landed.
        // The `+` buttons are the opposite — their edit lands the selection in
        // the cell just created, which is exactly where typing should go next.
        _selectMoved(grabbed, target);
      }
      _rangeBeforeChromeTap = null;
      return;
    }
    final TextSelection? saved = _caretBeforeCheckboxTap;
    final bool secondary = _secondaryGesture;
    _caretBeforeCheckboxTap = null;
    _secondaryGesture = false;
    _endGesture();
    if (secondary) {
      // Right-click already put the caret where the pointer was, and the menu is
      // on its way up. The "a click is a click" cleanup below exists for the
      // left button's word/line selection; letting it run here would collapse
      // the very selection the menu is about to offer 复制 for.
      _downPosition = null;
      return;
    }
    final int? at = _checkboxAt(event.position);
    if (at == null) {
      // Whatever a fast click-talk let the platform select on the way *up*.
      final TextEditingController c = widget.controller;
      if (c is MarkdownSourceController) _clickCaret(c, event.position);
      _downPosition = null;
      return;
    }

    final TextEditingController c = widget.controller;
    final String next = toggleTaskAt(c.text, at);
    _downPosition = null;
    if (next == c.text) return;
    // `[ ]` ⇄ `[x]` is one character for one, so selections stay valid, the undo
    // stack survives and nothing downstream re-lays out.
    c.value = c.value.copyWith(text: next, composing: TextRange.empty);
    widget.onChanged?.call(next);
    if (saved != null) {
      // Give the caret back: flipping a checkbox should not also move the
      // insertion point (otherwise the next keystroke lands inside the marker).
      // The field's own caret move happens after this handler, so it has to be
      // undone in a microtask — same frame, no visible jump.
      scheduleMicrotask(() {
        if (mounted) c.selection = saved;
      });
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _grabbedRow = null;
    _grabbed = null;
    _rangeBeforeChromeTap = null;
    tableDragPreview.value = null;
    _setCursor(_cursorAt(event.position));
    _endGesture();
    _downPosition = null;
    _gestureMoved = false;
  }

  /// Hands the reveal back to the live caret and repaints.
  void _endGesture() {
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController && c.revealAs != null) {
      c.revealAs = null;
      c.repaint();
    }
  }

  // ------------------------------------------------------------- overlays

  /// The gesture's reading of the current selection, shared by the formatter,
  /// the shortcuts and the context menu.
  TableRange? _resolveRange(String text, TextSelection selection) {
    final TextEditingController c = widget.controller;
    return c is MarkdownSourceController ? c.rangeFor(text, selection) : null;
  }

  /// Coalesces the controller and scroll notifications into one post-frame
  /// pass: the statistics chip needs the table's *laid-out* box, and the
  /// selection may change several times inside a single event.
  void _scheduleOverlayRefresh() {
    if (_cellEdit != null) {
      // Scrolling moves the table out from under the floating editor; commit
      // before the anchor becomes a lie.
      _commitCellEditor();
    }
    if (_overlayRefreshScheduled) return;
    _overlayRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _overlayRefreshScheduled = false;
      if (!mounted) return;
      _refreshOverlays();
    });
  }

  void _refreshOverlays() {
    final TextEditingValue value = widget.controller.value;
    final TableRange? full = tableRangeOf(value, resolve: _resolveRange);
    final TableRange? show = full != null && !full.isSingleCell ? full : null;

    Rect? anchor;
    final RenderObject? root = context.findRenderObject();
    final RenderBox? box = root is RenderBox && root.hasSize ? root : null;
    if (box != null) _editorSize = box.size;
    if (show != null && box != null) {
      final List<TableRowChrome> rows =
          _tableRows()
              .where(
                (TableRowChrome row) => row.chromeTableId == show.block.start,
              )
              .toList()
            ..sort(
              (TableRowChrome a, TableRowChrome b) =>
                  a.chromeRowIndex.compareTo(b.chromeRowIndex),
            );
      // The chip belongs at the **selection's** bottom-right corner, not the
      // table's: a block of the first two rows on a ten-row table would
      // otherwise report itself twelve lines away from what is lit.
      final int at = rows.indexWhere(
        (TableRowChrome row) => row.chromeRowIndex == show.lastRow,
      );
      if (at >= 0) {
        final Rect rowBounds = rows[at].chromeBounds();
        final List<Rect> cells = rows[at].chromeCells();
        final Rect global = show.lastColumn < cells.length
            ? Rect.fromLTRB(
                cells[show.lastColumn].left,
                rowBounds.top,
                cells[show.lastColumn].right,
                rowBounds.bottom,
              )
            : rowBounds;
        anchor = Rect.fromPoints(
          box.globalToLocal(global.topLeft),
          box.globalToLocal(global.bottomRight),
        );
      }
    }

    final String? key = show == null ? null : _rangeKey(show);
    final String? label = show == null ? null : tableStatsLabel(show);
    if (key == _statsKey &&
        label == _statsLabel &&
        _sameRect(anchor, _statsAnchor)) {
      return;
    }
    setState(() {
      _statsKey = key;
      _statsLabel = label;
      _statsAnchor = anchor;
    });
  }

  static bool _sameRect(Rect? a, Rect? b) {
    if (a == null || b == null) return a == b;
    return (a.left - b.left).abs() < 0.5 &&
        (a.top - b.top).abs() < 0.5 &&
        (a.width - b.width).abs() < 0.5 &&
        (a.height - b.height).abs() < 0.5;
  }

  static String _rangeKey(TableRange r) =>
      '${r.block.start}:${r.kind.index}:${r.firstRow}:${r.lastRow}:'
      '${r.firstColumn}:${r.lastColumn}:${r.anchorRow}:${r.anchorColumn}';

  /// Opens the floating editor over the active cell. F2 and the menu's
  /// 编辑单元格 both come through here.
  void _openCellEditor() {
    if (widget.readOnly || _cellEdit != null) return;
    final TextEditingController controller = widget.controller;
    final active = tableActiveCell(controller.value, resolve: _resolveRange);
    if (active == null) return;
    final List<TableRowChrome> rows = _tableRows()
        .where(
          (TableRowChrome row) =>
              row.chromeTableId == active.block.start &&
              row.chromeRowIndex == active.row,
        )
        .toList();
    if (rows.isEmpty) return;
    final List<Rect> cells = rows.first.chromeCells();
    if (active.column < 0 || active.column >= cells.length) return;
    final RenderObject? root = context.findRenderObject();
    if (root is! RenderBox || !root.hasSize) return;

    final Rect local = Rect.fromPoints(
      root.globalToLocal(cells[active.column].topLeft),
      root.globalToLocal(cells[active.column].bottomRight),
    );
    final double width = (local.width + 24).clamp(
      300.0,
      math.min(560.0, math.max(300.0, root.size.width - 24)),
    );
    final double left = local.left.clamp(
      8.0,
      math.max(8.0, root.size.width - width - 8),
    );
    final double below = local.bottom + 8;
    final double top = below + 128 <= root.size.height - 8
        ? below
        : math.max(8.0, local.top - 136);

    final TextEditingController text = TextEditingController(
      text: active.cell.text,
    );
    final FocusNode focus = FocusNode(debugLabel: 'nrs-cell-editor');
    setState(() {
      _cellEdit = _CellEdit(
        tableStart: active.block.start,
        row: active.row,
        column: active.column,
        panel: Rect.fromLTWH(left, top, width, 120),
      );
      _cellText = text;
      _cellFocus = focus;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _cellEdit != null) focus.requestFocus();
    });
  }

  /// Writes the floating editor's text back into its cell and closes.
  ///
  /// Going through [setTableCellText] keeps every rule in one place: the value
  /// is escaped (newlines become `<br>`), the table keeps its shape, and the
  /// caret lands in the cell that was edited.
  void _commitCellEditor() {
    final _CellEdit? edit = _cellEdit;
    final TextEditingController? controller = _cellText;
    if (edit == null || controller == null) return;
    final String text = controller.text;
    _closeCellEditor();
    final TextEditingValue? next = setTableCellText(
      widget.controller.value,
      tableStart: edit.tableStart,
      row: edit.row,
      column: edit.column,
      text: text,
    );
    if (next == null) return;
    widget.controller.value = next;
    widget.onChanged?.call(next.text);
  }

  void _cancelCellEditor() => _closeCellEditor();

  void _closeCellEditor() {
    if (_cellEdit == null) return;
    final TextEditingController? text = _cellText;
    final FocusNode? focus = _cellFocus;
    setState(() {
      _cellEdit = null;
      _cellText = null;
      _cellFocus = null;
    });
    // The field is still mounted in this frame; dispose after it has been
    // removed, or the TextField's own listener teardown trips over a dead
    // controller.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      text?.dispose();
      focus?.dispose();
    });
    widget.focusNode.requestFocus();
  }

  /// Ctrl+V: read the clipboard and insert it through [pasteValue], so the
  /// table padding rule reaches the keyboard exactly as it reaches the menu.
  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text == null || text.isEmpty) return;
    final TextEditingValue next = pasteValue(
      widget.controller.value,
      text,
      resolve: _resolveRange,
    );
    widget.controller.value = next;
    widget.onChanged?.call(next.text);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_pinCaretAboveText);
    widget.controller.removeListener(_scheduleOverlayRefresh);
    widget.scrollController.removeListener(_scheduleOverlayRefresh);
    widget.focusNode.removeListener(_pinCaretAboveText);
    _cellText?.dispose();
    _cellFocus?.dispose();
    // The click guard deliberately outlives the pointer — the platform's word
    // selection lands a moment *after* the button comes up — but it must not
    // outlive the editor.
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController) c.disarmClickGuard();
    if (tablePointerPosition.value != null) tablePointerPosition.value = null;
    _undoHistory.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    // A rebuild of this widget rebuilds the field's span tree, which is exactly
    // when the framework writes the platform caret order back.
    _pinCaretAboveText();
    final AppPalette p = context.palette;
    final TextStyle style = editorProseStyle(p, widget.fontSize);
    // The field's own region is deeper than the editor's, so its cursor wins
    // wherever it covers the chrome — which is why a column grip used to show
    // the I-beam. Hand it the chrome cursor explicitly.
    final MouseCursor fieldCursor = _chromeCursor == MouseCursor.defer
        ? SystemMouseCursors.text
        : _chromeCursor;

    final Widget editor = Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.tab): const _IndentIntent(
          false,
        ),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true):
            const _IndentIntent(true),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            const _CopyIntent(),
        const SingleActivator(LogicalKeyboardKey.keyX, control: true):
            const _CutIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            const _PasteIntent(),
        const SingleActivator(
          LogicalKeyboardKey.keyV,
          control: true,
          shift: true,
        ): const _PasteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            const _HistoryIntent(undo: true),
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): const _HistoryIntent(
          undo: false,
        ),
        const SingleActivator(LogicalKeyboardKey.keyY, control: true):
            const _HistoryIntent(undo: false),
        // Spreadsheet muscle memory. Both only do something inside a table;
        // everywhere else they fall through untouched.
        const SingleActivator(LogicalKeyboardKey.keyD, control: true):
            const _FillIntent(down: true),
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            const _FillIntent(down: false),
        const SingleActivator(
          LogicalKeyboardKey.keyC,
          control: true,
          shift: true,
        ): const _TsvIntent(),
        const SingleActivator(LogicalKeyboardKey.f2): const _EditCellIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _IndentIntent: CallbackAction<_IndentIntent>(
            onInvoke: (_IndentIntent intent) {
              // Inside a table, Tab is *cell navigation*, not indentation —
              // the same key every spreadsheet and Obsidian use. Only when the
              // caret is not in a table does it fall through to the list
              // indent it has always been.
              final TextEditingValue? cell = tableCellStep(
                widget.controller.value,
                forward: !intent.outdent,
              );
              // The landing cell is a range so typing replaces its content, and
              // the click guard would fold that range to the click that was
              // still inside its 400 ms window.
              if (cell != null) _disarmClickGuard();
              final TextEditingValue next =
                  cell ??
                  indentLines(widget.controller.value, outdent: intent.outdent);
              widget.controller.value = next;
              widget.onChanged?.call(next.text);
              return null;
            },
          ),
          _CopyIntent: CallbackAction<_CopyIntent>(
            onInvoke: (_CopyIntent intent) {
              final TextEditingValue v = widget.controller.value;
              final String out =
                  tableSelectionMarkdown(
                    v.text,
                    v.selection,
                    resolve: _resolveRange,
                  ) ??
                  v.selection.textInside(v.text);
              if (out.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: out));
              }
              return null;
            },
          ),
          _CutIntent: CallbackAction<_CutIntent>(
            onInvoke: (_CutIntent intent) {
              final TextEditingValue v = widget.controller.value;
              if (v.selection.isCollapsed) return null;
              // The clipboard gets the cells (a table) or the plain text, and
              // the document loses the **same** rectangle: a partial cell
              // block is cleared in place, a whole-row sweep takes the rows.
              // Splicing the raw source range is what left half a cell behind.
              final TableRange? range = tableRangeOf(v, resolve: _resolveRange);
              final String out =
                  range?.markdown ?? v.selection.textInside(v.text);
              unawaited(Clipboard.setData(ClipboardData(text: out)));
              final TextEditingValue value;
              if (range != null) {
                value = tableRangeClear(range);
              } else {
                final int start = v.selection.start.clamp(0, v.text.length);
                final String next =
                    v.selection.textBefore(v.text) +
                    v.selection.textAfter(v.text);
                value = TextEditingValue(
                  text: next,
                  selection: TextSelection.collapsed(
                    offset: start.clamp(0, next.length),
                  ),
                );
              }
              widget.controller.value = value;
              widget.onChanged?.call(value.text);
              return null;
            },
          ),
          _PasteIntent: CallbackAction<_PasteIntent>(
            onInvoke: (_PasteIntent intent) {
              unawaited(_pasteFromClipboard());
              return null;
            },
          ),
          _HistoryIntent: CallbackAction<_HistoryIntent>(
            onInvoke: (_HistoryIntent intent) {
              _navigatingHistory = true;
              try {
                if (intent.undo) {
                  _undoHistory.undo();
                } else {
                  _undoHistory.redo();
                }
              } finally {
                _navigatingHistory = false;
              }
              return null;
            },
          ),
          _FillIntent: CallbackAction<_FillIntent>(
            onInvoke: (_FillIntent intent) {
              final TextEditingValue? next = tableFill(
                widget.controller.value,
                down: intent.down,
                resolve: _resolveRange,
              );
              if (next == null) return null;
              widget.controller.value = next;
              widget.onChanged?.call(next.text);
              return null;
            },
          ),
          _TsvIntent: CallbackAction<_TsvIntent>(
            onInvoke: (_TsvIntent intent) {
              final TextEditingValue v = widget.controller.value;
              final String? out =
                  tableSelectionTsv(
                    v.text,
                    v.selection,
                    resolve: _resolveRange,
                  ) ??
                  tableActiveCell(v, resolve: _resolveRange)?.cell.text;
              if (out != null && out.isNotEmpty) {
                Clipboard.setData(ClipboardData(text: out));
              }
              return null;
            },
          ),
          _EditCellIntent: CallbackAction<_EditCellIntent>(
            onInvoke: (_EditCellIntent intent) {
              _openCellEditor();
              return null;
            },
          ),
        },
        // The `Listener` wraps the whole scroll view, not the field, and it is
        // **opaque**: a table's grips and plus buttons hang *outside* the
        // field's box (left of the table, above it, below its last line), and a
        // `deferToChild` listener only hears about pointers that hit the field
        // itself. That is why a click on the grip did nothing at first.
        child: MouseRegion(
          cursor: _chromeCursor,
          onHover: _onPointerHover,
          onExit: _onPointerExit,
          child: Listener(
            key: _fieldKey,
            behavior: HitTestBehavior.opaque,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: _ChromeShield(
              blocks: (Offset position) => _chromeAt(position) != null,
              child: SingleChildScrollView(
                controller: widget.scrollController,
                padding: widget.padding,
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: widget.maxWidth),
                    // The column width is measured here rather than guessed by the
                    // pane: the renderer sizes code bands and inline images from it,
                    // and a widget one pixel wider than the line makes it wrap.
                    child: LayoutBuilder(
                      builder: (BuildContext context, BoxConstraints c) {
                        final TextEditingController ctrl = widget.controller;
                        if (ctrl is MarkdownSourceController) {
                          ctrl.contentWidth = c.maxWidth;
                        }
                        return Focus(
                          // Not a tab stop — just a listener this close to the
                          // field, so table caret keys are decided before the
                          // platform's line movement (and before Shortcuts).
                          canRequestFocus: false,
                          skipTraversal: true,
                          onKeyEvent: _onTableKey,
                          child: TextField(
                            key: const Key('nrs-editor-field'),
                            controller: widget.controller,
                            focusNode: widget.focusNode,
                            undoController: _undoHistory,
                            readOnly: widget.readOnly,
                            onChanged: widget.onChanged,
                            maxLines: null,
                            expands: false,
                            autofocus: false,
                            mouseCursor: fieldCursor,
                            cursorColor: p.accent,
                            cursorWidth: 1.8,
                            cursorRadius: const Radius.circular(1),
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            inputFormatters: <TextInputFormatter>[
                              ListContinuationFormatter(),
                              // Last, so it sees the text every other formatter has
                              // already agreed on: a Backspace must never leave the
                              // cell the caret is in.
                              TableCellBarrierFormatter(
                                suspend: () => _navigatingHistory,
                                resolve: _resolveRange,
                              ),
                            ],
                            style: style,
                            // The field's own wash is transparent (see the
                            // `DefaultSelectionStyle` around `editor`), but these two
                            // still define the boxes `EditorSelectionPainter` paints
                            // and the caret is measured from.
                            //
                            // Flutter's desktop default is `BoxWidthStyle.max`, which
                            // makes every fully selected line a band running to the
                            // right edge of the column — a highlighted *block*, not
                            // highlighted *text*. Obsidian (and every desktop editor)
                            // hugs the glyphs, so `tight` it is.
                            //
                            // ⛔ Do not drop these two lines "because the default is
                            // fine": `max` is what turned a Ctrl+A into full-width
                            // stripes.
                            //
                            // The height style has to cover exactly the line box:
                            // `EditorSelectionPainter` pulls [kSelectionLineGap] out
                            // of each box to leave the seam, and a shorter box would
                            // eat into the line's own spacing. `Middle` is shifted
                            // ~3px down inside the line, so on a table — whose wash
                            // is painted to the same box — it left a strip of the
                            // paragraph's own highlight under the rounded bottom
                            // edge. `…Top` puts the box on the line, and the painter
                            // adds the seam on purpose.
                            selectionWidthStyle: ui.BoxWidthStyle.tight,
                            selectionHeightStyle:
                                ui.BoxHeightStyle.includeLineSpacingTop,
                            // No forced strut: headings are allowed to be taller than
                            // body text, and a hidden marker must collapse fully.
                            strutStyle: null,
                            decoration: InputDecoration(
                              isDense: true,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              hintText: widget.hintText,
                              hintStyle: style.copyWith(
                                color: p.textTertiary.withValues(alpha: 0.7),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            // The one hook that decides whether right-click reaches
                            // [buildEditorContextMenu] at all. `SelectionOverlay`
                            // routes the toolbar through `contextMenuBuilder` *only*
                            // when the controls are a [TextSelectionHandleControls];
                            // with a plain [TextSelectionControls] it silently falls
                            // back to the deprecated `toolbarOptions` menu and this
                            // builder is never called. The handle variant is the same
                            // Material control — it just says "handles are mine, the
                            // menu is the app's".
                            selectionControls:
                                materialTextSelectionHandleControls,
                            contextMenuBuilder:
                                (
                                  BuildContext context,
                                  EditableTextState state,
                                ) {
                                  return buildEditorContextMenu(
                                    state: state,
                                    value: widget.controller.value,
                                    onApply: _applyEdit,
                                    onDismiss: state.hideToolbar,
                                    resolve: _resolveRange,
                                    onEditCell: _openCellEditor,
                                  );
                                },
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Two surfaces float above the field: the low-contrast statistics chip
    // under the selection, and the F2 cell editor. Both are siblings of the
    // field rather than children of it, so the shortcuts inside the floating
    // TextField (Ctrl+C, arrows, Enter) belong to *that* field and are not
    // intercepted by the table actions.
    final _CellEdit? cell = _cellEdit;
    return Stack(
      children: <Widget>[
        // The selection's wash is painted here rather than by the field, so
        // every line can leave a two-pixel seam between its band and the next
        // one. The field's own boxes still decide the geometry (see
        // `EditorSelectionPainter`), and its built-in colour is transparent.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: EditorSelectionPainter(
                controller: widget.controller,
                scrollController: widget.scrollController,
                focusNode: widget.focusNode,
                editable: _editable,
                editorBox: () {
                  final RenderObject? root = context.findRenderObject();
                  return root is RenderBox && root.hasSize ? root : null;
                },
                color: p.selection,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DefaultSelectionStyle.merge(
            // The field's own wash tiles line to line. The bands, with their
            // seams, are painted by `EditorSelectionPainter` on the paper
            // behind this subtree. Only the main field is made transparent —
            // the F2 cell editor is a sibling and keeps its normal highlight.
            selectionColor: Colors.transparent,
            child: editor,
          ),
        ),
        if (_statsAnchor != null && _statsLabel != null)
          Positioned(
            top: _statsAnchor!.bottom + 6,
            right: math.max(8.0, _editorSize.width - _statsAnchor!.right),
            child: IgnorePointer(
              child: _TableStatsChip(label: _statsLabel!, palette: p),
            ),
          ),
        if (cell != null &&
            _cellText != null &&
            _cellFocus != null) ...<Widget>[
          // Clicking anywhere else commits, like every spreadsheet's formula
          // bar: the edit is never silently thrown away by moving on.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _commitCellEditor,
            ),
          ),
          Positioned.fromRect(
            rect: cell.panel,
            child: _CellEditorPanel(
              address: _cellAddress(cell.row, cell.column),
              controller: _cellText!,
              focusNode: _cellFocus!,
              palette: p,
              onCommit: _commitCellEditor,
              onCancel: _cancelCellEditor,
            ),
          ),
        ],
      ],
    );
  }
}

/// How far around a checkbox still counts as hitting it (logical pixels).
///
/// Small on purpose: the padded shell is already 26px wide, and a generous slop
/// would start swallowing clicks on the text beside it.
const double _kCheckboxTouchSlop = 4;

/// One open floating cell editor.
class _CellEdit {
  const _CellEdit({
    required this.tableStart,
    required this.row,
    required this.column,
    required this.panel,
  });

  final int tableStart;
  final int row;
  final int column;

  /// Where the panel sits, in the editor's own coordinates.
  final Rect panel;
}

/// Keeps a press that lands on the painted table chrome out of the field.
///
/// The chrome hangs off the table: a column grip sits *above* it, over a
/// normal text line. The field's own drag recognizer therefore read that press
/// as the start of a text selection and replaced the column selection the grip
/// had just made — the purple band disappeared mid-drag, while a row grip,
/// outside the text, kept it. Skipping the child here stops the field from
/// seeing the pointer; adding this box to the hit path keeps the editor's raw
/// [Listener], the shield's parent, receiving it. Hover still reaches the
/// surrounding [MouseRegion] for the same reason.
class _ChromeShield extends SingleChildRenderObjectWidget {
  const _ChromeShield({required this.blocks, required super.child});

  /// Whether [globalPosition] lands on a painted control.
  final bool Function(Offset globalPosition) blocks;

  @override
  _RenderChromeShield createRenderObject(BuildContext context) =>
      _RenderChromeShield(blocks);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderChromeShield renderObject,
  ) {
    renderObject.blocks = blocks;
  }
}

class _RenderChromeShield extends RenderProxyBox {
  _RenderChromeShield(this.blocks);

  bool Function(Offset globalPosition) blocks;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    if (blocks(localToGlobal(position))) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return super.hitTest(result, position: position);
  }
}

/// Spreadsheet-style column letters: 0 → A, 25 → Z, 26 → AA.
String _cellAddress(int row, int column) {
  int n = column + 1;
  String letters = '';
  while (n > 0) {
    final int r = (n - 1) % 26;
    letters = String.fromCharCode(0x41 + r) + letters;
    n = (n - 1) ~/ 26;
  }
  return '$letters${row + 1}';
}

/// The low-contrast strip under a selected table block: how many cells, how
/// many are filled, and what the numbers add up to.
class _TableStatsChip extends StatelessWidget {
  const _TableStatsChip({required this.label, required this.palette});

  final String label;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: palette.surfaceRaised.withValues(alpha: 0.94),
        borderRadius: AppRadius.pillAll,
        border: Border.all(color: palette.outlineSoft),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
          fontSize: 10.5,
          height: 1.25,
          color: palette.textTertiary,
          fontFeatures: const <ui.FontFeature>[ui.FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The F2 floating editor: a real multi-line field for a cell whose text does
/// not fit the one-line row, with the same commit/cancel grammar as a dialog.
class _CellEditorPanel extends StatelessWidget {
  const _CellEditorPanel({
    required this.address,
    required this.controller,
    required this.focusNode,
    required this.palette,
    required this.onCommit,
    required this.onCancel,
  });

  final String address;
  final TextEditingController controller;
  final FocusNode focusNode;
  final AppPalette palette;
  final VoidCallback onCommit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = palette;
    final TextStyle body = TextStyle(
      fontFamily: AppFonts.prose,
      fontFamilyFallback: AppFonts.proseFallback,
      fontSize: 13.5,
      height: 1.5,
      color: p.textPrimary,
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // Shift+Enter is deliberately not bound: it falls through to the field
        // and inserts the line break a long cell needs.
        const SingleActivator(LogicalKeyboardKey.escape): onCancel,
        const SingleActivator(LogicalKeyboardKey.enter): onCommit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onCommit,
      },
      child: Material(
        elevation: 18,
        shadowColor: p.shadow,
        color: p.surfaceRaised,
        borderRadius: AppRadius.mdAll,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          decoration: BoxDecoration(
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: p.outlineSoft),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: p.accentSoft,
                      borderRadius: AppRadius.smAll,
                    ),
                    child: Text(
                      address,
                      style: TextStyle(
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                        fontSize: 10.5,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: p.accent,
                        fontFeatures: const <ui.FontFeature>[
                          ui.FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Text(
                    '单元格',
                    style: TextStyle(
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                      fontSize: 11.5,
                      height: 1.2,
                      color: p.textSecondary,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // A narrow panel truncates the hint rather than overflowing:
                  // the field below is the point, the hint is a reminder.
                  Expanded(
                    child: Text(
                      'Enter 确认 · Shift+Enter 换行 · Esc 取消',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                        fontSize: 10.5,
                        height: 1.2,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: body,
                  cursorColor: p.accent,
                  cursorWidth: 1.6,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: p.surfaceSunken,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                      vertical: AppSpace.sm,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: AppRadius.smAll,
                      borderSide: BorderSide(color: p.outlineSoft),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: AppRadius.smAll,
                      borderSide: BorderSide(color: p.outlineSoft),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: AppRadius.smAll,
                      borderSide: BorderSide(color: p.accent),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
