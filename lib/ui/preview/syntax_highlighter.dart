/// A compact, dependency-free syntax highlighter.
///
/// NRS renders fenced code blocks itself rather than pulling in a highlighting
/// package, which keeps the token colours inside the app's own palette and
/// avoids shipping a multi-megabyte grammar bundle. The scanner is a single
/// alternation regex per language family: good enough for notes, instant on any
/// file size, and it degrades gracefully for unknown languages.
library;

enum TokenKind {
  plain,
  keyword,
  type,
  string,
  comment,
  number,
  func,
  punct,
  meta,
}

class CodeToken {
  const CodeToken(this.text, this.kind);
  final String text;
  final TokenKind kind;
}

class _LangSpec {
  const _LangSpec({
    required this.keywords,
    required this.types,
    this.lineComment = r'//',
    this.hashComment = false,
    this.blockComment = true,
    this.tripleQuotes = false,
    this.backtickStrings = false,
    this.annotation,
  });

  final Set<String> keywords;
  final Set<String> types;
  final String lineComment;
  final bool hashComment;
  final bool blockComment;
  final bool tripleQuotes;
  final bool backtickStrings;
  final String? annotation;
}

const Set<String> _sharedCKeywords = <String>{
  'if', 'else', 'for', 'while', 'do', 'switch', 'case', 'default', 'break',
  'continue', 'return', 'goto', 'sizeof', 'struct', 'union', 'enum', 'typedef',
  'static', 'const', 'volatile', 'extern', 'inline', 'register', 'unsigned',
  'signed', 'void', 'char', 'short', 'int', 'long', 'float', 'double', 'new',
  'delete', 'this', 'nullptr', 'true', 'false', 'namespace', 'using', 'class',
  'public', 'private', 'protected', 'virtual', 'override', 'template',
  'typename', 'try', 'catch', 'throw', 'auto', 'operator', 'friend', 'explicit',
};

