import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_enums.dart';
import '../core/utils/debouncer.dart';
import '../data/models/note.dart';
import '../data/storage/note_store_factory.dart';

/// A tag together with how many notes use it.
class TagStat {
  const TagStat(this.name, this.count);
  final String name;
  final int count;
}

enum SaveState { idle, dirty, saving, saved }

/// Owns the vault: loading, filtering, editing and persisting notes.
///
/// List order is deliberately *stable while you type* — a note only moves to the
/// top after an explicit refresh, create, delete or sort change. Watching the
/// row you are editing jump around is the fastest way to make an editor feel
/// cheap.
class NotesController extends ChangeNotifier {
  NotesController({NoteStore? store}) : _store = store ?? createNoteStore();

  final NoteStore _store;

  /// Every edit is written to disk on its own; this only collapses a *burst* of
  /// keystrokes into one write.
  ///
  /// 300ms is tuned to the pause between words rather than to the keystroke: any
  /// longer and "我改了一个字,然后关掉窗口" loses the character, any shorter and a
  /// fast typist rewrites the file several times a second for nothing. [saveNow]
  /// (Ctrl+S, switching notes, closing a pane) cuts the wait entirely.
  final Debouncer _autosave = Debouncer(
    delay: const Duration(milliseconds: 300),
  );

  List<Note> _notes = <Note>[];
  List<Note> _ordered = <Note>[];
  String? _selectedId;
  Note? _draft;
  String? _draftOriginalFileName;
  bool _loading = true;
  String? _error;
  SaveState _saveState = SaveState.idle;
  Timer? _savedIndicatorTimer;

  // -------------------------------------------------------------- filter state
  String _query = '';
  NoteScope _scope = NoteScope.all;
  String? _activeTag;

  // ------------------------------------------------------------------ getters

  bool get isLoading => _loading;
  String? get error => _error;
  String get vaultLocation => _store.location;
  bool get supportsNativeFiles => _store.supportsNativeFiles;
  List<Note> get allNotes => List<Note>.unmodifiable(_ordered);
  String? get selectedId => _selectedId;
  SaveState get saveState => _saveState;

  String get query => _query;
  NoteScope get scope => _scope;
  String? get activeTag => _activeTag;
  bool get isFiltered => _query.isNotEmpty || _scope != NoteScope.all || _activeTag != null;

