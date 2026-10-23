import 'dart:math' as math;

import 'template_date_format.dart';
import 'template_error.dart';
import 'template_interpreter.dart';

/// Everything the `tp.*` objects are allowed to ask of NRS.
///
/// The template language itself never touches the vault, the window or the
/// clipboard: it reaches them through this interface, so tests can supply a
/// deterministic host and the Web build never sees a desktop-only call.
abstract class TemplateHost {
  DateTime now();

  String get noteTitle;
  String get noteContent;
  List<String> get noteTags;

  /// Vault-relative path, `/`-separated.
  String get noteRelativePath;
  String get noteFolder;
  DateTime get noteCreatedAt;
  DateTime get noteUpdatedAt;

  /// Text selected in the editor when the template was invoked; empty for a
  /// new note or an automatic template.
  String get selection;

  /// Absolute path for a vault-relative path; null on platforms without a real
  /// filesystem (the browser build).
  String? absolutePathFor(String relativePath);

  /// Body of a note named by `[[title]]`, `[[title|alias]]`, a title or a path.
  String? noteBodyForReference(String reference);
  bool noteExistsForReference(String reference);

  Future<String?> prompt({
    required String text,
    required String defaultValue,
    required bool multiline,
  });

  /// Index into [options], or null when dismissed.
  Future<int?> suggester({
    required List<String> options,
    required String placeholder,
  });

  Future<String> clipboard();
}

/// Builds the `tp` root handed to the interpreter as a global.
NtlObject buildTemplateApi(TemplateHost host) {
  final NtlObject date = _dateApi(host);
  final NtlObject file = _fileApi(host);
  final NtlObject system = _systemApi(host);
  final NtlObject frontmatter = _ApiObject(
    'tp.frontmatter',
    <String, Object?>{
      'title': host.noteTitle,
      'tags': host.noteTags,
      'created': host.noteCreatedAt.toIso8601String(),
      'updated': host.noteUpdatedAt.toIso8601String(),
    },
    onMissing: (String name) => NtlUnavailable(
      'NRS 的 front-matter 只保留 title、tags、created、updated；'
      '「$name」这类自定义字段目前不会保存，也无法在模板里读取',
    ),
  );

  return _ApiObject(
    'tp',
    <String, Object?>{
      'date': date,
      'file': file,
      'system': system,
      'frontmatter': frontmatter,
      'web': const NtlUnavailable('本版本不支持 tp.web：模板不会发起任何网络请求'),
      'obsidian': const NtlUnavailable('本版本不支持 tp.obsidian：NRS 不是 Obsidian'),
      'app': const NtlUnavailable('本版本不支持 tp.app'),
      'config': const NtlUnavailable('本版本不支持 tp.config'),
      'hooks': const NtlUnavailable('本版本不支持 tp.hooks'),
    },
  );
}

NtlObject _dateApi(TemplateHost host) {
  String format(List<Object?> args, NtlCallSite site, [String? fallback]) =>
      _stringArg(
        args,
        0,
        'format',
        site,
        fallback: fallback ?? 'YYYY-MM-DD',
      );

  return _ApiObject('tp.date', <String, Object?>{
    'now': _ApiFunction('tp.date.now', (List<Object?> args, NtlCallSite site) async {
      final String pattern = format(args, site);
      final Object? offset = args.length > 1 ? args[1] : 0;
      final DateTime date = _offsetDate(host.now(), offset, 'offset', site);
      return formatNtlDate(date, pattern);
    }),
    'tomorrow': _ApiFunction(
      'tp.date.tomorrow',
      (List<Object?> args, NtlCallSite site) async {
        final String pattern = format(args, site);
        return formatNtlDate(
          host.now().add(const Duration(days: 1)),
          pattern,
        );
      },
    ),
    'yesterday': _ApiFunction(
      'tp.date.yesterday',
      (List<Object?> args, NtlCallSite site) async {
        final String pattern = format(args, site);
        return formatNtlDate(
          host.now().subtract(const Duration(days: 1)),
          pattern,
        );
      },
    ),
    'weekday': _ApiFunction(
      'tp.date.weekday',
      (List<Object?> args, NtlCallSite site) async {
        final String pattern = format(args, site);
        final int weekday = _intArg(args, 1, 'weekday', site);
        if (weekday < 0 || weekday > 6) {
          site.error('weekday 必须在 0（周日）到 6（周六）之间');
        }
        final DateTime now = host.now();
        final DateTime monday = now.subtract(Duration(days: now.weekday - 1));
        final int step = weekday == 0 ? 6 : weekday - 1;
        return formatNtlDate(monday.add(Duration(days: step)), pattern);
      },
    ),
  });
}

