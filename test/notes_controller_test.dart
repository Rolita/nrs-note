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
    expect(opened.note.fileName, startsWith('读书笔记-'));
  });
}
