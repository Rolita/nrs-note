import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/app_enums.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/notes_controller.dart';

/// An in-memory vault. The controller only ever talks to [NoteStore], so a fake
/// is enough to exercise the whole "follow a link" path without touching disk.
/// It extends rather than implements, so the `reveal` / `importMarkdown`
/// defaults come along and the fake stays about the four methods that matter.
class _MemoryStore extends NoteStore {
  _MemoryStore([List<Note>? seed]) : notes = <Note>[...?seed] {
    for (final Note note in notes) {
      _touch(note);
    }
  }

  final List<Note> notes;
  final Map<String, NoteFileStamp> _stamps = <String, NoteFileStamp>{};
  int _clock = 0;

  /// Trash entries, newest first, with the bytes needed to put them back.
  final List<_MemoryTrashEntry> trash = <_MemoryTrashEntry>[];

  /// Deletes of these ids fail, as a locked file would.
  final Set<String> failDeleteIds = <String>{};

  /// Makes the next save fail, as a read-only vault would.
  bool failSave = false;

  /// Directories that exist even when empty, as the real stores report them.
  final Set<String> folders = <String>{};

  /// Files below a folder that the note trash cannot restore.
  final Set<String> foreignFiles = <String>{};

  /// Every content string handed to [captureVersion], oldest first.
  final List<({String id, String raw})> captured =
      <({String id, String raw})>[];

  /// Seeded history, per note id.
  final Map<String, List<NoteVersion>> versions = <String, List<NoteVersion>>{};
  final Map<String, Map<String, String>> _versionRaw =
      <String, Map<String, String>>{};
  int _versionSeq = 0;

  void seedVersion(Note note, String body) {
    final DateTime at = DateTime(
      2026,
      1,
      1,
    ).add(Duration(minutes: ++_versionSeq));
    final String id = '${at.microsecondsSinceEpoch}';
    final String raw = note.copyWith(body: body, updatedAt: at).toMarkdown();
    versions
        .putIfAbsent(note.id, () => <NoteVersion>[])
        .add(NoteVersion(id: id, capturedAt: at, size: raw.length));
    _versionRaw.putIfAbsent(note.id, () => <String, String>{})[id] = raw;
  }

  /// Files the fake "desktop" can hand over, keyed by path. Anything not in
  /// here reads as a file that is gone.
  final Map<String, String> external = <String, String>{};

  /// 假的库根目录。null = 没有本地路径（和 web store 一样）。
  String? vault;

  @override
  String? get vaultPath => vault;

  @override
  Future<String?> readMarkdownFile(String path) async => external[path];

  @override
  bool get supportsTrash => true;

  @override
  bool get supportsHistory => true;

  void _touch(Note note) {
    _stamps[note.relativePath] = NoteFileStamp(
      relativePath: note.relativePath,
      modifiedAt: DateTime(2026, 1, 1).add(Duration(seconds: ++_clock)),
      size: note.toMarkdown().length,
    );
  }

  /// A save made by another program, before the controller notices.
  void writeExternally(Note next) {
    final int index = notes.indexWhere((Note n) => n.id == next.id);
    if (index >= 0) {
      _stamps.remove(notes[index].relativePath);
      notes.removeAt(index);
    }
    notes.insert(0, next);
    _touch(next);
  }

  void deleteExternally(Note note) {
    notes.removeWhere((Note n) => n.id == note.id);
    _stamps.remove(note.relativePath);
  }

  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<Note>> loadAll() async => List<Note>.of(notes);

  @override
  Future<List<NoteFileStamp>?> stamps() async => _stamps.values.toList();

  @override
  Future<NoteFileStamp?> stampOf(String relativePath) async =>
      _stamps[relativePath.replaceAll('\\', '/')];

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    if (failSave) throw StateError('disk is read-only');
    notes.removeWhere(
      (Note n) =>
          n.id == note.id ||
          (previousPath != null &&
              n.relativePath.toLowerCase() ==
                  previousPath.replaceAll('\\', '/').toLowerCase()),
    );
    if (previousPath != null) {
      _stamps.remove(previousPath.replaceAll('\\', '/'));
    }
    notes.insert(0, note);
    _touch(note);
  }

  @override
  Future<List<String>> listFolders() async => folders.toList()..sort();

  @override
  Future<String> createFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return '';
    String current = '';
    for (final String part in folder.split('/')) {
      current = current.isEmpty ? part : '$current/$part';
      folders.add(current);
    }
    return folder;
  }

  @override
  Future<bool> folderHoldsOnlyNotes(
    String folderPath,
    Set<String> notePaths,
  ) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    final String prefix = '$folder/';
    final bool exists =
        folders.contains(folder) ||
        notes.any(
          (Note n) => n.folderPath == folder || n.folderPath.startsWith(prefix),
        );
    if (!exists) return false;
    if (foreignFiles.any((String f) => f.startsWith(prefix))) return false;
    for (final Note note in notes) {
      if (!note.relativePath.startsWith(prefix)) continue;
      if (!notePaths.contains(note.relativePath)) return false;
    }
    return true;
  }

  @override
  Future<bool> deleteFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    final String prefix = '$folder/';
    if (notes.any((Note n) => n.relativePath.startsWith(prefix))) return false;
    if (foreignFiles.any((String f) => f.startsWith(prefix))) return false;
    folders.removeWhere(
      (String path) => path == folder || path.startsWith(prefix),
    );
    return true;
  }

  @override
  Future<TrashEntry?> delete(Note note) async {
    if (failDeleteIds.contains(note.id)) {
      throw StateError('file is locked');
    }
    final String raw = note.toMarkdown();
    final TrashEntry entry = TrashEntry(
      id: 'trash-${trash.length + 1}',
      originalPath: note.relativePath,
      title: note.title,
      deletedAt: DateTime(2026, 1, 2),
      size: raw.length,
    );
    trash.insert(
      0,
      _MemoryTrashEntry(
        entry: entry,
        raw: raw,
        fileName: note.fileName,
        folderPath: note.folderPath,
      ),
    );
    notes.removeWhere((Note n) => n.id == note.id);
    _stamps.remove(note.relativePath);
    return entry;
  }

  @override
  Future<List<TrashEntry>> listTrash() async => <TrashEntry>[
    for (final _MemoryTrashEntry e in trash) e.entry,
  ];

  @override
  Future<Note?> restoreTrash(String entryId) async {
    final int index = trash.indexWhere(
      (_MemoryTrashEntry e) => e.entry.id == entryId,
    );
    if (index < 0) return null;
    final _MemoryTrashEntry record = trash.removeAt(index);
    return writeNewMarkdown(
      record.raw,
      record.fileName,
      folderPath: record.folderPath,
    );
  }

  @override
  Future<void> purgeTrash(String entryId) async {
    trash.removeWhere((_MemoryTrashEntry e) => e.entry.id == entryId);
  }

  @override
  Future<void> emptyTrash() async => trash.clear();

  @override
  Future<List<NoteVersion>> historyOf(Note note) async {
    final List<NoteVersion> found = <NoteVersion>[...?versions[note.id]]
      ..sort(
        (NoteVersion a, NoteVersion b) => b.capturedAt.compareTo(a.capturedAt),
      );
    return found;
  }

  @override
  Future<String?> readVersion(Note note, String versionId) async =>
      _versionRaw[note.id]?[versionId];

  @override
  Future<bool> restoreVersion(Note note, String versionId) async {
    final String? raw = _versionRaw[note.id]?[versionId];
    if (raw == null) return false;
    final Note live = notes.firstWhere(
      (Note n) => n.id == note.id,
      orElse: () => note,
    );
    await captureVersion(live);
    await save(
      live.copyWith(
        body: Note.splitFrontMatter(raw).body,
        updatedAt: DateTime(2026, 2, 1),
      ),
      previousPath: live.relativePath,
    );
    return true;
  }

  @override
  Future<void> captureVersion(Note note) async {
    final Note live = notes.firstWhere(
      (Note n) => n.id == note.id,
      orElse: () => note,
    );
    captured.add((id: note.id, raw: live.toMarkdown()));
  }

  @override
  Future<Note> writeNewMarkdown(
    String raw,
    String fileName, {
    String folderPath = '',
  }) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    final String base = fileName.split(RegExp(r'[\\/]')).last;
    final String withExtension = base.toLowerCase().endsWith('.md')
        ? base
        : '$base.md';
    final Note parsed = Note.fromMarkdown(
      raw,
      withExtension,
      DateTime.now(),
      folderPath: folder,
    );
    final Note note = parsed.copyWith(
      fileName: _uniqueName(folder, withExtension),
    );
    await save(note);
    return note;
  }

  String _uniqueName(String folder, String wanted) {
    final Set<String> taken = <String>{
      for (final Note n in notes)
        if (n.folderPath.toLowerCase() == folder.toLowerCase())
          n.fileName.toLowerCase(),
    };
    if (!taken.contains(wanted.toLowerCase())) return wanted;
    final String stem = wanted.replaceAll(
      RegExp(r'\.md$', caseSensitive: false),
      '',
    );
    for (int i = 2; i < 1000; i++) {
      final String next = '$stem $i.md';
      if (!taken.contains(next.toLowerCase())) return next;
    }
    return wanted;
  }
}

