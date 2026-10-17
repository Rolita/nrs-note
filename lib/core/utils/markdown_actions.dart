import 'package:flutter/services.dart';

/// Pure functions that transform a [TextEditingValue].
///
/// Keeping every toolbar action as a value→value function means the toolbar,
/// the context menu and the keyboard shortcuts all share one implementation and
/// stay perfectly consistent.
typedef MarkdownEditFn = TextEditingValue Function(TextEditingValue);

TextEditingValue _normalised(TextEditingValue v) {
  final int start = v.selection.start < 0 ? v.text.length : v.selection.start;
  final int end = v.selection.end < 0 ? v.text.length : v.selection.end;
  return v.copyWith(
    selection: TextSelection(baseOffset: start.clamp(0, v.text.length), extentOffset: end.clamp(0, v.text.length)),
  );
}

bool _isWrapped(String text, int start, int end, String before, String after) {
  final int from = start - before.length;
  final int to = end + after.length;
  if (from < 0 || to > text.length) return false;
  return text.substring(from, start) == before &&
      text.substring(end, to) == after;
}

/// Wraps the selection in [before]/[after], or unwraps it when already wrapped.
MarkdownEditFn wrapSelection(
  String before,
  String after, {
  String placeholder = '文字',
}) {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    int start = v.selection.start;
    int end = v.selection.end;

    if (_isWrapped(text, start, end, before, after)) {
      final String inner = text.substring(start, end);
      final String next =
          text.substring(0, start - before.length) + inner + text.substring(end + after.length);
      final int offset = start - before.length;
      return TextEditingValue(
        text: next,
        selection: TextSelection(baseOffset: offset, extentOffset: offset + inner.length),
      );
    }

    // Nothing selected: grow to the word under the caret so double-click-less
    // formatting still feels instant.
    if (start == end) {
      final List<int> word = _wordBounds(text, start);
      start = word[0];
      end = word[1];
    }

    final String selected = text.substring(start, end);
    final String body = selected.isEmpty ? placeholder : selected;
    final String next = text.substring(0, start) + before + body + after + text.substring(end);
    final int bodyStart = start + before.length;
    return TextEditingValue(
      text: next,
      selection: TextSelection(baseOffset: bodyStart, extentOffset: bodyStart + body.length),
    );
  };
}

// ------------------------------------------------------------ block markers
//
// This section is the **single** source of truth for what block marker a line
// starts with. The toolbar actions, the status-bar label and the outline all
// read it instead of each carrying their own regular expression — three copies
// of the same judgement is how `# 标题` + "bullet list" ended up producing
// `- # 标题` (the old marker was never recognised, so it was never stripped).

/// The block marker a line starts with, as the live renderer sees it.
enum LineMarkerKind { paragraph, heading, bullet, ordered, quote, task, rule }

/// Where a line's block marker sits, and what it says.
class LineMarker {
  const LineMarker({
    this.kind = LineMarkerKind.paragraph,
    this.indent = 0,
    this.length = 0,
    this.level = 0,
    this.checked = false,
    this.number,
  });

  final LineMarkerKind kind;

  /// The indentation the user typed, in characters.
  ///
  /// Every action rebuilds a line as `indent + marker + rest`, so nesting
  /// survives a trip through the toolbar. Dropping it would flatten a nested
  /// list the moment you clicked "bullet list" to *un*-bullet it.
  final int indent;

  /// How many characters the marker itself occupies, *excluding* [indent].
  ///
  /// For [LineMarkerKind.rule] this is the rest of the line — a rule is the
  /// only marker where "marker" and "content" are the same thing.
  final int length;

  /// Heading level `1..6` when [kind] is [LineMarkerKind.heading].
  final int level;

  /// Whether the box is ticked when [kind] is [LineMarkerKind.task].
  final bool checked;

  /// The number of an ordered item, or of an **ordered task** (`6. [ ] 事`).
  final int? number;

  bool get isTask => kind == LineMarkerKind.task;

