import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/notes_controller.dart';

/// An in-memory vault. The controller only ever talks to [NoteStore], so a fake
/// is enough to exercise the whole "follow a link" path without touching disk.
/// It extends rather than implements, so the `reveal` / `importMarkdown`
/// defaults come along and the fake stays about the four methods that matter.
class _MemoryStore extends NoteStore {
  _MemoryStore([List<Note>? seed]) : notes = <Note>[...?seed];

  final List<Note> notes;

  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<Note>> loadAll() async => List<Note>.of(notes);

  @override
  Future<void> save(Note note, {String? previousFileName}) async {
    notes.removeWhere(
      (Note n) => n.id == note.id || n.fileName == previousFileName,
    );
    notes.insert(0, note);
  }

  @override
  Future<void> delete(Note note) async {
    notes.removeWhere((Note n) => n.id == note.id);
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
}

/// An in-memory vault whose writes take real time, so overlap is visible.
class _SlowStore extends _MemoryStore {
  _SlowStore() : super(<Note>[_note('随笔')]);

  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<void> save(Note note, {String? previousFileName}) async {
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await super.save(note, previousFileName: previousFileName);
    _inFlight--;
  }
}

/// The in-memory vault, counting writes.
class _CountingStore extends _MemoryStore {
  _CountingStore(this._written) : super(<Note>[_note('随笔')]);

  final void Function() _written;

  @override
  Future<void> save(Note note, {String? previousFileName}) {
    _written();
    return super.save(note, previousFileName: previousFileName);
  }
}
