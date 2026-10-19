import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_enums.dart';
import '../core/utils/debouncer.dart';
import '../data/models/note.dart';
import '../data/storage/note_store_factory.dart';

/// A note that was removed, kept byte-for-byte so "撤销" can put it back.
typedef DeletedNote = ({String raw, String fileName, String folderPath});

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
  List<String> _folders = <String>[];
  String _activeFolder = '';
  String? _selectedId;
  Note? _draft;
  String? _draftOriginalPath;
  bool _loading = true;
  String? _error;
  SaveState _saveState = SaveState.idle;
  Timer? _savedIndicatorTimer;

  // -------------------------------------------------------------- filter state
  String _query = '';
  bool _caseSensitive = false;
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

  /// Whether the query matches case for case. Off by default, because most
  /// searches are for a word rather than for its capitalisation.
  bool get caseSensitive => _caseSensitive;
  String? get activeTag => _activeTag;
  bool get isFiltered => _query.isNotEmpty || _activeTag != null;

  /// Folder that receives the next new note. Empty means the vault root.
  String get activeFolder => _activeFolder;

  /// Every real directory in the vault, including empty ones.
  List<String> get folders {
    final List<String> list = _folderPaths().toList()
      ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return List<String>.unmodifiable(list);
  }

  /// Direct children of [parentPath], as full vault-relative paths.
  List<String> childFoldersOf(String parentPath) {
    final String parent = Note.normalizeFolderPath(parentPath);
    final Set<String> children = <String>{};
    for (final String path in _folderPaths()) {
      if (parent.isEmpty) {
        if (!path.contains('/')) {
          children.add(path);
        } else {
          children.add(path.split('/').first);
        }
        continue;
      }
      final String prefix = '$parent/';
      if (!path.startsWith(prefix)) continue;
      final String rest = path.substring(prefix.length);
      if (rest.isEmpty) continue;
      children.add('$parent/${rest.split('/').first}');
    }
    final List<String> sorted = children.toList()
      ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  /// Notes that sit directly in [folderPath], in the chosen order. Subfolders
  /// own their own notes, so the tree draws them separately.
  List<Note> notesInFolder(String folderPath) {
    final String folder = Note.normalizeFolderPath(folderPath);
    return _ordered
        .where((Note n) => n.folderPath == folder)
        .toList(growable: false);
  }

  Set<String> _folderPaths() {
    final Set<String> paths = <String>{};
    void addWithParents(String folderPath) {
      String current = '';
      for (final String part in Note.normalizeFolderPath(folderPath).split('/')) {
        if (part.isEmpty) continue;
        current = current.isEmpty ? part : '$current/$part';
        paths.add(current);
      }
    }

    for (final String folder in _folders) {
      addWithParents(folder);
    }
    for (final Note note in _notes) {
      if (note.folderPath.isNotEmpty) addWithParents(note.folderPath);
    }
    return paths;
  }

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
    final String raw = _query.trim();
    final String q = _caseSensitive ? raw : raw.toLowerCase();
    String fold(String text) => _caseSensitive ? text : text.toLowerCase();
    return _ordered.where((Note n) {
      if (_activeTag != null && !n.tags.contains(_activeTag)) return false;
      if (q.isEmpty) return true;
      return fold(n.title).contains(q) ||
          fold(n.body).contains(q) ||
          n.tags.any((String t) => fold(t).contains(q));
    }).toList(growable: false);
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
    final List<Note> loaded;
    final List<String> folders;
    try {
      loaded = await _store.loadAll();
      folders = await _store.listFolders();
    } catch (e) {
      _error = '读取笔记库失败:$e';
      notifyListeners();
      return;
    }
    _notes = loaded;
    _folders = folders;
    if (_activeFolder.isNotEmpty && !_folderPaths().contains(_activeFolder)) {
      _activeFolder = '';
    }
    _resort();
    if (!keepSelection || selectedNote == null) {
      _selectedId = _ordered.isEmpty ? null : _ordered.first.id;
      _draft = selectedNote;
      _draftOriginalPath = _draft?.relativePath;
    } else {
      // Re-read the file that is currently open, but never clobber unsaved
      // edits: the draft stays authoritative while it is dirty.
      if (_saveState == SaveState.idle || _saveState == SaveState.saved) {
        _draft = selectedNote;
        _draftOriginalPath = _draft?.relativePath;
      }
    }
    notifyListeners();
  }

  void _resort() {
    _ordered = List<Note>.of(_notes)..sort(_compareNotes);
  }

  /// Sorting is the only thing that decides the order: the file name is the
  /// tie-breaker, so two notes saved in the same second never swap places
  /// between rebuilds.
  int _compareNotes(Note a, Note b) {
    final int primary = switch (_lastSortMode) {
      SortMode.titleAsc => a.title.toLowerCase().compareTo(
        b.title.toLowerCase(),
      ),
      SortMode.titleDesc => b.title.toLowerCase().compareTo(
        a.title.toLowerCase(),
      ),
      SortMode.updatedDesc => b.updatedAt.compareTo(a.updatedAt),
      SortMode.updatedAsc => a.updatedAt.compareTo(b.updatedAt),
      SortMode.createdDesc => b.createdAt.compareTo(a.createdAt),
      SortMode.createdAsc => a.createdAt.compareTo(b.createdAt),
    };
    if (primary != 0) return primary;
    return a.relativePath.toLowerCase().compareTo(b.relativePath.toLowerCase());
  }

  /// Injected by the shell so the vault order follows the user's sort choice.
  SortMode _lastSortMode = SortMode.updatedDesc;

  set sortMode(SortMode mode) {
    _lastSortMode = mode;
    _resort();
    notifyListeners();
  }

  // --------------------------------------------------------------- filtering

  /// The text in the field *is* the filter. Typing lets go of any tag that was
  /// pinned before, so a query always looks at the whole vault instead of the
  /// corner the last tag left it in.
  void setQuery(String value) {
    if (_query == value && _activeTag == null) return;
    _query = value;
    _activeTag = null;
    notifyListeners();
  }

  void setCaseSensitive(bool value) {
    if (_caseSensitive == value) return;
    _caseSensitive = value;
    notifyListeners();
  }

  /// Picking a tag is a filter of its own: whatever text was in the field is
  /// dropped, so the list shows that tag's notes and nothing else.
  void toggleTag(String tagName) {
    _query = '';
    _activeTag = _activeTag == tagName ? null : tagName;
    notifyListeners();
  }

  void clearFilters() {
    _query = '';
    _activeTag = null;
    notifyListeners();
  }

  // ----------------------------------------------------------------- folders

  void setActiveFolder(String folderPath) {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (_activeFolder == folder) return;
    _activeFolder = folder;
    notifyListeners();
  }

  /// Creates a folder inside [activeFolder]. Returns its path, or null when the
  /// name has no usable characters left.
  Future<String?> createFolder(String name) async {
    final String cleaned = Note.slugify(name);
    if (cleaned.isEmpty) return null;
    final String parent = _activeFolder;
    final String freeName = _freeFolderName(parent, cleaned);
    final String path = parent.isEmpty ? freeName : '$parent/$freeName';
    try {
      await _store.createFolder(path);
      _folders = await _store.listFolders();
      if (!_folders.any((String f) => f.toLowerCase() == path.toLowerCase())) {
        _folders = <String>[..._folders, path];
      }
    } catch (e) {
      _error = '创建文件夹失败:$e';
      notifyListeners();
      return null;
    }
    _activeFolder = path;
    notifyListeners();
    return path;
  }

  String _freeFolderName(String parent, String base) {
    final Set<String> taken = <String>{
      for (final String path in childFoldersOf(parent))
        path.split('/').last.toLowerCase(),
    };
    if (!taken.contains(base.toLowerCase())) return base;
    for (int i = 2; i < 1000; i++) {
      final String next = '$base $i';
      if (!taken.contains(next.toLowerCase())) return next;
    }
    return base;
  }

  // -------------------------------------------------------------- selection

  void select(String? id) {
    if (_selectedId == id) return;
    _autosave.flush(() => _persistDraft());
    _selectedId = id;
    _draft = selectedNote;
    _draftOriginalPath = _draft?.relativePath;
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

  Note createNote({String title = '', String? folderPath}) {
    _autosave.flush(() => _persistDraft());
    // A note always has a name, because the file always has one: an untitled
    // note is `未命名.md`, the next one in the same folder is `未命名 2.md`, and
    // so on. The title is then read back *out* of that file name, so what the
    // editor selects — the placeholder the first keystroke replaces — is the
    // name the file actually carries.
    final String folder = Note.normalizeFolderPath(
      folderPath ?? _activeFolder,
    );
    final Note blank = Note.blank(title: title.trim(), folderPath: folder);
    final String fileName = _freeName(blank.fileName, folderPath: folder);
    final Note note = blank.copyWith(
      title: Note.titleOfFileName(fileName),
      fileName: fileName,
    );
    _notes = <Note>[note, ..._notes];
    _resort();
    _selectedId = note.id;
    _draft = note;
    _draftOriginalPath = note.relativePath;
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
      createdAt: now,
      updatedAt: now,
      folderPath: source.folderPath,
      fileName: _freeName(
        Note.buildFileName(title),
        folderPath: source.folderPath,
      ),
    );
    _notes = <Note>[copy, ..._notes];
    _resort();
    _selectedId = copy.id;
    _draft = copy;
    _draftOriginalPath = null;
    _saveState = SaveState.dirty;
    notifyListeners();
    unawaited(_persistDraft());
  }

  /// Renames any note in the vault, whether or not it is the open one — the
  /// tree's inline rename and its F2 shortcut both work on a row you are not
  /// editing.
  ///
  /// The file moves with the name, because the file name *is* the title; the
  /// note keeps its id, which is what keeps the tree's selection on the row.
  Future<void> renameNote(Note note, String title) async {
    final String clean = title.trim();
    if (clean.isEmpty || clean == note.title) return;
    final Note updated = note.copyWith(
      title: clean,
      fileName: _freeName(
        Note.buildFileName(clean),
        exceptId: note.id,
        folderPath: note.folderPath,
      ),
      updatedAt: DateTime.now(),
    );
    final bool isDraft = _selectedId == note.id || _draft?.id == note.id;
    if (isDraft) _autosave.cancel();
    _replace(updated);
    if (isDraft) _draft = updated;
    _resort();
    notifyListeners();
    try {
      await _writing;
      await _store.save(updated, previousPath: note.relativePath);
      if (isDraft) _draftOriginalPath = updated.relativePath;
    } catch (e) {
      _error = '重命名失败:$e';
      notifyListeners();
    }
  }

  /// Moves [targets] into [targetFolder], keeping every name unique in it.
  ///
  /// Two notes called `未命名.md` dragged in together land as `未命名.md` and
  /// `未命名 2.md`, because each name is resolved *after* the previous note is
  /// already recorded in the destination folder.
  Future<void> moveNotes(List<Note> targets, String targetFolder) async {
    final String folder = Note.normalizeFolderPath(targetFolder);
    final List<Note> movable = targets
        .where((Note n) => n.folderPath != folder)
        .toList(growable: false);
    if (movable.isEmpty) return;

    final List<({Note note, String previousPath})> writes =
        <({Note note, String previousPath})>[];
    for (final Note note in movable) {
      final Note updated = note.copyWith(
        folderPath: folder,
        fileName: _freeName(
          note.fileName,
          exceptId: note.id,
          folderPath: folder,
        ),
        updatedAt: DateTime.now(),
      );
      writes.add((note: updated, previousPath: note.relativePath));
      _replace(updated);
    }
    final Set<String> ids = <String>{for (final Note n in movable) n.id};
    if (_draft != null && ids.contains(_draft!.id)) {
      _autosave.cancel();
      _draft = _notes.firstWhere((Note n) => n.id == _draft!.id);
    }
    notifyListeners();

    try {
      await _writing;
      for (final ({Note note, String previousPath}) write in writes) {
        await _store.save(write.note, previousPath: write.previousPath);
      }
      if (_draft != null) _draftOriginalPath = _draft!.relativePath;
    } catch (e) {
      _error = '移动失败:$e';
      notifyListeners();
    }
    await refresh(keepSelection: true);
  }

  /// Renames a folder in place. Notes inside keep their ids — the id lives in
  /// the front matter, not in the path — so the tree's selection survives.
  ///
  /// Returns the new path, or null when the name is unusable or the target is
  /// already taken.
  Future<String?> renameFolder(String folderPath, String newName) async {
    final String from = Note.normalizeFolderPath(folderPath);
    if (from.isEmpty) return null;
    final String cleaned = Note.slugify(newName);
    if (cleaned.isEmpty) return null;
    if (cleaned.toLowerCase() == from.split('/').last.toLowerCase()) {
      return from;
    }
    final String parent = _parentOf(from);
    final String free = _freeFolderName(parent, cleaned);
    return _relocateFolder(from, parent.isEmpty ? free : '$parent/$free');
  }

  /// Moves [folderPath] — and everything inside it — under [targetParent].
  ///
  /// Dragging a folder into another folder is the same directory move a rename
  /// does, only with the destination given instead of the name. Dropping a
  /// folder into itself or into one of its own sub-folders is refused: the
  /// branch would come loose from the root.
  Future<String?> moveFolder(String folderPath, String targetParent) async {
    final String from = Note.normalizeFolderPath(folderPath);
    if (from.isEmpty) return null;
    final String parent = Note.normalizeFolderPath(targetParent);
    if (parent == from || parent.startsWith('$from/')) return null;
    if (_parentOf(from) == parent) return from;
    final String free = _freeFolderName(parent, from.split('/').last);
    return _relocateFolder(from, parent.isEmpty ? free : '$parent/$free');
  }

  Future<String?> _relocateFolder(String from, String to) async {
    final String name = from.split('/').last;
    try {
      if (!await _store.renameFolder(from, to)) {
        _error = '文件夹「$name」已经存在';
        notifyListeners();
        return null;
      }
    } catch (e) {
      _error = '移动文件夹失败:$e';
      notifyListeners();
      return null;
    }
    // Follow the folder the tree is pointing at, and any note whose ancestors
    // moved along with it.
    if (_activeFolder == from || _activeFolder.startsWith('$from/')) {
      _activeFolder = '$to${_activeFolder.substring(from.length)}';
    }
    await refresh(keepSelection: true);
    return to;
  }

  static String _parentOf(String folder) =>
      folder.contains('/')
      ? folder.substring(0, folder.lastIndexOf('/'))
      : '';

  Future<void> deleteNote(Note note) => deleteNotes(<Note>[note]);

  /// Removes every note in [targets] from the list and from disk.
  ///
  /// The shell may be showing a different note than the ones selected in the
  /// tree, so the open draft only moves when it is one of the targets. A write
  /// already in flight is awaited first: letting it land after the delete would
  /// put the file back on disk, which looks like the delete silently failed.
  Future<void> deleteNotes(List<Note> targets) async {
    if (targets.isEmpty) return;
    final Set<String> ids = <String>{for (final Note n in targets) n.id};
    final String? openId = _selectedId ?? _draft?.id;
    final bool removingOpen = openId != null && ids.contains(openId);
    if (removingOpen) _autosave.cancel();

    _notes = _notes.where((Note n) => !ids.contains(n.id)).toList();
    _ordered = _ordered.where((Note n) => !ids.contains(n.id)).toList();
    if (removingOpen || _selectedId == null) {
      _selectedId = _ordered.isEmpty ? null : _ordered.first.id;
      _draft = selectedNote;
      _draftOriginalPath = _draft?.relativePath;
      _saveState = SaveState.idle;
    }
    notifyListeners();

    await _writing;
    for (final Note note in targets) {
      await _store.delete(note);
    }
  }

  /// Puts deleted notes back on disk — powers the "撤销" affordance.
  Future<void> restoreNote(
    String rawMarkdown,
    String fileName, {
    String folderPath = '',
  }) => restoreNotes(<DeletedNote>[
    (raw: rawMarkdown, fileName: fileName, folderPath: folderPath),
  ]);

  Future<void> restoreNotes(List<DeletedNote> backups) async {
    if (backups.isEmpty) return;
    try {
      final List<Note> restored = <Note>[];
      for (final DeletedNote backup in backups) {
        restored.add(
          await _store.writeNewMarkdown(
            backup.raw,
            backup.fileName,
            folderPath: backup.folderPath,
          ),
        );
      }
      await refresh(keepSelection: false);
      if (restored.isNotEmpty) select(restored.first.id);
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
        fileName: _freeName(
          Note.buildFileName(title),
          exceptId: current.id,
          folderPath: current.folderPath,
        ),
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// [candidate] unless another note in the same folder already owns that file
  /// name, in which case ` 2`, ` 3` … is appended before `.md`.
  ///
  /// File names are compared case-insensitively because Windows and macOS file
  /// systems are: `周报.md` and `周报.MD` are the same file. Folders are scoped
  /// separately: `工作/周报.md` and `随手/周报.md` are two perfectly good notes.
  String _freeName(
    String candidate, {
    String? exceptId,
    String? folderPath,
  }) {
    final String folder = Note.normalizeFolderPath(
      folderPath ?? _activeFolder,
    );
    final Set<String> taken = <String>{
      for (final Note n in _notes)
        if (n.id != exceptId &&
            n.folderPath.toLowerCase() == folder.toLowerCase())
          n.fileName.toLowerCase(),
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
      fileName: _freeName(
        draft.fileName,
        exceptId: draft.id,
        folderPath: draft.folderPath,
      ),
    );
    if (note.fileName != draft.fileName) {
      _draft = note;
      _replace(note);
    }
    _saveState = SaveState.saving;
    notifyListeners();
    final String? previous = _draftOriginalPath;
    try {
      await _store.save(note, previousPath: previous);
      _draftOriginalPath = note.relativePath;
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