const Map<String, _LangSpec> _specs = <String, _LangSpec>{
  'dart': _LangSpec(
    keywords: <String>{
      'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
      'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
      'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
      'external', 'factory', 'false', 'final', 'finally', 'for', 'get', 'hide',
      'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
      'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
      'return', 'sealed', 'set', 'show', 'static', 'super', 'switch', 'sync',
      'this', 'throw', 'true', 'try', 'typedef', 'var', 'void', 'when', 'while',
      'with', 'yield', 'Future', 'Stream', 'String', 'int', 'double', 'num',
      'bool', 'List', 'Map', 'Set', 'Object', 'Iterable', 'Duration', 'Widget',
      'BuildContext', 'State', 'StatelessWidget', 'StatefulWidget', 'DateTime',
    },
    types: <String>{},
    tripleQuotes: true,
    annotation: '@',
  ),
  'javascript': _LangSpec(
    keywords: <String>{
      'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
      'debugger', 'default', 'delete', 'do', 'else', 'export', 'extends',
      'false', 'finally', 'for', 'from', 'function', 'get', 'if', 'import',
      'in', 'instanceof', 'let', 'new', 'null', 'of', 'return', 'set', 'static',
      'super', 'switch', 'this', 'throw', 'true', 'try', 'typeof', 'undefined',
      'var', 'void', 'while', 'with', 'yield', 'interface', 'type', 'enum',
      'implements', 'declare', 'readonly', 'public', 'private', 'protected',
      'as', 'satisfies', 'keyof', 'number', 'string', 'boolean', 'any',
    },
    types: <String>{},
    backtickStrings: true,
  ),
  'python': _LangSpec(
    keywords: <String>{
      'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue',
      'def', 'del', 'elif', 'else', 'except', 'False', 'finally', 'for', 'from',
      'global', 'if', 'import', 'in', 'is', 'lambda', 'None', 'nonlocal', 'not',
      'or', 'pass', 'raise', 'return', 'True', 'try', 'while', 'with', 'yield',
      'self', 'match', 'case',
    },
    types: <String>{},
    lineComment: '#',
    hashComment: true,
    blockComment: false,
    tripleQuotes: true,
    annotation: '@',
  ),
  'shell': _LangSpec(
    keywords: <String>{
      'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'do', 'done', 'case',
      'esac', 'function', 'return', 'export', 'local', 'readonly', 'alias',
      'echo', 'cd', 'sudo', 'source', 'set', 'unset', 'exit', 'trap', 'shift',
    },
    types: <String>{},
    lineComment: '#',
    hashComment: true,
    blockComment: false,
  ),
  'yaml': _LangSpec(
    keywords: <String>{'true', 'false', 'null', 'yes', 'no', 'on', 'off'},
    types: <String>{},
    lineComment: '#',
    hashComment: true,
    blockComment: false,
  ),
  'sql': _LangSpec(
    keywords: <String>{
      'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET',
      'DELETE', 'CREATE', 'TABLE', 'INDEX', 'VIEW', 'DROP', 'ALTER', 'ADD',
      'JOIN', 'LEFT', 'RIGHT', 'INNER', 'OUTER', 'ON', 'GROUP', 'BY', 'ORDER',
      'HAVING', 'LIMIT', 'OFFSET', 'AS', 'AND', 'OR', 'NOT', 'NULL', 'IS',
      'IN', 'BETWEEN', 'LIKE', 'DISTINCT', 'UNION', 'ALL', 'CASE', 'WHEN',
      'THEN', 'ELSE', 'END', 'PRIMARY', 'KEY', 'FOREIGN', 'REFERENCES',
      'DEFAULT', 'AUTO_INCREMENT', 'COUNT', 'SUM', 'AVG', 'MIN', 'MAX',
    },
    types: <String>{'INT', 'VARCHAR', 'TEXT', 'BOOLEAN', 'DATE', 'TIMESTAMP'},
    lineComment: '--',
    blockComment: true,
  ),
  'rust': _LangSpec(
    keywords: <String>{
      'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
      'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in', 'let',
      'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return', 'self',
      'Self', 'static', 'struct', 'super', 'trait', 'true', 'type', 'unsafe',
      'use', 'where', 'while', 'String', 'Vec', 'Option', 'Result', 'Box',
    },
    types: <String>{},
    annotation: '#[',
  ),
  'go': _LangSpec(
    keywords: <String>{
      'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else',
      'fallthrough', 'for', 'func', 'go', 'goto', 'if', 'import', 'interface',
      'map', 'package', 'range', 'return', 'select', 'struct', 'switch', 'type',
      'var', 'nil', 'true', 'false', 'string', 'int', 'error', 'byte', 'rune',
    },
    types: <String>{},
    backtickStrings: true,
  ),
  'java': _LangSpec(
    keywords: <String>{
      'abstract', 'assert', 'boolean', 'break', 'byte', 'case', 'catch', 'char',
      'class', 'const', 'continue', 'default', 'do', 'double', 'else', 'enum',
      'extends', 'final', 'finally', 'float', 'for', 'goto', 'if', 'implements',
      'import', 'instanceof', 'int', 'interface', 'long', 'native', 'new',
      'package', 'private', 'protected', 'public', 'record', 'return', 'sealed',
      'short', 'static', 'strictfp', 'super', 'switch', 'synchronized', 'this',
      'throw', 'throws', 'transient', 'try', 'var', 'void', 'volatile', 'while',
      'true', 'false', 'null',
    },
    types: <String>{},
    annotation: '@',
  ),
  'kotlin': _LangSpec(
    keywords: <String>{
      'as', 'break', 'class', 'continue', 'data', 'do', 'else', 'false', 'for',
      'fun', 'if', 'in', 'interface', 'is', 'it', 'null', 'object', 'package',
      'return', 'sealed', 'super', 'suspend', 'this', 'throw', 'true', 'try',
      'typealias', 'val', 'var', 'when', 'while', 'open', 'override', 'private',
      'public', 'internal', 'companion', 'init', 'constructor', 'lateinit',
    },
    types: <String>{},
    annotation: '@',
  ),
  'swift': _LangSpec(
    keywords: <String>{
      'actor', 'as', 'async', 'await', 'break', 'case', 'catch', 'class',
      'continue', 'default', 'defer', 'do', 'else', 'enum', 'extension',
      'fallthrough', 'false', 'for', 'func', 'guard', 'if', 'import', 'in',
      'init', 'inout', 'internal', 'is', 'let', 'nil', 'open', 'operator',
      'private', 'protocol', 'public', 'repeat', 'rethrows', 'return', 'self',
      'some', 'static', 'struct', 'subscript', 'super', 'switch', 'throw',
      'throws', 'true', 'try', 'typealias', 'var', 'where', 'while',
    },
    types: <String>{},
    annotation: '@',
  ),
  'c': _LangSpec(keywords: _sharedCKeywords, types: <String>{}),
  'cpp': _LangSpec(keywords: _sharedCKeywords, types: <String>{}),
  'css': _LangSpec(
    keywords: <String>{
      'important', 'media', 'supports', 'keyframes', 'import', 'font-face',
      'from', 'to', 'root', 'hover', 'focus', 'active', 'nth-child', 'not',
      'flex', 'grid', 'absolute', 'relative', 'fixed', 'sticky', 'none',
      'block', 'inline', 'inherit', 'initial', 'unset',
    },
    types: <String>{},
    lineComment: '',
    blockComment: true,
  ),
};

