import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerScrollEvent,
        PointerSignalEvent,
        kDoubleTapTimeout,
        kSecondaryMouseButton,
        kTouchSlop;
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart' hide TableCell, TableRow;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../../core/platform/drop_support.dart';
import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/clipboard_image.dart';
import '../../core/utils/dropped_link.dart';
import '../../core/utils/html_source.dart';
import '../../core/utils/image_markup.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/markdown_outline.dart';
import '../../core/utils/table_model.dart';
import '../../core/utils/table_selection.dart';
import '../../state/settings_controller.dart';
import '../common/notices.dart';
import 'code_block_painter.dart';
import 'editor_context_menu.dart';
import 'image_viewer.dart';
import 'line_layout/line_editable_text.dart';
import 'line_layout/line_layout_engine.dart';
import 'line_layout/line_layout_pool.dart';
import 'line_layout/live_line_style.dart';
import 'line_layout/render_line_editable.dart';
import 'list_fold_painter.dart';
import 'live_markdown.dart';
import 'selection_wash.dart';

/// The one and only NRS editing surface: a plain [TextEditingController] whose
/// text *is* the Markdown.
///
/// 排版不在这里发生。按行引擎（`RenderLineEditable`）逐行取样式、按源码偏移
/// 上屏，所以这个控制器只负责源码本身、揭示选区（[revealAs]）和表格手势；
/// 过去那棵「画出来的 span 树」只服务于单段落排版，已经随那条路径退场。
class MarkdownSourceController extends TextEditingController {
  MarkdownSourceController({super.text});

  /// Fired when the user flips a task checkbox from inside the editor, so the
  /// draft — and the debounced auto-save — can pick the new text up.
  void Function(String newText)? onExternalChange;

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

