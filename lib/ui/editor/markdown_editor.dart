import 'dart:async';

import 'package:flutter/gestures.dart'
    show kDoubleTapTimeout, kSecondaryMouseButton, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/markdown_outline.dart';
import 'editor_context_menu.dart';
import 'live_markdown.dart';

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

  /// Opens the window in which a *range* selection is treated as a mis-read
  /// click and collapsed to [offset].
  ///
  /// Deliberately a little longer than [kDoubleTapTimeout]: the third click of
  /// a triple arrives inside the same window as the second.
  void armClickGuard(int offset) {
    _clickAnchor = offset;
    _clickGuard?.cancel();
    _clickGuard = Timer(const Duration(milliseconds: 400), () {
      _clickAnchor = null;
      _clickGuard = null;
    });
  }

  /// Lets ranges through again — as soon as the pointer travels far enough to
  /// be a drag, and whenever a new gesture starts.
  void disarmClickGuard() {
    _clickGuard?.cancel();
    _clickGuard = null;
    _clickAnchor = null;
  }

  @override
  set selection(TextSelection newSelection) {
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
    final String insert = '$indent$nextMarker ${checkbox.isEmpty ? '' : '[ ] '}';
    final String text = newValue.text.substring(0, at + 1) +
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
    final String text = newValue.text.substring(0, lineStart) +
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

/// The single source of truth for the editor's body typography.
///
/// The pane needs it too: mapping a source line onto a scroll offset means
/// measuring with the exact style the editor paints with.
TextStyle editorProseStyle(AppPalette p, double size) => TextStyle(
  fontFamily: AppFonts.prose,
  fontFamilyFallback: AppFonts.proseFallback,
  fontSize: size,
  // 1.78 of air, rounded to a line height the paragraph can step by exactly —
  // see [snapLineHeight]. Without it every row of a multi-line selection is
  // 0.41px shorter than the gap to the next one, and the highlight shows a
  // hairline of paper between the lines.
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
    final int offset = editable
        .getPositionForPoint(globalPosition)
        .offset
        .clamp(0, c.text.length);
    if (keepSelection) {
      final TextSelection sel = c.selection;
      if (sel.isValid && !sel.isCollapsed && offset >= sel.start && offset <= sel.end) {
        return;
      }
    }
    c.selection = TextSelection.collapsed(offset: offset);
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
    if (c.selection.isCollapsed) return;
    if (HardwareKeyboard.instance.isShiftPressed) return;
    final RenderEditable? editable = _editable();
    if (editable == null) return;
    final TextPosition at = editable.getPositionForPoint(globalPosition);
    c.selection = TextSelection.collapsed(
      offset: at.offset.clamp(0, c.text.length),
      affinity: at.affinity,
    );
  }

  /// Recorded on *down*: the field moves the caret on pointer-down, so reading
  /// the selection on up would already be too late.
  void _onPointerDown(PointerDownEvent event) {
    final bool secondary = event.buttons & kSecondaryMouseButton != 0;
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
    c.armClickGuard(
      editable
          .getPositionForPoint(event.position)
          .offset
          .clamp(0, c.text.length),
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
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

  @override
  void dispose() {
    // The click guard deliberately outlives the pointer — the platform's word
    // selection lands a moment *after* the button comes up — but it must not
    // outlive the editor.
    final TextEditingController c = widget.controller;
    if (c is MarkdownSourceController) c.disarmClickGuard();
    super.dispose();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final TextStyle style = editorProseStyle(p, widget.fontSize);

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.tab): const _IndentIntent(
          false,
        ),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true):
            const _IndentIntent(true),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _IndentIntent: CallbackAction<_IndentIntent>(
            onInvoke: (_IndentIntent intent) {
              final TextEditingValue next = indentLines(
                widget.controller.value,
                outdent: intent.outdent,
              );
              widget.controller.value = next;
              widget.onChanged?.call(next.text);
              return null;
            },
          ),
        },
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
                  return Listener(
                    key: _fieldKey,
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    child: TextField(
                      key: const Key('nrs-editor-field'),
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      readOnly: widget.readOnly,
                      onChanged: widget.onChanged,
                      maxLines: null,
                      expands: false,
                      autofocus: false,
                      cursorColor: p.accent,
                      cursorWidth: 1.8,
                      cursorRadius: const Radius.circular(1),
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      inputFormatters: <TextInputFormatter>[
                        ListContinuationFormatter(),
                      ],
                      style: style,
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
                      selectionControls: materialTextSelectionHandleControls,
                      contextMenuBuilder:
                          (BuildContext context, EditableTextState state) {
                            return buildEditorContextMenu(
                              state: state,
                              value: widget.controller.value,
                              onApply: _applyEdit,
                              onDismiss: state.hideToolbar,
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
    );
  }
}

/// How far around a checkbox still counts as hitting it (logical pixels).
///
/// Small on purpose: the padded shell is already 26px wide, and a generous slop
/// would start swallowing clicks on the text beside it.
const double _kCheckboxTouchSlop = 4;