NtlObject _fileApi(TemplateHost host) {
  return _ApiObject('tp.file', <String, Object?>{
    'title': _LazyValue(() => host.noteTitle),
    'content': _LazyValue(() => host.noteContent),
    'tags': _LazyValue(() => host.noteTags),
    'path': _ApiFunction('tp.file.path', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      final bool absolute = _boolArg(args, 0, 'absolute', site);
      if (absolute) {
        return host.absolutePathFor(host.noteRelativePath) ??
            host.noteRelativePath;
      }
      return host.noteRelativePath;
    }),
    'folder': _ApiFunction('tp.file.folder', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      final bool absolute = _boolArg(args, 0, 'absolute', site);
      if (absolute) {
        return host.absolutePathFor(host.noteFolder) ?? host.noteFolder;
      }
      return host.noteFolder;
    }),
    'creation_date': _ApiFunction('tp.file.creation_date', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      return _dateValue(host.noteCreatedAt, args, site);
    }),
    'last_modified_date': _ApiFunction('tp.file.last_modified_date', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      return _dateValue(host.noteUpdatedAt, args, site);
    }),
    'cursor': _ApiFunction('tp.file.cursor', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      final int order = args.isEmpty
          ? 1
          : _intArg(args, 0, 'order', site);
      if (order < 1) site.error('order 必须从 1 开始');
      site.output.cursor(order);
      return null;
    }),
    'selection': _ApiFunction('tp.file.selection', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      return host.selection;
    }),
    'include': _ApiFunction('tp.file.include', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      final String reference = _stringArg(args, 0, '笔记', site);
      final String? body = host.noteBodyForReference(reference);
      if (body == null) {
        site.error('找不到要包含的笔记「$reference」');
      }
      return body;
    }),
    'exists': _ApiFunction('tp.file.exists', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      final String reference = _stringArg(args, 0, '笔记', site);
      return host.noteExistsForReference(reference);
    }),
    'create_new': _unsupported('tp.file.create_new', '本版本不支持文件操作函数 tp.file.create_new'),
    'rename': _unsupported('tp.file.rename', '本版本不支持文件操作函数 tp.file.rename'),
    'move': _unsupported('tp.file.move', '本版本不支持文件操作函数 tp.file.move'),
    'cursor_append': _unsupported(
      'tp.file.cursor_append',
      '本版本不支持 tp.file.cursor_append',
    ),
    'find_tfile': _unsupported(
      'tp.file.find_tfile',
      '本版本不支持 tp.file.find_tfile',
    ),
  });
}

NtlObject _systemApi(TemplateHost host) {
  return _ApiObject('tp.system', <String, Object?>{
    'prompt': _ApiFunction('tp.system.prompt', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      final String text = _stringArg(
        args,
        0,
        'text',
        site,
        fallback: '',
        nullMeansFallback: true,
      );
      final String defaultValue = _stringArg(
        args,
        1,
        'default',
        site,
        fallback: '',
        nullMeansFallback: true,
      );
      final bool multiline = _boolArg(args, 2, 'multiline', site);
      final String? answer = await host.prompt(
        text: text,
        defaultValue: defaultValue,
        multiline: multiline,
      );
      if (answer == null) throw const TemplateCancelled();
      return answer;
    }),
    'suggester': _ApiFunction('tp.system.suggester', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      final List<Object?> textItems = _listArg(args, 0, 'textItems', site);
      final List<Object?> items = args.length > 1
          ? _listArg(args, 1, 'items', site)
          : textItems;
      if (textItems.isEmpty) site.error('textItems 不能为空');
      if (textItems.length != items.length) {
        site.error('textItems 与 items 的长度必须一致');
      }
      final String placeholder = _stringArg(
        args,
        2,
        'placeholder',
        site,
        fallback: '',
        nullMeansFallback: true,
      );
      final int? index = await host.suggester(
        options: <String>[
          for (final Object? item in textItems) stringifyNtl(item),
        ],
        placeholder: placeholder,
      );
      if (index == null) throw const TemplateCancelled();
      if (index < 0 || index >= items.length) {
        site.error('选择结果超出了列表范围');
      }
      return items[index];
    }),
    'clipboard': _ApiFunction('tp.system.clipboard', (
      List<Object?> args,
      NtlCallSite site,
    ) async {
      return host.clipboard();
    }),
    'multi_suggester': _unsupported(
      'tp.system.multi_suggester',
      '本版本不支持多选列表 tp.system.multi_suggester',
    ),
  });
}

// -------------------------------------------------------------------- values

/// A value that is computed when read, so note properties stay current even if
/// a prompt changed the draft between two tags.
class _LazyValue {
  const _LazyValue(this.read);

  final Object? Function() read;
}