  /// The list-level marker of this line: `N. ` when ordered, `- ` otherwise.
  ///
  /// Used when *removing* a checkbox (`1. [ ] 项` → `1. 项`) and when *adding*
  /// one to a line that is already a list (`1. 项` → `1. [ ] 项`).
  String get listPrefix => number == null ? '- ' : '$number. ';
}

// These mirror `live_markdown.dart` character for character, and are applied in
// the same order it classifies a line: heading, task, ordered, rule, bullet,
// quote. A table row carries no marker, so it scans as a paragraph.
final RegExp _mHeading = RegExp(r'^(\s{0,3})(#{1,6})(\s+)(.*?)(\s+#+\s*)?$');
final RegExp _mTask = RegExp(
  r'^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[[ xX]\])(\s+)(.*)$',
);
final RegExp _mOrdered = RegExp(r'^(\s*)(\d{1,9})([.)])(\s+)(.*)$');
final RegExp _mRule = RegExp(r'^ {0,3}(?:[-*_]\s*){3,}$');
final RegExp _mBullet = RegExp(r'^(\s*)([-*+])(\s+)(.*)$');
final RegExp _mQuote = RegExp(r'^(\s{0,3})(>)(\s?)(.*)$');
final RegExp _mIndent = RegExp(r'^\s*');

/// The order of the list inside a leading `-` / `1.`, or `null` when unordered.
int? _leadNumber(String lead) {
  if (!lead.endsWith('.')) return null;
  return int.tryParse(lead.substring(0, lead.length - 1));
}

/// Reads the block marker off a single line. [line] must not contain `\n`.
///
/// The marker length is always computed from the *group lengths* rather than
/// `line.length - content.length`: `# a #` has a marker that is not contiguous
/// (`# ` … ` #`), and subtracting the content length there would slice the text
/// at the wrong place.
LineMarker scanLineMarker(String line) {
  final String indent = _mIndent.firstMatch(line)!.group(0)!;
  final int n = indent.length;
  if (n == line.length) return LineMarker(indent: n);

  final Match? h = _mHeading.firstMatch(line);
  if (h != null) {
    return LineMarker(
      kind: LineMarkerKind.heading,
      indent: h.group(1)!.length,
      length: h.group(2)!.length + h.group(3)!.length,
      level: h.group(2)!.length,
    );
  }
  final Match? t = _mTask.firstMatch(line);
  if (t != null) {
    final String lead = t.group(2)!;
    return LineMarker(
      kind: LineMarkerKind.task,
      indent: t.group(1)!.length,
      length:
          lead.length +
          t.group(3)!.length +
          t.group(4)!.length +
          t.group(5)!.length,
      checked: t.group(4)!.toLowerCase().contains('x'),
      number: _leadNumber(lead),
    );
  }
  final Match? o = _mOrdered.firstMatch(line);
  if (o != null) {
    return LineMarker(
      kind: LineMarkerKind.ordered,
      indent: o.group(1)!.length,
      length: o.group(2)!.length + o.group(3)!.length + o.group(4)!.length,
      number: int.tryParse(o.group(2)!),
    );
  }
  if (_mRule.hasMatch(line)) {
    return LineMarker(
      kind: LineMarkerKind.rule,
      indent: n,
      length: line.length - n,
    );
  }
  final Match? b = _mBullet.firstMatch(line);
  if (b != null) {
    return LineMarker(
      kind: LineMarkerKind.bullet,
      indent: b.group(1)!.length,
      length: b.group(2)!.length + b.group(3)!.length,
    );
  }
  final Match? q = _mQuote.firstMatch(line);
  if (q != null) {
    return LineMarker(
      kind: LineMarkerKind.quote,
      indent: q.group(1)!.length,
      length: q.group(2)!.length + q.group(3)!.length,
    );
  }
  return LineMarker(indent: n);
}