  /// 刚绑定笔记、用户还没在正文里落过点：光标停在文首只是“停着”，不是在编辑。
  ///
  /// 揭示是按选区算的，若不按住，第一行是标题 / 引用的笔记一打开就露出 `# `
  /// 或 `>`，看起来像自动进了编辑模式。正文里任何一次落点、光标移动或输入
  /// 都会把它清掉（见 `EditorPane` 与两个落点处理）。
  bool revealSuppressed = false;

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
    // the block. Composing text over a range is written into the active cell,
    // and the composition is kept there so each preedit update replaces the
    // previous one instead of appending to it.
    if (!oldValue.selection.isCollapsed) {
      final TextEditingValue? handled = tableSelectionEdit(
        oldValue,
        newValue,
        resolve: resolve,
      );
      if (handled != null) return handled;
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

/// 撤销/重做把光标放回这次编辑发生的位置。
///
/// 历史记录里快照的选区属于**上一次**编辑，不能直接拿来当本次编辑的位置：
/// 多次撤销时它会让光标停在上一处，靠近时甚至只差一个字符。这里只按新旧
/// 正文的公共前后缀找出本次的变化区间：
///
/// - 正文变短（撤销一次插入）：落在被删掉文字的起点，也就是当初的插入点；
/// - 正文变长或等长（撤销删除、重做）：落在新内容的末尾。
int _historyCaretOffset(String before, String after) {
  final int shared = before.length < after.length
      ? before.length
      : after.length;
  int prefix = 0;
  while (prefix < shared &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  int suffix = 0;
  final int tail = shared - prefix;
  while (suffix < tail &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  final int newEnd = after.length - suffix;
  return after.length < before.length ? prefix : newEnd;
}

/// Keeps list bullets alive when the user presses Enter, steps an empty nested
/// item out one level, and ends the list on an empty top-level item. Implemented
/// as an input formatter so it sits directly in the native newline path instead
/// of fighting the text input system.
class ListContinuationFormatter extends TextInputFormatter {
  static final RegExp _listRe = RegExp(
    r'^(\s{0,})([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?(.*)$',
  );
  static final RegExp _quoteRe = RegExp(r'^(\s{0,3}>)(\s?)(.*)$');
  static final RegExp _orderedRe = RegExp(r'^(\d+)([.)])$');

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
    // "Is the caret at the end of its line" is `caret == lineEndOf(...)`,
    // *not* "does the rest of the text contain a newline" — the newline that
    // ends the line the caret is on sits at the caret itself, so the looser
    // question answers "yes, mid-line" for every line that has anything after
    // it. That inverted test is why continuation only ever worked on the last
    // line of a document.
    //
    // 行中回车在列表里同样要接上：`15. [ ] 序号排列|问题` 在竖线处回车，
    // 后半段要成为新的 `16.` 条目，而不是一条没有标记的裸行。只有“在行尾
    // 把空条目带走”这类收尾动作必须留在行尾。
    final int lineStart = lineStartOf(oldValue.text, at);
    final int lineEnd = lineEndOf(oldValue.text, at);
    final bool atLineEnd = at == lineEnd;

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

    final String line = oldValue.text.substring(lineStart, at);

    final Match? quote = _quoteRe.firstMatch(line);
    if (atLineEnd && quote != null && quote.group(3)!.trim().isEmpty) {
      // Enter on an empty `> ` ends the quote. 行中回车时标点后面还有正文，
      // 收走标记会把它们一起吞掉。
      return _dropMarker(newValue, lineStart, at - lineStart, at);
    }

    final Match? m = _listRe.firstMatch(line);
    if (m == null) return newValue;

    final String indent = m.group(1)!;
    final String marker = m.group(2)!;
    final String checkbox = m.group(3) ?? '';
    final String content = m.group(4) ?? '';

    if (content.trim().isEmpty) {
      // An empty item at the end of its line means "step out": one level out
      // when there is a parent item above to step to — `  - ` becomes `- ` —
      // and off the list entirely at the top. 行中回车时标记后面还有正文，
      // 删标记会把后半段一起删掉，这里只换行。
      if (!atLineEnd) return newValue;
      final ({String indent, String marker, bool separated})? parent =
          indent.isEmpty
          ? null
          : _parentItem(oldValue.text, lineStart, indent.length);
      if (parent != null) {
        return _stepOut(
          oldValue,
          newValue,
          lineStart,
          at,
          parentIndent: parent.indent,
          parentMarker: parent.marker,
          parentSeparated: parent.separated,
          marker: marker,
          checkbox: checkbox,
        );
      }
      return _dropMarker(newValue, lineStart, at - lineStart, at);
    }

    // `1. ` becomes `2. `, keeping the separator the user chose (`.` or `)`).
    // `tryParse` rather than `parse`: a run of digits long enough to overflow an
    // int is a typo, not a list, and Enter must never throw.
    String nextMarker = marker;
    final Match? num = _orderedRe.firstMatch(marker);
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

  /// The nearest list item above with a *smaller* indent — the level an empty
  /// item steps out to — or null when there is none at all.
  ///
  /// Blank lines belong to the list and are skipped. A paragraph, rule, heading
  /// or any other line is a break: it ends the list the item is part of, but the
  /// walk keeps going so an item indented under a list that such a break cut off
  /// can still step out to that list's level. `separated` reports whether a
  /// break was crossed on the way up, which is what makes the landing level a
  /// fresh list instead of a continuation. 被回车（空行）隔开不算断开。
  ({String indent, String marker, bool separated})? _parentItem(
    String text,
    int lineStart,
    int indent,
  ) {
    int end = lineStart - 1;
    bool separated = false;
    while (end >= 0) {
      final int start = end == 0 ? 0 : text.lastIndexOf('\n', end - 1) + 1;
      final String line = text.substring(start, end);
      if (line.trim().isNotEmpty) {
        final Match? m = _listRe.firstMatch(line);
        if (m == null) {
          separated = true;
        } else {
          final String above = m.group(1)!;
          if (above.length < indent) {
            return (indent: above, marker: m.group(2)!, separated: separated);
          }
        }
      }
      end = start - 1;
    }
    return null;
  }

  /// Rewrites the empty item just before the newline at [at] as an item at the
  /// parent's level.
  ///
  /// Stepping out *is* what that Enter does, so its newline is consumed: with
  /// text below, the empty item's own newline still ends the outdented line;
  /// at the bottom of the document the item simply changes level in place. An
  /// ordered item takes the next number of the level it lands on — the child's
  /// own number is local to the child level — while a bullet or task keeps the
  /// kind the user was writing. When that level was cut off from this item by
  /// other content, the landing item starts the number sequence over at 1: the
  /// old sequence is not the one it joins. 只隔空行不算隔开，父级序号照常接续。
  ///
  /// The edit adds no line, so the renumber formatter's "line count changed"
  /// gate would never see it; renumber here, forcibly, or the parent-level
  /// items below keep their old numbers and the new item collides with them.
  TextEditingValue _stepOut(
    TextEditingValue oldValue,
    TextEditingValue newValue,
    int lineStart,
    int at, {
    required String parentIndent,
    required String parentMarker,
    required bool parentSeparated,
    required String marker,
    required String checkbox,
  }) {
    String nextMarker = marker;
    final Match? num = _orderedRe.firstMatch(marker);
    if (num != null) {
      final String separator = num.group(2)!;
      if (parentSeparated) {
        nextMarker = '1$separator';
      } else {
        final Match? parentNum = _orderedRe.firstMatch(parentMarker);
        final int? n = int.tryParse(parentNum?.group(1) ?? '');
        if (n != null) nextMarker = '${n + 1}$separator';
      }
    }
    final String insert =
        '$parentIndent$nextMarker ${checkbox.isEmpty ? '' : '[ ] '}';
    final String text =
        newValue.text.substring(0, lineStart) +
        insert +
        newValue.text.substring(at + 1);
    return renumberAfterLineChange(
      oldValue,
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: lineStart + insert.length),
      ),
      force: true,
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

/// 增删整行后把有序列表的序号接上：删掉 `16.` 那一条，下面的 `17.` 变回
/// `16.`；在中间回车插进一条，后面的序号依次后移。
///
/// 只看“行数变没变”：逐字输入不会改行数；粘贴多行会被
/// [renumberAfterLineChange] 里的单个换行判断挡掉，序号原样保留。
class OrderedListRenumberFormatter extends TextInputFormatter {
  OrderedListRenumberFormatter({this.suspend});

  /// 撤销/重做送进来的是记下来的状态，不是一次编辑，不能借机重排。
  final bool Function()? suspend;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (suspend?.call() ?? false) return newValue;
    return renumberAfterLineChange(oldValue, newValue);
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
/// as a broken row. The cut path snaps the deleted range to whole rows; see
/// `TableRange`.
class _CutIntent extends Intent {
  const _CutIntent();
}

/// Ctrl+V on the body — the same insert as the context menu's paste, so a
/// pasted table gets the blank line that keeps it apart from the table above it.
/// See [padTablePaste].
class _PasteIntent extends Intent {
  const _PasteIntent();
}

/// 正文自己的撤销历史。
///
/// 输入框自带的 `UndoHistory` 会把 500ms 内的多次输入合并成一条记录，焦点后
/// 的第一条快照还可能被随后的一次输入挤掉：输入 7 次再撤销 7 次，正文仍会
/// 留下内容。这里改为每次正文变化都记账，但把「连续在同一处键入」合并成一
/// 块——撤销按块走，跟主流编辑器（VS Code、CodeMirror 的 history）一致：一段
/// 字一次撤掉，光标挪到别处再输才算新的一块。
///
/// 合并靠位置判断，不靠节流：这次变化必须紧接上一块留下的光标，且方向相同
/// （连续插入或连续删除）。把光标挪开、点选文字、组合输入都会断开这一块。
/// 组合输入（拼音未上屏）期间不记录，整段上屏算一步；只改选区不改正文的
/// 变化只更新基线，不产生历史。
/// 一段源码行先问表格、再问图片。
///
/// 两者是互斥的：表格行不是段落，图片只认整行单图，所以先后顺序只影响
/// 一次空解析，不影响语义。
class _LineBlockResolver {
  _LineBlockResolver(this.tables, this.images);

  final LiveTableBlocks tables;
  final LiveImageBlocks images;

  LineBlockView? blockFor(SourceLine line, LineBlockContext ctx) =>
      tables.blockFor(line, ctx) ?? images.blockFor(line, ctx);
}

class _EditHistory {
  _EditHistory(this._last);

  static const int _limit = 100;

  final List<TextEditingValue> _undo = <TextEditingValue>[];
  final List<TextEditingValue> _redo = <TextEditingValue>[];

  /// 控制器最近一次的值；[observe] 用它作为下一次编辑前的快照。
  TextEditingValue _last;

  /// 写回历史值时置位，避免把还原动作再记成一次编辑。
  bool _applying = false;

  /// 当前这一块是不是插入；上一块结束时光标落在哪个偏移。
  bool _inserting = false;
  int _caretAfter = 0;

  /// 当前位置还能不能接着上一块合并。
  bool _merge = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// 记录一次控制器变化。
  void observe(TextEditingValue value) {
    if (_applying) return;
    // 组合输入中间态不进历史，等上屏那一下再和组合前一起记。
    if (!value.composing.isCollapsed) return;
    if (value.text == _last.text) {
      // 点选一段文字才是明确的断点；光标还落在上一块附近时，框架补发的
      // 选区更新不能把一段字切成好几块。
      if (!value.selection.isCollapsed) _merge = false;
      _last = value;
      return;
    }

    final String before = _last.text;
    final String after = value.text;
    final int shared = before.length < after.length
        ? before.length
        : after.length;
    int prefix = 0;
    while (prefix < shared &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    int suffix = 0;
    final int tail = shared - prefix;
    while (suffix < tail &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    final bool inserting = after.length > before.length;
    final int removed = inserting ? 0 : before.length - after.length;
    // 插入接着上一块的末尾写；删除接着上一块的起点往前/往后删。
    final bool continues =
        _merge &&
        inserting == _inserting &&
        (inserting
            ? prefix == _caretAfter
            : removed > 0 &&
                  (prefix == _caretAfter || prefix + removed == _caretAfter));
    if (!continues) {
      _undo.add(_last);
      if (_undo.length > _limit) _undo.removeAt(0);
    }
    _redo.clear();
    _inserting = inserting;
    _caretAfter = inserting ? after.length - suffix : prefix;
    _merge = true;
    _last = value;
  }

  /// 要还原到的值；没有历史时返回 `null`。
  TextEditingValue? undo() {
    if (_undo.isEmpty) return null;
    _redo.add(_last);
    final TextEditingValue target = _undo.removeLast();
    _last = target;
    return target;
  }

  TextEditingValue? redo() {
    if (_redo.isEmpty) return null;
    _undo.add(_last);
    final TextEditingValue target = _redo.removeLast();
    _last = target;
    return target;
  }

  void beginApply() => _applying = true;

  /// Ends the current block, so the next change always starts a fresh undo step.
  ///
  /// A pasted image arrives right after whatever was typed; without this the
  /// insertion can be folded into that typing block and one Ctrl+Z erases both.
  void breakMerge() => _merge = false;

  /// 结束写回，并把基线对齐到控制器真正落下的值。
  ///
  /// 撤销/重做之后的第一次输入要另起一块，不能并进刚还原的那一步里。
  void endApply(TextEditingValue value) {
    _applying = false;
    _merge = false;
    _last = value;
  }
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

/// 正在被拖动的那条列分隔线，按下时记下的一切。
///
/// [boundary] 是线**左边**那一列的下标；拖最右外沿时它就是最后一列，没有
/// 右邻列（见 [_resizeTo]）。所有宽度都是渲染像素。
typedef _Resize = ({
  int tableId,
  int boundary,
  double startX,
  double boundaryX,
  double room,
  double scale,
  List<double> widths,
});

/// The Markdown editing surface.
class MarkdownEditor extends StatefulWidget {
  const MarkdownEditor({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.fontSize,
    this.padding = const EdgeInsets.fromLTRB(40, 28, 40, 200),
    this.maxWidth = AppLayout.proseMaxWidth,
    this.header,
    this.shortcuts = const <ShortcutActivator, Intent>{},
    this.actions = const <Type, Action<Intent>>{},
    this.onChanged,
    this.onTopLineChanged,
    this.onLineTopProbe,
    this.onJumpSettled,
    this.onTagTap,
    this.onWikilinkTap,
    this.onLinkTap,
    this.documentId,
    this.searchHighlight,
    this.searchHighlightColor,
    this.savePastedImage,
    this.imageProviderFor,
    this.imagePathFor,
    this.readOnly = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final double fontSize;
  final EdgeInsets padding;
  final double maxWidth;

  /// Scrolls with the document above the first line: the note's title.
  ///
  /// It lives inside the scroll view but outside [shortcuts] and the editor's
  /// own key handling — while the title has focus, Ctrl+Z must undo the title,
  /// not the body underneath it.
  final Widget? header;

  /// Host shortcuts and actions for the body, applied only to the field.
  ///
  /// They sit outside the editor's own maps (so the editor's finer-grained
  /// handling wins) but inside the scroll view, which keeps them away from
  /// [header].
  final Map<ShortcutActivator, Intent> shortcuts;
  final Map<Type, Action<Intent>> actions;

  final ValueChanged<String>? onChanged;

  /// Reports the source line at the top of the viewport on every scroll, so a
  /// reader who is only scrolling still gets the right section in the outline.
  final ValueChanged<int>? onTopLineChanged;

  /// 把「源码行 → 滚动内容坐标里的 y」交给宿主（大纲跳转用）。
  ///
  /// 每行高度由行引擎按自己的字号量出来，宿主推算不出来；这个口子在挂载时
  /// 注册、卸载时注销，调用时再向渲染对象取当前排版结果。返回值包含滚动内边距
  /// 与头部（标题）的高度，滚动控制器要的正是这个坐标。
  final ValueChanged<double? Function(int line)?>? onLineTopProbe;

  /// 把「立刻重排 + 重绘一次正文输入框」的能力交给宿主（大纲跳转用）。
  ///
  /// 按行绘制只画当前视口区间：跳转那一帧若把区间算成空段（或该帧因为需要
  /// 排版被跳过绘制），位置落定之后就再没有新帧，屏幕会一直空白到下一次
  /// hover。宿主在跳转后调用一次，把最终画面落定。挂载时注册、卸载时注销。
  final ValueChanged<VoidCallback?>? onJumpSettled;

  /// 点击 `#标签` 胶囊时回调，参数是不带 `#` 的标签名。
  ///
  /// 标签胶囊是渲染层画出来的，没有 widget 可以挂手势；点击由编辑器自己
  /// 在指针抬起时命中判定，命中后才通知宿主去切换搜索。
  final ValueChanged<String>? onTagTap;

  /// 点击 `[[双链]]` 时回调，参数是方括号里的目标标题。
  ///
  /// 链接和标签一样没有 widget 可以挂手势：命中由编辑器在指针抬起时按
  /// 渲染层自己的字形矩形判定。
  final ValueChanged<String>? onWikilinkTap;

  /// 点击 `[标签](地址)` 时回调，参数是可直接交给浏览器的地址。
  ///
  /// 只认 http/https 外链；相对路径不在这里处理。
  final ValueChanged<String>? onLinkTap;

  /// 当前正文的身份：笔记 id，外加宿主自己的版本号。
  ///
  /// 撤销栈跟着 [controller] 走，切笔记时控制器被整段改写；不在这里清栈，
  /// 一次 Ctrl+Z 就会把**上一份笔记**的正文恢复进来，而自动保存会把它写回
  /// 现在这份文件——等于用旧内容覆盖文件。换文档必须从空历史开始；同一个
  /// 笔记的正文被外部版本整段替换时，宿主也会换一个值，效果相同。
  final String? documentId;

  /// 搜索框里的词，命中处由渲染层铺色带。
  ///
  /// 只影响绘制：不碰排版，所以在搜索框里敲字不会让整篇正文重排。
  final ({String needle, bool caseSensitive})? searchHighlight;

  /// 搜索色带的颜色。
  final Color? searchHighlightColor;

  /// 把剪贴板里的一张图片存成 `assets/` 下的文件，返回可直接写进正文的相对
  /// 路径；存储不支持时返回 null。
  ///
  /// 为 null（例如 Web 构建）时，Ctrl+V 只在剪贴板有文本时生效，和过去一样。
  final Future<String?> Function(Uint8List pngBytes)? savePastedImage;

  /// 把正文里的图片引用解析成可绘制的图片；null 表示这一行画不出来。
  final ImageProvider? Function(String source)? imageProviderFor;

  /// 把正文里的图片引用解析成磁盘上的绝对路径。
  ///
  /// 只有「查看大图」用：浮层要知道原图多大，而尺寸得从文件头读。远程图
  /// 返回 null，浮层就不显示尺寸那一行。
  final String? Function(String source)? imagePathFor;

  final bool readOnly;

  @override
  State<MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<MarkdownEditor> {
  /// Lets us walk the field's element tree to find the checkbox shells.
  final GlobalKey _fieldKey = GlobalKey();

  /// Locates the scrolled header (the title), so the pointer handlers can tell
  /// a press on it from a press on the sheet around the body.
  final GlobalKey _headerKey = GlobalKey();

  bool _overHeader(Offset globalPosition) {
    final RenderObject? render = _headerKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return false;
    return (render.localToGlobal(Offset.zero) & render.size).contains(
      globalPosition,
    );
  }

  /// Where the caret was before a click that turned out to be on a checkbox.
  TextSelection? _caretBeforeCheckboxTap;

  /// 正文的撤销历史。按每次正文变化记一笔，不跟随 500ms 的节流合并。
  late _EditHistory _history;

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

  // ------------------------------------------------------------ line style
  //
  // 按行排版的光标不再需要任何修正层：`RenderLineEditable` 的
  // `getLocalRectForCaret` 直接按「这一行」的高度给出矩形，光标高度、基线、
  // 绘制顺序都由它自己负责。旧实现里围绕 `RenderEditable` 单段假设搭起来的
  // 那一整套（`_CaretSeat` / `_pinCaretAboveText` / strut 模板测量）随之退场。

  /// 按行排版的样式解析器，按（正文样式 + 调色板 + 悬停标签）缓存。
  ///
  /// 不能每次 build 都新建：渲染层用值相等判断是否需要重排，而方法 tear-off
  /// 的相等性依赖接收者实例，新实例会让每一帧都重排整篇。
  LiveLineStyle? _lineStyle;

  /// 指针当前悬停的标签（文档偏移）。按行排版没有 widget 胶囊可以接
  /// `MouseRegion`，所以悬停由这里命中后写进样式解析器。
  TextRange? _hoverTag;

  /// 按下时命中的标签胶囊，等指针抬起再决定是不是一次点击。
  ///
  /// 必须在按下时就取：输入框会把光标落在标签里，胶囊随即退回源码、底片消失，
  /// 等到抬起再命中就什么也找不到了。
  TextRange? _tagBeforeTap;

  /// 按下标签前的光标位置。
  ///
  /// 标签是链接不是文字：一次点击只跳转，不应把光标留在标签里、让它在回来时
  /// 还是展开的源码。抬起时把这份光标还回去，胶囊原样保留。
  TextSelection? _caretBeforeTagTap;

  /// 按下时命中的双链，等指针抬起再决定是不是一次点击。
  ///
  /// 和标签一样必须在按下时就取：输入框会把光标落进链接，方括号随即从
  /// 折叠态退回源码，到了抬起时命中的字形已经和按下时不是一回事。
  ({int start, int end, String target})? _wikilinkBeforeTap;

  /// 按下链接前的光标位置，抬起后归还：链接是跳转，不是一次落点。
  TextSelection? _caretBeforeWikilinkTap;

  /// 指针当前悬停的双链；按下命中的兜底，理由同 [_hoverTag]。
  ({int start, int end, String target})? _hoverWikilink;

  /// 按下时命中的外链，等指针抬起再决定是不是一次点击；命中理由同双链。
  ({int start, int end, String url})? _linkBeforeTap;

  /// 按下链接前的光标位置，抬起后归还：跳转不是一次落点。
  TextSelection? _caretBeforeLinkTap;

  /// 打开外链的修饰键：Ctrl（Windows/Linux）或 ⌘（macOS）。
  ///
  /// 单击链接是落光标、进编辑，跳转必须另加这个键——和 Obsidian、VS Code
  /// 的习惯一致，也让「点链接改字」不再每次弹一次浏览器。
  bool get _jumpModifier =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  /// 按下那一刻摊开的是哪一行（行首偏移）。
  ///
  /// 折叠态的行里，`[标签](地址)` 只画出标签：点在标签右缘时平台算出的偏移会
  /// 落在链接源码的末尾——行是这一下才摊开的，那个偏移没有意义。抬起时靠它
  /// 分辨「这一行本来就是摊开的（用户点的是源码）」和「这一下才摊开」。
  int? _openLineAtDown;

  /// 指针当前悬停的外链，按下命中的兜底。
  ({int start, int end, String url})? _hoverLink;

  LiveLineStyle _resolveLineStyle(TextStyle style, AppPalette palette) {
    final LiveLineStyle? cached = _lineStyle;
    final String source = _currentText();
    if (cached != null &&
        cached.base == style &&
        cached.palette == palette &&
        cached.hoverTag == _hoverTag &&
        cached.source == source &&
        cached.markerRevealLine == _markerReveal?.start) {
      return cached;
    }
    return _lineStyle = LiveLineStyle(
      base: style,
      palette: palette,
      reveal: _revealSelection,
      hoverTag: _hoverTag,
      source: source,
      markerRevealLine: _markerReveal?.start,
    );
  }

  /// 实时表格行的自绘内容，缓存规则同 [_resolveLineStyle]。
  ///
  /// 一份实例带着整张表的测量（列宽、行高、每个格子的 `TextPainter`），换掉
  /// 就要重新测量，所以只在正文样式或主题变化时重建。
  LiveTableBlocks? _tableBlocks;

  /// 跨笔记挂起行布局的池（P5a）：切走一篇笔记时输入框把布局挂进来，切回来
  /// 直接采用，只重排少数行。容量只留最近两篇，避免整篇 `TextPainter` 堆积。
  late final LineLayoutPool _layoutPool = LineLayoutPool();

  /// 实时图片行的自绘内容。
  ///
  /// 只在配色变化（或换文档，见 [didUpdateWidget]）时重建：图片块手里握着
  /// 解码后的 `ui.Image` 与监听器，重建一份等价的实例等于把每张图重新挂一遍。
  LiveImageBlocks? _imageBlocks;
  AppPalette? _imageBlocksPalette;

  LiveImageBlocks _resolveImageBlocks(AppPalette palette) {
    final LiveImageBlocks? cached = _imageBlocks;
    if (cached != null && _imageBlocksPalette == palette) return cached;
    cached?.dispose();
    _imageBlocksPalette = palette;
    return _imageBlocks = LiveImageBlocks(
      palette: palette,
      text: _currentText,
      selection: _revealSelection,
      selectedLine: () => _selectedImageLine,
      editingLine: () => _imageSourceLine,
      sourceFontSize: widget.fontSize,
      imageProviderFor: widget.imageProviderFor,
      onLineInvalidated: _invalidateImageLine,
    );
  }

  /// 把图片行解码完成后的重排请求转给渲染对象。
  void _invalidateImageLine(int lineStart) =>
      _editable()?.invalidateImageLine(lineStart);

  /// 表格与图片的组合解析器。
  ///
  /// 必须是稳定对象：每次 build 新建一个闭包，`lineLayoutKey` 就会变，每个
  /// 按键都会把整篇重排。这里按两份块实例的身份缓存。
  _LineBlockResolver? _lineBlocks;

  _LineBlockResolver _resolveLineBlocks(
    LiveTableBlocks tables,
    LiveImageBlocks images,
  ) {
    final _LineBlockResolver? cached = _lineBlocks;
    if (cached != null &&
        identical(cached.tables, tables) &&
        identical(cached.images, images)) {
      return cached;
    }
    return _lineBlocks = _LineBlockResolver(tables, images);
  }

  LiveTableBlocks _resolveTableBlocks(TextStyle style, AppPalette palette) {
    final LiveTableBlocks? cached = _tableBlocks;
    if (cached != null && cached.base == style && cached.palette == palette) {
      return cached;
    }
    // 旧表块即将被释放，挂起布局里的表格行会指向已释放的行视图：整池丢掉，
    // 宁可切回来重排一次，也不接受悬空的行块。
    _layoutPool.clear();
    cached?.dispose();
    return _tableBlocks = LiveTableBlocks(
      base: style,
      palette: palette,
      text: _currentText,
      selection: _currentSelection,
    );
  }

  String _currentText() => widget.controller.text;

  /// 表格选区洗色要跟着**光标**走，而不是拖选期间冻结的那份揭示选区：
  /// 冻结是为了不让标记在指针底下闪，和选中色带无关。
  TextSelection? _currentSelection() => widget.controller.selection;

  /// 按行排版用来展开标记的选区：`revealAs` 优先（拖动期间被冻结）。
  ///
  /// 做成稳定的方法引用，渲染层才能按值相等判断要不要重排。列表标记不归这里
  /// 管——它们按 [_markerReveal] 单独摊开，见 `markerRevealLine`。
  TextSelection? _revealSelection() {
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController) {
      final TextSelection? frozen = c.revealAs;
      if (frozen != null) return frozen;
      if (c.revealSuppressed) return null;
      return c.selection;
    }
    return c.selection;
  }

  @override
  void initState() {
    super.initState();
    _history = _EditHistory(widget.controller.value);
    widget.controller.addListener(_recordHistory);
    widget.controller.addListener(_scheduleOverlayRefresh);
    widget.controller.addListener(_onFoldsChanged);
    widget.scrollController.addListener(_scheduleOverlayRefresh);
    widget.scrollController.addListener(_reportTopLine);
    widget.onLineTopProbe?.call(_lineTopOf);
    widget.onJumpSettled?.call(_forceRepaint);
    _foldDocument = widget.documentId ?? '';
    _foldText = widget.controller.text;
    _foldedListStarts = Set<int>.of(
      _foldedByDocument[_foldDocument] ?? const <int>{},
    );
    _lastFoldSelection = widget.controller.selection;
  }

  void _recordHistory() => _history.observe(widget.controller.value);

  /// 源码行在滚动内容坐标里的顶部；渲染对象还没排版时为 `null`。
  ///
  /// 加上滚动内边距与头部（标题）的高度：两者都排在字段上方，滚动控制器只认
  /// 内容坐标，`_scrollToLine` 拿到的必须包含它们，否则跳转会差一截。
  double? _lineTopOf(int line) {
    final double? top = _editable()?.lineTopFor(line);
    if (top == null) return null;
    final RenderObject? header = _headerKey.currentContext?.findRenderObject();
    final double headerHeight = header is RenderBox && header.hasSize
        ? header.size.height
        : 0;
    return widget.padding.top + headerHeight + top;
  }

  /// 让正文输入框按当前状态重排 + 重绘一次（大纲跳转收尾用）。
  ///
  /// 不靠 `setState`：重建出来的 `LineEditableText` 属性与上一帧完全相同，
  /// `didUpdateWidget` 会早退，既不排版也不重绘。这里直接给渲染对象打标记；
  /// 排版走增量缓存命中路径（未变行直接复用），代价在 1ms 量级。
  void _forceRepaint() {
    final RenderLineEditable? field = _editable();
    if (field == null || !field.attached) return;
    field.markNeedsLayout();
    field.markNeedsPaint();
  }

  @override
  void didUpdateWidget(MarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换文档时撤销栈必须从空开始，否则 Ctrl+Z 会恢复上一份笔记的正文。
    // 输入框自己的 UndoHistory 靠下面 KeyedSubtree 的 documentId 整块重建来
    // 丢弃；正文历史挂在本 State 上，这里手动重置。
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_recordHistory);
      oldWidget.controller.removeListener(_scheduleOverlayRefresh);
      oldWidget.controller.removeListener(_onFoldsChanged);
      widget.controller.addListener(_recordHistory);
      widget.controller.addListener(_scheduleOverlayRefresh);
      widget.controller.addListener(_onFoldsChanged);
      _history = _EditHistory(widget.controller.value);
    } else if (oldWidget.documentId != widget.documentId) {
      _history = _EditHistory(widget.controller.value);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.documentId != widget.documentId) {
      _bindFoldSession();
      // 图片块按源码偏移缓存；换一份正文后旧偏移没有意义，图片流也要跟着
      // 断开，等新正文里真正出现的图片重新解析。
      _imageBlocks?.dispose();
      _imageBlocks = null;
      _imageBlocksPalette = null;
      _lineBlocks = null;
      // 源码行按偏移记着「正在改哪一行」：换文档后那个偏移落在新正文的别的
      // 地方，会让一张毫不相干的图莫名让出一行。选中态、悬停、全屏看图同理。
      _dropImageState();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_scheduleOverlayRefresh);
      oldWidget.scrollController.removeListener(_reportTopLine);
      widget.scrollController.addListener(_scheduleOverlayRefresh);
      widget.scrollController.addListener(_reportTopLine);
    }
    _scheduleOverlayRefresh();
  }

  // ------------------------------------------------------ task checkboxes
  //
  // ⛔ The boxes are deliberately *not* `GestureDetector`s — they are not
  // widgets at all: the renderer paints them into the marker slot (see
  // `RenderLineEditable.checkboxRectOf`). A widget would have to sit in a
  // `WidgetSpan` and be positioned through the paragraph's placeholder box,
  // which drifts from where the widget is actually painted as soon as the row
  // wraps or the marker column holds more than one element; the symptom is
  // "the box on the first line works and the others do not". Instead we listen
  // to raw pointers — a `Listener` never joins the gesture arena — and
  // hit-test the renderer's **own paint rect**, which is by definition where
  // the user sees the box.

  /// The source offset of the checkbox under [globalPosition], if any.
  ///
  /// 复选框现在是渲染层画出来的图形，没有 widget 可走：命中直接问渲染对象拿到
  /// 的矩形，和它画出来的地方逐像素一致。
  int? _checkboxAt(Offset globalPosition) {
    final RenderLineEditable? field = _editable();
    if (field == null) return null;
    return field.taskCheckboxAt(globalPosition, slop: _kCheckboxTouchSlop);
  }

  /// 从复选框的源码偏移反查它所在那一行的整段标记范围。
  ///
  /// 点复选框要的是「整行进编辑态」，而 [RenderLineEditable.listMarkerAt] 是按
  /// 指针**几何**命中的：按在方框上沿、或者按下点和抬起点不是一个地方时，
  /// 它会判不中。这里改成从源码算——方框的偏移是确定的，行首和标记长度也
  /// 是确定的，跟指针落在哪半像素无关。
  ///
  /// 光标给到 [markerStart] 自己，也就是方框开头：点方框的人想改的是
  /// `[ ]` 这三个字符。
  ({int start, int markerStart, int paintStart, bool revealed, int caret})?
  _markerRangeOf(int markerStart) {
    final ({int from, int to, String text})? line = _sourceLineAt(markerStart);
    if (line == null) return null;
    final LineMarker marker = scanLineMarker(line.text);
    if (marker.length <= 0) return null;
    final int from = line.from + marker.indent;
    final int to = from + marker.length;
    return (
      start: line.from,
      markerStart: from,
      paintStart: to,
      revealed: false,
      caret: markerStart.clamp(from, to),
    );
  }

  /// 指针下压着的 `#标签` 胶囊（文档偏移区间），没有则为 `null`。
  ///
  /// 只认胶囊真正覆盖的那块矩形：`positionAt` 会把段落右侧的空白吸附到行末，
  /// 若只看偏移，鼠标停在整行右边也会点亮最后一个标签。矩形取的是渲染层算
  /// 选区时用的同一份字形几何，横向再放开标签的内边距（[kTagPadX]）。
  TextRange? _tagAt(Offset globalPosition) {
    final RenderLineEditable? field = _editable();
    final LiveLineStyle? style = _lineStyle;
    if (field == null || style == null) return null;

    final int offset = field.positionAt(globalPosition).offset;
    final LineDocumentLayout? layout = field.lineLayout;
    if (layout == null) return null;
    SourceLine? target;
    for (final SourceLine line in layout.lines) {
      if (offset >= line.start && offset <= line.end) {
        target = line;
        break;
      }
    }
    if (target == null || !target.text.contains('#')) return null;

    for (final LineFillRun run in style.fillsFor(target)) {
      if (run.radius != kTagRadius) continue; // 只认标签胶囊，行内代码不点亮
      final TextRange range = TextRange(
        start: target.paintStart + run.from,
        end: target.paintStart + run.to,
      );
      for (final Rect local in field.selectionBands(
        TextSelection(baseOffset: range.start, extentOffset: range.end),
      )) {
        final Rect rect = Rect.fromLTRB(
          local.left - kTagPadX,
          local.top,
          local.right + kTagPadX,
          local.bottom,
        );
        if (rect
            .shift(field.localToGlobal(Offset.zero))
            .contains(globalPosition)) {
          return range;
        }
      }
    }
    return null;
  }

  /// 指针下压着的双链，没有则为 `null`。
  ///
  /// 和 [_tagAt] 同一条判据：只认字形真正覆盖的矩形，不认 `positionAt` 吸附
  /// 到的行末偏移；链接没有胶囊内边距，所以不额外放宽横向范围。
  ({int start, int end, String target})? _wikilinkAt(Offset globalPosition) {
    final RenderLineEditable? field = _editable();
    final LiveLineStyle? style = _lineStyle;
    if (field == null || style == null) return null;

    final int offset = field.positionAt(globalPosition).offset;
    final LineDocumentLayout? layout = field.lineLayout;
    if (layout == null) return null;
    SourceLine? target;
    for (final SourceLine line in layout.lines) {
      if (offset >= line.start && offset <= line.end) {
        target = line;
        break;
      }
    }
    if (target == null || !target.text.contains('[[')) return null;

    for (final ({int start, int end, String target}) link in style.wikilinksFor(
      target,
    )) {
      for (final Rect local in field.selectionBands(
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      )) {
        if (local
            .shift(field.localToGlobal(Offset.zero))
            .contains(globalPosition)) {
          return link;
        }
      }
    }
    return null;
  }

  /// 指针下压着的外链，没有则为 `null`；判据与 [_wikilinkAt] 同源。
  ({int start, int end, String url})? _linkAt(Offset globalPosition) {
    final RenderLineEditable? field = _editable();
    final LiveLineStyle? style = _lineStyle;
    if (field == null || style == null) return null;

    final int offset = field.positionAt(globalPosition).offset;
    final LineDocumentLayout? layout = field.lineLayout;
    if (layout == null) return null;
    SourceLine? target;
    for (final SourceLine line in layout.lines) {
      if (offset >= line.start && offset <= line.end) {
        target = line;
        break;
      }
    }
    if (target == null || !target.text.contains('](')) return null;

    for (final ({int start, int end, String url}) link in style.linksFor(
      target,
    )) {
      for (final Rect local in field.selectionBands(
        TextSelection(baseOffset: link.start, extentOffset: link.end),
      )) {
        if (local
            .shift(field.localToGlobal(Offset.zero))
            .contains(globalPosition)) {
          return link;
        }
      }
    }
    return null;
  }

  /// 悬停标签变了才重建：颜色是烤进每一行 `TextPainter` 的，必须让渲染层
  /// 重排（值相等判断在 [LiveLineStyle] 上），光重画改不了字形颜色。
  void _setHoverTag(TextRange? next) {
    if (next == _hoverTag) return;
    setState(() => _hoverTag = next);
  }

  /// The field's own render object — the only thing that can turn a screen point
  /// into a text offset exactly the way the field itself does.
  ///
  /// 只认按行排版的 [RenderLineEditable]：它的几何出口与画面对齐，而基类
  /// `RenderEditable` 的单段假设在列表行、代码围栏上都会偏。
  RenderLineEditable? _editable() {
    final BuildContext? root = _fieldKey.currentContext;
    if (root == null) return null;
    RenderLineEditable? found;
    void visit(Element element) {
      if (found != null) return;
      final RenderObject? ro = element.renderObject;
      if (ro is RenderLineEditable) {
        found = ro;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    final RenderLineEditable? re = found;
    return re != null && re.hasSize && re.attached ? re : null;
  }

  /// Where the pointer went down, and whether it has since travelled far enough
  /// to be a drag rather than a click.
  Offset? _downPosition;
  bool _gestureMoved = false;

  /// 按下时落下的选区基点，拖选时作为范围的起点。
  ///
  /// 按行渲染的输入框是裸 `EditableText`，不带 `TextField` 那层手势识别，
  /// 所以拖选范围由编辑器自己从这一点拉到指针当前位置。
  int? _dragAnchor;

  /// 用户点开了哪一行的列表标记（[start] 行首，[paintStart] 标记结束）。
  ///
  /// 只靠光标位置判断是不够的：光标停在 0 是常见状态（刚绑定笔记、Ctrl+Home），
  /// 第一行恰好是列表时就会无缘无故把 `- ` 摊出来。所以展开与否由“是不是点了
  /// 标记”决定，点别处就收起。
  ({int start, int paintStart})? _markerReveal;

  /// 点开标记的那一次按下的光标位置。
  ///
  /// 裸 `EditableText` 在抬手时还会按槽位把光标吸附回正文起点（它只认字形），
  /// 所以这里记一份，在同一个事件末尾用微任务还回去——和复选框的处理一致。
  int? _markerCaret;

  /// 按在了哪一行的标记区（抬手时还停在原地才算一次点击）。
  ///
  /// 按下就摊开会让整行在手指还没动的时候重排，也会把「按在标记上、拖到复选框」
  /// 这类手势的命中结果换掉——所以只记下来，抬手再决定。
  ({int start, int markerStart, int paintStart, bool revealed, int caret})?
  _pendingMarker;

  // ------------------------------------------------------------ list folds
  //
  // 折叠状态按笔记记在会话里：键是列表项的**行首偏移**，编辑后按公共前后缀
  // 平移，换 tab 时按 documentId 存取。箭头是画出来的，收起/展开只是一次
  // setState，不碰正文。

  Set<int> _foldedListStarts = <int>{};
  final Map<String, Set<int>> _foldedByDocument = <String, Set<int>>{};
  String _foldDocument = '';
  String _foldText = '';

  /// 指针所在的可折叠行、以及正压在按钮上的那一行。
  ///
  /// 展开的箭头只在悬停行显形；收起的一直画着，因为不点它就没有别的入口。
  int? _hoverFoldLine;
  int? _hoverFoldButton;

  /// 这一次按下是在点折叠箭头；抬手不能再去落光标。
  bool _foldPress = false;

  /// 这一次按下落在滚动条上。滚动条压在滚动视图的右缘、不在输入框里，所以
  /// 按下会先到这里；整段手势都得让给滚动条，抬手也不能再碰光标/选区。
  bool _scrollbarPress = false;

  TextSelection? _lastFoldSelection;

  /// The base offset of a drag that began **outside** the field's box.
  ///
  /// The field is exactly as tall as its text, so the paper below the last line
  /// — and the margins beside the column — are outside its box: its gesture
  /// recognisers never see the press, and a range started there was lost. A
  /// desktop mouse drag is still the select gesture out there, so the editor
  /// drives that range itself. Null when the gesture in flight is an ordinary
  /// one the field handles.
  int? _outsideAnchor;

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
    final RenderLineEditable? editable = _editable();
    if (editable == null) return;
    int offset = editable
        .positionAt(globalPosition)
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

  /// Focuses the field and parks the caret at the end of the note.
  ///
  /// Used by the press on the empty paper below the last line, which is outside
  /// the field's box and therefore has to do the field's work for it.
  void _focusBodyAtEnd() {
    widget.focusNode.requestFocus();
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController) c.disarmClickGuard();
    c.selection = TextSelection.collapsed(offset: c.text.length);
  }

  /// The field's own state, for the menu rows that are the platform's commands
  /// (copy, cut, paste, select all).
  LineEditableTextState? _editableTextState() {
    final BuildContext? root = _fieldKey.currentContext;
    if (root == null) return null;
    LineEditableTextState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement &&
          element.state is LineEditableTextState) {
        found = element.state as LineEditableTextState;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return found;
  }

  /// Opens the editor's right-click menu at [globalPosition].
  ///
  /// 按行渲染的字段没有 `TextField` 的手势层，所以文本上的右键也由这里直接开
  /// 菜单；字段之外的纸面走的是同一条路。
  void _showMenuAt(Offset globalPosition) {
    final LineEditableTextState? state = _editableTextState();
    if (state == null) return;
    unawaited(
      showAppMenu(
        context,
        globalPosition: globalPosition,
        // The menu is a route, and a route takes the focus with it. The caret
        // has to stay on screen under the menu, exactly as it does for a
        // right-click on the text.
        keepFocus: widget.focusNode,
        entries: buildEditorMenu(
          value: widget.controller.value,
          onApply: _applyEdit,
          state: state,
          resolve: _resolveRange,
          onEditCell: _openCellEditor,
          onPasteImage: _pasteImageFromClipboard,
        ),
      ),
    );
  }

  /// Whether [globalPosition] sits below the last painted line.
  ///
  /// The field ends where its text ends, so the rest of the sheet belongs to
  /// the scroll view alone; the editor treats a press there as "end of note".
  bool _belowText(Offset globalPosition) {
    final RenderLineEditable? re = _editable();
    if (re == null) return false;
    final Offset bottom = re.localToGlobal(Offset(0, re.size.height));
    return globalPosition.dy > bottom.dy;
  }

  /// Whether [globalPosition] lands on the editor's scrollbar.
  ///
  /// The bar is painted over the right edge of the scroll view but is not a
  /// child of the field, so its presses reach the raw [Listener] like any
  /// other press on the paper around the column. Without this the
  /// "outside the text" branch anchors a selection there, and dragging the
  /// bar down selects text instead of scrolling. Measured the way
  /// [RawScrollbar] hit-tests a mouse: the track (theme thickness plus its
  /// cross-axis margin on either side) along the viewport's trailing edge.
  bool _overScrollbar(Offset globalPosition) {
    if (!widget.scrollController.hasClients) return false;
    final ScrollPosition position = widget.scrollController.position;
    if (position.axis != Axis.vertical ||
        !position.hasPixels ||
        position.maxScrollExtent <= position.minScrollExtent) {
      return false;
    }
    final RenderObject? render = position.context.storageContext
        .findRenderObject();
    if (render is! RenderBox || !render.hasSize) return false;
    final Rect viewport = render.localToGlobal(Offset.zero) & render.size;
    final ScrollbarThemeData theme = ScrollbarTheme.of(context);
    final double thickness = theme.thickness?.resolve(<WidgetState>{}) ?? 8;
    final double margin = theme.crossAxisMargin ?? 2;
    final double trailing =
        viewport.right - (MediaQuery.maybeOf(context)?.padding.right ?? 0);
    return globalPosition.dx >= trailing - thickness - margin * 2 &&
        globalPosition.dx <= trailing;
  }

  /// Reports the source line the viewport starts on, whenever it is scrolled.
  ///
  /// Asked of the render object rather than measured: one pixel below the
  /// pane's top edge, `positionAt` answers exactly the line a reader sees
  /// first — wrapped paragraphs and heading line boxes included — for the
  /// price of a hit test.
  void _reportTopLine() {
    final ValueChanged<int>? report = widget.onTopLineChanged;
    if (report == null) return;
    final RenderLineEditable? re = _editable();
    final RenderObject? root = context.findRenderObject();
    if (re == null || root is! RenderBox || !root.hasSize) return;
    final Offset top = root.localToGlobal(Offset.zero);
    final String text = widget.controller.text;
    final int offset = re
        .positionAt(Offset(top.dx + 2, top.dy + 1))
        .offset
        .clamp(0, text.length);
    report('\n'.allMatches(text.substring(0, offset)).length);
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
    // 拖拽改宽中途按 Esc：预览丢掉，源码不动。
    if (key == LogicalKeyboardKey.escape && _imageResize != null) {
      _cancelImageResize();
      return KeyEventResult.handled;
    }
    // 拖着图片找落点途中按 Esc：插入线丢掉，图片留在原地。
    if (key == LogicalKeyboardKey.escape && _imageMove != null) {
      _cancelImageMove();
      _setCursor(SystemMouseCursors.basic);
      return KeyEventResult.handled;
    }
    // 图片源码行：Esc 丢掉，源码不动。
    if (key == LogicalKeyboardKey.escape &&
        (_imageEdit != null || _imageSourceLine != null)) {
      _cancelImageEditor();
      widget.focusNode.requestFocus();
      return KeyEventResult.handled;
    }
    // 全屏看图：Esc 退出来。
    if (key == LogicalKeyboardKey.escape && _viewerOpen) {
      _closeImageViewer();
      widget.focusNode.requestFocus();
      return KeyEventResult.handled;
    }
    // 选中的图片：Esc 收掉边框和按钮。
    if (key == LogicalKeyboardKey.escape && _selectedImageLine != null) {
      _selectImage(null);
      return KeyEventResult.handled;
    }
    // 选中的图片：Backspace / Delete 删掉整张图。图片是自绘的一整块，光标根本
    // 不在它里面；让字段自己去删，删掉的是隔壁那一行的字。
    if ((key == LogicalKeyboardKey.backspace ||
            key == LogicalKeyboardKey.delete) &&
        _imageEdit == null &&
        _imageSourceLine == null &&
        _selectedImageLine != null) {
      _deleteImageLine(_selectedImageLine!);
      return KeyEventResult.handled;
    }
    if (!v.selection.isValid ||
        (v.composing.isValid && !v.composing.isCollapsed)) {
      return KeyEventResult.ignored;
    }
    // 光标贴着图片删：图片行就是一整块，删它得整行删。
    //
    // Backspace 停在行尾（图片右侧）时，字段只会吃掉最后那个 `>`，一行
    // `<img …>` 变成半截标签；Delete 停在行首时同理，吃掉的是 `<`。两种都让
    // 图片凭空消失、原地留下一段废源码，所以这里接手。
    if (_imageEdit == null &&
        _imageSourceLine == null &&
        v.selection.isCollapsed &&
        (key == LogicalKeyboardKey.backspace ||
            key == LogicalKeyboardKey.delete)) {
      final int caret = v.selection.start;
      final int start = lineStartOf(v.text, caret);
      final int newline = v.text.indexOf('\n', start);
      final int end = newline < 0 ? v.text.length : newline;
      final bool isImageLine =
          end > start && ImageMarkup.parseLine(v.text.substring(start, end)) != null;
      final bool atEdge = key == LogicalKeyboardKey.backspace
          ? caret == end
          : caret == start;
      if (isImageLine && atEdge) {
        _deleteImageLine(start);
        return KeyEventResult.handled;
      }
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
    final RenderLineEditable? editable = _editable();
    if (editable == null) return;
    final int at = editable.positionAt(globalPosition).offset;
    c.selection = TextSelection.collapsed(offset: at.clamp(0, c.text.length));
  }

  /// 记下/清掉“哪一行的标记摊开”。
  ///
  /// 必须自己发起重建：点标记时光标常常已经停在行首，选区没有变化就不会有
  /// 通知，光改字段的话 `markerRevealLine` 传不到渲染层。
  void _setMarkerReveal(({int start, int paintStart})? value) {
    if (_markerReveal == value) return;
    setState(() => _markerReveal = value);
  }

  /// 折叠态里点在链接上（或它的留白上）时，光标落进链接源码，送去行末。
  ///
  /// 折叠态的 `[标签](地址)` 只画出标签：点击点换算回源码会落在标签末尾
  /// （`[标签|](地址)`），或者落在整段源码的末尾——两种都是「链接文字右边」，
  /// 而这一行是这一下才摊开的，那个偏移在摊开之后没有任何意义。用户点链接
  /// 是想接着写这一行，所以光标去行末。
  ///
  /// [openLine] 是按下那一刻摊开的行首：同一行本来就是摊开的，用户点的就是
  /// 源码，光标该留在原地，不能纠正。
  void _parkCaretOutOfLink(int? openLine) {
    if (widget.onLinkTap == null) return;
    final TextEditingController c = widget.controller;
    if (!c.text.contains('](')) return;
    final LiveLineStyle? style = _lineStyle;
    final List<SourceLine>? lines = _editable()?.lineLayout?.lines;
    if (style == null || lines == null) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      final TextSelection sel = c.selection;
      if (!sel.isValid || !sel.isCollapsed) return;
      final String text = c.text;
      final int at = sel.start;
      for (final SourceLine line in lines) {
        if (at < line.start || at > line.end) continue;
        if (openLine != null && line.start == openLine) return;
        for (final ({int start, int end, String url}) link in style.linksFor(
          line,
        )) {
          if (at <= link.start || at > link.end) continue;
          c.selection = TextSelection.collapsed(
            offset: lineEndOf(text, link.start).clamp(0, text.length),
          );
          return;
        }
        return;
      }
    });
  }

  /// 把点标记时定下的光标还给输入框。
  ///
  /// 裸 `EditableText` 会在同一次抬手事件里按槽位把光标吸附回正文起点，而它
  /// 的写入发生在监听器之后；微任务是同一帧里的最后一句话，光标不会先闪到
  /// 正文再跳回序号。
  void _restoreMarkerCaret(TextEditingController c) {
    final int? caret = _markerCaret;
    _markerCaret = null;
    if (caret == null || _gestureMoved) return;
    scheduleMicrotask(() {
      if (!mounted) return;
      c.selection = TextSelection.collapsed(
        offset: caret.clamp(0, c.text.length),
      );
    });
  }

  // ------------------------------------------------------------ list folds

  /// 文本或选区一变：先把折叠键跟着源码平移，再看光标是不是走进了折起来
  /// 的子树——是的话把它展开，否则光标会停在看不见的行上。
  void _onFoldsChanged() {
    final String text = widget.controller.text;
    final bool textChanged = text != _foldText;
    if (textChanged) {
      final Set<int> next = _remapFoldStarts(
        _foldedListStarts,
        _foldText,
        text,
      );
      _foldText = text;
      if (!setEquals(next, _foldedListStarts)) {
        _foldedListStarts = next;
        setState(() {});
      }
    }
    if (!textChanged) _guardSelectionAgainstFolds();
  }

  /// 换笔记时把折叠状态存到上一份、从下一份取回。
  void _bindFoldSession() {
    final String key = widget.documentId ?? '';
    if (key != _foldDocument) {
      _foldedByDocument[_foldDocument] = Set<int>.of(_foldedListStarts);
      _foldDocument = key;
      _foldedListStarts = Set<int>.of(_foldedByDocument[key] ?? const <int>{});
    }
    _foldText = widget.controller.text;
    _lastFoldSelection = widget.controller.selection;
    _hoverFoldLine = null;
    _hoverFoldButton = null;
  }

  /// 编辑点之前的折叠键不动，之后的整体平移；落在改动区间里的项已经不存在。
  Set<int> _remapFoldStarts(Set<int> starts, String oldText, String newText) {
    if (starts.isEmpty) return starts;
    final int limit = math.min(oldText.length, newText.length);
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
    final int changedEnd = oldText.length - suffix;
    final int delta = newText.length - oldText.length;
    final Set<int> out = <int>{};
    for (final int start in starts) {
      // 插入点正好压在折叠行的行首时，整行会被推到后面：键要跟着平移，
      // 否则折叠会跳到插入进来的那段文字上（在列表上方新起一段就是这种）。
      // 删除到行首则相反，行首还在原处。
      if (start < prefix || (start == prefix && delta < 0)) {
        out.add(start);
      } else if (start >= changedEnd) {
        out.add(start + delta);
      }
    }
    return out;
  }

  /// 选区端点进入折叠区时自动展开。
  ///
  /// 收起只是把行压成零高，源码还在：方向键、Ctrl+End、Shift+点击都可能
  /// 把光标送进那块看不见的文字。展开是最不容易让人迷路的处理——光标永远
  /// 落在画出来的字上。
  void _guardSelectionAgainstFolds() {
    if (_foldedListStarts.isEmpty) return;
    final TextSelection selection = widget.controller.selection;
    if (!selection.isValid || selection == _lastFoldSelection) return;
    _lastFoldSelection = selection;
    final LineDocumentLayout? layout = _editable()?.lineLayout;
    if (layout == null) return;

    final Set<int> expand = <int>{};
    for (final LaidOutLine line in layout.laidOut) {
      final ListFold? fold = line.fold;
      if (fold == null || !line.folded) continue;
      final int from = line.source.end;
      final int to = layout.lines[fold.lastIndex].end;
      final bool inside = selection.isCollapsed
          ? selection.start > from && selection.start <= to
          : selection.start <= to && selection.end > from;
      if (inside) expand.add(line.source.start);
    }
    if (expand.isEmpty) return;
    setState(() {
      _foldedListStarts = Set<int>.of(_foldedListStarts)..removeAll(expand);
    });
  }

  /// 收起/展开一条列表项。收起时若光标正藏在子树里，把它收回本行末尾。
  void _toggleListFold(ListFoldHandle handle) {
    final Set<int> next = Set<int>.of(_foldedListStarts);
    if (handle.folded) {
      next.remove(handle.lineStart);
    } else {
      next.add(handle.lineStart);
      final TextSelection selection = widget.controller.selection;
      if (selection.isValid &&
          selection.end > handle.lineEnd &&
          selection.start <= handle.hiddenEnd) {
        widget.controller.selection = TextSelection.collapsed(
          offset: handle.lineEnd,
        );
      }
    }
    setState(() => _foldedListStarts = next);
  }

  /// 箭头按钮；[visibleOnly] 时只认当前真的画出来的那个（展开项要悬停）。
  ListFoldHandle? _foldButtonAt(Offset position, {bool visibleOnly = false}) {
    final ListFoldHandle? handle = _editable()?.foldHandleAt(position);
    if (handle == null) return null;
    if (visibleOnly && !handle.folded && _hoverFoldLine != handle.lineStart) {
      return null;
    }
    return handle;
  }

  /// 指针落在哪一条可折叠列表项的横带上。
  ListFoldHandle? _foldRowAt(Offset position) =>
      _editable()?.foldRowAt(position);

  void _setFoldHover({int? row, int? button}) {
    if (_hoverFoldLine == row && _hoverFoldButton == button) return;
    setState(() {
      _hoverFoldLine = row;
      _hoverFoldButton = button;
    });
  }

  // ---------------------------------------------------------- table chrome
  //
  // The grips and the plus buttons a live table paints around itself are
  // *painted*, not widgets (see `_TableLineBlock`), so they are found the same
  // way the checkbox shells are: by asking the render object where it drew
  // what. A raw `Listener` never joins the gesture arena, so the editor hears
  // every press; a `_ChromeShield` then keeps the ones that land on a control
  // away from the field below, whose own drag recognizer would otherwise start
  // selecting the text behind the grip.

  /// Every rendered table row currently on screen.
  ///
  /// 按行排版后表格行不是 element 树里的渲染对象，而是行布局里的一块自绘
  /// 内容，所以直接问渲染对象要——它会先把每行的全局原点写进去，返回的矩形
  /// 与指针事件在同一个坐标系里。
  List<TableRowChrome> _tableRows() =>
      _editable()?.tableRows() ?? const <TableRowChrome>[];

  /// 自绘的图片块，按行序。命中、悬停与浮层定位都从这里取几何。
  List<ImageBlockChrome> _imageChrome() =>
      _editable()?.imageBlocks() ?? const <ImageBlockChrome>[];

  /// The grip, plus button or column divider under [globalPosition], with the
  /// row that painted it.
  ///
  /// The slop is the same one the paint uses, on purpose: a control is only
  /// *drawn* once the pointer is that close, so hit testing must not be any
  /// stricter — otherwise an icon you can see would refuse the click. A column
  /// divider is narrower than a grip: its band has to stay inside the cell's
  /// padding instead of swallowing clicks aimed at the text.
  (TableRowChrome, TableChromeTarget)? _chromeAt(
    Offset globalPosition, {
    double slop = kTableChromeSlop,
  }) {
    for (final TableRowChrome row in _tableRows()) {
      for (final TableChromeTarget t in row.chromeTargets()) {
        final double reach = t.kind == TableChromeKind.resizeColumn
            ? kTableResizeHitSlop
            : slop;
        if (t.rect.inflate(reach).contains(globalPosition)) return (row, t);
      }
    }
    return null;
  }

  /// The image resize handle under [globalPosition], with the line it belongs to.
  ///
  /// 图片块由渲染层自绘，手柄只是块上的一个命中区；原点每帧由 `imageBlocks()`
  /// 写成全局坐标，所以这里和指针事件在同一个坐标系里。
  ({int lineStart, double startWidth, double startDx, double maxWidth})?
  _imageHandleAt(Offset globalPosition) {
    final RenderLineEditable? field = _editable();
    if (field == null) return null;
    for (final ImageBlockChrome block in field.imageBlocks()) {
      final ImageResizeHandle? handle = block.chromeResizeHandle();
      if (handle == null || !handle.rect.contains(globalPosition)) continue;
      return (
        lineStart: block.imageSourceStart,
        startWidth: block.chromeImageBounds().width,
        startDx: globalPosition.dx,
        maxWidth: field.lineLayout?.width ?? block.chromeImageBounds().width,
      );
    }
    return null;
  }

  /// 图片本体下的那一行（行首偏移）。
  ///
  /// 图片是自绘的，字段根本不知道那儿有个东西；按下要挡住字段、悬停要点亮
  /// 按钮，都得先问出「这一下落在哪张图上」。
  int? _imageLineAt(Offset globalPosition) {
    for (final ImageBlockChrome block in _imageChrome()) {
      if (block.chromeImageBounds().contains(globalPosition)) {
        return block.imageSourceStart;
      }
    }
    return null;
  }

  /// 某一张图画出来多大。拖动预览框按它算尺寸。
  Size _imageSizeAt(int line) {
    for (final ImageBlockChrome block in _imageChrome()) {
      if (block.imageSourceStart == line) return block.chromeImageBounds().size;
    }
    return Size.zero;
  }

  /// 某一张图此刻画在哪一块（全局坐标）。
  Rect? _imageBoundsOf(int line) {
    for (final ImageBlockChrome block in _imageChrome()) {
      if (block.imageSourceStart == line) return block.chromeImageBounds();
    }
    return null;
  }

  /// The cell under [globalPosition] — resolved through the geometry the
  /// pointer sees, not through the text skeleton.
  ///
  /// 实时表格的骨架行会自己报出画出来的单元格矩形，有就优先用它；按行排版把
  /// 整行源码交给行引擎后，骨架行不存在，落点改问 [RenderLineEditable.positionAt]
  /// 拿到源码偏移，再由表格模型换算出单元格。
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
        final ({int row, int column, TableCell cell}) at = _mergeAnchorOf(
          block,
          row.chromeRowIndex,
          i,
        );
        return (block: block, row: at.row, column: at.column, cell: at.cell);
      }
    }

    final RenderLineEditable? field = _editable();
    if (field == null) return null;
    final String text = widget.controller.text;
    final int offset = field
        .positionAt(globalPosition)
        .offset
        .clamp(0, text.length);
    final TableBlock? block = TableBlock.parse(text, offset);
    if (block == null) return null;
    // 分隔符行不属于任何单元格：它折叠着，点击时应该把光标留在原处。
    for (final TableRow line in block.rows) {
      if (offset >= line.start && offset <= line.end) {
        if (line.divider) return null;
        break;
      }
    }
    final int row = block.rowAt(offset);
    if (row < 0) return null;
    final List<TableCell> rows = block.bodyRows[row].cells;
    final int column = block.columnAt(row, offset);
    if (column < 0 || column >= rows.length) return null;
    final ({int row, int column, TableCell cell}) at = _mergeAnchorOf(
      block,
      row,
      column,
    );
    return (block: block, row: at.row, column: at.column, cell: at.cell);
  }

  /// A merge is one cell to the pointer: clicking any part of it — including a
  /// covered cell in a lower row — edits the anchor.
  ({int row, int column, TableCell cell}) _mergeAnchorOf(
    TableBlock block,
    int row,
    int column,
  ) {
    final List<TableRow> body = block.bodyRows;
    for (final TableMerge m in tableMergesOf(block)) {
      if (!m.covers(row, column)) continue;
      final List<TableCell> cells = body[m.row].cells;
      if (m.column < cells.length) {
        return (row: m.row, column: m.column, cell: cells[m.column]);
      }
      break;
    }
    return (row: row, column: column, cell: body[row].cells[column]);
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
        // A covered cell has no width; the pointer can never be "inside" it.
        if (cells[i].width <= 0) continue;
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

  /// The column divider being dragged, with everything captured on press —
  /// every column's visible text width, the table's room and the scale between
  /// rendering and design pixels. All widths are rendering pixels.
  _Resize? _resize;

  /// 正在被拖动的图片右下角手柄。拖动期间只改显示宽度，松手才写一次源码。
  ({int lineStart, double startWidth, double startDx, double maxWidth})?
  _imageResize;

  /// 正被拖走的整张图片：按住图片本体、指针移开一段之后才算拖起来。
  ///
  /// 图片行是一整块，能「挪」的只有整行——所以落点按行边界吸附，拖到哪儿就
  /// 把这一行整行搬过去。
  _ImageMove? _imageMove;

  /// 指针停在哪张图片上（行首偏移），决定右上角那排按钮出不出现。
  ///
  /// 只在这一排按钮上画：图片本身是自绘的，没有 `MouseRegion` 可用。
  int? _hoverImageLine;

  /// 被点中的图片（行首偏移）。
  ///
  /// 点一下图片是「我要看这张图」，不是「把光标放进这一行」——图片行是自绘的，
  /// 光标落进去既看不见也没意义。所以按下只记下这一行：画一圈边框，右上角的
  /// 两个按钮固定显示。
  int? _selectedImageLine;

  /// 右上角那排按钮的位置（编辑器自己的坐标）。
  ///
  /// 几何必须在**指针事件里**算好：`_editable()` 要遍历子元素，在 build 期间
  /// 调它会撞上 `visitChildElements() called during build`。
  Rect? _imageActionsRect;

  /// 正在全屏看的那张图（浮层自己管图，这里只记「开着没有」）。
  bool _viewerOpen = false;

  /// 「查看大图」的那一层。
  ///
  /// 它挂在**根 Overlay** 上，不是编辑器 Stack 的一个孩子：用户要的是「盖住整个
  /// 软件」，而编辑器只占窗口中间那一块——挂在 Stack 里的话左边文件列表、右边
  /// 边栏都还亮着，放大一张图反而更看不清。
  OverlayEntry? _viewImageEntry;

  /// 最近一帧用的配色。浮层在指针事件里创建，那时没有 build 上下文可取。
  AppPalette? _palette;

  /// 正在改源码的那一行（行首偏移）。
  ///
  /// 有它，图片块就为源码让出一行高度——源码是这一行的一部分，不是浮在图上
  /// 的一块面板。
  int? _imageSourceLine;

  /// 打开着的图片源码行。图片本身不消失，只是被源码行推到下面。
  _ImageEdit? _imageEdit;
  TextEditingController? _imageText;
  FocusNode? _imageFocus;

  /// The resize divider under the pointer, as `<table>:<row>:<column>`.
  ///
  /// Only hover feedback needs it: crossing a row boundary keeps the cursor on
  /// `resizeColumn`, so nothing else would repaint the line into the new row.
  String? _hoverResizeKey;

  /// The grip strip (or grip button) under the pointer, as a repaint key.
  ///
  /// The strip makes every grip of one side visible and lights the button under
  /// the pointer; neither changes the mouse cursor once it is a hand, so moving
  /// along the strip would otherwise wait for an unrelated frame to repaint.
  String? _chromeHoverKey;

  /// What the pointer looks like over the editor: the I-beam wherever prose can
  /// be typed — the field stops at its last line, but the space below it is part
  /// of the writing surface too — the open hand on a grip (it is a button you
  /// drag), `click` on a `+`.
  ///
  /// A plain `MouseCursor`, not a `MouseRegion.cursor` computed inline: the
  /// region has to be rebuilt for the cursor to change, and rebuilding the
  /// editor on every mouse move is exactly what the painted chrome exists to
  /// avoid. It only changes when the *kind* of thing under the pointer changes.
  MouseCursor _pointerCursor = SystemMouseCursors.text;

  MouseCursor _cursorAt(
    Offset? position, {
    TextRange? tag,
    bool onWikilink = false,
    bool onLink = false,
  }) {
    if (position == null) return SystemMouseCursors.text;
    // 图片手柄是拖拽改宽，不是落光标：按下也不会移动光标。
    if (_imageHandleAt(position) != null) {
      return SystemMouseCursors.resizeUpLeftDownRight;
    }
    // 点图片是「选中它」，一次点击，不是落光标。
    if (_imageLineAt(position) != null) return SystemMouseCursors.click;
    // 折叠箭头是一次点击，不是落光标：悬停时先于页边/缩进的箭头光标判定。
    if (_foldButtonAt(position, visibleOnly: true) != null) {
      return SystemMouseCursors.click;
    }
    final (TableRowChrome, TableChromeTarget)? hit = _chromeAt(position);
    if (hit != null) {
      return switch (hit.$2.kind) {
        TableChromeKind.rowHandle ||
        TableChromeKind.columnHandle => SystemMouseCursors.grab,
        TableChromeKind.addRow ||
        TableChromeKind.addColumn => SystemMouseCursors.click,
        TableChromeKind.resizeColumn => SystemMouseCursors.resizeColumn,
      };
    }
    // 复选框是一次勾选而不是一段文字：悬停时给普通箭头，别让人以为能打字。
    if (_checkboxAt(position) != null) return SystemMouseCursors.basic;
    // 标签胶囊、双链和外链都是一次跳转而不是一段文字：手指光标是它们唯一的
    // 静态提示。
    if ((tag != null && widget.onTagTap != null) ||
        (onWikilink && widget.onWikilinkTap != null) ||
        (onLink && widget.onLinkTap != null)) {
      return SystemMouseCursors.click;
    }
    // 正文列两侧的页边和列表标记前的缩进都不是可编辑的字形：那里给箭头，
    // 免得把整张纸的留白都提示成输入区。标记本身和正文仍在列内，照旧是 I-beam。
    final RenderLineEditable? field = _editable();
    if (field != null) {
      final Offset origin = field.localToGlobal(Offset.zero);
      final bool outsideColumn =
          position.dx < origin.dx || position.dx > origin.dx + field.size.width;
      if (outsideColumn || field.isLeftOfListMarker(position)) {
        return SystemMouseCursors.basic;
      }
    }
    return SystemMouseCursors.text;
  }

  void _setCursor(MouseCursor next) {
    if (next == _pointerCursor) return;
    setState(() => _pointerCursor = next);
  }

  /// The whole point of the chrome's visibility: nothing is drawn unless the
  /// pointer is at the table's edge, so the editor has to tell the render
  /// objects where the pointer is.
  void _onPointerHover(PointerHoverEvent event) {
    if (_overHeader(event.position)) {
      // The title field owns the pointer there; leaving the body's hover state
      // behind would keep a fold arrow or a tag lit over the title.
      tablePointerPosition.value = null;
      _clearResizeHover();
      _clearChromeHover();
      _setHoverImage(null);
      _hoverWikilink = null;
      _setHoverTag(null);
      _setFoldHover();
      return;
    }
    tablePointerPosition.value = event.position;
    _refreshResizeHover(event.position);
    _refreshChromeHover(event.position);
    _refreshImageHover(event.position);
    // A drag owns the cursor (and the preview) until release.
    if (_grabbedRow != null || _resize != null || _imageResize != null) return;
    // 一次命中同时决定三件事：光标形状、标签的悬停配色、双链的按下兜底。
    final TextRange? tag = _tagAt(event.position);
    final ({int start, int end, String target})? wikilink = tag == null
        ? _wikilinkAt(event.position)
        : null;
    _hoverWikilink = wikilink;
    final ({int start, int end, String url})? link =
        tag == null && wikilink == null ? _linkAt(event.position) : null;
    _hoverLink = link;
    // 折叠箭头：按在按钮上才算按钮，落在这条列表项的行里则让箭头显形。
    final ListFoldHandle? foldButton = _foldButtonAt(event.position);
    final ListFoldHandle? foldRow = foldButton ?? _foldRowAt(event.position);
    _setFoldHover(row: foldRow?.lineStart, button: foldButton?.lineStart);
    _setCursor(
      _cursorAt(
        event.position,
        tag: tag,
        onWikilink: wikilink != null,
        onLink: link != null,
      ),
    );
    _setHoverTag(tag);
  }

  void _onPointerExit(PointerExitEvent event) {
    if (_grabbedRow != null ||
        _resize != null ||
        _imageResize != null ||
        _imageMove != null) {
      return;
    }
    // 指针可能是钻进右上角那排按钮了：按钮是 Stack 里压在编辑器之上的兄弟，
    // 编辑器这边只看见「离开」，可人并没有离开这张图。真收起来的话，指针还
    // 没落到按钮上按钮就没了，永远点不着。
    if (_imageActionsRect?.contains(event.localPosition) ?? false) return;
    tablePointerPosition.value = null;
    _clearResizeHover();
    _clearChromeHover();
    _setHoverImage(null);
    _hoverWikilink = null;
    _hoverLink = null;
    _setCursor(SystemMouseCursors.text);
    _setHoverTag(null);
    _setFoldHover();
  }

  /// Lights the actions of the image under the pointer.
  ///
  /// Keyed by line so sliding across one image is free: the buttons only move
  /// when the pointer crosses into another picture or leaves them all.
  void _refreshImageHover(Offset position) => _setHoverImage(
    _imageLineAt(position),
  );

  void _setHoverImage(int? line) {
    if (line == _hoverImageLine) return;
    setState(() {
      _hoverImageLine = line;
      _imageActionsRect = _imageActionsRectFor(line ?? _selectedImageLine);
    });
  }

  /// 点中（或取消点中）一张图。
  void _selectImage(int? line) {
    if (line == _selectedImageLine) return;
    setState(() {
      _selectedImageLine = line;
      _imageActionsRect = _imageActionsRectFor(_hoverImageLine ?? line);
    });
    _applyImageSelection();
  }

  /// 把选中态写进图片块，再让渲染对象重画一遍——只重画，不重排。
  void _applyImageSelection() {
    final RenderLineEditable? field = _editable();
    if (field == null) return;
    for (final ImageBlockChrome block in field.imageBlocks()) {
      block.chromeSelected = block.imageSourceStart == _selectedImageLine;
    }
    field.markNeedsPaint();
  }

  /// 那排按钮的落点：图片右上角内侧。
  ///
  /// 缩放手柄压在右下角，两者各管各的；宽度是写死的三颗按钮宽，位置能算准，
  /// 也就不必等这一帧量完再摆。
  Rect? _imageActionsRectFor(int? line) {
    if (line == null) return null;
    final bool canEdit = !widget.readOnly;
    final double barWidth = canEdit
        ? _kImageActionsEditWidth
        : _kImageActionsWidth;
    const double barHeight = _kImageActionsHeight;
    const double inset = 8;
    ImageBlockChrome? block;
    for (final ImageBlockChrome candidate in _imageChrome()) {
      if (candidate.imageSourceStart == line) {
        block = candidate;
        break;
      }
    }
    if (block == null) return null;
    final RenderObject? root = context.findRenderObject();
    if (root is! RenderBox || !root.hasSize) return null;
    final Rect bounds = Rect.fromPoints(
      root.globalToLocal(block.chromeImageBounds().topLeft),
      root.globalToLocal(block.chromeImageBounds().bottomRight),
    );
    final double left = (bounds.right - inset - barWidth).clamp(
      8.0,
      math.max(8.0, root.size.width - barWidth - 8),
    );
    final double top = (bounds.top + inset).clamp(
      8.0,
      math.max(8.0, root.size.height - barHeight - 8),
    );
    return Rect.fromLTWH(left, top, barWidth, barHeight);
  }

  /// Repaints when the divider under the pointer moves to another row — the
  /// hover line is per row, but the cursor stays `resizeColumn`.
  void _refreshResizeHover(Offset position) {
    final (TableRowChrome, TableChromeTarget)? hit = _chromeAt(position);
    final String? key =
        hit != null && hit.$2.kind == TableChromeKind.resizeColumn
        ? '${hit.$1.chromeTableId}:${hit.$1.chromeRowIndex}:${hit.$2.index}'
        : null;
    if (key == _hoverResizeKey) return;
    _hoverResizeKey = key;
    _editable()?.markNeedsPaint();
  }

  void _clearResizeHover() {
    if (_hoverResizeKey == null) return;
    _hoverResizeKey = null;
    _editable()?.markNeedsPaint();
  }

  /// Repaints when the pointer enters / leaves a grip strip, moves from one
  /// grip button to the next, or slides along the strip to another row /
  /// column — the visible grip follows the pointer, one at a time. Keyed so a
  /// hover inside the same button is free.
  void _refreshChromeHover(Offset position) {
    String? key;
    for (final TableRowChrome row in _tableRows()) {
      for (final TableChromeTarget target in row.chromeTargets()) {
        if (target.rect.inflate(2).contains(position)) {
          key = '${row.chromeTableId}:${target.kind.name}:${target.index}';
          break;
        }
      }
      if (key != null) break;
      for (final TableChromeStrip strip in TableChromeStrip.values) {
        final int? index = row.chromeStripIndexAt(position, strip);
        if (index != null) {
          key = '${row.chromeTableId}:${strip.name}:$index';
          break;
        }
      }
      if (key != null) break;
    }
    if (key == _chromeHoverKey) return;
    _chromeHoverKey = key;
    _editable()?.markNeedsPaint();
  }

  void _clearChromeHover() {
    if (_chromeHoverKey == null) return;
    _chromeHoverKey = null;
    _editable()?.markNeedsPaint();
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
      // Committed by [_finishResize] instead: it needs the widths captured on
      // press, not the generic chrome path.
      TableChromeKind.resizeColumn => null,
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

  /// Starts a selection the field cannot start itself.
  ///
  /// The field's box ends where its text ends and is only as wide as the prose
  /// column, so a press on the paper below the last line, or in the margin
  /// beside it, never reaches the field's recognisers. On a desktop a held
  /// left button out there still means *select* (see `NrsScrollBehavior` in
  /// app.dart), so the editor anchors the range itself and [_onPointerMove]
  /// walks the other end to the pointer.
  ///
  /// The anchor is the nearest place the gesture could be coming from: the end
  /// of the note for the paper below it (which is where a plain click there
  /// lands the caret anyway), the start for the padding above, the line it sits
  /// beside for a margin. Mouse only — a finger or stylus dragging in those
  /// margins is a scroll.
  void _beginOutsideDrag(Offset position, RenderLineEditable field) {
    final TextEditingController c = widget.controller;
    final Offset topLeft = field.localToGlobal(Offset.zero);
    final int at;
    if (position.dy > topLeft.dy + field.size.height) {
      at = c.text.length;
    } else if (position.dy < topLeft.dy) {
      at = 0;
    } else {
      at = _visibleEdgeOffset(
        field,
        field.positionAt(position).offset.clamp(0, c.text.length),
      );
    }
    final TextSelection before = c.selection;
    final bool extend =
        HardwareKeyboard.instance.isShiftPressed && before.isValid;
    final int anchor = extend ? before.baseOffset.clamp(0, c.text.length) : at;
    _outsideAnchor = anchor;
    _downPosition = position;
    _gestureMoved = false;
    _secondaryGesture = false;
    _caretBeforeCheckboxTap = null;
    if (c is MarkdownSourceController) {
      // The same freeze a press on the text takes: the layout under the pointer
      // must not reflow when the reveal catches up halfway through the drag.
      c.revealAs = c.selection;
      c.revealSuppressed = false;
      c.disarmClickGuard();
    }
    widget.focusNode.requestFocus();
    c.selection = extend
        ? TextSelection(baseOffset: anchor, extentOffset: at)
        : TextSelection.collapsed(offset: at);
    // ⛔ The field's `onTapOutside` unfocuses at the end of this very event,
    // after this listener has run — same trap as the paper click below the
    // text. Re-assert once the frame is over.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.focusNode.hasFocus) return;
      widget.focusNode.requestFocus();
    });
  }

  /// The source offset a pointer at the visual start of a line means.
  ///
  /// While the reveal is frozen, a line's Markdown prefix (`# `, `> `) is
  /// hidden and has zero width: the first visible glyph starts at the offset
  /// *after* it, so `positionAt` over that glyph answers the prefix's
  /// end. On release the line reveals and the prefix appears — outside the
  /// wash, which is why 从下往上框选标题时最上面的 `#` 号没有选中。 A drag edge
  /// that lands on the visual start of a line therefore walks back over the
  /// prefix; the walk only happens when every character before [offset] paints
  /// nothing, so a pointer anywhere on painted text is untouched.
  int _visibleEdgeOffset(RenderLineEditable field, int offset) {
    final String text = widget.controller.text;
    if (offset <= 0 || offset > text.length) return offset;
    final int lineStart = lineStartOf(text, offset);
    if (lineStart >= offset) return offset;
    final bool hidden = field
        .selectionBands(
          TextSelection(baseOffset: lineStart, extentOffset: offset),
        )
        .every((Rect band) => band.width <= 0);
    if (!hidden) return offset;
    // 列表标记根本没进 painter（`paintedFrom` 已经越过 `1. [ ] `）：回溯到
    // 行首会选中屏幕上不存在的源码，松开鼠标后连标记一起洗蓝、一起复制。
    // 标题/引用的前缀在 painter 里只是被排成零宽，`paintedFrom` 仍是行首，
    // 回溯照旧，让 `# ` 跟着显示出来的标题一起被选中。
    final LineDocumentLayout? layout = field.lineLayout;
    if (layout != null) {
      for (final LaidOutLine line in layout.laidOut) {
        if (offset < line.source.start || offset > line.source.end) continue;
        if (line.source.isList && !line.slot.revealedMarkers) return offset;
        break;
      }
    }
    return lineStart;
  }

  /// Applies [_visibleEdgeOffset] to both ends of a finished range.
  ///
  /// Only the editor's own outside drag can correct itself while the pointer
  /// moves; a range the field's recognisers wrote has to wait until the gesture
  /// is over, still before [_endGesture] lets the reveal go — the frozen tree
  /// is what tells the edges apart from a genuine mid-line offset.
  void _snapDragEdges() {
    final TextEditingController c = widget.controller;
    final RenderLineEditable? field = _editable();
    if (field == null) return;
    final TextSelection sel = c.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final int base = _visibleEdgeOffset(field, sel.baseOffset);
    final int extent = _visibleEdgeOffset(field, sel.extentOffset);
    if (base == sel.baseOffset && extent == sel.extentOffset) return;
    c.selection = TextSelection(
      baseOffset: base,
      extentOffset: extent,
      affinity: sel.affinity,
      isDirectional: sel.isDirectional,
    );
  }

  /// Recorded on *down*: the field moves the caret on pointer-down, so reading
  /// the selection on up would already be too late.
  void _onPointerDown(PointerDownEvent event) {
    _dragAnchor = null;
    _foldPress = false;
    // The title is scrolled with the document but is not part of the sheet:
    // its own field handles the press, and running the editor's "outside the
    // text" drag here would select body text from a title click.
    if (_overHeader(event.position)) return;
    // A press on the scrollbar is the scrollbar's: it is painted over the
    // right edge of the viewport, outside the field's box, so the branch
    // further down would take it for "the paper beside the text" and anchor a
    // selection there — dragging the bar then selected text instead of
    // scrolling.
    if (_overScrollbar(event.position)) {
      _scrollbarPress = true;
      _downPosition = null;
      _gestureMoved = false;
      _outsideAnchor = null;
      _grabbedRow = null;
      _grabbed = null;
      // The field's tap-outside unfocuses at the end of this very event; put
      // the caret's focus back once that has landed, like a paper click does.
      if (widget.focusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || widget.focusNode.hasFocus) return;
          widget.focusNode.requestFocus();
        });
      }
      return;
    }
    final bool secondary = event.buttons & kSecondaryMouseButton != 0;
    // 按在别处就把图片的选中态收掉：边框是「我正在看这张图」的记号。
    if (_selectedImageLine != null && _imageLineAt(event.position) == null) {
      _selectImage(null);
    }
    // 图片手柄在选区拖动之前判定：按下只开始改宽，不移动光标、不进入选字。
    // 命中的是 `_ChromeShield`，所以焦点得自己补。
    if (!secondary) {
      final ({int lineStart, double startWidth, double startDx, double maxWidth})?
      handle = _imageHandleAt(event.position);
      if (handle != null) {
        _imageResize = handle;
        _rangeBeforeChromeTap = null;
        _downPosition = event.position;
        _gestureMoved = false;
        widget.focusNode.requestFocus();
        _setCursor(SystemMouseCursors.resizeUpLeftDownRight);
        if (widget.focusNode.hasFocus) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || widget.focusNode.hasFocus) return;
            widget.focusNode.requestFocus();
          });
        }
        return;
      }
    }
    // 点图片本体：不落光标（图片行是自绘的，光标进去看不见也没意义），只把
    // 它选中——边框加上，右上角的两个按钮固定显示。
    //
    // ⛔ 这里**不建拖动候选**。搬图只有右上角那颗按钮一条路：图片是正文里
    //    最大的一块，随手一拖就把它挪走，比「拖不动」难受得多。想搬就点按钮，
    //    那个动作是明确的。
    final int? imageLine = _imageLineAt(event.position);
    if (imageLine != null) {
      _selectImage(imageLine);
      if (!secondary) {
        _rangeBeforeChromeTap = null;
        _downPosition = event.position;
        _gestureMoved = false;
        // 命中被 `_ChromeShield` 挡下了，字段收不到这一下，它的「点空白处
        // 失焦」却照样在事件末尾生效。不补回来，选中图片后按 Backspace
        // 删图会一点反应都没有——键盘事件全落在一个没有焦点的字段上。
        widget.focusNode.requestFocus();
        if (widget.focusNode.hasFocus) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || widget.focusNode.hasFocus) return;
            widget.focusNode.requestFocus();
          });
        }
        return;
      }
      // 右键仍然要菜单。图片挡住了字段，菜单不会自己弹，这里照正文那条路由
      // 补上：先把落点放进这一行，菜单才知道该对哪一行下手。
      final TextEditingController c = widget.controller;
      if (c is MarkdownSourceController) {
        c.disarmClickGuard();
        _placeCaret(c, event.position, keepSelection: true);
        _showMenuAt(event.position);
      }
      return;
    }
    // 标签胶囊只在按下这一刻还铺着底片：输入框马上会把光标落进标签、退回
    // 源码，等到抬起再命中就找不到它了。悬停命中的区间是同一块胶囊的兜底，
    // 防止按下时输入框已经把光标挪进去。
    _tagBeforeTap = (secondary || widget.onTagTap == null)
        ? null
        : (_tagAt(event.position) ?? _hoverTag);
    _wikilinkBeforeTap =
        (secondary || widget.onWikilinkTap == null || _tagBeforeTap != null)
        ? null
        : (_wikilinkAt(event.position) ?? _hoverWikilink);
    final TextSelection caret = widget.controller.selection;
    // 按下这一刻摊开的就是光标所在行（见 [_openLineAtDown]）。
    _openLineAtDown = caret.isValid
        ? lineStartOf(widget.controller.text, caret.start)
        : null;
    final ({int start, int end, String url})? hitLink =
        (secondary ||
            widget.onLinkTap == null ||
            !_jumpModifier ||
            _tagBeforeTap != null ||
            _wikilinkBeforeTap != null)
        ? null
        : (_linkAt(event.position) ?? _hoverLink);
    // 单击只落光标：链接是正文的一部分，点它十次有九次是想改字。跳转留给
    // Ctrl/⌘ + 单击（[_jumpModifier]），否则每点一下弹一次浏览器，链接就
    // 没法编辑了。
    _linkBeforeTap = hitLink;
    _caretBeforeTagTap = _tagBeforeTap != null && caret.isValid ? caret : null;
    _caretBeforeWikilinkTap = _wikilinkBeforeTap != null && caret.isValid
        ? caret
        : null;
    _caretBeforeLinkTap = _linkBeforeTap != null && caret.isValid
        ? caret
        : null;
    if (!secondary) {
      // 折叠箭头在自己的按钮上：一次按下就收起/展开，光标原地不动。
      final ListFoldHandle? fold = _foldButtonAt(
        event.position,
        visibleOnly: true,
      );
      if (fold != null) {
        _toggleListFold(fold);
        _foldPress = true;
        _downPosition = event.position;
        _gestureMoved = false;
        return;
      }
      final (TableRowChrome, TableChromeTarget)? hit = _chromeAt(
        event.position,
      );
      if (hit != null) {
        // The chrome shield keeps this press out of the field, so focusing is
        // ours to do — otherwise a grip or `+` clicked from an unfocused
        // editor would act without giving the keyboard anywhere to go.
        widget.focusNode.requestFocus();
        if (hit.$2.kind == TableChromeKind.resizeColumn) {
          // 列宽拖动不动选区：按下只记下拖动前的几何，松手才写文档。
          final TableRowChrome row = hit.$1;
          final Rect bounds = row.chromeBounds();
          _resize = (
            tableId: row.chromeTableId,
            boundary: hit.$2.index,
            startX: event.position.dx,
            boundaryX: hit.$2.rect.left - bounds.left,
            room: row.chromeColumnRoom(),
            scale: row.chromeWidthScale(),
            widths: row.chromeColumnWidths(),
          );
          _rangeBeforeChromeTap = null;
          _downPosition = event.position;
          _gestureMoved = false;
          _setCursor(_cursorAt(event.position));
          // The press lands on the shield, not the field's tap region, so the
          // field's tap-outside handler may unfocus it. Ctrl+Z right after a
          // resize has to reach the editor's own history.
          if (widget.focusNode.hasFocus) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || widget.focusNode.hasFocus) return;
              widget.focusNode.requestFocus();
            });
          }
          return;
        }
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
    // A primary mouse press outside the field's box: the paper below the last
    // line, the roof above the first, the margin beside the column. The field
    // never sees these, so the drag-select has to be driven here.
    if (!secondary && event.kind == PointerDeviceKind.mouse) {
      final RenderLineEditable? field = _editable();
      if (field != null) {
        final Rect box = field.localToGlobal(Offset.zero) & field.size;
        if (!box.contains(event.position)) {
          _beginOutsideDrag(event.position, field);
          return;
        }
      }
    }
    // The paper below the last line is nobody's: the field is exactly as tall
    // as its text, so a press down there never reached it — the caret only
    // appeared when the click landed on a line that already had words on it.
    // Treat the empty sheet as "carry on at the end", which is what every
    // editor does, and give the field the focus a tap on text would have.
    if (_belowText(event.position)) {
      if (secondary) {
        // A right-click out here is the same gesture as one on the text, and it
        // has to give the same menu. The field never sees it, so the menu is
        // opened by hand — after the caret has been parked at the end, so the
        // rows describe the place the menu was summoned from.
        _focusBodyAtEnd();
        _showMenuAt(event.position);
        _downPosition = null;
        _gestureMoved = false;
        return;
      }
      _focusBodyAtEnd();
      // ⛔ On desktop a `TextField` unfocuses the primary focus when a press
      // lands outside it, and that runs **after** this handler — the press is
      // outside both the title and the body, so the focus asked for above was
      // taken straight back and only a second click stuck. Re-assert at the end
      // of the frame, once that unfocus has landed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.focusNode.hasFocus) return;
        _focusBodyAtEnd();
      });
      _downPosition = null;
      _gestureMoved = false;
      return;
    }
    // The caret to hand back is the one on screen: `revealAs` is cleared on
    // release, so at pointer-down the controller's selection and the painted
    // layout still agree.
    final TextEditingController anchor = widget.controller;
    _caretBeforeCheckboxTap = _checkboxAt(event.position) == null
        ? null
        : anchor.selection;
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
      _setMarkerReveal(null);
      c.disarmClickGuard();
      _placeCaret(c, event.position, keepSelection: true);
      // 右键菜单由编辑器自己开：按行渲染的输入框不转给 `contextMenuBuilder`
      //（那个入口已经在阶段 4 删掉了），这条路由必须在这里接上。
      _showMenuAt(event.position);
      return;
    }

    // Freeze the reveal for the whole gesture. A tap and a drag both start here,
    // and what the user is aiming at is what was painted a moment ago — letting
    // the markers appear the instant the button goes down reflows the line under
    // a hand that has not moved yet, which is how a drag over 「编辑器」 ends up
    // selecting 「编辑」. The reveal catches up on release.
    c.revealAs = c.selection;
    // 落点就是“用户开始编辑这一行”的凭据：刚打开笔记时的静默揭示到此结束。
    c.revealSuppressed = false;
    // A click must stay a click. The guard has to live in the controller rather
    // than here — see [MarkdownSourceController.armClickGuard] — and the anchor
    // is taken *now*, while the reveal is still frozen, so it refers to the
    // layout the user is actually pointing at.
    c.disarmClickGuard();
    // 点正文或别处一律收起展开的标记；标记本身留到抬手再摊开——按下就摊会让
    // 整行在手指还没动的时候重排（见上面冻结揭示选区的理由）。
    _markerCaret = null;
    _pendingMarker = null;
    final int? checkbox = _checkboxAt(event.position);
    if (checkbox != null) {
      // 复选框和序号是同一个标记的两段。以前点复选框只翻转、不进编辑态，
      // 点序号才摊开，于是「有序任务」这一行两段各进各的——点一下方框，
      // 前面的 `1. ` 还画在槽位里。现在照常记下这一行的标记范围，抬手时
      // 和序号一样整行摊开；翻转仍然在抬手那段做。
      _pendingMarker = _markerRangeOf(checkbox);
      _setMarkerReveal(null);
      return;
    }
    final RenderLineEditable? editable = _editable();
    if (editable == null) return;
    // 只有按在文字框里的指针才移动光标。页面两侧的留白属于外层的滚动视图：
    // 在那里拖动是滚动，硬把光标放过去会让「光标可得见」把滚动位置拽回原处，
    // 一段长笔记就再也拖不动了。
    final Rect fieldBox = editable.localToGlobal(Offset.zero) & editable.size;
    if (!fieldBox.contains(event.position)) return;
    int at = editable.positionAt(event.position).offset.clamp(0, c.text.length);
    // 点在列表标记槽位里：把 `- ` / `1. ` / `[ ] ` 摊进正文，并把光标放到
    // 点中的字间。落在正文上时 listMarkerAt 返回 null，行为完全不变。
    ({int start, int markerStart, int paintStart, bool revealed, int caret})?
    marker = editable.listMarkerAt(event.position);
    _pendingMarker = marker;
    if (marker == null) {
      _setMarkerReveal(null);
    } else if (!marker.revealed) {
      // 换行才收起；同一行押着不动它，抬手时还要接着摊开。
      if (_markerReveal?.start != marker.start) _setMarkerReveal(null);
      // 点 `1.` 的哪一段就落在哪一段：点中序号右侧不该把光标拽回最左边。
      // 标记起点仍然在缩进之后，输入不会插到缩进前面。
      at = marker.caret;
      _markerCaret = marker.caret;
    }
    final ({TableBlock block, int row, int column, TableCell cell})? cell =
        _paintedCellAt(event.position);
    if (cell != null) at = _caretInCell(cell.cell, at);
    c.armClickGuard(at);
    // 按行渲染的输入框没有 `TextField` 的手势层：落点、Shift 扩选、拖选都由这里
    // 直接驱动。`positionAt` 就是渲染对象自己的命中，和画面对齐。
    widget.focusNode.requestFocus();
    final TextSelection before = c.selection;
    final bool extend =
        HardwareKeyboard.instance.isShiftPressed &&
        before.isValid &&
        before.baseOffset != at;
    if (extend) {
      // 扩选是刻意的范围，不能被“点击守卫”折回光标。
      c.disarmClickGuard();
      c.selection = TextSelection(
        baseOffset: before.baseOffset,
        extentOffset: at,
      );
    } else {
      c.selection = TextSelection.collapsed(offset: at);
    }
    _dragAnchor = extend ? before.baseOffset : at;
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
    if (_resize != null) {
      _dragResize(event.position);
      return;
    }
    if (_imageResize != null) {
      _dragImageResize(event.position);
      return;
    }
    if (_imageMove != null) {
      _dragImageMove(event.position);
      return;
    }
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
      // The preview is a paint-only state; a pointer move never rebuilds the
      // editor, so without this it would only appear on the next stray frame.
      _editable()?.markNeedsPaint();
      return;
    }
    final int? outside = _outsideAnchor;
    if (outside != null) {
      final Offset from = _downPosition ?? event.position;
      if (!_gestureMoved && (event.position - from).distance > kTouchSlop) {
        _gestureMoved = true;
      }
      if (!_gestureMoved) return;
      final RenderLineEditable? field = _editable();
      if (field == null) return;
      final TextEditingController c = widget.controller;
      final int at = field.positionAt(event.position).offset;
      c.selection = TextSelection(
        baseOffset: outside.clamp(0, c.text.length),
        extentOffset: _visibleEdgeOffset(field, at.clamp(0, c.text.length)),
      );
      return;
    }
    final Offset? from = _downPosition;
    if (from == null) return;
    if (!_gestureMoved) {
      if ((event.position - from).distance <= kTouchSlop) return;
      _gestureMoved = true;
      // It turned out to be a drag, and a range is exactly what a drag means:
      // let the guard go before the first move asks for one.
      final TextEditingController c = widget.controller;
      if (c is MarkdownSourceController) c.disarmClickGuard();
    }
    // 拖选：从按下时记下的落点拉到当前指针。裸输入框不再替我们做这件事。
    final int? anchor = _dragAnchor;
    if (anchor == null) return;
    final RenderLineEditable? field = _editable();
    if (field == null) return;
    final TextEditingController c = widget.controller;
    final int at = field.positionAt(event.position).offset;
    c.selection = TextSelection(
      baseOffset: anchor.clamp(0, c.text.length),
      extentOffset: at.clamp(0, c.text.length),
    );
  }

  /// One frame of a divider drag: compute the pair, move the ghost line, and
  /// repaint. No document write and no layout while the button is down — the
  /// visible widths are captured on press and the edit happens once on release.
  void _dragResize(Offset position) {
    final _Resize resize = _resize!;
    final double dx = position.dx - resize.startX;
    if (!_gestureMoved) {
      if (dx.abs() < kTableResizeStartSlop) return;
      _gestureMoved = true;
    }
    final double left = _resizeTo(resize, dx).left;
    tableResizePreview.value = TableResizePreview(
      tableId: resize.tableId,
      localX: resize.boundaryX + left - resize.widths[resize.boundary],
    );
    _editable()?.markNeedsPaint();
  }

  /// 一次拖动在水平位移 [dx] 之后的新列宽（渲染像素）。
  ///
  /// [left] 是线左边那一列的宽度；[right] 是右边那一列的宽度，拖**最右外沿**
  /// 时为 `null`——那条线右边没有列可以让位，只能长到整张表铺满正文为止。
  ({double left, double? right}) _resizeTo(_Resize resize, double dx) {
    final int b = resize.boundary;
    final double left = resize.widths[b];
    final double sum = resize.widths.fold<double>(
      0,
      (double a, double w) => a + w,
    );
    if (b + 1 >= resize.widths.length) {
      return (
        left: resizeEdgeColumn(
          left: left,
          // 其它列都不动时，这一列还能长到多少。
          ceiling: resize.room - (sum - left),
          dx: dx,
        ),
        right: null,
      );
    }
    final (double nextLeft, double nextRight) = resizeColumnPair(
      left: left,
      right: resize.widths[b + 1],
      dx: dx,
      room: resize.room,
      others: sum - left - resize.widths[b + 1],
    );
    return (left: nextLeft, right: nextRight);
  }

  /// Ends a divider drag: one document edit, or none when the divider never
  /// actually moved.
  void _finishResize(Offset position) {
    final _Resize resize = _resize!;
    final bool moved = _gestureMoved;
    _resize = null;
    tableResizePreview.value = null;
    tablePointerPosition.value = position;
    _setCursor(_cursorAt(position));
    _downPosition = null;
    _gestureMoved = false;
    _rangeBeforeChromeTap = null;
    // The ghost line is gone even when no edit lands, and the cursor does not
    // change (the pointer is still on the divider), so nothing else would
    // repaint it away.
    _editable()?.markNeedsPaint();
    if (!moved) return;

    final ({double left, double? right}) next = _resizeTo(
      resize,
      position.dx - resize.startX,
    );
    if ((next.left - resize.widths[resize.boundary]).abs() < 0.5) return;
    final List<double> widths = List<double>.of(resize.widths);
    widths[resize.boundary] = next.left;
    final double? right = next.right;
    if (right != null) widths[resize.boundary + 1] = right;
    final TextEditingValue? edited = resizeTableColumns(
      widget.controller.value,
      tableId: resize.tableId,
      widths: <int>[
        for (final double w in widths) math.max(1, (w / resize.scale).round()),
      ],
    );
    if (edited == null) return;
    widget.controller.value = edited;
    widget.onChanged?.call(edited.text);
  }

  /// 从右上角的移动按钮开始拖。
  ///
  /// 那个按钮存在的意义就是拖动，所以不等拖拽阈值：按下去就已经在搬了。
  /// 指针后续的移动 / 抬起由那颗按钮自己的 [Listener] 直接送进来——它压在
  /// 字段上面，字段收不到这些事件。
  ///
  /// 这也是**唯一**的搬图入口。点图片本体只选中，不搬。
  void _beginImageMoveFromHandle(int line) {
    setState(() {
      _selectedImageLine = line;
      _imageMove = _ImageMove(lineStart: line)..size = _imageSizeAt(line);
    });
    _applyImageSelection();
    _setCursor(SystemMouseCursors.grabbing);
  }

  /// 一帧拖动：把指针的 y 吸附到最近的行边界，指针的 x 决定贴哪一边。
  ///
  /// 和改宽一样，拖动期间**一个字节都不写**：整行搬移会在松手时一次性落成，
  /// 否则每移动一像素就是一步撤销，光标还会在搬来搬去的行里乱跳。
  void _dragImageMove(Offset position) {
    final _ImageMove move = _imageMove!;
    final RenderLineEditable? field = _editable();
    final RenderObject? root = context.findRenderObject();
    if (field == null || root is! RenderBox || !root.hasSize) return;
    final ({Rect line, int offset})? target = field.dropTargetAt(position);
    if (target == null) return;

    // 落在自己身上（自己这一行的行首，或紧跟其后的下一行行首）等于没挪位置，
    // 但**贴哪一边**仍然可以变：原地往左一拖就是把这张图改成左浮动。
    //
    // 浮动图片那一行高度是 0，指针停在图上时按行边界算会落到它下面那一行去；
    // 所以指针只要还压在图上，就一律当「原地」。
    final ({int from, int to, String text})? own = _sourceLineAt(move.lineStart);
    final String text = widget.controller.text;
    final int ownEnd = own == null
        ? -1
        : (own.to < text.length ? own.to + 1 : own.to);
    final bool onSelf = _imageBoundsOf(move.lineStart)?.contains(position) ?? false;
    final bool same =
        onSelf || target.offset == move.lineStart || target.offset == ownEnd;

    // 落点在正文的哪一栏：左三分之一贴左，右三分之一贴右，中间独占一行。
    final double left = target.line.left;
    final double width = math.max(1.0, target.line.width);
    final double x = position.dx - left;
    final ImageAlign? align = x < width * 0.34
        ? ImageAlign.left
        : (x > width * 0.66 ? ImageAlign.right : null);

    final Rect local = Rect.fromPoints(
      root.globalToLocal(target.line.topLeft),
      root.globalToLocal(target.line.bottomRight),
    );
    // 预览框：贴边时是图片真会占的那块，独占一行时铺满整栏。
    final double ghostHeight = move.size.height;
    final double ghostWidth = align == null ? width : move.size.width;
    final double ghostLeft = align == ImageAlign.right
        ? left + width - ghostWidth
        : left;
    final Rect ghost = Rect.fromPoints(
      root.globalToLocal(Offset(ghostLeft, target.line.top)),
      root.globalToLocal(
        Offset(ghostLeft + ghostWidth, target.line.top + ghostHeight),
      ),
    );
    if (move.target == (same ? null : target.offset) &&
        move.align == align &&
        _sameRect(move.ghost, ghost) &&
        _sameRect(move.dropLine, align == null && !same ? local : null)) {
      return;
    }
    setState(() {
      move.target = same ? null : target.offset;
      move.align = align;
      move.ghost = ghost;
      // 贴边时预览框已经说明了落点，再画一条插入线只是噪音。
      move.dropLine = align == null && !same ? local : null;
    });
  }

  /// 松手：把这一整行搬到落点，并按落点写好贴哪一边。
  void _finishImageMove(Offset position) {
    final _ImageMove move = _imageMove!;
    final int? target = move.target;
    final ImageAlign? align = move.align;
    _imageMove = null;
    _downPosition = null;
    _gestureMoved = false;
    _setCursor(_cursorAt(position));
    // 插入线与预览框都是画出来的，状态一清就得重画一遍。
    setState(() {});

    final ({int from, int to, String text})? line = _sourceLineAt(
      move.lineStart,
    );
    if (line == null) return;
    final ImageMarkup? markup = ImageMarkup.parseLine(line.text);
    if (markup == null) return;

    // 落点的对齐直接定死：`toMarkdown(align: null)` 会退回**原来那个**对齐，
    // 而这里「没贴边」的意思正是要把原来的浮动取消掉。
    final String rewritten = ImageMarkup(
      source: markup.source,
      alt: markup.alt,
      width: markup.width,
      align: align,
    ).toMarkdown(asTag: align != null);
    String text = widget.controller.text;
    int caret = line.from;
    if (target != null) {
      final ({String text, int caret, int delta})? moved = moveSourceLine(
        text: text,
        lineStart: line.from,
        lineEnd: line.to,
        insertAt: target,
      );
      if (moved != null) {
        text = moved.text;
        caret = moved.caret;
      }
    }
    // 对齐和搬家合成**一次**写入：两步写下去就是两步撤销，人得按两次 Ctrl+Z
    // 才回到拖动之前。
    if (rewritten != line.text) {
      text = text.replaceRange(caret, caret + line.text.length, rewritten);
    }
    if (text == widget.controller.text) return;
    _history.breakMerge();
    _applyEdit(
      (TextEditingValue _) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );
    // 搬完仍然选中它：人得看得见自己刚把哪张图挪到了哪儿。
    _selectImage(caret);
  }

  /// Esc 或手势被取消：插入线丢掉，文档一个字都不动。
  void _cancelImageMove() {
    if (_imageMove == null) return;
    _imageMove = null;
    _downPosition = null;
    _gestureMoved = false;
    setState(() {});
  }

  /// One frame of an image resize: the preview width changes, the document does
  /// not. Writing the controller on every move would stack up dozens of undo
  /// steps and make the caret jump inside a line whose length keeps changing.
  void _dragImageResize(Offset position) {
    final resize = _imageResize!;
    final double ceiling = math.max(96.0, resize.maxWidth);
    final double width = (resize.startWidth + position.dx - resize.startDx)
        .clamp(96.0, ceiling);
    if ((width - resize.startWidth).abs() >= 0.5) _gestureMoved = true;
    _imageBlocks?.setPreviewWidth(resize.lineStart, width);
    _editable()?.invalidateImageLine(resize.lineStart);
  }

  /// Ends an image resize: drop the preview, then write the width once.
  ///
  /// The line is regenerated from its own markup (`![…]` stays Markdown when it
  /// had no width, an `<img … width>` replaces it when it did), so the drag
  /// commits to the same syntax the line already uses.
  void _finishImageResize(Offset position) {
    final resize = _imageResize!;
    final double startWidth = resize.startWidth;
    final double? preview = _imageBlocks?.previewWidthOf(resize.lineStart);
    _imageResize = null;
    _downPosition = null;
    _gestureMoved = false;
    _imageBlocks?.setPreviewWidth(resize.lineStart, null);
    _editable()?.invalidateImageLine(resize.lineStart);
    _setCursor(_cursorAt(position));
    if (preview == null || (preview - startWidth).abs() < 0.5) return;

    _history.breakMerge();
    _applyEdit((TextEditingValue current) {
      final String text = current.text;
      if (resize.lineStart < 0 || resize.lineStart > text.length) return current;
      final int end = lineEndOf(text, resize.lineStart);
      final String oldLine = text.substring(resize.lineStart, end);
      final ImageMarkup? markup = ImageMarkup.parseLine(oldLine);
      if (markup == null) return current;
      final String line = markup.toMarkdown(width: preview.roundToDouble());
      if (line == oldLine) return current;

      final int delta = line.length - oldLine.length;
      int shift(int offset) => offset >= end ? offset + delta : offset;
      final String next = text.replaceRange(resize.lineStart, end, line);
      final TextSelection sel = current.selection;
      final TextSelection selection;
      if (!sel.isValid) {
        selection = sel;
      } else if (sel.isCollapsed) {
        selection = TextSelection.collapsed(
          offset: shift(sel.baseOffset).clamp(0, next.length),
          affinity: sel.affinity,
        );
      } else {
        selection = TextSelection(
          baseOffset: shift(sel.baseOffset).clamp(0, next.length),
          extentOffset: shift(sel.extentOffset).clamp(0, next.length),
          affinity: sel.affinity,
          isDirectional: sel.isDirectional,
        );
      }
      return TextEditingValue(
        text: next,
        selection: selection,
        composing: TextRange.empty,
      );
    });
  }

  /// Esc or a cancelled gesture: throw the preview away, write nothing.
  void _cancelImageResize() {
    final ({int lineStart, double startWidth, double startDx, double maxWidth})?
    resize = _imageResize;
    if (resize == null) return;
    _imageResize = null;
    _downPosition = null;
    _gestureMoved = false;
    _imageBlocks?.setPreviewWidth(resize.lineStart, null);
    _editable()?.invalidateImageLine(resize.lineStart);
  }

  void _onPointerUp(PointerUpEvent event) {
    _dragAnchor = null;
    // The gesture was the scrollbar's from the first pixel; the caret and the
    // selection it started from are none of its business.
    if (_scrollbarPress) {
      _scrollbarPress = false;
      _downPosition = null;
      _gestureMoved = false;
      _endGesture();
      return;
    }
    if (_foldPress) {
      _foldPress = false;
      _downPosition = null;
      _gestureMoved = false;
      _setCursor(_cursorAt(event.position));
      return;
    }
    final TextRange? tappedTag = _tagBeforeTap;
    final TextSelection? tappedTagCaret = _caretBeforeTagTap;
    _tagBeforeTap = null;
    _caretBeforeTagTap = null;
    final ({int start, int end, String target})? tappedWikilink =
        _wikilinkBeforeTap;
    final TextSelection? tappedWikilinkCaret = _caretBeforeWikilinkTap;
    _wikilinkBeforeTap = null;
    _caretBeforeWikilinkTap = null;
    final ({int start, int end, String url})? tappedLink = _linkBeforeTap;
    final TextSelection? tappedLinkCaret = _caretBeforeLinkTap;
    _linkBeforeTap = null;
    _caretBeforeLinkTap = null;
    final int? openLine = _openLineAtDown;
    _openLineAtDown = null;
    // 按下时命中的列表标记：只有“按下和抬手都在原地”的那一次点击才摊开它。
    final ({
      int start,
      int markerStart,
      int paintStart,
      bool revealed,
      int caret,
    })?
    pendingMarker = _pendingMarker;
    _pendingMarker = null;
    if (_resize != null) {
      _finishResize(event.position);
      return;
    }
    if (_imageResize != null) {
      _finishImageResize(event.position);
      return;
    }
    if (_imageMove != null) {
      _finishImageMove(event.position);
      return;
    }
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
    if (_outsideAnchor != null) {
      _outsideAnchor = null;
      _downPosition = null;
      _gestureMoved = false;
      _endGesture();
      return;
    }
    final TextSelection? saved = _caretBeforeCheckboxTap;
    final bool secondary = _secondaryGesture;
    _caretBeforeCheckboxTap = null;
    _secondaryGesture = false;
    // A range the field itself drove was mapped against the frozen reveal, so
    // its edges can sit just past a hidden `# ` (see [_visibleEdgeOffset]).
    // The outside drag snapped as it moved; this is the same correction, once,
    // for a drag that started inside the field — and it has to run *before*
    // [_endGesture], while the frozen tree still hides the prefix.
    if (!secondary && _gestureMoved) _snapDragEdges();
    _endGesture();
    if (secondary) {
      // Right-click already put the caret where the pointer was, and the menu is
      // on its way up. The "a click is a click" cleanup below exists for the
      // left button's word/line selection; letting it run here would collapse
      // the very selection the menu is about to offer 复制 for.
      _downPosition = null;
      return;
    }
    // A tag chip is a link, not text: a plain click on it opens the search
    // instead of dropping a caret. Dragging off a chip is still a drag.
    if (tappedTag != null && !_gestureMoved) {
      final String text = widget.controller.text;
      if (tappedTag.end <= text.length) {
        final String token = text.substring(tappedTag.start, tappedTag.end);
        _downPosition = null;
        if (tappedTagCaret != null) {
          // 输入框会在这次事件之后才落光标，所以归还也要晚一拍；同帧内完成，
          // 画面不会先露出源码再跳走。
          scheduleMicrotask(() {
            if (mounted) widget.controller.selection = tappedTagCaret;
          });
        }
        widget.onTagTap?.call(
          token.startsWith('#') ? token.substring(1) : token,
        );
      }
      return;
    }
    // 双链也是一次跳转：按下时命中的链接在抬起仍算一次点击时打开。光标先
    // 归还一拍，链接本来的折叠态才不会因为这次点击留在展开的源码上。
    if (tappedWikilink != null && !_gestureMoved) {
      _downPosition = null;
      if (tappedWikilinkCaret != null) {
        scheduleMicrotask(() {
          if (mounted) widget.controller.selection = tappedWikilinkCaret;
        });
      }
      widget.onWikilinkTap?.call(tappedWikilink.target);
      return;
    }
    // 外链：Ctrl/⌘ + 单击才跳转。光标先归还一拍——跳转不是一次落点，不该
    // 顺手把光标挪到链接里。
    if (tappedLink != null && !_gestureMoved) {
      _downPosition = null;
      if (tappedLinkCaret != null) {
        scheduleMicrotask(() {
          if (mounted) widget.controller.selection = tappedLinkCaret;
        });
      }
      widget.onLinkTap?.call(tappedLink.url);
      return;
    }
    final int? at = _checkboxAt(event.position);
    if (at == null) {
      // 抬手还在标记上：这才是“点了标记”，现在把源码摊进正文。
      if (pendingMarker != null && !_gestureMoved) {
        _setMarkerReveal((
          start: pendingMarker.start,
          paintStart: pendingMarker.paintStart,
        ));
      }
      // Whatever a fast click-talk let the platform select on the way *up*.
      final TextEditingController c = widget.controller;
      if (c is MarkdownSourceController) _clickCaret(c, event.position);
      // 点在链接胶囊的留白上时命中不到链接，光标会停在「文字右边」——落进
      // 链接源码里的一律改去行末（理由见 [_parkCaretOutOfLink]）。
      _parkCaretOutOfLink(openLine);
      _restoreMarkerCaret(c);
      _downPosition = null;
      return;
    }

    final TextEditingController c = widget.controller;
    final String next = toggleTaskAt(c.text, at);
    // 点复选框也把整行标记摊进正文——序号和复选框是一段标记的两截，只翻
    // 方框的话前面的 `1. ` 还画在槽位里，两截各进各的。
    //
    // ⚠️ 按下点和抬起点可能不是同一个位置（按在方框右边的留白、抬起才落到
    // 方框上），那种情况下按下的那一下没有记到标记范围，这里按偏移补一次。
    final ({int start, int markerStart, int paintStart, bool revealed, int caret})?
    marker = pendingMarker ?? _markerRangeOf(at);
    final bool reveal = marker != null && !_gestureMoved;
    if (reveal) {
      _setMarkerReveal((
        start: marker.start,
        paintStart: marker.paintStart,
      ));
    }
    // Whatever the pointer dragged out on the way, a click on a marker ends as a
    // click. `TextField` counts clicks, and two of them select a **word**: the
    // marker column is one character wide — the box swallows the rest of
    // `- [ ] ` to nothing — so the range's only box with pixels is the marker
    // cell itself, and the wash paints a square growing out of the checkbox.
    // Handing the old caret back is not enough on its own: a press that missed
    // the box has no caret to hand back.
    //
    // 摊开之后光标要落在**点中的那一段**：还给点之前的位置，人会看见整行
    // 变成源码、光标却还在别处，想改 `[ ]` 还得再点一次。
    final TextSelection end = reveal
        ? TextSelection.collapsed(
            // 夹在标记内部：按下点和抬起点可能不是同一个位置（按下在方框
            // 右边的留白、抬起才落到方框上），换算出来的偏移会跑到正文里去。
            offset: marker.caret
                .clamp(marker.start, marker.paintStart)
                .clamp(0, next.length),
          )
        : (saved ?? TextSelection.collapsed(offset: at));
    _downPosition = null;
    if (next != c.text) {
      // `[ ]` ⇄ `[x]` is one character for one, so selections stay valid, the
      // undo stack survives and nothing downstream re-lays out.
      c.value = c.value.copyWith(text: next, composing: TextRange.empty);
      widget.onChanged?.call(next);
    }
    // Give the caret back: flipping a checkbox should not also move the
    // insertion point (otherwise the next keystroke lands inside the marker).
    // The field's own caret/selection move happens after this handler, so it has
    // to be undone in a microtask — same frame, no visible jump.
    scheduleMicrotask(() {
      if (mounted) c.selection = end;
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _dragAnchor = null;
    _foldPress = false;
    _scrollbarPress = false;
    _markerCaret = null;
    _pendingMarker = null;
    _grabbedRow = null;
    _grabbed = null;
    _outsideAnchor = null;
    _rangeBeforeChromeTap = null;
    _tagBeforeTap = null;
    _caretBeforeTagTap = null;
    _wikilinkBeforeTap = null;
    _caretBeforeWikilinkTap = null;
    _linkBeforeTap = null;
    _caretBeforeLinkTap = null;
    _openLineAtDown = null;
    if (_resize != null) {
      _resize = null;
      tableResizePreview.value = null;
      _editable()?.markNeedsPaint();
    }
    _cancelImageResize();
    _cancelImageMove();
    if (tableDragPreview.value != null) {
      tableDragPreview.value = null;
      _editable()?.markNeedsPaint();
    }
    _setCursor(_cursorAt(event.position));
    _endGesture();
    _downPosition = null;
    _gestureMoved = false;
  }

  /// 滚轮落在自绘控件上时，把滚动交还给滚动视图。
  ///
  /// [`_ChromeShield`] 命中即 `return true`、不再往下问：光标才不会落进图片那
  /// 一行、表格抓手上的一下也不会变成落字。代价是它把整棵
  /// `SingleChildScrollView` 从命中链上剪掉了——滚轮信号（`PointerSignalEvent`
  /// 只发给命中链上的监听者）到不了 `Scrollable`，指针停在图片或表格上就滚不动。
  ///
  /// 这里补一手：注册到 `pointerSignalResolver` 而不是直接滚。正常落在文字上
  /// 时 `Scrollable` 在链上更深、先注册，我们这份会被忽略——不会滚两下；只有
  /// 被盾牌剪掉那一种情况才轮到我们。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final ScrollController controller = widget.scrollController;
    if (!controller.hasClients) return;
    final ScrollPosition position = controller.position;
    final double delta = event.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (
      PointerEvent _,
    ) {
      position.pointerScroll(delta);
    });
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
        _sameRect(anchor, _statsAnchor) &&
        !_imageActionsMoved() &&
        !_imageEditorMoved()) {
      return;
    }
    setState(() {
      _statsKey = key;
      _statsLabel = label;
      _statsAnchor = anchor;
    });
  }

  /// 滚动会把图片挪走，右上角那排按钮得跟着。返回是否真的动了，好让
  /// `_refreshOverlays` 决定要不要 `setState`。
  bool _imageActionsMoved() {
    final int? line = _hoverImageLine ?? _selectedImageLine;
    final Rect? next = _imageActionsRectFor(line);
    if (_sameRect(next, _imageActionsRect)) return false;
    _imageActionsRect = next;
    return true;
  }

  /// 图片上方的源码行也得跟着滚动走，不然图一滚它就悬在半空了。
  bool _imageEditorMoved() {
    final _ImageEdit? edit = _imageEdit;
    if (edit == null) return false;
    final Rect? next = _imagePanelRect(edit.lineStart);
    if (_sameRect(next, edit.panel) || next == null) return false;
    edit.panel = next;
    return true;
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

  // --------------------------------------------------------------- 图片区块

  /// 某一图片行的原文，以及它在文档里的范围。
  ({int from, int to, String text})? _sourceLineAt(int lineStart) {
    final String doc = widget.controller.text;
    if (lineStart < 0 || lineStart > doc.length) return null;
    final int newline = doc.indexOf('\n', lineStart);
    final int to = newline < 0 ? doc.length : newline;
    return (from: lineStart, to: to, text: doc.substring(lineStart, to));
  }

  /// 打开图片行的源码编辑。
  ///
  /// 输入框**浮在图片上沿**，一个像素都不占布局：图片的位置、大小、贴哪一边
  /// 全都不动。改源码是「看这一行字」，不该顺手重排整篇——以前让它占一行高，
  /// 点一下「编辑这个区块」整个版面就跳一次，浮动图片更糟，贴边会被临时取消。
  void _openImageEditor(int lineStart) {
    if (widget.readOnly || _imageEdit != null) return;
    final ({int from, int to, String text})? line = _sourceLineAt(lineStart);
    if (line == null) return;
    final AppPalette palette = _palette ?? AppPalette.light;

    // 先让这一行把浮层的位置算出来（块自己知道输入框该摆在哪），下一帧再摆。
    setState(() {
      _imageSourceLine = lineStart;
      // 按钮自己压着源码行，先收起来；关掉时再按选中态补回来。
      _hoverImageLine = null;
      _imageActionsRect = null;
    });
    _invalidateImageLine(lineStart);

    _mountImageEditor(lineStart, line.text, palette, tries: 0);
  }

  /// 等这一行把浮窗位置算出来，再把输入框挂上去。
  ///
  /// 块要等一次排版才知道浮窗摆在哪，所以必须等下一帧。但「等不到就算了」是
  /// 不行的：滚动、图片刚解码完、增量重排被交回全量，都可能让这一帧拿不到矩形
  /// ——用户看到的就是「点了一下，什么都没发生」，还得再点一次才灵。所以拿不
  /// 到就再等一帧；真的等不到，就按图片本体的位置兜一个底。**点了一定要开**，
  /// 位置差一点也比没反应强。
  void _mountImageEditor(
    int lineStart,
    String text,
    AppPalette palette, {
    required int tries,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _imageSourceLine != lineStart || _imageEdit != null) return;
      Rect? panel = _imagePanelRect(lineStart);
      if (panel == null) {
        if (tries < 4) {
          // 再排一帧：`_invalidateImageLine` 可能把重排推到了下一帧。
          // 没有这一句，空闲时压根不会有下一帧，回调就永远不来了。
          WidgetsBinding.instance.ensureVisualUpdate();
          _mountImageEditor(lineStart, text, palette, tries: tries + 1);
          return;
        }
        panel = _fallbackImagePanel(lineStart);
      }
      // 这一行是 HTML，不是散文：着色交给控制器，输入框本身只管编辑。
      final TextEditingController controller = _HtmlSourceController(
        text: text,
        palette: palette,
      );
      final FocusNode focus = FocusNode(debugLabel: 'nrs-image-editor');
      setState(() {
        _imageEdit = _ImageEdit(lineStart: lineStart, panel: panel!);
        _imageText = controller;
        _imageFocus = focus;
      });
      focus.requestFocus();
      // 光标落在行尾，**不要全选**：整行被选区染色，看上去就是一根紫条，
      // 又像一块面板了。Obsidian 那边也是一行字加一个光标。
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    });
  }

  /// 浮窗位置的兜底：块自己报不出矩形时，按图片本体摆一块。
  ///
  /// 只在「点了编辑却一直拿不到几何」时用得上——那正是最不能没反应的时候。
  Rect _fallbackImagePanel(int lineStart) {
    final RenderObject? root = context.findRenderObject();
    final bool sized = root is RenderBox && root.hasSize;
    final Size size = sized ? root.size : const Size(760, 600);
    Rect image = _imageBoundsOf(lineStart) ?? Rect.zero;
    if (sized && !image.isEmpty) {
      image = Rect.fromPoints(
        root.globalToLocal(image.topLeft),
        root.globalToLocal(image.bottomRight),
      );
    } else {
      image = Rect.fromLTWH(0, 0, size.width, 200);
    }
    final double width = math.max(240.0, math.min(size.width - 32, 380));
    final double left = image.left + 12;
    final double top = image.top + 12;
    return Rect.fromLTWH(
      left.clamp(8.0, math.max(8.0, size.width - width - 8)),
      top.clamp(8.0, math.max(8.0, size.height - 120)),
      width,
      math.max(52.0, math.min(120.0, size.height - top - 8)),
    );
  }

  /// 源码行占的那块地方——浮在图片上沿，这里只是把全局坐标换成编辑器坐标。
  Rect? _imagePanelRect(int lineStart) {
    final RenderObject? root = context.findRenderObject();
    if (root is! RenderBox || !root.hasSize) return null;
    for (final ImageBlockChrome block in _imageChrome()) {
      if (block.imageSourceStart != lineStart) continue;
      final Rect global = block.chromeSourceBounds();
      if (global.isEmpty) return null;
      return Rect.fromPoints(
        root.globalToLocal(global.topLeft),
        root.globalToLocal(global.bottomRight),
      );
    }
    return null;
  }

  /// 全屏看这张图。
  ///
  /// 浮层本身在 `image_viewer.dart`；这里只负责两件事：**把这篇笔记里的图
  /// 都收集起来**（浮层要知道「我是第几张、还有几张」），以及把浮层挂到根
  /// Overlay 上。
  ///
  /// 挂在根 Overlay 而不是编辑器 Stack 里：用户要的是「盖住整个软件」，而
  /// 编辑器只占窗口中间那一块——挂在 Stack 里的话左边文件列表、右边边栏都
  /// 还亮着，放大一张图反而更看不清。
  void _openImageViewer(int lineStart) {
    final String text = widget.controller.text;
    final List<NoteImageView> images = <NoteImageView>[];
    int index = 0;

    // 手动扫行而不是 `split('\n')`：要知道当前这张在列表里的位置，就得跟着
    // 维护行首偏移，正好和 [_sourceLineAt] 的口径一致。
    int offset = 0;
    while (offset <= text.length) {
      final int newline = text.indexOf('\n', offset);
      final int end = newline < 0 ? text.length : newline;
      final ImageMarkup? markup = ImageMarkup.parseLine(
        text.substring(offset, end),
      );
      if (markup != null) {
        final ImageProvider? provider = widget.imageProviderFor?.call(
          markup.source,
        );
        if (provider != null) {
          // 用「落在这一行里」而不是「正好等于行首」：调用方给的是行首偏移，
          // 但差一个字符也不该让浮层从第一张开始。
          if (offset <= lineStart && lineStart <= end) index = images.length;
          images.add(
            NoteImageView(
              source: markup.source,
              alt: markup.alt,
              provider: provider,
              absolutePath: widget.imagePathFor?.call(markup.source),
            ),
          );
        }
      }
      if (newline < 0) break;
      offset = end + 1;
    }

    if (images.isEmpty) return;

    _viewImageEntry?.remove();
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) => NoteImageViewer(
        images: images,
        index: index,
        onClose: _closeImageViewer,
      ),
    );
    _viewImageEntry = entry;
    setState(() => _viewerOpen = true);
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _closeImageViewer() {
    final OverlayEntry? entry = _viewImageEntry;
    if (entry == null) return;
    _viewImageEntry = null;
    entry.remove();
    if (!mounted) return;
    setState(() => _viewerOpen = false);
    widget.focusNode.requestFocus();
  }

  /// 把这一行的源码写回文档。清空等于删掉这个图片区块。
  void _commitImageEditor() {
    final _ImageEdit? edit = _imageEdit;
    final TextEditingController? controller = _imageText;
    if (edit == null || controller == null) return;
    final String next = controller.text.trim();
    final int lineStart = edit.lineStart;
    final String text = widget.controller.text;
    // 先收起来：块要把让出来的那一行还回去，行高得在改字之前恢复。
    _closeImageEditor();
    final ({int from, int to, String text})? line = _sourceLineAt(lineStart);
    if (line == null) return;
    if (next == line.text) return;

    // 整行清空时把换行一起带走，否则会留下一个空段落。
    final int from = line.from;
    final int to = next.isEmpty && line.to < text.length ? line.to + 1 : line.to;
    final String updated = text.replaceRange(from, to, next);
    final int caret = (from + next.length).clamp(0, updated.length);
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: caret),
    );
    widget.onChanged?.call(updated);
    widget.focusNode.requestFocus();
  }

  void _cancelImageEditor() => _closeImageEditor();

  /// 删掉一整个图片区块：整行连同它自己的那个换行。
  ///
  /// 图片是一整块，没有「删一个字符」这回事。只删行内字符的后果有两种：留下
  /// 一个空段落，或者把 `<img …>` 削成半截标签——图片没了，源码却还在原地。
  void _deleteImageLine(int lineStart) {
    final ({int from, int to, String text})? line = _sourceLineAt(lineStart);
    if (line == null) return;
    final String text = widget.controller.text;
    int from = line.from;
    int to = line.to;
    if (to < text.length) {
      // 行尾那个换行属于这一行：一起删掉，下一行顶上来。
      to += 1;
    } else if (from > 0) {
      // 最后一行没有换行可吃，就吃上一行末尾那个，免得留下一个空段落。
      from -= 1;
    }
    final String updated = text.replaceRange(from, to, '');
    final int caret = from.clamp(0, updated.length);
    _history.breakMerge();
    setState(() {
      _hoverImageLine = null;
      _selectedImageLine = null;
      _imageActionsRect = null;
    });
    _applyEdit(
      (TextEditingValue _) => TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: caret),
      ),
    );
  }

  /// 换文档时把图片相关的状态一次清干净。
  ///
  /// 这里不走 `_closeImageEditor()`：正在 `didUpdateWidget` 里，`setState` 是多余
  /// 的，而且旧的那行输入框这一帧还挂着，控制器得等它摘掉再销毁。
  void _dropImageState() {
    final TextEditingController? text = _imageText;
    final FocusNode? focus = _imageFocus;
    _imageEdit = null;
    _imageText = null;
    _imageFocus = null;
    _imageSourceLine = null;
    _selectedImageLine = null;
    _hoverImageLine = null;
    _imageActionsRect = null;
    _imageMove = null;
    final OverlayEntry? viewer = _viewImageEntry;
    _viewImageEntry = null;
    _viewerOpen = false;
    viewer?.remove();
    if (text != null || focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        text?.dispose();
        focus?.dispose();
      });
    }
  }

  void _closeImageEditor() {
    final _ImageEdit? edit = _imageEdit;
    final int? line = edit?.lineStart ?? _imageSourceLine;
    if (line == null) return;
    final TextEditingController? text = _imageText;
    final FocusNode? focus = _imageFocus;
    setState(() {
      _imageEdit = null;
      _imageText = null;
      _imageFocus = null;
      // 块据此把浮层收起来——图片从头到尾没挪过，所以这里只重画不重排。
      _imageSourceLine = null;
      // 那排按钮要跟着回来。点「编辑」时按钮被主动收掉了，这里必须补回来，
      // 否则关掉之后按钮凭空消失：指针明明还停在图上，也不会自己回来——看
      // 起来就是「再想点一次，打不开了」。没选中过任何图时按刚关掉的那一行
      // 补，因为指针就在那儿。
      _hoverImageLine ??= _selectedImageLine == null ? line : null;
      _imageActionsRect = _imageActionsRectFor(_selectedImageLine ?? line);
    });
    _invalidateImageLine(line);
    // 与单元格浮层同一条规矩：等这一帧把字段摘掉再销毁控制器。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      text?.dispose();
      focus?.dispose();
    });
  }

  /// 图片右上角那排按钮，位置由 [_imageActionsRect] 现成给出。
  ///
  /// 悬停出现、离开消失；点中一张图之后固定显示——那时指针可能已经跑远了，
  /// 但人还在看这张图，按钮不该跟着没。
  ///
  /// 这里不碰 `_editable()`：build 期间遍历子元素会抛异常，几何在指针事件和
  /// 滚动回调里算。
  Widget? _imageActions(AppPalette p) {
    final Rect? rect = _imageActionsRect;
    final int? line = _hoverImageLine ?? _selectedImageLine;
    if (rect == null || line == null || _imageEdit != null) return null;
    return Positioned.fromRect(
      rect: rect,
      child: _ImageActions(
        palette: p,
        canEdit: !widget.readOnly,
        onView: () => _openImageViewer(line),
        onEdit: () => _openImageEditor(line),
        onMoveDown: (PointerDownEvent event) => _beginImageMoveFromHandle(line),
        onMove: (PointerMoveEvent event) => _dragImageMove(event.position),
        onMoveUp: (PointerUpEvent event) => _finishImageMove(event.position),
        onMoveCancel: _cancelImageMove,
        onExit: (PointerExitEvent event) {
          // 按钮是压在编辑器之上的兄弟：指针从这里回到图上时，编辑器那边
          // 的悬停会接手；真走了才收。
          if (_imageLineAt(event.position) != null) return;
          _setHoverImage(null);
        },
      ),
    );
  }

  /// Ctrl+V: read the clipboard and insert it through [pasteValue], so the
  /// table padding rule reaches the keyboard exactly as it reaches the menu.
  ///
  /// Text comes first: a clipboard holding both text and a bitmap still pastes
  /// the text. Only an empty text clipboard falls through to the image, which
  /// is how pasting a screenshot works at all.
  Future<void> _pasteFromClipboard() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String? text = data?.text;
    if (text == null || text.isEmpty) {
      await _pasteImageFromClipboard();
      return;
    }
    final String? refusal = pasteGridRefusal(text);
    if (refusal != null) {
      if (mounted) {
        showSplitNotice(context, refusal, kind: NoticeKind.error);
      }
      return;
    }
    final TextEditingValue next = pasteValue(
      widget.controller.value,
      text,
      resolve: _resolveRange,
    );
    widget.controller.value = next;
    widget.onChanged?.call(next.text);
  }

  /// Whether an image cannot be inserted at [value]'s caret.
  ///
  /// A table row and a fenced code block are both source structures where a
  /// bare image line would not merely look wrong — it would break the block
  /// apart. The caret decides, exactly as it does for every marker reveal.
  bool _imagePasteRefused(TextEditingValue value) {
    final TextSelection selection = value.selection;
    final int caret = (selection.isValid ? selection.start : value.text.length)
        .clamp(0, value.text.length);
    if (isInsideFence(value.text, caret)) return true;
    final String line = value.text.substring(
      lineStartOf(value.text, caret),
      lineEndOf(value.text, caret),
    );
    return isTableLine(line);
  }

  /// 拖进来的东西：一张网页图片写成 `<img src="…">`，一条网页链接写成
  /// `[标题](地址)`，其它文字按纯文本落到落点。
  ///
  /// 图片先判（判定在 [parseDroppedImage] 里）：拖一张图时浏览器同时给了图片
  /// 地址和一条 URL，先问链接的话，一张图会变成正文里一行 `[图](地址)`。
  /// 链接次之（[parseDroppedLink]），认不出链接才落到文字——拖一段网页上选中
  /// 的文字过来，里面顺手带了个网址，那也是这段文字的一部分。文字走
  /// [pasteValue]，和 Ctrl+V 是同一条路：表格里粘表格的规矩、单元格里换行变
  /// `<br>`，拖进来也一模一样。
  Future<void> _onDrop(PerformDropEvent event) async {
    if (widget.readOnly) return;
    final ({DroppedImage? image, DroppedLink? link, String? text})? dropped =
        await _readDropped(event);
    if (dropped == null || !mounted) return;
    final RenderLineEditable? field = _editable();
    final TextEditingValue current = widget.controller.value;
    final int raw = field == null
        ? widget.controller.selection.start
        : field.positionAt(event.position.global).offset;
    final int at = (raw < 0 ? current.text.length : raw).clamp(
      0,
      current.text.length,
    );
    // 拖放自成一步：不能让 Ctrl+Z 把刚才打的字一起撤掉。
    _history.breakMerge();

    final DroppedImage? image = dropped.image;
    if (image != null) {
      // 落点是拖放的位置，不是当前光标：拒绝与否按落点判。
      final TextEditingValue probe = current.copyWith(
        selection: TextSelection.collapsed(offset: at),
      );
      if (_imagePasteRefused(probe)) {
        showSplitNotice(context, '表格或代码块里不能插入图片', kind: NoticeKind.error);
        return;
      }
      final String imageLine = markdownImageFor(image);
      _applyEdit((TextEditingValue v) {
        final ({String text, int caret}) inserted = insertImageBlock(
          text: v.text,
          at: at.clamp(0, v.text.length),
          end: at.clamp(0, v.text.length),
          imageLine: imageLine,
        );
        return TextEditingValue(
          text: inserted.text,
          selection: TextSelection.collapsed(offset: inserted.caret),
        );
      });
      return;
    }

    final DroppedLink? link = dropped.link;
    if (link != null) {
      final String markdown = markdownLinkFor(link);
      _applyEdit((TextEditingValue v) => insertDroppedLink(v, at, markdown));
      return;
    }

    final String text = dropped.text!;
    final String? refusal = pasteGridRefusal(text);
    if (refusal != null) {
      if (mounted) showSplitNotice(context, refusal, kind: NoticeKind.error);
      return;
    }
    // 落点是拖放的位置，不是当前光标；先把它当成一次「在这里粘贴」。
    _applyEdit(
      (TextEditingValue v) => pasteValue(
        v.copyWith(
          selection: TextSelection.collapsed(
            offset: at.clamp(0, v.text.length),
          ),
        ),
        text,
      ),
    );
  }

  /// 读一次拖放的载荷，决定它是图片、链接还是文字；三样都读不出时返回 `null`。
  ///
  /// 四种载荷都要试：系统 URL（浏览器最准的那份）、浏览器附带的
  /// `<a href=…>标题</a>` 或 `<img src=…>`（标题与图片地址从这里来）、纯文本。
  /// 某个格式不支持时读出来就是 `null`，缺一项不影响其余几项。文件拖放
  /// （`file://`）不当作文字。
  ///
  /// **图片先判**：拖一张图时浏览器同时给了图片地址和一条 `text/uri-list`，
  /// 先问链接的话，一张图会变成一行 `[图](地址)`——图片没进去，正文多一条链接。
  Future<({DroppedImage? image, DroppedLink? link, String? text})?>
  _readDropped(PerformDropEvent event) async {
    for (final DropItem item in event.session.items) {
      // `DataReader` 只在 super_clipboard 里导出，这里按推断拿，不为了一个
      // 类型名多引一整个包。
      final reader = item.dataReader;
      if (reader == null) continue;

      // 拖放期间不能 await 平台通道，所以读取是回调式的（`getValue`）；
      // 包一层 Completer，调用处才好按顺序读三种格式。
      Future<T?> read<T extends Object>(ValueFormat<T> format) {
        if (!reader.canProvide(format)) return Future<T?>.value();
        final Completer<T?> done = Completer<T?>();
        reader.getValue<T>(
          format,
          (T? value) {
            if (!done.isCompleted) done.complete(value);
          },
          onError: (Object error) {
            if (!done.isCompleted) done.complete(null);
          },
        );
        return done.future;
      }

      final bool file = reader.canProvide(Formats.fileUri);
      final NamedUri? uri = await read<NamedUri>(Formats.uri);
      final String? html = await read<String>(Formats.htmlText);
      final String? text = await read<String>(Formats.plainText);
      final DroppedImage? image = parseDroppedImage(
        uri: uri?.uri.toString(),
        html: html,
        plainText: text,
      );
      // 拖进来认错时，这里能直接看到浏览器到底给了什么（仅 debug 构建）。
      // HTML 先还原成能读的样子再打：原始载荷是「UTF-8 被当 UTF-16 解」的
      // 满屏乱码，打出来只会吓人，正文其实是对的。
      assert(() {
        debugPrint(
          'NRS drop: file=$file uri=$uri\n'
          'NRS drop: image=$image\n'
          'NRS drop: html=${describeDroppedHtml(html ?? '')}\n'
          'NRS drop: text=${clipForLog(text ?? '')}',
        );
        return true;
      }());
      if (image != null) return (image: image, link: null, text: null);
      final DroppedLink? link = parseDroppedLink(
        uri: uri?.uri.toString(),
        name: uri?.name,
        html: html,
        plainText: text,
      );
      if (link != null) return (image: null, link: link, text: null);
      final String? plain = parseDroppedText(
        html: html,
        plainText: text,
        file: file,
      );
      if (plain != null) return (image: null, link: null, text: plain);
    }
    return null;
  }

  /// Saves the clipboard's bitmap into the note's `assets/` and inserts its
  /// reference as a paragraph of its own. Returns whether anything was written.
  ///
  /// Runs after the text paste has found nothing. Silence is deliberate for the
  /// common "plain text clipboard, nothing to paste" case: the image channel is
  /// tried on every such Ctrl+V, and a notice there would fire constantly.
  Future<bool> _pasteImageFromClipboard() async {
    final Future<String?> Function(Uint8List)? save = widget.savePastedImage;
    if (widget.readOnly || save == null) return false;

    if (_imagePasteRefused(widget.controller.value)) {
      if (mounted) {
        showSplitNotice(
          context,
          '表格或代码块里不能粘贴图片',
          kind: NoticeKind.error,
        );
      }
      return false;
    }

    // Switching notes while the clipboard and the disk are being read would
    // otherwise drop the image into the note that happens to be open next.
    final String documentId = widget.documentId ?? '';
    final Uint8List? png = await ClipboardImage.readPng();
    if (png == null || !mounted || widget.documentId != documentId) {
      return false;
    }

    // The caret may have moved into a table or a fence while we waited.
    if (_imagePasteRefused(widget.controller.value)) {
      showSplitNotice(
        context,
        '表格或代码块里不能粘贴图片',
        kind: NoticeKind.error,
      );
      return false;
    }

    String? relative;
    try {
      relative = await save(png);
    } catch (_) {
      if (mounted) {
        showSplitNotice(context, '图片保存失败', kind: NoticeKind.error);
      }
      return false;
    }
    if (!mounted || widget.documentId != documentId) return false;
    if (relative == null) {
      showSplitNotice(context, '当前存储不支持保存图片', kind: NoticeKind.error);
      return false;
    }

    // 用 `<img …>` 写：这一行一旦被拖过宽度就会变成标签，插入时写另一种
    // 语法会让同一张图在同一份文件里长成两副样子。没拖过就不写宽度，图仍然
    // 按正文列自适应。
    final String imageLine = ImageMarkup(
      source: relative,
      alt: '图片',
    ).toMarkdown(asTag: true);
    // A paste is a step of its own: the image must not be folded into the
    // typing block that happened to precede it, or one Ctrl+Z erases both.
    _history.breakMerge();
    _applyEdit((TextEditingValue current) {
      final TextSelection selection = current.selection;
      final int at = (selection.isValid ? selection.start : current.text.length)
          .clamp(0, current.text.length);
      final int end = (selection.isValid ? selection.end : current.text.length)
          .clamp(at, current.text.length);
      final ({String text, int caret}) inserted = insertImageBlock(
        text: current.text,
        at: at,
        end: end,
        imageLine: imageLine,
      );
      return TextEditingValue(
        text: inserted.text,
        selection: TextSelection.collapsed(offset: inserted.caret),
      );
    });
    return true;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleOverlayRefresh);
    widget.controller.removeListener(_onFoldsChanged);
    widget.scrollController.removeListener(_scheduleOverlayRefresh);
    widget.scrollController.removeListener(_reportTopLine);
    widget.onLineTopProbe?.call(null);
    widget.onJumpSettled?.call(null);
    // 放大层挂在根 Overlay 上，不随这棵子树一起拆：编辑器被换掉时得自己收。
    _viewImageEntry?.remove();
    _viewImageEntry = null;
    _cellText?.dispose();
    _cellFocus?.dispose();
    _imageText?.dispose();
    _imageFocus?.dispose();
    _layoutPool.dispose();
    _imageBlocks?.dispose();
    _imageBlocks = null;
    // The click guard deliberately outlives the pointer — the platform's word
    // selection lands a moment *after* the button comes up — but it must not
    // outlive the editor.
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController) c.disarmClickGuard();
    if (tablePointerPosition.value != null) tablePointerPosition.value = null;
    tableResizePreview.value = null;
    widget.controller.removeListener(_recordHistory);
    super.dispose();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final AppPalette themed = context.palette;
    // 切换配色时 `MaterialApp` 会逐帧补间 `ThemeData`，`ThemeData.lerp` 连
    // `AppPalette` 一起补间；而按行排版把配色算进语义键（`LiveLineStyle`），
    // 跟着逐帧的配色走等于在 180ms 里把整篇正文重排十几遍——切换主题的卡顿
    // 就来自这里。正文取设置里已经落定的目标配色，只换一次布局；外壳的补间
    // 不受影响。没有设置控制器时（组件测试直接挂编辑器）照旧用主题里的配色。
    final SettingsController? settings = Provider.of<SettingsController?>(
      context,
      listen: false,
    );
    final AppPalette p = settings?.paletteFor(themed.brightness) ?? themed;
    _palette = p;
    final TextStyle style = editorProseStyle(p, widget.fontSize);
    // 按行排版：每行按源码种类取样式与行高，列表标记由渲染层画。
    final LiveLineStyle lineStyle = _resolveLineStyle(style, p);
    final LiveTableBlocks tableBlocks = _resolveTableBlocks(style, p);
    final LiveImageBlocks imageBlocks = _resolveImageBlocks(p);
    final _LineBlockResolver lineBlocks = _resolveLineBlocks(
      tableBlocks,
      imageBlocks,
    );
    // The field's own region is deeper than the editor's, so its cursor wins
    // wherever it covers the chrome — which is why a column grip used to show
    // the I-beam. Hand it the editor's cursor explicitly.
    final MouseCursor fieldCursor = _pointerCursor;

    final Map<ShortcutActivator, Intent>
    editorShortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.tab): const _IndentIntent(false),
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
    };

    final Map<Type, Action<Intent>> editorActions = <Type, Action<Intent>>{
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
          final String out = range?.markdown ?? v.selection.textInside(v.text);
          unawaited(Clipboard.setData(ClipboardData(text: out)));
          final TextEditingValue value;
          if (range != null) {
            value = tableRangeClear(range);
          } else {
            final int start = v.selection.start.clamp(0, v.text.length);
            final String next =
                v.selection.textBefore(v.text) + v.selection.textAfter(v.text);
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
          final TextEditingValue? target = intent.undo
              ? _history.undo()
              : _history.redo();
          if (target == null) return null;
          final String beforeText = widget.controller.text;
          _history.beginApply();
          _navigatingHistory = true;
          try {
            final LineEditableTextState? field = _editableTextState();
            if (field != null) {
              field.userUpdateTextEditingValue(
                target,
                SelectionChangedCause.keyboard,
              );
            } else {
              widget.controller.value = target;
            }
          } finally {
            _navigatingHistory = false;
            _history.endApply(widget.controller.value);
          }
          if (beforeText != target.text) {
            widget.controller.selection = TextSelection.collapsed(
              offset: _historyCaretOffset(beforeText, target.text),
            );
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
              tableSelectionTsv(v.text, v.selection, resolve: _resolveRange) ??
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
    };

    // The `Listener` wraps the whole scroll view, not the field, and it is
    // **opaque**: a table's grips and plus buttons hang *outside* the
    // field's box (left of the table, above it, below its last line), and a
    // `deferToChild` listener only hears about pointers that hit the field
    // itself. That is why a click on the grip did nothing at first.
    final Widget editor = MouseRegion(
      cursor: _pointerCursor,
      onHover: _onPointerHover,
      onExit: _onPointerExit,
      child: Listener(
        key: _fieldKey,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        onPointerSignal: _onPointerSignal,
        child: _ChromeShield(
          // 图片本体也算「自绘控件」：字段不知道那儿画着一张图，放它过去就会
          // 把光标落进图片行——那行字是看不见的，光标落进去等于凭空消失。
          blocks: (Offset position) =>
              !_overHeader(position) &&
              (_chromeAt(position) != null ||
                  _foldButtonAt(position, visibleOnly: true) != null ||
                  _imageHandleAt(position) != null ||
                  _imageLineAt(position) != null),
          child: SingleChildScrollView(
            controller: widget.scrollController,
            padding: widget.padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Inside the scroll view so it leaves with the text, but
                // outside both shortcut maps — Ctrl+Z with the title
                // focused must undo the title, not the body.
                if (widget.header != null)
                  KeyedSubtree(key: _headerKey, child: widget.header!),
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: widget.maxWidth),
                    child: Shortcuts(
                      shortcuts: widget.shortcuts,
                      child: Actions(
                        actions: widget.actions,
                        child: Shortcuts(
                          shortcuts: editorShortcuts,
                          child: Actions(
                            actions: editorActions,
                            child: Focus(
                              // Not a tab stop — just a listener this close to the
                              // field, so table caret keys are decided before the
                              // platform's line movement (and before Shortcuts).
                              canRequestFocus: false,
                              skipTraversal: true,
                              onKeyEvent: _onTableKey,
                              child: KeyedSubtree(
                                // 文档一变，整块输入框重建：撤销栈随之清空。
                                key: ValueKey<String?>(
                                  'doc-${widget.documentId}',
                                ),
                                child: LineEditableText(
                                  key: const Key('nrs-editor-field'),
                                  controller: widget.controller,
                                  focusNode: widget.focusNode,
                                  readOnly: widget.readOnly,
                                  onChanged: widget.onChanged,
                                  maxLines: null,
                                  expands: false,
                                  autofocus: false,
                                  mouseCursor: fieldCursor,
                                  cursorColor: p.accent,
                                  backgroundCursorColor: p.accent,
                                  // 正文洗色由 `EditorSelectionPainter` 画（行间留缝），
                                  // 字段自己不画。⛔ 不能靠外层 `DefaultSelectionStyle`
                                  // 关闭：标题框也在这棵子树里，会被一起透明掉。
                                  selectionColor: Colors.transparent,
                                  cursorWidth: 1.8,
                                  cursorRadius: const Radius.circular(1),
                                  keyboardType: TextInputType.multiline,
                                  textInputAction: TextInputAction.newline,
                                  inputFormatters: <TextInputFormatter>[
                                    ListContinuationFormatter(),
                                    // 行数一变就把有序列表的序号接上：删掉 16 那一条，
                                    // 下面的 17 变回 16；回车插进去的条目也会让后面的
                                    // 序号依次后移。
                                    OrderedListRenumberFormatter(
                                      suspend: () => _navigatingHistory,
                                    ),
                                    // Last, so it sees the text every other formatter has
                                    // already agreed on: a Backspace must never leave the
                                    // cell the caret is in.
                                    TableCellBarrierFormatter(
                                      suspend: () => _navigatingHistory,
                                      resolve: _resolveRange,
                                    ),
                                  ],
                                  style: style,
                                  // 选区盒子的形状不再由这两个参数决定：
                                  // `RenderLineEditable.getBoxesForSelection` 直接转发按行
                                  // 引擎的 `selectionBands`（横向贴字形、纵向铺满视觉行），
                                  // 传进来的 `BoxWidthStyle` / `BoxHeightStyle` 会被忽略。
                                  // 字段的底色是透明的（见上面的 `selectionColor`），
                                  // 洗色由 `EditorSelectionPainter` 自己画。
                                  //
                                  // 行高由按行引擎给（见 `lineHeightFor`）；这个 strut 只
                                  // 留给继承来的那套单段排版做几何兜底，压到 1px 才不会被
                                  // 正文字号撑成所有行共用的最小行高。
                                  strutStyle: const StrutStyle(
                                    fontSize: 1,
                                    height: 1,
                                    leading: 0,
                                  ),
                                  // 按行排版：每行按源码种类取样式、行高与 span 树。
                                  // `lineLayoutKey` 是解析器的语义键（不含源码）：
                                  // 每敲一个字都会重建 `LiveLineStyle`，渲染层靠这个
                                  // 键认出「未被编辑的行排版仍然有效」，走编辑增量
                                  // 而不是整篇重排。
                                  lineLayoutKey: lineStyle.styleKey,
                                  // 跨笔记复用：切走的布局挂进池，切回来直接采用。
                                  layoutPool: _layoutPool,
                                  layoutCacheDocument: widget.documentId,
                                  lineStyleFor: lineStyle.styleFor,
                                  lineHeightFor: lineStyle.heightFor,
                                  lineSpanFor: lineStyle.spanFor,
                                  // 行内代码的圆角底片：一行一个 `TextPainter` 没有
                                  // widget 端帽，铺底由渲染层按这份区间自己画。
                                  lineFillFor: lineStyle.fillsFor,
                                  // 代码块卡片的内边距：卡片铺满正文列，代码行由引擎
                                  // 左右各退 16px，不必再把卡片画到列外。
                                  lineInsetFor: lineStyle.insetFor,
                                  // 表格与整行图片不是一行文字：行高、绘制、命中
                                  // 都由对应的块自己回答，引擎只负责 y 定位。
                                  lineBlockFor: lineBlocks.blockFor,
                                  // 选区变了要重排（`# `、`**` 的显隐会改行宽）；拖动期间
                                  // 冻结在按下时的那一份。
                                  revealSelection: _revealSelection,
                                  // 点开的这一行把标记摊进正文，其余行仍然由渲染层把
                                  // 圆点 / 序号 / 复选框画在左侧槽位里。
                                  markerRevealLine: _markerReveal?.start,
                                  // 收起的列表项：子树压成零高，箭头由编辑器叠的
                                  // `ListFoldPainter` 画在字段外面（顶级项在页边距）。
                                  foldedLines: _foldedListStarts,
                                  // 列表标记（圆点 / 序号 / 复选框 / 导轨）由渲染层
                                  // 画在正文左侧的槽位里，源码里的 `- ` 不再上屏。
                                  markerStyle: lineStyle.markers,
                                  searchHighlight: widget.searchHighlight,
                                  searchHighlightColor:
                                      widget.searchHighlightColor,
                                  // 交给继承来的单段排版（`super.performLayout` 与
                                  // `getWordBoundary` 都读它）的仍是纯源码：装饰树里的
                                  // U+FFFC 会让那些按整段算的方法错位。行内样式只走
                                  // `lineSpanFor`，两者互不影响。
                                  plainTextSpan: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
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
    final _ImageEdit? imageEdit = _imageEdit;
    final TextEditingController? imageText = _imageText;
    final FocusNode? imageFocus = _imageFocus;
    final Widget? imageActions = _imageActions(p);
    return Stack(
      children: <Widget>[
        // A fenced block is one rounded slab, painted here because a
        // `TextStyle` background can only cover the run it belongs to — which
        // is what turned a block into a stripe per line. Under the wash, so a
        // selection still reads over the code.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: CodeBlockPainter(
                controller: widget.controller,
                scrollController: widget.scrollController,
                editable: _editable,
                editorBox: () {
                  final RenderObject? root = context.findRenderObject();
                  return root is RenderBox && root.hasSize ? root : null;
                },
                fill: codeSlabFill(p),
                labelStyle: TextStyle(
                  fontFamily: AppFonts.ui,
                  fontFamilyFallback: AppFonts.uiFallback,
                  fontSize: AppText.caption,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.2,
                  color: p.textSecondary,
                ),
                // The label goes away while the block shows its source; the
                // renderer freezes the reveal for a drag, so ask for the same
                // selection it paints with.
                selection: _revealSelection,
              ),
            ),
          ),
        ),
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
        // 拖一条网页链接进来 → 在落点写成 `[标题](地址)`。只收链接的三种
        // 载荷（系统 URL、浏览器附带的 HTML 片段、纯文本），文件与图片不
        // 在这里认领——它们有自己的粘贴/落图路径。
        //
        // 测试进程里没有原生拖放层（区域一建起来就抛 `MissingPluginException`，
        // 且是异步抛出的），所以那边挂的就是普通编辑器。
        Positioned.fill(
          child: systemDragAndDropAvailable
              ? DropRegion(
                  formats: const <DataFormat>[
                    Formats.uri,
                    Formats.htmlText,
                    Formats.plainText,
                  ],
                  hitTestBehavior: HitTestBehavior.translucent,
                  onDropOver: (DropOverEvent event) => DropOperation.copy,
                  onPerformDrop: _onDrop,
                  child: editor,
                )
              : editor,
        ),
        // 折叠箭头在字段的裁剪之外（顶级列表项的按钮落在页边距里），所以
        // 由编辑器这层画。几何按当前排版现取，滚动时跟着走。
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: ListFoldPainter(
                controller: widget.controller,
                scrollController: widget.scrollController,
                editorBox: () {
                  final RenderObject? root = context.findRenderObject();
                  return root is RenderBox && root.hasSize ? root : null;
                },
                handles: () =>
                    _editable()?.foldHandles() ?? const <ListFoldHandle>[],
                hoveredLine: _hoverFoldLine,
                hoveredButton: _hoverFoldButton,
                iconColor: p.textTertiary,
                hoverIconColor: p.accent,
                hoverFill: p.accentSoft,
                ellipsisStyle: style.copyWith(color: p.textTertiary),
                textScaler: MediaQuery.textScalerOf(context),
              ),
            ),
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
        // 图片右上角的「查看大图」+「编辑这个区块」：悬停出现，选中后固定。
        ?imageActions,
        // 拖动图片时的插入线：落点只能是行与行之间。
        if (_imageMove?.dropLine != null)
          Positioned.fromRect(
            rect: _imageMove!.dropLine!,
            child: IgnorePointer(child: _ImageDropLine(palette: p)),
          ),
        // 拖动图片时的落位预览：贴边浮动时它就是图片真会占的那一块。
        if (_imageMove?.ghost != null)
          Positioned.fromRect(
            rect: _imageMove!.ghost!,
            child: IgnorePointer(
              child: _ImageDropGhost(
                palette: p,
                floating: _imageMove!.align != null,
              ),
            ),
          ),
        if (imageEdit != null && imageText != null && imageFocus != null) ...<Widget>[
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _commitImageEditor,
            ),
          ),
          Positioned.fromRect(
            rect: imageEdit.panel,
            child: _ImageSourceLine(
              palette: p,
              style: style,
              controller: imageText,
              focusNode: imageFocus,
              onCommit: _commitImageEditor,
              onCancel: _cancelImageEditor,
            ),
          ),
        ],
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
/// Small on purpose: the marker slot is already 26px wide, and a generous slop
/// would start swallowing clicks on the text beside it.
const double _kCheckboxTouchSlop = 4;

/// One open image source editor: which line, and where the panel sits.
class _ImageEdit {
  _ImageEdit({required this.lineStart, required this.panel});

  final int lineStart;

  /// 源码行占的那块矩形，编辑器坐标。滚动会重算——块自己已经让出了这一行，
  /// 这里只是把它报出来的位置换算过来。
  Rect panel;
}

/// 一次「把整张图搬到别处」的拖动。
///
/// 图片行是一整块，能挪的只有整行：落点吸附到行与行之间，松手时整行搬过去。
/// 落点还决定**贴哪一边**——拖到正文左侧三分之一就贴左、右侧三分之一就贴右，
/// 中间则是独占一行。贴边之后后面几行正文会在另一侧绕排，这就是「左文字右
/// 图片」的来源。
/// 一次「把图片搬到别处」的拖动。
///
/// 只能从右上角的移动按钮发起（见 `_beginImageMoveFromHandle`）。点图片本体
/// 只选中，不建这个对象——图片是正文里最大的一块，随手一拖就把它挪走，比
/// 「拖不动」难受得多。
class _ImageMove {
  _ImageMove({required this.lineStart});

  /// 被搬的那一行（行首偏移）。
  final int lineStart;

  /// 落点：文档偏移，一定是某一行的行首。`null` 表示落在自己身上（不搬）。
  int? target;

  /// 插入线在编辑器坐标里的矩形；`null` 时不画。
  Rect? dropLine;

  /// 落点要写成哪种对齐；`null` 表示独占一行。
  ImageAlign? align;

  /// 预览框在编辑器坐标里的矩形：松手之后图片大概会占这一块。
  Rect? ghost;

  /// 被搬的那张图画出来多大，预览框按它算。
  Size size = Size.zero;
}

/// 拖动图片时那条插入线。
///
/// 只画一条实心细线，不做箭头、不做虚框：它要回答的只有一件事——「松手之后
/// 这张图会插在哪两行之间」。
class _ImageDropLine extends StatelessWidget {
  const _ImageDropLine({required this.palette});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: palette.accent,
      borderRadius: BorderRadius.circular(1),
    ),
  );
}

/// 拖动图片时那个落位预览框。
///
/// 不画真图（那要再走一遍解码与自绘），只画一块半透明底色加一圈强调色边框：
/// 它要回答的是「松手之后这块地方归它」，不是「它长什么样」——图片本身就在
/// 原地，眼睛一直在看着它。
class _ImageDropGhost extends StatelessWidget {
  const _ImageDropGhost({required this.palette, required this.floating});

  final AppPalette palette;

  /// 贴边浮动：框是图片的宽度；独占一行时框铺满整栏。
  final bool floating;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: palette.accent.withValues(alpha: floating ? 0.10 : 0.06),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(
        color: palette.accent.withValues(alpha: 0.75),
        width: 1.5,
      ),
    ),
  );
}

/// 图片右上角那排按钮的尺寸。写死是为了让位置能先算出来再摆——量完再挪会
/// 看见它跳一下。
///
/// 只有图标：按钮压在图片上，字越多挡掉的画面越多，名字交给 Tooltip。
const double _kImageActionButtonWidth = 28;
const double _kImageActionsGap = 6;

/// 只读时只有「查看大图」。
const double _kImageActionsWidth = _kImageActionButtonWidth;

/// 可编辑时是「查看大图」「移动」「编辑这个区块」三颗。
const double _kImageActionsEditWidth =
    _kImageActionButtonWidth * 3 + _kImageActionsGap * 2;
const double _kImageActionsHeight = 24;

/// 图片右上角那排按钮：「查看大图」「移动」「编辑这个区块」。
///
/// 它悬在图片上，所以底色要压得住图片：浅色底 + 一圈描边，不用半透明——半透明
/// 压在一张白底截图上等于没有。
class _ImageActions extends StatelessWidget {
  const _ImageActions({
    required this.palette,
    required this.canEdit,
    required this.onView,
    required this.onEdit,
    required this.onMoveDown,
    required this.onMove,
    required this.onMoveUp,
    required this.onMoveCancel,
    required this.onExit,
  });

  final AppPalette palette;

  /// 只读时只剩「查看大图」：看图不是编辑。
  final bool canEdit;
  final VoidCallback onView;
  final VoidCallback onEdit;

  /// 「移动」是一颗能拖的按钮：按下就开始搬，不必等指针走出阈值。
  final void Function(PointerDownEvent event) onMoveDown;
  final void Function(PointerMoveEvent event) onMove;
  final void Function(PointerUpEvent event) onMoveUp;
  final VoidCallback onMoveCancel;

  final void Function(PointerExitEvent event) onExit;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onExit: onExit,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: _kImageActionButtonWidth,
            child: _ImageActionButton(
              palette: palette,
              icon: LucideIcons.maximize2,
              tip: '查看大图',
              onTap: onView,
            ),
          ),
          if (canEdit) ...<Widget>[
            const SizedBox(width: _kImageActionsGap),
            SizedBox(
              width: _kImageActionButtonWidth,
              child: _ImageDragButton(
                palette: palette,
                onDown: onMoveDown,
                onMove: onMove,
                onUp: onMoveUp,
                onCancel: onMoveCancel,
              ),
            ),
            const SizedBox(width: _kImageActionsGap),
            SizedBox(
              width: _kImageActionButtonWidth,
              child: _ImageActionButton(
                palette: palette,
                icon: LucideIcons.squarePen,
                tip: '编辑这个区块',
                onTap: onEdit,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 「移动」那颗按钮：长得和别的按钮一样，但它不是点击，是拖。
///
/// 用 [Listener] 而不是 `GestureDetector`：拖动要跨过整个正文，落点由编辑器
/// 按指针位置算；走手势竞技场的话，字段自己的选区拖动会来抢这一下。
class _ImageDragButton extends StatefulWidget {
  const _ImageDragButton({
    required this.palette,
    required this.onDown,
    required this.onMove,
    required this.onUp,
    required this.onCancel,
  });

  final AppPalette palette;
  final void Function(PointerDownEvent event) onDown;
  final void Function(PointerMoveEvent event) onMove;
  final void Function(PointerUpEvent event) onUp;
  final VoidCallback onCancel;

  @override
  State<_ImageDragButton> createState() => _ImageDragButtonState();
}

class _ImageDragButtonState extends State<_ImageDragButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = widget.palette;
    final Color ink = _hovered ? p.accent : p.textSecondary;
    return Tooltip(
      message: '移动',
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: widget.onDown,
          onPointerMove: widget.onMove,
          onPointerUp: widget.onUp,
          onPointerCancel: (_) => widget.onCancel(),
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: _kImageActionsHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? p.accentSoft : p.surfaceRaised,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _hovered ? p.accent.withValues(alpha: 0.45) : p.outline,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: p.shadow,
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(LucideIcons.move, size: 13, color: ink),
          ),
        ),
      ),
    );
  }
}

/// 图片源码行的控制器：把那一行按 HTML 词法着色。
///
/// 这一行是 `<img src="…" width="677" alt="图片">`，不是散文，也不是链接。
/// 整行染成一个颜色（链接色）会让人以为点它能跳转；这里按标签名 / 属性名 /
/// 属性值 / 标点分色，和代码编辑器里看到的一样。
///
/// 着色只发生在**渲染**这一层：`text` 仍然是那一行原文，写回文档、撤销、
/// 光标偏移全都不受影响。
class _HtmlSourceController extends TextEditingController {
  _HtmlSourceController({super.text, required this.palette});

  final AppPalette palette;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 输入法正在拼字：交给默认实现。组合区间的下划线、`composing` 的范围
    // 都不该由这里代劳，拼字期间颜色统一退回正文色也正好。
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return htmlSourceSpan(text, style ?? const TextStyle(), palette);
  }
}

