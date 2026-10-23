import '../data/models/note.dart';
import '../state/template_settings.dart';
import 'template_api.dart';
import 'template_ast.dart';
import 'template_interpreter.dart';
import 'template_parser.dart';

/// The UI half of `tp.system.*`.
///
/// The template language is pure Dart, so prompts, suggesters and the clipboard
/// arrive through this contract. The desktop shell supplies real dialogs; tests
/// supply deterministic answers.
abstract class TemplateInteraction {
  /// The user's answer, or null when the dialog was cancelled.
  Future<String?> prompt({
    required String text,
    required String defaultValue,
    required bool multiline,
  });

  /// Index into [options], or null when the dialog was cancelled.
  Future<int?> suggester({
    required List<String> options,
    required String placeholder,
  });

  Future<String> clipboard();
}

/// Discovery, folder rules and rendering for template notes.
///
/// It deliberately owns no state: the vault list, the settings and the current
/// note are passed in on each call, so a renamed folder or a freshly created
/// note is picked up without a cache to invalidate.
class TemplateService {
  const TemplateService();

  /// Every note inside [templatesFolder] and its sub-folders, ordered by path.
  ///
  /// The templates folder is part of the vault, not a hidden directory: these
  /// are ordinary notes and stay visible in the tree, search and tag views.
  List<Note> discoverTemplates(List<Note> notes, String templatesFolder) {
    final String folder = Note.normalizeFolderPath(templatesFolder);
    if (folder.isEmpty) return const <Note>[];
    final String lower = folder.toLowerCase();
    final List<Note> found = <Note>[
      for (final Note note in notes)
        if (_inside(note.folderPath, lower)) note,
    ]..sort((Note a, Note b) {
      final int byPath = a.relativePath.toLowerCase().compareTo(
        b.relativePath.toLowerCase(),
      );
      return byPath != 0 ? byPath : a.relativePath.compareTo(b.relativePath);
    });
    return found;
  }

  /// True when [folderPath] is the templates folder or sits below it.
  ///
  /// Notes created there never pick up a folder template: a template that
  /// applies another template would make the folder self-referential.
  bool isInsideTemplatesFolder(String folderPath, String templatesFolder) {
    final String folder = Note.normalizeFolderPath(folderPath).toLowerCase();
    final String templates = Note.normalizeFolderPath(
      templatesFolder,
    ).toLowerCase();
    if (templates.isEmpty) return false;
    return folder == templates || folder.startsWith('$templates/');
  }

  /// The template a new note in [folderPath] should start from, or null.
  ///
  /// The deepest matching rule wins, so a rule for 工作/项目 overrides one for
  /// 工作, and a root rule is the catch-all. A rule whose template was deleted
  /// is skipped and the next shallower rule gets its turn.
  Note? folderTemplateFor({
    required List<Note> notes,
    required String folderPath,
    required String templatesFolder,
    required List<FolderTemplateRule> rules,
  }) {
    if (rules.isEmpty) return null;
    if (isInsideTemplatesFolder(folderPath, templatesFolder)) return null;
    final String folder = Note.normalizeFolderPath(folderPath);

    final List<({FolderTemplateRule rule, int index})> matching =
        <({FolderTemplateRule rule, int index})>[
          for (int i = 0; i < rules.length; i++)
            if (rules[i].matches(folder)) (rule: rules[i], index: i),
        ]..sort((({FolderTemplateRule rule, int index}) a,
                ({FolderTemplateRule rule, int index}) b) {
            final int byDepth = b.rule.depth.compareTo(a.rule.depth);
            return byDepth != 0 ? byDepth : a.index.compareTo(b.index);
          });

    for (final ({FolderTemplateRule rule, int index}) item in matching) {
      for (final Note note in notes) {
        if (note.id == item.rule.templateId) return note;
      }
    }
    return null;
  }

