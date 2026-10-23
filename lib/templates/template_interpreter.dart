import 'template_ast.dart';
import 'template_error.dart';

/// Returned by an [NtlObject] when it does not know [name]. The interpreter
/// turns this into a readable error instead of silently producing `null`.
const Object ntlMissing = _NtlMissing();

class _NtlMissing {
  const _NtlMissing();
}

/// A member that exists in Templater but is deliberately not available here.
/// The interpreter turns it into an error that explains the boundary.
class NtlUnavailable {
  const NtlUnavailable(this.message);

  final String message;
}

/// One member of the template API (`tp`, `tp.file`, `tp.date`…).
abstract class NtlObject {
  String get ntlName;

  /// The property or function called [name], or [ntlMissing].
  Object? member(String name);
}

/// A callable exposed to templates. Every call is awaited, which is what lets
/// `tp.system.prompt` look synchronous in a template.
abstract class NtlCallable {
  String get ntlName;

  Future<Object?> call(List<Object?> arguments, NtlCallSite site);
}

/// Where a built-in call happened, and the buffer it may write cursors into.
class NtlCallSite {
  const NtlCallSite({
    required this.output,
    required this.line,
    required this.column,
    required this.source,
  });

  final NtlRenderBuffer output;
  final int line;
  final int column;
  final String source;

  Never error(String message) {
    throw TemplateRuntimeError(
      message,
      line: line,
      column: column,
      source: source,
    );
  }
}

class NtlCursorMark {
  const NtlCursorMark(this.order, this.offset);

  final int order;
  final int offset;
}

/// The rendered text so far, plus the cursor markers the template placed.
class NtlRenderBuffer {
  final StringBuffer _text = StringBuffer();
  final List<NtlCursorMark> _cursors = <NtlCursorMark>[];

  String get text => _text.toString();
  int get length => _text.length;
  List<NtlCursorMark> get cursors => List<NtlCursorMark>.unmodifiable(_cursors);

  void write(String value) => _text.write(value);

  /// `tR = ""`: the earlier text and the cursor markers inside it are gone.
  void clear() {
    _text.clear();
    _cursors.clear();
  }

  void cursor(int order) {
    _cursors.add(NtlCursorMark(order, _text.length));
  }
}

class NtlRenderResult {
  const NtlRenderResult({required this.text, this.cursorOffset});

  final String text;

  /// Caret position after insertion, in UTF-16 code units, or null when the
  /// template did not ask for a specific place.
  final int? cursorOffset;
}

/// Evaluates a parsed template. Pure Dart: no file or UI access lives here;
/// the `tp.*` objects carry their own host when they need one.
class TemplateInterpreter {
  TemplateInterpreter({this.maxSteps = 200000});

  final int maxSteps;

  final Map<String, Object?> _variables = <String, Object?>{};
  final Set<String> _constants = <String>{};
  final NtlRenderBuffer _output = NtlRenderBuffer();
  int _steps = 0;
  int _tagLine = 1;
  int _tagColumn = 1;
  String _tagSource = '';

  Future<NtlRenderResult> render(
    NtlTemplate template, {
    Map<String, Object?> globals = const <String, Object?>{},
  }) async {
    _variables
      ..clear()
      ..addAll(globals);
    _constants
      ..clear()
      ..addAll(globals.keys);
    _output.clear();
    _steps = 0;

    for (final TemplateNode node in template.nodes) {
      switch (node) {
        case TemplateText():
          _output.write(node.text);

        case TemplateExpressionTag():
          _enterTag(node.line, node.column, node.source);
          final Object? value = await _eval(node.expression);
          _output.write(stringifyNtl(value));

        case TemplateCodeTag():
          _enterTag(node.line, node.column, node.source);
          for (final NtlStatement statement in node.statements) {
            await _execute(statement);
          }
      }
    }

    return NtlRenderResult(
      text: _output.text,
      cursorOffset: _chosenCursor(_output.cursors),
    );
  }

  void _enterTag(int line, int column, String source) {
    _tagLine = line;
    _tagColumn = column;
    _tagSource = source;
  }

