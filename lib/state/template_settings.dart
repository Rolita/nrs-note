import 'dart:convert';

import '../data/models/note.dart';

/// The default folder that holds templates. Kept here rather than in the
/// controller so the service can name it without importing UI state.
const String kDefaultTemplatesFolder = '模板';

/// One「文件夹 → 模板」rule used for automatic application.
///
/// The template is referenced by note **id**, not by path: renaming or moving
/// the template must not silently detach every rule that points at it.
class FolderTemplateRule {
  const FolderTemplateRule({
    required this.folderPath,
    required this.templateId,
  });

  /// Normalized vault-relative folder. Empty means the vault root, which is the
  /// catch-all rule.
  final String folderPath;

  final String templateId;

  bool get isRoot => folderPath.isEmpty;

  /// Number of path segments, used to pick the deepest matching rule.
  int get depth => folderPath.isEmpty ? 0 : folderPath.split('/').length;

  /// Whether a new note landing in [folder] should use this rule.
  ///
  /// Matching is case-insensitive: vault folders come from the file system,
  /// where Windows and macOS treat `Work` and `work` as the same directory.
  bool matches(String folder) {
    final String target = Note.normalizeFolderPath(folder).toLowerCase();
    final String rule = folderPath.toLowerCase();
    if (rule.isEmpty) return true;
    return target == rule || target.startsWith('$rule/');
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'folder': folderPath,
    'template': templateId,
  };

