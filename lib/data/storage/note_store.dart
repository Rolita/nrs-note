import 'dart:typed_data';

import '../models/note.dart';

/// Result of comparing the on-disk vault with what the UI already knows about.
class VaultSnapshot {
  const VaultSnapshot({required this.notes, required this.location});

  final List<Note> notes;

  /// Human readable vault path (or storage description on the web).
  final String location;
}

/// A cheap fingerprint of one note file: enough to decide whether the file
/// needs to be re-read, without reading it.
class NoteFileStamp {
  const NoteFileStamp({
    required this.relativePath,
    required this.modifiedAt,
    required this.size,
  });

  /// Vault-relative path, `/`-separated.
  final String relativePath;
  final DateTime modifiedAt;
  final int size;

  @override
  bool operator ==(Object other) =>
      other is NoteFileStamp &&
      other.relativePath == relativePath &&
      other.modifiedAt == modifiedAt &&
      other.size == size;

  @override
  int get hashCode => Object.hash(relativePath, modifiedAt, size);
}

/// vault 里一个「既不是笔记也不是白板」的文件：图片、PDF、附件。
///
/// 文件树把它们和笔记、白板列在一起，是为了让列表和磁盘长得一样 —— 用户
/// 在资源管理器里看得到的文件，在这里也应该找得到，而不是只剩 `.md`。
/// 它们不参与任何索引：不解析、不进图谱、不进回收站。
class VaultFile {
  const VaultFile({required this.relativePath});

  /// Vault-relative path, `/`-separated.
  final String relativePath;

  /// 所在文件夹，根目录是空串。
  String get folderPath {
    final int slash = relativePath.lastIndexOf('/');
    return slash <= 0 ? '' : relativePath.substring(0, slash);
  }

  /// 文件名，带后缀。
  String get fileName => relativePath.split('/').last;

  /// 后缀，不带点，保留原大小写。没有后缀时是空串。
  String get extension {
    final int dot = fileName.lastIndexOf('.');
    return dot <= 0 ? '' : fileName.substring(dot + 1);
  }

  /// 去掉后缀的名字。树里显示的就是它。
  String get title {
    final String name = fileName;
    final int dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}

/// A deleted note waiting in the vault's trash.
class TrashEntry {
  const TrashEntry({
    required this.id,
    required this.originalPath,
    required this.title,
    required this.deletedAt,
    required this.size,
  });

  final String id;

  /// Vault-relative path the note will return to, `/`-separated.
  final String originalPath;
  final String title;
  final DateTime deletedAt;
  final int size;
}

/// One snapshot in a note's version history.
class NoteVersion {
  const NoteVersion({
    required this.id,
    required this.capturedAt,
    required this.size,
  });

  /// Stable id for this snapshot, derived from its capture time.
  final String id;
  final DateTime capturedAt;
  final int size;
}

/// Thrown by [NoteStore.save] when the target file already exists and is not
/// the file this note owns — typically a note the user created outside NRS.
///
/// Refusing is the point: two notes with one name would silently become one
/// note. The controller catches this, re-reads the vault, picks a free name and
/// retries, which is the same ` 2` rule the UI already promises.
class NotePathTaken implements Exception {
  NotePathTaken(this.relativePath);

  final String relativePath;

  @override
  String toString() => '文件名已被占用:$relativePath';
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

  /// vault 在磁盘上的真实路径。浏览器端没有文件系统，返回 null。
  ///
  /// 白板存储要拿它来定位同一棵树：白板是 vault 里的普通文件，必须和笔记
  /// 待在同一个目录，否则用户在文件管理器里看到的是两棵互不相干的树。
  String? get vaultPath => null;

  /// Reads every note in the vault, newest first.
  Future<List<Note>> loadAll();

  /// Fingerprints for every note file, or null where the platform has no way to
  /// notice changes made outside the app (the browser build).
  Future<List<NoteFileStamp>?> stamps() async => null;

  /// The fingerprint of one file, or null when it does not exist. Used to keep
  /// the baseline current after the app's own writes.
  Future<NoteFileStamp?> stampOf(String relativePath) async => null;

  /// Every real folder in the vault, vault-relative and `/`-separated.
  ///
  /// Empty folders are included: they are real directories the user made, and a
  /// file tree that hides them cannot explain where the next note will land.
  Future<List<String>> listFolders() async => const <String>[];

