import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'table_model.dart';
import 'table_selection.dart';

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
    selection: TextSelection(
      baseOffset: start.clamp(0, v.text.length),
      extentOffset: end.clamp(0, v.text.length),
    ),
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
          text.substring(0, start - before.length) +
          inner +
          text.substring(end + after.length);
      final int offset = start - before.length;
      return TextEditingValue(
        text: next,
        selection: TextSelection(
          baseOffset: offset,
          extentOffset: offset + inner.length,
        ),
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
    final String next =
        text.substring(0, start) + before + body + after + text.substring(end);
    final int bodyStart = start + before.length;
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: bodyStart,
        extentOffset: bodyStart + body.length,
      ),
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
    final String lead = at > 0 && text.substring(at - 1, at) != '\n'
        ? '\n'
        : '';
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

// ------------------------------------------------------------------- tables
//
// The rules live in `table_model.dart`: a table is parsed into a grid, edited
// as a grid, and rendered back. What is here is the editor's half — what a key
// does, where the caret lands, and what a selection means.

/// The cell a table **caret** belongs to, as `(row, column)` among the body
/// rows.
///
/// Shared with the selection model in `table_selection.dart`, so the cell a
/// menu command acts on and the cell a drag paints can never disagree.
(int, int) _cellOf(TableBlock block, int offset) =>
    tableCellAt(block, offset, extent: false);

/// The selection that puts a cell under the user's fingers: its text, or the
/// whole cell (padding included) when it holds nothing — so the first keystroke
/// replaces the placeholder instead of landing next to it.
TextSelection _cellSelection(TableCell cell) => cell.isEmpty
    ? TextSelection(baseOffset: cell.start, extentOffset: cell.end)
    : TextSelection(
        baseOffset: cell.contentStart,
        extentOffset: cell.contentEnd,
      );

TextEditingValue _valueOf(TableEditResult edit) =>
    TextEditingValue(text: edit.text, selection: edit.selection);

/// The rectangle a selection means, allowing a gesture to speak first.
///
/// Geometry alone cannot tell a column-grip selection from a cell rectangle
/// that happens to cover one column, and §4.3 says the gesture decides. The
/// editor keeps that intent on the controller; commands read it through this
/// resolver and fall back to geometry for a plain drag.
typedef TableRangeResolver =
    TableRange? Function(String text, TextSelection selection);

TableRange? tableRangeOf(
  TextEditingValue value, {
  TableRangeResolver? resolve,
}) {
  final TableRange? intended = resolve?.call(value.text, value.selection);
  if (intended != null) return intended;
  return TableRange.fromSelection(value.text, value.selection);
}

/// The active cell of [range] as source offsets, or `null` outside a table.
///
/// Used by the floating editor, which has to read the cell whole (escapes
/// unescaped) and write it back in one command.
({TableBlock block, int row, int column, TableCell cell})? tableActiveCell(
  TextEditingValue value, {
  TableRangeResolver? resolve,
}) {
  final TableBlock? block = TableBlock.parse(value.text, value.selection.start);
  if (block == null || block.bodyRows.isEmpty) return null;
  final TableRange? range = tableRangeOf(value, resolve: resolve);
  final (int row, int column) = range != null
      ? (range.anchorRow, range.anchorColumn)
      : tableCellAt(block, value.selection.start, extent: false);
  final List<TableRow> body = block.bodyRows;
  final int r = row.clamp(0, body.length - 1);
  final List<TableCell> cells = body[r].cells;
  if (cells.isEmpty) return null;
  final int c = column.clamp(0, cells.length - 1);
  return (block: block, row: r, column: c, cell: cells[c]);
}

/// Writes [text] into one cell — the F2 overlay's commit.
///
/// Line breaks become `<br>` through [escapeCell] on the way out, so a
/// multi-line cell stays one source line and the renderer's 「one row = one
/// line」 invariant survives.
TextEditingValue? setTableCellText(
  TextEditingValue raw, {
  required int tableStart,
  required int row,
  required int column,
  required String text,
}) {
  final TableBlock? block = TableBlock.parse(
    raw.text,
    tableStart.clamp(0, raw.text.length),
  );
  if (block == null) return null;
  final TableEditResult edited = TableCommands.writeRect(
    block,
    fromRow: row,
    toRow: row,
    fromColumn: column,
    toColumn: column,
    atRow: row,
    atColumn: column,
    values: <List<String>>[
      <String>[text],
    ],
  );
  return _valueOf(edited);
}

/// Inserts an empty table and drops the caret into its first cell.
///
/// Two columns by two rows is the smallest shape that shows a header, a divider
/// and a body row at once; the caret blinks in the first cell and the rest is
/// one Tab away.
MarkdownEditFn insertTable() {
  return (TextEditingValue raw) {
    final TextEditingValue v = _normalised(raw);
    final String text = v.text;
    final int at = v.selection.start;
    final String lead = at > 0 && text.substring(at - 1, at) != '\n'
        ? '\n'
        : '';
    final String table = TableGrid(
      rows: <List<String>>[
        <String>['', ''],
        <String>['', ''],
      ],
      aligns: <TableAlign>[TableAlign.none, TableAlign.none],
      header: true,
    ).render();
    final String inserted = '$lead$table\n';
    final String next = text.replaceRange(at, v.selection.end, inserted);
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: (at + lead.length + 2).clamp(0, next.length),
      ),
    );
  };
}

/// The cells of a table line, as `[start, end)` ranges of **line-relative**
/// offsets — the text between the pipes, padding included.
///
/// One parser for the whole app: the renderer measures its columns from these
/// ranges, Tab walks them and the model edits them. A second copy would
/// eventually disagree with the first about what a cell is.
List<(int, int)> tableCellsOf(String line) => cellsOfLine(line);

/// Whether a line is a row of a table (the divider counts — it is part of the
/// block, it just holds no cells).
bool isTableLine(String line) => isRowLine(line);

/// `| --- | :-: |` — the row that says a table has begun and how its columns
/// are aligned.
bool isTableDivider(String line) => isDividerLine(line);

/// Whether deleting the character at [removedAt] would take it **out of the
/// cell that holds the caret** — the one edit a table cell must not allow.
///
/// A cell is edited in place, so the caret sits between two pipes; one
/// Backspace too many eats the pipe (or, once the cell is already empty, the
/// last character of the cell to its left). The grid then loses a column and
/// the row falls back to its raw source. Deleting *inside* the cell stays
/// unlimited; only the cell's own boundary is a wall.
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
    // table, and `start + b` is the pipe itself, which ends the cell's range
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

/// Where text typed at [at] has to go so that it lands **inside a cell**.
///
/// The rendered row is not editable text: its line still carries the pipes and
/// the padding, and native caret movement can park the caret on any of them.
/// Typing there used to append a phantom cell after the closing pipe (`| a |x`)
/// or a character before the leading one, which stops the line being a row at
/// all. This is the formatter's last line of defence for the routes the table
/// key handler never sees — Ctrl+End, PageDown, a word jump, an engine edit.
///
/// `null` means the insertion is already inside a cell's text (or outside a
/// table, or on the divider, which is edited on purpose). Pipes, padding and
/// the line ends resolve to the nearest cell's content edge.
int? tableTypingAnchor(String text, int at) {
  if (at < 0 || at > text.length) return null;
  // Cheap pre-check: typing over prose must not parse the document.
  final String line = text.substring(
    lineStartOf(text, at),
    lineEndOf(text, at),
  );
  if (!isRowLine(line)) return null;
  final TableBlock? block = TableBlock.parse(text, at);
  if (block == null || block.bodyRows.isEmpty) return null;
  if (_onDivider(block, at)) return null;
  final int r = block.rowAt(at);
  if (r < 0) return null;
  final List<TableCell> cells = block.bodyRows[r].cells;
  if (cells.isEmpty) return null;

  int anchor = cells.last.contentEnd;
  for (final TableCell cell in cells) {
    if (cell.isEmpty) {
      if (at <= cell.end) {
        anchor = cell.contentStart;
        break;
      }
      continue;
    }
    if (at <= cell.contentStart) {
      anchor = cell.contentStart;
      break;
    }
    if (at <= cell.contentEnd) {
      anchor = at;
      break;
    }
    if (at <= cell.end) {
      // Trailing padding or the pipe that closes the cell: append to the text,
      // leaving the padding where the column alignment expects it.
      anchor = cell.contentEnd;
      break;
    }
  }
  return anchor == at ? null : anchor;
}

