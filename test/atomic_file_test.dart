import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/storage/atomic_file.dart';

/// The writer is the only thing standing between a crash and a truncated note,
/// so its promises are checked against a real folder: either the old bytes are
/// still there, or the new bytes are there in full — never half of either.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('nrs-atomic-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File target([String name = 'note.md']) =>
      File('${root.path}${Platform.pathSeparator}$name');

  List<String> names() => root
      .listSync(recursive: true)
      .whereType<File>()
      .map((File f) => f.path.split(Platform.pathSeparator).last)
      .toList()
    ..sort();

  test('replace commits the new contents and leaves no scaffolding', () async {
    target().writeAsStringSync('旧内容');

    await AtomicFileWriter().replace(target(), '新内容');

    expect(target().readAsStringSync(), '新内容');
    expect(names(), <String>['note.md']);
  });

  test('replace creates the file when it does not exist yet', () async {
    await AtomicFileWriter().replace(target(), '第一版');

    expect(target().readAsStringSync(), '第一版');
    expect(names(), <String>['note.md']);
  });

  test('a failed temporary write leaves the original byte-for-byte intact', () async {
    target().writeAsStringSync('不能丢的内容');
    final AtomicFileWriter writer = AtomicFileWriter(
      writeTemp: (File file, String contents) async {
        await file.writeAsString('半截');
        throw const FileSystemException('disk full');
      },
    );

    await expectLater(
      writer.replace(target(), '新内容'),
      throwsA(isA<FileSystemException>()),
    );

    expect(target().readAsStringSync(), '不能丢的内容');
    expect(
      names(),
      <String>['note.md'],
      reason: '失败后不该留下半截临时文件',
    );
  });

  test('the backup-rotation path also ends with one complete file', () async {
    target().writeAsStringSync('旧内容');

    await AtomicFileWriter(
      forceBackupRotation: true,
    ).replace(target(), '新内容');

    expect(target().readAsStringSync(), '新内容');
    expect(names(), <String>['note.md']);
  });

  test('recover puts a backup back when its target vanished', () async {
    File('${target().path}.nrs-bak').writeAsStringSync('还在的内容');

    await AtomicFileWriter().recover(root);

    expect(target().readAsStringSync(), '还在的内容');
    expect(names(), <String>['note.md']);
  });

  test('recover drops the backup when the target is present', () async {
    target().writeAsStringSync('新内容');
    File('${target().path}.nrs-bak').writeAsStringSync('旧内容');

    await AtomicFileWriter().recover(root);

    expect(target().readAsStringSync(), '新内容');
    expect(names(), <String>['note.md']);
  });

  test('recover deletes stale temp files but keeps a live one', () async {
    final File stale = File('${target().path}.nrs-tmp-999-0')
      ..writeAsStringSync('半截');
    stale.setLastModifiedSync(
      DateTime.now().subtract(const Duration(hours: 2)),
    );
    final File fresh = File('${target().path}.nrs-tmp-999-1')
      ..writeAsStringSync('另一个实例正在写');
    fresh.setLastModifiedSync(DateTime.now());

    await AtomicFileWriter().recover(root);

    expect(stale.existsSync(), isFalse, reason: '过期的残留要清掉');
    expect(
      fresh.existsSync(),
      isTrue,
      reason: '别的实例可能正在写,不能抢删',
    );
  });

  test('recovery reaches backups in sub-folders too', () async {
    final Directory folder = Directory(
      '${root.path}${Platform.pathSeparator}工作',
    )..createSync();
    File(
      '${folder.path}${Platform.pathSeparator}周报.md.nrs-bak',
    ).writeAsStringSync('正文');

    await AtomicFileWriter().recover(root);

    expect(
      File(
        '${folder.path}${Platform.pathSeparator}周报.md',
      ).readAsStringSync(),
      '正文',
    );
  });
}
