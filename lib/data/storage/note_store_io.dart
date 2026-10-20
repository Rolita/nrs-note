import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import 'atomic_file.dart';
import 'note_store.dart';

/// Desktop implementation: one real `.md` file per note inside a vault folder
/// the user can open in Explorer / Finder.
///
/// Folders in the tree are real directories, not a label stored in the file.
/// Moving a note by hand therefore moves it in the app, and an empty directory
/// the user made is still visible after a restart.
class IoNoteStore with NoteStoreSupport implements NoteStore {
  IoNoteStore({
    this.folderName = 'NRS Notes',
    this.overrideRoot,
    AtomicFileWriter? writer,
  }) : _writer = writer ?? AtomicFileWriter();

  final String folderName;
  final Directory? overrideRoot;
  final AtomicFileWriter _writer;

  Directory? _vault;
  String _location = '';

  @override
  String get location => _location;

  @override
  bool get supportsNativeFiles => true;

  Directory get vault {
    final Directory? v = _vault;
    if (v == null) {
      throw StateError('IoNoteStore.init() must be awaited before use.');
    }
    return v;
  }

  @override
  Future<void> init() async {
    if (_vault != null) return;
    final Directory root =
        overrideRoot ?? await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${root.path}${Platform.pathSeparator}$folderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _vault = dir;
    _location = dir.path;

    // A crash mid-write can leave a backup or a half-written temp behind. Put
    // the vault back together *before* deciding whether it is empty, otherwise
    // a recovered note would not count and a welcome note would be seeded on
    // top of it.
    await _writer.recover(dir);

    final List<File> existing = await _mdFiles();
    if (existing.isEmpty) {
      final Note welcome = Note.welcome();
      await _writer.replace(
        File(_pathFor(welcome.relativePath)),
        welcome.toMarkdown(),
      );
    }
  }

  Future<List<File>> _mdFiles() async {
    final Directory dir = vault;
    try {
      final List<FileSystemEntity> entries = await dir
          .list(recursive: true, followLinks: false)
          .toList();
      return entries
          .whereType<File>()
          .where((File f) => f.path.toLowerCase().endsWith('.md'))
          .toList(growable: false);
    } on FileSystemException {
      return const <File>[];
    }
  }