/// The table-safe value for a deletion that removed `[from, to)`, or `null`
/// when the edit does not cut into a row's structure.
///
/// [tableCellBarrier] guards one character; a word delete (Ctrl+Backspace,
/// Ctrl+Delete) removes a whole run in one engine update and used to walk
/// straight through the closing pipe. The cell under the caret owns the edit:
/// its text may go, its padding and pipes may not. A run that starts in the
/// previous cell is cut at this cell's content edge rather than deleting
/// structure.
///
/// Returning [oldValue] blocks a deletion that was entirely structural:
/// applying it would change the table's shape, and letting it through to the
/// engine would also move the caret as if something had been removed.
TextEditingValue? tableClampDeletion(
  TextEditingValue oldValue,
  int from,
  int to,
) {
  final String text = oldValue.text;
  if (from < 0 || to > text.length || from >= to) return null;
  // A selection is handled by the range model, which already refuses edits that
  // leave the table. This rule is for the caret: the cell it stands in owns the
  // word delete.
  if (!oldValue.selection.isCollapsed) return null;
  final int caret = oldValue.selection.start;
  final TableBlock? block = TableBlock.parse(text, caret);
  if (block == null || block.bodyRows.isEmpty) return null;
  if (_onDivider(block, caret)) return null;
  final (int row, int column) = tableCellAt(block, caret, extent: false);
  final TableRow line = block.bodyRows[row];
  if (line.cells.isEmpty) return null;
  final TableCell cell = line.cells[column.clamp(0, line.cells.length - 1)];
  if (from >= cell.contentStart && to <= cell.contentEnd) return null;

  final int a = from.clamp(cell.contentStart, cell.contentEnd);
  final int b = to.clamp(cell.contentStart, cell.contentEnd);
  if (a >= b) return oldValue;
  final String next = text.replaceRange(a, b, '');
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: a),
  );
}

/// Whether [at] sits on a table's **divider row** — the `| --- |` line that
/// holds no cells and is the table's skeleton.
///
/// The renderer collapses the line to nothing except while the caret is parked
/// on it, which is exactly when a keystroke could rewrite the dashes and turn
/// the grid back into loose pipes. Alignment is edited through the model (the
/// menu writes the divider), never by typing into it.
bool tableOnDivider(String text, int at) {
  if (at < 0 || at > text.length) return false;
  final TableBlock? block = TableBlock.parse(text, at);
  return block != null && _onDivider(block, at);
}

/// Whether the raw edit `[from, to)` cuts the table's own **skeleton**: a
/// divider row, or a newline that is one of a block's row boundaries.
///
/// The rectangle model sees every edit it can recognise first, and a caret
/// delete inside a cell is clamped by [tableClampDeletion]. What is left is an
/// engine write no command matched — a selection anchored on the hidden divider
/// (it holds no cells, so it is no rectangle), or a native word delete that
/// sweeps over a line break. Applying those would turn the block back into a
/// run of loose pipes, and the source is not on screen to repair it.
///
/// Removing the block **whole** is not damage: a range that spans it end to end
/// is the user deleting a table.
bool tableSkeletonTouched(String text, int from, int to) {
  if (from < 0 || to > text.length || from >= to) return false;
  TableBlock? block;
  for (final int at in <int>[from, to, to - 1]) {
    block = TableBlock.parse(text, at);
    if (block != null) break;
  }
  if (block == null) return false;
  final int blockEnd = block.end < text.length ? block.end + 1 : block.end;
  if (from <= block.start && to >= blockEnd) return false;

  for (final TableRow row in block.rows) {
    if (row.divider && from <= row.end && to > row.start) return true;
  }
  // The newline before the block, between its rows, and after its last row:
  // removing one glues two rows — or a paragraph — into one malformed line.
  final int first = math.max(block.start - 1, from);
  final int last = math.min(blockEnd, to);
  for (int i = first; i < last; i++) {
    if (text.codeUnitAt(i) == 0x0A) return true;
  }
  return false;
}

/// The markdown a **table** selection puts on the clipboard: a table built out
/// of the cells it covers, header row and divider included.
///
/// A table is selected **by the cell** — the editor's wash snaps out to whole
/// cells — so a drag that crosses a cell boundary is a selection of *cells*, not
/// of characters. What comes back has to be a **table**, not a column of loose
/// lines: the first selected row becomes the header, and a divider is emitted,
/// because markdown only recognises a table when its second line is one.
///
/// `null` when the selection is inside one cell (that is ordinary text) or
/// leaves the block (that is prose).
String? tableSelectionMarkdown(
  String text,
  TextSelection selection, {
  TableRangeResolver? resolve,
}) => tableRangeOf(
  TextEditingValue(text: text, selection: selection),
  resolve: resolve,
)?.markdown;

/// The value after the washed rectangle is **emptied** — Delete, Backspace or
/// a cut.
///
/// * a cell block is cleared in place: the rows stay, because the selection
///   covered only some of their cells;
/// * a whole-row sweep removes the rows, which is what 「删掉这一行」 means;
/// * a whole-column sweep removes the columns.
///
/// A cleared block keeps its rectangle lit, so an accidental Delete is followed
/// by typing back into the same cells rather than by a caret that has to be
/// found again.
TextEditingValue tableRangeClear(TableRange range) {
  final TableBlock block = range.block;
  switch (range.kind) {
    case TableRangeKind.rows:
      return _valueOf(
        TableCommands.deleteRows(block, range.firstRow, range.lastRow),
      );
    case TableRangeKind.columns:
      // A table needs at least one column, so a sweep that would take the
      // last one is a no-op — the menu row is greyed for the same reason.
      if (range.columnCount >= block.columns) {
        return TextEditingValue(
          text: block.text,
          selection: range.toTextSelection(),
        );
      }
      return _valueOf(
        TableCommands.deleteColumns(
          block,
          from: range.firstColumn,
          to: range.lastColumn,
          row: range.anchorRow,
        ),
      );
    case TableRangeKind.cells:
      return _clearCells(range);
  }
}

/// Clears a rectangle's **contents**, whatever the range's kind, and keeps the
/// rectangle lit. The table keeps its shape; structure is only removed by the
/// row/column commands (and by the keyboard's Delete on a whole-row sweep).
TextEditingValue _clearCells(TableRange range) {
  final TableBlock block = range.block;
  final TableEditResult cleared = TableCommands.clearRect(
    block,
    fromRow: range.firstRow,
    toRow: range.lastRow,
    fromColumn: range.firstColumn,
    toColumn: range.lastColumn,
  );
  final TableBlock? fresh = TableBlock.parse(
    cleared.text,
    block.start.clamp(0, cleared.text.length),
  );
  if (fresh == null) return _valueOf(cleared);
  return TextEditingValue(
    text: cleared.text,
    selection: TableRange.rect(
      fresh,
      fromRow: range.firstRow,
      toRow: range.lastRow,
      fromColumn: range.firstColumn,
      toColumn: range.lastColumn,
      activeRow: range.anchorRow,
      activeColumn: range.anchorColumn,
    ).toTextSelection(),
  );
}