/// The marker of the line the caret is on — what the toolbar lights up.
LineMarker markerAt(TextEditingValue value) {
  final String text = value.text;
  final int caret = value.selection.start.clamp(0, text.length);
  return scanLineMarker(
    text.substring(lineStartOf(text, caret), lineEndOf(text, caret)),
  );
}

/// Which [BlockStyle] best describes [m], so a button can show itself as active.
///
/// A rule and a bare paragraph both map to [BlockStyle.paragraph]: neither has a
/// button to light up, and a rule is not something the toolbar can "set".
BlockStyle blockStyleOf(LineMarker m) => switch (m.kind) {
  LineMarkerKind.heading => switch (m.level) {
    1 => BlockStyle.h1,
    2 => BlockStyle.h2,
    3 => BlockStyle.h3,
    4 => BlockStyle.h4,
    5 => BlockStyle.h5,
    _ => BlockStyle.h6,
  },
  LineMarkerKind.bullet => BlockStyle.bullet,
  LineMarkerKind.ordered => BlockStyle.ordered,
  LineMarkerKind.quote => BlockStyle.quote,
  LineMarkerKind.task =>
    m.number == null ? BlockStyle.task : BlockStyle.orderedTask,
  LineMarkerKind.paragraph || LineMarkerKind.rule => BlockStyle.paragraph,
};

/// The block a toolbar button asks for.
enum BlockStyle {
  paragraph,
  h1,
  h2,
  h3,
  h4,
  h5,
  h6,
  bullet,
  ordered,
  quote,

  /// Unordered task list (`- [ ] 事`). Applied to a line that is *already* a
  /// list it keeps that list's marker: `1. 事` becomes `1. [ ] 事`, not
  /// `- [ ] 事`. Losing the number there is the bug this shares with the
  /// EPUB Reader's note panel.
  task,

  /// Ordered task list (`1. [ ] 事`) — the explicit way to ask for a numbered
  /// checkbox, whichever block the line is in today.
  orderedTask;

  /// `1..6` for the six heading styles, `null` for everything else.
  int? get headingLevel {
    if (index < h1.index || index > h6.index) return null;
    return index - h1.index + 1;
  }

  bool get isTask => this == BlockStyle.task || this == BlockStyle.orderedTask;
}

bool _already(LineMarker m, BlockStyle s) => switch (s) {
  BlockStyle.paragraph => m.kind == LineMarkerKind.paragraph,
  BlockStyle.h1 => m.kind == LineMarkerKind.heading && m.level == 1,
  BlockStyle.h2 => m.kind == LineMarkerKind.heading && m.level == 2,
  BlockStyle.h3 => m.kind == LineMarkerKind.heading && m.level == 3,
  BlockStyle.h4 => m.kind == LineMarkerKind.heading && m.level == 4,
  BlockStyle.h5 => m.kind == LineMarkerKind.heading && m.level == 5,
  BlockStyle.h6 => m.kind == LineMarkerKind.heading && m.level == 6,
  // A task line is *not* a bullet and *not* an ordered item: clicking "bullet
  // list" on `- [ ] 事` must drop the box (`- 事`), not toggle the line bare.
  BlockStyle.bullet => m.kind == LineMarkerKind.bullet,
  BlockStyle.ordered => m.kind == LineMarkerKind.ordered,
  BlockStyle.quote => m.kind == LineMarkerKind.quote,
  // Any checkbox counts as "already a task list", numbered or not: clicking the
  // button again takes the box off and leaves the list marker it found.
  BlockStyle.task => m.isTask,
  BlockStyle.orderedTask => m.isTask && m.number != null,
};

