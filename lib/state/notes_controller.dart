import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_enums.dart';
import '../core/platform/boot_trace.dart';
import '../core/utils/debouncer.dart';
import '../data/models/note.dart';
import '../data/storage/note_store_factory.dart';
import 'vault_reconciler.dart';

/// What one delete request actually accomplished.
///
/// [receipts] are the trash entries the undo affordance needs; [failed] counts
/// notes whose files could not be moved and therefore stayed in the vault.
typedef DeleteOutcome = ({List<TrashEntry> receipts, int deleted, int failed});

/// What one folder delete actually accomplished.
///
/// [blocked] carries the reason nothing was touched — a folder holding files the
/// note trash cannot restore is refused before any note moves. [removed] says
/// the directory itself is gone; [deleted] notes may be in the trash even when
/// it is false, so undo reads [receipts] and not [removed].
typedef FolderDeleteOutcome = ({
  List<TrashEntry> receipts,
  int deleted,
  int failed,
  bool removed,
  String? blocked,
});

/// A tag together with how many notes use it.
class TagStat {
  const TagStat(this.name, this.count);
  final String name;
  final int count;
}

/// One search result: a note, and every line in it that matched.
class SearchHit {
  const SearchHit({required this.note, required this.snippets});

  final Note note;

  /// Matching lines, in the order they appear. Empty when the only match was in
  /// the title — the group header already shows that.
  final List<SearchSnippet> snippets;

  int get matchCount => snippets.length;
}

/// One matching line, with the range to pick out inside it.
class SearchSnippet {
  const SearchSnippet({
    required this.text,
    required this.matchStart,
    required this.matchEnd,
    required this.matchOffset,
  });

  final String text;

  /// Range to highlight inside [text]. `-1` when there is nothing to mark.
  final int matchStart;
  final int matchEnd;

  /// Where the match sits in the note's body, in source offsets. Clicking the
  /// snippet opens the note and parks the caret here, so `…`-trimmed snippets
  /// still land on the right line.
  final int matchOffset;

  bool get hasHighlight => matchStart >= 0 && matchEnd > matchStart;
}

enum SaveState { idle, dirty, saving, saved }

enum DraftConflictKind { modified, deleted }

/// The open note changed on disk while it had unsaved edits.
///
/// Autosave stops until the user chooses: silently overwriting either side is
/// exactly the data loss all of this bookkeeping exists to prevent.
class DraftConflict {
  const DraftConflict({
    required this.noteId,
    required this.kind,
    this.external,
  });

  final String noteId;
  final DraftConflictKind kind;

  /// The version on disk. Null when the file itself was deleted.
  final Note? external;

  bool get isDeleted => kind == DraftConflictKind.deleted;
}

/// Owns the vault: loading, filtering, editing and persisting notes.
///
/// List order is deliberately *stable while you type* — a note only moves to the
/// top after an explicit refresh, create, delete or sort change. Watching the
/// row you are editing jump around is the fastest way to make an editor feel
/// cheap.
class NotesController extends ChangeNotifier {
  NotesController({NoteStore? store}) : _store = store ?? createNoteStore();

  final NoteStore _store;

  /// Called after [createNote] has put a brand-new blank note in place.
  ///
  /// The shell uses it for folder templates; the controller itself knows nothing
  /// about templates. The hook runs asynchronously, so the note is already on
  /// screen and the user can start typing while a template prompt is open. It
  /// must therefore re-check the note before writing anything — [applyBodyIfEmpty]
  /// is the safe way to do that.
  Future<void> Function(Note note)? onBlankNoteCreated;

  /// How many canvases live in [folder], subfolders included.
  ///
  /// [deleteFolder] needs it for the message it shows when the folder is not
  /// clean. Without it the user reads "还有不是笔记的文件" and has no idea what
  /// that file is — usually a `.nrs` board, which is exactly what stopped the
  /// delete. Canvases are never trashed together with the folder, so they have
  /// to be named instead.
  Future<int> Function(String folder)? canvasCountOf;

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

  /// 文件树里的「其他文件」：图片、附件。只用于显示，不参与任何索引。
  List<VaultFile> _files = <VaultFile>[];
  String _activeFolder = '';
  String? _selectedId;
  Note? _draft;
  String? _draftOriginalPath;
  bool _loading = true;
  String? _error;
  SaveState _saveState = SaveState.idle;
  Timer? _savedIndicatorTimer;

  /// The version each note was last read from or written to disk. An external
  /// edit is only a conflict when it differs from *this*, not from whatever the
  /// user has typed since.
  final Map<String, Note> _baselines = <String, Note>{};

  /// The vault as it was at the last load; used to notice changes without
  /// re-reading every file on every focus.
  Map<String, NoteFileStamp> _stamps = <String, NoteFileStamp>{};

  DraftConflict? _conflict;
  bool _syncInFlight = false;
  int _editRevision = 0;

  // -------------------------------------------------------------- filter state
  String _query = '';
  bool _caseSensitive = false;

  // ------------------------------------------------------------------ getters

  bool get isLoading => _loading;
  String? get error => _error;
  String get vaultLocation => _store.location;
  bool get supportsNativeFiles => _store.supportsNativeFiles;

  /// vault 的真实路径（浏览器端为 null）。
  String? get vaultPath => _store.vaultPath;
  bool get supportsTrash => _store.supportsTrash;
  bool get supportsHistory => _store.supportsHistory;
  List<Note> get allNotes => List<Note>.unmodifiable(_ordered);

  /// 只读的结构版本号：新增/删除/重命名/移动/排序/文件夹变化时递增。
  ///
  /// 文件树只需要在这个版本号、选中项或筛选条件变化时重建；正文输入不碰它，
  /// 因此不会让整棵文件树跟着每个字符重排（任务徽标由行内单独订阅）。
  int get structureRevision => _structureRevision;

  int _structureRevision = 0;

  void _bumpStructure() => _structureRevision++;

  Note? noteById(String id) => _noteById(id);
  String? get selectedId => _selectedId;
  SaveState get saveState => _saveState;

  /// The unresolved external change for the open note, if any.
  DraftConflict? get conflict => _conflict;

  bool get _draftHasConflict =>
      _conflict != null && _conflict!.noteId == _draft?.id;

  String get query => _query;

  /// Whether the query matches case for case. Off by default, because most
  /// searches are for a word rather than for its capitalisation.
  bool get caseSensitive => _caseSensitive;

  /// The tag the query is pinned to, if any.
  ///
  /// Derived from the query rather than stored beside it: clicking `#入门` in a
  /// note types `tag:#入门` into the search box, so there is exactly one place
  /// that says what is being filtered — and the user can see it, edit it, or
  /// add a word after it.
  String? get activeTag {
    final List<String> tags = parseQuery(_query).tags;
    return tags.isEmpty ? null : tags.first;
  }

  bool get isFiltered => _query.trim().isNotEmpty;

  /// Folder that receives the next new note. Empty means the vault root.
  String get activeFolder => _activeFolder;

