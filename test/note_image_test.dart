import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/storage/note_store_io.dart';

/// `assetPath` is the only gate between a note's Markdown and the file system:
/// everything it returns is handed to `FileImage`. It must accept the relative
/// references NRS writes and nothing that can leave the vault.
void main() {
  late Directory root;
  late IoNoteStore store;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('nrs-assets-');
    store = IoNoteStore(overrideRoot: root);
    await store.init();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String inside(List<String> parts) =>
      <String>[store.vault.path, ...parts].join(Platform.pathSeparator);

  test('resolves a relative reference against the note folder', () {
    expect(
      store.assetPath('项目/计划', 'assets/x.png'),
      inside(<String>['项目', '计划', 'assets', 'x.png']),
    );
    expect(
      store.assetPath('', 'assets/x.png'),
      inside(<String>['assets', 'x.png']),
    );
  });

  test('decodes percent-escaped characters', () {
    expect(
      store.assetPath('a b', 'assets/x%20y.png'),
      inside(<String>['a b', 'assets', 'x y.png']),
    );
  });

  test('accepts backslashes between path segments', () {
    expect(
      store.assetPath('', r'assets\sub\x.png'),
      inside(<String>['assets', 'sub', 'x.png']),
    );
  });

  test('rejects remote sources', () {
    for (final String source in <String>[
      'https://example.com/x.png',
      'HTTP://example.com/x.png',
      'http://example.com/x.png',
      'data:image/png;base64,AAAA',
    ]) {
      expect(store.assetPath('', source), isNull, reason: source);
    }
  });

  test('rejects absolute paths', () {
    for (final String source in <String>[
      '/etc/passwd',
      r'C:\Windows\x.png',
      r'\\server\share\x.png',
      '%2Fetc%2Fpasswd',
    ]) {
      expect(store.assetPath('', source), isNull, reason: source);
    }
  });

  test('rejects any path that climbs out of the note folder', () {
    for (final String source in <String>[
      '../x.png',
      'assets/../../x.png',
      '%2e%2e/x.png',
      'assets/%2E%2E/%2E%2E/x.png',
      r'..\x.png',
    ]) {
      expect(store.assetPath('', source), isNull, reason: source);
    }
  });

  test('rejects an unreadable escape and an empty source', () {
    expect(store.assetPath('', '%zz/x.png'), isNull);
    expect(store.assetPath('', ''), isNull);
    expect(store.assetPath('', '   '), isNull);
  });
}
