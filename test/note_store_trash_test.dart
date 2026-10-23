import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/data/storage/note_store_io.dart';

void main() {
  late Directory root;
  late String vault;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nrs-trash-');
    vault = '${root.path}${Platform.pathSeparator}NRS Notes';
    Directory(vault).createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File file(String relative) => File(
    '$vault${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}',
  );

  Directory dir(String relative) => Directory(
    '$vault${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}',
  );

  Future<IoNoteStore> openStore() async {
    final IoNoteStore store = IoNoteStore(overrideRoot: root);
    await store.init();
    return store;
  }

  Future<({IoNoteStore store, Note note, TrashEntry entry})> deletedNote({
    String title = '计划',
    String folder = '项目',
  }) async {
    final IoNoteStore store = await openStore();
    final Note note = Note.blank(title: title, folderPath: folder);
    await store.save(note);
    final TrashEntry? entry = await store.delete(note);
    expect(entry, isNotNull);
    return (store: store, note: note, entry: entry!);
  }

  test('delete moves the file into the vault trash', () async {
    final IoNoteStore store = await openStore();
    final Note note = Note.blank(title: '计划', folderPath: '项目');
    await store.save(note);

    final TrashEntry? entry = await store.delete(note);

    expect(entry, isNotNull);
    expect(file('项目/计划.md').existsSync(), isFalse);
    expect(
      dir('.nrs-trash/${entry!.id}').existsSync(),
      isTrue,
      reason: '回收站条目必须在笔记库内部',
    );
    expect(entry.originalPath, '项目/计划.md');
    expect(entry.title, '计划');
    expect(entry.size, greaterThan(0));
    expect(
      (await store.loadAll()).any((Note n) => n.id == note.id),
      isFalse,
      reason: '回收站里的文件不能被当成正式笔记',
    );
    expect(await store.listTrash(), hasLength(1));
  });

  test('internal directories are pruned from notes, stamps and folders',
      () async {
    final IoNoteStore store = await openStore();
    final Note note = Note.blank(title: '保留', folderPath: '工作');
    await store.save(note);
    final Note gone = Note.blank(title: '丢掉', folderPath: '工作');
    await store.save(gone);
    await store.delete(gone);

    // A snapshot-shaped file that a real history capture would create.
    dir('.nrs-history/deadbeef').createSync(recursive: true);
    file('.nrs-history/deadbeef/123456.md').writeAsStringSync('快照');
    dir('.nrs-trash/not-a-note').createSync(recursive: true);
    file('.nrs-trash/not-a-note/随手.md').writeAsStringSync('不应出现');

    final List<Note> notes = await store.loadAll();
    final List<NoteFileStamp> stamps = await store.stamps();
    final List<String> folders = await store.listFolders();

    expect(notes.map((Note n) => n.title), contains('保留'));
    expect(notes.any((Note n) => n.id == gone.id), isFalse);
    expect(
      stamps.every((NoteFileStamp s) => !s.relativePath.contains('.nrs-')),
      isTrue,
    );
    expect(folders, contains('工作'));
    expect(
      folders.any((String f) => f.contains('.nrs-')),
      isFalse,
      reason: '内部目录不能出现在文件树里',
    );
  });

  test('restore returns the note to its folder with its identity intact',
      () async {
    final (:store, :note, :entry) = await deletedNote();

    final Note? restored = await store.restoreTrash(entry.id);

    expect(restored, isNotNull);
    expect(restored!.id, note.id);
    expect(restored.body, note.body);
    expect(restored.folderPath, '项目');
    expect(restored.fileName, '计划.md');
    expect(file('项目/计划.md').existsSync(), isTrue);
    expect(file('项目/计划.md').readAsStringSync(), contains(note.body));
    expect(await store.listTrash(), isEmpty);
  });

  test('restore recreates a folder that was removed while in the trash',
      () async {
    final (:store, :entry, note: _) = await deletedNote();
    dir('项目').deleteSync(recursive: true);

    final Note? restored = await store.restoreTrash(entry.id);

    expect(restored, isNotNull);
    expect(dir('项目').existsSync(), isTrue);
    expect(file('项目/计划.md').existsSync(), isTrue);
  });

  test('restore never overwrites a file that took the old name', () async {
    final (:store, :entry, note: _) = await deletedNote();
    final Note newcomer = Note.blank(title: '计划', folderPath: '项目');
    await store.save(newcomer);
    final String newcomerRaw = file('项目/计划.md').readAsStringSync();

    final Note? restored = await store.restoreTrash(entry.id);

    expect(restored, isNotNull);
    expect(restored!.fileName, '计划 2.md');
    expect(file('项目/计划.md').readAsStringSync(), newcomerRaw);
    expect(file('项目/计划 2.md').existsSync(), isTrue);
  });

  test('an entry with missing metadata still restores to the vault root',
      () async {
    final (:store, :entry, note: _) = await deletedNote();
    final File meta = File(
      '${dir('.nrs-trash/${entry.id}').path}${Platform.pathSeparator}meta.json',
    );
    meta.deleteSync();

    final List<TrashEntry> listed = await store.listTrash();
    expect(listed, hasLength(1));
    expect(listed.single.originalPath, '计划.md');

    final Note? restored = await store.restoreTrash(entry.id);
    expect(restored, isNotNull);
    expect(file('计划.md').existsSync(), isTrue);
  });

  test('a corrupt or dangerous path cannot escape the vault', () async {
    final (:store, :entry, note: _) = await deletedNote();
    final File meta = File(
      '${dir('.nrs-trash/${entry.id}').path}${Platform.pathSeparator}meta.json',
    );
    meta.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'schema': 1,
        'originalPath': '../../外面/计划.md',
        'deletedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );

    final Note? restored = await store.restoreTrash(entry.id);

    expect(restored, isNotNull);
    expect(restored!.folderPath, '外面');
    expect(file('外面/计划.md').existsSync(), isTrue);
    expect(File('${root.path}${Platform.pathSeparator}外面${Platform.pathSeparator}计划.md').existsSync(), isFalse);
  });

  test('purge and empty only touch the trash', () async {
    final IoNoteStore store = await openStore();
    final Note live = Note.blank(title: '留着');
    await store.save(live);
    final Note first = Note.blank(title: '第一篇');
    final Note second = Note.blank(title: '第二篇');
    await store.save(first);
    await store.save(second);
    final TrashEntry a = (await store.delete(first))!;
    final TrashEntry b = (await store.delete(second))!;

    await store.purgeTrash(a.id);

    expect(await store.listTrash(), hasLength(1));
    expect((await store.loadAll()).any((Note n) => n.id == live.id), isTrue);

    await store.emptyTrash();

    expect(await store.listTrash(), isEmpty);
    expect(dir('.nrs-trash').existsSync(), isFalse);
    expect((await store.loadAll()).any((Note n) => n.id == live.id), isTrue);
    expect(b.id, isNotEmpty);
  });

  test('a vault holding only trash does not grow a welcome note', () async {
    final IoNoteStore store = await openStore();
    final List<Note> seeded = await store.loadAll();
    expect(seeded, isNotEmpty);
    for (final Note note in seeded) {
      await store.delete(note);
    }
    expect(await store.loadAll(), isEmpty);

    final IoNoteStore reopened = await openStore();

    expect(await reopened.loadAll(), isEmpty);
    expect(await reopened.listTrash(), hasLength(seeded.length));
  });

  test('a failed move aborts the delete and keeps the note on disk', () async {
    final IoNoteStore store = await openStore();
    final Note note = Note.blank(title: '不能丢');
    await store.save(note);
    // A file where the trash directory should be makes entry creation fail.
    File('$vault${Platform.pathSeparator}.nrs-trash')
        .writeAsStringSync('blocked');

    await expectLater(store.delete(note), throwsA(isA<FileSystemException>()));

    expect(file('不能丢.md').existsSync(), isTrue);
    expect((await store.loadAll()).any((Note n) => n.id == note.id), isTrue);
  });
}