  /// Every real directory in the vault, including empty ones.
  List<String> get folders {
    final List<String> list = _folderPaths().toList()
      ..sort((String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return List<String>.unmodifiable(list);
  }

  /// 文件树里的「其他文件」：图片、PDF、附件。笔记和白板不在其中。
  List<VaultFile> get files => List<VaultFile>.unmodifiable(_files);

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
    final ({List<String> tags, String text}) parsed = parseQuery(_query);
    final String raw = parsed.text;
    final String q = _caseSensitive ? raw : raw.toLowerCase();
    final bool fold = !_caseSensitive;
    return _ordered.where((Note n) {
      // Every `tag:` filter has to hold; tags are matched case-insensitively
      // because they are labels, not code.
      for (final String tag in parsed.tags) {
        final String needle = tag.toLowerCase();
        if (!n.tags.any((String t) => t.toLowerCase() == needle)) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      final String title = fold ? n.foldedTitle : n.title;
      final String body = fold ? n.foldedBody : n.body;
      return title.contains(q) ||
          body.contains(q) ||
          n.tags.any(
            (String t) => (fold ? t.toLowerCase() : t).contains(q),
          );
    }).toList(growable: false);
  }

  /// The visible notes, each with the line that made it match.
  ///
  /// A list of names answers "which notes"; a search wants "where", so every
  /// hit carries the matching line and the range inside it to highlight.
  List<SearchHit> get searchHits {
    final ({List<String> tags, String text}) parsed = parseQuery(_query);
    return <SearchHit>[
      for (final Note note in visibleNotes) _hitFor(note, parsed),
    ];
  }

  /// Splits a query into `tag:` filters and the free text that is left.
  ///
  /// `tag:#入门 引用` means "notes tagged 入门 that mention 引用": the tag is a
  /// filter, not a word to look for, so it is parsed out instead of being
  /// matched against the body — otherwise a note that merely mentions the tag
  /// in passing would still be found.
  static ({List<String> tags, String text}) parseQuery(String raw) {
    final List<String> tags = <String>[];
    final StringBuffer text = StringBuffer();
    for (final String token in raw.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      if (token.toLowerCase().startsWith('tag:')) {
        final String name = token
            .substring(4)
            .replaceFirst(RegExp(r'^#'), '')
            .trim();
        if (name.isNotEmpty) tags.add(name);
      } else {
        if (text.isNotEmpty) text.write(' ');
        text.write(token);
      }
    }
    return (tags: tags, text: text.toString());
  }

  /// Every matching line in [note], one snippet per line, in source order.
  ///
  /// A note can match on several lines — every mention of a tag, say — and each
  /// of them is worth showing: the count in the group header has to mean
  /// something, and one snippet per note would hide the other four.
  SearchHit _hitFor(Note note, ({List<String> tags, String text}) parsed) {
    // 大小写不敏感时直接在 Note 的折叠副本上找，偏移与原正文一致：副本由
    // 同一套 `toLowerCase` 生成，和逐次转换的结果逐字符相同。
    final String haystack = _caseSensitive ? note.body : note.foldedBody;
    final List<String> needles = <String>[
      for (final String tag in parsed.tags) '#$tag',
      if (parsed.text.isNotEmpty) parsed.text,
    ];
    final List<SearchSnippet> snippets = <SearchSnippet>[];
    final Set<int> lines = <int>{};

    for (final String needle in needles) {
      int from = 0;
      while (snippets.length < _kMaxSnippets) {
        final int at = _indexOf(haystack, needle, from);
        if (at < 0) break;
        final int lineStart = note.body.lastIndexOf('\n', at) + 1;
        // Two needles on one line is still one line: the group shows lines, and
        // the same line twice would inflate the count.
        if (lines.add(lineStart)) {
          snippets.add(_snippetAt(note.body, at, needle.length, lineStart));
        }
        from = at + (needle.isEmpty ? 1 : needle.length);
      }
    }

    // Matched on the title only: the header already shows the name, so fall
    // back to the first line of the body as quiet context.
    if (snippets.isEmpty) {
      final String firstLine = note.body
          .split('\n')
          .firstWhere((String line) => line.trim().isNotEmpty, orElse: () => '');
      if (firstLine.trim().isNotEmpty) {
        final int at = note.body.indexOf(firstLine);
        snippets.add(
          SearchSnippet(
            text: firstLine.trim(),
            matchStart: -1,
            matchEnd: -1,
            matchOffset: at < 0 ? 0 : at,
          ),
        );
      }
    }
    return SearchHit(note: note, snippets: snippets);
  }

  /// How many snippets one note may contribute before the group becomes a
  /// document view rather than a search result.
  static const int _kMaxSnippets = 20;

  /// The line containing [at], trimmed, with the highlight mapped onto it.
  ///
  /// Long lines are cut to a window around the match, because a snippet that
  /// starts at column zero of a 400-character paragraph would push the
  /// highlight out of the two visible lines — which is the only reason to show
  /// the snippet at all.
  SearchSnippet _snippetAt(
    String body,
    int at,
    int length,
    int lineStart,
  ) {
    int lineEnd = body.indexOf('\n', at);
    if (lineEnd < 0) lineEnd = body.length;
    final String rawLine = body.substring(lineStart, lineEnd);
    final int lead = rawLine.length - rawLine.trimLeft().length;
    String text = rawLine.trim();
    int start = at - lineStart - lead;
    int end = start + length;

    const int window = 120;
    if (text.length > window) {
      final int from = (start - 30).clamp(0, text.length - window);
      final int to = from + window;
      final String head = from > 0 ? '…' : '';
      final String tail = to < text.length ? '…' : '';
      text = '$head${text.substring(from, to)}$tail';
      start += head.length - from;
      end += head.length - from;
    }

    return SearchSnippet(
      text: text,
      matchStart: start.clamp(0, text.length),
      matchEnd: end.clamp(0, text.length),
      matchOffset: at,
    );
  }

  int _indexOf(String haystack, String needle, [int from = 0]) {
    if (needle.isEmpty) return -1;
    if (_caseSensitive) return haystack.indexOf(needle, from);
    // 大小写不敏感时 [haystack] 已经折叠过，只需折查询词。
    return haystack.indexOf(needle.toLowerCase(), from);
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
    bool restored = false;
    try {
      await _store.init();
      BootTrace.mark('store init');
      await refresh(keepSelection: false);
      BootTrace.mark('refresh');
      // `refresh` 自己吞掉了读盘失败。读不到 vault 时不能把会话兑现成空
      // 标签栏，否则下一次保存就把上次的四个标签抹掉了。
      if (_error == null) restored = _applySession();
    } catch (e) {
      _error = '无法打开笔记库:$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
    if (!restored && _selectedId == null && _ordered.isNotEmpty) {
      select(_ordered.first.id);
    }
  }

  Future<void> refresh({bool keepSelection = true}) async {
    final List<Note> loaded;
    final List<String> folders;
    final List<NoteFileStamp>? stamps;
    final List<VaultFile> files;
    try {
      // 先读正文，再取指纹：读的时候顺手 stat 过了，`stamps()` 直接拿那份
      // 结果，不用把八百多个文件再 open 一遍。桌面端的指纹和内容来自**同一次**
      // stat，比原先两次独立扫描更一致。
      loaded = await _store.loadAll();
      stamps = await _store.stamps();
      folders = await _store.listFolders();
      // 不读内容也不 stat，只从上面那次遍历的结果里筛，所以它是免费的。
      files = await _store.listFiles();
    } catch (e) {
      _error = '读取笔记库失败:$e';
      notifyListeners();
      return;
    }
    if (stamps != null) {
      _stamps = <String, NoteFileStamp>{
        for (final NoteFileStamp stamp in stamps)
          stamp.relativePath: stamp,
      };
    }
    _notes = loaded;
    _folders = folders;
    _files = files;
    // A tab whose note is gone (deleted or moved on disk) has nothing to show.
    _openIds.removeWhere((String id) => _noteById(id) == null);
    if (_activeFolder.isNotEmpty && !_folderPaths().contains(_activeFolder)) {
      _activeFolder = '';
    }
    _resort();
    if (!keepSelection || selectedNote == null) {
      _selectedId = _ordered.isEmpty ? null : _ordered.first.id;
      if (_selectedId != null) _rememberTab(_selectedId!);
      _draft = selectedNote;
      _draftOriginalPath = _draft?.relativePath;
      _rememberBaseline(_draft);
    } else {
      // Re-read the file that is currently open, but never clobber unsaved
      // edits: the draft stays authoritative while it is dirty.
      if (_saveState == SaveState.idle || _saveState == SaveState.saved) {
        _draft = selectedNote;
        _draftOriginalPath = _draft?.relativePath;
        _rememberBaseline(_draft);
      }
    }
    notifyListeners();
  }

  void _rememberBaseline(Note? note) {
    if (note == null) return;
    if (_conflict?.noteId == note.id) return;
    _baselines[note.id] = note;
  }

  void _resort() {
    _ordered = List<Note>.of(_notes)..sort(_compareNotes);
    _bumpStructure();
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

  SortMode get sortMode => _lastSortMode;

  set sortMode(SortMode mode) {
    _lastSortMode = mode;
    _resort();
    notifyListeners();
  }

  // --------------------------------------------------------------- filtering

  /// The text in the field *is* the filter — including its `tag:` parts, which
  /// is why there is no separate "active tag" to keep in sync: whatever the
  /// field says is what the list shows.
  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    notifyListeners();
  }

  void setCaseSensitive(bool value) {
    if (_caseSensitive == value) return;
    _caseSensitive = value;
    notifyListeners();
  }

  /// Picking a tag writes `tag:#name` into the field, so the filter is visible
  /// and editable; picking the same tag again clears it.
  void toggleTag(String tagName) {
    final String next = 'tag:#$tagName';
    setQuery(_query.trim() == next ? '' : next);
  }

  void clearFilters() => setQuery('');

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
    _bumpStructure();
    notifyListeners();
    return path;
  }

  /// Creates [folderPath] (parents included) wherever it lives in the vault.
  ///
  /// Unlike [createFolder], which names a new child of the active folder, this
  /// takes a full vault-relative path — the templates folder comes from
  /// settings, so it must not be reinterpreted relative to the current tree
  /// selection.
  Future<bool> ensureFolder(String folderPath) async {
    final String path = Note.normalizeFolderPath(folderPath);
    if (path.isEmpty) return false;
    if (_folderPaths().any(
      (String f) => f.toLowerCase() == path.toLowerCase(),
    )) {
      return true;
    }
    try {
      await _store.createFolder(path);
      _folders = await _store.listFolders();
      if (!_folders.any((String f) => f.toLowerCase() == path.toLowerCase())) {
        _folders = <String>[..._folders, path];
      }
    } catch (e) {
      _error = '创建文件夹失败:$e';
      notifyListeners();
      return false;
    }
    _bumpStructure();
    notifyListeners();
    return true;
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

  /// Notes that are open, in tab order.
  ///
  /// The selected id is always one of these — or null when the strip is empty.
  /// Opening a note that is already open just switches to its tab; the strip
  /// never holds two tabs for one note.
  final List<String> _openIds = <String>[];

  List<String> get openIds => List<String>.unmodifiable(_openIds);

  /// 启动时要恢复的标签会话，`null` 表示没有（首次启动）。
  ///
  /// 等 vault 读完才兑现：id 认不出的笔记（换过库、手删过文件）要跳过，
  /// 不能先画出一个空标签再让它消失。
  List<String>? _sessionTabs;
  String? _sessionSelected;

  bool _tabSessionRestored = false;

  /// 这次启动真的按上次的标签会话恢复过（哪怕是空标签栏）。
  ///
  /// 外壳据此决定要不要补「选中第一篇」的默认动作：用户自己关光标签是
  /// 一个状态，不该在下一帧被当成「没有选中」重新填上。
  bool get tabSessionRestored => _tabSessionRestored;

  /// The open notes in tab order. A note that disappeared from the vault is
  /// skipped rather than drawn as a blank tab.
  List<Note> get openNotes {
    final List<Note> open = <Note>[];
    for (final String id in _openIds) {
      final Note? note = _noteById(id);
      if (note != null) open.add(note);
    }
    return open;
  }

  Note? _noteById(String id) {
    for (final Note note in _notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  /// 接上上次退出时的标签栏，等 [bootstrap] 读完 vault 后恢复。
  ///
  /// [tabs] 为 `null` 表示没有会话（首次启动），保持原来的「打开第一篇」；
  /// 空列表表示用户上次关光了标签，启动后也应保持空。必须在 [bootstrap]
  /// 之前调用。
  void restoreSession({List<String>? tabs, String? selected}) {
    _sessionTabs = tabs == null ? null : List<String>.of(tabs);
    _sessionSelected = selected;
  }

  /// 把会话落到刚读完的 vault 上。
  ///
  /// 返回 true 表示确实有一次会话要恢复——包括空列表。调用方据此跳过
  /// 「没有选中就打开第一篇」的默认动作。
  bool _applySession() {
    final List<String>? saved = _sessionTabs;
    if (saved == null) return false;
    final String? savedSelected = _sessionSelected;
    _sessionTabs = null;
    _sessionSelected = null;
    _tabSessionRestored = true;

    final List<String> surviving = <String>[];
    for (final String id in saved) {
      if (_noteById(id) != null && !surviving.contains(id)) surviving.add(id);
    }
    _openIds
      ..clear()
      ..addAll(surviving);

    if (surviving.isEmpty) {
      _selectedId = null;
      _draft = null;
      _draftOriginalPath = null;
      _saveState = SaveState.idle;
      return true;
    }

    String wanted = surviving.first;
    if (savedSelected != null && surviving.contains(savedSelected)) {
      wanted = savedSelected;
    } else if (savedSelected != null) {
      // 上次选中的那篇不在 vault 里了：右邻居接手，它原本在最后一页时交给
      // 左邻居——和 [closeTab] 是同一条规则。
      final int at = saved.indexOf(savedSelected);
      bool found = false;
      for (int i = at + 1; i < saved.length; i++) {
        if (surviving.contains(saved[i])) {
          wanted = saved[i];
          found = true;
          break;
        }
      }
      if (!found) {
        for (int i = at - 1; i >= 0; i--) {
          if (surviving.contains(saved[i])) {
            wanted = saved[i];
            break;
          }
        }
      }
    }
    _selectedId = wanted;
    _draft = selectedNote;
    _draftOriginalPath = _draft?.relativePath;
    _rememberBaseline(_draft);
    _saveState = _draftHasConflict ? SaveState.dirty : SaveState.idle;
    return true;
  }

  void _rememberTab(String id) {
    if (!_openIds.contains(id)) _openIds.add(id);
  }

  void select(String? id) {
    if (_selectedId == id) {
      // A tab can be missing after a restore or a delete that ran behind the
      // shell's back; selecting it again is the cheapest way to heal that.
      if (id != null && !_openIds.contains(id)) {
        _openIds.add(id);
        notifyListeners();
      }
      return;
    }
    _autosave.flush(() => _persistDraft());
    if (id != null) _rememberTab(id);
    _selectedId = id;
    _draft = selectedNote;
    _draftOriginalPath = _draft?.relativePath;
    _rememberBaseline(_draft);
    _saveState = _draftHasConflict ? SaveState.dirty : SaveState.idle;
    notifyListeners();
  }

  /// Closes one tab. Closing the active tab hands the editor to its right-hand
  /// neighbour, or to the left one when it was last — the same rule a browser
  /// uses, so the strip never jumps back to the far end.
  void closeTab(String id) {
    final int index = _openIds.indexOf(id);
    if (index < 0) return;
    final bool wasActive = _selectedId == id;
    _openIds.removeAt(index);
    if (!wasActive) {
      notifyListeners();
      return;
    }
    _autosave.flush(() => _persistDraft());
    _selectedId = _openIds.isEmpty
        ? null
        : _openIds[index.clamp(0, _openIds.length - 1)];
    _draft = selectedNote;
    _draftOriginalPath = _draft?.relativePath;
    _rememberBaseline(_draft);
    _saveState = _draftHasConflict ? SaveState.dirty : SaveState.idle;
    notifyListeners();
  }

  /// Ctrl+Tab / Ctrl+Shift+Tab: moves between open tabs, wrapping at the ends.
  void selectAdjacentTab(int delta) {
    if (_openIds.length < 2) return;
    final int current = _selectedId == null
        ? -1
        : _openIds.indexOf(_selectedId!);
    if (current < 0) {
      select(_openIds.first);
      return;
    }
    final int count = _openIds.length;
    final int next = (current + delta) % count;
    select(_openIds[next < 0 ? next + count : next]);
  }

  void selectAdjacentInList(List<Note> visible, int delta) {
    if (visible.isEmpty) return;
    final int index = visible.indexWhere((Note n) => n.id == _selectedId);
    final int next = index < 0 ? 0 : (index + delta).clamp(0, visible.length - 1);
    select(visible[next].id);
  }

  // ------------------------------------------------------------------- CRUD

  /// Creates a blank note and opens it.
  ///
  /// [runCreationHook] is false for flows that already have their own content
  /// for the new note — creating from a template must not also apply the
  /// folder's automatic template on top.
  Note createNote({
    String title = '',
    String? folderPath,
    bool runCreationHook = true,
  }) {
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
    _rememberTab(note.id);
    _draft = note;
    // Nothing is on disk yet. Leaving this null makes the first write a
    // creation, so a file the user dropped into the vault at that name is
    // reported as a clash instead of being overwritten.
    _draftOriginalPath = null;
    _baselines.remove(note.id);
    _editRevision++;
    _saveState = SaveState.dirty;
    notifyListeners();
    unawaited(_persistDraft());
    if (runCreationHook) _runCreationHook(note);
    return note;
  }

  void _runCreationHook(Note note) {
    final Future<void> Function(Note note)? hook = onBlankNoteCreated;
    if (hook == null) return;
    unawaited(() async {
      try {
        await hook(note);
      } catch (e) {
        _error = '模板套用失败:$e';
        notifyListeners();
      }
    }());
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
    _rememberTab(copy.id);
    _draft = copy;
    _draftOriginalPath = null;
    _baselines.remove(copy.id);
    _editRevision++;
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
    // The row handed in can be older than the draft: body edits do not bump the
    // tree's structure revision, so the menu may still hold the Note it drew
    // before the last keystroke. Renaming that copy would write its old body
    // over the file.
    final Note current = _noteById(note.id) ?? note;
    final String clean = title.trim();
    if (clean.isEmpty || clean == current.title) return;
    final Note updated = current.copyWith(
      title: clean,
      fileName: _freeName(
        Note.buildFileName(clean),
        exceptId: current.id,
        folderPath: current.folderPath,
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
      await _store.save(updated, previousPath: current.relativePath);
      await _refreshStamp(updated.relativePath, current.relativePath);
      _baselines[updated.id] = updated;
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
    for (final Note target in movable) {
      // Same trap as [renameNote]: a drag carries the rows as they were drawn,
      // and the open note may have unsaved words typed since. The move writes
      // the file, so it has to carry the freshest copy, not the dragged one.
      final Note note = _noteById(target.id) ?? target;
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
        await _refreshStamp(write.note.relativePath, write.previousPath);
        _baselines[write.note.id] = write.note;
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

  /// Deletes [folderPath] and everything the note trash can hold.
  ///
  /// The folder is checked before anything moves: the trash restores notes, not
  /// pictures or hand-written files, so a directory holding anything else is
  /// refused while it is still whole. Otherwise the notes are trashed
  /// recursively and only the empty directories are removed — a partial delete
  /// leaves the notes that failed exactly where they were.
  /// Boards directly in [folder] or below it. Never throws: a listing failure
  /// only costs a less specific message.
  Future<int> _canvasCountIn(String folder) async {
    final Future<int> Function(String folder)? count = canvasCountOf;
    if (count == null) return 0;
    try {
      return await count(folder);
    } catch (_) {
      return 0;
    }
  }

  Future<FolderDeleteOutcome> deleteFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) {
      return (
        receipts: const <TrashEntry>[],
        deleted: 0,
        failed: 0,
        removed: false,
        blocked: '不能删除笔记库根目录',
      );
    }

    final List<Note> targets = _notes
        .where(
          (Note note) =>
              note.folderPath == folder ||
              note.folderPath.startsWith('$folder/'),
        )
        .toList(growable: false);
    final bool clean;
    try {
      clean = await _store.folderHoldsOnlyNotes(folder, <String>{
        for (final Note note in targets) note.relativePath,
      });
    } catch (e) {
      return (
        receipts: const <TrashEntry>[],
        deleted: 0,
        failed: 0,
        removed: false,
        blocked: '无法检查文件夹内容:$e',
      );
    }
    if (!clean) {
      final int boards = await _canvasCountIn(folder);
      return (
        receipts: const <TrashEntry>[],
        deleted: 0,
        failed: 0,
        removed: false,
        blocked: boards > 0 ? '文件夹里还有 $boards 块白板' : '文件夹里还有不是笔记的文件',
      );
    }

    final DeleteOutcome outcome = await deleteNotes(targets);
    bool removed = false;
    if (outcome.failed == 0) {
      try {
        removed = await _store.deleteFolder(folder);
      } catch (e) {
        _error = '删除文件夹失败:$e';
      }
    }

    if (removed &&
        (_activeFolder == folder || _activeFolder.startsWith('$folder/'))) {
      _activeFolder = _parentOf(folder);
    }
    try {
      _folders = await _store.listFolders();
      // A sub-folder can disappear while its ancestor survives; never leave the
      // next new note pointed at a path the tree no longer shows.
      if (_activeFolder.isNotEmpty && !_folderPaths().contains(_activeFolder)) {
        _activeFolder = '';
      }
    } catch (_) {
      // The note list already moved; a stale folder list must not undo that.
    }
    _bumpStructure();
    notifyListeners();
    return (
      receipts: outcome.receipts,
      deleted: outcome.deleted,
      failed: outcome.failed,
      removed: removed,
      blocked: null,
    );
  }

  Future<TrashEntry?> deleteNote(Note note) async {
    final DeleteOutcome outcome = await deleteNotes(<Note>[note]);
    return outcome.receipts.isEmpty ? null : outcome.receipts.first;
  }

  /// Moves [targets] into the vault's trash and only then removes them from the
  /// open lists. A file that could not be moved stays in the vault and on
  /// screen; a bulk delete is allowed to be partial rather than pretending the
  /// untouched notes are gone.
  ///
  /// When the open note is among the targets its pending edits are flushed
  /// first: a trash entry holding the previous draft would silently lose the
  /// last few characters.
  Future<DeleteOutcome> deleteNotes(List<Note> targets) async {
    if (targets.isEmpty) {
      return (receipts: const <TrashEntry>[], deleted: 0, failed: 0);
    }

    final String? openId = _draft?.id ?? _selectedId;
    final bool removingOpen =
        openId != null && targets.any((Note n) => n.id == openId);
    if (removingOpen) {
      final bool flushed = await _flushDraftBefore('删除');
      if (!flushed) {
        return (
          receipts: const <TrashEntry>[],
          deleted: 0,
          failed: targets.length,
        );
      }
    } else {
      // A write already in flight must land before the file is moved; letting
      // it land afterwards would put the note back on disk.
      await _writing;
    }

    final List<TrashEntry> receipts = <TrashEntry>[];
    final List<Note> deleted = <Note>[];
    int failed = 0;
    String? failure;
    for (final Note target in targets) {
      final Note note = _noteById(target.id) ?? target;
      try {
        final TrashEntry? receipt = await _store.delete(note);
        deleted.add(note);
        if (receipt != null) receipts.add(receipt);
      } catch (e) {
        failed++;
        final String title = note.title.trim().isEmpty
            ? note.fileName
            : note.title.trim();
        failure = '删除「$title」失败,文件仍保留:$e';
      }
    }

    if (failure != null) _error = failure;
    if (deleted.isNotEmpty) _removeDeletedFromMemory(deleted);
    notifyListeners();
    return (receipts: receipts, deleted: deleted.length, failed: failed);
  }

  void _removeDeletedFromMemory(List<Note> deleted) {
    final Set<String> ids = <String>{for (final Note n in deleted) n.id};
    final String? openId = _draft?.id ?? _selectedId;
    final bool removingOpen = openId != null && ids.contains(openId);
    final int oldIndex = openId == null ? -1 : _openIds.indexOf(openId);

    _notes = _notes.where((Note n) => !ids.contains(n.id)).toList();
    _ordered = _ordered.where((Note n) => !ids.contains(n.id)).toList();
    _bumpStructure();
    _openIds.removeWhere(ids.contains);
    for (final Note note in deleted) {
      _stamps.remove(note.relativePath);
      _baselines.remove(note.id);
    }
    if (_conflict != null && ids.contains(_conflict!.noteId)) {
      _conflict = null;
    }
    if (removingOpen) {
      _autosave.cancel();
      _selectNeighbor(oldIndex);
    } else if (_selectedId != null && _noteById(_selectedId!) == null) {
      _selectNeighbor(oldIndex);
    }
  }

  /// Saves the open draft and reports whether it is safe to continue with an
  /// operation that will rebuild the draft from disk.
  Future<bool> _flushDraftBefore(String action) async {
    _autosave.cancel();
    // A clean draft has nothing to flush; writing it anyway would schedule a
    // save-indicator timer for an operation that never touched the file.
    if (_saveState == SaveState.dirty) await _persistDraft();
    await _writing;
    if (_saveState != SaveState.dirty) return true;
    _error = _draftHasConflict
        ? '$action已取消:先处理当前笔记的外部冲突'
        : '$action已取消:当前笔记未能保存到磁盘';
    notifyListeners();
    return false;
  }

  /// Writes `.md` files dropped onto the note list into the vault.
  ///
  /// A file dragged in from the desktop is not a vault file: it is read, then
  /// written as a **new** note under its own name. A name already taken gets
  /// the same ` 2` rule every other new file gets, so a drop can never
  /// overwrite what is already there.
  ///
  /// Everything else is refused and counted: a folder, a PDF, a picture. The
  /// list is notes, and a note is a `.md`.
  ///
  /// Files land in [activeFolder] — the folder the user is standing in — the
  /// same place 新建笔记 would put them.
  ///
  /// The last file imported is opened — with several files in one drop, that is
  /// the one the user was aiming at.
  Future<({int imported, int refused})> importMarkdownFiles(
    List<String> paths,
  ) async {
    int imported = 0;
    int refused = 0;
    String? lastId;
    for (final String path in paths) {
      final String name = _fileNameOfPath(path);
      if (!name.toLowerCase().endsWith('.md')) {
        refused++;
        continue;
      }
      final String? raw = await _store.readMarkdownFile(path);
      if (raw == null) {
        refused++;
        continue;
      }
      try {
        final Note note = await _store.writeNewMarkdown(
          raw,
          name,
          folderPath: _activeFolder,
        );
        lastId = note.id;
        imported++;
      } catch (_) {
        refused++;
      }
    }
    if (imported > 0) {
      await refresh(keepSelection: false);
      if (lastId != null) select(lastId);
    }
    return (imported: imported, refused: refused);
  }

  // ------------------------------------------------------------------- trash

  /// Everything waiting in the vault's trash, newest deletion first.
  Future<List<TrashEntry>> listTrash() async {
    try {
      return await _store.listTrash();
    } catch (e) {
      _error = '读取回收站失败:$e';
      notifyListeners();
      return const <TrashEntry>[];
    }
  }

  /// Restores the given trash entries, returning how many came back.
  ///
  /// Restoring rebuilds the draft from disk, so the open note is saved first.
  /// Entries that fail stay in the trash; a partial restore keeps what worked.
  Future<int> restoreTrashEntries(List<String> entryIds) async {
    if (entryIds.isEmpty) return 0;
    if (!await _flushDraftBefore('恢复')) return 0;

    int restored = 0;
    int failed = 0;
    String? firstId;
    for (final String entryId in entryIds) {
      try {
        final Note? note = await _store.restoreTrash(entryId);
        if (note == null) {
          failed++;
          continue;
        }
        restored++;
        firstId ??= note.id;
      } catch (_) {
        failed++;
      }
    }
    if (restored > 0) {
      await refresh(keepSelection: false);
      final String? selectId = firstId;
      if (selectId != null && _noteById(selectId) != null) select(selectId);
    }
    if (failed > 0) {
      _error = '有 $failed 篇笔记未能恢复,条目仍保留在回收站';
      notifyListeners();
    }
    return restored;
  }

  Future<bool> restoreTrashEntry(String entryId) async =>
      await restoreTrashEntries(<String>[entryId]) > 0;

  /// Permanently removes one trash entry.
  Future<bool> purgeTrash(String entryId) async {
    try {
      await _store.purgeTrash(entryId);
      return true;
    } catch (e) {
      _error = '永久删除失败:$e';
      notifyListeners();
      return false;
    }
  }

  /// Permanently empties the trash.
  Future<bool> emptyTrash() async {
    try {
      await _store.emptyTrash();
      return true;
    } catch (e) {
      _error = '清空回收站失败:$e';
      notifyListeners();
      return false;
    }
  }

  // ----------------------------------------------------------------- history

  Future<List<NoteVersion>> historyOf(Note note) async {
    try {
      return await _store.historyOf(note);
    } catch (e) {
      _error = '读取历史版本失败:$e';
      notifyListeners();
      return const <NoteVersion>[];
    }
  }

  Future<String?> readVersion(Note note, String versionId) =>
      _store.readVersion(note, versionId);

  /// Replaces [note]'s body with the given snapshot.
  ///
  /// The store snapshots what is on disk first, so the restore itself is
  /// reversible. The open editor is reloaded from the new body afterwards;
  /// identity, file name and folder stay exactly where they are.
  Future<bool> restoreVersion(Note note, String versionId) async {
    final bool open = _draft?.id == note.id || _selectedId == note.id;
    if (open && !await _flushDraftBefore('恢复历史版本')) return false;
    if (!open) await _writing;

    final Note target = _noteById(note.id) ?? note;
    final bool restored;
    try {
      restored = await _store.restoreVersion(target, versionId);
    } catch (e) {
      _error = '恢复历史版本失败:$e';
      notifyListeners();
      return false;
    }
    if (!restored) {
      _error = '恢复历史版本失败:该版本可能已被清理';
      notifyListeners();
      return false;
    }

    // Makes `refresh` re-read the open draft instead of treating it as dirty.
    if (open) _saveState = SaveState.idle;
    await refresh(keepSelection: true);
    notifyListeners();
    return true;
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

  /// Writes [body] into a note that is still empty, then saves at once.
  ///
  /// This is the write half of folder templates. Rendering happens elsewhere and
  /// can open prompts, so by the time the result arrives the user may have typed
  /// into the note, switched away or deleted it. Every one of those must win:
  /// the template is applied only when the note still exists and its body is
  /// untouched. An already-written body is never replaced.
  ///
  /// Returns whether the body was applied. A failed disk write still applies it
  /// in memory and reports through [error]; the user keeps an editor they can
  /// copy from rather than losing the rendered text too.
  Future<bool> applyBodyIfEmpty(String noteId, String body) async {
    final Note? current = _noteById(noteId);
    if (current == null || current.body.isNotEmpty) return false;

    if (_draft?.id == noteId) {
      if (_draftHasConflict || _draft!.body.isNotEmpty) return false;
      updateBody(body);
      await saveNow();
      return _noteById(noteId)?.body == body;
    }

    // Not on screen. A write of this note may already be queued (it is brand
    // new), and that earlier snapshot must land before this fuller one.
    await _writing;
    final Note? latest = _noteById(noteId);
    if (latest == null || latest.body.isNotEmpty) return false;
    final Note updated = latest.copyWith(body: body, updatedAt: DateTime.now());
    _replace(updated);
    notifyListeners();
    try {
      await _store.save(updated, previousPath: updated.relativePath);
      _baselines[updated.id] = updated;
      await _refreshStamp(updated.relativePath);
      return true;
    } catch (e) {
      _error = '保存失败:$e';
      notifyListeners();
      return false;
    }
  }

  /// [candidate] unless another note in the same folder already owns that file
  /// name, in which case ` 2`, ` 3` … is appended before `.md`.
  ///
  /// File names are compared case-insensitively because Windows and macOS file
  /// systems are: `周报.md` and `周报.MD` are the same file. Folders are scoped
  /// separately: `工作/周报.md` and `随手/周报.md` are two perfectly good notes.
  ///
  /// [among] checks against a freshly read disk list instead of the in-memory
  /// one; the save path needs that after a file appeared outside the app.
  String _freeName(
    String candidate, {
    String? exceptId,
    String? folderPath,
    Iterable<Note>? among,
  }) {
    final String folder = Note.normalizeFolderPath(
      folderPath ?? _activeFolder,
    );
    final Set<String> taken = <String>{
      for (final Note n in among ?? _notes)
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
    final Note? previous = _draft;
    // 正文以外的字段（标题/文件名/所在目录）会改变文件树上的那一行，
    // 这类编辑同样要推进结构版本号，否则树会停在旧标题上。
    final bool structureChanged =
        previous == null ||
        previous.title != next.title ||
        previous.fileName != next.fileName ||
        previous.folderPath != next.folderPath;
    _draft = next;
    _replace(next);
    _editRevision++;
    if (structureChanged) _bumpStructure();
    _saveState = SaveState.dirty;
    notifyListeners();
    // While a conflict is unresolved the note does not write itself: the next
    // autosave would answer the other program by silently overwriting it.
    if (!_draftHasConflict) _autosave.run(_persistDraft);
  }

  Future<void> saveNow() async {
    if (_draftHasConflict) return;
    _autosave.cancel();
    await _persistDraft();
  }

  /// The tail of the write chain, and how many writes are on it.
  Future<void> _writing = Future<void>.value();
  int _writesQueued = 0;

  /// Bumped as each write starts. [syncFromDisk] snapshots it so a disk read
  /// that raced with one of our own saves is discarded: the bytes it holds are
  /// older than what is already on disk, and applying them would put yesterday's
  /// prose back into the editor and turn the next keystroke into an overwrite.
  int _writeRevision = 0;

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
  /// a real overlap is queued, and the queued write carries the note *as it was
  /// when it was flushed*: switching tabs right after typing calls this with the
  /// old draft, and reading `_draft` again when the queue drains would save the
  /// newly opened note instead and drop the edit that was being flushed.
  Future<void> _persistDraft() {
    if (_draftHasConflict) return Future<void>.value();
    final Note? snapshot = _draft;
    if (snapshot == null) return Future<void>.value();
    final String? previous = _draftOriginalPath;
    final Future<void> task = _writesQueued == 0
        ? _writeDraft(snapshot, previous)
        : _writing.then((_) => _writeDraft(snapshot, previous));
    _writesQueued++;
    // A failed write must not poison the queue: [_writeDraft] already reports
    // the error through [error], so the chain itself always completes.
    _writing = task
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _writesQueued--);
    return task;
  }

  Future<void> _writeDraft(Note draft, String? flushedFrom) async {
    _writeRevision++;
    // The same id does not mean it is still on screen: the flush that queued
    // this write may have been followed by a tab switch. Only the note that is
    // still open may touch `_draft`, its path, its save indicator and the
    // rename retry — otherwise a late write of the previous note hijacks the
    // editor's path and the next save lands on the wrong file.
    final bool stillDraft = _draft?.id == draft.id;
    // A queued write can also be stale for the *same* note: a retried name or
    // words typed after it was flushed are newer and already have (or will
    // have) a write of their own. Writing this snapshot would put the older
    // title or body back on disk and into the tree.
    if (stillDraft &&
        (_draft!.body != draft.body ||
            _draft!.title != draft.title ||
            _draft!.folderPath != draft.folderPath)) {
      return;
    }
    // A still-open note may also have moved on since this snapshot was queued;
    // its newest path is the one the previous write left behind.
    final String? previous = stillDraft ? _draftOriginalPath : flushedFrom;
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
    if (stillDraft && note.fileName != draft.fileName) {
      _draft = note;
      _replace(note);
    }
    if (stillDraft) {
      _saveState = SaveState.saving;
      notifyListeners();
    }
    try {
      await _store.save(note, previousPath: previous);
      // The baseline and the stamp describe the file, so they stay true even
      // if the editor has moved to another note in the meantime.
      _baselines[note.id] = note;
      await _refreshStamp(note.relativePath, previous);
      // The tab may have switched while the write was in flight. Its path and
      // its save indicator belong to whoever is open *now*.
      if (_draft?.id != draft.id) return;
      _draftOriginalPath = note.relativePath;
      // While a newer edit waits for its own write, saying "已保存" would be a
      // lie and would let a focus sync treat the newer text as clean.
      _saveState = _matchesDraft(note) ? SaveState.saved : SaveState.dirty;
    } on NotePathTaken {
      if (_draft?.id != draft.id) {
        _error = '保存失败:文件名已被占用';
        return;
      }
      // Retrying mutates the draft, so it only belongs to the newest version;
      // an older snapshot leaves the clash to the queued write behind it.
      if (!_matchesDraft(note)) {
        _saveState = SaveState.dirty;
      } else {
        final bool retried = await _retryAfterPathTaken(note, previous);
        if (_draft?.id != draft.id) return;
        _saveState = retried ? SaveState.saved : SaveState.dirty;
      }
    } catch (e) {
      _error = '保存失败:$e';
      if (_draft?.id != draft.id) return;
      _saveState = SaveState.dirty;
    }
    if (_draft?.id != draft.id) return;
    notifyListeners();
    if (_saveState != SaveState.saved) return;
    _savedIndicatorTimer?.cancel();
    _savedIndicatorTimer = Timer(const Duration(seconds: 2), () {
      if (_saveState == SaveState.saved) {
        _saveState = SaveState.idle;
        notifyListeners();
      }
    });
  }

  bool _matchesDraft(Note note) {
    final Note? draft = _draft;
    return draft != null &&
        draft.id == note.id &&
        draft.body == note.body &&
        draft.title == note.title &&
        draft.fileName == note.fileName &&
        draft.folderPath == note.folderPath;
  }

  /// Handles the one clash only disk can reveal: a file appeared at the name
  /// this note wants (made in Explorer, by a sync client, or by another window).
  ///
  /// Re-reads the vault, picks the next free name and writes once more, so the
  /// other file survives and this note becomes ` 2` — the same rule the list
  /// shows when two notes in one folder share a title.
  Future<bool> _retryAfterPathTaken(Note note, String? previous) async {
    final List<Note> disk;
    try {
      disk = await _store.loadAll();
    } catch (e) {
      _error = '保存失败:$e';
      return false;
    }
    final String free = _freeName(
      note.fileName,
      exceptId: note.id,
      folderPath: note.folderPath,
      among: disk,
    );
    if (free.toLowerCase() == note.fileName.toLowerCase()) {
      _error = '保存失败:文件名已被占用';
      return false;
    }

    final Note renamed = note.copyWith(
      fileName: free,
      // A placeholder title (`未命名`) follows its file, as it does on
      // creation; a title the user typed stays exactly what they typed.
      title: note.title == Note.titleOfFileName(note.fileName)
          ? Note.titleOfFileName(free)
          : note.title,
    );
    _draft = renamed;
    _replace(renamed);
    try {
      await _store.save(renamed, previousPath: previous);
    } catch (e) {
      _error = '保存失败:$e';
      return false;
    }
    _draftOriginalPath = renamed.relativePath;
    _baselines[renamed.id] = renamed;
    // Now that our own file exists too, a reload shows both notes without
    // losing the draft.
    await refresh(keepSelection: true);
    return true;
  }

  /// Keeps the change-detection baseline in step with the app's own writes, so
  /// focusing the window does not re-read the vault just to learn that nothing
  /// changed.
  Future<void> _refreshStamp(String path, [String? previous]) async {
    if (previous != null &&
        previous.toLowerCase() != path.toLowerCase()) {
      _stamps.remove(previous);
    }
    try {
      final NoteFileStamp? stamp = await _store.stampOf(path);
      if (stamp == null) {
        _stamps.remove(path);
      } else {
        _stamps[path] = stamp;
      }
    } catch (_) {
      // A missing stamp only costs one extra read on the next focus.
      _stamps.remove(path);
    }
  }

  // -------------------------------------------------------------- vault sync

  /// Re-reads the vault when it changed outside the app.
  ///
  /// Called when the window regains focus. Returns a short message for the
  /// shell to show when a clean note was reloaded; null when nothing visible
  /// happened.
  Future<String?> syncFromDisk() async {
    if (_loading || _syncInFlight || _writesQueued > 0 || _conflict != null) {
      return null;
    }
    final List<NoteFileStamp>? stamps;
    try {
      stamps = await _store.stamps();
    } catch (_) {
      return null;
    }
    if (stamps == null || _sameStamps(stamps, _stamps)) return null;

    _syncInFlight = true;
    try {
      final String? draftId = _draft?.id;
      final int revision = _editRevision;
      final int writes = _writeRevision;
      final List<Note> disk;
      try {
        disk = await _store.loadAll();
      } catch (_) {
        return null;
      }
      // The user kept typing while the disk was being read, or a save started
      // and possibly finished. This round is stale; the next focus asks again.
      // The write count matters even after `_writesQueued` is back to zero: the
      // read may have caught the file *before* that save replaced it, and
      // applying those older bytes over a clean-looking draft would undo an edit
      // the disk already has.
      if (_editRevision != revision ||
          _writeRevision != writes ||
          _draft?.id != draftId ||
          _writesQueued > 0) {
        return null;
      }
      final ReconcileResult result = reconcileVault(
        current: _notes,
        disk: disk,
        draftId: draftId,
        draftDirty: _saveState == SaveState.dirty,
        draftBaseline: draftId == null ? null : _baselines[draftId],
      );
      // The stamps were taken before the read, so a file that changed during it
      // is simply looked at again on the next focus.
      _stamps = <String, NoteFileStamp>{
        for (final NoteFileStamp stamp in stamps) stamp.relativePath: stamp,
      };
      return await _applyReconciliation(result);
    } finally {
      _syncInFlight = false;
    }
  }

  bool _sameStamps(
    List<NoteFileStamp> disk,
    Map<String, NoteFileStamp> known,
  ) {
    if (disk.length != known.length) return false;
    for (final NoteFileStamp stamp in disk) {
      if (known[stamp.relativePath] != stamp) return false;
    }
    return true;
  }

  Future<String?> _applyReconciliation(ReconcileResult result) async {
    for (final ({Note note, String previousPath}) repair in result.repairs) {
      try {
        await _store.save(repair.note, previousPath: repair.previousPath);
      } catch (e) {
        _error = '修复重复笔记失败:$e';
      }
      _stamps.remove(repair.previousPath);
    }

    final Note? oldDraft = _draft;
    final String? oldSelected = _selectedId;
    final int oldIndex =
        oldSelected == null ? -1 : _openIds.indexOf(oldSelected);

    _notes = result.notes;
    try {
      _folders = await _store.listFolders();
    } catch (_) {
      // Keep the folder list we have; the notes are the important part.
    }
    if (_activeFolder.isNotEmpty && !_folderPaths().contains(_activeFolder)) {
      _activeFolder = '';
    }
    _openIds.removeWhere((String id) => _noteById(id) == null);
    _baselines.removeWhere(
      (String id, Note _) => !_notes.any((Note n) => n.id == id),
    );
    _resort();

    String? notice;
    switch (result.draftAction) {
      case DraftAction.untouched:
        break;

      case DraftAction.adoptDiskPath:
        final Note? draft = oldDraft;
        final Note? diskDraft = result.diskDraft;
        if (draft != null && diskDraft != null) {
          final Note adopted = draft.copyWith(
            folderPath: diskDraft.folderPath,
          );
          _draft = adopted;
          _replace(adopted);
          _draftOriginalPath = diskDraft.relativePath;
          _baselines[adopted.id] = diskDraft;
        }

      case DraftAction.reload:
        final Note? diskDraft = result.diskDraft;
        if (diskDraft != null) {
          final bool changed =
              oldDraft == null ||
              oldDraft.body != diskDraft.body ||
              oldDraft.title != diskDraft.title ||
              oldDraft.relativePath != diskDraft.relativePath;
          _draft = diskDraft;
          _draftOriginalPath = diskDraft.relativePath;
          _baselines[diskDraft.id] = diskDraft;
          _saveState = SaveState.idle;
          if (changed) notice = '已载入磁盘上的最新版本';
        }

      case DraftAction.conflict:
        final Note? draft = oldDraft;
        final Note? diskDraft = result.diskDraft;
        if (draft != null && diskDraft != null) {
          final Note adopted = draft.copyWith(
            folderPath: diskDraft.folderPath,
          );
          _draft = adopted;
          _replace(adopted);
          _draftOriginalPath = diskDraft.relativePath;
          _conflict = DraftConflict(
            noteId: adopted.id,
            kind: DraftConflictKind.modified,
            external: diskDraft,
          );
          _saveState = SaveState.dirty;
        }

      case DraftAction.orphan:
        final Note? draft = oldDraft;
        if (draft != null) {
          _conflict = DraftConflict(
            noteId: draft.id,
            kind: DraftConflictKind.deleted,
          );
          _saveState = SaveState.dirty;
        }

      case DraftAction.removed:
        _conflict = null;
        _selectNeighbor(oldIndex);
    }

    if (result.draftAction != DraftAction.removed &&
        _selectedId != null &&
        _noteById(_selectedId!) == null) {
      _selectNeighbor(oldIndex);
    }

    notifyListeners();
    return notice;
  }

  /// Puts the selection on the tab next to the one at [oldIndex], the way a
  /// browser does after closing a tab.
  void _selectNeighbor(int oldIndex) {
    if (_openIds.isNotEmpty) {
      _selectedId = _openIds[oldIndex.clamp(0, _openIds.length - 1)];
    } else if (_ordered.isNotEmpty) {
      _selectedId = _ordered.first.id;
      _rememberTab(_selectedId!);
    } else {
      _selectedId = null;
    }
    _autosave.cancel();
    _draft = selectedNote;
    _draftOriginalPath = _draft?.relativePath;
    _rememberBaseline(_draft);
    _saveState = SaveState.idle;
  }

  // --------------------------------------------------------------- conflicts

  /// Keep the local edits, writing them over the version on disk.
  Future<void> keepMine() async {
    final DraftConflict? conflict = _conflict;
    final Note? draft = _draft;
    if (conflict == null || draft == null || conflict.noteId != draft.id) {
      return;
    }
    if (conflict.isDeleted) {
      await saveConflictCopy();
      return;
    }
    // The external version is about to be overwritten; keep it in history so
    // "keep mine" is itself reversible.
    await _store.captureVersion(conflict.external!);
    _conflict = null;
    final Note toSave = draft.copyWith(updatedAt: DateTime.now());
    _draft = toSave;
    _replace(toSave);
    _saveState = SaveState.dirty;
    notifyListeners();
    await _persistDraft();
  }

  /// Drop the local edits and take the version on disk.
  Future<void> takeTheirs() async {
    final DraftConflict? conflict = _conflict;
    final Note? draft = _draft;
    if (conflict == null || draft == null || conflict.noteId != draft.id) {
      return;
    }
    if (conflict.isDeleted) {
      _discardDraft();
      return;
    }
    final Note external = conflict.external!;
    _conflict = null;
    _draft = external;
    _replace(external);
    _draftOriginalPath = external.relativePath;
    _baselines[external.id] = external;
    _saveState = SaveState.idle;
    _autosave.cancel();
    notifyListeners();
  }

  /// The file was deleted outside: keep the unsaved text, but under a free
  /// name, instead of resurrecting the path someone just cleared.
  Future<void> saveConflictCopy() async {
    final DraftConflict? conflict = _conflict;
    final Note? draft = _draft;
    if (conflict == null ||
        draft == null ||
        conflict.noteId != draft.id ||
        !conflict.isDeleted) {
      return;
    }
    try {
      final Note copy = await _store.writeNewMarkdown(
        draft.toMarkdown(),
        draft.fileName,
        folderPath: draft.folderPath,
      );
      _conflict = null;
      _baselines.remove(draft.id);
      _saveState = SaveState.idle;
      await refresh(keepSelection: false);
      select(copy.id);
    } catch (e) {
      _error = '另存失败:$e';
      notifyListeners();
    }
  }

  /// Throws away the open note without touching the disk. Used when the file is
  /// already gone, so there is nothing to delete.
  void _discardDraft() {
    final Note? draft = _draft;
    if (draft == null) return;
    final int index = _openIds.indexOf(draft.id);
    _notes = _notes.where((Note n) => n.id != draft.id).toList();
    _ordered = _ordered.where((Note n) => n.id != draft.id).toList();
    _bumpStructure();
    _openIds.remove(draft.id);
    _baselines.remove(draft.id);
    _conflict = null;
    _saveState = SaveState.idle;
    _autosave.cancel();
    _selectNeighbor(index);
    notifyListeners();
  }

  // ------------------------------------------------------------------- assets

  /// Writes a pasted PNG beside the open note and returns the reference to put
  /// in Markdown (`assets/image_….png`). Null where images cannot be stored.
  Future<String?> saveAsset(Uint8List pngBytes) async {
    final Note? note = _draft ?? selectedNote;
    if (note == null) return null;
    return _store.saveAsset(
      note.folderPath,
      _imageAssetName(DateTime.now()),
      pngBytes,
    );
  }

  /// Absolute path of an image referenced by the open note, for rendering.
  String? assetPathFor(String source) {
    final Note? note = _draft ?? selectedNote;
    if (note == null) return null;
    return _store.assetPath(note.folderPath, source);
  }

  static String _imageAssetName(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'image_${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.png';
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

/// The file name at the end of [path], whichever separator the platform used.
///
/// A path dragged in from Explorer is `…\笔记.md` and one from Finder is
/// `…/笔记.md`; the vault only ever wants the last segment.
String _fileNameOfPath(String path) {
  final int cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut < 0 ? path : path.substring(cut + 1);
}