/// 图片上方那一行源码。
///
/// 刻意长得不像面板：没有底色、没有圆角卡片、没有标题栏和快捷键提示，字体就是
/// 正文那一套。用户点「编辑这个区块」是**回到那一行**去改字，不是打开一个对话框
/// ——弹窗会把图和它自己的源码隔成两件事。
class _ImageSourceLine extends StatelessWidget {
  const _ImageSourceLine({
    required this.palette,
    required this.style,
    required this.controller,
    required this.focusNode,
    required this.onCommit,
    required this.onCancel,
  });

  final AppPalette palette;

  /// 正文的排版样式：源码行和上下文字号一致，换行宽度才对得上。
  final TextStyle style;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onCommit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = palette;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onCancel,
        const SingleActivator(LogicalKeyboardKey.enter): onCommit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onCommit,
      },
      child: Container(
        // 一块**浮在图片上**的小窗：不占布局，图片一个像素都不动。
        // 底色必须压得住图片（浅色底 + 一圈描边 + 一层阴影），半透明等于没有。
        decoration: BoxDecoration(
          color: p.surfaceRaised,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: p.outline),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: p.shadow,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
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
          // 底色是正文色，具体每个词的颜色由 [_HtmlSourceController] 按 HTML
          // 词法给：这一行是标签，不是链接，也不是普通段落。
          style: style.copyWith(color: p.textPrimary),
          cursorColor: p.accent,
          cursorWidth: 1.6,
          // 主题里那套 InputDecorationTheme 会**盖过** `border: none`：它显式
          // 配了 `focusedBorder`，而解析顺序是 `focusedBorder ?? border`。所以
          // 焦点框必须逐个状态关掉，否则一进来就套着一个圆角紫框，看着又像
          // 弹窗了。`filled` 同理——不关掉会在纸色上再铺一层白。
          decoration: const InputDecoration(
            isDense: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}

/// 一颗只有图标的按钮。名字挂在 [Tooltip] 上——压在图片上的按钮不该写满字。
class _ImageActionButton extends StatefulWidget {
  const _ImageActionButton({
    required this.palette,
    required this.icon,
    required this.tip,
    required this.onTap,
  });

  final AppPalette palette;
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_ImageActionButton> createState() => _ImageActionButtonState();
}

class _ImageActionButtonState extends State<_ImageActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = widget.palette;
    final Color ink = _hovered ? p.accent : p.textSecondary;
    return Tooltip(
      message: widget.tip,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: _kImageActionsHeight,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? p.accentSoft : p.surfaceRaised,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _hovered ? p.accent.withValues(alpha: 0.45) : p.outline,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: p.shadow,
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(widget.icon, size: 13, color: ink),
          ),
        ),
      ),
    );
  }
}

/// One open floating cell editor.
class _CellEdit {  const _CellEdit({
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