  static FolderTemplateRule? tryDecode(Object? raw) {
    if (raw is! Map) return null;
    final Object? folder = raw['folder'];
    final Object? template = raw['template'];
    if (template is! String || template.trim().isEmpty) return null;
    return FolderTemplateRule(
      folderPath: Note.normalizeFolderPath(folder is String ? folder : ''),
      templateId: template.trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FolderTemplateRule &&
      other.folderPath.toLowerCase() == folderPath.toLowerCase() &&
      other.templateId == templateId;

  @override
  int get hashCode =>
      Object.hash(folderPath.toLowerCase(), templateId);

  @override
  String toString() => 'FolderTemplateRule($folderPath -> $templateId)';
}

/// What a template hotkey does when pressed.
enum TemplateAction {
  /// Render the template into the note that is open, at the caret.
  insert,

  /// Create a note from the template.
  create;

  String get label => switch (this) {
    TemplateAction.insert => '插入到当前笔记',
    TemplateAction.create => '新建笔记',
  };
}

/// One template's keyboard shortcut.
///
/// The key is stored as [LogicalKeyboardKey.keyId] plus modifier booleans, so
/// the binding follows the physical key rather than the character the current
/// layout prints on it.
class TemplateHotkey {
  const TemplateHotkey({
    required this.templateId,
    required this.keyId,
    required this.action,
    this.control = false,
    this.alt = false,
    this.shift = false,
  });

  final String templateId;
  final int keyId;
  final TemplateAction action;
  final bool control;
  final bool alt;
  final bool shift;

  /// A binding without a modifier would steal ordinary typing, so it is never
  /// registered.
  bool get hasModifier => control || alt || shift;

  bool get isValid =>
      templateId.trim().isNotEmpty && keyId > 0 && hasModifier;

  /// Whether two bindings press the same chord, regardless of which template
  /// they belong to or what they do.
  bool sameChord(TemplateHotkey other) =>
      keyId == other.keyId &&
      control == other.control &&
      alt == other.alt &&
      shift == other.shift;

  Map<String, Object?> toJson() => <String, Object?>{
    'keyId': keyId,
    'control': control,
    'alt': alt,
    'shift': shift,
    'action': action.name,
  };

  static TemplateHotkey? tryDecode(String templateId, Object? raw) {
    if (raw is! Map) return null;
    final Object? keyId = raw['keyId'];
    if (keyId is! int || keyId <= 0) return null;
    final String actionName = raw['action'] is String
        ? raw['action']! as String
        : TemplateAction.insert.name;
    final TemplateAction action = TemplateAction.values.firstWhere(
      (TemplateAction a) => a.name == actionName,
      orElse: () => TemplateAction.insert,
    );
    return TemplateHotkey(
      templateId: templateId,
      keyId: keyId,
      action: action,
      control: raw['control'] == true,
      alt: raw['alt'] == true,
      shift: raw['shift'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TemplateHotkey &&
      other.templateId == templateId &&
      other.keyId == keyId &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift &&
      other.action == action;

  @override
  int get hashCode =>
      Object.hash(templateId, keyId, control, alt, shift, action);

  @override
  String toString() =>
      'TemplateHotkey($templateId, keyId=$keyId, '
      'ctrl=$control, alt=$alt, shift=$shift, ${action.name})';
}

/// Decodes the stored rule list. Malformed input yields an empty list: settings
/// are read at start-up, and a bad value must not keep the app from opening.
List<FolderTemplateRule> decodeFolderTemplateRules(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <FolderTemplateRule>[];
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <FolderTemplateRule>[];
    final Map<String, FolderTemplateRule> byFolder =
        <String, FolderTemplateRule>{};
    for (final Object? item in decoded) {
      final FolderTemplateRule? rule = FolderTemplateRule.tryDecode(item);
      if (rule == null) continue;
      // One folder, one rule: the last one wins, so editing an existing rule
      // replaces it instead of creating a second line for the same folder.
      byFolder[rule.folderPath.toLowerCase()] = rule;
    }
    return List<FolderTemplateRule>.unmodifiable(byFolder.values);
  } on FormatException {
    return const <FolderTemplateRule>[];
  }
}

/// Encodes rules in a stable order, so `settings == settings` can be checked by
/// comparing the serialized form.
String encodeFolderTemplateRules(Iterable<FolderTemplateRule> rules) {
  // One folder, one rule. Last-wins matches the decoder and lets the settings
  // UI replace a rule by appending its new version.
  final Map<String, FolderTemplateRule> byFolder =
      <String, FolderTemplateRule>{};
  for (final FolderTemplateRule rule in rules) {
    if (rule.templateId.trim().isEmpty) continue;
    byFolder[rule.folderPath.toLowerCase()] = rule;
  }
  final List<FolderTemplateRule> sorted = byFolder.values.toList()
    ..sort((FolderTemplateRule a, FolderTemplateRule b) {
      final int byFolder = a.folderPath.toLowerCase().compareTo(
        b.folderPath.toLowerCase(),
      );
      return byFolder != 0 ? byFolder : a.templateId.compareTo(b.templateId);
    });
  return jsonEncode(<Map<String, Object?>>[
    for (final FolderTemplateRule rule in sorted) rule.toJson(),
  ]);
}

/// Decodes template shortcuts, keyed by template note id.
Map<String, TemplateHotkey> decodeTemplateHotkeys(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, TemplateHotkey>{};
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return const <String, TemplateHotkey>{};
    final Map<String, TemplateHotkey> out = <String, TemplateHotkey>{};
    for (final MapEntry<Object?, Object?> entry in decoded.entries) {
      final Object? id = entry.key;
      if (id is! String || id.isEmpty) continue;
      final TemplateHotkey? binding = TemplateHotkey.tryDecode(id, entry.value);
      if (binding == null || !binding.isValid) continue;
      out[id] = binding;
    }
    return Map<String, TemplateHotkey>.unmodifiable(out);
  } on FormatException {
    return const <String, TemplateHotkey>{};
  }
}

/// Encodes shortcuts in template-id order; the stored form is the equality key.
String encodeTemplateHotkeys(Map<String, TemplateHotkey> bindings) {
  final List<String> ids = bindings.keys.toList()..sort();
  final Map<String, Object?> out = <String, Object?>{};
  for (final String id in ids) {
    final TemplateHotkey? binding = bindings[id];
    if (binding == null || !binding.isValid) continue;
    out[id] = binding.toJson();
  }
  return jsonEncode(out);
}

/// The id of the template already using [candidate]'s chord, or null.
///
/// Settings uses this to refuse a second binding instead of silently letting
/// one of the two templates never fire.
String? templateHotkeyConflict(
  Map<String, TemplateHotkey> bindings,
  TemplateHotkey candidate,
) {
  for (final MapEntry<String, TemplateHotkey> entry in bindings.entries) {
    if (entry.key == candidate.templateId) continue;
    if (entry.value.sameChord(candidate)) return entry.key;
  }
  return null;
}
