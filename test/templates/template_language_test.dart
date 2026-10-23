import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/templates/template_ast.dart';
import 'package:nrs/templates/template_error.dart';
import 'package:nrs/templates/template_interpreter.dart';
import 'package:nrs/templates/template_parser.dart';

Future<NtlRenderResult> _render(
  String source, {
  Map<String, Object?> globals = const <String, Object?>{},
}) {
  final NtlTemplate template = TemplateParser(source).parse();
  return TemplateInterpreter().render(template, globals: globals);
}

class _Mark extends NtlCallable {
  @override
  String get ntlName => 'mark';

  @override
  Future<Object?> call(List<Object?> arguments, NtlCallSite site) async {
    final num raw = arguments.isEmpty ? 1 : arguments.first! as num;
    site.output.cursor(raw.toInt());
    return null;
  }
}

class _Value extends NtlCallable {
  _Value(this.value);

  final Object? value;

  @override
  String get ntlName => 'value';

  @override
  Future<Object?> call(List<Object?> arguments, NtlCallSite site) async {
    return value;
  }
}

class _Cancel extends NtlCallable {
  @override
  String get ntlName => 'cancel';

  @override
  Future<Object?> call(List<Object?> arguments, NtlCallSite site) async {
    throw const TemplateCancelled();
  }
}

class _Box extends NtlObject {
  _Box(this.values);

  final Map<String, Object?> values;

  @override
  String get ntlName => 'box';

  @override
  Object? member(String name) => values[name] ?? ntlMissing;
}

