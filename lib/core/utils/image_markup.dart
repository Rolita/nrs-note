/// 图片靠哪一边浮动，正文从另一侧绕排。
///
/// `null`（不是这个枚举）才是「独占一行」：图片默认把下面所有文字顶开，
/// 只有明确写了 `align="left|right"` 才让正文挤到旁边去。
enum ImageAlign {
  left,
  right;

  static ImageAlign? parse(String? raw) => switch (raw?.trim().toLowerCase()) {
    'left' => ImageAlign.left,
    'right' => ImageAlign.right,
    _ => null,
  };
}

/// A line that consists of exactly one image, either Markdown
/// `![alt](source)` or a single `<img …>` tag.
///
/// This is pure value logic: the editor uses it to decide whether a paragraph
/// should be drawn as a picture, and to rewrite that line when its width is
/// changed. Anything that is not the *whole* line is ordinary source text.
class ImageMarkup {
  const ImageMarkup({
    required this.source,
    this.alt,
    this.width,
    this.align,
  });

  /// `assets/x.png`, `https://…`, `data:…`.
  final String source;

  /// Alt text, `null` when the syntax has none or it is empty.
  final String? alt;

  /// Width in logical pixels as written in the source, `null` when the line
  /// does not declare one.
  final double? width;

  /// 靠边浮动；`null` 表示独占一行。
  ///
  /// 有它时这一行不再占一整行高度：图片贴在左/右栏，后面几行正文在另一侧
  /// 绕排，直到文字越过图片底部。这就是「左文字右图片」的排版来源。
  final ImageAlign? align;

  bool get isExternal {
    final String lower = source.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:');
  }

  /// Parses [lineText] as one image line. Leading/trailing whitespace is
  /// ignored; any other content makes this return null.
  static ImageMarkup? parseLine(String lineText) {
    final String line = lineText.trim();
    if (line.isEmpty) return null;
    if (line.startsWith('![')) return _parseMarkdown(line);
    if (line.toLowerCase().startsWith('<img')) return _parseTag(line);
    return null;
  }

  /// The line to write in place of the source line.
  ///
  /// Without a width this is standard Markdown; with one it is an `<img>` tag
  /// so the width survives in other Markdown tools.
  ///
  /// [asTag] forces the tag form even when there is no width. The editor uses
  /// it when **inserting** an image: this app already writes a tag the moment
  /// the width is dragged, and switching syntax between "just pasted" and
  /// "resized once" would make the same picture look like two different
  /// things in the same file.
  String toMarkdown({double? width, bool asTag = false, ImageAlign? align}) {
    final double? effective = width ?? this.width;
    final ImageAlign? side = align ?? this.align;
    final String altText = alt ?? '';
    final String escapedAlt = _escapeAlt(altText);
    // 靠边浮动只能写在标签里，`![…](…)` 没有放属性的地方。
    if (effective == null && !asTag && side == null) {
      final String destination = _needsAngles(source) ? '<$source>' : source;
      return '![$escapedAlt]($destination)';
    }
    final StringBuffer out = StringBuffer('<img src="$source"');
    if (effective != null) out.write(' width="${_formatWidth(effective)}"');
    if (side != null) out.write(' align="${side.name}"');
    if (altText.isNotEmpty) out.write(' alt="$escapedAlt"');
    out.write('>');
    return out.toString();
  }

  static ImageMarkup? _parseMarkdown(String line) {
    int i = 2;
    final StringBuffer alt = StringBuffer();
    bool closed = false;
    while (i < line.length) {
      final String ch = line[i];
      if (ch == r'\' && i + 1 < line.length) {
        alt.write(line[i + 1]);
        i += 2;
        continue;
      }
      if (ch == ']') {
        closed = true;
        i++;
        break;
      }
      alt.write(ch);
      i++;
    }
    if (!closed || i >= line.length || line[i] != '(') return null;
    i++;

    String source;
    if (i < line.length && line[i] == '<') {
      final int close = line.indexOf('>', i + 1);
      if (close < 0) return null;
      source = line.substring(i + 1, close);
      i = close + 1;
    } else {
      final int start = i;
      int depth = 0;
      while (i < line.length) {
        final String ch = line[i];
        if (ch == r'\' && i + 1 < line.length) {
          i += 2;
          continue;
        }
        if (ch == '(') {
          depth++;
        } else if (ch == ')') {
          if (depth == 0) break;
          depth--;
        } else if ((ch == ' ' || ch == '\t') && depth == 0) {
          break;
        }
        i++;
      }
      source = line.substring(start, i);
    }

    while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
      i++;
    }
    if (i >= line.length) return null;

