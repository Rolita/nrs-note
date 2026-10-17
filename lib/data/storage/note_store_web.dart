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
class WebNoteStore with NoteStoreSupport implements NoteStore {
  static const String _prefix = 'nrs/v1/file/';

  final Map<String, String> _cache = <String, String>{};
  bool _ready = false;

  @override
  String get location => '浏览器本地存储 (localStorage)';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<void> init() async {
    if (_ready) return;
    _reloadCache();
    _ready = true;
    if (_cache.isEmpty) {
      final Note welcome = Note.welcome();
      _cache[welcome.fileName] = welcome.toMarkdown();
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
      if (value != null) _cache[key.substring(_prefix.length)] = value;
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
    _cache.forEach((String name, String raw) {
      ls.setItem('$_prefix$name', raw);
    });
  }

  @override
  Future<List<Note>> loadAll() async {
    await init();
    final DateTime now = DateTime.now();
    final List<Note> notes = <Note>[];
    _cache.forEach((String name, String raw) {
      notes.add(Note.fromMarkdown(raw, name, now));
    });
    return sortNotes(notes);
  }

  @override
  Future<void> save(Note note, {String? previousFileName}) async {
    await init();
    _cache[note.fileName] = note.toMarkdown();
    if (previousFileName != null && previousFileName != note.fileName) {
      _cache.remove(previousFileName);
    }
    _flush();
  }

  @override
  Future<void> delete(Note note) async {
    await init();
    _cache.remove(note.fileName);
    _flush();
  }

  @override
  Future<bool> reveal() async => false;

  @override
  Future<Note?> importMarkdown(String raw, String preferredName) async =>
      writeNewMarkdown(raw, preferredName);

  @override
  Future<Note> writeNewMarkdown(String raw, String fileName) async {
    await init();
    String base = fileName;
    if (!base.toLowerCase().endsWith('.md')) base = '$base.md';
    final Note parsed = Note.fromMarkdown(raw, base, DateTime.now());
    final Note note = parsed.copyWith(
      fileName: Note.buildFileName(parsed.title, parsed.id),
      updatedAt: DateTime.now(),
    );
    await save(note);
    return note;
  }

  /// Exposed for the "export vault" action in the browser build.
  String exportJson() => jsonEncode(_cache);
}

NoteStore createNoteStore() => WebNoteStore();