  /// Renders [template] with [note] as its context.
  ///
  /// Rendering happens entirely in memory. A syntax error, a runtime error or
  /// [TemplateCancelled] escapes to the caller before anything is written; the
  /// caller is what decides whether an empty note stays behind.
  Future<NtlRenderResult> render({
    required Note template,
    required Note note,
    required List<Note> notes,
    required TemplateInteraction interaction,
    String selection = '',
    DateTime? now,
    String? vaultRoot,
  }) async {
    final NtlTemplate parsed = TemplateParser(template.body).parse();
    final TemplateHost host = _VaultTemplateHost(
      note: note,
      notes: notes,
      interaction: interaction,
      selection: selection,
      timestamp: now ?? DateTime.now(),
      vaultRoot: vaultRoot,
    );
    return TemplateInterpreter().render(
      parsed,
      globals: <String, Object?>{'tp': buildTemplateApi(host)},
    );
  }

  /// Resolves `[[标题]]`, `[[标题|别名]]`, a title, a file name or a
  /// vault-relative path to a note.
  ///
  /// Paths are tried before titles when the reference looks like a path. A
  /// title lookup is case-insensitive and keeps the vault's order when two
  /// notes share a title, which is the same first-match rule the link jump
  /// uses.
  static Note? findReference(String reference, List<Note> notes) {
    String ref = reference.trim();
    if (ref.startsWith('[[') && ref.endsWith(']]')) {
      ref = ref.substring(2, ref.length - 2);
    }
    final int alias = ref.indexOf('|');
    if (alias >= 0) ref = ref.substring(0, alias);
    ref = ref.trim();
    if (ref.isEmpty) return null;

    final String lower = ref.toLowerCase();
    final String path = lower.replaceAll('\\', '/');
    final bool looksLikePath = path.contains('/') || path.endsWith('.md');
    final String withMd = path.endsWith('.md') ? path : '$path.md';

    if (looksLikePath) {
      for (final Note note in notes) {
        final String relative = note.relativePath.toLowerCase();
        if (relative == withMd || relative == path) return note;
      }
    }
    for (final Note note in notes) {
      if (note.title.trim().toLowerCase() == lower) return note;
    }
    for (final Note note in notes) {
      if (note.fileName.toLowerCase() == withMd) return note;
    }
    return null;
  }

  bool _inside(String folderPath, String lowerTemplatesFolder) {
    final String folder = folderPath.toLowerCase();
    return folder == lowerTemplatesFolder ||
        folder.startsWith('$lowerTemplatesFolder/');
  }
}

class _VaultTemplateHost implements TemplateHost {
  _VaultTemplateHost({
    required this.note,
    required this.notes,
    required this.interaction,
    required this.selection,
    required this.timestamp,
    required this.vaultRoot,
  });

  final Note note;
  final List<Note> notes;
  final TemplateInteraction interaction;
  @override
  final String selection;
  final DateTime timestamp;
  final String? vaultRoot;

  @override
  String get noteTitle => note.title;

  @override
  String get noteContent => note.body;

  @override
  List<String> get noteTags => note.tags;

  @override
  String get noteRelativePath => note.relativePath;

  @override
  String get noteFolder => note.folderPath;

  @override
  DateTime get noteCreatedAt => note.createdAt;

  @override
  DateTime get noteUpdatedAt => note.updatedAt;

  @override
  String? absolutePathFor(String relativePath) {
    final String root = vaultRoot?.trim() ?? '';
    if (root.isEmpty) return null;
    final String relative = relativePath.replaceAll('\\', '/');
    if (relative.isEmpty) return root;
    return root.endsWith('/') || root.endsWith('\\')
        ? '$root$relative'
        : '$root/$relative';
  }

  @override
  String? noteBodyForReference(String reference) =>
      TemplateService.findReference(reference, notes)?.body;

  @override
  bool noteExistsForReference(String reference) =>
      TemplateService.findReference(reference, notes) != null;

  @override
  Future<String?> prompt({
    required String text,
    required String defaultValue,
    required bool multiline,
  }) => interaction.prompt(
    text: text,
    defaultValue: defaultValue,
    multiline: multiline,
  );

  @override
  Future<int?> suggester({
    required List<String> options,
    required String placeholder,
  }) => interaction.suggester(options: options, placeholder: placeholder);

  @override
  Future<String> clipboard() => interaction.clipboard();

  @override
  DateTime now() => timestamp;
}
