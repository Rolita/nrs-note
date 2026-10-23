import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/state/template_settings.dart';
import 'package:nrs/templates/template_error.dart';
import 'package:nrs/templates/template_interpreter.dart';
import 'package:nrs/templates/template_service.dart';

Note _note(
  String id,
  String title, {
  String folder = '',
  String body = '',
}) => Note(
  id: id,
  title: title,
  body: body,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  folderPath: folder,
);

class _Interaction implements TemplateInteraction {
  _Interaction({this.promptAnswer = '', this.suggesterIndex = 0});

  String? promptAnswer;
  int? suggesterIndex;
  String clipboardText = '剪贴板';

  final List<({String text, String defaultValue, bool multiline})> prompts =
      <({String text, String defaultValue, bool multiline})>[];
  final List<({List<String> options, String placeholder})> suggesters =
      <({List<String> options, String placeholder})>[];

  @override
  Future<String?> prompt({
    required String text,
    required String defaultValue,
    required bool multiline,
  }) async {
    prompts.add((text: text, defaultValue: defaultValue, multiline: multiline));
    return promptAnswer;
  }

  @override
  Future<int?> suggester({
    required List<String> options,
    required String placeholder,
  }) async {
    suggesters.add((options: options, placeholder: placeholder));
    return suggesterIndex;
  }

  @override
  Future<String> clipboard() async => clipboardText;
}