/// The value after [inserted] is typed over the washed rectangle.
///
/// The text lands in the **active cell** and every other selected cell is
/// cleared — the same rule as a spreadsheet, and the only one that does not
/// silently throw away the cell the user started from.
TextEditingValue tableRangeReplace(TableRange range, String inserted) =>
    _valueOf(
      TableCommands.writeRect(
        range.block,
        fromRow: range.firstRow,
        toRow: range.lastRow,
        fromColumn: range.firstColumn,
        toColumn: range.lastColumn,
        atRow: range.anchorRow,
        atColumn: range.anchorColumn,
        values: <List<String>>[
          <String>[inserted],
        ],
      ),
    );

/// Empties the selection's cells — or the caret's own cell when there is no
/// rectangle. The row / column structure never changes here; the menu's
/// destructive row and column commands are separate on purpose. This is the
/// menu's 清空, not the keyboard's Delete: one is named after what it does, the
/// other is direct manipulation and takes whole rows with it.
TextEditingValue? tableClearCells(
  TextEditingValue raw, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  if (range != null) return _clearCells(range);
  final ({TableBlock block, int row, int column, TableCell cell})? active =
      tableActiveCell(v, resolve: resolve);
  if (active == null) return null;
  return _valueOf(
    TableCommands.clearRect(
      active.block,
      fromRow: active.row,
      toRow: active.row,
      fromColumn: active.column,
      toColumn: active.column,
    ),
  );
}

/// Interprets an edit that arrived over a **multi-cell** selection, or returns
/// `null` when the selection is not a table block.
///
/// The platform's own replacement would splice the text across pipes: typing
/// `x` over three selected cells would leave `| x |  |` with the source's
/// pipes and a different number of columns. So the edit is read as "what was
/// inserted over this rectangle" and replayed through the grid:
///
/// * the whole range disappeared → [tableRangeClear];
/// * anything else → [tableRangeReplace] with the inserted run.
///
/// Only an edit that is exactly `before + inserted + after` is recognised, with
/// the caret sitting immediately after the inserted run. Undo and redo also
/// hand the formatter a newValue built from an *older* document, with the
/// selection that document had; a kept rectangle there looks exactly like a
/// replacement of the whole range, and replaying it wrote the restored document
/// into a single cell — Ctrl+Z after a rectangle clear corrupted the table.
/// The editor suspends this reading while it runs a history intent, and
/// anything still unrecognised falls through untouched: blocking it would turn
/// an undo from some other surface into a no-op.
///
/// A deletion needs no caret guard: restoring the original is `before +
/// original + after`, never `before + after`, so only the original clear (or
/// its redo) matches, and [tableRangeClear] is idempotent.
TextEditingValue? tableSelectionEdit(
  TextEditingValue oldValue,
  TextEditingValue newValue, {
  TableRangeResolver? resolve,
}) {
  final TableRange? range = tableRangeOf(oldValue, resolve: resolve);
  if (range == null) return null;
  if (newValue.text == oldValue.text) return newValue;

  final TextSelection selection = oldValue.selection;
  final String before = selection.textBefore(oldValue.text);
  final String after = selection.textAfter(oldValue.text);
  final String gone = before + after;
  if (newValue.text == gone) return tableRangeClear(range);
  if (newValue.text.length < before.length + after.length ||
      !newValue.text.startsWith(before) ||
      !newValue.text.endsWith(after)) {
    return newValue;
  }
  final String inserted = newValue.text.substring(
    before.length,
    newValue.text.length - after.length,
  );
  // The platform puts the caret at the end of what it inserted; a restored
  // value carries the caret it was recorded with.
  if (!newValue.selection.isCollapsed ||
      newValue.selection.baseOffset != before.length + inserted.length) {
    return newValue;
  }
  final TextEditingValue replaced = tableRangeReplace(range, inserted);
  if (!newValue.composing.isValid) return replaced;
  // Keep the preedit marked inside the active cell. Closing the composition
  // left the engine with no range to replace, so its next preedit landed next
  // to the previous one ('n' → 'nni') and the commit inherited the leftovers.
  final int end = replaced.selection.isCollapsed
      ? replaced.selection.baseOffset
      : replaced.selection.extentOffset;
  return replaced.copyWith(
    composing: TextRange(start: math.max(0, end - inserted.length), end: end),
  );
}

/// The largest grid a single paste may build. Beyond it the edit is refused
/// whole rather than freezing the editor while a block nobody can read is
/// parsed, rendered and laid out.
const int maxPasteGridRows = 500;
const int maxPasteGridCells = 20000;

/// Why [pasted] would build a grid too large to insert, or `null` when it is
/// safe (or not a grid at all).
///
/// Counted from the text itself: handing a huge clipboard to [_pastedGrid]
/// would allocate the very grid this guard exists to avoid.
String? pasteGridRefusal(String pasted) {
  final List<String> lines = pasted.replaceAll('\r\n', '\n').split('\n');
  final List<String> meaningful = <String>[
    for (final String line in lines)
      if (line.trim().isNotEmpty) line,
  ];
  final bool markdown =
      lines.isNotEmpty &&
      isTableLine(lines.first) &&
      ((lines.length > 1 && isDividerLine(lines[1])) ||
          lines.where(isTableLine).length >= 2);
  final bool tsv =
      !markdown &&
      meaningful.length >= 2 &&
      meaningful.first.split('\t').length >= 2;
  if (!markdown && !tsv) return null;

  final int rows;
  final int columns;
  if (markdown) {
    final List<String> rowLines = <String>[];
    for (final String line in lines) {
      if (!isTableLine(line)) break;
      rowLines.add(line);
    }
    rows = rowLines.where((String line) => !isDividerLine(line)).length;
    columns = rowLines.fold<int>(
      0,
      (int max, String line) => math.max(max, cellsOfLine(line).length),
    );
  } else {
    rows = meaningful.length;
    columns = meaningful.first.split('\t').length;
  }

  if (rows <= maxPasteGridRows && rows * columns <= maxPasteGridCells) {
    return null;
  }
  return '粘贴内容过大：$rows 行 × $columns 列'
      '（最多 $maxPasteGridRows 行、$maxPasteGridCells 格）';
}

/// [pasted] with the blank line a **table** needs to stay a table of its own.
///
/// Markdown has no "end of table" token: two tables with nothing between them
/// are one table. So a block pasted on the line under a table used to grow that
/// table by its rows with an empty right-hand column, and the two tables became
/// one — user: 「如果是在表格的下一行粘贴的话，会把两个表格连在一起」.
String padTablePaste(String text, int at, String pasted) {
  if (pasted.isEmpty || !isTableLine(pasted.split('\n').first)) return pasted;
  String out = pasted;
  final int lineStart = lineStartOf(text, at);
  if (lineStart > 0) {
    final String above = text.substring(
      lineStartOf(text, lineStart - 1),
      lineStart - 1,
    );
    if (isTableLine(above) && !out.startsWith('\n')) out = '\n$out';
  }
  final int lineEnd = lineEndOf(text, at);
  if (lineEnd < text.length) {
    final String below = text.substring(
      lineEnd + 1,
      lineEndOf(text, lineEnd + 1),
    );
    if (isTableLine(below) && !out.endsWith('\n\n')) {
      out = out.endsWith('\n') ? '$out\n' : '$out\n\n';
    }
  }
  return out;
}

/// The pasted block as a grid: a Markdown table, or TSV from a spreadsheet.
TableGrid? _pastedGrid(String pasted) {
  if (isMarkdownTable(pasted)) return gridFromMarkdown(pasted.trim());
  final List<List<String>>? tsv = gridFromTsv(pasted);
  if (tsv == null) return null;
  return TableGrid(
    rows: tsv,
    aligns: List<TableAlign>.filled(tsv.first.length, TableAlign.none),
    header: true,
  );
}

