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

/// Inserts an empty table and drops the caret into its first cell.
///
/// A table is the one block the renderer has to size as a whole, so the
/// skeleton that gets inserted must already be well formed — a header row, the
/// `| --- |` divider that turns it into a header, and a body row. Two columns
/// by two rows is the smallest shape that shows all three parts at once, and
/// the one the reference app drops in: the caret blinks in the first cell and
/// the rest is one Tab away.
MarkdownEditFn insertTable() {
  const String snippet = '|  |  |\n| --- | --- |\n|  |  |\n';
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    final int at = v.selection.start;
    final String lead = at > 0 && text.substring(at - 1, at) != '\n' ? '\n' : '';
    final String inserted = '$lead$snippet';
    final String next = text.replaceRange(at, v.selection.end, inserted);
    // Two characters in: past the leading `| ` of the first header cell.
    final int caret = at + lead.length + 2;
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: caret.clamp(0, next.length),
      ),
    );
  };
}

/// The cells of a table line, as `[start, end)` ranges of **line-relative**
/// offsets — the text between the pipes, padding spaces included.
///
/// One parser for the whole app: the renderer measures its columns from these
/// ranges and Tab walks them. A second copy would eventually disagree with the
/// first about what a cell is.
List<(int, int)> tableCellsOf(String line) {
  final List<(int, int)> cells = <(int, int)>[];
  int pipe = line.indexOf('|');
  if (pipe < 0) return cells;
  while (true) {
    final int next = line.indexOf('|', pipe + 1);
    final int from = pipe + 1;
    if (next < 0) {
      if (from < line.length) cells.add((from, line.length));
      break;
    }
    cells.add((from, next));
    pipe = next;
  }
  return cells;
}

/// Whether a line is a row of a table (the divider counts — it is part of the
/// block, it just holds no cells).
bool isTableLine(String line) => line.trimLeft().startsWith('|');

/// Whether deleting the character at [removedAt] would take it **out of the
/// cell that holds the caret** — the one edit a table cell must not allow.
///
/// A cell is edited in place, so the caret sits between two pipes; one
/// Backspace too many eats the pipe (or, once the cell is already empty, the
/// last character of the cell to its left). The grid then loses a column and
/// the row falls back to its raw source — the user reads that as 「跨表格把
/// 区域两个字给删了」. Deleting *inside* the cell stays unlimited; only the
/// cell's own boundary is a wall. Deleting the pipes is still possible from
/// outside a cell (a selection, or a caret sitting on the row's edges).
bool tableCellBarrier(String text, int removedAt) {
  if (removedAt < 0 || removedAt >= text.length) return false;
  final int start = lineStartOf(text, removedAt);
  final String line = text.substring(start, lineEndOf(text, removedAt));
  if (!isTableLine(line)) return false;
  final List<(int, int)> cells = tableCellsOf(line);
  if (cells.isEmpty) return false;
  for (final (int a, int b) in cells) {
    // The caret and the character about to go are the same offset here: a
    // one-character deletion lands the caret exactly where the character was.
    if (removedAt < start + a || removedAt > start + b) continue;
    // Only the cell's **content** may go. Its padding spaces belong to the
    // table — eating one would slide the glyphs of the cell a space to the
    // left — and `start + b` is the pipe itself, which ends the cell's range
    // and therefore never counts as content.
    int from = start + a;
    int to = start + b;
    while (from < to && line[from - start] == ' ') {
      from++;
    }
    while (to > from && line[to - 1 - start] == ' ') {
      to--;
    }
    return removedAt < from || removedAt >= to;
  }
  // Outside every cell but still on a row: the pipes are the table.
  return text[removedAt] == '|';
}

/// `| --- | :-: |` — the row that says a table has begun and how its columns
/// are aligned.
///
/// The one judgement in the app: the renderer collapses this row, Tab steps
/// over it, and neither may disagree about which row it is.
bool isTableDivider(String line) => line.contains('-') && _dividerRe.hasMatch(line);

final RegExp _dividerRe = RegExp(r'^[\s|:\-]+$');

/// The lines of the table block that contains [caret], as absolute
/// `[start, end)` ranges — divider line included, because a column has to be
/// added to it as well or the table would lose its alignment row.
List<(int, int)> _tableRowLines(String text, int caret) {
  int start = lineStartOf(text, caret);
  final int here = start;
  while (start > 0) {
    final int prev = lineStartOf(text, start - 1);
    if (!isTableLine(text.substring(prev, lineEndOf(text, prev)))) break;
    start = prev;
  }
  int end = lineEndOf(text, here);
  while (end < text.length) {
    final int next = end + 1;
    final int stop = lineEndOf(text, next);
    if (!isTableLine(text.substring(next, stop))) break;
    end = stop;
  }
  final List<(int, int)> rows = <(int, int)>[];
  int at = start;
  while (at <= end) {
    final int stop = lineEndOf(text, at);
    rows.add((at, stop));
    at = stop + 1;
    if (stop == end) break;
  }
  return rows;
}

