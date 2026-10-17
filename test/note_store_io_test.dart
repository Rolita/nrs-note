import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store_io.dart';

/// The desktop vault is the real target, so the file-name contract is checked
/// against a real folder rather than a fake: one `.md` per note, and the file's
/// name *is* the note's name.
void main() {
  late Directory root;

  /// The store creates its own `NRS Notes` folder under the root it is given.
  late String vault;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nrs-vault-');
    vault = '${root.path}${Platform.pathSeparator}NRS Notes';
    Directory(vault).createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File file(String name) =>
      File('$vault${Platform.pathSeparator}$name');

  test('a legacy <title>-<id>.md file is renamed to <title>.md on load', () async {
    // What the previous scheme wrote: a short id glued to the title.
    final Note legacy = Note(
      id: 'abc123',
      title: '写作计划',
      body: '正文',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
      fileName: '写作计划-abc123.md',
    );
    file('写作计划-abc123.md').writeAsStringSync(legacy.toMarkdown());

    final IoNoteStore store = IoNoteStore(overrideRoot: root);
    await store.init();
    final List<Note> notes = await store.loadAll();

    final Note loaded = notes.firstWhere((Note n) => n.id == 'abc123');
    expect(loaded.fileName, '写作计划.md');
    // The title is the file name — one name, not a name plus an id.
    expect(loaded.title, '写作计划');
    expect(file('写作计划.md').existsSync(), isTrue);
    expect(file('写作计划-abc123.md').existsSync(), isFalse);
  });

  test('a hand-named file is never migrated behind the user back', () async {
    // The stem ends in six characters that look like an id, but the title in
    // the metadata is different: this is a file the user named, not one NRS
    // generated, so it must be left exactly where it is.
    file('会议纪要-abc123.md').writeAsStringSync(
      '---\nid: x\ntitle: 周会\n---\n\n正文\n',
    );

    final IoNoteStore store = IoNoteStore(overrideRoot: root);
    await store.init();
    final List<Note> notes = await store.loadAll();

    expect(notes.first.fileName, '会议纪要-abc123.md');
    expect(notes.first.title, '会议纪要-abc123');
    expect(file('会议纪要-abc123.md').existsSync(), isTrue);
    expect(file('周会.md').existsSync(), isFalse);
  });

  test('saving under a new title moves the file and leaves no orphan', () async {
    final IoNoteStore store = IoNoteStore(overrideRoot: root);
    await store.init();

    final Note note = Note.blank(title: '旧名字');
    await store.save(note);
    expect(file('旧名字.md').existsSync(), isTrue);

    final Note renamed = note.copyWith(
      title: '新名字',
      fileName: Note.buildFileName('新名字'),
    );
    await store.save(renamed, previousFileName: note.fileName);

    expect(file('新名字.md').existsSync(), isTrue);
    expect(
      file('旧名字.md').existsSync(),
      isFalse,
      reason: '改名后旧文件必须消失，否则库里会多出一篇幽灵笔记',
    );
  });

  test('an untitled note lives in 未命名.md', () async {
    final IoNoteStore store = IoNoteStore(overrideRoot: root);
    await store.init();

    final Note note = Note.blank();
    expect(note.fileName, '未命名.md');
    await store.save(note);

    final List<Note> notes = await store.loadAll();
    final Note loaded = notes.firstWhere((Note n) => n.id == note.id);
    expect(loaded.title, '未命名');
    expect(loaded.fileName, '未命名.md');
  });
}