class _ApiObject implements NtlObject {
  _ApiObject(
    this.ntlName,
    this._members, {
    this.onMissing,
  });

  @override
  final String ntlName;

  final Map<String, Object?> _members;
  final Object? Function(String name)? onMissing;

  @override
  Object? member(String name) {
    if (_members.containsKey(name)) {
      final Object? value = _members[name];
      if (value is _LazyValue) return value.read();
      return value;
    }
    return onMissing?.call(name) ?? ntlMissing;
  }
}

class _ApiFunction implements NtlCallable {
  const _ApiFunction(this.ntlName, this._body);

  @override
  final String ntlName;
  final Future<Object?> Function(List<Object?> arguments, NtlCallSite site)
  _body;

  @override
  Future<Object?> call(List<Object?> arguments, NtlCallSite site) =>
      _body(arguments, site);
}

NtlCallable _unsupported(String name, String message) {
  return _ApiFunction(name, (List<Object?> args, NtlCallSite site) async {
    site.error(message);
  });
}

// ----------------------------------------------------------------- arguments

String _stringArg(
  List<Object?> args,
  int index,
  String name,
  NtlCallSite site, {
  String? fallback,
  bool nullMeansFallback = false,
}) {
  if (index >= args.length) {
    if (fallback != null) return fallback;
    site.error('缺少参数「$name」');
  }
  final Object? value = args[index];
  if (value == null && nullMeansFallback && fallback != null) return fallback;
  if (value is! String) site.error('参数「$name」需要字符串');
  return value;
}

int _intArg(
  List<Object?> args,
  int index,
  String name,
  NtlCallSite site, {
  int? fallback,
}) {
  if (index >= args.length) {
    if (fallback != null) return fallback;
    site.error('缺少参数「$name」');
  }
  final Object? value = args[index];
  if (value is! num || value != value.truncateToDouble()) {
    site.error('参数「$name」需要整数');
  }
  return value.toInt();
}

bool _boolArg(
  List<Object?> args,
  int index,
  String name,
  NtlCallSite site, {
  bool fallback = false,
}) {
  if (index >= args.length) return fallback;
  final Object? value = args[index];
  if (value is! bool) site.error('参数「$name」需要 true 或 false');
  return value;
}

List<Object?> _listArg(
  List<Object?> args,
  int index,
  String name,
  NtlCallSite site,
) {
  if (index >= args.length) site.error('缺少参数「$name」');
  final Object? value = args[index];
  if (value is! List) site.error('参数「$name」需要数组');
  return value.cast<Object?>();
}

Object _dateValue(DateTime date, List<Object?> args, NtlCallSite site) {
  if (args.isEmpty || args[0] == null) return date.toIso8601String();
  final String pattern = _stringArg(args, 0, 'format', site);
  return formatNtlDate(date, pattern);
}

DateTime _offsetDate(
  DateTime date,
  Object? raw,
  String name,
  NtlCallSite site,
) {
  if (raw == null || (raw is num && raw == 0)) return date;
  if (raw is num) {
    return date.add(Duration(days: raw.toInt()));
  }
  if (raw is! String) {
    site.error('参数「$name」需要天数或 "2d" 这样的时长');
  }
  final RegExpMatch? match = RegExp(
    r'^([+-]?\d+)\s*(s|m|h|d|w|M|y)$',
  ).firstMatch(raw.trim());
  if (match == null) {
    site.error('无法识别的时间偏移「$raw」，请写成 2d、-1w、3h 这样的形式');
  }
  final int amount = int.parse(match.group(1)!);
  switch (match.group(2)!) {
    case 's':
      return date.add(Duration(seconds: amount));
    case 'm':
      return date.add(Duration(minutes: amount));
    case 'h':
      return date.add(Duration(hours: amount));
    case 'd':
      return date.add(Duration(days: amount));
    case 'w':
      return date.add(Duration(days: amount * 7));
    case 'M':
      return _addMonths(date, amount);
    default:
      return _addYears(date, amount);
  }
}

DateTime _addMonths(DateTime date, int months) {
  final int total = date.year * 12 + (date.month - 1) + months;
  final int year = total ~/ 12;
  final int month = total % 12 + 1;
  final int day = math.min(date.day, DateTime(year, month + 1, 0).day);
  return DateTime(
    year,
    month,
    day,
    date.hour,
    date.minute,
    date.second,
    date.millisecond,
    date.microsecond,
  );
}

DateTime _addYears(DateTime date, int years) {
  final int year = date.year + years;
  final int day = math.min(date.day, DateTime(year, date.month + 1, 0).day);
  return DateTime(
    year,
    date.month,
    day,
    date.hour,
    date.minute,
    date.second,
    date.millisecond,
    date.microsecond,
  );
}