/// Every row of the table block that contains [caret], as absolute
/// `[start, end)` cell ranges. Divider lines are skipped: there is nothing
/// there to type into.
List<List<(int, int)>> _tableBlock(String text, int caret) {
  return <List<(int, int)>>[
    for (final (int start, int stop) in _tableRowLines(text, caret))
      if (!isTableDivider(text.substring(start, stop)))
        if (tableCellsOf(text.substring(start, stop)).isNotEmpty)
          <(int, int)>[
            for (final (int a, int b) in tableCellsOf(text.substring(start, stop)))
              (start + a, start + b),
          ],
  ];
}

/// The markdown a **table** selection puts on the clipboard: a table built out
/// of the cells it covers, header row and divider included.
///
/// A table is selected **by the cell** — the editor's wash snaps out to whole
/// cells — so a drag that crosses a cell boundary is a selection of *cells*, not
/// of the characters between them. Handing the raw range to the clipboard gave
/// the user the pipes, the `| --- | --- |` divider and the leading `| 侧栏 |` of
/// every row the drag passed through — user: 「在表格里是选中格子，选中文字只能
/// 选中同一格的文字」.
///
/// And what comes back has to be a **table**, not a column of loose lines: the
/// point of copying a block is to paste a block. Markdown only recognises a
/// table when the second line is a divider, so one is emitted, and the first
/// selected row becomes the header — which is the real header whenever the drag
/// started at the top of the table. user: 「如果我只选中左边一部分，复制的时候，
/// 可以直接粘贴这部分表格」.
///
/// `null` means "not a cell selection", and the caller must fall back to the
/// plain range: a drag inside **one** cell is ordinary text selection and has to
/// copy exactly the characters under the pointer, and a range that starts in
/// prose (or runs out of the table) is prose.
String? tableSelectionMarkdown(String text, TextSelection selection) {
  if (selection.isCollapsed || !selection.isValid) return null;
  final int a = selection.start;
  final int b = selection.end;
  if (a < 0 || b > text.length) return null;
  final List<List<(int, int)>> rows = _tableBlock(text, a);
  if (rows.isEmpty) return null;
  // ⛔ Both ends in the same block. `b` is exclusive, so the last selected
  // character is `b - 1`: once the block ends before it, the selection has run
  // out of the table and there are no cells to hand back.
  if (b - 1 > rows.last.last.$2) return null;
  final (int, int)? from = _cellAtOffset(rows, text, a);
  final (int, int)? to = _cellAtOffset(rows, text, b - 1);
  if (from == null || to == null) return null;
  // One cell: this is text selection inside it, character for character.
  if (from == to) return null;

  final int r0 = from.$1 < to.$1 ? from.$1 : to.$1;
  final int r1 = from.$1 < to.$1 ? to.$1 : from.$1;
  final int c0 = from.$2 < to.$2 ? from.$2 : to.$2;
  final int c1 = from.$2 < to.$2 ? to.$2 : from.$2;
  final int cols = c1 - c0 + 1;
  final List<String> lines = <String>[];
  for (int r = r0; r <= r1; r++) {
    final List<String> cells = <String>[];
    for (int c = c0; c <= c0 + cols - 1; c++) {
      if (c >= rows[r].length) {
        // A short row still fills the grid, or the pasted table would come out
        // with a ragged edge and the divider would not match its own header.
        cells.add('');
        continue;
      }
      final (int start, int stop) = rows[r][c];
      // The padding spaces belong to the table, not to the cell: they line the
      // columns up in the source and would only show up as ragged indentation
      // once pasted somewhere else.
      cells.add(text.substring(start, stop).trim());
    }
    lines.add('| ${cells.join(' | ')} |');
    if (r == r0) {
      lines.add('| ${List<String>.filled(cols, '---').join(' | ')} |');
    }
  }
  return lines.join('\n');
}

