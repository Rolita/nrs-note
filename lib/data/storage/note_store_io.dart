import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import 'note_store.dart';

/// Desktop implementation: one real `.md` file per note inside a vault folder
/// the user can open in Explorer / Finder.
class IoNoteStore with NoteStoreSupport implements NoteStore {
  IoNoteStore({this.folderName = 'NRS Notes', this.overrideRoot});

  final String folderName;
  final Directory? overrideRoot;

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

    final List<File> existing = await _mdFiles();
    if (existing.isEmpty) {
      final Note welcome = Note.welcome();
      await File(_pathFor(welcome.fileName)).writeAsString(welcome.toMarkdown());
    }
  }

  Future<List<File>> _mdFiles() async {
    final Directory dir = vault;
    try {
      final List<FileSystemEntity> entries = await dir.list().toList();
      return entries
          .whereType<File>()
          .where(
            (File f) => f.path.toLowerCase().endsWith('.md'),
          )
          .toList(growable: false);
    } on FileSystemException {
      return const <File>[];
    }
  }

  String _pathFor(String fileName) =>
      '${vault.path}${Platform.pathSeparator}$fileName';

  String _baseName(String fileName) => fileName.split(RegExp(r'[\\/]')).last;

  @override
  Future<List<Note>> loadAll() async {
    final List<File> files = await _mdFiles();
    final List<Note> notes = <Note>[];
    for (final File f in files) {
      try {
        final String raw = await f.readAsString();
        final DateTime modified = await f.lastModified();
        notes.add(Note.fromMarkdown(raw, _baseName(f.path), modified));
      } on FileSystemException {
        // A file locked by another process should never take the app down.
        continue;
      }
    }
    return sortNotes(notes);
  }

  @override
  Future<void> save(Note note, {String? previousFileName}) async {
    final String target = _baseName(note.fileName);
    await File(_pathFor(target)).writeAsString(
      note.toMarkdown(),
      flush: true,
    );
    if (previousFileName != null &&
        _baseName(previousFileName) != target) {
      await _deleteQuietly(_baseName(previousFileName));
    }
  }

  @override
  Future<void> delete(Note note) async {
    await _deleteQuietly(_baseName(note.fileName));
  }

  Future<void> _deleteQuietly(String fileName) async {
    final File f = File(_pathFor(fileName));
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
  Future<Note?> importMarkdown(String raw, String preferredName) async {
    final Note note = await writeNewMarkdown(raw, preferredName);
    return note;
  }

  @override
  Future<Note> writeNewMarkdown(String raw, String fileName) async {
    String base = _baseName(fileName);
    if (!base.toLowerCase().endsWith('.md')) base = '$base.md';
    final Note parsed = Note.fromMarkdown(raw, base, DateTime.now());
    final Note note = parsed.title.isEmpty
        ? parsed.copyWith(fileName: base, updatedAt: DateTime.now())
        : parsed.copyWith(
            fileName: Note.buildFileName(parsed.title, parsed.id),
            updatedAt: DateTime.now(),
          );
    await save(note);
    return note;
  }
}

NoteStore createNoteStore() => IoNoteStore();