    if (line[i] == ')') {
      i++;
    } else {
      final String quote = line[i];
      if (quote != '"' && quote != "'" && quote != '(') return null;
      final String close = quote == '(' ? ')' : quote;
      i++;
      while (i < line.length && line[i] != close) {
        if (line[i] == r'\') i++;
        i++;
      }
      if (i >= line.length) return null;
      i++;
      while (i < line.length && (line[i] == ' ' || line[i] == '\t')) {
        i++;
      }
      if (i >= line.length || line[i] != ')') return null;
      i++;
    }

    if (i != line.length) return null;
    if (source.trim().isEmpty) return null;
    final String decodedAlt = _decodeAlt(alt.toString());
    return ImageMarkup(
      source: source.trim(),
      alt: decodedAlt.isEmpty ? null : decodedAlt,
    );
  }

  static ImageMarkup? _parseTag(String line) {
    if (line.length < 5 || !_isSpace(line[4])) return null;
    int i = 4;
    bool closed = false;
    final Map<String, String?> attributes = <String, String?>{};

    while (i < line.length) {
      while (i < line.length && _isSpace(line[i])) {
        i++;
      }
      if (i >= line.length) return null;
      if (line[i] == '>') {
        i++;
        closed = true;
        break;
      }
      if (line[i] == '/' && i + 1 < line.length && line[i + 1] == '>') {
        i += 2;
        closed = true;
        break;
      }

      final int nameStart = i;
      while (i < line.length && _isAttributeName(line[i])) {
        i++;
      }
      if (i == nameStart) return null;
      final String name = line.substring(nameStart, i).toLowerCase();

      while (i < line.length && _isSpace(line[i])) {
        i++;
      }
      String? value;
      if (i < line.length && line[i] == '=') {
        i++;
        while (i < line.length && _isSpace(line[i])) {
          i++;
        }
        if (i >= line.length) return null;
        final String quote = line[i];
        if (quote == '"' || quote == "'") {
          i++;
          final int start = i;
          while (i < line.length && line[i] != quote) {
            i++;
          }
          if (i >= line.length) return null;
          value = line.substring(start, i);
          i++;
        } else {
          final int start = i;
          while (i < line.length &&
              !_isSpace(line[i]) &&
              line[i] != '>' &&
              !(line[i] == '/' && i + 1 < line.length && line[i + 1] == '>')) {
            i++;
          }
          value = line.substring(start, i);
        }
      }
      attributes[name] = value;
    }

    if (!closed || i != line.length) return null;
    final String? source = attributes['src'];
    if (source == null || source.trim().isEmpty) return null;

    double? width;
    if (attributes.containsKey('width')) {
      final String? raw = attributes['width'];
      if (raw == null) return null;
      width = _parseWidth(raw);
      if (width == null) return null;
    }
    final String? alt = attributes['alt'];
    return ImageMarkup(
      source: source.trim(),
      alt: alt == null || alt.isEmpty ? null : _decodeAlt(alt),
      width: width,
      // 认不出的对齐值（`center`、`absmiddle`）当作没写：一行 `<img>` 不该
      // 因为一个不认识的属性就整行退回源码。
      align: ImageAlign.parse(attributes['align']),
    );
  }

  static bool _isSpace(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';

  static bool _isAttributeName(String ch) {
    final int code = ch.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A) ||
        ch == '-' ||
        ch == '_' ||
        ch == ':' ||
        ch == '.';
  }