/// Which cell of a table block an offset belongs to, as `(row, column)`.
///
/// An offset on a pipe — or on the newline that closes a row — belongs to the
/// cell that **ends** there, so a drag that stops on the row boundary keeps the
/// cell the pointer is sitting in instead of jumping into the next row.
(int, int)? _cellAtOffset(
  List<List<(int, int)>> rows,
  String text,
  int offset,
) {
  for (int r = 0; r < rows.length; r++) {
    final List<(int, int)> row = rows[r];
    if (row.isEmpty) continue;
    if (offset <= row.last.$2) {
      for (int c = 0; c < row.length; c++) {
        if (offset <= row[c].$2) return (r, c);
      }
      return (r, row.length - 1);
    }
    if (offset == row.last.$2 + 1 &&
        offset < text.length &&
        text[offset] == '\n') {
      return (r, row.length - 1);
    }
  }
  return null;
}

/// [pasted] with the blank line a **table** needs to stay a table of its own.
///
/// Markdown has no "end of table" token: two tables with nothing between them
/// are one table. So a block pasted on the line under a table grew that table by
/// four rows with an empty right-hand column, and the two tables became one —
/// user: 「如果是在表格的下一行粘贴的话，会把两个表格连在一起」.
///
/// Only the boundaries the pasted block actually touches are padded: pasting a
/// table into the middle of a paragraph is a paste, not a table.
String padTablePaste(String text, int at, String pasted) {
  if (pasted.isEmpty || !isTableLine(pasted.split('\n').first)) return pasted;
  final int from = at.clamp(0, text.length);
  final int lineStart = lineStartOf(text, from);
  // ⛔ The caret has to own the start of its line. Mid-line, a blank line would
  // split a paragraph in half instead of closing a table.
  if (from != lineStart) return pasted;
  String out = pasted;
  if (lineStart > 0) {
    // The line above: a table row would swallow the pasted block as more of its
    // own rows, so the block gets a blank line to stand on.
    final String above = text.substring(lineStartOf(text, lineStart - 1), lineStart - 1);
    if (isTableLine(above) && !out.startsWith('\n')) out = '\n$out';
  }
  if (from < text.length) {
    // …and the line below, which would otherwise read as the next row of the
    // block we just pasted.
    final String below = text.substring(from, lineEndOf(text, from));
    if (isTableLine(below) && !out.endsWith('\n\n')) {
      out = out.endsWith('\n') ? '$out\n' : '$out\n\n';
    }
  }
  return out;
}

/// Whether [line] is a row of pipes with nothing in it — the row `Enter` at the
/// end of a table makes, and the only row a pasted block may replace.
bool _blankRow(String line) {
  if (!isTableLine(line)) return false;
  for (final (int a, int b) in tableCellsOf(line)) {
    if (line.substring(a, b).trim().isNotEmpty) return false;
  }
  return true;
}

/// The pasted block's rows, ready to be **added to the table it lands in** — its
/// header and divider dropped, because that table already has both.
///
/// A copied block is a table of its own, but pasting it under a table is how
/// rows get duplicated, and what comes out has to be **one** table, not two —
/// user: 「还是两个表格啊？应该连在一起变成一个表格」. The copy's header cannot
/// survive that: markdown has exactly one header, its first row, so a second
/// header would land as a data row carrying the old column names (which is the
/// mess in the user's screenshot).
///
/// `null` when the block cannot join, and the caller keeps the two tables apart
/// instead: the caret is in a row that already holds text, the block is not the
/// same width as the table, or there is no table at the caret at all. A
/// one-column copy under a three-column table is the everyday example of the
/// width rule — that one is meant to stay a table of its own.
(int, int, String)? _joinTable(String text, int from, int to, String pasted) {
  final int lineStart = lineStartOf(text, from);
  final int lineEnd = lineEndOf(text, from);
  if (to > lineEnd) return null;
  final String line = text.substring(lineStart, lineEnd);

  final int cols;
  int start;
  int end;
  if (isTableLine(line)) {
    // ⛔ Only an empty row — the one `Enter` leaves at the end of a table — is
    // taken over. A row that holds text keeps it.
    if (!_blankRow(line)) return null;
    cols = tableCellsOf(line).length;
    start = lineStart;
    end = lineEnd;
  } else {
    // The line right under a table: the rows join it where they stand.
    if (from != lineStart || lineStart == 0) return null;
    final String above = text.substring(
      lineStartOf(text, lineStart - 1),
      lineStart - 1,
    );
    if (!isTableLine(above)) return null;
    cols = tableCellsOf(above).length;
    start = from;
    end = to;
  }

  final List<String> rows = <String>[];
  bool first = true;
  for (final String row in pasted.split('\n')) {
    if (!isTableLine(row)) return null;
    if (isTableDivider(row)) continue;
    final List<String> cells = <String>[
      for (final (int a, int b) in tableCellsOf(row)) row.substring(a, b).trim(),
    ];
    if (cells.length != cols) return null;
    if (first) {
      // The copy's own header: the table it joins already has one.
      first = false;
      continue;
    }
    rows.add('| ${cells.join(' | ')} |');
  }
  if (rows.isEmpty) return null;
  return (start, end, rows.join('\n'));
}

