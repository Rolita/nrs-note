import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';
import 'note_store.dart';

/// Desktop version history: timestamped raw snapshots under `.nrs-history/`.
///
/// Snapshots are grouped by a stable hash of `note.id`, so renaming or moving a
/// note keeps its history attached. The raw `.md` is stored, which makes a
/// restore a content swap rather than a lossy re-serialisation.
class HistoryStore {
  HistoryStore(
    this._vault, {
    AtomicFileWriter? writer,
    DateTime Function()? clock,
    this.minInterval = defaultMinInterval,
    this.retention = defaultRetention,
    this.maxVersions = defaultMaxVersions,
  }) : _writer = writer ?? AtomicFileWriter(),
       _now = clock ?? DateTime.now;

  static const String dirName = '.nrs-history';
  static const Duration defaultMinInterval = Duration(minutes: 10);
  static const Duration defaultRetention = Duration(days: 180);
  static const int defaultMaxVersions = 100;

  final Directory _vault;
  final AtomicFileWriter _writer;
  final DateTime Function() _now;

  /// Minimum gap between automatic snapshots of one note.
  final Duration minInterval;

  /// Snapshots older than this are pruned.
  final Duration retention;

  /// Hard cap per note; the oldest versions beyond it are pruned.
  final int maxVersions;

  /// Avoids a directory scan on every autosave. Null means "no snapshot yet".
  final Map<String, DateTime?> _newestAt = <String, DateTime?>{};

  Directory get root =>
      Directory('${_vault.path}${Platform.pathSeparator}$dirName');

  String _sep() => Platform.pathSeparator;

  String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

  Directory _dirFor(String noteId) =>
      Directory('${root.path}${_sep()}${_keyFor(noteId)}');

  /// True when a save is allowed to snapshot, judged from the newest filename
  /// alone so the caller can skip reading the old file inside the interval.
  Future<bool> shouldCapture(String noteId) async {
    if (noteId.isEmpty) return false;
    if (minInterval <= Duration.zero) return true;
    final DateTime? newest = await _newestTime(noteId);
    if (newest == null) return true;
    return _now().toUtc().difference(newest) >= minInterval;
  }

  Future<DateTime?> _newestTime(String noteId) async {
    if (_newestAt.containsKey(noteId)) return _newestAt[noteId];
    final List<_Snapshot> versions = await _versions(noteId);
    final DateTime? newest = versions.isEmpty ? null : versions.last.capturedAt;
    _newestAt[noteId] = newest;
    return newest;
  }

  /// Writes [content] as a new snapshot.
  ///
  /// [force] bypasses [minInterval] but not the content dedupe. Failures are
  /// swallowed: history is a safety net, not a reason to fail a save.
  Future<bool> capture(
    String noteId,
    String content, {
    bool force = false,
  }) async {
    if (noteId.isEmpty) return false;
    try {
      if (!force && !await shouldCapture(noteId)) return false;
      final List<_Snapshot> versions = await _versions(noteId);
      if (versions.isNotEmpty) {
        final String newest = await versions.last.file.readAsString();
        if (newest == content) {
          _newestAt[noteId] = versions.last.capturedAt;
          return false;
        }
      }
      final DateTime now = _now().toUtc();
      int micros = now.microsecondsSinceEpoch;
      if (versions.isNotEmpty &&
          micros <= versions.last.capturedAt.microsecondsSinceEpoch) {
        micros = versions.last.capturedAt.microsecondsSinceEpoch + 1;
      }
      final Directory dir = _dirFor(noteId);
      await dir.create(recursive: true);
      await _writer.replace(File('${dir.path}${_sep()}$micros.md'), content);
      _newestAt[noteId] = DateTime.fromMicrosecondsSinceEpoch(
        micros,
        isUtc: true,
      );
      await _prune(noteId);
      return true;
    } catch (_) {
      _newestAt.remove(noteId);
      return false;
    }
  }