/// [v] with [pasted] dropped in at its selection.
///
/// The rules, in order:
///
/// * a paste **inside a table** joins that table when the widths match (the
///   copy's header is dropped — a table has exactly one), and lands as a table
///   of its own below it when they do not;
/// * a paste on the line right under a table joins it the same way;
/// * a paste **inside a cell** has its line breaks turned into `<br>`: one cell
///   is one line, and a raw newline would slice the row in half;
/// * anywhere else, a table is pasted with a blank line on the side that faces
///   another table, so the two never fuse.
TextEditingValue pasteValue(
  TextEditingValue v,
  String pasted, {
  TableRangeResolver? resolve,
}) {
  if (pasteGridRefusal(pasted) != null) return v;
  final String text = v.text;
  final int a = (v.selection.start < 0 ? text.length : v.selection.start).clamp(
    0,
    text.length,
  );
  final int b = (v.selection.end < 0 ? text.length : v.selection.end).clamp(
    0,
    text.length,
  );
  final int from = a < b ? a : b;
  final int to = a < b ? b : a;

  final TableGrid? grid = _pastedGrid(pasted);

  // A selection that covers more than one cell is a **rectangle**: the paste
  // fills it from the active cell and clears the rest. It must never reach the
  // "join the table below" rules — those answer a caret, not a range, and they
  // would append the clipboard under a table whose cells the user just lit.
  // The resolver lets a column-grip selection paste **as a column**.
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  if (range != null) {
    return _valueOf(
      TableCommands.writeRect(
        range.block,
        fromRow: range.firstRow,
        toRow: range.lastRow,
        fromColumn: range.firstColumn,
        toColumn: range.lastColumn,
        atRow: range.anchorRow,
        atColumn: range.anchorColumn,
        values:
            grid?.rows ??
            <List<String>>[
              <String>[unescapeCell(pasted.replaceAll('\r\n', '\n'))],
            ],
      ),
    );
  }

  if (grid == null) {
    // Plain text. Inside a cell its newlines would break the row, and a raw
    // `|` would end the cell outright; both are escaped the GFM way.
    final TableBlock? cell = TableBlock.parse(text, from);
    if (cell != null) {
      final String flat = escapeCell(pasted.replaceAll('\r\n', '\n'));
      return TextEditingValue(
        text: text.replaceRange(from, to, flat),
        selection: TextSelection.collapsed(offset: from + flat.length),
      );
    }
    return TextEditingValue(
      text: text.replaceRange(from, to, pasted),
      selection: TextSelection.collapsed(offset: from + pasted.length),
    );
  }

  final String block = grid.render();
  // The host table: the one the caret is in, or the one directly above it.
  TableBlock? host = TableBlock.parse(text, from);
  if (host == null && from > 0) {
    final TableBlock? above = TableBlock.parse(text, from - 1);
    if (above != null && from == above.end + 1) host = above;
  }
  if (host != null) {
    // A blank last row is a placeholder left by Enter or Tab, not data. Drop it
    // first: that is what lets a block of a different width take the row's
    // place instead of leaving an empty row between the two tables.
    String base = text;
    TableBlock target = host;
    final TableRow last = host.bodyRows.last;
    final bool blankTail = last.cells.every((TableCell c) => c.isEmpty);
    if (blankTail && from >= last.start && from <= last.end) {
      final int cut = last.start > 0 ? last.start - 1 : 0;
      base = text.replaceRange(cut, last.end, '');
      target = TableBlock.parse(base, host.start.clamp(0, base.length)) ?? host;
    }

    if (grid.columns == target.columns) {
      // Join. The copy's header goes (a table has exactly one), and so does the
      // newline that ended the table — the joined rows are its new end.
      TableBlock joinedHost = target;
      String joinBase = base;
      if (joinedHost.end == joinBase.length - 1 && joinBase.endsWith('\n')) {
        joinBase = joinBase.substring(0, joinBase.length - 1);
        joinedHost =
            TableBlock.parse(
              joinBase,
              joinedHost.start.clamp(0, joinBase.length),
            ) ??
            joinedHost;
      }
      final List<List<String>> rows = <List<String>>[...grid.rows];
      if (grid.header) rows.removeAt(0);
      final TableEditResult joined = TableCommands.appendRows(joinedHost, rows);
      final TableBlock? fresh = TableBlock.parse(
        joined.text,
        joinedHost.start.clamp(0, joined.text.length),
      );
      return TextEditingValue(
        text: joined.text,
        selection: TextSelection.collapsed(
          offset: (fresh?.end ?? joined.selection.start).clamp(
            0,
            joined.text.length,
          ),
        ),
      );
    }

    // A different width cannot join: it becomes a table of its own, above the
    // host when the caret is on the host's first line and below it otherwise —
    // always with a blank line between, or the two render as one grid.
    final bool before = from <= target.start;
    final int at;
    final String insert;
    if (before) {
      at = target.start;
      insert = '$block\n\n';
    } else if (target.end < base.length) {
      // Insert after the table's own newline, otherwise the trailing newline
      // ends up *after* the pasted block as an extra blank line.
      at = target.end + 1;
      insert = at < base.length ? '\n$block\n\n' : '\n$block';
    } else {
      at = target.end;
      insert = '\n\n$block';
    }
    final String next = base.replaceRange(at, at, insert);
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: (at + insert.length).clamp(0, next.length),
      ),
    );
  }

  final String insert = padTablePaste(text, from, block);
  final String next = text.replaceRange(from, to, insert);
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: from + insert.length),
  );
}

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
TextEditingValue? tableCellStep(TextEditingValue raw, {required bool forward}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final List<TableRow> body = block.bodyRows;
  if (body.isEmpty) return null;

  // A caret parked on the hidden divider is still *in* the table: forward goes
  // to the first row below it, backward to the last row above it — never into
  // the dashes, which hold no cells.
  final bool onDivider = block.rows.any(
    (TableRow r) =>
        r.divider && v.selection.start >= r.start && v.selection.start <= r.end,
  );
  if (onDivider) {
    if (forward) {
      final int r = body.indexWhere(
        (TableRow x) => x.start > v.selection.start,
      );
      final TableRow target = body[r < 0 ? body.length - 1 : r];
      return TextEditingValue(
        text: v.text,
        selection: _cellSelection(target.cells.first),
      );
    }
    final int r = body.lastIndexWhere(
      (TableRow x) => x.end < v.selection.start,
    );
    final TableRow target = body[r < 0 ? 0 : r];
    return TextEditingValue(
      text: v.text,
      selection: _cellSelection(target.cells.last),
    );
  }

  final (int row, int column) = _cellOf(block, v.selection.start);

  if (!forward) {
    if (column > 0) {
      return TextEditingValue(
        text: v.text,
        selection: _cellSelection(body[row].cells[column - 1]),
      );
    }
    if (row > 0) {
      final List<TableCell> cells = body[row - 1].cells;
      return TextEditingValue(
        text: v.text,
        selection: _cellSelection(cells[cells.length - 1]),
      );
    }
    return TextEditingValue(
      text: v.text,
      selection: _cellSelection(body.first.cells.first),
    );
  }

  if (column + 1 < body[row].cells.length) {
    return TextEditingValue(
      text: v.text,
      selection: _cellSelection(body[row].cells[column + 1]),
    );
  }
  if (row + 1 < body.length) {
    return TextEditingValue(
      text: v.text,
      selection: _cellSelection(body[row + 1].cells.first),
    );
  }
  // Past the last cell: grow the table by one row and land in its first cell.
  final TableEditResult grown = TableCommands.insertRow(
    block,
    row: row,
    above: false,
  );
  final TableBlock fresh =
      TableBlock.parse(grown.text, block.start + 1) ?? block;
  final TableRow last = fresh.bodyRows.last;
  return TextEditingValue(
    text: grown.text,
    selection: last.cells.isEmpty
        ? TextSelection.collapsed(offset: last.start)
        : _cellSelection(last.cells.first),
  );
}