String _prefixFor(BlockStyle s, LineMarker m, int index) => switch (s) {
  BlockStyle.paragraph => '',
  BlockStyle.h1 => '# ',
  BlockStyle.h2 => '## ',
  BlockStyle.h3 => '### ',
  BlockStyle.h4 => '#### ',
  BlockStyle.h5 => '##### ',
  BlockStyle.h6 => '###### ',
  BlockStyle.bullet => '- ',
  // Numbering is taken from the *new* count, not the old one — selecting two
  // lines that start at `9.` has to produce `1.` `2.`, not `9.` `10.`.
  BlockStyle.ordered => '${index + 1}. ',
  BlockStyle.quote => '> ',
  BlockStyle.task => '${m.listPrefix}[ ] ',
  // "Ordered task list" is an *ordered* list, so it numbers like one — asking
  // for it explicitly means "renumber this from 1", the same as the ordered
  // list button. Only `task` inherits the number it finds.
  BlockStyle.orderedTask => '${index + 1}. [ ] ',
};

/// Sets (or, clicked twice, clears) the block style of every line the selection
/// touches.
///
/// * The old marker is stripped first, so styles replace each other instead of
///   stacking: `# 标题` + bullet list = `- 标题`.
/// * Blank lines are left alone, so a selection that spans a paragraph break
///   does not sprout an empty bullet.
/// * Markers are re-derived per line rather than replacing the whole line with a
///   fixed prefix, which is what keeps `1.` alive through a task conversion.
MarkdownEditFn applyBlockStyle(BlockStyle style) {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    final int first = lineStartOf(text, v.selection.start);
    final int last = lineEndOf(text, v.selection.end);
    // A fenced block is code, and a fence has no block markers to set: pushing
    // `- ` onto a line of Dart only puts the dashes inside the code, where the
    // renderer hides nothing, so the click would look dead while still editing
    // the text. Do nothing instead.
    if (isInsideFence(text, first)) return raw;
    final List<String> lines = text.substring(first, last).split('\n');
    final List<LineMarker> markers = <LineMarker>[
      for (final String l in lines) scanLineMarker(l),
    ];

    final List<int> live = <int>[
      for (int i = 0; i < lines.length; i++)
        if (lines[i].trim().isNotEmpty) i,
    ];
    if (live.isEmpty) return raw;

    final bool clearing = live.every((int i) => _already(markers[i], style));

    int seq = 0;
    final List<String> out = <String>[];
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      if (line.trim().isEmpty) {
        out.add(line);
        continue;
      }
      final LineMarker m = markers[i];
      final String prefix = clearing
          // Clearing a task removes the box but *keeps* the list marker:
          // `1. [ ] 事` goes back to `1. 事`, it does not go back to `事`.
          ? (style.isTask ? m.listPrefix : '')
          : _prefixFor(style, m, seq++);
      out.add(
        '${line.substring(0, m.indent)}$prefix'
        '${line.substring(m.indent + m.length)}',
      );
    }
    return _rebuild(v, first, last, out);
  };
}

/// Writes [lines] back over `[first, last)` and puts the selection back.
///
/// With a selection the whole rebuilt block stays selected (so you can stack
/// another style on it); with a bare caret it lands at the **end of the first
/// line**, because the next thing the user types has to land *after* the marker
/// — a caret at the line start would insert text in front of `## `.
TextEditingValue _rebuild(
  TextEditingValue v,
  int first,
  int last,
  List<String> lines,
) {
  final String block = lines.join('\n');
  final String next = v.text.replaceRange(first, last, block);
  if (v.selection.start != v.selection.end) {
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: first,
        extentOffset: (first + block.length).clamp(first, next.length),
      ),
    );
  }
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(
      offset: (first + lines.first.length).clamp(0, next.length),
    ),
  );
}

/// Inserts a horizontal rule on a line of its own.
///
/// A leading `\n` is only added when the caret is *not* already at a line start:
/// a `---` glued to the end of a paragraph is not a rule (the marker has to be
/// the whole line), and adding one at offset 0 would open the document with a
/// blank line.
MarkdownEditFn insertDivider() {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    final int at = v.selection.start;
    final String lead = at > 0 && text.substring(at - 1, at) != '\n' ? '\n' : '';
    final String inserted = '$lead---\n';
    final String next = text.replaceRange(at, v.selection.end, inserted);
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: (at + inserted.length).clamp(0, next.length),
      ),
    );
  };
}