  int? _chosenCursor(List<NtlCursorMark> marks) {
    if (marks.isEmpty) return null;
    for (final NtlCursorMark mark in marks) {
      if (mark.order == 1) return mark.offset.clamp(0, _output.length);
    }
    return marks.first.offset.clamp(0, _output.length);
  }

  // -------------------------------------------------------------- statements

  Future<void> _execute(NtlStatement statement) async {
    _tick();
    switch (statement) {
      case NtlVariableDeclaration():
        await _declare(statement);

      case NtlAssignment():
        await _assign(statement);

      case NtlIf():
        final Object? test = await _eval(statement.condition);
        final List<NtlStatement> branch = truthy(test)
            ? statement.thenBranch
            : statement.elseBranch;
        for (final NtlStatement child in branch) {
          await _execute(child);
        }

      case NtlExpressionStatement():
        await _eval(statement.expression);
    }
  }

  Future<void> _declare(NtlVariableDeclaration statement) async {
    if (statement.name == 'tR') {
      _error('tR 是模板的输出缓冲区，不需要声明');
    }
    if (_variables.containsKey(statement.name)) {
      _error('变量「${statement.name}」已经存在');
    }
    final Object? value = statement.initializer == null
        ? null
        : await _eval(statement.initializer!);
    _variables[statement.name] = value;
    if (statement.isConst) _constants.add(statement.name);
  }

  Future<void> _assign(NtlAssignment statement) async {
    final Object? value = await _eval(statement.value);
    if (statement.name == 'tR') {
      if (statement.operator == '=') {
        _output.clear();
        _output.write(stringifyNtl(value));
        return;
      }
      if (statement.operator == '+=') {
        _output.write(stringifyNtl(value));
        return;
      }
      _error('tR 只支持 = 和 += 赋值');
    }
    if (!_variables.containsKey(statement.name)) {
      _error('未定义的变量「${statement.name}」');
    }
    if (_constants.contains(statement.name)) {
      _error('「${statement.name}」是常量，不能修改');
    }
    if (statement.operator == '=') {
      _variables[statement.name] = value;
      return;
    }
    final Object? current = _variables[statement.name];
    final String operator = statement.operator.substring(0, 1);
    _variables[statement.name] = _binary(operator, current, value);
  }

  // ------------------------------------------------------------- expressions

  Future<Object?> _eval(NtlExpression expression) async {
    _tick();
    switch (expression) {
      case NtlLiteral():
        return expression.value;

      case NtlVariable():
        return _lookup(expression.name);

      case NtlArrayLiteral():
        final List<Object?> values = <Object?>[];
        for (final NtlExpression element in expression.elements) {
          values.add(await _eval(element));
        }
        return values;

      case NtlUnary():
        final Object? operand = await _eval(expression.operand);
        return switch (expression.operator) {
          '!' => !truthy(operand),
          '-' => _negate(operand),
          '+' => _requireNumber(operand, '正号'),
          _ => _error('未知运算符「${expression.operator}」'),
        };

      case NtlAwait():
        return _eval(expression.expression);

      case NtlBinary():
        return _binaryExpression(expression);

      case NtlConditional():
        final Object? test = await _eval(expression.condition);
        return _eval(truthy(test) ? expression.whenTrue : expression.whenFalse);

      case NtlMember():
        final Object? target = await _eval(expression.object);
        return _member(target, expression.name);

      case NtlCall():
        final Object? callee = await _eval(expression.callee);
        final List<Object?> arguments = <Object?>[];
        for (final NtlExpression argument in expression.arguments) {
          arguments.add(await _eval(argument));
        }
        if (callee is! NtlCallable) {
          _error('这个值不是函数，不能调用');
        }
        return callee.call(
          arguments,
          NtlCallSite(
            output: _output,
            line: _tagLine,
            column: _tagColumn,
            source: _tagSource,
          ),
        );
    }
  }