/// One trashed note: the public receipt, plus the bytes that put it back.
class _MemoryTrashEntry {
  const _MemoryTrashEntry({
    required this.entry,
    required this.raw,
    required this.fileName,
    required this.folderPath,
  });

  final TrashEntry entry;
  final String raw;
  final String fileName;
  final String folderPath;
}

Note _note(String title, {String body = '', String folderPath = ''}) => Note(
  id: Note.newId(),
  title: title,
  body: body,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  folderPath: folderPath,
);

Future<NotesController> _open(_MemoryStore store) async {
  final NotesController notes = NotesController(store: store);
  addTearDown(notes.dispose);
  await notes.bootstrap();
  return notes;
}

void main() {
  test('a link to a note that exists just opens it', () async {
    final Note existing = _note('写作计划', body: '正文');
    final _MemoryStore store = _MemoryStore(<Note>[_note('另一篇'), existing]);
    final NotesController notes = await _open(store);

    final ({Note note, bool created}) opened = notes.openOrCreateByTitle(
      '写作计划',
    );

    expect(opened.created, isFalse);
    expect(opened.note.id, existing.id);
    expect(notes.selectedId, existing.id);
    expect(
      notes.allNotes.length,
      2,
      reason: 'nothing should have been written',
    );
  });

  test('a link to a note that does not exist writes it', () async {
    final _MemoryStore store = _MemoryStore(<Note>[_note('另一篇')]);
    final NotesController notes = await _open(store);

    final ({Note note, bool created}) opened = notes.openOrCreateByTitle('新想法');

    expect(opened.created, isTrue);
    expect(opened.note.title, '新想法');
    expect(opened.note.body, isEmpty, reason: 'a new link target starts blank');
    // And you are standing in it, so the next keystroke is the note.
    expect(notes.selectedId, opened.note.id);
    expect(notes.draft?.title, '新想法');
    expect(notes.allNotes.length, 2);
    expect(
      store.notes.any((Note n) => n.title == '新想法'),
      isTrue,
      reason: 'the new note never reached the store',
    );
  });

  test('matching a title ignores case and surrounding space', () async {
    final Note existing = _note('Weekly Plan');
    final _MemoryStore store = _MemoryStore(<Note>[existing]);
    final NotesController notes = await _open(store);

    final ({Note note, bool created}) opened = notes.openOrCreateByTitle(
      '  weekly PLAN  ',
    );

    expect(opened.created, isFalse);
    expect(opened.note.id, existing.id);
    expect(
      notes.allNotes.length,
      1,
      reason: 'a near-miss must not fork the note',
    );
  });

  test('the created note is titled with the link target, trimmed', () async {
    final _MemoryStore store = _MemoryStore();
    final NotesController notes = await _open(store);

    final ({Note note, bool created}) opened = notes.openOrCreateByTitle(
      '  读书笔记  ',
    );

    expect(opened.created, isTrue);
    expect(opened.note.title, '读书笔记');
    expect(opened.note.fileName, '读书笔记.md');
  });

  test('a new note is 未命名.md, and the second one picks a free name', () async {
    final NotesController notes = await _open(_MemoryStore());

    final Note first = notes.createNote();
    // A note always has a name, because the file always has one.
    expect(first.title, '未命名');
    expect(first.fileName, '未命名.md');

    final Note second = notes.createNote();
    expect(second.fileName, '未命名 2.md', reason: '两个新笔记不能占同一个文件');
    expect(first.fileName, '未命名.md', reason: '第一篇的名字不能被抢走');
  });

  test('the second new note is titled 未命名 2, like its file', () async {
    final NotesController notes = await _open(_MemoryStore());

    expect(notes.createNote().title, '未命名');
    final Note second = notes.createNote();
    expect(second.fileName, '未命名 2.md');
    expect(second.title, '未命名 2', reason: '编辑器里选中的占位名必须和磁盘上的文件名一致');
  });

  test('renameNote moves the file and leaves no orphan behind', () async {
    final _MemoryStore store = _MemoryStore(<Note>[_note('写作计划')]);
    final NotesController notes = await _open(store);
    final Note original = notes.allNotes.single;

    await notes.renameNote(original, '新的计划');

    expect(notes.allNotes.single.title, '新的计划');
    expect(notes.allNotes.single.fileName, '新的计划.md');
    expect(
      store.notes.single.relativePath,
      '新的计划.md',
      reason: '旧文件要被删掉,而不是留在库里当孤儿',
    );
  });

  test('moveNotes never lets two 未命名.md collide in one folder', () async {
    final _MemoryStore store = _MemoryStore();
    final NotesController notes = await _open(store);
    final Note first = notes.createNote(folderPath: '甲');
    final Note second = notes.createNote(folderPath: '乙');
    expect(first.fileName, '未命名.md');
    expect(second.fileName, '未命名.md', reason: '不同文件夹可以各有一篇未命名');

    await notes.moveNotes(<Note>[first, second], '合并');

    final List<String> names =
        notes.allNotes
            .where((Note n) => n.folderPath == '合并')
            .map((Note n) => n.fileName)
            .toList()
          ..sort();
    expect(names, <String>['未命名 2.md', '未命名.md']);
    expect(
      store.notes.where((Note n) => n.folderPath == '合并').length,
      2,
      reason: '两篇都要真的落进新文件夹',
    );
  });

  test('retitling renames the file, and only the file it owns', () async {
    final Note note = _note('旧标题', body: '正文');
    final _MemoryStore store = _MemoryStore(<Note>[note]);
    final NotesController notes = await _open(store);
    expect(note.fileName, '旧标题.md');

    notes.updateTitle('新标题');
    expect(notes.draft?.title, '新标题');
    expect(notes.draft?.fileName, '新标题.md');
    await notes.saveNow();

    expect(
      store.notes.where((Note n) => n.fileName == '旧标题.md'),
      isEmpty,
      reason: '改名后旧文件必须消失,否则库里会多出一篇幽灵笔记',
    );
    expect(store.notes.where((Note n) => n.fileName == '新标题.md'), hasLength(1));
  });

  test('a title clash never writes over the other note', () async {
    final Note first = _note('周报');
    final Note second = _note('月报');
    final _MemoryStore store = _MemoryStore(<Note>[first, second]);
    final NotesController notes = await _open(store);

    notes.select(second.id);
    notes.updateTitle('周报');
    expect(notes.draft?.fileName, '周报 2.md', reason: '撞名要加序号,不能覆盖');
    await notes.saveNow();

    expect(
      store.notes.where((Note n) => n.fileName == '周报.md'),
      hasLength(1),
      reason: '原来那篇「周报」必须还在',
    );
    expect(store.notes, hasLength(2), reason: '两篇都得在,一篇都没被吃掉');
  });

  test('every edit is written without anyone pressing Ctrl+S', () async {
    final _MemoryStore store = _MemoryStore(<Note>[_note('随笔', body: '第一行')]);
    final NotesController notes = await _open(store);

    notes.updateBody('第一行改过');
    expect(notes.saveState, SaveState.dirty, reason: '先记账,再落盘');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(
      store.notes.single.body,
      '第一行改过',
      reason: '输入完就该自己写下去,不该等着谁按 Ctrl+S',
    );
    expect(notes.saveState, SaveState.saved);
  });

  test('Ctrl+S cuts the wait and writes at once', () async {
    final _MemoryStore store = _MemoryStore(<Note>[_note('随笔', body: '第一行')]);
    final NotesController notes = await _open(store);

    notes.updateBody('不等那 300 毫秒');
    await notes.saveNow();

    expect(store.notes.single.body, '不等那 300 毫秒');
    expect(notes.saveState, SaveState.saved);
  });

  test('a burst of keystrokes is one write, not one per character', () async {
    // Auto-save has to be invisible *and* cheap: the debounce collapses a burst
    // into the trailing edit, so a 30-character sentence is not 30 file writes.
    int writes = 0;
    final _CountingStore store = _CountingStore(() => writes++);
    final NotesController notes = NotesController(store: store);
    addTearDown(notes.dispose);
    await notes.bootstrap();

    for (int i = 1; i <= 10; i++) {
      notes.updateBody('字' * i);
    }
    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(writes, 1, reason: '连续输入只该落一次盘');
    expect(store.notes.single.body, '字' * 10);
  });

  test('two writes in flight still leave one file behind', () async {
    // Each write deletes the name it thinks it replaced. Overlap them and an
    // earlier write lands after a later one, leaving both files — one note on
    // screen, two on disk at the next start.
    final _SlowStore store = _SlowStore();
    final NotesController notes = NotesController(store: store);
    addTearDown(notes.dispose);
    await notes.bootstrap();

    notes.updateTitle('第一个名字');
    final Future<void> first = notes.saveNow();
    notes.updateTitle('第二个名字');
    final Future<void> second = notes.saveNow();
    await Future.wait(<Future<void>>[first, second]);

    expect(store.maxInFlight, 1, reason: '写盘必须排队,不能同时进行');
    expect(store.notes, hasLength(1), reason: '不能留下幽灵文件');
    expect(store.notes.single.fileName, '第二个名字.md');
  });

  test(
    'switching notes while a write is in flight keeps the last edits',
    () async {
      // The queue used to read `_draft` again when it drained, so a flush that
      // waited behind a slow write saved the *newly opened* note and dropped the
      // words typed in the old one.
      final _GatedStore store = _GatedStore();
      final NotesController notes = NotesController(store: store);
      addTearDown(notes.dispose);
      await notes.bootstrap();
      final Note first = notes.allNotes.firstWhere(
        (Note n) => n.title == '第一篇',
      );
      final Note second = notes.allNotes.firstWhere(
        (Note n) => n.title == '第二篇',
      );
      notes.select(first.id);

      store.blockNextSave();
      notes.updateBody('改过一次');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await store.saveStarted;

      notes.updateBody('切走前的最后一版');
      notes.select(second.id);
      store.release();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        store.notes.firstWhere((Note n) => n.id == first.id).body,
        '切走前的最后一版',
        reason: '排队的那次写盘必须带着切走前的快照,而不是新打开的草稿',
      );
      expect(notes.draft?.id, second.id);
      expect(
        store.notes.firstWhere((Note n) => n.id == second.id).body,
        '另一篇',
        reason: '切过去的那篇不能被上一篇的排队写盘顺手覆盖',
      );

      // The late write must not leave its own path on the freshly opened note:
      // the next save of that note would then delete the previous one's file.
      notes.updateBody('第二篇的新正文');
      await notes.saveNow();

      expect(store.notes, hasLength(2));
      expect(
        store.notes.firstWhere((Note n) => n.id == first.id).body,
        '切走前的最后一版',
      );
      expect(
        store.notes.firstWhere((Note n) => n.id == second.id).body,
        '第二篇的新正文',
      );
    },
  );

  test(
    'renaming a row older than the last keystroke keeps the new words',
    () async {
      // The tree redraws on structure changes only, so its row can predate the
      // typing. Writing that stale copy during a rename rolls the file back.
      final Note note = _note('甲', body: '正文');
      final _MemoryStore store = _MemoryStore(<Note>[note]);
      final NotesController notes = await _open(store);
      final Note stale = notes.draft!;

      notes.updateBody('刚敲的正文');
      await notes.saveNow();
      await notes.renameNote(stale, '乙');

      final Note stored = store.notes.single;
      expect(stored.title, '乙');
      expect(stored.fileName, '乙.md');
      expect(stored.body, '刚敲的正文', reason: '重命名不能把旧正文写回去');
    },
  );

  test(
    'dragging a row older than the last keystroke keeps the new words',
    () async {
      final Note note = _note('甲', body: '正文');
      final _MemoryStore store = _MemoryStore(<Note>[note]);
      final NotesController notes = await _open(store);
      final Note stale = notes.draft!;

      notes.updateBody('刚敲的正文');
      await notes.saveNow();
      await notes.moveNotes(<Note>[stale], '归档');

      final Note stored = store.notes.single;
      expect(stored.folderPath, '归档');
      expect(stored.relativePath, '归档/甲.md');
      expect(stored.body, '刚敲的正文', reason: '移动不能把旧正文写回去');
    },
  );

  test(
    'a focus sync that raced with a save never puts the older body back',
    () async {
      // The sync read the file before our save replaced it. Applying that older
      // snapshot on top of an already-saved draft is a silent undo of real work.
      final _RacingStore store = _RacingStore();
      final NotesController notes = await _open(store);

      notes.updateBody('刚敲的新正文');
      store.arm();
      store.touchStamp();
      final Future<String?> sync = notes.syncFromDisk();
      await store.readStarted;

      await notes.saveNow();
      store.finishRead();
      await sync;

      expect(notes.draft?.body, '刚敲的新正文', reason: '读盘早于保存完成时,那次读到的旧字节必须作废');
      expect(notes.saveState, SaveState.saved);
      expect(store.notes.single.body, '刚敲的新正文');
    },
  );

  test('all six sort modes order the vault as their labels promise', () async {
    final Note alpha = Note(
      id: 'alpha',
      title: 'Alpha',
      body: '',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 2, 1),
    );
    final Note beta = Note(
      id: 'beta',
      title: 'Beta',
      body: '',
      createdAt: DateTime(2026, 2, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final NotesController notes = await _open(
      _MemoryStore(<Note>[alpha, beta]),
    );
    List<String> titles() => notes.allNotes.map((Note n) => n.title).toList();

    notes.sortMode = SortMode.titleAsc;
    expect(titles(), <String>['Alpha', 'Beta']);
    notes.sortMode = SortMode.titleDesc;
    expect(titles(), <String>['Beta', 'Alpha']);
    notes.sortMode = SortMode.updatedDesc;
    expect(titles(), <String>['Alpha', 'Beta']);
    notes.sortMode = SortMode.updatedAsc;
    expect(titles(), <String>['Beta', 'Alpha']);
    notes.sortMode = SortMode.createdDesc;
    expect(titles(), <String>['Beta', 'Alpha']);
    notes.sortMode = SortMode.createdAsc;
    expect(titles(), <String>['Alpha', 'Beta']);
  });

  test('a search sweeps the whole vault, folders included', () async {
    final Note inFolder = Note(
      id: 'b',
      title: 'nrs开发进度',
      body: '# nrs开发进度\n',
      folderPath: '项目',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    final NotesController notes = await _open(
      _MemoryStore(<Note>[_note('欢迎使用 NRS'), inFolder, _note('NRS 快速入门')]),
    );

    notes.setQuery('nrs');
    expect(notes.visibleNotes, hasLength(3), reason: '搜索要扫全库，不能只看顶层或当前文件夹');
    expect(notes.visibleNotes.map((Note n) => n.title), contains('nrs开发进度'));
  });

  test(
    'clearing the query drops the results, and any tag filter with it',
    () async {
      final NotesController notes = await _open(
        _MemoryStore(<Note>[_note('NRS 快速入门'), _note('闲话', body: '# 杂')]),
      );

      notes.setQuery('nrs');
      expect(notes.visibleNotes, hasLength(1));

      notes.setQuery('');
      expect(notes.isFiltered, isFalse);
      expect(notes.visibleNotes, hasLength(2), reason: '清空后回到完整列表');
    },
  );

  test(
    'typing a query lets go of the tag filter, so search is vault-wide',
    () async {
      final NotesController notes = await _open(
        _MemoryStore(<Note>[
          _note('NRS 快速入门', body: '正文 #入门\n'),
          _note('nrs开发进度'),
          _note('闲话'),
        ]),
      );

      notes.toggleTag('入门');
      expect(notes.visibleNotes, hasLength(1), reason: '先只看这个标签');

      notes.setQuery('nrs');
      expect(notes.activeTag, isNull, reason: '一开始打字就不再受标签限制');
      expect(notes.visibleNotes, hasLength(2), reason: '要搜到全库里所有 nrs');

      notes.setQuery('');
      expect(notes.isFiltered, isFalse, reason: '清空后不该留下上一轮的结果');
    },
  );

  test(
    'case-insensitive hits read from the folded copy, casing intact',
    () async {
      final NotesController notes = await _open(
        _MemoryStore(<Note>[
          _note('Plan', body: '第一行\nSee the NRS Plan here\n最后一行\n'),
        ]),
      );

      notes.setQuery('nrs plan');
      final List<SearchHit> hits = notes.searchHits;
      expect(hits, hasLength(1));

      final SearchSnippet snippet = hits.single.snippets.single;
      expect(snippet.text, 'See the NRS Plan here', reason: '摘要取原正文的大小写');
      expect(
        snippet.text.substring(snippet.matchStart, snippet.matchEnd),
        'NRS Plan',
        reason: '偏移来自折叠副本，但落在原正文的同一位置',
      );
    },
  );

  test(
    'body edits leave the structure revision alone, tree edits move it',
    () async {
      final Note existing = _note('计划', body: '正文');
      final NotesController notes = await _open(_MemoryStore(<Note>[existing]));
      final int start = notes.structureRevision;

      notes.select(existing.id);
      notes.updateBody('正文改');
      expect(notes.structureRevision, start, reason: '正文输入不应该重建文件树');

      notes.updateTitle('计划改');
      expect(
        notes.structureRevision,
        greaterThan(start),
        reason: '标题就是文件名，树上的那一行必须更新',
      );

      final int afterTitle = notes.structureRevision;
      final Note created = notes.createNote(title: '新笔记');
      expect(notes.structureRevision, greaterThan(afterTitle));

      final int afterCreate = notes.structureRevision;
      await notes.deleteNotes(<Note>[created]);
      expect(notes.structureRevision, greaterThan(afterCreate));

      final int afterDelete = notes.structureRevision;
      notes.sortMode = SortMode.updatedAsc;
      expect(
        notes.structureRevision,
        greaterThan(afterDelete),
        reason: '排序变化也要重排',
      );
    },
  );

  test('names are scoped to their folder, so 未命名.md can repeat', () async {
    final NotesController notes = await _open(_MemoryStore());

    notes.setActiveFolder('工作');
    final Note work = notes.createNote();
    notes.setActiveFolder('生活');
    final Note life = notes.createNote();
    notes.setActiveFolder('工作');
    final Note workAgain = notes.createNote();

    expect(work.fileName, '未命名.md');
    expect(life.fileName, '未命名.md', reason: '不同文件夹可以各有一篇未命名');
    expect(workAgain.fileName, '未命名 2.md', reason: '同一个文件夹内仍然要避让');
    expect(notes.notesInFolder('工作'), hasLength(2));
    expect(notes.notesInFolder('生活'), hasLength(1));
  });

  test('a new folder nests under the active folder', () async {
    final NotesController notes = await _open(_MemoryStore());

    final String? work = await notes.createFolder('工作');
    expect(work, '工作');
    notes.setActiveFolder(work!);

    final String? weekly = await notes.createFolder('周报');
    expect(weekly, '工作/周报');
    expect(notes.activeFolder, '工作/周报');
    expect(notes.childFoldersOf(''), contains('工作'));
    expect(notes.childFoldersOf('工作'), contains('工作/周报'));
  });

  test('a file that appeared on disk turns the new note into 未命名 2', () async {
    final _CollidingStore store = _CollidingStore();
    final NotesController notes = await _open(store);

    final Note created = notes.createNote();
    expect(created.fileName, '未命名.md');
    await notes.saveNow();

    expect(notes.draft?.fileName, '未命名 2.md');
    expect(notes.draft?.title, '未命名 2', reason: '占位名要跟着文件名走');
    final Note external = store.notes.firstWhere(
      (Note n) => n.fileName == '未命名.md',
    );
    expect(external.body, '外部写的正文', reason: '外部文件必须原样保留');
    expect(
      store.notes.where((Note n) => n.fileName == '未命名 2.md'),
      hasLength(1),
    );
    expect(
      notes.allNotes.map((Note n) => n.fileName),
      containsAll(<String>['未命名.md', '未命名 2.md']),
      reason: '重试之后,两篇笔记都要出现在列表里',
    );
  });

  test('focusing the window reloads a clean note changed outside', () async {
    final Note original = _note('随笔', body: '第一行');
    final _MemoryStore store = _MemoryStore(<Note>[original]);
    final NotesController notes = await _open(store);

    store.writeExternally(original.copyWith(body: '外部改过'));
    final String? notice = await notes.syncFromDisk();

    expect(notice, isNotNull);
    expect(notes.draft?.body, '外部改过');
    expect(notes.saveState, SaveState.idle);
  });

  test(
    'an external edit while typing opens a conflict and stops autosave',
    () async {
      final Note original = _note('随笔', body: '第一行');
      final _MemoryStore store = _MemoryStore(<Note>[original]);
      final NotesController notes = await _open(store);

      notes.updateBody('本地改过');
      store.writeExternally(original.copyWith(body: '外部改过'));
      await notes.syncFromDisk();

      expect(notes.conflict?.kind, DraftConflictKind.modified);
      expect(notes.draft?.body, '本地改过', reason: '冲突不能吞掉本地输入');

      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(store.notes.single.body, '外部改过', reason: '冲突未解决前,自动保存必须停下');

      await notes.keepMine();
      expect(notes.conflict, isNull);
      expect(store.notes.single.body, '本地改过');
      expect(notes.saveState, SaveState.saved);
    },
  );

  test('taking the disk version drops the local edits', () async {
    final Note original = _note('随笔', body: '第一行');
    final _MemoryStore store = _MemoryStore(<Note>[original]);
    final NotesController notes = await _open(store);

    notes.updateBody('本地改过');
    store.writeExternally(original.copyWith(body: '外部改过'));
    await notes.syncFromDisk();
    await notes.takeTheirs();

    expect(notes.conflict, isNull);
    expect(notes.draft?.body, '外部改过');
    expect(store.notes.single.body, '外部改过');
  });

  test(
    'a note deleted outside keeps the draft as a copy, not a loss',
    () async {
      final Note original = _note('随笔', body: '第一行');
      final _MemoryStore store = _MemoryStore(<Note>[original]);
      final NotesController notes = await _open(store);

      notes.updateBody('本地改过');
      store.deleteExternally(original);
      await notes.syncFromDisk();

      expect(notes.conflict?.isDeleted, isTrue);
      expect(notes.allNotes, hasLength(1), reason: '文件没了,但没保存的文字不能跟着消失');

      await notes.saveConflictCopy();
      expect(notes.conflict, isNull);
      expect(store.notes, hasLength(1));
      expect(store.notes.single.body, '本地改过');
    },
  );

  test('a file moved outside is followed, and the edits are kept', () async {
    final Note original = _note('随笔', body: '第一行');
    final _MemoryStore store = _MemoryStore(<Note>[original]);
    final NotesController notes = await _open(store);

    notes.updateBody('本地改过');
    store.writeExternally(original.copyWith(folderPath: '工作'));
    await notes.syncFromDisk();

    expect(notes.conflict, isNull, reason: '只是挪了位置,不是内容冲突');
    expect(notes.draft?.body, '本地改过');
    expect(notes.draft?.folderPath, '工作');

    await notes.saveNow();
    expect(store.notes.single.relativePath, '工作/随笔.md');
    expect(store.notes.single.body, '本地改过');
  });

  test('a clean note deleted outside closes its tab', () async {
    final Note original = _note('随笔');
    final _MemoryStore store = _MemoryStore(<Note>[original]);
    final NotesController notes = await _open(store);

    store.deleteExternally(original);
    await notes.syncFromDisk();

    expect(notes.allNotes, isEmpty);
    expect(notes.draft, isNull);
    expect(notes.conflict, isNull);
  });

  group('回收站', () {
    test(
      'deleting the open note puts the unsaved edits in the trash',
      () async {
        final Note note = _note('随笔', body: '第一行');
        final _MemoryStore store = _MemoryStore(<Note>[note]);
        final NotesController notes = await _open(store);

        notes.updateBody('本地改过');
        final DeleteOutcome outcome = await notes.deleteNotes(<Note>[note]);

        expect(outcome.deleted, 1);
        expect(outcome.failed, 0);
        expect(outcome.receipts, hasLength(1));
        expect(store.notes, isEmpty);
        expect(
          store.trash.single.raw,
          contains('本地改过'),
          reason: '回收站里必须是删除前一秒的正文',
        );
        expect(notes.draft, isNull);
      },
    );

    test('a delete that cannot save the open draft is cancelled', () async {
      final Note note = _note('随笔', body: '第一行');
      final _MemoryStore store = _MemoryStore(<Note>[note]);
      final NotesController notes = await _open(store);

      notes.updateBody('本地改过');
      store.failSave = true;
      final DeleteOutcome outcome = await notes.deleteNotes(<Note>[note]);

      expect(outcome.deleted, 0);
      expect(outcome.failed, 1);
      expect(store.notes, hasLength(1), reason: '没保存成功就不能删');
      expect(notes.allNotes, hasLength(1));
      expect(notes.draft?.body, '本地改过', reason: '本地输入不能丢');
      expect(notes.error, contains('删除已取消'));
    });

    test('undoing a delete brings the note back and selects it', () async {
      final Note note = _note('随笔', body: '正文', folderPath: '工作');
      final _MemoryStore store = _MemoryStore(<Note>[note]);
      final NotesController notes = await _open(store);

      final DeleteOutcome outcome = await notes.deleteNotes(<Note>[note]);
      final int restored = await notes.restoreTrashEntries(<String>[
        outcome.receipts.single.id,
      ]);

      expect(restored, 1);
      expect(store.trash, isEmpty);
      final Note back = store.notes.single;
      expect(back.id, note.id);
      expect(back.title, '随笔');
      expect(back.relativePath, '工作/随笔.md');
      expect(back.body, '正文');
      expect(notes.selectedId, back.id);
      expect(notes.draft?.body, '正文');
    });

    test('a batch delete keeps the notes it could not move', () async {
      final Note first = _note('一');
      final Note second = _note('二');
      final _MemoryStore store = _MemoryStore(<Note>[first, second]);
      final NotesController notes = await _open(store);

      store.failDeleteIds.add(second.id);
      final DeleteOutcome outcome = await notes.deleteNotes(<Note>[
        first,
        second,
      ]);

      expect(outcome.deleted, 1);
      expect(outcome.failed, 1);
      expect(outcome.receipts, hasLength(1));
      expect(store.notes.single.id, second.id, reason: '没删掉的必须留在库里');
      expect(notes.allNotes.single.id, second.id);
      expect(notes.error, contains('二'));
    });
  });

  group('删除文件夹', () {
    test(
      'a folder delete trashes every note below it and removes the folder',
      () async {
        final Note rootNote = _note('根目录');
        final Note plan = _note('计划', body: '正文', folderPath: '项目');
        final Note sub = _note('子计划', body: '正文', folderPath: '项目/子项目');
        final _MemoryStore store = _MemoryStore(<Note>[rootNote, plan, sub]);
        await store.createFolder('项目/子项目');
        final NotesController notes = await _open(store);
        notes.setActiveFolder('项目/子项目');

        final FolderDeleteOutcome outcome = await notes.deleteFolder('项目');

        expect(outcome.blocked, isNull);
        expect(outcome.removed, isTrue);
        expect(outcome.deleted, 2);
        expect(outcome.failed, 0);
        expect(outcome.receipts, hasLength(2));
        expect(store.notes.single.id, rootNote.id);
        expect(notes.allNotes.single.id, rootNote.id);
        expect(notes.folders, isNot(contains('项目')));
        expect(notes.activeFolder, '', reason: '被删掉的目录要让下一步落到根目录');
      },
    );

    test(
      'a folder with a foreign file is refused before any note moves',
      () async {
        final Note plan = _note('计划', body: '正文', folderPath: '项目');
        final _MemoryStore store = _MemoryStore(<Note>[plan]);
        await store.createFolder('项目');
        store.foreignFiles.add('项目/附件.png');
        final NotesController notes = await _open(store);

        final FolderDeleteOutcome outcome = await notes.deleteFolder('项目');

        expect(outcome.blocked, contains('不是笔记'));
        expect(outcome.removed, isFalse);
        expect(outcome.deleted, 0);
        expect(store.notes.single.id, plan.id);
        expect(store.trash, isEmpty, reason: '拒绝时连一篇笔记都不能移动');
        expect(notes.allNotes.single.id, plan.id);
      },
    );

    test('白板挡住文件夹删除时，提示里说清楚有几块', () async {
      final Note plan = _note('计划', body: '正文', folderPath: '项目');
      final _MemoryStore store = _MemoryStore(<Note>[plan]);
      await store.createFolder('项目');
      store.foreignFiles.add('项目/草图.nrs');
      final NotesController notes = await _open(store);
      notes.canvasCountOf = (String folder) async => folder == '项目' ? 1 : 0;

      final FolderDeleteOutcome outcome = await notes.deleteFolder('项目');

      expect(outcome.blocked, '文件夹里还有 1 块白板');
      expect(outcome.removed, isFalse);
      expect(store.trash, isEmpty);
    });

    test('数不清白板时退回泛化提示，而不是把异常抛给界面', () async {
      final Note plan = _note('计划', body: '正文', folderPath: '项目');
      final _MemoryStore store = _MemoryStore(<Note>[plan]);
      await store.createFolder('项目');
      store.foreignFiles.add('项目/附件.png');
      final NotesController notes = await _open(store);
      notes.canvasCountOf = (String folder) async => throw StateError('磁盘掉了');

      final FolderDeleteOutcome outcome = await notes.deleteFolder('项目');

      expect(outcome.blocked, contains('不是笔记'));
      expect(outcome.removed, isFalse);
    });

    test(
      'a note that cannot be trashed keeps the folder and the other notes',
      () async {
        final Note first = _note('一', folderPath: '项目');
        final Note second = _note('二', folderPath: '项目/子');
        final _MemoryStore store = _MemoryStore(<Note>[first, second]);
        await store.createFolder('项目/子');
        final NotesController notes = await _open(store);
        store.failDeleteIds.add(second.id);

        final FolderDeleteOutcome outcome = await notes.deleteFolder('项目');

        expect(outcome.removed, isFalse);
        expect(outcome.deleted, 1);
        expect(outcome.failed, 1);
        expect(outcome.receipts, hasLength(1));
        expect(store.notes.single.id, second.id);
        expect(notes.folders, contains('项目'));
      },
    );

    test('an empty folder is removed without a trash entry', () async {
      final _MemoryStore store = _MemoryStore();
      await store.createFolder('空');
      final NotesController notes = await _open(store);

      final FolderDeleteOutcome outcome = await notes.deleteFolder('空');

      expect(outcome.removed, isTrue);
      expect(outcome.deleted, 0);
      expect(outcome.receipts, isEmpty);
      expect(notes.folders, isNot(contains('空')));
    });

    test(
      'undoing a folder delete puts the notes back with their folders',
      () async {
        final Note plan = _note('计划', body: '正文', folderPath: '项目/子');
        final _MemoryStore store = _MemoryStore(<Note>[plan]);
        await store.createFolder('项目/子');
        final NotesController notes = await _open(store);

        final FolderDeleteOutcome outcome = await notes.deleteFolder('项目');
        final int restored = await notes.restoreTrashEntries(<String>[
          outcome.receipts.single.id,
        ]);

        expect(restored, 1);
        expect(store.notes.single.relativePath, '项目/子/计划.md');
        expect(notes.folders, contains('项目/子'));
      },
    );
  });

  group('版本历史', () {
    test(
      'restoring a version swaps the body in place and keeps the tab',
      () async {
        final Note note = _note('计划', body: '旧版', folderPath: '工作');
        final _MemoryStore store = _MemoryStore(<Note>[note]);
        store.seedVersion(note, '旧版');
        final NotesController notes = await _open(store);
        final String versionId = store.versions[note.id]!.single.id;

        notes.updateBody('新版');
        final bool restored = await notes.restoreVersion(
          notes.draft!,
          versionId,
        );

        expect(restored, isTrue);
        expect(notes.draft?.body, '旧版');
        expect(notes.draft?.title, '计划');
        expect(notes.draft?.relativePath, '工作/计划.md');
        expect(notes.saveState, SaveState.idle);
        expect(notes.selectedId, note.id);
        expect(store.notes.single.body, '旧版');
        expect(store.captured, hasLength(1));
        expect(
          store.captured.single.raw,
          contains('新版'),
          reason: '恢复前的内容要先进历史,恢复才可逆',
        );
      },
    );

    test('keepMine snapshots the disk version before discarding it', () async {
      final Note original = _note('随笔', body: '第一行');
      final _MemoryStore store = _MemoryStore(<Note>[original]);
      final NotesController notes = await _open(store);

      notes.updateBody('本地改过');
      store.writeExternally(original.copyWith(body: '外部改过'));
      await notes.syncFromDisk();
      expect(notes.conflict, isNotNull);

      await notes.keepMine();

      expect(notes.conflict, isNull);
      expect(store.notes.single.body, '本地改过');
      expect(store.captured, hasLength(1));
      expect(store.captured.single.raw, contains('外部改过'));
    });
  });

  group('模板套用', () {
    test('新笔记触发一次创建钩子，模板新建可以跳过它', () async {
      final NotesController notes = await _open(_MemoryStore());
      int calls = 0;
      final Completer<Note> seen = Completer<Note>();
      notes.onBlankNoteCreated = (Note note) async {
        calls++;
        if (!seen.isCompleted) seen.complete(note);
      };

      final Note withHook = notes.createNote();
      expect((await seen.future).id, withHook.id);

      final Note direct = notes.createNote(runCreationHook: false);
      await pumpEventQueue();
      expect(calls, 1, reason: '用模板新建时不能再套一层文件夹模板');
      expect(direct.id, isNot(withHook.id));
    });

    test('空笔记写入模板并立即保存；有字时绝不覆盖', () async {
      final _MemoryStore store = _MemoryStore();
      final NotesController notes = await _open(store);

      final Note blank = notes.createNote();
      expect(await notes.applyBodyIfEmpty(blank.id, '# 模板正文'), isTrue);
      expect(notes.draft!.body, '# 模板正文');
      expect(
        store.notes.firstWhere((Note n) => n.id == blank.id).body,
        '# 模板正文',
      );

      final Note typed = notes.createNote();
      notes.updateBody('我自己写的');
      expect(await notes.applyBodyIfEmpty(typed.id, '# 模板正文'), isFalse);
      expect(notes.draft!.body, '我自己写的');
      await notes.saveNow();
      expect(
        store.notes.firstWhere((Note n) => n.id == typed.id).body,
        '我自己写的',
      );
    });

    test('切换到别的笔记后，模板仍写到目标笔记而不是当前草稿', () async {
      final _MemoryStore store = _MemoryStore(<Note>[_note('旧笔记')]);
      final NotesController notes = await _open(store);
      final Note created = notes.createNote();
      final Note other = notes.allNotes.firstWhere(
        (Note n) => n.id != created.id,
      );
      notes.select(other.id);

      expect(await notes.applyBodyIfEmpty(created.id, '模板内容'), isTrue);
      expect(notes.draft!.id, other.id);
      expect(notes.draft!.body, isEmpty);
      expect(
        store.notes.firstWhere((Note n) => n.id == created.id).body,
        '模板内容',
      );
    });

    test('用户抢在模板渲染完成前输入，钩子的写入被拒绝', () async {
      final NotesController notes = await _open(_MemoryStore());
      final Completer<bool> applied = Completer<bool>();
      final Completer<void> typing = Completer<void>();

      notes.onBlankNoteCreated = (Note note) async {
        await typing.future; // prompt 打开期间用户开始打字
        applied.complete(await notes.applyBodyIfEmpty(note.id, '模板内容'));
      };

      final Note created = notes.createNote();
      notes.updateBody('抢在模板前输入');
      typing.complete();

      expect(await applied.future, isFalse);
      expect(notes.draft!.body, '抢在模板前输入');
      expect(notes.noteById(created.id)!.body, '抢在模板前输入');
    });
  });

  group('白板改笔记正文', () {
    test('没开着的笔记：列表和磁盘一起改，不切走当前草稿', () async {
      final Note target = _note('甲', body: '旧正文');
      final Note other = _note('乙');
      final _MemoryStore store = _MemoryStore(<Note>[target, other]);
      final NotesController notes = await _open(store);
      notes.select(other.id);

      expect(await notes.writeNoteBody(target.relativePath, '新正文'), isTrue);

      expect(notes.noteById(target.id)!.body, '新正文');
      expect(store.notes.firstWhere((Note n) => n.id == target.id).body, '新正文');
      expect(notes.draft!.id, other.id, reason: '不该把开着的那篇切掉');
      expect(notes.draft!.body, isEmpty);
    });

    test('开着的笔记：改草稿并立即落盘', () async {
      final Note target = _note('甲', body: '旧正文');
      final _MemoryStore store = _MemoryStore(<Note>[target]);
      final NotesController notes = await _open(store);
      expect(notes.draft?.id, target.id);

      expect(await notes.writeNoteBody(target.relativePath, '新正文'), isTrue);

      expect(notes.draft!.body, '新正文');
      expect(store.notes.single.body, '新正文');
    });

    test('写盘失败返回 false，不假装写成功', () async {
      final Note target = _note('甲');
      final Note other = _note('乙');
      final _MemoryStore store = _MemoryStore(<Note>[target, other]);
      final NotesController notes = await _open(store);
      notes.select(other.id);
      store.failSave = true;

      expect(await notes.writeNoteBody(target.relativePath, '新正文'), isFalse);
      expect(notes.error, isNotNull);
    });

    test('笔记不存在：返回 false', () async {
      final NotesController notes = await _open(_MemoryStore());

      expect(await notes.writeNoteBody('查无此篇.md', '正文'), isFalse);
    });
  });

  group('标签栏会话', () {
    test('四个标签按原顺序回来，选中的还是第四个', () async {
      final List<Note> seed = <Note>[
        _note('一'),
        _note('二'),
        _note('三'),
        _note('四'),
      ];
      final _MemoryStore store = _MemoryStore(seed);

      final NotesController first = NotesController(store: store);
      addTearDown(first.dispose);
      await first.bootstrap();
      for (final Note note in seed) {
        first.select(note.id);
      }
      expect(first.selectedId, seed.last.id);
      final List<String> tabs = first.openIds;

      final NotesController second = NotesController(store: store);
      addTearDown(second.dispose);
      second.restoreSession(tabs: tabs, selected: first.selectedId);
      await second.bootstrap();

      expect(second.openIds, tabs, reason: '顺序也要一样');
      expect(second.selectedId, seed.last.id);
      expect(second.draft?.id, seed.last.id);
      expect(second.tabSessionRestored, isTrue);
    });

    test('上次把标签全关了，重启后也不替他打开一篇', () async {
      final _MemoryStore store = _MemoryStore(<Note>[_note('一'), _note('二')]);
      final NotesController notes = NotesController(store: store);
      addTearDown(notes.dispose);
      notes.restoreSession(tabs: const <String>[], selected: null);
      await notes.bootstrap();

      expect(notes.openIds, isEmpty);
      expect(notes.selectedId, isNull);
      expect(notes.draft, isNull);
      expect(notes.tabSessionRestored, isTrue, reason: '空标签栏是用户选的，不是要修复的空白');
    });

    test('上次选中的那篇没了，右邻居接手；没有右边就交给左邻居', () async {
      final Note one = _note('一');
      final Note two = _note('二');
      final Note three = _note('三');
      final _MemoryStore store = _MemoryStore(<Note>[one, two, three]);

      final NotesController middle = NotesController(store: store);
      addTearDown(middle.dispose);
      middle.restoreSession(
        tabs: <String>[one.id, '不见了', two.id, three.id],
        selected: '不见了',
      );
      await middle.bootstrap();

      expect(middle.openIds, <String>[one.id, two.id, three.id]);
      expect(middle.selectedId, two.id, reason: '右邻居接手');

      final NotesController last = NotesController(store: store);
      addTearDown(last.dispose);
      last.restoreSession(
        tabs: <String>[one.id, two.id, '也不见了'],
        selected: '也不见了',
      );
      await last.bootstrap();

      expect(last.openIds, <String>[one.id, two.id]);
      expect(last.selectedId, two.id, reason: '没有右邻居时交给左邻居');
    });

    test('没存过会话时照旧打开第一篇，不冒充恢复成功', () async {
      final Note first = _note('一');
      final NotesController notes = NotesController(
        store: _MemoryStore(<Note>[first, _note('二')]),
      );
      addTearDown(notes.dispose);
      await notes.bootstrap();

      expect(notes.selectedId, first.id);
      expect(notes.openIds, <String>[first.id]);
      expect(notes.tabSessionRestored, isFalse);
    });
  });

  group('importMarkdownFiles', () {
    test('a dropped .md becomes a note under its own name and opens', () async {
      final _MemoryStore store = _MemoryStore(<Note>[_note('另一篇')]);
      store.external[r'C:\Users\me\Desktop\周报.md'] = '# 周报\n\n本周进展';
      final NotesController notes = await _open(store);

      final result = await notes.importMarkdownFiles(<String>[
        r'C:\Users\me\Desktop\周报.md',
      ]);

      expect(result.imported, 1);
      expect(result.refused, 0);
      expect(result.paths, <String>['周报.md'], reason: '导入的路径要能拿去引用');
      final Note imported = notes.allNotes.firstWhere(
        (Note n) => n.title == '周报',
      );
      expect(imported.body, contains('本周进展'));
      expect(imported.fileName, '周报.md');
      expect(notes.selectedId, imported.id, reason: '导入的那篇应该被打开');
    });

    test(
      'a name already in the vault gets the 2 rule, not an overwrite',
      () async {
        final Note existing = _note('周报', body: '原来的正文');
        final _MemoryStore store = _MemoryStore(<Note>[existing]);
        store.external['/tmp/周报.md'] = '# 周报\n\n拖进来的';
        final NotesController notes = await _open(store);

        await notes.importMarkdownFiles(<String>['/tmp/周报.md']);

        expect(notes.allNotes.length, 2);
        final Note kept = notes.allNotes.firstWhere(
          (Note n) => n.fileName == '周报.md',
        );
        expect(kept.body, contains('原来的正文'), reason: '同名文件不能被覆盖');
        final Note added = notes.allNotes.firstWhere(
          (Note n) => n.fileName == '周报 2.md',
        );
        expect(added.body, contains('拖进来的'));
      },
    );

    test('anything that is not a .md is refused and counted', () async {
      final _MemoryStore store = _MemoryStore();
      store.external['/tmp/预算.pdf'] = 'not markdown';
      store.external['/tmp/笔记.md'] = '# 笔记';
      final NotesController notes = await _open(store);

      final result = await notes.importMarkdownFiles(<String>[
        '/tmp/预算.pdf',
        '/tmp/笔记.md',
      ]);

      expect(result.imported, 1);
      expect(result.refused, 1);
      expect(result.paths, <String>['笔记.md'], reason: '被拒的那个不进 paths');
      expect(notes.allNotes.length, 1);
      expect(notes.allNotes.single.title, '笔记');
    });

    test('a file that cannot be read is refused', () async {
      final _MemoryStore store = _MemoryStore();
      final NotesController notes = await _open(store);

      final result = await notes.importMarkdownFiles(<String>['/tmp/不见了.md']);

      expect(result.imported, 0);
      expect(result.refused, 1);
      expect(result.paths, isEmpty);
      expect(notes.allNotes, isEmpty);
    });
  });

  group('relativeVaultPath', () {
    test('库根按目录边界比、大小写不敏感；没有本地库就一律算库外', () {
      expect(NotesController.relativeVaultPath(null, '/vault/甲.md'), isNull);
      expect(NotesController.relativeVaultPath('', '/vault/甲.md'), isNull);
      expect(
        NotesController.relativeVaultPath('/vault', '/vault/甲.md'),
        '甲.md',
      );
      expect(
        NotesController.relativeVaultPath('/vault/', '/vault/甲.md'),
        '甲.md',
        reason: '根目录末尾有没有斜杠都一样',
      );
      expect(
        NotesController.relativeVaultPath('/vault', '/vaultx/甲.md'),
        isNull,
        reason: '前缀得停在目录分隔符上，不能把 vaultx 当成 vault',
      );
      expect(
        NotesController.relativeVaultPath('/vault', '/vault'),
        isNull,
        reason: '根目录自己不是一篇笔记',
      );
    });
  });
}

/// An in-memory vault whose writes take real time, so overlap is visible.
class _SlowStore extends _MemoryStore {
  _SlowStore() : super(<Note>[_note('随笔')]);

  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await super.save(note, previousPath: previousPath);
    _inFlight--;
  }
}