/// The caret a keyboard move should leave behind: a plain collapse, or the
/// same anchor with a new moving end when Shift is held.
TextSelection _caretAt(TextSelection from, int at, bool extend) =>
    extend && from.isValid
    ? TextSelection(baseOffset: from.baseOffset, extentOffset: at)
    : TextSelection.collapsed(offset: at);

/// A caret on the collapsed divider line. The line is real only while the caret
/// is on it — that is how the dashes are edited — so cell movement leaves it
/// alone.
bool _onDivider(TableBlock block, int offset) => block.rows.any(
  (TableRow r) => r.divider && offset >= r.start && offset <= r.end,
);

/// Home / End inside a table: the line's edges are structural pixels, so the
/// caret goes to the **cell's** text edges instead of the row's pipes.
///
/// Returns `null` outside a table (and on the divider), where the normal line
/// behaviour applies.
TextEditingValue? tableCaretToCellEdge(
  TextEditingValue raw, {
  required bool end,
  bool extend = false,
}) {
  final TextEditingValue v = _normalised(raw);
  if (!v.selection.isValid) return null;
  final int caret = extend
      ? raw.selection.extentOffset.clamp(0, v.text.length)
      : v.selection.start;
  final TableBlock? block = TableBlock.parse(v.text, caret);
  if (block == null || block.bodyRows.isEmpty) return null;
  if (_onDivider(block, caret)) return null;
  final (int row, int column) = tableCellAt(block, caret, extent: false);
  final TableRow line = block.bodyRows[row];
  if (line.cells.isEmpty) return null;
  final TableCell cell = line.cells[column.clamp(0, line.cells.length - 1)];
  final int at = end ? cell.contentEnd : cell.contentStart;
  return TextEditingValue(
    text: v.text,
    selection: _caretAt(raw.selection, at, extend),
  );
}

/// Arrow Left / Right at a cell boundary: step into the neighbouring cell
/// rather than walking through the invisible padding and the pipe.
///
/// `null` means "the caret is inside the cell's text — let the field move it
/// one character", and also "outside a table". At the table's first / last
/// cell the key is consumed with no movement, which keeps the caret off the
/// structural pixels at the row's ends.
TextEditingValue? tableCaretStepCell(
  TextEditingValue raw, {
  required bool forward,
  bool extend = false,
}) {
  final TextEditingValue v = _normalised(raw);
  if (!v.selection.isValid) return null;
  if (!v.selection.isCollapsed && !extend) return null;
  final int caret = extend
      ? raw.selection.extentOffset.clamp(0, v.text.length)
      : v.selection.start;
  final TableBlock? block = TableBlock.parse(v.text, caret);
  if (block == null || block.bodyRows.isEmpty) return null;
  if (_onDivider(block, caret)) return null;
  final (int row, int column) = tableCellAt(block, caret, extent: false);
  final TableRow line = block.bodyRows[row];
  if (line.cells.isEmpty) return null;
  final int c = column.clamp(0, line.cells.length - 1);
  final TableCell cell = line.cells[c];
  final int from = cell.contentStart;
  final int to = cell.contentEnd;

  int target;
  if (forward) {
    if (caret < to) return null;
    if (c + 1 < line.cells.length) {
      target = line.cells[c + 1].contentStart;
    } else if (row + 1 < block.bodyRows.length) {
      target = block.bodyRows[row + 1].cells.isEmpty
          ? block.bodyRows[row + 1].start
          : block.bodyRows[row + 1].cells.first.contentStart;
    } else {
      target = to;
    }
  } else {
    if (caret > from) return null;
    if (c > 0) {
      target = line.cells[c - 1].contentEnd;
    } else if (row > 0) {
      final List<TableCell> above = block.bodyRows[row - 1].cells;
      target = above.isEmpty
          ? block.bodyRows[row - 1].start
          : above.last.contentEnd;
    } else {
      target = from;
    }
  }
  return TextEditingValue(
    text: v.text,
    selection: _caretAt(raw.selection, target, extend),
  );
}

/// Arrow Up / Down inside a table: the same column one body row above / below.
///
/// The divider is not a row the user can stand on — native line movement lands
/// exactly there from the first body row, reveals `| --- | --- |` and lets the
/// next keystroke edit the dashes. `null` means the move leaves the table, so
/// the normal line movement still works above the header and below the last
/// row.
TextEditingValue? tableCaretVertical(
  TextEditingValue raw, {
  required bool down,
  bool extend = false,
}) {
  final TextEditingValue v = _normalised(raw);
  if (!v.selection.isValid) return null;
  if (!v.selection.isCollapsed && !extend) return null;
  final int caret = extend
      ? raw.selection.extentOffset.clamp(0, v.text.length)
      : v.selection.start;
  final TableBlock? block = TableBlock.parse(v.text, caret);
  if (block == null || block.bodyRows.isEmpty) return null;
  if (_onDivider(block, caret)) return null;
  final (int row, int column) = tableCellAt(block, caret, extent: false);
  final int targetRow = down ? row + 1 : row - 1;
  if (targetRow < 0 || targetRow >= block.bodyRows.length) return null;
  final TableRow line = block.bodyRows[row];
  if (line.cells.isEmpty) return null;
  final TableCell cell = line.cells[column.clamp(0, line.cells.length - 1)];
  final TableRow targetLine = block.bodyRows[targetRow];
  if (targetLine.cells.isEmpty) return null;
  final TableCell targetCell =
      targetLine.cells[column.clamp(0, targetLine.cells.length - 1)];
  // Keep the position *inside the text*, not the absolute source offset: the
  // column above may be wider, and the caret should stay near the same word.
  final int within = (caret - cell.contentStart).clamp(
    0,
    cell.contentEnd - cell.contentStart,
  );
  final int at = (targetCell.contentStart + within).clamp(
    targetCell.contentStart,
    targetCell.contentEnd,
  );
  return TextEditingValue(
    text: v.text,
    selection: _caretAt(raw.selection, at, extend),
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
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final TableEditResult grown = TableCommands.insertRow(
    block,
    row: row,
    above: false,
    column: column,
  );
  // Land in the same column of the new row, with the whole cell selected so
  // typing replaces the placeholder instead of sitting next to it.
  final TableBlock fresh =
      TableBlock.parse(grown.text, block.start + 1) ?? block;
  final List<TableRow> body = fresh.bodyRows;
  final TableRow target = body[(row + 1).clamp(0, body.length - 1)];
  if (target.cells.isEmpty) {
    return TextEditingValue(
      text: grown.text,
      selection: TextSelection.collapsed(offset: target.start),
    );
  }
  return TextEditingValue(
    text: grown.text,
    selection: _cellSelection(
      target.cells[column.clamp(0, target.cells.length - 1)],
    ),
  );
}

/// The table edits the menu offers — the ones a keyboard cannot do: every row
/// has to change at once for a column, which is exactly the kind of edit nobody
/// should be doing by hand.
enum TableEdit {
  rowAbove,
  rowBelow,
  columnLeft,
  columnRight,
  deleteRow,
  deleteColumn,
}

/// Applies [op] to the table the caret is in, or returns `null` when the caret
/// is not on a table row (or a pipe-led line inside a fence, which is code).
///
/// The caret is kept in the cell it was in, so adding a column on the left does
/// not silently move the user into a different one.
TextEditingValue? editTable(TextEditingValue raw, TableEdit op) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final (int row, int column0) = _cellOf(block, v.selection.start);
  // The “+” that hangs off a table's right edge is clicked on the row's first
  // character, not inside a cell: it means "after the last column".
  final bool atRowStart = v.selection.start <= block.bodyRows[row].start;
  final int column = op == TableEdit.columnRight && atRowStart
      ? math.max(0, block.bodyRows[row].cells.length - 1)
      : column0;

  // The divider is the table's skeleton: deleting it would turn the grid back
  // into a plain run of pipes.
  final bool onDivider = block.rows.any(
    (TableRow r) =>
        r.divider && v.selection.start >= r.start && v.selection.start <= r.end,
  );
  if (op == TableEdit.deleteRow && onDivider) return null;

  final TableEditResult? result = switch (op) {
    TableEdit.rowAbove => TableCommands.insertRow(
      block,
      row: row,
      above: true,
      column: column,
    ),
    TableEdit.rowBelow => TableCommands.insertRow(
      block,
      row: row,
      above: false,
      column: column,
    ),
    TableEdit.columnLeft => TableCommands.insertColumn(
      block,
      row: row,
      column: column,
      right: false,
    ),
    TableEdit.columnRight => TableCommands.insertColumn(
      block,
      row: row,
      column: column,
      right: true,
    ),
    TableEdit.deleteRow => TableCommands.deleteRow(block, row),
    TableEdit.deleteColumn => TableCommands.deleteColumn(
      block,
      row: row,
      column: column,
    ),
  };
  return result == null ? null : _valueOf(result);
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
  final TableBlock? block = TableBlock.parse(raw.text, at);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, raw.selection.start);
  final TableEditResult? moved = TableCommands.moveRow(
    block,
    from: from,
    to: to,
    column: column,
  );
  return moved == null ? null : _valueOf(moved);
}

