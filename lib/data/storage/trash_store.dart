import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/utils/canvas_document.dart' show canvasExtension;
import '../models/note.dart';
import 'canvas_store.dart' show canvasTitleOf;
import 'note_store.dart';

/// A trashed note with its contents, ready to be written back.
class TrashRecord {
  const TrashRecord({
    required this.entry,
    required this.markdown,
    required this.fileName,
  });

  final TrashEntry entry;
  final String markdown;
  final String fileName;
}

/// Desktop trash: one directory per deleted note under `.nrs-trash/`.
///
/// The metadata is written *before* the note file is moved in. A crash between
/// the two leaves the note at its original path plus an empty entry, never a
/// note that exists only in a half-described trash.
class TrashStore {
  TrashStore(this._vault, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  static const String dirName = '.nrs-trash';
  static const String _metaName = 'meta.json';

  final Directory _vault;
  final DateTime Function() _now;
  final Random _random = Random();

  Directory get root =>
      Directory('${_vault.path}${Platform.pathSeparator}$dirName');

  String _sep() => Platform.pathSeparator;

  String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  /// 条目在回收站里显示的名字：去掉后缀。
  ///
  /// 笔记是 `.md`，白板是 `.nrs`，两者在同一个回收站里并排——名字里留着
  /// 后缀，读起来像两种不同的东西，而它们对用户来说都是「我删掉的那份」。
  static String _titleOf(String fileName) {
    final String lower = fileName.toLowerCase();
    if (lower.endsWith(canvasExtension)) return canvasTitleOf(fileName);
    return Note.titleOfFileName(fileName);
  }

  String _normalizeRelative(String raw) =>
      raw.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');

  Future<TrashEntry?> move(File source, String relativePath) async {
    if (!await source.exists()) return null;
    final String originalPath = _normalizeRelative(relativePath);
    final String fileName = _baseName(originalPath);
    final DateTime now = _now().toUtc();
    final Directory dir = await _newEntryDir(now);
    final String contentPath = '${dir.path}${_sep()}$fileName';
    final File meta = File('${dir.path}${_sep()}$_metaName');
    try {
      await meta.writeAsString(
        jsonEncode(<String, Object?>{
          'schema': 1,
          'originalPath': originalPath,
          'deletedAt': now.toIso8601String(),
        }),
        flush: true,
      );
      await source.rename(contentPath);
    } catch (_) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // Best effort: the note itself is untouched because the move failed.
      }
      rethrow;
    }
    int size = 0;
    try {
      size = await File(contentPath).length();
    } on FileSystemException {
      // A size is only for display; the entry is still valid without it.
    }
    return TrashEntry(
      id: _baseName(dir.path),
      originalPath: originalPath,
      title: _titleOf(fileName),
      deletedAt: now,
      size: size,
    );
  }

  Future<Directory> _newEntryDir(DateTime now) async {
    for (int attempt = 0; attempt < 20; attempt++) {
      final String id =
          '${now.microsecondsSinceEpoch.toRadixString(36)}-'
          '${_random.nextInt(1 << 24).toRadixString(36).padLeft(5, '0')}';
      final Directory dir = Directory('${root.path}${_sep()}$id');
      if (await dir.exists()) continue;
      await dir.create(recursive: true);
      return dir;
    }
    throw FileSystemException('无法创建回收站条目', root.path);
  }

  Future<List<TrashEntry>> list() async {
    final Directory dir = root;
    if (!await dir.exists()) return const <TrashEntry>[];
    final List<TrashEntry> entries = <TrashEntry>[];
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        try {
          final TrashRecord? record = await _readEntry(entity);
          if (record != null) entries.add(record.entry);
        } on FileSystemException {
          // One unreadable entry must not hide the rest.
        }
      }
    } on FileSystemException {
      return const <TrashEntry>[];
    }
    entries.sort((TrashEntry a, TrashEntry b) {
      final int byTime = b.deletedAt.compareTo(a.deletedAt);
      return byTime != 0 ? byTime : b.id.compareTo(a.id);
    });
    return entries;
  }

  Future<TrashRecord?> read(String entryId) async {
    final Directory? dir = _dirFor(entryId);
    if (dir == null) return null;
    try {
      if (!await dir.exists()) return null;
      final TrashRecord? entry = await _readEntry(dir, withContent: true);
      return entry;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> purge(String entryId) async {
    final Directory? dir = _dirFor(entryId);
    if (dir == null) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Already gone, or not ours to delete.
    }
  }

  Future<void> empty() async {
    final Directory dir = root;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Best effort; the next delete recreates it.
    }
  }

  /// Removes entries left half-created by a crash.
  ///
  /// Only metadata-only directories old enough that no live delete could still
  /// own them are removed; an entry with content is always kept.
  Future<void> cleanupResidue({
    Duration maxAge = const Duration(hours: 1),
  }) async {
    final Directory dir = root;
    if (!await dir.exists()) return;
    final DateTime cutoff = _now().toUtc().subtract(maxAge);
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        try {
          if (await _findContent(entity) != null) continue;
          final FileStat stat = await entity.stat();
          if (stat.modified.toUtc().isBefore(cutoff)) {
            await entity.delete(recursive: true);
          }
        } on FileSystemException {
          // Leave it for the next start.
        }
      }
    } on FileSystemException {
      // A missing trash directory is simply an empty one.
    }
  }

  Directory? _dirFor(String entryId) {
    if (entryId.isEmpty ||
        entryId == '.' ||
        entryId == '..' ||
        entryId.contains('/') ||
        entryId.contains('\\')) {
      return null;
    }
    return Directory('${root.path}${_sep()}$entryId');
  }

  Future<TrashRecord?> _readEntry(
    Directory dir, {
    bool withContent = false,
  }) async {
    final Map<String, Object?>? meta = await _readMeta(dir);
    final String? original = _string(meta?['originalPath']);
    final File? content = await _findContent(
      dir,
      preferredName: original == null ? null : _baseName(original),
    );
    if (content == null) return null;

    final String contentName = _baseName(content.path);
    final String originalPath = original == null || original.trim().isEmpty
        ? contentName
        : _normalizeRelative(original);
    final String fileName = _baseName(originalPath);
    final DateTime deletedAt =
        _parseDate(meta?['deletedAt']) ??
        (await dir.stat()).modified.toUtc();
    int size = 0;
    try {
      size = await content.length();
    } on FileSystemException {
      // Display-only.
    }
    final TrashEntry entry = TrashEntry(
      id: _baseName(dir.path),
      originalPath: originalPath,
      title: _titleOf(fileName),
      deletedAt: deletedAt,
      size: size,
    );
    if (!withContent) {
      return TrashRecord(entry: entry, markdown: '', fileName: fileName);
    }
    final String markdown = await content.readAsString();
    return TrashRecord(entry: entry, markdown: markdown, fileName: fileName);
  }

  Future<Map<String, Object?>?> _readMeta(Directory dir) async {
    final File meta = File('${dir.path}${_sep()}$_metaName');
    try {
      if (!await meta.exists()) return null;
      final Object? decoded = jsonDecode(await meta.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The file holding the note. Prefers the name recorded in meta, then any
  /// `.md`, then anything that is not `meta.json` or a writer leftover.
  Future<File?> _findContent(
    Directory dir, {
    String? preferredName,
  }) async {
    final List<File> files = <File>[];
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final String name = _baseName(entity.path);
        if (name == _metaName) continue;
        if (name.endsWith('.nrs-bak') || name.contains('.nrs-tmp-')) continue;
        files.add(entity);
      }
    } on FileSystemException {
      return null;
    }
    if (files.isEmpty) return null;
    files.sort(
      (File a, File b) =>
          _baseName(a.path).toLowerCase().compareTo(_baseName(b.path).toLowerCase()),
    );
    if (preferredName != null && preferredName.isNotEmpty) {
      for (final File file in files) {
        if (_baseName(file.path).toLowerCase() ==
            preferredName.toLowerCase()) {
          return file;
        }
      }
    }
    for (final File file in files) {
      if (_baseName(file.path).toLowerCase().endsWith('.md')) return file;
    }
    return files.first;
  }

  String? _string(Object? value) => value is String ? value : null;

  DateTime? _parseDate(Object? value) {
    if (value is! String) return null;
    return DateTime.tryParse(value)?.toUtc();
  }
}
