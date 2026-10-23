import 'template_error.dart';

enum TemplateSegmentKind { text, expression, code }

/// One piece of the template file: literal text or one `<% … %>` tag.
class TemplateSegment {
  const TemplateSegment.text(this.text, {required this.line, required this.column})
    : kind = TemplateSegmentKind.text,
      code = '',
      raw = '',
      codeLine = line,
      codeColumn = column;

  const TemplateSegment.tag({
    required this.kind,
    required this.code,
    required this.raw,
    required this.line,
    required this.column,
    required this.codeLine,
    required this.codeColumn,
  }) : text = '';

  final TemplateSegmentKind kind;

  /// Present for [TemplateSegmentKind.text].
  final String text;

  /// The source between the tag markers, without whitespace-control signs.
  final String code;

  /// The whole tag as written, used in error messages.
  final String raw;

  /// Position of the tag's `<%`, 1-based.
  final int line;
  final int column;

  /// Position of the first character of [code], 1-based.
  final int codeLine;
  final int codeColumn;
}

/// Splits a template into literal text and tags, applying Templater's
/// whitespace controls (`<%_`, `<%-`, `_%>`, `-%>`).
class TemplateScanner {
  TemplateScanner(this.source);

  final String source;

  List<TemplateSegment> scan() {
    final List<TemplateSegment> segments = <TemplateSegment>[];
    int cursor = 0;
    String? pendingAfter;

    while (cursor < source.length) {
      final int open = source.indexOf('<%', cursor);
      if (open < 0) {
        _addText(segments, source.substring(cursor), cursor, pendingAfter);
        break;
      }

      int p = open + 2;
      String? before;
      if (p < source.length && (source[p] == '_' || source[p] == '-')) {
        before = source[p];
        p++;
      }

      TemplateSegmentKind kind = TemplateSegmentKind.expression;
      if (p < source.length && source[p] == '*') {
        kind = TemplateSegmentKind.code;
        p++;
      } else if (p < source.length && source[p] == '+') {
        p++;
      }

      final _Close? close = _findClose(p);
      if (close == null) {
        final ({int line, int column}) at = _positionAt(open);
        throw TemplateSyntaxError(
          '标签没有闭合，缺少 %>',
          line: at.line,
          column: at.column,
          source: source.substring(open),
        );
      }

      String text = _trimBefore(source.substring(cursor, open), before);
      _addText(segments, text, cursor, pendingAfter);
      pendingAfter = null;

      final ({int line, int column}) tagAt = _positionAt(open);
      final ({int line, int column}) codeAt = _positionAt(p);
      segments.add(
        TemplateSegment.tag(
          kind: kind,
          code: source.substring(p, close.codeEnd),
          raw: source.substring(open, close.next),
          line: tagAt.line,
          column: tagAt.column,
          codeLine: codeAt.line,
          codeColumn: codeAt.column,
        ),
      );

      pendingAfter = close.after;
      cursor = close.next;
    }

    return segments;
  }

  void _addText(
    List<TemplateSegment> segments,
    String text,
    int offset,
    String? after,
  ) {
    final String trimmed = _trimAfter(text, after);
    if (trimmed.isEmpty) return;
    final ({int line, int column}) at = _positionAt(offset);
    segments.add(
      TemplateSegment.text(trimmed, line: at.line, column: at.column),
    );
  }

  static String _trimBefore(String text, String? marker) {
    if (marker == '_') return text.replaceFirst(RegExp(r'\s+$'), '');
    if (marker == '-') {
      if (text.endsWith('\r\n')) return text.substring(0, text.length - 2);
      if (text.endsWith('\n')) return text.substring(0, text.length - 1);
    }
    return text;
  }

  static String _trimAfter(String text, String? marker) {
    if (marker == '_') return text.replaceFirst(RegExp(r'^\s+'), '');
    if (marker == '-') {
      if (text.startsWith('\r\n')) return text.substring(2);
      if (text.startsWith('\n')) return text.substring(1);
    }
    return text;
  }

