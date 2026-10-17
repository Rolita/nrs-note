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

  /// Writes [note] to its [Note.fileName].
  ///
  /// When [previousFileName] is supplied and differs, the old file is removed
  /// so that renaming a note does not leave an orphan behind.
  Future<void> save(Note note, {String? previousFileName});

  /// Removes the note's file from the vault.
  Future<void> delete(Note note);

  /// Opens the vault folder in the OS file manager. No-op where unsupported.
  Future<bool> reveal() async => false;

  /// Imports a stray `.md` file found outside the vault (used by drag & drop).
  Future<Note?> importMarkdown(String raw, String preferredName) async => null;

  /// Persists an arbitrary raw `.md` string under a new file name.
  Future<Note> writeNewMarkdown(String raw, String fileName) async =>
      Note.fromMarkdown(raw, fileName, DateTime.now());
}

/// Shared helpers for the concrete stores.
mixin NoteStoreSupport {
  List<Note> sortNotes(List<Note> notes) {
    final List<Note> sorted = List<Note>.of(notes)
      ..sort((Note a, Note b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  }
}