/// Inserts a link and leaves the **URL** selected.
///
/// Selecting the URL rather than the label is the point: the label is usually
/// already what the user selected (or a placeholder they can leave), while the
/// address is the one thing that always has to be typed or pasted next. Landing
/// the selection back on the label makes the user click into the brackets to
/// finish the job.
MarkdownEditFn insertLink() {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String selected = v.text.substring(
      v.selection.start,
      v.selection.end,
    );
    final String label = selected.isEmpty ? '标题' : selected;
    const String url = 'https://';
    final String inserted = '[$label]($url)';
    final String next = v.text.replaceRange(
      v.selection.start,
      v.selection.end,
      inserted,
    );
    // `[label](` is one bracket + the label + `](`.
    final int urlStart = v.selection.start + 1 + label.length + 2;
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: urlStart,
        extentOffset: (urlStart + url.length).clamp(0, next.length),
      ),
    );
  };
}

/// Inserts an internal `[[wikilink]]` and leaves the **label** selected.
///
/// The sibling of [insertLink], not a synonym for it: NRS paints `[[…]]` as a
/// chip that jumps to the note with that title, so "新增链接" and "新增外部链接"
/// are two different destinations. Selecting the label (rather than landing the
/// caret after the brackets) is what lets you type the target straight over the
/// placeholder.
MarkdownEditFn insertWikilink() {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String selected = v.text.substring(
      v.selection.start,
      v.selection.end,
    );
    final String label = selected.isEmpty ? '笔记标题' : selected;
    final String inserted = '[[$label]]';
    final String next = v.text.replaceRange(
      v.selection.start,
      v.selection.end,
      inserted,
    );
    final int start = v.selection.start + 2;
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: start,
        extentOffset: (start + label.length).clamp(0, next.length),
      ),
    );
  };
}

/// Inserts a standalone block at the caret, guaranteeing blank lines around it.
MarkdownEditFn insertBlock(String snippet, {int? caretOffset}) {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    final int at = v.selection.start;

    final String lead = at == 0 || text.substring(0, at).endsWith('\n')
        ? '\n'
        : '\n\n';
    final String trail = text.substring(at).startsWith('\n') ? '' : '\n';

    final String next =
        text.substring(0, at) + lead + snippet + trail + text.substring(at);
    final int caret = at + lead.length + (caretOffset ?? snippet.length);
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret.clamp(0, next.length)),
    );
  };
}

/// Wraps the selection in a fenced code block, or opens an empty one.
MarkdownEditFn codeBlock({String language = ''}) {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    final String selection = v.text.substring(
      v.selection.start,
      v.selection.end,
    );
    final int at = v.selection.start;

    final String lead = at == 0 || text.substring(0, at).endsWith('\n')
        ? '\n'
        : '\n\n';
    final String body = selection.isEmpty ? '' : selection;
    final String snippet = '```$language\n$body\n```\n';
    final String next =
        text.substring(0, at) + lead + snippet + text.substring(v.selection.end);
    final int caret = selection.isEmpty
        ? at + lead.length + 3 + language.length + 1
        : at + lead.length + snippet.length;
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret.clamp(0, next.length)),
    );
  };
}

const String kTableSkeleton = '''
| 列一 | 列二 | 列三 |
| --- | --- | --- |
| 内容 | 内容 | 内容 |
''';

