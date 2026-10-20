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
  Future<void> delete(Note note) async {
    notes.removeWhere((Note n) => n.id == note.id);
    _stamps.remove(note.relativePath);
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
      fileName: _uniqueName(folder, Note.buildFileName(parsed.title)),
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

Note _note(String title, {String body = ''}) => Note(
  id: Note.newId(),
  title: title,
  body: body,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
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
    expect(notes.allNotes.length, 2, reason: 'nothing should have been written');
  });

  test('a link to a note that does not exist writes it', () async {
    final _MemoryStore store = _MemoryStore(<Note>[_note('另一篇')]);
    final NotesController notes = await _open(store);

    final ({Note note, bool created}) opened = notes.openOrCreateByTitle(
      '新想法',
    );

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
    expect(notes.allNotes.length, 1, reason: 'a near-miss must not fork the note');
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
    expect(
      second.title,
      '未命名 2',
      reason: '编辑器里选中的占位名必须和磁盘上的文件名一致',
    );
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
    expect(
      store.notes.where((Note n) => n.fileName == '新标题.md'),
      hasLength(1),
    );
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
    expect(
      notes.visibleNotes,
      hasLength(3),
      reason: '搜索要扫全库，不能只看顶层或当前文件夹',
    );
    expect(
      notes.visibleNotes.map((Note n) => n.title),
      contains('nrs开发进度'),
    );
  });

  test('clearing the query drops the results, and any tag filter with it',
      () async {
    final NotesController notes = await _open(
      _MemoryStore(<Note>[_note('NRS 快速入门'), _note('闲话', body: '# 杂')]),
    );

    notes.setQuery('nrs');
    expect(notes.visibleNotes, hasLength(1));

    notes.setQuery('');
    expect(notes.isFiltered, isFalse);
    expect(notes.visibleNotes, hasLength(2), reason: '清空后回到完整列表');
  });

  test('typing a query lets go of the tag filter, so search is vault-wide',
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
  });

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

  test('an external edit while typing opens a conflict and stops autosave',
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
    expect(
      store.notes.single.body,
      '外部改过',
      reason: '冲突未解决前,自动保存必须停下',
    );

    await notes.keepMine();
    expect(notes.conflict, isNull);
    expect(store.notes.single.body, '本地改过');
    expect(notes.saveState, SaveState.saved);
  });

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

  test('a note deleted outside keeps the draft as a copy, not a loss', () async {
    final Note original = _note('随笔', body: '第一行');
    final _MemoryStore store = _MemoryStore(<Note>[original]);
    final NotesController notes = await _open(store);

    notes.updateBody('本地改过');
    store.deleteExternally(original);
    await notes.syncFromDisk();

    expect(notes.conflict?.isDeleted, isTrue);
    expect(
      notes.allNotes,
      hasLength(1),
      reason: '文件没了,但没保存的文字不能跟着消失',
    );

    await notes.saveConflictCopy();
    expect(notes.conflict, isNull);
    expect(store.notes, hasLength(1));
    expect(store.notes.single.body, '本地改过');
  });

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