/// A vault that grows a file behind the controller's back exactly when it
/// first tries to create `未命名.md` — the Explorer case.
class _CollidingStore extends _MemoryStore {
  _CollidingStore() : super();

  bool _collided = false;

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    if (!_collided && note.fileName == '未命名.md') {
      _collided = true;
      notes.add(
        Note(
          id: Note.newId(),
          title: '未命名',
          body: '外部写的正文',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      );
      throw NotePathTaken(note.relativePath);
    }
    await super.save(note, previousPath: previousPath);
  }
}

/// The in-memory vault, counting writes.
class _CountingStore extends _MemoryStore {
  _CountingStore(this._written) : super(<Note>[_note('随笔')]);

  final void Function() _written;

  @override
  Future<void> save(Note note, {String? previousPath}) {
    _written();
    return super.save(note, previousPath: previousPath);
  }
}

/// The in-memory vault with one save that can be held open, so a tab switch
/// lands while that write is still in flight.
class _GatedStore extends _MemoryStore {
  _GatedStore()
    : super(<Note>[_note('第一篇', body: '正文'), _note('第二篇', body: '另一篇')]);

  Completer<void>? _gate;
  Completer<void>? _held;
  Completer<void>? _started;

  Future<void> get saveStarted => _started!.future;

  void blockNextSave() {
    _gate = Completer<void>();
    _started = Completer<void>();
  }

