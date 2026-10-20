import 'dart:io';

/// Writes a file to a temporary sibling first, then commits it with a rename.
///
/// A note is one file, so a half-written file is a half-written note. Writing
/// in place leaves that window open on every autosave; [replace] reduces it to
/// a rename, which is the smallest window the file system offers.
///
/// The temporary and backup names end in `.nrs-tmp-*` / `.nrs-bak`, never in
/// `.md`, so the vault scanner cannot mistake a leftover for a note.
class AtomicFileWriter {
  AtomicFileWriter({
    Future<void> Function(File file, String contents)? writeTemp,
    this.forceBackupRotation = false,
  }) : _writeTemp = writeTemp ?? _writeAndFlush;

  final Future<void> Function(File file, String contents) _writeTemp;

  /// Exercises the backup-rotation branch even where rename can replace a file.
  /// It exists for the tests; production decides per platform by trying.
  final bool forceBackupRotation;

  static int _sequence = 0;

  String _tempPath(File target) =>
      '${target.path}.nrs-tmp-$pid-${_sequence++}';

  String _backupPath(File target) => '${target.path}.nrs-bak';

  static Future<void> _writeAndFlush(File file, String contents) =>
      file.writeAsString(contents, flush: true);

  /// Replaces [target] with [contents] without ever leaving it truncated.
  Future<void> replace(File target, String contents) async {
    await target.parent.create(recursive: true);
    final File temp = File(_tempPath(target));
    try {
      await _writeTemp(temp, contents);
      if (!forceBackupRotation) {
        try {
          await temp.rename(target.path);
          return;
        } on FileSystemException {
          // Some platforms (or a file locked by another process) refuse to
          // rename over an existing target. Rotate a backup instead.
        }
      }
      await _replaceViaBackup(temp, target);
    } catch (_) {
      await _deleteQuietly(temp);
      rethrow;
    }
  }

  Future<void> _replaceViaBackup(File temp, File target) async {
    final File backup = File(_backupPath(target));
    final bool hadTarget = await target.exists();
    if (hadTarget) {
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
    }
    try {
      await temp.rename(target.path);
    } catch (_) {
      // Put the old file back rather than leaving the user with nothing.
      if (hadTarget && await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  }

  /// Cleans up after a crash between the temporary write and the commit.
  ///
  /// A backup is only kept when its target vanished; a temporary file is only
  /// removed once it is old enough that no running instance can still own it.
  Future<void> recover(
    Directory vault, {
    Duration maxTempAge = const Duration(hours: 1),
  }) async {
    final DateTime now = DateTime.now();
    try {
      await for (final FileSystemEntity entity
          in vault.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final String path = entity.path;
        if (path.endsWith('.nrs-bak')) {
          final File target = File(
            path.substring(0, path.length - '.nrs-bak'.length),
          );
          try {
            if (await target.exists()) {
              await entity.delete();
            } else {
              await entity.rename(target.path);
            }
          } on FileSystemException {
            // Read-only or locked: leave it for the next start rather than
            // turning a note into an error dialog.
          }
          continue;
        }
        if (!path.contains('.nrs-tmp-')) continue;
        try {
          final FileStat stat = await entity.stat();
          if (now.difference(stat.modified) > maxTempAge) {
            await entity.delete();
          }
        } on FileSystemException {
          // Gone already, or not ours to delete.
        }
      }
    } on FileSystemException {
      // A vault that disappears mid-scan is a fresh install, not a failure.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Best effort; the original error is the one worth reporting.
    }
  }
}