  _Close? _findClose(int from) {
    String? quote;
    bool escaped = false;
    for (int i = from; i < source.length; i++) {
      final String ch = source[i];
      if (quote != null) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == quote) {
          quote = null;
        }
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        continue;
      }
      if (source.startsWith('_%>', i)) {
        return _Close(codeEnd: i, after: '_', next: i + 3);
      }
      if (source.startsWith('-%>', i)) {
        return _Close(codeEnd: i, after: '-', next: i + 3);
      }
      if (source.startsWith('%>', i)) {
        return _Close(codeEnd: i, after: null, next: i + 2);
      }
    }
    return null;
  }

  ({int line, int column}) _positionAt(int offset) {
    int line = 1;
    int lineStart = 0;
    for (int i = 0; i < offset; i++) {
      if (source.codeUnitAt(i) == 0x0A) {
        line++;
        lineStart = i + 1;
      }
    }
    return (line: line, column: offset - lineStart + 1);
  }
}

class _Close {
  const _Close({required this.codeEnd, required this.after, required this.next});

  final int codeEnd;
  final String? after;
  final int next;
}

enum NtlTokenType { identifier, number, string, operator, punctuation, eof }

class NtlToken {
  const NtlToken({
    required this.type,
    required this.lexeme,
    required this.line,
    required this.column,
    this.value,
  });

  final NtlTokenType type;
  final String lexeme;
  final int line;
  final int column;
  final Object? value;

  @override
  String toString() => '$type($lexeme)';
}

/// Lexer for the small expression/statement language inside a tag.
class NtlLexer {
  NtlLexer(this.source, {this.baseLine = 1, this.baseColumn = 1});

  final String source;
  final int baseLine;
  final int baseColumn;

  final List<NtlToken> _tokens = <NtlToken>[];
  int _index = 0;
  int _line = 0;
  int _column = 0;

  int get _lineNow => baseLine + _line;
  int get _columnNow => _line == 0 ? baseColumn + _column : _column + 1;