  void release() {
    final Completer<void>? gate = _held;
    _held = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    final Completer<void>? gate = _gate;
    if (gate != null && !gate.isCompleted) {
      _gate = null;
      _held = gate;
      _started!.complete();
      await gate.future;
    }
    await super.save(note, previousPath: previousPath);
  }
}

/// The in-memory vault whose next [loadAll] blocks, reproducing a focus sync
/// that read the disk before the app's own save replaced the file.
class _RacingStore extends _MemoryStore {
  _RacingStore() : super(<Note>[_note('随笔', body: '旧正文')]);

  Completer<void>? _readStarted;
  Completer<void>? _readGate;

  Future<void> get readStarted => _readStarted!.future;

  void arm() {
    _readStarted = Completer<void>();
    _readGate = Completer<void>();
  }

  void finishRead() {
    _readGate?.complete();
    _readGate = null;
  }

  /// Touches the file the way another program would, so the next focus sync
  /// believes the vault changed and reads it.
  void touchStamp() {
    writeExternally(notes.first);
  }

  @override
  Future<List<Note>> loadAll() async {
    final Completer<void>? gate = _readGate;
    if (gate == null) return super.loadAll();
    final List<Note> snapshot = List<Note>.of(notes);
    _readStarted!.complete();
    await gate.future;
    return snapshot;
  }
}