/// Moves one column of the table at [at] from [from] to [to].
TextEditingValue? moveTableColumn(
  TextEditingValue raw,
  int at,
  int from,
  int to,
) {
  final TableBlock? block = TableBlock.parse(raw.text, at);
  if (block == null) return null;
  final (int row, _) = _cellOf(block, raw.selection.start);
  final TableEditResult? moved = TableCommands.moveColumn(
    block,
    from: from,
    to: to,
    row: row,
  );
  return moved == null ? null : _valueOf(moved);
}

/// Sets the alignment of the caret's column — the edit the divider row used to
/// make impossible to reach.
TextEditingValue? setTableAlign(TextEditingValue raw, TableAlign align) {
  final TableBlock? block = TableBlock.parse(raw.text, raw.selection.start);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, raw.selection.start);
  return _valueOf(
    TableCommands.setAlign(block, row: row, column: column, align: align),
  );
}

/// Sets the alignment of every column the selection covers — 对齐 on a block of
/// cells has to be one edit, not N menu trips.
TextEditingValue? setTableAlignRange(
  TextEditingValue raw,
  TableAlign align, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  if (range == null) return setTableAlign(v, align);
  final (int row, int column) = _cellOf(block, v.selection.start);
  return _valueOf(
    TableCommands.setAlignRange(
      block,
      from: range.firstColumn,
      to: range.lastColumn,
      row: row,
      column: column,
      align: align,
    ),
  );
}

/// Removes the table the caret is in, newline included.
TextEditingValue? deleteTableAt(TextEditingValue raw) {
  final TableBlock? block = TableBlock.parse(raw.text, raw.selection.start);
  if (block == null) return null;
  return _valueOf(TableCommands.deleteTable(block));
}

/// Sorts the table at the caret by the column it sits in.
TextEditingValue? sortTable(TextEditingValue raw, {required bool ascending}) {
  final TableBlock? block = TableBlock.parse(raw.text, raw.selection.start);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, raw.selection.start);
  final TableEditResult? sorted = TableCommands.sortRows(
    block,
    column: column,
    ascending: ascending,
    row: row,
  );
  return sorted == null ? null : _valueOf(sorted);
}

/// Swaps the table's rows and columns.
TextEditingValue? transposeTable(TextEditingValue raw) {
  final TableBlock? block = TableBlock.parse(raw.text, raw.selection.start);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, raw.selection.start);
  return _valueOf(TableCommands.transpose(block, row: row, column: column));
}

/// Aligns each column by its data: numeric columns right, the rest left.
TextEditingValue? autoAlignTable(TextEditingValue raw) {
  final TableBlock? block = TableBlock.parse(raw.text, raw.selection.start);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, raw.selection.start);
  return _valueOf(TableCommands.autoAlign(block, row: row, column: column));
}

/// Appends a summary row for the caret's column.
TextEditingValue? summarizeTable(
  TextEditingValue raw,
  TableAggregate aggregate,
) {
  final TableBlock? block = TableBlock.parse(raw.text, raw.selection.start);
  if (block == null) return null;
  final (_, int column) = _cellOf(block, raw.selection.start);
  final TableEditResult? result = TableCommands.appendAggregate(
    block,
    column: column,
    aggregate: aggregate,
  );
  return result == null ? null : _valueOf(result);
}

/// The selected cells as tab-separated values — the shape a spreadsheet
/// understands. `null` when the selection is not a block of cells.
String? tableSelectionTsv(
  String text,
  TextSelection selection, {
  TableRangeResolver? resolve,
}) => tableRangeOf(
  TextEditingValue(text: text, selection: selection),
  resolve: resolve,
)?.tsv;

/// Ctrl+D / Ctrl+R: copy the first row down, or the first column right.
///
/// A spreadsheet fill, not a drag-handle: the source is the selection's **first
/// row/column** (or, for a one-row/one-column selection, the line just outside
/// it), and the selection stays lit over the written rectangle. A collapsed
/// caret copies the cell above/left — the smallest fill there is.
///
/// Returns `null` when there is nothing to fill from, or when the selection is
/// a slice of one cell: that is ordinary text editing and the key must not
/// rewrite the table under it.
TextEditingValue? tableFill(
  TextEditingValue raw, {
  required bool down,
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  if (range != null) {
    final List<List<String>>? values = down
        ? _fillDownValues(range)
        : _fillRightValues(range);
    if (values == null) return null;
    final TableEditResult written = TableCommands.writeRect(
      range.block,
      fromRow: range.firstRow,
      toRow: range.lastRow,
      fromColumn: range.firstColumn,
      toColumn: range.lastColumn,
      atRow: range.firstRow,
      atColumn: range.firstColumn,
      values: values,
    );
    final TableBlock? fresh = TableBlock.parse(
      written.text,
      range.block.start.clamp(0, written.text.length),
    );
    if (fresh == null) return _valueOf(written);
    return TextEditingValue(
      text: written.text,
      selection: TableRange.rect(
        fresh,
        fromRow: range.firstRow,
        toRow: range.lastRow,
        fromColumn: range.firstColumn,
        toColumn: range.lastColumn,
        activeRow: range.anchorRow,
        activeColumn: range.anchorColumn,
      ).toTextSelection(),
    );
  }

  if (!v.selection.isCollapsed) return null;
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null || block.bodyRows.isEmpty) return null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final int sourceRow = down ? row - 1 : row;
  final int sourceColumn = down ? column : column - 1;
  if (sourceRow < 0 || sourceColumn < 0) return null;
  final List<TableRow> body = block.bodyRows;
  if (sourceRow >= body.length) return null;
  final List<TableCell> cells = body[sourceRow].cells;
  if (cells.isEmpty) return null;
  final String text = cells[sourceColumn.clamp(0, cells.length - 1)].text;
  return _valueOf(
    TableCommands.writeRect(
      block,
      fromRow: row,
      toRow: row,
      fromColumn: column,
      toColumn: column,
      atRow: row,
      atColumn: column,
      values: <List<String>>[
        <String>[text],
      ],
    ),
  );
}

/// Fill-down source values: the selection's first row, or the row above a
/// one-row selection.
List<List<String>>? _fillDownValues(TableRange range) {
  if (range.lastRow > range.firstRow) {
    final List<String> source = range.values.first;
    return <List<String>>[
      for (int r = range.firstRow; r <= range.lastRow; r++)
        List<String>.of(source),
    ];
  }
  if (range.firstRow == 0) return null;
  final TableRow above = range.block.bodyRows[range.firstRow - 1];
  return <List<String>>[
    <String>[
      for (int c = range.firstColumn; c <= range.lastColumn; c++)
        c < above.cells.length ? above.cells[c].text : '',
    ],
  ];
}

