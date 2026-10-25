import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import 'atomic_file.dart';
import 'history_store.dart';
import 'note_store.dart';
import 'trash_store.dart';

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
    DateTime Function()? clock,
    this.historyMinInterval = HistoryStore.defaultMinInterval,
  }) : _writer = writer ?? AtomicFileWriter(),
       _clock = clock ?? DateTime.now;

  final String folderName;
  final Directory? overrideRoot;
  final AtomicFileWriter _writer;
  final DateTime Function() _clock;

  /// Exposed for tests; production uses the ten-minute default.
  final Duration historyMinInterval;

  TrashStore? _trash;
  HistoryStore? _history;

  TrashStore get _trashStore =>
      _trash ??= TrashStore(vault, clock: _clock);

  HistoryStore get _historyStore => _history ??= HistoryStore(
    vault,
    clock: _clock,
    minInterval: historyMinInterval,
  );

  Directory? _vault;
  String _location = '';

  @override
  String get location => _location;

  @override
  bool get supportsNativeFiles => true;

  @override
  String? get vaultPath => _vault?.path;

  @override
  bool get supportsTrash => true;

  @override
  bool get supportsHistory => true;

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
    await _writer.recover(
      dir,
      skipDirectories: <String>{
        TrashStore.dirName.toLowerCase(),
        HistoryStore.dirName.toLowerCase(),
      },
    );

    try {
      await _trashStore.cleanupResidue();
    } on FileSystemException {
      // A trash that cannot be tidied is still readable.
    }

    final List<File> existing = await _mdFiles();
    if (existing.isEmpty) {
      bool trashEmpty = true;
      try {
        trashEmpty = (await _trashStore.list()).isEmpty;
      } on FileSystemException {
        // Unknown trash contents are not evidence of a fresh install.
        trashEmpty = false;
      }
      if (trashEmpty) {
        final Note welcome = Note.welcome();
        await _writer.replace(
          File(_pathFor(welcome.relativePath)),
          welcome.toMarkdown(),
        );
      }
    }
  }

  Future<List<File>> _mdFiles() async {
    final List<File> files = <File>[];
    try {
      await _walk(vault, files: files);
    } on FileSystemException {
      return const <File>[];
    }
    return files;
  }

  /// Walks the vault without descending into the app's own bookkeeping
  /// directories. Their `.md` files are snapshots, not notes.
  Future<void> _walk(
    Directory dir, {
    List<File>? files,
    List<Directory>? dirs,
  }) async {
    try {
      await for (final FileSystemEntity entity
          in dir.list(followLinks: false)) {
        if (entity is Directory) {
          if (_isInternalDirName(_baseName(entity.path))) continue;
          dirs?.add(entity);
          await _walk(entity, files: files, dirs: dirs);
        } else if (entity is File &&
            files != null &&
            entity.path.toLowerCase().endsWith('.md')) {
          files.add(entity);
        }
      }
    } on FileSystemException {
      // One unreadable subtree must not hide the rest of the vault.
    }
  }

  bool _isInternalDirName(String name) {
    final String lower = name.toLowerCase();
    return lower == TrashStore.dirName || lower == HistoryStore.dirName;
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
    final List<Directory> found = <Directory>[];
    try {
      await _walk(vault, dirs: found);
    } on FileSystemException {
      return const <String>[];
    }
    final List<String> folders = found
        .map(_relativeOf)
        .where((String p) => p.isNotEmpty)
        .where(
          (String p) => !p
              .split('/')
              .any((String segment) => segment.toLowerCase() == 'assets'),
        )
        .toList();
    folders.sort(
      (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    return folders;
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
  Future<bool> folderHoldsOnlyNotes(
    String folderPath,
    Set<String> notePaths,
  ) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    if (_isInternalDirName(folder.split('/').first)) return false;
    final Directory dir = Directory(_pathFor(folder));
    if (!await dir.exists()) return false;
    final Set<String> known = <String>{
      for (final String path in notePaths)
        path.replaceAll('\\', '/').toLowerCase(),
    };
    return _holdsOnlyKnownNotes(dir, known);
  }

  /// Every file below [dir] has to be one of [known]. Links and unreadable
  /// entries count as unknown: they cannot be put in the note trash, so the
  /// folder stays.
  Future<bool> _holdsOnlyKnownNotes(Directory dir, Set<String> known) async {
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          // The app's own bookkeeping has no business inside a note folder, and
          // deleting it would take snapshots the trash cannot restore.
          if (_isInternalDirName(_baseName(entity.path))) return false;
          if (!await _holdsOnlyKnownNotes(entity, known)) return false;
        } else if (entity is File) {
          if (!known.contains(_relativeOf(entity).toLowerCase())) return false;
        } else {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> deleteFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    if (_isInternalDirName(folder.split('/').first)) return false;
    final Directory dir = Directory(_pathFor(folder));
    if (!await dir.exists()) return false;
    return _removeEmptyTree(dir);
  }

  /// Deletes [dir] only after every child directory is gone and no non-directory
  /// entry is left. The non-recursive delete is the final guard: if anything
  /// appeared while walking, the directory stays.
  Future<bool> _removeEmptyTree(Directory dir) async {
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          if (!await _removeEmptyTree(entity)) return false;
        } else {
          return false;
        }
      }
      await dir.delete();
      return true;
    } on FileSystemException {
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
  Future<String?> saveAsset(
    String folderPath,
    String fileName,
    Uint8List bytes,
  ) async {
    if (_vault == null) await init();
    final String folder = Note.normalizeFolderPath(folderPath);
    final String assetsRel = folder.isEmpty ? 'assets' : '$folder/assets';
    final Directory dir = Directory(_pathFor(assetsRel));
    await dir.create(recursive: true);

    String base = _baseName(fileName.trim());
    base = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    base = base.replaceAll('..', '_');
    String stem = base
        .replaceAll(RegExp(r'\.png$', caseSensitive: false), '')
        .trim();
    if (stem.isEmpty || stem == '.') stem = 'image';

    final String candidate = await _freeAssetName(dir, stem);
    final File target = File('${dir.path}${Platform.pathSeparator}$candidate');
    // The same temp-then-rename rule the note writer uses: a crash leaves a
    // `.tmp` beside the picture, never a half-written PNG the editor will read.
    final File temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
    return 'assets/$candidate';
  }

  Future<String> _freeAssetName(Directory dir, String stem) async {
    String candidate = '$stem.png';
    for (int i = 2; i < 1000; i++) {
      final File file = File('${dir.path}${Platform.pathSeparator}$candidate');
      if (!await file.exists()) return candidate;
      candidate = '${stem}_$i.png';
    }
    return '${stem}_${DateTime.now().microsecondsSinceEpoch}.png';
  }

  @override
  String? assetPath(String folderPath, String source) {
    final Directory? root = _vault;
    if (root == null) return null;
    final String raw = source.trim();
    if (raw.isEmpty) return null;
    final String lower = raw.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:')) {
      return null;
    }
    if (raw.startsWith('/') ||
        raw.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
      return null;
    }

    String decoded;
    try {
      decoded = Uri.decodeComponent(raw);
    } on ArgumentError {
      return null;
    }
    decoded = decoded.replaceAll('\\', '/');
    if (decoded.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(decoded)) {
      return null;
    }
    if (decoded.split('/').any((String part) => part == '..')) return null;

    final String relative = _join(
      Note.normalizeFolderPath(folderPath),
      decoded,
    );
    final String absolute = _pathFor(relative);
    final String vaultPrefix = '${root.path}${Platform.pathSeparator}'
        .toLowerCase();
    if (!absolute.toLowerCase().startsWith(vaultPrefix)) return null;
    return absolute;
  }

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    final String folder = Note.normalizeFolderPath(note.folderPath);
    final String targetName = _baseName(note.fileName);
    final String target = _join(folder, targetName);
    final File targetFile = File(_pathFor(target));
    await targetFile.parent.create(recursive: true);

    final String contents = note.toMarkdown();
    final String? previousRelative = previousPath?.replaceAll('\\', '/');
    final bool samePath =
        previousRelative != null &&
        previousRelative.toLowerCase() == target.toLowerCase();
    if (samePath) {
      await _captureBeforeWrite(note, targetFile, contents);
      await _writer.replace(targetFile, contents);
      return;
    }

    // A different name means this save is a rename or a move. If something
    // already sits on the target name, it is not ours to write over: the
    // controller resolves the clash with the same ` 2` rule it uses in memory.
    if (await targetFile.exists()) {
      throw NotePathTaken(target);
    }

    final File? previousFile = previousRelative == null
        ? null
        : File(_pathFor(previousRelative));
    final bool hadPrevious =
        previousFile != null && await previousFile.exists();

    if (hadPrevious) {
      // Land the new contents on the file we own, then move that file. A crash
      // between the two leaves the note saved under its old name — never two
      // copies of the same note on disk.
      await _captureBeforeWrite(note, previousFile, contents);
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

  /// Keeps the content that is about to be overwritten.
  ///
  /// The interval check comes before the file read, so ordinary autosaves pay
  /// nothing once a snapshot exists. Pure renames and moves are skipped by
  /// comparing bodies: the front matter's `updated` changes on every save, but
  /// the prose did not.
  Future<void> _captureBeforeWrite(
    Note note,
    File file,
    String next,
  ) async {
    try {
      if (!await _historyStore.shouldCapture(note.id)) return;
      if (!await file.exists()) return;
      final String previous = await file.readAsString();
      if (Note.splitFrontMatter(previous).body ==
          Note.splitFrontMatter(next).body) {
        return;
      }
      await _historyStore.capture(note.id, previous);
    } catch (_) {
      // A history snapshot must never take a save down with it.
    }
  }

  @override
  Future<TrashEntry?> delete(Note note) async {
    final File file = File(_pathFor(note.relativePath));
    if (!await file.exists()) return null;
    return _trashStore.move(file, note.relativePath);
  }

  @override
  Future<List<TrashEntry>> listTrash() async {
    if (_vault == null) await init();
    return _trashStore.list();
  }

  @override
  Future<Note?> restoreTrash(String entryId) async {
    if (_vault == null) await init();
    final TrashRecord? record = await _trashStore.read(entryId);
    if (record == null) return null;
    final ({String folder, String fileName}) path = _restorePath(record);
    final Note note = await writeNewMarkdown(
      record.markdown,
      path.fileName,
      folderPath: path.folder,
    );
    await _trashStore.purge(entryId);
    return note;
  }

  @override
  Future<void> purgeTrash(String entryId) async {
    if (_vault == null) return;
    await _trashStore.purge(entryId);
  }

  @override
  Future<void> emptyTrash() async {
    if (_vault == null) return;
    await _trashStore.empty();
  }

  /// Turns untrusted metadata back into a path inside the vault. An absolute
  /// path, a drive letter or `..` can never make the restore escape the vault.
  ({String folder, String fileName}) _restorePath(TrashRecord record) {
    final List<String> parts = record.entry.originalPath
        .replaceAll('\\', '/')
        .split('/')
        .map((String part) => part.trim())
        .where(
          (String part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              !part.contains(':'),
        )
        .toList();
    String fileName = parts.isEmpty ? '' : parts.removeLast();
    if (fileName.isEmpty) fileName = record.fileName;
    fileName = _baseName(fileName);
    if (fileName.isEmpty) fileName = '未命名.md';
    if (!fileName.toLowerCase().endsWith('.md')) fileName = '$fileName.md';
    return (
      folder: Note.normalizeFolderPath(parts.join('/')),
      fileName: fileName,
    );
  }

  @override
  Future<List<NoteVersion>> historyOf(Note note) async {
    if (_vault == null) await init();
    return _historyStore.list(note.id);
  }

  @override
  Future<String?> readVersion(Note note, String versionId) async {
    if (_vault == null) return null;
    return _historyStore.read(note.id, versionId);
  }

  @override
  Future<bool> restoreVersion(Note note, String versionId) async {
    if (_vault == null) await init();
    final String? raw = await _historyStore.read(note.id, versionId);
    if (raw == null) return false;
    final Note version = Note.fromMarkdown(
      raw,
      note.fileName,
      _clock(),
      folderPath: note.folderPath,
    );
    final Note restored = note.copyWith(
      body: version.body,
      updatedAt: _clock(),
    );
    // Make the restore itself reversible before touching the current file.
    await captureVersion(note);
    final File target = File(_pathFor(restored.relativePath));
    await target.parent.create(recursive: true);
    await _writer.replace(target, restored.toMarkdown());
    return true;
  }

  @override
  Future<void> captureVersion(Note note) async {
    if (_vault == null) return;
    try {
      final File file = File(_pathFor(note.relativePath));
      if (!await file.exists()) return;
      final String raw = await file.readAsString();
      await _historyStore.capture(note.id, raw, force: true);
    } catch (_) {
      // Force capture is best effort; the caller's own operation is the point.
    }
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
  Future<String?> readMarkdownFile(String path) async {
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      final String raw = await file.readAsString();
      // Notepad on Windows writes a BOM; it is not part of the note.
      return raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    } on FileSystemException {
      return null;
    } on FormatException {
      // Not UTF-8: refuse rather than import a page of U+FFFD.
      return null;
    }
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
      // The caller's file name is the name that comes back: imports keep the
      // dropped file's name, and a trash restore keeps the original. A file
      // already sitting there forces the ` 2` rule instead of being replaced.
      fileName: await _freeName(folder, withExtension, ''),
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