  /// `/`-separated path below the vault root, the form [Note.relativePath] uses.
  String _relativeOf(FileSystemEntity entity) => entity.path
      .substring(vault.path.length)
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'^/+'), '');

  String _pathFor(String relativePath) {
    final List<String> parts = relativePath
        .split('/')
        .where((String p) => p.isNotEmpty)
        .toList();
    return <String>[vault.path, ...parts].join(Platform.pathSeparator);
  }

  String _baseName(String fileName) => fileName.split(RegExp(r'[\\/]')).last;

  String _folderOf(String relativePath) {
    final int slash = relativePath.lastIndexOf('/');
    return slash < 0 ? '' : relativePath.substring(0, slash);
  }

  String _join(String folderPath, String fileName) {
    final String folder = Note.normalizeFolderPath(folderPath);
    return folder.isEmpty ? fileName : '$folder/$fileName';
  }

  @override
  Future<List<String>> listFolders() async {
    try {
      final List<FileSystemEntity> entries = await vault
          .list(recursive: true, followLinks: false)
          .toList();
      final List<String> folders = entries
          .whereType<Directory>()
          .map(_relativeOf)
          .where((String p) => p.isNotEmpty)
          .toList();
      folders.sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return folders;
    } on FileSystemException {
      return const <String>[];
    }
  }

  @override
  Future<String> createFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return '';
    await Directory(_pathFor(folder)).create(recursive: true);
    return folder;
  }

  @override
  Future<bool> renameFolder(String from, String to) async {
    final String source = Note.normalizeFolderPath(from);
    final String target = Note.normalizeFolderPath(to);
    if (source.isEmpty || target.isEmpty || source == target) return false;
    final Directory sourceDir = Directory(_pathFor(source));
    if (!await sourceDir.exists()) return false;
    if (await Directory(_pathFor(target)).exists()) return false;
    try {
      await sourceDir.rename(_pathFor(target));
      return true;
    } on FileSystemException {
      // A folder in use, or a permission problem: report it rather than
      // pretending the rename happened.
      return false;
    }
  }

  @override
  Future<List<NoteFileStamp>> stamps() async {
    final List<NoteFileStamp> stamps = <NoteFileStamp>[];
    for (final File file in await _mdFiles()) {
      try {
        final FileStat stat = await file.stat();
        stamps.add(
          NoteFileStamp(
            relativePath: _relativeOf(file),
            modifiedAt: stat.modified,
            size: stat.size,
          ),
        );
      } on FileSystemException {
        // Vanished mid-scan: it simply is not part of this snapshot.
      }
    }
    return stamps;
  }

  @override
  Future<NoteFileStamp?> stampOf(String relativePath) async {
    final File file = File(_pathFor(relativePath.replaceAll('\\', '/')));
    try {
      if (!await file.exists()) return null;
      final FileStat stat = await file.stat();
      return NoteFileStamp(
        relativePath: _relativeOf(file),
        modifiedAt: stat.modified,
        size: stat.size,
      );
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<List<Note>> loadAll() async {
    final List<File> files = await _mdFiles();
    final List<Note> notes = <Note>[];
    for (final File f in files) {
      try {
        final String raw = await f.readAsString();
        final DateTime modified = await f.lastModified();
        final String relative = _relativeOf(f);
        final String folder = _folderOf(relative);
        final String name = _baseName(relative);
        final String fileName = await _migrateLegacyName(
          f,
          name,
          folder,
          raw,
        );
        notes.add(
          Note.fromMarkdown(
            raw,
            fileName,
            modified,
            folderPath: folder,
          ),
        );
      } on FileSystemException {
        // A file locked by another process should never take the app down.
        continue;
      }
    }
    return sortNotes(notes);
  }

  /// Renames a file written by the old `<title>-<id>.md` scheme to `<title>.md`,
  /// inside its own folder.
  ///
  /// NRS used to hide a short id in the file name to keep names unique. The
  /// file name is now the note's name, so that suffix is not just noise — it
  /// would show up *in the title*. The migration is deliberately conservative:
  /// it only fires when the stem is exactly `<slug>-<6 chars>` **and** the slug
  /// is the slug of the note's own title, i.e. a file this app named itself.
  /// Anything the user renamed by hand is left alone, as is any target that is
  /// already taken in that folder.
  Future<String> _migrateLegacyName(
    File file,
    String fileName,
    String folderPath,
    String raw,
  ) async {
    final String stem = fileName.replaceAll(
      RegExp(r'\.md$', caseSensitive: false),
      '',
    );
    final Match? m = RegExp(r'^(.+)-([0-9a-z]{6})$').firstMatch(stem);
    if (m == null) return fileName;
    final String title = Note.splitFrontMatter(raw).meta['title'] ?? '';
    if (title.trim().isEmpty) return fileName;
    final String slug = Note.slugify(title);
    if (slug.isEmpty || slug != m.group(1)) return fileName;
    final String target = '$slug.md';
    final String targetPath = _pathFor(_join(folderPath, target));
    if (await File(targetPath).exists()) return fileName;
    try {
      await file.rename(targetPath);
      return target;
    } on FileSystemException {
      // Read-only folder, or the name is taken in another case. Keep the old
      // name: it still opens, and the title simply carries the suffix.
      return fileName;
    }
  }

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    final String folder = Note.normalizeFolderPath(note.folderPath);
    final String targetName = _baseName(note.fileName);
    final String target = _join(folder, targetName);
    final File targetFile = File(_pathFor(target));
    await targetFile.parent.create(recursive: true);

    final String? previousRelative = previousPath?.replaceAll('\\', '/');
    final bool samePath =
        previousRelative != null &&
        previousRelative.toLowerCase() == target.toLowerCase();
    if (samePath) {
      await _writer.replace(targetFile, note.toMarkdown());
      return;
    }

    // A different name means this save is a rename or a move. If something
    // already sits on the target name, it is not ours to write over: the
    // controller resolves the clash with the same ` 2` rule it uses in memory.
    if (await targetFile.exists()) {
      throw NotePathTaken(target);
    }

    final String contents = note.toMarkdown();
    final File? previousFile = previousRelative == null
        ? null
        : File(_pathFor(previousRelative));
    final bool hadPrevious =
        previousFile != null && await previousFile.exists();

    if (hadPrevious) {
      // Land the new contents on the file we own, then move that file. A crash
      // between the two leaves the note saved under its old name — never two
      // copies of the same note on disk.
      await _writer.replace(previousFile, contents);
      try {
        await previousFile.rename(targetFile.path);
        return;
      } on FileSystemException {
        // Renaming can fail across volumes, or because the name appeared in
        // the meantime. The check below tells the two apart.
      }
      if (await targetFile.exists()) {
        throw NotePathTaken(target);
      }
    }

    await _writer.replace(targetFile, contents);
    if (hadPrevious) await _deleteQuietly(previousRelative!);
  }

  @override
  Future<void> delete(Note note) async {
    await _deleteQuietly(note.relativePath);
  }

  Future<void> _deleteQuietly(String relativePath) async {
    final File f = File(_pathFor(relativePath));
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Ignore: the note is gone from the UI either way.
    }
  }

  @override
  Future<bool> reveal() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return false;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', <String>[vault.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[vault.path]);
      } else {
        await Process.run('xdg-open', <String>[vault.path]);
      }
      return true;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<Note?> importMarkdown(
    String raw,
    String preferredName, {
    String folderPath = '',
  }) async {
    return writeNewMarkdown(raw, preferredName, folderPath: folderPath);
  }

  @override
  Future<Note> writeNewMarkdown(
    String raw,
    String fileName, {
    String folderPath = '',
  }) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    final String base = _baseName(fileName);
    final String withExtension = base.toLowerCase().endsWith('.md')
        ? base
        : '$base.md';
    final Note parsed = Note.fromMarkdown(
      raw,
      withExtension,
      DateTime.now(),
      folderPath: folder,
    );
    final Note note = parsed.copyWith(
      fileName: await _freeName(
        folder,
        Note.buildFileName(parsed.title),
        withExtension,
      ),
      updatedAt: DateTime.now(),
    );
    await save(note);
    return note;
  }

  /// [wanted], or ` 2`/` 3` … when that file already exists in [folderPath] and
  /// is not [excluding] itself (the file being rewritten).
  Future<String> _freeName(
    String folderPath,
    String wanted,
    String excluding,
  ) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (wanted.toLowerCase() == excluding.toLowerCase()) return wanted;
    if (!await File(_pathFor(_join(folder, wanted))).exists()) return wanted;
    final String stem = wanted.replaceAll(
      RegExp(r'\.md$', caseSensitive: false),
      '',
    );
    for (int i = 2; i < 1000; i++) {
      final String next = '$stem $i.md';
      if (!await File(_pathFor(_join(folder, next))).exists()) return next;
    }
    return wanted;
  }
}

NoteStore createNoteStore() => IoNoteStore();