const Map<String, String> _aliases = <String, String>{
  'js': 'javascript',
  'jsx': 'javascript',
  'ts': 'javascript',
  'tsx': 'javascript',
  'mjs': 'javascript',
  'node': 'javascript',
  'typescript': 'javascript',
  'py': 'python',
  'python3': 'python',
  'sh': 'shell',
  'bash': 'shell',
  'zsh': 'shell',
  'console': 'shell',
  'powershell': 'shell',
  'ps1': 'shell',
  'yml': 'yaml',
  'toml': 'yaml',
  'ini': 'yaml',
  'mysql': 'sql',
  'postgres': 'sql',
  'postgresql': 'sql',
  'sqlite': 'sql',
  'c++': 'cpp',
  'cc': 'cpp',
  'h': 'c',
  'hpp': 'cpp',
  'rs': 'rust',
  'golang': 'go',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'scss': 'css',
  'less': 'css',
  'plaintext': '',
  'text': '',
  'txt': '',
  '': '',
};

String normaliseLanguage(String? raw) {
  final String key = (raw ?? '').trim().toLowerCase();
  if (_aliases.containsKey(key)) return _aliases[key]!;
  if (_specs.containsKey(key)) return key;
  return '';
}

/// Highlights [code], returning one token list per source line so the renderer
/// can lay out a gutter and the code body in lockstep.
List<List<CodeToken>> highlightCode(String code, String? language) {
  final String lang = normaliseLanguage(language);
  final _LangSpec? spec = _specs[lang];
  final List<CodeToken> flat = spec == null
      ? _genericScan(code)
      : _scan(code, spec);
  return _splitLines(flat);
}

List<List<CodeToken>> _splitLines(List<CodeToken> tokens) {
  final List<List<CodeToken>> lines = <List<CodeToken>>[<CodeToken>[]];
  for (final CodeToken t in tokens) {
    final List<String> parts = t.text.split('\n');
    for (int i = 0; i < parts.length; i++) {
      if (i > 0) lines.add(<CodeToken>[]);
      if (parts[i].isNotEmpty) {
        lines.last.add(CodeToken(parts[i], t.kind));
      }
    }
  }
  return lines;
}

