import 'dart:convert';

import 'package:web/web.dart' as web;

import '../models/note.dart';
import 'note_store.dart';

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
    final web.Storage ls = web.window.localStorage;
    for (int i = 0; i < ls.length; i++) {
      final String? key = ls.key(i);
      if (key == null || !key.startsWith(_prefix)) continue;
      final String? value = ls.getItem(key);
      if (value != null) {
        _cache[key.substring(_prefix.length).replaceAll('\\', '/')] = value;
      }
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
    final web.Storage ls = web.window.localStorage;
    final List<String> stale = <String>[];
    for (int i = 0; i < ls.length; i++) {
      final String? key = ls.key(i);
      if (key != null && key.startsWith(_prefix)) stale.add(key);
    }
    for (final String key in stale) {
      ls.removeItem(key);
    }
    _cache.forEach((String relativePath, String raw) {
      ls.setItem('$_prefix$relativePath', raw);
    });
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

  /// Exposed for the "export vault" action in the browser build.
  String exportJson() => jsonEncode(_cache);
}

NoteStore createNoteStore() => WebNoteStore();