/// [v] with [pasted] dropped in at its selection — the one insert path every
/// paste route goes through, so the table rules below can never be skipped.
///
/// Three of them, in order:
///
/// * the block **joins** the table at the caret, header dropped, when it is the
///   same width ([_joinTable]) — that is how rows get duplicated;
/// * inside an **empty row** that it cannot join, the row is replaced: the block
///   becomes a table of its own rather than being poured into the row's first
///   cell;
/// * on a line of its own next to a table, a blank line is added, because
///   markdown has no end-of-table token ([padTablePaste]).
///
/// A caret inside a row that already holds text is left alone: there is no
/// reading of "paste a table here" that does not destroy something, and silently
/// eating the row would be worse than the mess it makes.
TextEditingValue pasteValue(TextEditingValue v, String pasted) {
  final String text = v.text;
  final int a = (v.selection.start < 0 ? text.length : v.selection.start)
      .clamp(0, text.length);
  final int b = (v.selection.end < 0 ? text.length : v.selection.end)
      .clamp(0, text.length);
  final int from = a < b ? a : b;
  final int to = a < b ? b : a;

  int start = from;
  int end = to;
  String insert = pasted;
  if (pasted.isNotEmpty && isTableLine(pasted.split('\n').first)) {
    final (int, int, String)? join = _joinTable(text, start, end, pasted);
    if (join != null) {
      start = join.$1;
      end = join.$2;
      insert = join.$3;
    } else {
      final int lineStart = lineStartOf(text, start);
      final int lineEnd = lineEndOf(text, start);
      if (end <= lineEnd && _blankRow(text.substring(lineStart, lineEnd))) {
        start = lineStart;
        end = lineEnd;
        // The blank line above, and one below when something follows: the pasted
        // block takes the row's place, it does not move into it.
        final bool below = end + 1 < text.length;
        insert = '\n$pasted${below ? '\n' : ''}';
      } else {
        insert = padTablePaste(text, start, pasted);
      }
    }
  }
  return TextEditingValue(
    text: text.replaceRange(start, end, insert),
    selection: TextSelection.collapsed(offset: start + insert.length),
  );
}

/// A row of pipes with [columns] empty cells: `|  |  |`.
String _emptyRow(int columns) => '|${'  |' * columns}';


/// Tab / Shift+Tab inside a table: step to the neighbouring cell, the way
/// Obsidian and every spreadsheet do.
///
/// Returns `null` when the caret is not in a table, so the caller can fall back
/// to indenting a list item.
///
/// * Tab on the last cell of a row goes to the first cell of the next row;
/// * Tab on the very last cell appends a row — a table you can never grow from
///   the keyboard is a table you have to hand-edit;
/// * the cell you land in is **selected**, so typing replaces its content.
TextEditingValue? tableCellStep(
  TextEditingValue raw, {
  required bool forward,
}) {
  final TextEditingValue v = _normalised(raw);
  final String text = v.text;
  final int caret = v.selection.start;
  // Tab is cell navigation only when the caret is *on* a table row: a paragraph
  // directly under a table must still indent rather than jump into the grid.
  // Inside a fence the pipes are code, so Tab is indentation there too.
  final int lineStart = lineStartOf(text, caret);
  if (!isTableLine(text.substring(lineStart, lineEndOf(text, caret)))) {
    return null;
  }
  if (isInsideFence(text, caret)) return null;
  final List<List<(int, int)>> rows = _tableBlock(text, caret);
  if (rows.isEmpty) return null;

  final List<(int, int)> flat = <(int, int)>[for (final List<(int, int)> r in rows) ...r];
  int index = -1;
  for (int i = 0; i < flat.length; i++) {
    if (flat[i].$1 <= caret && caret <= flat[i].$2) {
      index = i;
      break;
    }
  }
  if (index < 0) {
    // The caret is on a line with no cells — the divider, which the editor
    // hides. Step into the nearest row rather than falling out of the table.
    if (!forward) {
      return _selectCell(
        text,
        flat.lastWhere(
          ((int, int) c) => c.$2 <= caret,
          orElse: () => flat.first,
        ),
      );
    }
    return _selectCell(
      text,
      flat.firstWhere(
        ((int, int) c) => c.$1 >= caret,
        orElse: () => flat.last,
      ),
    );
  }

  if (!forward) {
    if (index == 0) return _selectCell(text, flat.first);
    return _selectCell(text, flat[index - 1]);
  }
  if (index + 1 < flat.length) return _selectCell(text, flat[index + 1]);

  // Past the last cell: grow the table by one row, and select its first cell so
  // typing lands inside it instead of after the padding spaces.
  final int columns = rows.fold<int>(
    0,
    (int m, List<(int, int)> r) => m > r.length ? m : r.length,
  );
  final int at = _afterTrailingPipe(text, flat.last.$2);
  final String grown = text.replaceRange(at, at, '\n${_emptyRow(columns)}');
  final (int, int) fresh = tableCellsOf(_emptyRow(columns)).first;
  return TextEditingValue(
    text: grown,
    selection: TextSelection(
      baseOffset: at + 1 + fresh.$1,
      extentOffset: at + 1 + fresh.$2,
    ),
  );
}