  static double? _parseWidth(String raw) {
    String value = raw.trim();
    if (value.toLowerCase().endsWith('px')) {
      value = value.substring(0, value.length - 2).trim();
    }
    final double? parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }

  static String _decodeAlt(String raw) =>
      raw.replaceAll('&quot;', '"').replaceAll(r'\\', r'\');

  static String _escapeAlt(String alt) => alt
      .replaceAll(r'\', r'\\')
      .replaceAll('"', '&quot;')
      .replaceAll(']', r'\]');

  static bool _needsAngles(String source) =>
      source.contains(RegExp(r'[\s()<>]'));

  static String _formatWidth(double width) {
    if (width == width.roundToDouble()) return width.round().toString();
    return width.toString();
  }
}

/// Inserts [imageLine] at `[at, end)` with a blank line on either side so the
/// image owns its own paragraph.
///
/// At the very end of a document a trailing newline is always added, even when
/// the caret is already at a line start: the caret has to land on the next
/// line, so the first keystroke after the paste starts a paragraph instead of
/// being appended to the image's own line.
({String text, int caret}) insertImageBlock({
  required String text,
  required int at,
  required int end,
  required String imageLine,
}) {
  final String prefix = at > 0 && text[at - 1] != '\n' ? '\n' : '';
  String suffix = end < text.length && text[end] != '\n' ? '\n' : '';
  if (at == end && at == text.length) suffix = '\n';
  final String next =
      text.substring(0, at) + prefix + imageLine + suffix + text.substring(end);
  return (
    text: next,
    caret: at + prefix.length + imageLine.length + suffix.length,
  );
}

/// 把 `[lineStart, lineEnd)` 这一整行搬到 [insertAt]（另一行的行首）。
///
/// 搬的是**整行连同它自己的换行**：图片是一整块，搬走不能留下空段落，搬过去
/// 也得自成一个段落。返回新的正文、搬完后这一行的新行首，以及这次搬动的净位移
/// （新行首 − 旧行首，编辑器据此把光标和选中态一起挪过去）。
///
/// 搬不动时返回 `null`：落点就在这一行自己身上，或者紧挨着它（搬了等于没搬）。
({String text, int caret, int delta})? moveSourceLine({
  required String text,
  required int lineStart,
  required int lineEnd,
  required int insertAt,
}) {
  if (lineStart < 0 ||
      lineEnd < lineStart ||
      lineEnd > text.length ||
      insertAt < 0 ||
      insertAt > text.length) {
    return null;
  }
  // 落点就是自己这一行的行首，或者紧跟着自己的下一行行首：原地不动。
  final int ownEnd = lineEnd < text.length ? lineEnd + 1 : lineEnd;
  if (insertAt == lineStart || insertAt == ownEnd) return null;

  final String line = text.substring(lineStart, lineEnd);
  // 这一行有没有自己的换行可带走；没有（文末最后一行）就带走上一行那个。
  final bool hasNewline = lineEnd < text.length;
  final int cutFrom = hasNewline
      ? lineStart
      : (lineStart > 0 ? lineStart - 1 : lineStart);
  final int cutTo = hasNewline ? lineEnd + 1 : lineEnd;
  if (cutTo <= cutFrom) return null;
  final String rest = text.replaceRange(cutFrom, cutTo, '');

  // 落点在新正文里的偏移：删掉的那一段在它前面，就整体左移。
  final int removed = cutTo - cutFrom;
  int at = insertAt >= cutTo ? insertAt - removed : insertAt;
  at = at.clamp(0, rest.length);

  final String before = rest.substring(0, at);
  final String after = rest.substring(at);
  final StringBuffer out = StringBuffer(before);
  if (before.isNotEmpty && !before.endsWith('\n')) out.write('\n');
  final int caret = out.length;
  out.write(line);
  if (after.isNotEmpty) {
    out.write('\n');
    out.write(after);
  }
  return (
    text: out.toString(),
    caret: caret,
    delta: caret - lineStart,
  );
}