  Note? get selectedNote {
    final String? id = _selectedId;
    if (id == null) return null;
    for (final Note n in _notes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// The live working copy — what the editor binds to.
  Note? get draft => _draft;

  List<Note> get visibleNotes {
    final String q = _query.trim().toLowerCase();
    final List<Note> filtered = _notes.where((Note n) {
      switch (_scope) {
        case NoteScope.pinned:
          if (!n.pinned) return false;
        case NoteScope.favorites:
          if (!n.favorite) return false;
        case NoteScope.tasks:
          if (n.taskTotal == 0) return false;
        case NoteScope.untagged:
          if (n.tags.isNotEmpty) return false;
        case NoteScope.all:
          break;
      }
      if (_activeTag != null && !n.tags.contains(_activeTag)) return false;
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.body.toLowerCase().contains(q) ||
          n.tags.any((String t) => t.toLowerCase().contains(q));
    }).toList();

    final List<String> order = _ordered.map((Note n) => n.id).toList();
    filtered.sort(
      (Note a, Note b) => order.indexOf(a.id).compareTo(order.indexOf(b.id)),
    );
    return filtered;
  }

  List<TagStat> get tags {
    final Map<String, int> counts = <String, int>{};
    for (final Note n in _notes) {
      for (final String t in n.tags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final List<TagStat> stats = counts.entries
        .map((MapEntry<String, int> e) => TagStat(e.key, e.value))
        .toList()
      ..sort((TagStat a, TagStat b) {
        final int byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.name.compareTo(b.name);
      });
    return stats;
  }

  int get totalWords =>
      _notes.fold<int>(0, (int sum, Note n) => sum + n.wordCount);

  int get totalFavorites => _notes.where((Note n) => n.favorite).length;

  // -------------------------------------------------------------------- load

  Future<void> bootstrap() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await _store.init();
      await refresh(keepSelection: false);
    } catch (e) {
      _error = '无法打开笔记库:$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
    if (_selectedId == null && _ordered.isNotEmpty) {
      select(_ordered.first.id);
    }
  }

  Future<void> refresh({bool keepSelection = true}) async {
    try {
      _notes = await _store.loadAll();
    } catch (e) {
      _error = '读取笔记库失败:$e';
      notifyListeners();
      return;
    }
    _resort();
    if (!keepSelection || selectedNote == null) {
      _selectedId = _ordered.isEmpty ? null : _ordered.first.id;
      _draft = selectedNote;
      _draftOriginalFileName = _draft?.fileName;
    } else {
      // Re-read the file that is currently open, but never clobber unsaved
      // edits: the draft stays authoritative while it is dirty.
      if (_saveState == SaveState.idle || _saveState == SaveState.saved) {
        _draft = selectedNote;
        _draftOriginalFileName = _draft?.fileName;
      }
    }
    notifyListeners();
  }

  void _resort() {
    final SortMode mode = _lastSortMode;
    _ordered = List<Note>.of(_notes);
    switch (mode) {
      case SortMode.titleAsc:
        _ordered.sort(
          (Note a, Note b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
      case SortMode.longestFirst:
        _ordered.sort((Note a, Note b) => b.wordCount.compareTo(a.wordCount));
      case SortMode.updatedDesc:
        _ordered.sort((Note a, Note b) => b.updatedAt.compareTo(a.updatedAt));
      case SortMode.createdDesc:
        _ordered.sort((Note a, Note b) => b.createdAt.compareTo(a.createdAt));
    }
    // Pinned notes always float to the top, then keep the chosen order.
    _ordered.sort((Note a, Note b) {
      if (a.pinned == b.pinned) return 0;
      return a.pinned ? -1 : 1;
    });
  }

  /// Injected by the shell so the vault order follows the user's sort choice.
  SortMode _lastSortMode = SortMode.updatedDesc;

  set sortMode(SortMode mode) {
    _lastSortMode = mode;
    _resort();
    notifyListeners();
  }

  // --------------------------------------------------------------- filtering

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void setScope(NoteScope value) {
    if (_scope == value) return;
    _scope = value;
    _activeTag = null;
    notifyListeners();
  }

  void toggleTag(String tagName) {
    _activeTag = _activeTag == tagName ? null : tagName;
    if (_activeTag != null) _scope = NoteScope.all;
    notifyListeners();
  }

  void clearFilters() {
    _query = '';
    _activeTag = null;
    _scope = NoteScope.all;
    notifyListeners();
  }

  // -------------------------------------------------------------- selection

  void select(String? id) {
    if (_selectedId == id) return;
    _autosave.flush(() => _persistDraft());
    _selectedId = id;
    _draft = selectedNote;
    _draftOriginalFileName = _draft?.fileName;
    _saveState = SaveState.idle;
    notifyListeners();
  }

  void selectAdjacentInList(List<Note> visible, int delta) {
    if (visible.isEmpty) return;
    final int index = visible.indexWhere((Note n) => n.id == _selectedId);
    final int next = index < 0 ? 0 : (index + delta).clamp(0, visible.length - 1);
    select(visible[next].id);
  }

  // ------------------------------------------------------------------- CRUD

  Note createNote({String title = ''}) {
    _autosave.flush(() => _persistDraft());
    // A note always has a name, because the file always has one: an untitled
    // note is `未命名.md` and is titled 「未命名」. The editor selects that
    // placeholder, so the first keystroke replaces it.
    final String name = title.trim().isEmpty ? '未命名' : title;
    final Note blank = Note.blank(title: name);
    // `未命名.md` the first time, `未命名 2.md` after that — the file name has
    // to stay free before anything is written to it.
    final Note note = blank.copyWith(
      fileName: _freeName(blank.fileName),
    );
    _notes = <Note>[note, ..._notes];
    _ordered = <Note>[note, ..._ordered];
    _selectedId = note.id;
    _draft = note;
    _draftOriginalFileName = note.fileName;
    _saveState = SaveState.dirty;
    notifyListeners();
    unawaited(_persistDraft());
    return note;
  }

  /// Opens the note titled [title], writing a new one when the vault has none.
  ///
  /// A `[[link]]` to a title that does not exist yet is not an error — it is how
  /// you make one. Dropping the title into the search box instead (the old
  /// behaviour) left a dead link behind and asked the user to retype, from a
  /// filtered list, the exact name they had just typed into the link.
  ///
  /// Returns the note that is now open, and whether it had to be created —
  /// callers surface that difference to the user.
  ({Note note, bool created}) openOrCreateByTitle(String title) {
    final String wanted = title.trim();
    final String needle = wanted.toLowerCase();
    for (final Note n in _notes) {
      if (n.title.trim().toLowerCase() == needle) {
        select(n.id);
        return (note: n, created: false);
      }
    }
    return (note: createNote(title: wanted), created: true);
  }

  /// Duplicates a note so it can be used as a template.
  void duplicate(Note source) {
    final DateTime now = DateTime.now();
    final String id = Note.newId();
    final String title = '${source.title.isEmpty ? '未命名' : source.title} 副本';
    final Note copy = Note(
      id: id,
      title: title,
      body: source.body,
      tags: source.tags,
      createdAt: now,
      updatedAt: now,
      fileName: _freeName(Note.buildFileName(title)),
    );
    _notes = <Note>[copy, ..._notes];
    _ordered = <Note>[copy, ..._ordered];
    _selectedId = copy.id;
    _draft = copy;
    _draftOriginalFileName = null;
    _saveState = SaveState.dirty;
    notifyListeners();
    unawaited(_persistDraft());
  }

  Future<void> deleteNote(Note note) async {
    _notes = _notes.where((Note n) => n.id != note.id).toList();
    _ordered = _ordered.where((Note n) => n.id != note.id).toList();
    if (_selectedId == note.id) {
      _selectedId = _ordered.isEmpty ? null : _ordered.first.id;
      _draft = selectedNote;
      _draftOriginalFileName = _draft?.fileName;
    }
    notifyListeners();
    await _store.delete(note);
  }

  /// Puts a deleted note back on disk — powers the "撤销" affordance.
  Future<void> restoreNote(String rawMarkdown, String fileName) async {
    try {
      final Note restored = await _store.writeNewMarkdown(
        rawMarkdown,
        fileName,
      );
      await refresh(keepSelection: false);
      select(restored.id);
    } catch (e) {
      _error = '恢复失败:$e';
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ edits

  void updateBody(String body) {
    final Note? current = _draft;
    if (current == null || current.body == body) return;
    _applyDraft(current.copyWith(body: body, updatedAt: DateTime.now()));
  }

  void updateTitle(String title) {
    final Note? current = _draft;
    if (current == null || current.title == title) return;
    // The title *is* the file name, so this rename has to move the file too —
    // [Note.fileName] carries the new name and `_persistDraft` deletes the old
    // file once the new one is written.
    _applyDraft(
      current.copyWith(
        title: title,
        fileName: _freeName(Note.buildFileName(title), exceptId: current.id),
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// [candidate] unless another note already owns that file name, in which case
  /// ` 2`, ` 3` … is appended before `.md`.
  ///
  /// File names are compared case-insensitively because Windows and macOS file
  /// systems are: `周报.md` and `周报.MD` are the same file.
  String _freeName(String candidate, {String? exceptId}) {
    final Set<String> taken = <String>{
      for (final Note n in _notes)
        if (n.id != exceptId) n.fileName.toLowerCase(),
    };
    if (!taken.contains(candidate.toLowerCase())) return candidate;
    final String stem = candidate.replaceAll(
      RegExp(r'\.md$', caseSensitive: false),
      '',
    );
    for (int i = 2; i < 1000; i++) {
      final String next = '$stem $i.md';
      if (!taken.contains(next.toLowerCase())) return next;
    }
    return candidate;
  }

  void setTags(List<String> tags) {
    final Note? current = _draft;
    if (current == null) return;
    _applyDraft(current.copyWith(tags: tags, updatedAt: DateTime.now()));
    _autosave.run(_persistDraft);
  }

  void togglePinned(Note note) {
    final Note updated = note.copyWith(
      pinned: !note.pinned,
      updatedAt: DateTime.now(),
    );
    _replace(updated);
    if (_selectedId == note.id) _draft = updated;
    _resort();
    notifyListeners();
    unawaited(_store.save(updated));
  }

  void toggleFavorite(Note note) {
    final Note updated = note.copyWith(
      favorite: !note.favorite,
      updatedAt: DateTime.now(),
    );
    _replace(updated);
    if (_selectedId == note.id) _draft = updated;
    notifyListeners();
    unawaited(_store.save(updated));
  }

  void _replace(Note updated) {
    _notes = _notes
        .map((Note n) => n.id == updated.id ? updated : n)
        .toList();
    _ordered = _ordered
        .map((Note n) => n.id == updated.id ? updated : n)
        .toList();
  }

  /// Replaces the note in the visible list *without* re-sorting, then schedules
  /// a debounced write.
  void _applyDraft(Note next) {
    _draft = next;
    _replace(next);
    _saveState = SaveState.dirty;
    notifyListeners();
    _autosave.run(_persistDraft);
  }

  Future<void> saveNow() async {
    _autosave.cancel();
    await _persistDraft();
  }

  /// The tail of the write chain, and how many writes are on it.
  Future<void> _writing = Future<void>.value();
  int _writesQueued = 0;

  /// Writes the draft, **one write at a time**.
  ///
  /// Auto-save fires on its own every few hundred milliseconds, so two writes
  /// can overlap on a slow disk. That is not a cosmetic problem: each write
  /// deletes the file name it believes it replaced, so an earlier write landing
  /// *after* a later one leaves both files behind — one note on screen, two on
  /// disk after the next start.
  ///
  /// With nothing in flight the write starts *now* rather than on a later
  /// microtask, so "create a note" is on disk by the time the call returns. Only
  /// a real overlap is queued, and a queued write always writes what the draft
  /// says when it runs, not what it said when the timer fired.
  Future<void> _persistDraft() {
    final Future<void> task = _writesQueued == 0
        ? _writeDraft()
        : _writing.then((_) => _writeDraft());
    _writesQueued++;
    // A failed write must not poison the queue: [_writeDraft] already reports
    // the error through [error], so the chain itself always completes.
    _writing = task
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _writesQueued--);
    return task;
  }

  Future<void> _writeDraft() async {
    final Note? draft = _draft;
    if (draft == null) return;
    // Last line of defence: a file name is the note's name, so two notes must
    // never end up sharing one. (Retitling two notes to the same thing in a
    // row can land here before the list has settled.)
    final Note note = draft.copyWith(
      fileName: _freeName(draft.fileName, exceptId: draft.id),
    );
    if (note.fileName != draft.fileName) {
      _draft = note;
      _replace(note);
    }
    _saveState = SaveState.saving;
    notifyListeners();
    final String? previous = _draftOriginalFileName;
    try {
      await _store.save(note, previousFileName: previous);
      _draftOriginalFileName = note.fileName;
      _saveState = SaveState.saved;
    } catch (e) {
      _saveState = SaveState.dirty;
      _error = '保存失败:$e';
    }
    notifyListeners();
    _savedIndicatorTimer?.cancel();
    _savedIndicatorTimer = Timer(const Duration(seconds: 2), () {
      if (_saveState == SaveState.saved) {
        _saveState = SaveState.idle;
        notifyListeners();
      }
    });
  }

  // ------------------------------------------------------------------ export

  String exportSelectedMarkdown() {
    final Note? note = _draft ?? selectedNote;
    if (note == null) return '';
    final String title = note.title.isEmpty ? '未命名' : note.title;
    final String body = note.body.replaceFirst(RegExp(r'^\n+'), '');
    return '# $title\n\n$body';
  }

  // ------------------------------------------------------------------- misc

  Future<bool> revealVault() => _store.reveal();

  void setError(String? message) {
    _error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _autosave.dispose();
    _savedIndicatorTimer?.cancel();
    super.dispose();
  }
}