List<CodeToken> _scan(String code, _LangSpec spec) {
  // Build a single alternation. Every branch must consume at least one
  // character, otherwise `allMatches` would silently skip source text.
  //
  // Groups are matched by *index* rather than by name: languages legitimately
  // omit the block-comment or line-comment branch, and `namedGroup` throws for
  // a name that is not part of the compiled pattern.
  final List<_Alt> alts = <_Alt>[];

  if (spec.lineComment.isNotEmpty) {
    alts.add(
      _Alt(
        _Kind.lineComment,
        '${RegExp.escape(spec.lineComment)}[^\\n]*',
      ),
    );
  }
  if (spec.blockComment) {
    alts.add(_Alt(_Kind.blockComment, r'/\*[\s\S]*?\*/'));
  }

  final List<String> stringAlts = <String>[];
  if (spec.tripleQuotes) {
    stringAlts.add(r'"""[\s\S]*?"""');
    stringAlts.add(r"'''[\s\S]*?'''");
  }
  if (spec.backtickStrings) {
    stringAlts.add(r'`(?:\\.|[^`\\])*`');
  }
  stringAlts.add(r'"(?:\\.|[^"\\\n])*"');
  stringAlts.add(r"'(?:\\.|[^'\\\n])*'");
  alts.add(_Alt(_Kind.string, stringAlts.join('|')));

  alts.add(
    _Alt(
      _Kind.number,
      r'\b0[xX][0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b',
    ),
  );
  alts.add(_Alt(_Kind.word, r'[A-Za-z_$][A-Za-z0-9_$]*'));
  alts.add(_Alt(_Kind.punct, r'[{}()\[\];,.<>+\-*/%=!&|^~?:]+'));
  alts.add(_Alt(_Kind.other, r'[\s\S]'));

  final RegExp re = RegExp(
    alts.map((_Alt a) => '(${a.pattern})').join('|'),
  );
  final List<CodeToken> out = <CodeToken>[];
  final StringBuffer pending = StringBuffer();

  void flush() {
    if (pending.isNotEmpty) {
      out.add(CodeToken(pending.toString(), TokenKind.plain));
      pending.clear();
    }
  }

  for (final RegExpMatch m in re.allMatches(code)) {
    for (int i = 0; i < alts.length; i++) {
      final String? text = m.group(i + 1);
      if (text == null) continue;
      switch (alts[i].kind) {
        case _Kind.lineComment:
        case _Kind.blockComment:
          flush();
          out.add(CodeToken(text, TokenKind.comment));
        case _Kind.string:
          flush();
          out.add(CodeToken(text, TokenKind.string));
        case _Kind.number:
          flush();
          out.add(CodeToken(text, TokenKind.number));
        case _Kind.word:
          flush();
          if (spec.keywords.contains(text)) {
            out.add(CodeToken(text, TokenKind.keyword));
          } else if (spec.types.contains(text) || _looksLikeType(text)) {
            out.add(CodeToken(text, TokenKind.type));
          } else if (_isCallSite(code, m.end)) {
            out.add(CodeToken(text, TokenKind.func));
          } else {
            out.add(CodeToken(text, TokenKind.plain));
          }
        case _Kind.punct:
          flush();
          out.add(CodeToken(text, TokenKind.punct));
        case _Kind.other:
          pending.write(text);
      }
      break;
    }
  }
  flush();
  return out;
}

enum _Kind { lineComment, blockComment, string, number, word, punct, other }

class _Alt {
  const _Alt(this.kind, this.pattern);
  final _Kind kind;
  final String pattern;
}

/// Fallback for languages without a grammar: comments, strings, numbers only.
List<CodeToken> _genericScan(String code) {
  return _scan(
    code,
    const _LangSpec(
      keywords: <String>{},
      types: <String>{},
      blockComment: true,
    ),
  );
}

final RegExp _upperStart = RegExp(r'^[A-Z]');

bool _looksLikeType(String word) {
  if (word.length < 2) return false;
  if (!_upperStart.hasMatch(word)) return false;
  // SCREAMING_CASE is a constant, not a type.
  if (word.toUpperCase() == word) return false;
  return true;
}

bool _isCallSite(String code, int end) {
  int i = end;
  while (i < code.length && (code[i] == ' ' || code[i] == '\t')) {
    i++;
  }
  if (i < code.length && code[i] == '(') return true;
  // Dart named constructors / cascades read better as functions too.
  return false;
}
