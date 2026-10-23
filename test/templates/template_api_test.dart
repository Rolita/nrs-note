import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/templates/template_api.dart';
import 'package:nrs/templates/template_ast.dart';
import 'package:nrs/templates/template_error.dart';
import 'package:nrs/templates/template_interpreter.dart';
import 'package:nrs/templates/template_parser.dart';

class _FakeHost implements TemplateHost {
  _FakeHost({DateTime? nowValue})
    : nowValue = nowValue ?? DateTime(2026, 10, 23, 13, 5, 9, 123);

  final DateTime nowValue;

  final Map<String, String> notes = const <String, String>{
    '素材': '素材正文',
    '日记/素材.md': '素材正文',
  };

  String? promptAnswer = '';
  int? suggesterIndex;
  String clipboardText = '剪贴板内容';
  String selectionText = '选中的文字';

  String? promptText;
  String? promptDefault;
  bool? promptMultiline;
  List<String>? suggesterOptions;
  String? suggesterPlaceholder;

  @override
  DateTime now() => nowValue;

  @override
  String get noteTitle => '今天';

  @override
  String get noteContent => '当前正文';

  @override
  List<String> get noteTags => <String>['日记', '随记'];

  @override
  String get noteRelativePath => '日记/今天.md';

  @override
  String get noteFolder => '日记';

  @override
  DateTime get noteCreatedAt => DateTime(2026, 10, 20, 9, 30);

  @override
  DateTime get noteUpdatedAt => DateTime(2026, 10, 22, 18, 45);

  @override
  String get selection => selectionText;

  @override
  String? absolutePathFor(String relativePath) {
    if (relativePath.isEmpty) return 'C:/库';
    return 'C:/库/$relativePath';
  }

  @override
  String? noteBodyForReference(String reference) {
    String clean = reference.trim();
    if (clean.startsWith('[[') && clean.endsWith(']]')) {
      clean = clean.substring(2, clean.length - 2);
    }
    clean = clean.split('|').first.trim();
    return notes[clean];
  }

  @override
  bool noteExistsForReference(String reference) =>
      noteBodyForReference(reference) != null;

  @override
  Future<String?> prompt({
    required String text,
    required String defaultValue,
    required bool multiline,
  }) async {
    promptText = text;
    promptDefault = defaultValue;
    promptMultiline = multiline;
    return promptAnswer;
  }

  @override
  Future<int?> suggester({
    required List<String> options,
    required String placeholder,
  }) async {
    suggesterOptions = options;
    suggesterPlaceholder = placeholder;
    return suggesterIndex;
  }

  @override
  Future<String> clipboard() async => clipboardText;
}

Future<NtlRenderResult> _render(String source, _FakeHost host) {
  final NtlTemplate template = TemplateParser(source).parse();
  return TemplateInterpreter().render(
    template,
    globals: <String, Object?>{'tp': buildTemplateApi(host)},
  );
}