void main() {
  group('text and interpolation', () {
    test('literal text survives and expressions join it', () async {
      final NtlRenderResult result = await _render('你好，<% "世界" %>！');
      expect(result.text, '你好，世界！');
      expect(result.cursorOffset, isNull);
    });

    test('arithmetic follows operator precedence', () async {
      expect((await _render('<% 1 + 2 * 3 %>')).text, '7');
      expect((await _render('<% (1 + 2) * 3 %>')).text, '9');
      expect((await _render('<% 7 / 2 %>')).text, '3.5');
      expect((await _render('<% 7 % 4 %>')).text, '3');
    });

    test('plus concatenates when either side is a string', () async {
      expect((await _render('<% "共 " + 3 + " 篇" %>')).text, '共 3 篇');
    });

    test('null, booleans and arrays read the documented way', () async {
      expect((await _render('<% null %>|<% true %>|<% false %>')).text, '|true|false');
      expect((await _render('<% ["好", "一般", "差"] %>')).text, '好,一般,差');
      expect((await _render('<% tp.frontmatter.tags.length %>', globals: <String, Object?>{
        'tp': _Box(<String, Object?>{
          'frontmatter': _Box(<String, Object?>{
            'tags': <String>['a', 'b', 'c'],
          }),
        }),
      })).text, '3');
    });

    test('comparison, equality and ternary work', () async {
      expect((await _render('<% 2 > 1 ? "是" : "否" %>')).text, '是');
      expect((await _render('<% "ab" == "ab" && 1 != 2 %>')).text, 'true');
      expect((await _render('<% 1 == 1.0 %>')).text, 'true');
    });

    test('a trailing semicolon is tolerated inside an expression tag', () async {
      expect((await _render('<% 1 + 1; %>')).text, '2');
    });
  });

  group('whitespace control', () {
    test('<%_ removes every preceding space', () async {
      expect((await _render('A   \n<%_ "B" %>')).text, 'AB');
    });

    test('<%- removes one preceding newline', () async {
      expect((await _render('A\n<%- "B" %>')).text, 'AB');
      expect((await _render('A\n\n<%- "B" %>')).text, 'A\nB');
    });

    test('_%> removes every following space', () async {
      expect((await _render('A<% "B" _%>   \nC')).text, 'ABC');
    });

    test('-%> removes one following newline', () async {
      expect((await _render('A<% "B" -%>\nC')).text, 'ABC');
      expect((await _render('A<% "B" -%>\n\nC')).text, 'AB\nC');
    });
  });

  group('statements', () {
    test('let and if/else shape the output', () async {
      final String source =
          '<%* let who = "小明"; if (who == "小明") { tR += "你好"; } '
          'else { tR += "再见"; } %>！';
      expect((await _render(source)).text, '你好！');
    });

    test('variables declared in one tag are visible in the next', () async {
      expect(
        (await _render('<%* let x = 2; -%><% x * 3 %>')).text,
        '6',
      );
    });

    test('else if is supported', () async {
      const String source =
          '<%* let n = 3; if (n == 1) { tR += "一"; } '
          'else if (n == 3) { tR += "三"; } else { tR += "其他"; } %>';
      expect((await _render(source)).text, '三');
    });

    test('assignments and compound assignments update values', () async {
      expect(
        (await _render(
          '<%* let n = 1; n += 4; n *= 2; -%><% n %>',
        )).text,
        '10',
      );
      expect(
        (await _render('<%* let s = "a"; s += "b"; -%><% s %>')).text,
        'ab',
      );
    });

    test('const cannot be reassigned', () async {
      expect(
        () => _render('<%* const n = 1; n = 2; %>'),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            contains('常量'),
          ),
        ),
      );
    });

    test('an undeclared variable is a readable runtime error', () async {
      expect(
        () => _render('<% missing %>'),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            contains('未定义的变量'),
          ),
        ),
      );
    });
  });

  group('tR and cursors', () {
    test('tR += appends and tR reads what has been written', () async {
      expect((await _render('<%* tR += "A"; tR += "B"; %>')).text, 'AB');
      expect((await _render('<%* tR += "A"; %><% tR %>')).text, 'AA');
    });

    test('tR = "" clears earlier output', () async {
      expect((await _render('前<%* tR = ""; tR += "后"; %>')).text, '后');
    });

    test('a cursor marker records the output offset', () async {
      final NtlRenderResult result = await _render(
        '前<% mark(1) %>后',
        globals: <String, Object?>{'mark': _Mark()},
      );
      expect(result.text, '前后');
      expect(result.cursorOffset, 1);
    });

    test('order 1 wins over an earlier marker with another order', () async {
      final NtlRenderResult result = await _render(
        'A<% mark(2) %>B<% mark(1) %>C',
        globals: <String, Object?>{'mark': _Mark()},
      );
      expect(result.text, 'ABC');
      expect(result.cursorOffset, 2);
    });

    test('clearing tR also drops the markers placed before it', () async {
      final NtlRenderResult result = await _render(
        'A<% mark(1) %><%* tR = ""; %>Z',
        globals: <String, Object?>{'mark': _Mark()},
      );
      expect(result.text, 'Z');
      expect(result.cursorOffset, isNull);
    });

    test('the first marker with order 1 is used', () async {
      final NtlRenderResult result = await _render(
        'A<% mark(1) %>B<% mark(1) %>',
        globals: <String, Object?>{'mark': _Mark()},
      );
      expect(result.cursorOffset, 1);
    });
  });

  group('calls and host cancellation', () {
    test('calls are awaited without an explicit await', () async {
      expect(
        (await _render('<% value() %>', globals: <String, Object?>{
          'value': _Value('完成'),
        })).text,
        '完成',
      );
    });

    test('await is accepted and changes nothing', () async {
      expect(
        (await _render('<% await value() %>', globals: <String, Object?>{
          'value': _Value('完成'),
        })).text,
        '完成',
      );
    });

    test('a cancelled prompt aborts the whole render', () async {
      expect(
        () => _render('前<% cancel() %>后', globals: <String, Object?>{
          'cancel': _Cancel(),
        }),
        throwsA(isA<TemplateCancelled>()),
      );
    });

    test('unknown members mention the object and the name', () async {
      expect(
        () => _render('<% box.nope %>', globals: <String, Object?>{
          'box': _Box(const <String, Object?>{}),
        }),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            allOf(contains('box'), contains('nope')),
          ),
        ),
      );
    });
  });

  group('syntax errors', () {
    test('an unclosed tag names its line and column', () async {
      expect(
        () => _render('第一行\n第二行 <% 1 + 1'),
        throwsA(
          isA<TemplateSyntaxError>()
              .having((TemplateSyntaxError e) => e.line, 'line', 2)
              .having((TemplateSyntaxError e) => e.message, 'message', contains('没有闭合')),
        ),
      );
    });

    test('loops are refused with an explanation', () async {
      expect(
        () => _render('<%* for (let i = 0; i < 2; i++) { } %>'),
        throwsA(
          isA<TemplateSyntaxError>().having(
            (TemplateSyntaxError e) => e.message,
            'message',
            contains('循环'),
          ),
        ),
      );
    });

    test('function declarations are refused', () async {
      expect(
        () => _render('<%* function f() { } %>'),
        throwsA(isA<TemplateSyntaxError>()),
      );
    });

    test('division by zero is a runtime error', () async {
      expect(
        () => _render('<% 1 / 0 %>'),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            contains('除数'),
          ),
        ),
      );
    });

    test('string escapes are decoded', () async {
      expect(
        (await _render('<% "a\\n\\"b\\"" %>')).text,
        'a\n"b"',
      );
    });

    test('comments are ignored inside tags', () async {
      expect((await _render('<%* // 说明\n tR += "A"; /* 尾注 */ %>')).text, 'A');
    });
  });
}