/// The offset just past the `|` that closes the cell whose text ends at [end],
/// or [end] itself when the row has no trailing pipe.
int _afterTrailingPipe(String text, int end) {
  final int stop = lineEndOf(text, end);
  int at = end;
  while (at < stop && (text[at] == ' ' || text[at] == '\t')) {
    at++;
  }
  return at < stop && text[at] == '|' ? at + 1 : stop;
}

/// Selects a cell's content, minus the padding spaces that belong to the
/// source, not to the text.
TextEditingValue _selectCell(String text, (int, int) cell) {
  int a = cell.$1;
  int b = cell.$2;
  while (a < b && (text[a] == ' ' || text[a] == '\t')) {
    a++;
  }
  while (b > a && (text[b - 1] == ' ' || text[b - 1] == '\t')) {
    b--;
  }
  return TextEditingValue(
    text: text,
    selection: b > a
        ? TextSelection(baseOffset: a, extentOffset: b)
        : TextSelection.collapsed(offset: a),
  );
}

/// Enter inside a table: a new row of the same width, right below the row the
/// caret is on, with the caret in the same column. Returns `null` outside a
/// table (and outside a fence, where pipes are code).
///
/// Driven off the caret's own line rather than the block, so it works from the
/// Enter formatter too — where the caret has already been pushed to the end of
/// the line and a bare newline at that point would slice the row in two.
TextEditingValue? tableRowBelow(TextEditingValue raw) {
  final TextEditingValue v = _normalised(raw);
  final String text = v.text;
  final int caret = v.selection.start;
  final int start = lineStartOf(text, caret);
  final int stop = lineEndOf(text, caret);
  final String line = text.substring(start, stop);
  if (!isTableLine(line) || isInsideFence(text, caret)) return null;
  final List<(int, int)> cells = tableCellsOf(line);
  if (cells.isEmpty) return null;

  final int inLine = caret - start;
  final int column = cells.indexWhere(
    ((int, int) c) => c.$1 <= inLine && inLine <= c.$2,
  );
  final int at = _afterTrailingPipe(text, start + cells.last.$2);
  final String fresh = _emptyRow(cells.length);
  final String grown = text.replaceRange(at, at, '\n$fresh');
  // Land in the same column, one row down — never back at the first cell, or
  // typing would silently jump columns.
  final List<(int, int)> spans = tableCellsOf(fresh);
  final (int, int) cell = spans[(column < 0 ? 0 : column).clamp(0, spans.length - 1)];
  return TextEditingValue(
    text: grown,
    selection: TextSelection(
      baseOffset: at + 1 + cell.$1,
      extentOffset: at + 1 + cell.$2,
    ),
  );
}

/// The table edits the menu offers — the ones a keyboard cannot do: every row
/// has to change at once for a column, which is exactly the kind of edit nobody
/// should be doing by hand.
enum TableEdit { rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn }

