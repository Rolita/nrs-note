import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/history_store.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/data/storage/note_store_io.dart';

void main() {
  late Directory root;
  late String vault;
  late DateTime now;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nrs-history-');
    vault = '${root.path}${Platform.pathSeparator}NRS Notes';
    Directory(vault).createSync(recursive: true);
    now = DateTime.utc(2026, 1, 1, 12);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File file(String relative) => File(
    '$vault${Platform.pathSeparator}'
    '${relative.replaceAll('/', Platform.pathSeparator)}',
  );

  IoNoteStore store({Duration interval = Duration.zero}) => IoNoteStore(
    overrideRoot: root,
    clock: () => now,
    historyMinInterval: interval,
  );

  Future<List<String>> historyBodies(
    IoNoteStore store,
    Note note,
  ) async {
    final List<String> bodies = <String>[];
    for (final version in await store.historyOf(note)) {
      final String? raw = await store.readVersion(note, version.id);
      expect(raw, isNotNull);
      bodies.add(Note.splitFrontMatter(raw!).body);
    }
    return bodies;
  }

  test('the content overwritten by the first save becomes a version', () async {
    final IoNoteStore s = store();
    await s.init();
    final Note note = Note.blank(title: '计划');
    await s.save(note);

    await s.save(note.copyWith(body: '第二版'), previousPath: note.relativePath);

    expect(await historyBodies(s, note), <String>[note.body]);
    expect(await s.historyOf(note), hasLength(1));
  });

  test('autosaves inside ten minutes share one version', () async {
    final IoNoteStore s = store(interval: const Duration(minutes: 10));
    await s.init();
    final Note note = Note.blank(title: '节流');
    await s.save(note);

    now = now.add(const Duration(minutes: 1));
    await s.save(note.copyWith(body: '一分钟后'), previousPath: note.relativePath);
    expect(await s.historyOf(note), hasLength(1));

    now = now.add(const Duration(minutes: 1));
    await s.save(note.copyWith(body: '两分钟后'), previousPath: note.relativePath);
    expect(
      await s.historyOf(note),
      hasLength(1),
      reason: '十分钟内的连续保存只留第一版',
    );

    now = now.add(const Duration(minutes: 9));
    await s.save(note.copyWith(body: '十一分钟后'), previousPath: note.relativePath);
    expect(await s.historyOf(note), hasLength(2));
  });

  test('a pure rename or move does not create a version', () async {
    final IoNoteStore s = store(interval: const Duration(minutes: 10));
    await s.init();
    final Note note = Note.blank(title: '旧名');
    await s.save(note);
    now = now.add(const Duration(minutes: 11));
    await s.save(note.copyWith(body: '改过正文'), previousPath: note.relativePath);
    final int baseline = (await s.historyOf(note)).length;

    now = now.add(const Duration(minutes: 11));
    final Note renamed = note.copyWith(
      title: '新名',
      fileName: Note.buildFileName('新名'),
      body: '改过正文',
    );
    await s.save(renamed, previousPath: note.relativePath);

    expect(
      await s.historyOf(renamed),
      hasLength(baseline),
      reason: '只改文件名、正文没变，不应该占用一个版本',
    );
  });

  test('history follows the note id across a rename', () async {
    final IoNoteStore s = store(interval: const Duration(minutes: 10));
    await s.init();
    final Note note = Note.blank(title: '旧名', folderPath: '项目');
    await s.save(note);
    now = now.add(const Duration(minutes: 11));
    await s.save(note.copyWith(body: '第二版'), previousPath: note.relativePath);
    expect(await s.historyOf(note), hasLength(1));

    final Note moved = note.copyWith(
      title: '新名',
      fileName: Note.buildFileName('新名'),
      folderPath: '归档',
      body: '第三版',
    );
    now = now.add(const Duration(minutes: 11));
    await s.save(moved, previousPath: note.relativePath);

    final List<NoteVersion> versions = await s.historyOf(moved);
    expect(versions.length, greaterThanOrEqualTo(2));
    expect(
      file('归档/新名.md').existsSync(),
      isTrue,
      reason: '正文改了，文件必须在移动后的位置',
    );
  });

  test('restore swaps the body and keeps the current identity and path',
      () async {
    final IoNoteStore s = store();
    await s.init();
    final Note note = Note.blank(title: '计划', folderPath: '项目');
    await s.save(note);
    await s.save(note.copyWith(body: '当前正文'), previousPath: note.relativePath);
    final List<NoteVersion> versions = await s.historyOf(note);
    final NoteVersion oldest = versions.last;

    final Note current = note.copyWith(
      title: '计划改名',
      fileName: Note.buildFileName('计划改名'),
      folderPath: '归档',
      body: '当前正文',
    );
    await s.save(current, previousPath: note.relativePath);
    await s.save(current.copyWith(body: '最新正文'), previousPath: current.relativePath);

    final bool ok = await s.restoreVersion(
      current.copyWith(body: '最新正文'),
      oldest.id,
    );

    expect(ok, isTrue);
    final Note reread = (await s.loadAll()).firstWhere((Note n) => n.id == note.id);
    expect(reread.body, note.body);
    expect(reread.id, note.id);
    expect(reread.fileName, '计划改名.md');
    expect(reread.folderPath, '归档');
    expect(file('归档/计划改名.md').existsSync(), isTrue);
    expect(
      await historyBodies(s, reread),
      contains('最新正文'),
      reason: '恢复前的内容必须先进入历史，恢复才能撤回',
    );
  });

  test('restoring twice walks back and forth through the chain', () async {
    final IoNoteStore s = store();
    await s.init();
    final Note note = Note.blank(title: '往返');
    await s.save(note);
    await s.save(note.copyWith(body: '中间版'), previousPath: note.relativePath);
    await s.save(note.copyWith(body: '最终版'), previousPath: note.relativePath);

    final List<NoteVersion> versions = await s.historyOf(note);
    final NoteVersion first = versions.last;
    expect((await s.readVersion(note, first.id)), isNotNull);

    await s.restoreVersion(note.copyWith(body: '最终版'), first.id);
    final Note afterFirst =
        (await s.loadAll()).firstWhere((Note n) => n.id == note.id);
    expect(afterFirst.body, note.body);

    final List<NoteVersion> after = await s.historyOf(afterFirst);
    NoteVersion? finalVersion;
    for (final NoteVersion version in after) {
      final String? raw = await s.readVersion(afterFirst, version.id);
      if (raw != null && Note.splitFrontMatter(raw).body == '最终版') {
        finalVersion = version;
        break;
      }
    }
    expect(finalVersion, isNotNull, reason: '恢复前的内容必须留下可再恢复的一版');
    await s.restoreVersion(afterFirst, finalVersion!.id);
    final Note afterSecond =
        (await s.loadAll()).firstWhere((Note n) => n.id == note.id);

    expect(afterSecond.body, '最终版');
  });

  test('retention keeps only the hundred newest versions', () async {
    final HistoryStore history = HistoryStore(
      Directory(vault),
      clock: () => now,
      minInterval: Duration.zero,
      maxVersions: 3,
    );
    for (int i = 0; i < 5; i++) {
      now = now.add(const Duration(minutes: 1));
      expect(await history.capture('note-1', '正文 $i'), isTrue);
    }

    final List<NoteVersion> versions = await history.list('note-1');

    expect(versions, hasLength(3));
    final List<String> bodies = <String>[];
    for (final NoteVersion version in versions) {
      bodies.add((await history.read('note-1', version.id))!);
    }
    expect(bodies, <String>['正文 4', '正文 3', '正文 2']);
  });

  test('versions older than the retention window are pruned', () async {
    final HistoryStore history = HistoryStore(
      Directory(vault),
      clock: () => now,
      minInterval: Duration.zero,
      retention: const Duration(days: 10),
    );
    await history.capture('note-2', '十天前');
    now = now.add(const Duration(days: 5));
    await history.capture('note-2', '五天后');
    now = now.add(const Duration(days: 10));
    await history.capture('note-2', '十五天后');

    final List<NoteVersion> versions = await history.list('note-2');

    expect(versions, hasLength(2));
    final List<String> bodies = <String>[];
    for (final NoteVersion version in versions) {
      bodies.add((await history.read('note-2', version.id))!);
    }
    expect(bodies, <String>['十五天后', '五天后']);
  });

  test('a broken history directory never fails the save', () async {
    final IoNoteStore s = store();
    await s.init();
    final Note note = Note.blank(title: '保存优先');
    await s.save(note);
    File('$vault${Platform.pathSeparator}.nrs-history')
        .writeAsStringSync('not a directory');

    await s.save(
      note.copyWith(body: '仍然要保存成功'),
      previousPath: note.relativePath,
    );

    final Note reread = (await s.loadAll()).firstWhere((Note n) => n.id == note.id);
    expect(reread.body, '仍然要保存成功');
  });
}