/// Continues a list when Enter is pressed inside one.
///
/// Returns `null` when the caret is not in a list, letting the default newline
/// behaviour take over.
TextEditingValue? continueListOnEnter(TextEditingValue v) {
  final TextSelection sel = v.selection;
  if (!sel.isValid || !sel.isCollapsed) return null;
  final String text = v.text;
  final int lineStart = lineStartOf(text, sel.start);
  final String line = text.substring(lineStart, sel.start);
  final Match? m = RegExp(r'^(\s{0,3})([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?(.*)$')
      .firstMatch(line);
  if (m == null) return null;

  final String indent = m.group(1)!;
  final String marker = m.group(2)!;
  final String checkbox = m.group(3) ?? '';
  final String content = m.group(4) ?? '';

  // Pressing Enter on an empty item ends the list.
  if (content.trim().isEmpty) {
    final String next = text.replaceRange(lineStart, sel.start, '');
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: lineStart),
    );
  }

  String nextMarker = marker;
  if (RegExp(r'^\d+[.)]$').hasMatch(marker)) {
    final int n = int.parse(marker.replaceAll(RegExp(r'[.)]'), ''));
    final String dot = marker.endsWith(')') ? ')' : '.';
    nextMarker = '${n + 1}$dot';
  }
  final String newItem = '\n$indent$nextMarker ${checkbox.isEmpty ? '' : '[ ] '}';
  final String next = text.replaceRange(sel.start, sel.start, newItem);
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: sel.start + newItem.length),
  );
}

/// Tab / Shift+Tab indentation inside lists.
TextEditingValue indentLines(TextEditingValue v, {required bool outdent}) {
  final String text = v.text;
  final int firstLine = lineStartOf(text, v.selection.start);
  final int blockEnd = lineEndOf(text, v.selection.end);
  final List<String> lines = text.substring(firstLine, blockEnd).split('\n');
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    if (outdent) {
      out.write(
        line.startsWith('  ') ? line.substring(2) : line.replaceFirst(RegExp(r'^\s'), ''),
      );
    } else if (line.trim().isEmpty) {
      out.write(line);
    } else {
      out.write('  $line');
    }
    if (i != lines.length - 1) out.write('\n');
  }
  final String result =
      text.substring(0, firstLine) + out.toString() + text.substring(blockEnd);
  final int delta = result.length - text.length;
  return TextEditingValue(
    text: result,
    selection: TextSelection(
      baseOffset: firstLine,
      extentOffset: (blockEnd + delta).clamp(firstLine, result.length),
    ),
  );
}

bool isInsideFence(String text, int offset) {
  int fences = 0;
  int index = 0;
  for (final String line in text.split('\n')) {
    if (RegExp(r'^\s{0,3}```').hasMatch(line)) fences++;
    final int lineEnd = index + line.length;
    if (offset >= index && offset <= lineEnd) break;
    index = lineEnd + 1;
  }
  return fences.isOdd;
}

/// The index of the first character of the line that contains [offset].
///
/// `offset == 0` is the one case that needs care, and it is worth spelling out
/// because getting it wrong is invisible until it is not: `offset - 1` has to
/// be *ignored*, not clamped back to `0`. Clamping searches for a newline *at*
/// index 0 — and a document whose body starts with a blank line (which is
/// exactly what the front-matter split used to leave behind) then reports the
/// line as starting at 1 while [lineEndOf] still says it ends at 0, so the
/// caller slices `substring(1, 0)` and the whole pane turns into a red box.
///
/// Both this and [lineEndOf] are public because the pane needs the same
/// judgement for its "行 n,列 m" readout, and a second copy of it is how the two
/// ends drift apart again.
int lineStartOf(String text, int offset) {
  if (offset <= 0) return 0;
  final int at = offset > text.length ? text.length : offset;
  final int i = text.lastIndexOf('\n', at - 1);
  return i < 0 ? 0 : i + 1;
}

/// The index of the newline that ends the line containing [offset], or the end
/// of the text when it is the last line.
///
/// A caret parked *on* a newline belongs to the line that newline terminates,
/// which is why the search starts at [offset] itself.
int lineEndOf(String text, int offset) {
  final int i = text.indexOf('\n', offset.clamp(0, text.length));
  return i < 0 ? text.length : i;
}

List<int> _wordBounds(String text, int caret) {
  bool isWord(String c) => RegExp(r'[^\s\p{P}]', unicode: true).hasMatch(c);
  int start = caret;
  int end = caret;
  while (start > 0 && isWord(text[start - 1])) {
    start--;
  }
  while (end < text.length && isWord(text[end])) {
    end++;
  }
  return <int>[start, end];
}