/// Applies [op] to the table the caret is in, or returns `null` when the caret
/// is not on a table row (or a pipe-led line inside a fence, which is code).
///
/// The caret is kept in the cell it was in, so adding a column on the left does
/// not silently move the user into a different one.
TextEditingValue? editTable(TextEditingValue raw, TableEdit op) {
  final TextEditingValue v = _normalised(raw);
  final String text = v.text;
  final int caret = v.selection.start;
  if (isInsideFence(text, caret)) return null;
  final int lineStart = lineStartOf(text, caret);
  final int lineStop = lineEndOf(text, caret);
  final String here = text.substring(lineStart, lineStop);
  if (!isTableLine(here)) return null;

  final List<(int, int)> rows = _tableRowLines(text, caret);
  final List<(int, int)> cells = tableCellsOf(here);
  final int column = cells.indexWhere(
    ((int, int) c) => lineStart + c.$1 <= caret && caret <= lineStart + c.$2,
  );

  switch (op) {
    case TableEdit.rowBelow:
      return tableRowBelow(raw);

    case TableEdit.rowAbove:
      final (int, int) row = rows.firstWhere(
        ((int, int) r) => r.$1 == lineStart,
        orElse: () => (lineStart, lineStop),
      );
      final String fresh = _emptyRow(cells.length);
      final String grown = text.replaceRange(row.$1, row.$1, '$fresh\n');
      final List<(int, int)> spans = tableCellsOf(fresh);
      final (int, int) cell = spans[(column < 0 ? 0 : column).clamp(0, spans.length - 1)];
      return TextEditingValue(
        text: grown,
        selection: TextSelection(
          baseOffset: row.$1 + cell.$1,
          extentOffset: row.$1 + cell.$2,
        ),
      );

    case TableEdit.deleteRow:
      // Keep the divider: a table with no alignment row is no longer a table.
      if (isTableDivider(here)) return null;
      final int stop = lineStop < text.length ? lineStop + 1 : lineStop;
      final int from = lineStart == 0 ? 0 : lineStart - 1;
      final String cut = text.replaceRange(from, stop, '');
      return TextEditingValue(
        text: cut,
        selection: TextSelection.collapsed(
          offset: from.clamp(0, cut.length),
        ),
      );

    case TableEdit.columnLeft:
    case TableEdit.columnRight:
      return _addColumn(
        text,
        rows,
        cells,
        column,
        caret,
        after: op == TableEdit.columnRight,
      );

    case TableEdit.deleteColumn:
      if (cells.length <= 1) return null;
      return _dropColumn(text, rows, cells, column, caret);
  }
}

/// Applies one structural edit to every row of a block, and keeps the caret
/// where the user left it.
///
/// `edit` describes a single row as `(at, remove, insert)` — a splice, the same
/// shape whether the row grows or shrinks. That is what lets one caret remap
/// serve both: everything after a splice slides by `insert.length - remove`, and
/// a caret that fell inside the removed range lands at the splice point, which
/// is the cell the edit was about.
TextEditingValue _rebuildRows(
  String text,
  List<(int, int)> rows,
  int caret,
  (int, int, String) Function(String line, int start) edit,
) {
  final StringBuffer out = StringBuffer();
  int cursor = 0;
  int shift = 0;
  int moved = caret;
  for (final (int start, int stop) in rows) {
    final String line = text.substring(start, stop);
    final (int at, int remove, String insert) = edit(line, start);
    out
      ..write(text.substring(cursor, start))
      ..write(line.substring(0, at))
      ..write(insert)
      ..write(line.substring(at + remove));
    final int delta = insert.length - remove;
    final int atAbs = start + at;
    if (caret >= atAbs + remove) {
      moved += delta;
    } else if (caret > atAbs) {
      moved = atAbs + shift + insert.length;
    }
    shift += delta;
    cursor = stop;
  }
  out.write(text.substring(cursor));
  final String rebuilt = out.toString();
  return TextEditingValue(
    text: rebuilt,
    selection: TextSelection.collapsed(
      offset: moved.clamp(0, rebuilt.length),
    ),
  );
}

/// One more cell in every row — right of the caret's column when [after], left
/// of it otherwise.
///
/// "Right of a cell" means just past the pipe that closes it. Inserting *before*
/// that pipe would swallow the new cell into its neighbour; inserting after the
/// previous pipe is what makes `| a | b |` become `| a |  | b |`.
///
/// The divider row gets `---`, not spaces: a divider of empty cells still reads
/// as a plain row and the table would quietly lose its alignment.
TextEditingValue? _addColumn(
  String text,
  List<(int, int)> rows,
  List<(int, int)> hereCells,
  int column,
  int caret, {
  required bool after,
}) {
  if (hereCells.isEmpty) return null;
  final int target =
      (column < 0 ? hereCells.length - 1 : column).clamp(0, hereCells.length - 1);
  return _rebuildRows(text, rows, caret, (String line, int start) {
    final List<(int, int)> cells = tableCellsOf(line);
    if (cells.isEmpty) return (0, 0, '');
    final int at = target.clamp(0, cells.length - 1);
    final String filler = isTableDivider(line) ? ' --- |' : '  |';
    if (!after) return (cells[at].$1, 0, filler);
    // A row without a trailing pipe has nowhere to hang the new cell: close it
    // first (`| a | b` → `| a | b |  |`), never leave a cell glued to its text.
    final bool closed = cells[at].$2 < line.length;
    return closed ? (cells[at].$2 + 1, 0, filler) : (line.length, 0, ' |$filler');
  });
}