/// Fill-right source values: each row's first selected cell, or the cell to the
/// left of a one-column selection.
List<List<String>>? _fillRightValues(TableRange range) {
  if (range.lastColumn > range.firstColumn) {
    return <List<String>>[
      for (int r = range.firstRow; r <= range.lastRow; r++)
        <String>[
          for (int c = range.firstColumn; c <= range.lastColumn; c++)
            range.textAt(r, range.firstColumn),
        ],
    ];
  }
  if (range.firstColumn == 0) return null;
  return <List<String>>[
    for (int r = range.firstRow; r <= range.lastRow; r++)
      <String>[range.textAt(r, range.firstColumn - 1)],
  ];
}

/// Inserts as many rows as the selection covers, above or below it.
TextEditingValue? tableInsertRows(
  TextEditingValue raw, {
  required bool above,
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  // A column selection spans every row, but it is not a row selection: insert
  // one row, not one per row on screen.
  final TableRange? rows = range != null && !range.isColumns ? range : null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final int from = rows?.firstRow ?? row;
  final int to = rows?.lastRow ?? row;
  return _valueOf(
    TableCommands.insertRowsAt(
      block,
      at: above ? from : to + 1,
      count: to - from + 1,
      column: rows?.anchorColumn ?? column,
    ),
  );
}

/// Inserts as many columns as the selection covers, left or right of it.
TextEditingValue? tableInsertColumns(
  TextEditingValue raw, {
  required bool right,
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  // The mirror of the row rule: a row sweep covers every column without being
  // a column selection.
  final TableRange? columns = range != null && !range.isRows ? range : null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final int from = columns?.firstColumn ?? column;
  final int to = columns?.lastColumn ?? column;
  return _valueOf(
    TableCommands.insertColumnsAt(
      block,
      at: right ? to + 1 : from,
      count: to - from + 1,
      row: row,
    ),
  );
}

/// Copies every row the selection covers, directly below it.
TextEditingValue? tableDuplicateRows(
  TextEditingValue raw, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  final TableRange? rows = range != null && !range.isColumns ? range : null;
  final TableEditResult? result = rows == null
      ? TableCommands.duplicateRow(block, row: row, column: column)
      : TableCommands.duplicateRows(
          block,
          from: rows.firstRow,
          to: rows.lastRow,
          column: rows.anchorColumn,
        );
  return result == null ? null : _valueOf(result);
}

/// Copies every column the selection covers, directly to its right.
TextEditingValue? tableDuplicateColumns(
  TextEditingValue raw, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  final TableRange? columns = range != null && !range.isRows ? range : null;
  final TableEditResult? result = columns == null
      ? TableCommands.duplicateColumn(block, row: row, column: column)
      : TableCommands.duplicateColumns(
          block,
          from: columns.firstColumn,
          to: columns.lastColumn,
          row: row,
        );
  return result == null ? null : _valueOf(result);
}

/// Moves the selected rows one slot up ([delta] -1) or down (+1).
TextEditingValue? tableMoveRows(
  TextEditingValue raw, {
  required int delta,
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  final TableRange? rows = range != null && !range.isColumns ? range : null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final TableEditResult? result = TableCommands.moveRows(
    block,
    from: rows?.firstRow ?? row,
    to: rows?.lastRow ?? row,
    delta: delta,
    row: row,
    column: column,
  );
  return result == null ? null : _valueOf(result);
}

/// Moves the selected columns one slot left ([delta] -1) or right (+1).
TextEditingValue? tableMoveColumns(
  TextEditingValue raw, {
  required int delta,
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  final TableRange? columns = range != null && !range.isRows ? range : null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  final TableEditResult? result = TableCommands.moveColumns(
    block,
    from: columns?.firstColumn ?? column,
    to: columns?.lastColumn ?? column,
    delta: delta,
    row: row,
    column: column,
  );
  return result == null ? null : _valueOf(result);
}

/// Removes every row the selection covers. The divider is not a row.
TextEditingValue? tableDeleteRows(
  TextEditingValue raw, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null) return null;
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  final TableRange? rows = range != null && !range.isColumns ? range : null;
  final bool onDivider = block.rows.any(
    (TableRow r) =>
        r.divider && v.selection.start >= r.start && v.selection.start <= r.end,
  );
  if (rows == null && onDivider) return null;
  final (int row, _) = _cellOf(block, v.selection.start);
  return _valueOf(
    TableCommands.deleteRows(
      block,
      rows?.firstRow ?? row,
      rows?.lastRow ?? row,
    ),
  );
}

/// Removes every column the selection covers. The last column cannot go: a
/// table needs at least one cell.
TextEditingValue? tableDeleteColumns(
  TextEditingValue raw, {
  TableRangeResolver? resolve,
}) {
  final TextEditingValue v = _normalised(raw);
  final TableBlock? block = TableBlock.parse(v.text, v.selection.start);
  if (block == null || block.columns <= 1) return null;
  final TableRange? range = tableRangeOf(v, resolve: resolve);
  final TableRange? columns = range != null && !range.isRows ? range : null;
  final (int row, int column) = _cellOf(block, v.selection.start);
  return _valueOf(
    TableCommands.deleteColumns(
      block,
      from: columns?.firstColumn ?? column,
      to: columns?.lastColumn ?? column,
      row: row,
    ),
  );
}

/// The text a stats strip or menu row shows for [range].
String tableStatsLabel(TableRange range) {
  final TableStats stats = range.stats;
  final List<String> parts = <String>[
    '${range.rowCount}×${range.columnCount}',
    '${stats.filled} 格非空',
  ];
  if (stats.hasNumbers) {
    parts.add('合计 ${formatNumber(stats.sum!)}');
    parts.add('平均 ${formatNumber(stats.average!)}');
  }
  return parts.join(' · ');
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
        text.substring(0, at) +
        lead +
        snippet +
        text.substring(v.selection.end);
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

/// Tab / Shift+Tab indentation inside lists.
///
/// Indenting changes an item's *level*, not its number — the number is literal
/// source text that the renderer prints as written. Without a renumber pass an
/// ordered list drifts into `1, 2, 3, 5, 5, 6, 3` after a few Tab round trips,
/// so every indent renumbers the list block it lands in: one counter per
/// nesting level, each counting from 1 again.
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
        line.startsWith('  ')
            ? line.substring(2)
            : line.replaceFirst(RegExp(r'^\s'), ''),
      );
    } else if (line.trim().isEmpty) {
      out.write(line);
    } else {
      out.write('  $line');
    }
    if (i != lines.length - 1) out.write('\n');
  }
  final String indented =
      text.substring(0, firstLine) + out.toString() + text.substring(blockEnd);
  final int delta = indented.length - text.length;
  final ({String text, List<({int at, int delta})> shifts}) numbered =
      _renumberOrderedList(indented, firstLine, blockEnd + delta);
  final String result = numbered.text;

  // Every number that changed width moves the text after it; the caret and the
  // selection follow by the sum of the shifts that happen before them.
  int follow(int offset) {
    int moved = offset;
    for (final ({int at, int delta}) shift in numbered.shifts) {
      if (offset > shift.at) moved += shift.delta;
    }
    if (moved < 0) return 0;
    return moved > result.length ? result.length : moved;
  }

  // Tab is an edit, not a selection. With a plain caret this used to select the
  // whole line, so the next keystroke — or an IME composition — replaced the
  // line instead of editing it. The caret follows its text by the indentation's
  // own delta; only a real range keeps a block selection.
  if (v.selection.isCollapsed) {
    return TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(
        offset: follow(
          (v.selection.start + delta).clamp(firstLine, indented.length),
        ),
      ),
    );
  }
  return TextEditingValue(
    text: result,
    selection: TextSelection(
      baseOffset: follow(firstLine),
      extentOffset: follow(
        (blockEnd + delta).clamp(firstLine, indented.length),
      ),
    ),
  );
}