  List<NtlToken> tokenize() {
    while (_index < source.length) {
      final String ch = source[_index];
      if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
        _advance();
        continue;
      }
      if (ch == '/' && _peek(1) == '/') {
        while (_index < source.length && source[_index] != '\n') {
          _advance();
        }
        continue;
      }
      if (ch == '/' && _peek(1) == '*') {
        final int line = _lineNow;
        final int column = _columnNow;
        _advance();
        _advance();
        while (_index < source.length &&
            !(source[_index] == '*' && _peek(1) == '/')) {
          _advance();
        }
        if (_index >= source.length) {
          throw TemplateSyntaxError(
            '注释没有闭合，缺少 */',
            line: line,
            column: column,
            source: source,
          );
        }
        _advance();
        _advance();
        continue;
      }

      if (_isDigit(ch)) {
        _number();
        continue;
      }
      if (_isIdentStart(ch)) {
        _identifier();
        continue;
      }
      if (ch == '"' || ch == "'") {
        _string(ch);
        continue;
      }
      if (_operatorOrPunctuation()) continue;

      throw TemplateSyntaxError(
        '无法识别的字符「$ch」',
        line: _lineNow,
        column: _columnNow,
        source: source,
      );
    }
    _tokens.add(
      NtlToken(
        type: NtlTokenType.eof,
        lexeme: '',
        line: _lineNow,
        column: _columnNow,
      ),
    );
    return _tokens;
  }

  bool _operatorOrPunctuation() {
    const List<String> operators = <String>[
      '===',
      '!==',
      '==',
      '!=',
      '<=',
      '>=',
      '&&',
      '||',
      '+=',
      '-=',
      '*=',
      '/=',
      '%=',
      '+',
      '-',
      '*',
      '/',
      '%',
      '!',
      '=',
      '<',
      '>',
      '?',
      ':',
    ];
    for (final String op in operators) {
      if (source.startsWith(op, _index)) {
        final int line = _lineNow;
        final int column = _columnNow;
        for (int i = 0; i < op.length; i++) {
          _advance();
        }
        if (op == '===' || op == '!==') {
          throw TemplateSyntaxError(
            '不支持 $op，请使用 ${op.substring(0, 2)}',
            line: line,
            column: column,
            source: source,
          );
        }
        _tokens.add(
          NtlToken(
            type: NtlTokenType.operator,
            lexeme: op,
            line: line,
            column: column,
          ),
        );
        return true;
      }
    }
    const String punctuation = '()[]{},.;';
    if (punctuation.contains(source[_index])) {
      final int line = _lineNow;
      final int column = _columnNow;
      final String ch = source[_index];
      _advance();
      _tokens.add(
        NtlToken(
          type: NtlTokenType.punctuation,
          lexeme: ch,
          line: line,
          column: column,
        ),
      );
      return true;
    }
    return false;
  }

  void _number() {
    final int start = _index;
    final int line = _lineNow;
    final int column = _columnNow;
    while (_index < source.length && _isDigit(source[_index])) {
      _advance();
    }
    bool isDouble = false;
    if (_index < source.length &&
        source[_index] == '.' &&
        _index + 1 < source.length &&
        _isDigit(source[_index + 1])) {
      isDouble = true;
      _advance();
      while (_index < source.length && _isDigit(source[_index])) {
        _advance();
      }
    }
    final String raw = source.substring(start, _index);
    _tokens.add(
      NtlToken(
        type: NtlTokenType.number,
        lexeme: raw,
        line: line,
        column: column,
        value: isDouble ? double.parse(raw) : int.parse(raw),
      ),
    );
  }

  void _identifier() {
    final int start = _index;
    final int line = _lineNow;
    final int column = _columnNow;
    while (_index < source.length && _isIdentPart(source[_index])) {
      _advance();
    }
    _tokens.add(
      NtlToken(
        type: NtlTokenType.identifier,
        lexeme: source.substring(start, _index),
        line: line,
        column: column,
      ),
    );
  }

  void _string(String quote) {
    final int line = _lineNow;
    final int column = _columnNow;
    _advance();
    final StringBuffer buffer = StringBuffer();
    while (_index < source.length) {
      final String ch = source[_index];
      if (ch == quote) {
        _advance();
        final String value = buffer.toString();
        _tokens.add(
          NtlToken(
            type: NtlTokenType.string,
            lexeme: value,
            line: line,
            column: column,
            value: value,
          ),
        );
        return;
      }
      if (ch == '\n') {
        throw TemplateSyntaxError(
          '字符串不能跨行，缺少结束引号',
          line: line,
          column: column,
          source: source,
        );
      }
      if (ch == r'\') {
        _advance();
        if (_index >= source.length) break;
        final String escaped = source[_index];
        switch (escaped) {
          case 'n':
            buffer.write('\n');
            _advance();
          case 't':
            buffer.write('\t');
            _advance();
          case 'r':
            buffer.write('\r');
            _advance();
          case r'\':
            buffer.write(r'\');
            _advance();
          case '"':
            buffer.write('"');
            _advance();
          case "'":
            buffer.write("'");
            _advance();
          case 'u':
            if (_index + 4 >= source.length) {
              throw TemplateSyntaxError(
                '\\u 后面需要 4 位十六进制数字',
                line: _lineNow,
                column: _columnNow,
                source: source,
              );
            }
            final String hex = source.substring(_index + 1, _index + 5);
            final int? code = int.tryParse(hex, radix: 16);
            if (code == null) {
              throw TemplateSyntaxError(
                '\\u 后面需要 4 位十六进制数字',
                line: _lineNow,
                column: _columnNow,
                source: source,
              );
            }
            buffer.writeCharCode(code);
            for (int i = 0; i < 5; i++) {
              _advance();
            }
          default:
            buffer.write(escaped);
            _advance();
        }
        continue;
      }
      buffer.write(ch);
      _advance();
    }
    throw TemplateSyntaxError(
      '字符串没有闭合',
      line: line,
      column: column,
      source: source,
    );
  }

  String? _peek(int offset) {
    final int at = _index + offset;
    return at < source.length ? source[at] : null;
  }

  static bool _isDigit(String ch) =>
      ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39;

  static bool _isIdentStart(String ch) {
    final int c = ch.codeUnitAt(0);
    return (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x5F ||
        c == 0x24;
  }

  static bool _isIdentPart(String ch) => _isIdentStart(ch) || _isDigit(ch);

  void _advance() {
    if (_index >= source.length) return;
    if (source[_index] == '\n') {
      _line++;
      _column = 0;
    } else {
      _column++;
    }
    _index++;
  }
}
