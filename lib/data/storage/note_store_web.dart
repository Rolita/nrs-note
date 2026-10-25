import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../models/note.dart';
import 'note_store.dart';
import 'web_sync.dart';

/// Browser fallback.
///
/// The web build exists so the UI can be previewed and shared without a desktop
/// toolchain. Persistence uses `localStorage`, which means the notes survive a
/// reload but stay inside the browser profile — hence [supportsNativeFiles] is
/// false and the UI labels the location accordingly.
///
/// Folders are simulated with `/`-separated keys (`.../file/项目/计划.md`) plus
/// a small list of directories that exist even when empty.
class WebNoteStore with NoteStoreSupport implements NoteStore {
  static const String _prefix = 'nrs/v1/file/';
  static const String _trashPrefix = 'nrs/v1/trash/';
  static const String _foldersKey = 'nrs/v1/folders';

  final Map<String, String> _cache = <String, String>{};

  /// 上次成功写进 localStorage 的正文；`_flush` 只写与它不同的键。
  final Map<String, String> _persisted = <String, String>{};

  final Set<String> _folders = <String>{};
  final Random _random = Random();
  bool _ready = false;

  @override
  String get location => '浏览器本地存储 (localStorage)';

  @override
  bool get supportsNativeFiles => false;

  /// 浏览器里没有文件系统，白板也走 localStorage。
  @override
  String? get vaultPath => null;

  @override
  bool get supportsTrash => true;

  /// 浏览器版不保存版本历史：正文就在 localStorage 里，另存快照会成倍占用
  /// 本来就紧张的配额。桌面版才是长期写作的地方。
  @override
  bool get supportsHistory => false;

  @override
  Future<void> init() async {
    if (_ready) return;
    _reloadCache();
    _reloadFolders();
    _ready = true;
    if (_cache.isEmpty && !_hasTrash()) {
      final Note welcome = Note.welcome();
      _cache[welcome.relativePath] = welcome.toMarkdown();
      _flush();
    }
  }

  void _reloadCache() {
    _cache.clear();
    _persisted.clear();
    final web.Storage ls = web.window.localStorage;
    final List<String> legacyKeys = <String>[];
    for (int i = 0; i < ls.length; i++) {
      final String? key = ls.key(i);
      if (key == null || !key.startsWith(_prefix)) continue;
      final String? value = ls.getItem(key);
      if (value == null) continue;
      final String path = key.substring(_prefix.length).replaceAll('\\', '/');
      _cache[path] = value;
      _persisted[path] = value;
      // 旧版本可能写入了带反斜杠的键；同一篇笔记只留归一化后的一个。
      if (key != '$_prefix$path') legacyKeys.add(key);
    }
    for (final String key in legacyKeys) {
      ls.removeItem(key);
    }
  }