void main() {
  const TemplateService service = TemplateService();
  final DateTime now = DateTime(2026, 10, 23, 13, 5, 9);

  group('模板发现', () {
    test('只收模板文件夹及其子文件夹里的笔记，并按路径排序', () {
      final List<Note> notes = <Note>[
        _note('1', 'B', folder: '模板/B'),
        _note('2', 'A', folder: '模板'),
        _note('3', 'C', folder: '模板/A'),
        _note('4', '外边', folder: '工作'),
        _note('5', '模板', folder: ''), // 根目录同名笔记不是模板
      ];

      final List<Note> found = service.discoverTemplates(notes, '模板');

      expect(
        found.map((Note n) => n.relativePath),
        <String>['模板/A.md', '模板/A/C.md', '模板/B/B.md'],
      );
    });

    test('模板文件夹可以是任意库内路径，不再固定在「模板」', () {
      final List<Note> notes = <Note>[
        _note('1', '自定义', folder: '工作/我的模板'),
        _note('2', '默认', folder: '模板'),
        _note('3', '根目录里同名', folder: ''),
      ];

      final List<Note> found = service.discoverTemplates(notes, '工作/我的模板');

      expect(found.map((Note n) => n.title), <String>['自定义']);
    });

    test('文件夹为空或指向根目录时没有模板', () {
      final List<Note> notes = <Note>[_note('1', 'A', folder: '模板')];
      expect(service.discoverTemplates(notes, ''), isEmpty);
      expect(service.discoverTemplates(notes, '  '), isEmpty);
    });

    test('模板文件夹及其子文件夹不参与自动套用', () {
      expect(service.isInsideTemplatesFolder('模板', '模板'), isTrue);
      expect(service.isInsideTemplatesFolder('模板/日报', '模板'), isTrue);
      expect(service.isInsideTemplatesFolder('模板二', '模板'), isFalse);
      expect(service.isInsideTemplatesFolder('工作', '模板'), isFalse);
      expect(service.isInsideTemplatesFolder('工作', ''), isFalse);
    });
  });

  group('文件夹规则', () {
    final List<Note> notes = <Note>[
      _note('root', '根模板', folder: '模板'),
      _note('work', '工作模板', folder: '模板/工作'),
      _note('deep', '项目模板', folder: '模板/工作'),
      _note('other', '生活模板', folder: '模板'),
    ];

    test('最深的匹配规则胜出，根规则兜底', () {
      final List<FolderTemplateRule> rules = <FolderTemplateRule>[
        const FolderTemplateRule(folderPath: '', templateId: 'root'),
        const FolderTemplateRule(folderPath: '工作', templateId: 'work'),
        const FolderTemplateRule(folderPath: '工作/项目', templateId: 'deep'),
      ];

      expect(
        service
            .folderTemplateFor(
              notes: notes,
              folderPath: '工作/项目/子目录',
              templatesFolder: '模板',
              rules: rules,
            )
            ?.id,
        'deep',
      );
      expect(
        service
            .folderTemplateFor(
              notes: notes,
              folderPath: '工作/其他',
              templatesFolder: '模板',
              rules: rules,
            )
            ?.id,
        'work',
      );
      expect(
        service
            .folderTemplateFor(
              notes: notes,
              folderPath: '生活',
              templatesFolder: '模板',
              rules: rules,
            )
            ?.id,
        'root',
      );
      expect(
        service
            .folderTemplateFor(
              notes: notes,
              folderPath: '',
              templatesFolder: '模板',
              rules: rules,
            )
            ?.id,
        'root',
      );
    });

    test('模板文件夹里永远不套用，根规则也不例外', () {
      final List<FolderTemplateRule> rules = <FolderTemplateRule>[
        const FolderTemplateRule(folderPath: '', templateId: 'root'),
      ];
      expect(
        service.folderTemplateFor(
          notes: notes,
          folderPath: '模板',
          templatesFolder: '模板',
          rules: rules,
        ),
        isNull,
      );
      expect(
        service.folderTemplateFor(
          notes: notes,
          folderPath: '模板/日记',
          templatesFolder: '模板',
          rules: rules,
        ),
        isNull,
      );
    });

    test('规则按 id 引用模板：模板改名后仍然有效', () {
      final Note renamed = _note('work', '日报模板 v2', folder: '模板/工作');
      final List<FolderTemplateRule> rules = <FolderTemplateRule>[
        const FolderTemplateRule(folderPath: '', templateId: 'root'),
        const FolderTemplateRule(folderPath: '工作', templateId: 'work'),
      ];
      expect(
        service
            .folderTemplateFor(
              notes: <Note>[_note('root', '根模板', folder: '模板'), renamed],
              folderPath: '工作',
              templatesFolder: '模板',
              rules: rules,
            )
            ?.title,
        '日报模板 v2',
      );
    });

    test('失效的深层规则被跳过，回退到较浅的规则', () {
      final List<FolderTemplateRule> rules = <FolderTemplateRule>[
        const FolderTemplateRule(folderPath: '', templateId: 'root'),
        const FolderTemplateRule(folderPath: '工作', templateId: 'gone'),
      ];
      expect(
        service
            .folderTemplateFor(
              notes: <Note>[_note('root', '根模板', folder: '模板')],
              folderPath: '工作/项目',
              templatesFolder: '模板',
              rules: rules,
            )
            ?.id,
        'root',
      );
    });

    test('文件夹匹配忽略大小写', () {
      final List<FolderTemplateRule> rules = <FolderTemplateRule>[
        const FolderTemplateRule(folderPath: 'Work', templateId: 'root'),
      ];
      expect(
        service
            .folderTemplateFor(
              notes: <Note>[_note('root', '模板', folder: '模板')],
              folderPath: 'work/子目录',
              templatesFolder: '模板',
              rules: rules,
            )
            ?.id,
        'root',
      );
    });
  });

  group('渲染', () {
    final Note template = _note(
      'tpl',
      '日报',
      folder: '模板',
      body:
          '# <% tp.file.title %>\n'
          '日期：<% tp.date.now("YYYY-MM-DD") %>\n'
          '选中：<% tp.file.selection() %>\n'
          '<% tp.file.cursor() %>',
    );

    test('用当前笔记作上下文，并带回光标标记', () async {
      final Note context = _note('n1', '今日', folder: '工作', body: '旧正文');
      final NtlRenderResult result = await service.render(
        template: template,
        note: context,
        notes: <Note>[template, context],
        interaction: _Interaction(),
        selection: '一段选中的文字',
        now: now,
      );

      expect(result.text, contains('# 今日'));
      expect(result.text, contains('日期：2026-10-23'));
      expect(result.text, contains('选中：一段选中的文字'));
      expect(result.cursorOffset, isNotNull);
      expect(result.text.substring(result.cursorOffset!), isEmpty);
    });

    test('include 支持标题、别名和路径，exists 区分缺失', () async {
      final Note material = _note('m', '素材', body: '素材正文');
      final Note snippet = _note('s', '片段', folder: '模板', body: '片段正文');
      final Note context = _note('n1', '今日', folder: '工作');
      final Note tpl = _note(
        'tpl',
        '引用',
        folder: '模板',
        body:
            '[<% tp.file.include("[[素材]]") %>]'
            '[<% tp.file.include("[[素材|别名]]") %>]'
            '[<% tp.file.include("模板/片段.md") %>]'
            '[<% tp.file.exists("素材") %>]'
            '[<% tp.file.exists("没有这篇") %>]',
      );

      final NtlRenderResult result = await service.render(
        template: tpl,
        note: context,
        notes: <Note>[material, snippet, context, tpl],
        interaction: _Interaction(),
        now: now,
      );

      expect(result.text, '[素材正文][素材正文][片段正文][true][false]');
    });

    test('path(true) 拼出库根下的绝对路径，无桌面文件系统时退回相对路径', () async {
      final Note context = _note('n1', '笔记', folder: '工作');
      final Note tpl = _note(
        'tpl',
        '路径',
        folder: '模板',
        body: '<% tp.file.path(true) %>|<% tp.file.path() %>',
      );

      final NtlRenderResult desktop = await service.render(
        template: tpl,
        note: context,
        notes: <Note>[context, tpl],
        interaction: _Interaction(),
        now: now,
        vaultRoot: r'C:\笔记库',
      );
      expect(desktop.text, r'C:\笔记库/工作/笔记.md|工作/笔记.md');

      final NtlRenderResult web = await service.render(
        template: tpl,
        note: context,
        notes: <Note>[context, tpl],
        interaction: _Interaction(),
        now: now,
      );
      expect(web.text, '工作/笔记.md|工作/笔记.md');
    });

    test('prompt / suggester 通过交互层往返', () async {
      final _Interaction interaction = _Interaction(
        promptAnswer: '小周',
        suggesterIndex: 1,
      );
      final Note context = _note('n1', '今日');
      final Note tpl = _note(
        'tpl',
        '问询',
        folder: '模板',
        body:
            '<%* let who = tp.system.prompt("为谁记录", "我", false); -%>'
            '<% who %>|<% tp.system.suggester(["差", "好"], ["low", "high"]) %>',
      );

      final NtlRenderResult result = await service.render(
        template: tpl,
        note: context,
        notes: <Note>[context, tpl],
        interaction: interaction,
        now: now,
      );

      expect(result.text, '小周|high');
      expect(interaction.prompts.single.text, '为谁记录');
      expect(interaction.prompts.single.defaultValue, '我');
      expect(interaction.suggesters.single.options, <String>['差', '好']);
    });

    test('取消 prompt 时整次渲染中止', () async {
      final _Interaction interaction = _Interaction(promptAnswer: null);
      final Note context = _note('n1', '今日');
      final Note tpl = _note(
        'tpl',
        '问询',
        folder: '模板',
        body: '前<% tp.system.prompt("名字") %>后',
      );

      await expectLater(
        service.render(
          template: tpl,
          note: context,
          notes: <Note>[context, tpl],
          interaction: interaction,
          now: now,
        ),
        throwsA(isA<TemplateCancelled>()),
      );
    });

    test('语法错误与不支持的 API 报错，而不是输出半截文本', () async {
      final Note context = _note('n1', '今日');
      final _Interaction interaction = _Interaction();

      await expectLater(
        service.render(
          template: _note('a', '坏', folder: '模板', body: '前<% for (;;) { } %>后'),
          note: context,
          notes: <Note>[context],
          interaction: interaction,
          now: now,
        ),
        throwsA(isA<TemplateSyntaxError>()),
      );

      await expectLater(
        service.render(
          template: _note(
            'b',
            '坏',
            folder: '模板',
            body: '前<% tp.web.fetch("https://example.com") %>后',
          ),
          note: context,
          notes: <Note>[context],
          interaction: interaction,
          now: now,
        ),
        throwsA(isA<TemplateRuntimeError>()),
      );
    });
  });

  group('引用解析', () {
    final List<Note> notes = <Note>[
      _note('m', '素材', body: '正文'),
      _note('n', '笔记', folder: '工作'),
    ];

    test('标题、别名、文件名和路径都能找到同一篇', () {
      for (final String reference in <String>[
        '素材',
        '[[素材]]',
        '[[素材|别名]]',
        ' 素材 ',
      ]) {
        expect(
          TemplateService.findReference(reference, notes)?.id,
          'm',
          reason: reference,
        );
      }
      for (final String reference in <String>[
        '工作/笔记',
        '工作/笔记.md',
        r'工作\笔记.md',
      ]) {
        expect(
          TemplateService.findReference(reference, notes)?.id,
          'n',
          reason: reference,
        );
      }
      expect(TemplateService.findReference('没有', notes), isNull);
      expect(TemplateService.findReference('[[|别名]]', notes), isNull);
    });
  });
}
