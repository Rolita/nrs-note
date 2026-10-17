/// Document-structure helpers shared by the outline panel and the renderer.
library;

class Heading {
  const Heading({
    required this.level,
    required this.text,
    required this.line,
  });

  final int level;
  final String text;
  final int line;

  String get plainText => text
      .replaceAllMapped(RegExp(r'`([^`]*)`'), (Match m) => m.group(1) ?? '')
      .replaceAll(RegExp(r'\*\*|__|\*|_|~~'), '')
      .replaceAllMapped(
        RegExp(r'\[([^\]]*)\]\([^)]*\)'),
        (Match m) => m.group(1) ?? '',
      )
      .trim();
}

final RegExp _atx = RegExp(r'^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$');
/// A setext underline promotes the line above it to a heading.
///
/// Only `===` counts. A run of `-` (and `***`, `___`) is a horizontal rule, both
/// here and in the live renderer, so that typing `---` under a paragraph draws a
/// divider instead of silently turning the paragraph into a heading.
final RegExp _setextUnderline = RegExp(r'^ {0,3}=+\s*$');
final RegExp _rule = RegExp(r'^ {0,3}(?:[-*_]\s*){3,}$');

/// Scans ATX **and** setext headings while skipping fenced code blocks, so a
/// `# comment` inside a shell snippet never shows up in the outline and the
/// order always matches what the renderer produces.
List<Heading> extractHeadings(String source) {
  final List<Heading> headings = <Heading>[];
  final List<String> lines = source.split('\n');
  String? fence;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final Match? fenceMatch = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line);
    if (fenceMatch != null) {
      final String marker = fenceMatch.group(1)!;
      if (fence == null) {
        fence = marker[0];
      } else if (marker[0] == fence) {
        fence = null;
      }
      continue;
    }
    if (fence != null) continue;

    final Match? m = _atx.firstMatch(line);
    if (m != null) {
      headings.add(
        Heading(level: m.group(1)!.length, text: m.group(2)!, line: i),
      );
      continue;
    }

    final Match? underline = _setextUnderline.firstMatch(line);
    if (underline != null && i > 0) {
      final String previous = lines[i - 1];
      final bool usablePrevious =
          previous.trim().isNotEmpty &&
          !_atx.hasMatch(previous) &&
          !_setextUnderline.hasMatch(previous) &&
          !_rule.hasMatch(previous) &&
          !RegExp(r'^\s{0,3}[-*+]\s').hasMatch(previous) &&
          !RegExp(r'^\s{0,3}>\s?').hasMatch(previous);
      if (usablePrevious) {
        headings.add(
          Heading(level: 1, text: previous.trim(), line: i - 1),
        );
      }
    }
  }
  return headings;
}

/// A task item, unordered (`- [ ] 事`) or ordered (`1. [ ] 事`).
///
/// The ordered form comes from the toolbar's "ordered task list"; the renderer
/// draws both, so every helper that hunts for checkboxes has to see both.
final RegExp _taskPrefix = RegExp(r'^(\s*(?:[-*+]|\d{1,9}[.)])\s+\[)([ xX])(\])');

/// Source line numbers (0-based) of every task-list item, in document order.
///
/// The rendered preview uses this to map a clicked checkbox back to the exact
/// line of Markdown that produced it.
List<int> taskLineNumbers(String source) {
  final List<int> lines = <int>[];
  final List<String> split = source.split('\n');
  String? fence;
  for (int i = 0; i < split.length; i++) {
    final String line = split[i];
    final Match? fenceMatch = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line);
    if (fenceMatch != null) {
      final String marker = fenceMatch.group(1)!;
      if (fence == null) {
        fence = marker[0];
      } else if (marker[0] == fence) {
        fence = null;
      }
      continue;
    }
    if (fence != null) continue;
    if (_taskPrefix.hasMatch(line)) {
      lines.add(i);
    }
  }
  return lines;
}

/// Flips `- [ ]` ⇄ `- [x]` on a single source line.
String toggleTaskOnLine(String source, int lineIndex, bool done) {
  final List<String> lines = source.split('\n');
  if (lineIndex < 0 || lineIndex >= lines.length) return source;
  final String line = lines[lineIndex];
  if (!_taskPrefix.hasMatch(line)) return source;
  lines[lineIndex] = line.replaceFirstMapped(
    _taskPrefix,
    (Match m) => '${m.group(1)}${done ? 'x' : ' '}${m.group(3)}',
  );
  return lines.join('\n');
}

/// Flips the checkbox on whichever line contains [offset], and returns the new
/// full text (unchanged if that line is not a task).
///
/// The editor's checkbox hit test only knows *which character the clicked box
/// stands in for*, not which line that was — this is the bridge. It replaces
/// exactly one character (`[ ]` ⇄ `[x]`), so every offset after it stays valid
/// and the live renderer's tree never has to shift.
String toggleTaskAt(String source, int offset) {
  if (source.isEmpty || offset < 0 || offset >= source.length) return source;
  final int lineStart = _lineStartOf(source, offset);
  final int lineEnd = _lineEndOf(source, offset);

  final String line = source.substring(lineStart, lineEnd);
  if (!_taskPrefix.hasMatch(line)) return source;
  // The bracket is the first `[` on the line — the prefix before it is only
  // indentation, the bullet (or number) and spaces, none of which contain one.
  final int at = lineStart + line.indexOf('[') + 1;
  if (at <= lineStart || at >= source.length) return source;
  return source.replaceRange(at, at + 1, source[at] == ' ' ? 'x' : ' ');
}

/// See `markdown_actions.dart`'s `lineStartOf`: offset 0 must *ignore* its
/// missing previous character rather than search for a newline at index 0,
/// which would report the line after a leading blank line instead of the blank
/// line itself.
int _lineStartOf(String text, int offset) {
  if (offset <= 0) return 0;
  final int at = offset > text.length ? text.length : offset;
  final int i = text.lastIndexOf('\n', at - 1);
  return i < 0 ? 0 : i + 1;
}

int _lineEndOf(String text, int offset) {
  final int i = text.indexOf('\n', offset.clamp(0, text.length));
  return i < 0 ? text.length : i;
}