  /// vault 里的非笔记文件（图片、PDF、附件……），不含 `.md` 和 `.nrs`。
  ///
  /// 只给文件树显示用，所以不读内容、也不 stat：一个装了几百张图的
  /// `assets/` 不值得为了一次列表去开几百个句柄。
  Future<List<VaultFile>> listFiles() async => const <VaultFile>[];

  /// Creates [folderPath] and its parents. Returns the normalized path.
  Future<String> createFolder(String folderPath) async =>
      Note.normalizeFolderPath(folderPath);

  /// Renames [from] to [to], notes and sub-folders included.
  ///
  /// Returns false when the move is impossible — the source is missing, the
  /// target already exists, or the platform cannot rename directories. Refusing
  /// is deliberate: silently merging two folders would scatter the notes.
  Future<bool> renameFolder(String from, String to) async => false;

  /// True when [folderPath] contains nothing but directories and the note files
  /// in [notePaths].
  ///
  /// The note trash cannot hold anything else, so a folder with a picture or a
  /// hand-written text file is not deletable: removing it would destroy content
  /// the app could never restore. Platforms that cannot inspect the folder
  /// answer false, which refuses the delete rather than guessing.
  Future<bool> folderHoldsOnlyNotes(
    String folderPath,
    Set<String> notePaths,
  ) async => false;

  /// Removes [folderPath] and its empty sub-directories, deepest first.
  ///
  /// Only empty directories are ever deleted. Returns false when the folder
  /// itself is still there — anything the note trash cannot hold is inside, or a
  /// directory could not be removed. Empty sub-directories may already have been
  /// removed; nothing else is touched.
  Future<bool> deleteFolder(String folderPath) async => false;

  /// Writes [bytes] to `<folderPath>/assets/<fileName>`, picking a free name
  /// when that one is taken.
  ///
  /// Returns the reference to put in Markdown — `assets/x.png`, relative to the
  /// note — or null where the platform has no real files to put an image in.
  Future<String?> saveAsset(
    String folderPath,
    String fileName,
    Uint8List bytes,
  ) async => null;

  /// Absolute path on disk for an image referenced by a note, or null for
  /// remote sources, paths that escape the vault, and the web build.
  String? assetPath(String folderPath, String source) => null;

  /// Writes [note] to its [Note.relativePath].
  ///
  /// When [previousPath] is supplied and differs, the old file is removed so
  /// that renaming a note does not leave an orphan behind.
  Future<void> save(Note note, {String? previousPath});

  /// True when deleting moves the note into a restorable trash.
  bool get supportsTrash => false;

  /// True when snapshots of overwritten content can be listed and restored.
  bool get supportsHistory => false;

  /// Removes the note from the vault, returning its trash receipt when the
  /// platform keeps one. A null receipt means the note is gone for good.
  Future<TrashEntry?> delete(Note note);

  /// Everything currently in the trash, newest deletion first.
  Future<List<TrashEntry>> listTrash() async => const <TrashEntry>[];

  /// Restores a trashed note to its original path (or a free name there).
  Future<Note?> restoreTrash(String entryId) async => null;

  /// Permanently removes one trash entry.
  Future<void> purgeTrash(String entryId) async {}

  /// Permanently removes every trash entry.
  Future<void> emptyTrash() async {}

  /// Snapshots of [note]'s previous content, newest first.
  Future<List<NoteVersion>> historyOf(Note note) async =>
      const <NoteVersion>[];

  /// Raw `.md` contents of one snapshot, or null when it disappeared.
  Future<String?> readVersion(Note note, String versionId) async => null;

  /// Replaces [note]'s body with [versionId], first snapshotting what is on
  /// disk now so the restore itself can be undone.
  Future<bool> restoreVersion(Note note, String versionId) async => false;

  /// Snapshots the note's current on-disk content immediately, ignoring the
  /// normal capture interval. Used before destructive overwrites.
  Future<void> captureVersion(Note note) async {}

  /// Opens the vault folder in the OS file manager. No-op where unsupported.
  Future<bool> reveal() async => false;

  /// Imports a stray `.md` file found outside the vault (used by drag & drop).
  Future<Note?> importMarkdown(
    String raw,
    String preferredName, {
    String folderPath = '',
  }) async => null;

  /// Reads a `.md` file from anywhere on disk — the source side of a drop.
  ///
  /// `null` when the path is missing, is not a file, or cannot be read. The
  /// vault writes and reads UTF-8, so a file in another encoding is refused
  /// rather than imported as a page of replacement characters.
  Future<String?> readMarkdownFile(String path) async => null;

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
