import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/state/template_settings.dart';

void main() {
  Future<({SettingsController settings, SharedPreferences prefs})> load([
    Map<String, Object>? seed,
  ]) async {
    SharedPreferences.setMockInitialValues(seed ?? <String, Object>{});
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return (settings: SettingsController(prefs), prefs: prefs);
  }

  group('模板文件夹', () {
    test('默认是「模板」，非法路径退回默认值', () async {
      final (:settings, :prefs) = await load();
      expect(settings.templatesFolder, '模板');

      settings.templatesFolder = ' 工作 / 模板 ';
      expect(settings.templatesFolder, '工作/模板');
      expect(prefs.getString('nrs.templatesFolder'), '工作/模板');

      settings.templatesFolder = '  ';
      expect(settings.templatesFolder, '模板');
    });

    test('设置同值时不通知，也不重写偏好', () async {
      final (:settings, :prefs) = await load();
      int notifications = 0;
      settings.addListener(() => notifications++);

      settings.templatesFolder = '模板';
      expect(notifications, 0);
      expect(prefs.containsKey('nrs.templatesFolder'), isFalse);
    });
  });

  group('文件夹规则', () {
    test('set / get 往返，并按文件夹稳定编码', () async {
      final (:settings, :prefs) = await load();
      settings.folderTemplateRules = const <FolderTemplateRule>[
        FolderTemplateRule(folderPath: '', templateId: 'root'),
        FolderTemplateRule(folderPath: '工作/项目', templateId: 'deep'),
        FolderTemplateRule(folderPath: '工作', templateId: 'work'),
      ];

      final List<FolderTemplateRule> read = settings.folderTemplateRules;
      expect(read.map((FolderTemplateRule r) => r.folderPath), <String>[
        '',
        '工作',
        '工作/项目',
      ]);
      expect(read.map((FolderTemplateRule r) => r.templateId), <String>[
        'root',
        'work',
        'deep',
      ]);
      expect(prefs.getString('nrs.folderTemplates'), contains('"folder":"工作"'));
    });

    test('同一文件夹只留最后一条规则', () {
      final String encoded = encodeFolderTemplateRules(
        const <FolderTemplateRule>[
          FolderTemplateRule(folderPath: '工作', templateId: 'old'),
          FolderTemplateRule(folderPath: '工作', templateId: 'new'),
        ],
      );
      final List<FolderTemplateRule> decoded = decodeFolderTemplateRules(encoded);
      expect(decoded.length, 1);
      expect(decoded.single.templateId, 'new');
    });

    test('坏 JSON 不阻止启动，读成空规则', () {
      expect(decodeFolderTemplateRules('not json'), isEmpty);
      expect(decodeFolderTemplateRules('{}'), isEmpty);
      expect(
        decodeFolderTemplateRules('[{"folder":"x"},{"template":"t"}]').single,
        const FolderTemplateRule(folderPath: '', templateId: 't'),
        reason: '缺 folder 的规则按根目录规则读，缺 template 的跳过',
      );
    });
  });

  group('自动套用开关', () {
    test('默认关闭并持久化', () async {
      final (:settings, :prefs) = await load();
      expect(settings.autoApplyFolderTemplates, isFalse);
      settings.autoApplyFolderTemplates = true;
      expect(prefs.getBool('nrs.autoApplyFolderTemplates'), isTrue);
    });
  });

  group('模板快捷键', () {
    test('往返并丢掉没有修饰键的绑定', () async {
      final (:settings, :prefs) = await load();
      settings.templateHotkeys = const <String, TemplateHotkey>{
        'tpl-a': TemplateHotkey(
          templateId: 'tpl-a',
          keyId: 78,
          action: TemplateAction.insert,
          control: true,
          shift: true,
        ),
        'tpl-b': TemplateHotkey(
          templateId: 'tpl-b',
          keyId: 66,
          action: TemplateAction.create,
          alt: true,
        ),
        'broken': TemplateHotkey(
          templateId: 'broken',
          keyId: 71,
          action: TemplateAction.insert,
        ),
      };

      final Map<String, TemplateHotkey> read = settings.templateHotkeys;
      expect(read.keys, <String>['tpl-a', 'tpl-b']);
      expect(read['tpl-a']!.control, isTrue);
      expect(read['tpl-a']!.shift, isTrue);
      expect(read['tpl-b']!.action, TemplateAction.create);
      expect(prefs.getString('nrs.templateHotkeys'), isNot(contains('broken')));
    });

    test('同一按键组合的第二个模板被识别为冲突，改动作不算冲突', () {
      const TemplateHotkey first = TemplateHotkey(
        templateId: 'a',
        keyId: 78,
        action: TemplateAction.insert,
        control: true,
      );
      const TemplateHotkey second = TemplateHotkey(
        templateId: 'b',
        keyId: 78,
        action: TemplateAction.create,
        control: true,
      );
      const TemplateHotkey changedAction = TemplateHotkey(
        templateId: 'a',
        keyId: 78,
        action: TemplateAction.create,
        control: true,
      );
      const TemplateHotkey other = TemplateHotkey(
        templateId: 'c',
        keyId: 78,
        action: TemplateAction.insert,
        control: true,
        shift: true,
      );

      final Map<String, TemplateHotkey> bindings = <String, TemplateHotkey>{
        'a': first,
      };
      expect(templateHotkeyConflict(bindings, second), 'a');
      expect(templateHotkeyConflict(bindings, changedAction), isNull);
      expect(templateHotkeyConflict(bindings, other), isNull);
    });

    test('坏 JSON 与无效绑定都读成空表', () {
      expect(decodeTemplateHotkeys('nope'), isEmpty);
      expect(decodeTemplateHotkeys('[]'), isEmpty);
      expect(
        decodeTemplateHotkeys('{"a":{"keyId":0,"control":true}}'),
        isEmpty,
      );
      expect(
        decodeTemplateHotkeys('{"a":{"keyId":70,"control":false}}'),
        isEmpty,
      );
    });
  });
}