/// One cell fewer in every row. The range removed is "the pipe before the cell
/// plus the cell itself", so the pipe that closed it becomes the new separator —
/// no `| |` left behind, and the row still starts with a pipe.
TextEditingValue? _dropColumn(
  String text,
  List<(int, int)> rows,
  List<(int, int)> hereCells,
  int column,
  int caret,
) {
  if (hereCells.isEmpty) return null;
  final int target =
      (column < 0 ? hereCells.length - 1 : column).clamp(0, hereCells.length - 1);
  return _rebuildRows(text, rows, caret, (String line, int start) {
    final List<(int, int)> cells = tableCellsOf(line);
    if (cells.isEmpty) return (0, 0, '');
    final int at = target.clamp(0, cells.length - 1);
    return (cells[at].$1 - 1, cells[at].$2 - cells[at].$1 + 1, '');
  });
}

/// Applies [op] to the table that contains [at] — the offset of any character
/// on one of its rows.
///
/// The “+” buttons that hang off a table's right and bottom edges are clicked
/// with the caret somewhere else entirely, so the operation they run cannot be
/// keyed off the selection the way the context menu's is.
TextEditingValue? editTableAt(TextEditingValue raw, int at, TableEdit op) =>
    editTable(
      raw.copyWith(
        selection: TextSelection.collapsed(
          offset: at.clamp(0, raw.text.length),
        ),
      ),
      op,
    );

/// Moves one row of the table at [at] from [from] to [to] — the drag handles on
/// the table's left edge.
///
/// [from] and [to] are indices among the block's **non-divider** rows, which is
/// the order the renderer paints. The divider is not a row: it is what makes the
/// row above it the header, so it travels with whichever row ends up first —
/// dragging the header down swaps the two roles, exactly as Obsidian does, and
/// the table never loses its alignment row.
TextEditingValue? moveTableRow(TextEditingValue raw, int at, int from, int to) {
  final String text = raw.text;
  if (isInsideFence(text, at)) return null;
  final List<(int, int)> lines = _tableRowLines(text, at);
  if (lines.length < 2) return null;
  final List<String> rows = <String>[
    for (final (int a, int b) in lines) text.substring(a, b),
  ];
  final int divider = rows.indexWhere(isTableDivider);
  final List<int> body = <int>[
    for (int i = 0; i < rows.length; i++)
      if (i != divider) i,
  ];
  if (body.length < 2) return null;
  if (from < 0 || from >= body.length || to < 0 || to >= body.length) {
    return null;
  }
  if (from == to) return null;
  final List<int> order = <int>[...body];
  order.insert(to, order.removeAt(from));
  // The divider always sits directly under the first row: that is the row the
  // renderer will treat as the header, so the two can never disagree.
  final List<int> out = divider < 0
      ? order
      : <int>[order.first, divider, ...order.skip(1)];
  final String rebuilt = <String>[for (final int i in out) rows[i]].join('\n');
  final String next = text.replaceRange(lines.first.$1, lines.last.$2, rebuilt);
  // The caret stays on the **text** it was on, which has moved.
  final int block = lines.first.$1;
  int moved = raw.selection.start;
  final int li = lines.indexWhere(
    ((int, int) r) => raw.selection.start >= r.$1 && raw.selection.start <= r.$2,
  );
  final int ni = li < 0 ? -1 : out.indexOf(li);
  if (ni >= 0) {
    final List<String> fresh = <String>[for (final int i in out) rows[i]];
    moved = block + _lineOffset(fresh, ni) + (raw.selection.start - lines[li].$1);
  }
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: moved.clamp(0, next.length)),
  );
}

/// The absolute offset of line [i] in a block of lines that were split on `\n`
/// and started at the block's first character.
int _lineOffset(List<String> lines, int i) {
  int at = 0;
  for (int k = 0; k < i; k++) {
    at += lines[k].length + 1;
  }
  return at;
}

