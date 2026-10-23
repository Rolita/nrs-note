import 'template_ast.dart';
import 'template_error.dart';
import 'template_lexer.dart';

/// Parses a template file into [NtlTemplate].
class TemplateParser {
  TemplateParser(this.source);

  final String source;

  NtlTemplate parse() {
    final List<TemplateSegment> segments = TemplateScanner(source).scan();
    final List<TemplateNode> nodes = <TemplateNode>[];
    for (final TemplateSegment segment in segments) {
      switch (segment.kind) {
        case TemplateSegmentKind.text:
          nodes.add(TemplateText(segment.text));

        case TemplateSegmentKind.expression:
          nodes.add(_expressionTag(segment));

        case TemplateSegmentKind.code:
          nodes.add(_codeTag(segment));
      }
    }
    return NtlTemplate(nodes);
  }

  TemplateExpressionTag _expressionTag(TemplateSegment segment) {
    final _NtlParser parser = _NtlParser(
      _tokensFor(segment),
      tagSource: segment.raw,
    );
    final NtlExpression expression = parser.parseExpressionOnly();
    return TemplateExpressionTag(
      expression: expression,
      line: segment.line,
      column: segment.column,
      source: segment.raw,
    );
  }

  TemplateCodeTag _codeTag(TemplateSegment segment) {
    final _NtlParser parser = _NtlParser(
      _tokensFor(segment),
      tagSource: segment.raw,
    );
    final List<NtlStatement> statements = parser.parseStatements();
    return TemplateCodeTag(
      statements: statements,
      line: segment.line,
      column: segment.column,
      source: segment.raw,
    );
  }

  List<NtlToken> _tokensFor(TemplateSegment segment) {
    return NtlLexer(
      segment.code,
      baseLine: segment.codeLine,
      baseColumn: segment.codeColumn,
    ).tokenize();
  }
}

class _NtlParser {
  _NtlParser(this._tokens, {required this.tagSource});

  final List<NtlToken> _tokens;
  final String tagSource;
  int _at = 0;

  NtlExpression parseExpressionOnly() {
    final NtlExpression expression = parseExpression();
    while (_match(';')) {}
    if (!_isAtEnd) _error('表达式后面还有多余的内容');
    return expression;
  }

  List<NtlStatement> parseStatements() {
    final List<NtlStatement> statements = <NtlStatement>[];
    while (!_isAtEnd) {
      statements.add(_statement());
    }
    return statements;
  }

  // -------------------------------------------------------------- statements

  NtlStatement _statement() {
    if (_checkWord('let') || _checkWord('const')) return _declaration();
    if (_checkWord('if')) return _ifStatement();
    if (_checkWord('else')) _error('else 前面没有对应的 if');
    if (_checkWord('for') || _checkWord('while')) {
      _error('本版本不支持循环，请直接写出需要的内容');
    }
    if (_checkWord('function')) {
      _error('本版本不支持函数声明');
    }
    if (_checkWord('try')) {
      _error('本版本不支持 try/catch');
    }

    final NtlExpression expression = parseExpression();
    if (_isAssignment(_current.lexeme)) {
      final String operator = _current.lexeme;
      _advance();
      final NtlExpression value = parseExpression();
      _statementEnd();
      if (expression is! NtlVariable) {
        _error('只能给变量赋值');
      }
      return NtlAssignment(
        name: expression.name,
        operator: operator,
        value: value,
      );
    }
    _statementEnd();
    return NtlExpressionStatement(expression);
  }

  NtlStatement _declaration() {
    final bool isConst = _checkWord('const');
    final String keyword = _advance().lexeme;
    if (!_checkType(NtlTokenType.identifier) || _isReserved(_current.lexeme)) {
      _error('$keyword 后面需要一个变量名');
    }
    final String name = _advance().lexeme;
    NtlExpression? initializer;
    if (_match('=')) {
      initializer = parseExpression();
    }
    _statementEnd();
    return NtlVariableDeclaration(
      name: name,
      isConst: isConst,
      initializer: initializer,
    );
  }

  NtlStatement _ifStatement() {
    _advance();
    _expect('(');
    final NtlExpression condition = parseExpression();
    _expect(')');
    final List<NtlStatement> thenBranch = _branch();
    List<NtlStatement> elseBranch = const <NtlStatement>[];
    if (_matchWord('else')) {
      if (_checkWord('if')) {
        elseBranch = <NtlStatement>[_ifStatement()];
      } else {
        elseBranch = _branch();
      }
    }
    return NtlIf(
      condition: condition,
      thenBranch: thenBranch,
      elseBranch: elseBranch,
    );
  }

  List<NtlStatement> _branch() {
    if (_match('{')) {
      final List<NtlStatement> body = <NtlStatement>[];
      while (!_check('}') && !_isAtEnd) {
        body.add(_statement());
      }
      _expect('}');
      return body;
    }
    return <NtlStatement>[_statement()];
  }

  void _statementEnd() {
    if (_match(';')) return;
    if (_isAtEnd || _check('}')) return;
    _error('语句之间缺少 ;');
  }

  // ------------------------------------------------------------- expressions

  NtlExpression parseExpression() => _conditional();

  NtlExpression _conditional() {
    final NtlExpression condition = _logicalOr();
    if (_match('?')) {
      final NtlExpression whenTrue = parseExpression();
      _expect(':');
      final NtlExpression whenFalse = parseExpression();
      return NtlConditional(condition, whenTrue, whenFalse);
    }
    return condition;
  }

