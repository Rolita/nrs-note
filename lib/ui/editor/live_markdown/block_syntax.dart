part of '../live_markdown.dart';

// ---------------------------------------------------------------- block kinds

/// 围栏行的语法：缩进、围栏字符与 info string。
///
/// 段落级的块判定（`_Kind`、标题/列表/引用/分隔线正则）已随 `buildLiveSpans`
/// 一起退役；按行排版由 `line_layout` 的扫描器判定块种类。
final RegExp _fenceRe = RegExp(r'^(\s{0,3})(`{3,}|~{3,})(.*)$');

/// The font size used for punctuation that is hidden. Zero, not "very small":
/// a proportional font at 0.1px still has a non-zero advance, and those slivers
/// add up into a visible wobble.
const double _kHiddenFontSize = 0;

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