  void _reloadFolders() {
    _folders.clear();
    final String? raw = web.window.localStorage.getItem(_foldersKey);
    if (raw == null) return;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final Object? item in decoded) {
          if (item is String) {
            final String folder = Note.normalizeFolderPath(item);
            if (folder.isNotEmpty) _folders.add(folder);
          }
        }
      }
    } on FormatException {
      // A corrupted preference must not hide the notes themselves.
    }
  }

  void _flush() {
    // 只写变化项；全部写成功后才会删过期键。配额超限时 setItem 抛错，
    // 已存在的笔记仍是旧值，不会出现「清空一半又写了一半」的残缺库。
    WebSyncPlan.between(persisted: _persisted, next: _cache).apply(
      _LocalStorage(),
      _persisted,
      prefix: _prefix,
    );
  }

  void _flushFolders() {
    web.window.localStorage.setItem(_foldersKey, jsonEncode(_folders.toList()));
  }

  void _rememberFolder(String folderPath) {
    String current = '';
    for (final String part in folderPath.split('/')) {
      if (part.isEmpty) continue;
      current = current.isEmpty ? part : '$current/$part';
      _folders.add(current);
    }
  }

  List<String> _allFolders() {
    final Set<String> all = <String>{..._folders};
    for (final String relative in _cache.keys) {
      final int slash = relative.lastIndexOf('/');
      if (slash > 0) {
        String current = '';
        for (final String part in relative.substring(0, slash).split('/')) {
          if (part.isEmpty) continue;
          current = current.isEmpty ? part : '$current/$part';
          all.add(current);
        }
      }
    }
    final List<String> sorted = all.toList()
      ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  @override
  Future<List<String>> listFolders() async {
    await init();
    return _allFolders();
  }

  @override
  Future<String> createFolder(String folderPath) async {
    await init();
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return '';
    _rememberFolder(folder);
    _flushFolders();
    return folder;
  }

  @override
  Future<bool> renameFolder(String from, String to) async {
    await init();
    final String source = Note.normalizeFolderPath(from);
    final String target = Note.normalizeFolderPath(to);
    if (source.isEmpty || target.isEmpty || source == target) return false;
    final String prefix = '$source/';
    final bool taken = _allFolders().any(
      (String folder) => folder.toLowerCase() == target.toLowerCase(),
    );
    if (taken) return false;

    for (final String key in _cache.keys.toList()) {
      if (key == source || key.startsWith(prefix)) {
        final String raw = _cache.remove(key)!;
        _cache['$target${key.substring(source.length)}'] = raw;
      }
    }
    final List<String> moved = _folders
        .where((String folder) => folder == source || folder.startsWith(prefix))
        .toList(growable: false);
    for (final String folder in moved) {
      _folders.remove(folder);
    }
    for (final String folder in moved) {
      _rememberFolder('$target${folder.substring(source.length)}');
    }
    _flush();
    _flushFolders();
    return true;
  }

  @override
  Future<bool> folderHoldsOnlyNotes(
    String folderPath,
    Set<String> notePaths,
  ) async {
    await init();
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    final bool exists = _allFolders().any(
      (String path) => path.toLowerCase() == folder.toLowerCase(),
    );
    if (!exists) return false;
    final String prefix = '$folder/';
    final Set<String> known = <String>{
      for (final String path in notePaths) path.toLowerCase(),
    };
    for (final String path in _cache.keys) {
      if (!path.startsWith(prefix)) continue;
      if (!known.contains(path.toLowerCase())) return false;
    }
    return true;
  }

  @override
  Future<bool> deleteFolder(String folderPath) async {
    await init();
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    final String prefix = '$folder/';
    // A note still in the folder means the controller's delete did not finish;
    // dropping the folder record would hide it from the tree instead of deleting
    // anything.
    if (_cache.keys.any((String key) => key.startsWith(prefix))) return false;
    final String lowerPrefix = prefix.toLowerCase();
    _folders.removeWhere(
      (String path) =>
          path.toLowerCase() == folder.toLowerCase() ||
          path.toLowerCase().startsWith(lowerPrefix),
    );
    _flushFolders();
    return true;
  }

  /// 浏览器版不支持保存图片；图片能力只属于桌面版的真实文件系统。
  @override
  Future<String?> saveAsset(
    String folderPath,
    String fileName,
    Uint8List bytes,
  ) async => null;

  @override
  String? assetPath(String folderPath, String source) => null;

  /// Browser storage cannot be changed by another program, so there is no
  /// change detection to offer.
  @override
  Future<List<NoteFileStamp>?> stamps() async => null;

  @override
  Future<NoteFileStamp?> stampOf(String relativePath) async => null;

  @override
  Future<List<Note>> loadAll() async {
    await init();
    final DateTime now = DateTime.now();
    final List<Note> notes = <Note>[];
    _cache.forEach((String relativePath, String raw) {
      final int slash = relativePath.lastIndexOf('/');
      final String folder = slash < 0 ? '' : relativePath.substring(0, slash);
      final String name = slash < 0
          ? relativePath
          : relativePath.substring(slash + 1);
      notes.add(
        Note.fromMarkdown(raw, name, now, folderPath: folder),
      );
    });
    return sortNotes(notes);
  }

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    await init();
    _cache[note.relativePath] = note.toMarkdown();
    if (previousPath != null && previousPath != note.relativePath) {
      _cache.remove(previousPath);
    }
    _flush();
  }

  @override
  Future<TrashEntry?> delete(Note note) async {
    await init();
    final String? raw = _cache[note.relativePath];
    if (raw == null) return null;

    final String fileName = _baseName(note.relativePath);
    final DateTime now = DateTime.now().toUtc();
    final String entryId = _newTrashId(now);
    final String key = '$_trashPrefix$entryId';
    final String record = jsonEncode(<String, Object?>{
      'schema': 1,
      'originalPath': note.relativePath,
      'deletedAt': now.toIso8601String(),
      'raw': raw,
    });
    // 先落回收站再删原键：配额超限时 setItem 抛错，笔记原样留在库里。
    web.window.localStorage.setItem(key, record);
    try {
      _cache.remove(note.relativePath);
      _flush();
    } catch (_) {
      _cache[note.relativePath] = raw;
      web.window.localStorage.removeItem(key);
      rethrow;
    }
    return TrashEntry(
      id: entryId,
      originalPath: note.relativePath,
      title: Note.titleOfFileName(fileName),
      deletedAt: now,
      size: utf8.encode(raw).length,
    );
  }

  @override
  Future<List<TrashEntry>> listTrash() async {
    await init();
    final List<TrashEntry> entries = <TrashEntry>[];
    final web.Storage ls = web.window.localStorage;
    for (int i = 0; i < ls.length; i++) {
      final String? key = ls.key(i);
      if (key == null || !key.startsWith(_trashPrefix)) continue;
      final _WebTrashRecord? record = _readTrashRecord(key);
      if (record != null) entries.add(record.entry);
    }
    entries.sort((TrashEntry a, TrashEntry b) {
      final int byTime = b.deletedAt.compareTo(a.deletedAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return entries;
  }

  @override
  Future<Note?> restoreTrash(String entryId) async {
    await init();
    final String key = '$_trashPrefix$entryId';
    final _WebTrashRecord? record = _readTrashRecord(key);
    if (record == null) return null;
    final int slash = record.entry.originalPath.lastIndexOf('/');
    final String folder = slash < 0
        ? ''
        : record.entry.originalPath.substring(0, slash);
    final Note note = await writeNewMarkdown(
      record.raw,
      _baseName(record.entry.originalPath),
      folderPath: folder,
    );
    web.window.localStorage.removeItem(key);
    return note;
  }

  @override
  Future<void> purgeTrash(String entryId) async {
    web.window.localStorage.removeItem('$_trashPrefix$entryId');
  }

  @override
  Future<List<NoteVersion>> historyOf(Note note) async =>
      const <NoteVersion>[];

  @override
  Future<String?> readVersion(Note note, String versionId) async => null;

  @override
  Future<bool> restoreVersion(Note note, String versionId) async => false;

  @override
  Future<void> captureVersion(Note note) async {}

  @override
  Future<void> emptyTrash() async {
    final web.Storage ls = web.window.localStorage;
    final List<String> keys = <String>[
      for (int i = 0; i < ls.length; i++)
        if (ls.key(i)?.startsWith(_trashPrefix) ?? false) ls.key(i)!,
    ];
    for (final String key in keys) {
      ls.removeItem(key);
    }
  }

  /// Restoring a recycled note must not create a *second* welcome note next
  /// time the page loads, so an existing trash counts as evidence of real use.
  bool _hasTrash() {
    final web.Storage ls = web.window.localStorage;
    for (int i = 0; i < ls.length; i++) {
      if (ls.key(i)?.startsWith(_trashPrefix) ?? false) return true;
    }
    return false;
  }

  String _newTrashId(DateTime now) {
    return '${now.microsecondsSinceEpoch.toRadixString(36)}-'
        '${_random.nextInt(1 << 24).toRadixString(36).padLeft(5, '0')}';
  }

  _WebTrashRecord? _readTrashRecord(String key) {
    final String? raw = web.window.localStorage.getItem(key);
    if (raw == null) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final Object? path = decoded['originalPath'];
      final Object? body = decoded['raw'];
      if (path is! String || body is! String) return null;
      final DateTime? deletedAt = decoded['deletedAt'] is String
          ? DateTime.tryParse(decoded['deletedAt']! as String)?.toUtc()
          : null;
      final String fileName = _baseName(path);
      return _WebTrashRecord(
        entry: TrashEntry(
          id: key.substring(_trashPrefix.length),
          originalPath: path,
          title: Note.titleOfFileName(fileName),
          deletedAt: deletedAt ?? DateTime.utc(1970),
          size: utf8.encode(body).length,
        ),
        raw: body,
      );
    } on FormatException {
      return null;
    }
  }

  String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  @override
  Future<bool> reveal() async => false;

  @override
  Future<Note?> importMarkdown(
    String raw,
    String preferredName, {
    String folderPath = '',
  }) async {
    return writeNewMarkdown(raw, preferredName, folderPath: folderPath);
  }

  /// No `file://` on the web: there is no path to read, so a drop there is
  /// handled by the browser, not by the vault.
  @override
  Future<String?> readMarkdownFile(String path) async => null;

  @override
  Future<Note> writeNewMarkdown(
    String raw,
    String fileName, {
    String folderPath = '',
  }) async {
    await init();
    final String folder = Note.normalizeFolderPath(folderPath);
    String base = fileName.split(RegExp(r'[\\/]')).last;
    if (!base.toLowerCase().endsWith('.md')) base = '$base.md';
    final Note parsed = Note.fromMarkdown(
      raw,
      base,
      DateTime.now(),
      folderPath: folder,
    );
    final Note note = parsed.copyWith(
      // Keep the caller's name (dropped file / trashed note), but never
      // overwrite a key that is already there — that is the ` 2` rule.
      fileName: _freeName(folder, base, ''),
      updatedAt: DateTime.now(),
    );
    await save(note);
    return note;
  }

  /// [wanted], or ` 2`/` 3` … when that key already exists in [folder] and is
  /// not [excluding] itself.
  String _freeName(String folder, String wanted, String excluding) {
    if (wanted.toLowerCase() == excluding.toLowerCase()) return wanted;
    final String folderPath = Note.normalizeFolderPath(folder);
    String keyOf(String name) => folderPath.isEmpty ? name : '$folderPath/$name';
    if (!_cache.containsKey(keyOf(wanted))) return wanted;
    final String stem = wanted.replaceAll(
      RegExp(r'\.md$', caseSensitive: false),
      '',
    );
    for (int i = 2; i < 1000; i++) {
      final String next = '$stem $i.md';
      if (!_cache.containsKey(keyOf(next))) return next;
    }
    return wanted;
  }
}

/// One localStorage trash entry: the receipt plus the markdown to write back.
class _WebTrashRecord {
  const _WebTrashRecord({required this.entry, required this.raw});

  final TrashEntry entry;
  final String raw;
}

/// 把 `package:web` 的 localStorage 包成 [WebKeyValue]，让落盘逻辑留在纯 Dart 里。
class _LocalStorage implements WebKeyValue {
  final web.Storage _ls = web.window.localStorage;

  @override
  void setItem(String key, String value) => _ls.setItem(key, value);

  @override
  void removeItem(String key) => _ls.removeItem(key);
}

NoteStore createNoteStore() => WebNoteStore();