/// Moves one column of the table at [at] from [from] to [to]. Every row is
/// rewritten — the divider included, so `:-:` alignment stays with its column.
///
/// Rows that are too short to have the column keep their own shape: a malformed
/// row must not be "repaired" into something the user did not write.
TextEditingValue? moveTableColumn(
  TextEditingValue raw,
  int at,
  int from,
  int to,
) {
  final String text = raw.text;
  if (isInsideFence(text, at)) return null;
  if (from == to || from < 0 || to < 0) return null;
  final List<(int, int)> lines = _tableRowLines(text, at);
  if (lines.length < 2) return null;
  final StringBuffer out = StringBuffer();
  int cursor = 0;
  int shift = 0;
  int caret = raw.selection.start;
  for (final (int start, int stop) in lines) {
    final String line = text.substring(start, stop);
    out.write(text.substring(cursor, start));
    final List<(int, int)> cells = tableCellsOf(line);
    final int width = cells.length;
    if (width < 2 ||
        from < 0 ||
        to < 0 ||
        from >= width ||
        to >= width ||
        from == to) {
      out.write(line);
      cursor = stop;
      continue;
    }
    final List<int> order = <int>[for (int i = 0; i < width; i++) i];
    order.insert(to, order.removeAt(from));
    final int indent = line.length - line.trimLeft().length;
    final String joined = <String>[
      for (final int i in order) line.substring(cells[i].$1, cells[i].$2),
    ].join('|');
    final String rebuilt = '${line.substring(0, indent)}|$joined|';
    final int delta = rebuilt.length - line.length;
    if (caret > stop) {
      shift += delta;
    } else if (caret >= start && caret <= stop) {
      // Keep the caret on the character it was on: the cell it lives in has a
      // new index, so the offset inside the cell is re-applied at its new place.
      final int inLine = caret - start;
      final int cell = cells.indexWhere(
        ((int, int) c) => inLine >= c.$1 && inLine <= c.$2,
      );
      if (cell >= 0) {
        final int target = cell < width ? order.indexOf(cell) : -1;
        if (target >= 0) {
          final List<(int, int)> fresh = tableCellsOf(rebuilt);
          final int intoCell = (inLine - cells[cell].$1).clamp(
            0,
            fresh[target].$2 - fresh[target].$1,
          );
          caret = start + shift + fresh[target].$1 + intoCell;
        }
      }
    }
    out.write(rebuilt);
    cursor = stop;
  }
  out.write(text.substring(cursor));
  final String next = out.toString();
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: caret.clamp(0, next.length)),
  );
}

/// Inserts a link and leaves the **URL** selected.
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

/// Strips inline Markdown from the selection — or from the line under the caret
/// when nothing is selected.
///
/// "Clear formatting" has to be the exact inverse of the format commands, so it
/// removes precisely the markers those commands add: `**`, `*`, `__`, `~~`,
/// `==`, backticks, `%%`, `[[…]]` and `[text](url)`. It deliberately leaves
/// list bullets, task boxes and heading marks alone — those are block
/// structure, and 「段落设置 ▸ 正文」 is the command that drops them.
///
/// The pass is repeated because dropping one pair can expose another (bold
/// inside bold, a link around a link), and it stops as soon as nothing changes.
MarkdownEditFn clearFormatting() {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    final bool hasRange =
        v.selection.isValid && !v.selection.isCollapsed;
    final int start = hasRange ? v.selection.start : lineStartOf(text, v.selection.start);
    final int end = hasRange ? v.selection.end : lineEndOf(text, v.selection.start);
    final String slice = text.substring(start, end);
    final String clean = _stripInline(slice);
    if (clean == slice) {
      return hasRange
          ? v
          : v.copyWith(
              selection: TextSelection(
                baseOffset: start,
                extentOffset: end,
              ),
            );
    }
    final String next = text.replaceRange(start, end, clean);
    return TextEditingValue(
      text: next,
      selection: TextSelection(baseOffset: start, extentOffset: start + clean.length),
    );
  };
}

/// One inline-markup scrub, applied until it stops changing anything.
String _stripInline(String source) {
  String out = source;
  for (int pass = 0; pass < 4; pass++) {
    final String before = out;
    out = out
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (Match m) => m[1]!)
        .replaceAllMapped(RegExp(r'__(.+?)__'), (Match m) => m[1]!)
        .replaceAllMapped(RegExp(r'~~(.+?)~~'), (Match m) => m[1]!)
        .replaceAllMapped(RegExp(r'==(.+?)=='), (Match m) => m[1]!)
        // The comment's text is kept: clearing formatting is not deleting.
        .replaceAllMapped(RegExp(r'%%(.+?)%%'), (Match m) => m[1]!)
        .replaceAllMapped(RegExp(r'`([^`]+)`'), (Match m) => m[1]!)
        .replaceAllMapped(RegExp(r'\[\[(.+?)\]\]'), (Match m) => m[1]!)
        .replaceAllMapped(
          RegExp(r'\[([^\]]*)\]\([^)]*\)'),
          (Match m) => m[1]!,
        )
        .replaceAllMapped(
          // A lone `*pair*` — after `**` is gone, so bold never lands here.
          RegExp(r'([^*\w]|^)\*([^*]+)\*(?![\w*])'),
          (Match m) => '${m[1]!}${m[2]!}',
        );
    if (out == before) break;
  }
  return out;
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
