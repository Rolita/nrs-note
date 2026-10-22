import 'dart:convert';

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
  static const String _foldersKey = 'nrs/v1/folders';

  final Map<String, String> _cache = <String, String>{};

  /// 上次成功写进 localStorage 的正文；`_flush` 只写与它不同的键。
  final Map<String, String> _persisted = <String, String>{};

  final Set<String> _folders = <String>{};
  bool _ready = false;

  @override
  String get location => '浏览器本地存储 (localStorage)';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<void> init() async {
    if (_ready) return;
    _reloadCache();
    _reloadFolders();
    _ready = true;
    if (_cache.isEmpty) {
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
  Future<void> delete(Note note) async {
    await init();
    _cache.remove(note.relativePath);
    _flush();
  }

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
      fileName: _freeName(
        folder,
        Note.buildFileName(parsed.title),
        base,
      ),
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

/// 把 `package:web` 的 localStorage 包成 [WebKeyValue]，让落盘逻辑留在纯 Dart 里。
class _LocalStorage implements WebKeyValue {
  final web.Storage _ls = web.window.localStorage;

  @override
  void setItem(String key, String value) => _ls.setItem(key, value);

  @override
  void removeItem(String key) => _ls.removeItem(key);
}

NoteStore createNoteStore() => WebNoteStore();
