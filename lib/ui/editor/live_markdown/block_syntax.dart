part of '../live_markdown.dart';

// ---------------------------------------------------------------- block kinds

enum _Kind {
  paragraph,
  heading,
  fence,
  code,
  bullet,
  ordered,
  task,
  quote,
  rule,
  setext,
  table,
  tableHeader,
  tableDivider,
}

final RegExp _fenceRe = RegExp(r'^(\s{0,3})(`{3,}|~{3,})(.*)$');

final RegExp _headingRe = RegExp(r'^(\s{0,3})(#{1,6})(\s+)(.*?)(\s+#+\s*)?$');

final RegExp _bulletRe = RegExp(r'^(\s*)([-*+])(\s+)(.*)$');

final RegExp _taskRe = RegExp(
  r'^(\s*)([-*+]|\d{1,9}[.)])(\s+)(\[[ xX]\])(\s+)(.*)$',
);

/// Whether a task's lead-in is a number (`1.`) rather than a bullet (`-`).
///
/// The lead group is either a single bullet character or digits plus `.`/`)`,
/// so anything longer than one character is a number.
bool _isOrderedLead(String lead) => lead.length > 1;

final RegExp _orderedRe = RegExp(r'^(\s*)(\d{1,9})([.)])(\s+)(.*)$');

final RegExp _quoteRe = RegExp(r'^(\s{0,3})(>)(\s?)(.*)$');

final RegExp _ruleRe = RegExp(r'^ {0,3}(?:[-*_]\s*){3,}$');

/// A setext underline turns the line above it into a heading. Only `===` counts
/// here: a run of `-` is *always* a horizontal rule, because that is what
/// everyone who types `---` under a paragraph means, and silently promoting the
/// paragraph to a heading is the single most confusing thing this renderer can
/// do. Use `##` for a level-2 heading.
final RegExp _setextRe = RegExp(r'^ {0,3}(=+)\s*$');

/// The font size used for punctuation that is hidden. Zero, not "very small":
/// a proportional font at 0.1px still has a non-zero advance, and those slivers
/// add up into a visible wobble.
const double _kHiddenFontSize = 0;

/// A fenced code block, remembered so it can be highlighted as a whole.
class _Fence {
  _Fence({required this.open, required this.language});

  final int open;
  int close = -1;
  final String language;
  List<List<CodeToken>>? tokens;
}

/// Height of the card's header row: the band above the first line of code that
/// carries the language label. 16px — not a prose row — is what keeps the card
/// compact; the label itself is painted by `CodeBlockPainter`.
const double _kCodeHeaderHeight = 16;

/// One fenced code block's source range, fence lines included.
class CodeBlockRange {
  const CodeBlockRange({
    required this.start,
    required this.end,
    this.label,
    this.closed = true,
  });

  /// Offset of the opening fence's first character.
  final int start;

  /// Offset just past the closing fence's last character (the end of the note
  /// for a block that was never closed).
  final int end;

  /// The language the card names in its top-right corner, or `null` when the
  /// fence carried no info string.
  final String? label;

  /// False for a fence that was never closed. The block then has no closing
  /// row, which is the one thing a line-height measure has to know.
  final bool closed;
}

/// The source ranges of every fenced block, scanned with the same rule the
/// renderer uses so the slab and the text can never disagree about where a
/// block starts or ends.
List<CodeBlockRange> codeBlockRanges(String text) {
  final List<CodeBlockRange> out = <CodeBlockRange>[];
  if (!text.contains('```') && !text.contains('~~~')) return out;
  final List<String> lines = text.split('\n');
  int offset = 0;
  int open = -1;
  String? label;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final Match? f = _fenceRe.firstMatch(line);
    if (f != null) {
      if (open < 0) {
        open = offset;
        label = _codeLabel(_fenceLanguage(f.group(3) ?? ''));
      } else {
        out.add(
          CodeBlockRange(
            start: open,
            end: offset + line.length,
            label: label,
          ),
        );
        open = -1;
        label = null;
      }
    }
    offset += line.length + 1;
  }
  if (open >= 0) {
    out.add(
      CodeBlockRange(
        start: open,
        end: text.length,
        label: label,
        closed: false,
      ),
    );
  }
  return out;
}