  Future<Object?> _binaryExpression(NtlBinary expression) async {
    if (expression.operator == '&&') {
      final Object? left = await _eval(expression.left);
      if (!truthy(left)) return false;
      return truthy(await _eval(expression.right));
    }
    if (expression.operator == '||') {
      final Object? left = await _eval(expression.left);
      if (truthy(left)) return true;
      return truthy(await _eval(expression.right));
    }
    final Object? left = await _eval(expression.left);
    final Object? right = await _eval(expression.right);
    return _binary(expression.operator, left, right);
  }

  Object? _lookup(String name) {
    if (name == 'tR') return _output.text;
    if (_variables.containsKey(name)) return _variables[name];
    _error('未定义的变量「$name」');
  }

  Object? _member(Object? target, String name) {
    if (target is NtlObject) {
      final Object? value = target.member(name);
      if (value is NtlUnavailable) _error(value.message);
      if (!identical(value, ntlMissing)) return value;
      _error('「${target.ntlName}」没有成员「$name」');
    }
    if ((target is List || target is String) && name == 'length') {
      return target is List ? target.length : (target as String).length;
    }
    if (target == null) _error('不能读取 null 的成员「$name」');
    _error('这个值没有成员「$name」');
  }

  Object? _binary(String operator, Object? left, Object? right) {
    switch (operator) {
      case '+':
        if (left is String || right is String) {
          return stringifyNtl(left) + stringifyNtl(right);
        }
        if (left is num && right is num) return left + right;
        _error('+ 只能用于数字或字符串');

      case '-':
        return _requireNumber(left, '-') - _requireNumber(right, '-');

      case '*':
        return _requireNumber(left, '*') * _requireNumber(right, '*');

      case '/':
        final num divisor = _requireNumber(right, '/');
        if (divisor == 0) _error('除数不能为 0');
        return _requireNumber(left, '/') / divisor;

      case '%':
        final num divisor = _requireNumber(right, '%');
        if (divisor == 0) _error('除数不能为 0');
        return _requireNumber(left, '%') % divisor;

      case '==':
        return _equals(left, right);

      case '!=':
        return !_equals(left, right);

      case '<':
      case '<=':
      case '>':
      case '>=':
        return _compare(operator, left, right);

      default:
        _error('未知运算符「$operator」');
    }
  }

  bool _equals(Object? left, Object? right) {
    if (left is num && right is num) return left == right;
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (int i = 0; i < left.length; i++) {
        if (!_equals(left[i], right[i])) return false;
      }
      return true;
    }
    return left == right;
  }

  bool _compare(String operator, Object? left, Object? right) {
    final int result;
    if (left is num && right is num) {
      result = left.compareTo(right);
    } else if (left is String && right is String) {
      result = left.compareTo(right);
    } else {
      _error('比较运算的两边必须是同类型的数字或字符串');
    }
    return switch (operator) {
      '<' => result < 0,
      '<=' => result <= 0,
      '>' => result > 0,
      _ => result >= 0,
    };
  }

  num _requireNumber(Object? value, String operator) {
    if (value is num) return value;
    _error('「$operator」需要数字，实际是 ${_typeName(value)}');
  }

  num _negate(Object? value) => -_requireNumber(value, '负号');

  String _typeName(Object? value) {
    if (value == null) return 'null';
    if (value is String) return '字符串';
    if (value is num) return '数字';
    if (value is bool) return '布尔值';
    if (value is List) return '数组';
    if (value is NtlCallable) return '函数';
    return value.runtimeType.toString();
  }

  void _tick() {
    _steps++;
    if (_steps > maxSteps) {
      _error('模板执行步数超出上限（$maxSteps 步），请检查模板内容');
    }
  }

  Never _error(String message) {
    throw TemplateRuntimeError(
      message,
      line: _tagLine,
      column: _tagColumn,
      source: _tagSource,
    );
  }
}

/// How a value reads inside the template output.
String stringifyNtl(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num) {
    if (value is int) return value.toString();
    final double d = value.toDouble();
    if (d.isFinite && d == d.truncateToDouble()) {
      return d.toStringAsFixed(0);
    }
    return d.toString();
  }
  if (value is bool) return value ? 'true' : 'false';
  if (value is List) return value.map(stringifyNtl).join(',');
  return value.toString();
}

bool truthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is List) return value.isNotEmpty;
  return true;
}