  /// Snapshots for [noteId], newest first, pruned to the current limits.
  Future<List<NoteVersion>> list(String noteId) async {
    if (noteId.isEmpty) return const <NoteVersion>[];
    final List<_Snapshot> versions = await _prune(noteId);
    return <NoteVersion>[
      for (final _Snapshot version in versions.reversed)
        NoteVersion(
          id: version.id,
          capturedAt: version.capturedAt.toLocal(),
          size: version.size,
        ),
    ];
  }

  /// Raw contents of one snapshot, or null when the id is invalid/missing.
  Future<String?> read(String noteId, String versionId) async {
    if (noteId.isEmpty || !RegExp(r'^\d+$').hasMatch(versionId)) return null;
    final File file = File(
      '${_dirFor(noteId).path}${_sep()}$versionId.md',
    );
    try {
      if (!await file.exists()) return null;
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  Future<List<_Snapshot>> _versions(String noteId) async {
    final Directory dir = _dirFor(noteId);
    if (!await dir.exists()) return const <_Snapshot>[];
    final List<_Snapshot> found = <_Snapshot>[];
    try {
      await for (final FileSystemEntity entity
          in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final String name = _baseName(entity.path);
        final int? micros = _parseMicros(name);
        if (micros == null) continue;
        int size = 0;
        try {
          size = await entity.length();
        } on FileSystemException {
          // A size is not worth losing the whole list over.
        }
        found.add(
          _Snapshot(
            capturedAt: DateTime.fromMicrosecondsSinceEpoch(
              micros,
              isUtc: true,
            ),
            id: name.substring(0, name.length - 3),
            file: entity,
            size: size,
          ),
        );
      }
    } on FileSystemException {
      return const <_Snapshot>[];
    }
    found.sort(
      (_Snapshot a, _Snapshot b) => a.capturedAt.compareTo(b.capturedAt),
    );
    return found;
  }

  /// Deletes versions beyond [maxVersions] or older than [retention], then
  /// returns what is left in oldest-first order.
  Future<List<_Snapshot>> _prune(String noteId) async {
    final List<_Snapshot> versions = await _versions(noteId);
    if (versions.isEmpty) {
      _newestAt[noteId] = null;
      return versions;
    }
    final DateTime cutoff = _now().toUtc().subtract(retention);
    final int firstKept = versions.length > maxVersions
        ? versions.length - maxVersions
        : 0;
    final List<_Snapshot> kept = <_Snapshot>[];
    for (int i = 0; i < versions.length; i++) {
      final _Snapshot version = versions[i];
      final bool tooOld = version.capturedAt.isBefore(cutoff);
      if (i < firstKept || tooOld) {
        try {
          await version.file.delete();
        } on FileSystemException {
          // Locked: it will be retried on the next prune.
        }
      } else {
        kept.add(version);
      }
    }
    _newestAt[noteId] = kept.isEmpty ? null : kept.last.capturedAt;
    return kept;
  }

  int? _parseMicros(String name) {
    final String lower = name.toLowerCase();
    if (!lower.endsWith('.md')) return null;
    final String stem = name.substring(0, name.length - 3);
    if (!RegExp(r'^\d+$').hasMatch(stem)) return null;
    return int.tryParse(stem);
  }

  /// Two independent 32-bit FNV-style passes give a path-safe, stable key for
  /// ids that may come from another editor and contain any character.
  String _keyFor(String noteId) {
    int a = 0x811c9dc5;
    int b = 0x9e3779b9;
    for (final int byte in utf8.encode(noteId)) {
      a = ((a ^ byte) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ byte) * 0x85EBCA6B) & 0xFFFFFFFF;
    }
    return a.toRadixString(16).padLeft(8, '0') +
        b.toRadixString(16).padLeft(8, '0');
  }
}

class _Snapshot {
  const _Snapshot({
    required this.capturedAt,
    required this.id,
    required this.file,
    required this.size,
  });

  final DateTime capturedAt;
  final String id;
  final File file;
  final int size;
}