  NtlExpression _logicalOr() {
    NtlExpression left = _logicalAnd();
    while (_match('||')) {
      left = NtlBinary('||', left, _logicalAnd());
    }
    return left;
  }

  NtlExpression _logicalAnd() {
    NtlExpression left = _equality();
    while (_match('&&')) {
      left = NtlBinary('&&', left, _equality());
    }
    return left;
  }

  NtlExpression _equality() {
    NtlExpression left = _comparison();
    while (_check('==') || _check('!=')) {
      final String operator = _advance().lexeme;
      left = NtlBinary(operator, left, _comparison());
    }
    return left;
  }

  NtlExpression _comparison() {
    NtlExpression left = _additive();
    while (_check('<') ||
        _check('<=') ||
        _check('>') ||
        _check('>=')) {
      final String operator = _advance().lexeme;
      left = NtlBinary(operator, left, _additive());
    }
    return left;
  }

  NtlExpression _additive() {
    NtlExpression left = _multiplicative();
    while (_check('+') || _check('-')) {
      final String operator = _advance().lexeme;
      left = NtlBinary(operator, left, _multiplicative());
    }
    return left;
  }

  NtlExpression _multiplicative() {
    NtlExpression left = _unary();
    while (_check('*') || _check('/') || _check('%')) {
      final String operator = _advance().lexeme;
      left = NtlBinary(operator, left, _unary());
    }
    return left;
  }

  NtlExpression _unary() {
    if (_match('!')) return NtlUnary('!', _unary());
    if (_match('-')) return NtlUnary('-', _unary());
    if (_match('+')) return NtlUnary('+', _unary());
    if (_matchWord('await')) return NtlAwait(_unary());
    return _postfix();
  }

  NtlExpression _postfix() {
    NtlExpression expression = _primary();
    while (true) {
      if (_match('.')) {
        if (!_checkType(NtlTokenType.identifier)) {
          _error('点号后面需要一个名字');
        }
        expression = NtlMember(expression, _advance().lexeme);
      } else if (_match('(')) {
        final List<NtlExpression> arguments = <NtlExpression>[];
        if (!_check(')')) {
          do {
            arguments.add(parseExpression());
          } while (_match(',') && !_check(')'));
        }
        _expect(')');
        expression = NtlCall(expression, arguments);
      } else {
        return expression;
      }
    }
  }

  NtlExpression _primary() {
    if (_matchType(NtlTokenType.number) || _matchType(NtlTokenType.string)) {
      return NtlLiteral(_previous.value);
    }
    if (_matchWord('true')) return const NtlLiteral(true);
    if (_matchWord('false')) return const NtlLiteral(false);
    if (_matchWord('null')) return const NtlLiteral(null);

    if (_match('(')) {
      final NtlExpression inner = parseExpression();
      _expect(')');
      return inner;
    }
    if (_match('[')) {
      final List<NtlExpression> elements = <NtlExpression>[];
      if (!_check(']')) {
        do {
          elements.add(parseExpression());
        } while (_match(',') && !_check(']'));
      }
      _expect(']');
      return NtlArrayLiteral(elements);
    }

    if (_checkType(NtlTokenType.identifier)) {
      if (_isReserved(_current.lexeme)) {
        _error('「${_current.lexeme}」不能当作变量');
      }
      return NtlVariable(_advance().lexeme);
    }

    if (_checkWord('function') || _checkWord('for') || _checkWord('while')) {
      _error('本版本不支持 ${_current.lexeme}');
    }
    _error('需要一个表达式');
  }

  // ----------------------------------------------------------------- helpers

  static const Set<String> _reservedWords = <String>{
    'let',
    'const',
    'if',
    'else',
    'true',
    'false',
    'null',
    'await',
    'for',
    'while',
    'function',
    'try',
  };

  static bool _isReserved(String word) => _reservedWords.contains(word);

  static bool _isAssignment(String lexeme) =>
      lexeme == '=' ||
      lexeme == '+=' ||
      lexeme == '-=' ||
      lexeme == '*=' ||
      lexeme == '/=' ||
      lexeme == '%=';

  NtlToken get _current => _tokens[_at.clamp(0, _tokens.length - 1)];

  NtlToken get _previous => _tokens[(_at - 1).clamp(0, _tokens.length - 1)];

  bool get _isAtEnd => _current.type == NtlTokenType.eof;

  bool _check(String lexeme) => !_isAtEnd && _current.lexeme == lexeme;

  bool _checkWord(String word) =>
      _current.type == NtlTokenType.identifier && _current.lexeme == word;

  bool _checkType(NtlTokenType type) => _current.type == type;

  NtlToken _advance() {
    if (!_isAtEnd) _at++;
    return _previous;
  }

  bool _match(String lexeme) {
    if (!_check(lexeme)) return false;
    _advance();
    return true;
  }

  bool _matchWord(String word) {
    if (!_checkWord(word)) return false;
    _advance();
    return true;
  }

  bool _matchType(NtlTokenType type) {
    if (!_checkType(type)) return false;
    _advance();
    return true;
  }

  void _expect(String lexeme) {
    if (_match(lexeme)) return;
    _error('这里需要「$lexeme」');
  }

  Never _error(String message) {
    throw TemplateSyntaxError(
      message,
      line: _current.line,
      column: _current.column,
      source: tagSource,
    );
  }
}
