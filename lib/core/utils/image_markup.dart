/// A line that consists of exactly one image, either Markdown
/// `![alt](source)` or a single `<img …>` tag.
///
/// This is pure value logic: the editor uses it to decide whether a paragraph
/// should be drawn as a picture, and to rewrite that line when its width is
/// changed. Anything that is not the *whole* line is ordinary source text.
class ImageMarkup {
  const ImageMarkup({required this.source, this.alt, this.width});

  /// `assets/x.png`, `https://…`, `data:…`.
  final String source;

  /// Alt text, `null` when the syntax has none or it is empty.
  final String? alt;

  /// Width in logical pixels as written in the source, `null` when the line
  /// does not declare one.
  final double? width;

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
  String toMarkdown({double? width}) {
    final double? effective = width ?? this.width;
    final String altText = alt ?? '';
    final String escapedAlt = _escapeAlt(altText);
    if (effective == null) {
      final String destination = _needsAngles(source) ? '<$source>' : source;
      return '![$escapedAlt]($destination)';
    }
    final StringBuffer out = StringBuffer('<img src="$source"');
    out.write(' width="${_formatWidth(effective)}"');
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
/// line, otherwise it would sit inside the image line and immediately reveal
/// the source again.
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
