import '../models/note.dart';

/// Result of comparing the on-disk vault with what the UI already knows about.
class VaultSnapshot {
  const VaultSnapshot({required this.notes, required this.location});

  final List<Note> notes;

  /// Human readable vault path (or storage description on the web).
  final String location;
}

/// The persistence contract every platform must satisfy.
///
/// NRS stores one `.md` file per note. That is the whole point of the app, so
/// the interface is intentionally tiny and file-shaped rather than
/// database-shaped.
abstract class NoteStore {
  /// Prepares the vault (creates the directory, seeds the welcome note on a
  /// truly fresh install).
  Future<void> init();

  /// Where the notes live, for display in the UI.
  String get location;

  /// True when notes are real files on disk and can be revealed in a file
  /// manager. False for the in-browser fallback.
  bool get supportsNativeFiles;

  /// Reads every note in the vault, newest first.
  Future<List<Note>> loadAll();

  /// Every real folder in the vault, vault-relative and `/`-separated.
  ///
  /// Empty folders are included: they are real directories the user made, and a
  /// file tree that hides them cannot explain where the next note will land.
  Future<List<String>> listFolders() async => const <String>[];

  /// Creates [folderPath] and its parents. Returns the normalized path.
  Future<String> createFolder(String folderPath) async =>
      Note.normalizeFolderPath(folderPath);

  /// Renames [from] to [to], notes and sub-folders included.
  ///
  /// Returns false when the move is impossible — the source is missing, the
  /// target already exists, or the platform cannot rename directories. Refusing
  /// is deliberate: silently merging two folders would scatter the notes.
  Future<bool> renameFolder(String from, String to) async => false;

  /// Writes [note] to its [Note.relativePath].
  ///
  /// When [previousPath] is supplied and differs, the old file is removed so
  /// that renaming a note does not leave an orphan behind.
  Future<void> save(Note note, {String? previousPath});

  /// Removes the note's file from the vault.
  Future<void> delete(Note note);

  /// Opens the vault folder in the OS file manager. No-op where unsupported.
  Future<bool> reveal() async => false;

  /// Imports a stray `.md` file found outside the vault (used by drag & drop).
  Future<Note?> importMarkdown(
    String raw,
    String preferredName, {
    String folderPath = '',
  }) async => null;

  /// Persists an arbitrary raw `.md` string under a new file name.
  Future<Note> writeNewMarkdown(
    String raw,
    String fileName, {
    String folderPath = '',
  }) async => Note.fromMarkdown(
    raw,
    fileName,
    DateTime.now(),
    folderPath: folderPath,
  );
}

/// Shared helpers for the concrete stores.
mixin NoteStoreSupport {
  List<Note> sortNotes(List<Note> notes) {
    final List<Note> sorted = List<Note>.of(notes)
      ..sort((Note a, Note b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  }
}