/// 增删整行之后，把受影响的整段有序列表重新编号。
///
/// 删掉 `16.` 那一条，下面的 `17.` 要变回 `16.`；在中间回车插进一条，后面的
/// 序号依次后移。只在“行数变了”时动手：逐字输入、只改一条内容都不重编号；
/// 粘贴整段列表时插入的不是单个换行，也保留原来的序号。
TextEditingValue renumberAfterLineChange(
  TextEditingValue oldValue,
  TextEditingValue newValue,
) {
  if (newValue.text == oldValue.text || !newValue.selection.isValid) {
    return newValue;
  }
  final int oldLines = '\n'.allMatches(oldValue.text).length;
  final int newLines = '\n'.allMatches(newValue.text).length;
  if (oldLines == newLines) return newValue;

  // 本次编辑的公共前后缀，用来定位它落在哪几行上。
  final int shorter = oldValue.text.length < newValue.text.length
      ? oldValue.text.length
      : newValue.text.length;
  int prefix = 0;
  while (prefix < shorter &&
      oldValue.text.codeUnitAt(prefix) == newValue.text.codeUnitAt(prefix)) {
    prefix++;
  }
  int suffix = 0;
  while (suffix < shorter - prefix &&
      oldValue.text.codeUnitAt(oldValue.text.length - 1 - suffix) ==
          newValue.text.codeUnitAt(newValue.text.length - 1 - suffix)) {
    suffix++;
  }
  final int newChangedEnd = newValue.text.length - suffix;

  if (newLines > oldLines) {
    // 只认“敲了一个回车”。粘贴多行时插入片段里不止一个换行，序号原样保留。
    final String inserted = newValue.text.substring(prefix, newChangedEnd);
    if ('\n'.allMatches(inserted).length != 1) return newValue;
  }

  // 代码块里的 `1. ` 是代码，不是列表。
  if (isInsideFence(oldValue.text, prefix) ||
      isInsideFence(newValue.text, prefix)) {
    return newValue;
  }

  final ({String text, List<({int at, int delta})> shifts}) numbered =
      _renumberOrderedList(
        newValue.text,
        prefix,
        newChangedEnd,
        continueFromFirst: true,
      );
  if (numbered.text == newValue.text) return newValue;

  // 序号变宽变窄会推动它后面的文字，光标按同一个位移跟着走。
  int follow(int offset) {
    int moved = offset;
    for (final ({int at, int delta}) shift in numbered.shifts) {
      if (offset > shift.at) moved += shift.delta;
    }
    return moved.clamp(0, numbered.text.length);
  }

  final TextSelection selection = newValue.selection;
  return TextEditingValue(
    text: numbered.text,
    selection: TextSelection(
      baseOffset: follow(selection.baseOffset),
      extentOffset: follow(selection.extentOffset),
      affinity: selection.affinity,
    ),
  );
}

/// Rewrites every ordered item in the list block that holds the lines
/// `[from]..[to]` of [text], so each nesting level counts 1, 2, 3 again.
///
/// A blank line does not end a list (a loose list is still one list); anything
/// else does. [shifts] reports each number whose width changed, at its offset in
/// [text], so the caller can keep the caret beside the digits it was next to.
///
/// [continueFromFirst] keeps the number the block already starts at and counts
/// up from there, instead of restarting every level at 1. Deleting an item is
/// exactly that case: a list that starts at `15.` must stay at 15 and close the
/// gap the deletion left, not turn into `1.`.
({String text, List<({int at, int delta})> shifts}) _renumberOrderedList(
  String text,
  int from,
  int to, {
  bool continueFromFirst = false,
}) {
  const List<({int at, int delta})> none = <({int at, int delta})>[];
  final List<String> lines = text.split('\n');
  final List<int> starts = <int>[];
  int offset = 0;
  for (final String line in lines) {
    starts.add(offset);
    offset += line.length + 1;
  }

  int lineAt(int position) {
    final int at = position < 0
        ? 0
        : (position > text.length ? text.length : position);
    int i = 0;
    while (i + 1 < starts.length && starts[i + 1] <= at) {
      i++;
    }
    return i;
  }

  bool isList(int i) {
    final LineMarkerKind kind = scanLineMarker(lines[i]).kind;
    return kind == LineMarkerKind.bullet ||
        kind == LineMarkerKind.ordered ||
        kind == LineMarkerKind.task;
  }

  bool isBlank(int i) => lines[i].trim().isEmpty;

  int first = lineAt(from);
  int last = lineAt(to);
  // Tab on a paragraph is still plain indentation: only an edit that lands on a
  // list line renumbers anything.
  bool touchesList = false;
  for (int i = first; i <= last; i++) {
    if (isList(i)) {
      touchesList = true;
      break;
    }
  }
  if (!touchesList) return (text: text, shifts: none);

  // Widen to the whole list: an indented item changes the siblings above and
  // below it, not just its own line.
  while (first > 0 && (isBlank(first - 1) || isList(first - 1))) {
    first--;
  }
  while (last + 1 < lines.length && (isBlank(last + 1) || isList(last + 1))) {
    last++;
  }

  /// One counter per nesting level, in the order the levels open.
  final List<({int indent, int number})> levels =
      <({int indent, int number})>[];
  final List<({int at, int delta})> shifts = <({int at, int delta})>[];
  final RegExp lead = RegExp(r'^(\s*)(\d{1,9})([.)])');
  bool changed = false;

  for (int i = first; i <= last; i++) {
    if (isBlank(i)) continue;
    final LineMarker marker = scanLineMarker(lines[i]);
    // The lead is read here rather than off [marker]: a task's number is not
    // exposed for every separator (`1) [ ] x` parses as a task with no number).
    final Match? m =
        marker.kind == LineMarkerKind.ordered ||
            marker.kind == LineMarkerKind.task
        ? lead.firstMatch(lines[i])
        : null;
    if (m == null) {
      if (marker.kind != LineMarkerKind.bullet &&
          marker.kind != LineMarkerKind.task) {
        continue;
      }
      // A bullet is a different list, so an ordered item at the same level
      // after it starts over.
      while (levels.isNotEmpty && levels.last.indent > marker.indent) {
        levels.removeLast();
      }
      if (levels.isNotEmpty && levels.last.indent == marker.indent) {
        levels.removeLast();
      }
      continue;
    }

    final int indent = m.group(1)!.length;
    while (levels.isNotEmpty && levels.last.indent > indent) {
      levels.removeLast();
    }
    final int number;
    if (levels.isNotEmpty && levels.last.indent == indent) {
      number = levels.last.number + 1;
      levels[levels.length - 1] = (indent: indent, number: number);
    } else {
      number = continueFromFirst ? int.parse(m.group(2)!) : 1;
      levels.add((indent: indent, number: number));
    }

    final int oldWidth = m.group(2)!.length;
    if (number == int.parse(m.group(2)!)) continue;
    shifts.add((at: starts[i] + indent, delta: '$number'.length - oldWidth));
    lines[i] = lines[i].replaceRange(indent, indent + oldWidth, '$number');
    changed = true;
  }

  return (text: changed ? lines.join('\n') : text, shifts: shifts);
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
    final bool hasRange = v.selection.isValid && !v.selection.isCollapsed;
    final int start = hasRange
        ? v.selection.start
        : lineStartOf(text, v.selection.start);
    final int end = hasRange
        ? v.selection.end
        : lineEndOf(text, v.selection.start);
    final String slice = text.substring(start, end);
    final String clean = _stripInline(slice);
    if (clean == slice) {
      return hasRange
          ? v
          : v.copyWith(
              selection: TextSelection(baseOffset: start, extentOffset: end),
            );
    }
    final String next = text.replaceRange(start, end, clean);
    return TextEditingValue(
      text: next,
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + clean.length,
      ),
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
        .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (Match m) => m[1]!)
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