void main() {
  group('tp.date', () {
    test('defaults to an ISO date', () async {
      expect(
        (await _render('<% tp.date.now() %>', _FakeHost())).text,
        '2026-10-23',
      );
    });

    test('renders the documented tokens', () async {
      expect(
        (await _render(
          '<% tp.date.now("YYYY-MM-DD HH:mm:ss.SSS") %>',
          _FakeHost(),
        )).text,
        '2026-10-23 13:05:09.123',
      );
      expect(
        (await _render('<% tp.date.now("MMMM dddd") %>', _FakeHost())).text,
        '十月 星期五',
      );
      expect(
        (await _render('<% tp.date.now("MMM ddd YY/M/D h:mm") %>', _FakeHost()))
            .text,
        '10月 周五 26/10/23 1:05',
      );
      expect(
        (await _render('<% tp.date.now("[第]YYYY[年]") %>', _FakeHost())).text,
        '第2026年',
      );
    });

    test('day, week, hour and month offsets are supported', () async {
      expect(
        (await _render(
          '<% tp.date.now("YYYY-MM-DD", -1) %>',
          _FakeHost(),
        )).text,
        '2026-10-22',
      );
      expect(
        (await _render(
          '<% tp.date.now("YYYY-MM-DD", "2d") %>',
          _FakeHost(),
        )).text,
        '2026-10-25',
      );
      expect(
        (await _render(
          '<% tp.date.now("YYYY-MM-DD", "-1w") %>',
          _FakeHost(),
        )).text,
        '2026-10-16',
      );
      expect(
        (await _render(
          '<% tp.date.now("HH:mm", "3h") %>',
          _FakeHost(),
        )).text,
        '16:05',
      );
      expect(
        (await _render(
          '<% tp.date.now("YYYY-MM-DD", "1M") %>',
          _FakeHost(),
        )).text,
        '2026-11-23',
      );
    });

    test('month offsets clamp to the end of a shorter month', () async {
      expect(
        (await _render(
          '<% tp.date.now("YYYY-MM-DD", "1M") %>',
          _FakeHost(nowValue: DateTime(2026, 1, 31, 8)),
        )).text,
        '2026-02-28',
      );
    });

    test('tomorrow and yesterday use the same clock time', () async {
      expect(
        (await _render(
          '<% tp.date.tomorrow("YYYY-MM-DD HH:mm") %>',
          _FakeHost(),
        )).text,
        '2026-10-24 13:05',
      );
      expect(
        (await _render(
          '<% tp.date.yesterday("YYYY-MM-DD HH:mm") %>',
          _FakeHost(),
        )).text,
        '2026-10-22 13:05',
      );
    });

    test('weekday treats 0 as Sunday and 1 as Monday', () async {
      expect(
        (await _render(
          '<% tp.date.weekday("YYYY-MM-DD", 1) %>',
          _FakeHost(),
        )).text,
        '2026-10-19',
      );
      expect(
        (await _render(
          '<% tp.date.weekday("YYYY-MM-DD", 0) %>',
          _FakeHost(),
        )).text,
        '2026-10-25',
      );
      expect(
        (await _render(
          '<% tp.date.weekday("YYYY-MM-DD", 5) %>',
          _FakeHost(),
        )).text,
        '2026-10-23',
      );
    });

    test('an unreadable duration explains the accepted forms', () async {
      expect(
        () => _render('<% tp.date.now("YYYY", "下周") %>', _FakeHost()),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            contains('2d'),
          ),
        ),
      );
    });
  });

  group('tp.file', () {
    test('exposes the current note properties', () async {
      expect((await _render('<% tp.file.title %>', _FakeHost())).text, '今天');
      expect(
        (await _render('<% tp.file.content %>', _FakeHost())).text,
        '当前正文',
      );
      expect(
        (await _render('<% tp.file.tags %>', _FakeHost())).text,
        '日记,随记',
      );
      expect(
        (await _render('<% tp.file.selection() %>', _FakeHost())).text,
        '选中的文字',
      );
    });

    test('path and folder switch between relative and absolute', () async {
      expect(
        (await _render(
          '<% tp.file.path() %>|<% tp.file.path(true) %>',
          _FakeHost(),
        )).text,
        '日记/今天.md|C:/库/日记/今天.md',
      );
      expect(
        (await _render(
          '<% tp.file.folder() %>|<% tp.file.folder(true) %>',
          _FakeHost(),
        )).text,
        '日记|C:/库/日记',
      );
    });

    test('creation and modification dates accept a format', () async {
      expect(
        (await _render(
          '<% tp.file.creation_date("YYYY-MM-DD HH:mm") %>',
          _FakeHost(),
        )).text,
        '2026-10-20 09:30',
      );
      expect(
        (await _render(
          '<% tp.file.last_modified_date("YYYY-MM-DD") %>',
          _FakeHost(),
        )).text,
        '2026-10-22',
      );
      expect(
        (await _render('<% tp.file.creation_date() %>', _FakeHost())).text,
        '2026-10-20T09:30:00.000',
      );
    });

    test('cursor places the caret in the output', () async {
      final NtlRenderResult result = await _render(
        '前<% tp.file.cursor() %>后',
        _FakeHost(),
      );
      expect(result.text, '前后');
      expect(result.cursorOffset, 1);
    });

    test('include reads a note body and exists answers truthfully', () async {
      expect(
        (await _render(
          '<% tp.file.include("[[素材]]") %>',
          _FakeHost(),
        )).text,
        '素材正文',
      );
      expect(
        (await _render(
          '<% tp.file.exists("素材") %>|<% tp.file.exists("没有") %>',
          _FakeHost(),
        )).text,
        'true|false',
      );
    });

    test('a missing include is a readable error', () async {
      expect(
        () => _render('<% tp.file.include("[[没有]]") %>', _FakeHost()),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            contains('找不到'),
          ),
        ),
      );
    });

    test('file-writing functions are explicitly refused', () async {
      expect(
        () => _render('<% tp.file.rename("新名字") %>', _FakeHost()),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            contains('不支持文件操作'),
          ),
        ),
      );
    });
  });

  group('tp.system', () {
    test('prompt passes the text and default and returns the answer', () async {
      final _FakeHost host = _FakeHost()..promptAnswer = '小明';
      final NtlRenderResult result = await _render(
        '<%* let who = tp.system.prompt("为谁记录？", "我"); -%>你好，<% who %>',
        host,
      );
      expect(result.text, '你好，小明');
      expect(host.promptText, '为谁记录？');
      expect(host.promptDefault, '我');
      expect(host.promptMultiline, isFalse);
    });

    test('dismissing a prompt cancels the render', () async {
      final _FakeHost host = _FakeHost()..promptAnswer = null;
      expect(
        () => _render('<% tp.system.prompt("为谁？") %>', host),
        throwsA(isA<TemplateCancelled>()),
      );
    });

    test('dismissing the suggester cancels the render', () async {
      final _FakeHost host = _FakeHost()..suggesterIndex = null;
      expect(
        () => _render('<% tp.system.suggester(["好"], [1]) %>', host),
        throwsA(isA<TemplateCancelled>()),
      );
    });

    test('suggester returns the matching item', () async {
      final _FakeHost host = _FakeHost()..suggesterIndex = 1;
      final NtlRenderResult result = await _render(
        '<% tp.system.suggester(["好", "差"], [1, 2], "选一个") %>',
        host,
      );
      expect(result.text, '2');
      expect(host.suggesterOptions, <String>['好', '差']);
      expect(host.suggesterPlaceholder, '选一个');
    });

    test('clipboard returns the host text', () async {
      expect(
        (await _render('<% tp.system.clipboard() %>', _FakeHost())).text,
        '剪贴板内容',
      );
    });

    test('tp.web is refused with an explanation', () async {
      expect(
        () => _render('<% tp.web.request("https://x") %>', _FakeHost()),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            contains('tp.web'),
          ),
        ),
      );
    });
  });

  group('tp.frontmatter', () {
    test('known fields come from the note', () async {
      expect(
        (await _render(
          '<% tp.frontmatter.title %>|<% tp.frontmatter.tags %>',
          _FakeHost(),
        )).text,
        '今天|日记,随记',
      );
    });

    test('custom keys explain the front-matter limitation', () async {
      expect(
        () => _render('<% tp.frontmatter.mood %>', _FakeHost()),
        throwsA(
          isA<TemplateRuntimeError>().having(
            (TemplateRuntimeError e) => e.message,
            'message',
            allOf(contains('front-matter'), contains('mood')),
          ),
        ),
      );
    });
  });
}
