import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import 'atomic_file.dart';
import 'history_store.dart';
import 'note_store.dart';
import 'trash_store.dart';

/// 一个文件从盘上读出来的原始内容。
typedef _RawFile = ({
  String path,
  String raw,
  DateTime modified,
  int size,
});

/// Desktop implementation: one real `.md` file per note inside a vault folder
/// the user can open in Explorer / Finder.
///
/// Folders in the tree are real directories, not a label stored in the file.
/// Moving a note by hand therefore moves it in the app, and an empty directory
/// the user made is still visible after a restart.
class IoNoteStore with NoteStoreSupport implements NoteStore {
  IoNoteStore({
    this.folderName = 'NRS Notes',
    this.overrideRoot,
    AtomicFileWriter? writer,
    DateTime Function()? clock,
    this.historyMinInterval = HistoryStore.defaultMinInterval,
  }) : _writer = writer ?? AtomicFileWriter(),
       _clock = clock ?? DateTime.now;

  final String folderName;
  final Directory? overrideRoot;
  final AtomicFileWriter _writer;
  final DateTime Function() _clock;

  /// Exposed for tests; production uses the ten-minute default.
  final Duration historyMinInterval;

  TrashStore? _trash;
  HistoryStore? _history;

  /// 后台进行的回收站打扫。
  ///
  /// 启动时不 await 它（见 [init]），只有在要判断「这是不是一次全新安装」
  /// 时才等——那条路径上「回收站里有没有东西」必须等打扫完才准。
  Future<void> _residueCleanup = Future<void>.value();

  TrashStore get _trashStore =>
      _trash ??= TrashStore(vault, clock: _clock);

  HistoryStore get _historyStore => _history ??= HistoryStore(
    vault,
    clock: _clock,
    minInterval: historyMinInterval,
  );

  Directory? _vault;
  String _location = '';

  @override
  String get location => _location;

  @override
  bool get supportsNativeFiles => true;

  @override
  String? get vaultPath => _vault?.path;

  @override
  bool get supportsTrash => true;

  @override
  bool get supportsHistory => true;

  Directory get vault {
    final Directory? v = _vault;
    if (v == null) {
      throw StateError('IoNoteStore.init() must be awaited before use.');
    }
    return v;
  }

  @override
  Future<void> init() async {
    if (_vault != null) return;
    final Directory root =
        overrideRoot ?? await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${root.path}${Platform.pathSeparator}$folderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _vault = dir;
    _location = dir.path;

    // 回收站清理是纯打扫：它只动 `.nrs-trash`，和读笔记没有任何交集。让它
    // 在后台和 `loadAll()` 并行跑，不要挡在启动路径上——回收站里攒了几十条
    // 时这一项就是几十毫秒，而它晚几百毫秒做完没有任何区别。
    _residueCleanup = _trashStore
        .cleanupResidue()
        .catchError((Object _) {
          // 清不动的回收站照样可读，不值得让启动失败。
        });

    // 崩溃残骸（`.nrs-bak` / `.nrs-tmp-*`）由下面这次遍历顺手收拾：必须先
    // 收完再判断「库是不是空的」，否则恢复出来的笔记不算数，欢迎笔记会盖
    // 在它上面。
    final List<File> existing = await _mdFiles();
    if (existing.isEmpty) {
      bool trashEmpty = true;
      try {
        // 全新安装的判断要看**打扫之后**的回收站：残骸不算「里面有东西」。
        await _residueCleanup;
        trashEmpty = (await _trashStore.list()).isEmpty;
      } on FileSystemException {
        // Unknown trash contents are not evidence of a fresh install.
        trashEmpty = false;
      }
      if (trashEmpty) {
        final Note welcome = Note.welcome();
        await _writer.replace(
          File(_pathFor(welcome.relativePath)),
          welcome.toMarkdown(),
        );
        // 刚才那次「库是不是空的」用的是遍历缓存，现在库里多了一篇，
        // 不清掉的话紧接着的 loadAll() 会拿到空清单。
        invalidateScan();
      }
    }
  }

  /// 上一次遍历的结果。
  ///
  /// `refresh()` 会连着要「文件清单 / 全部笔记 / 文件夹清单」三份东西，
  /// 各自走一遍 vault 就是三次完整递归——859 篇的库光走目录就要 200ms
  /// 上下，白扔。
  ///
  /// 只在**同一次刷新**里复用：任何写操作都会立刻 [invalidateScan]，
  /// 所以界面不会看到一个旧的文件清单。
  ({List<File> files, List<Directory> dirs})? _scan;

  /// 丢掉遍历缓存。写盘、删除、建目录之后必须调——否则下一次刷新会拿到
  /// 一份「还没有这个文件」的清单，笔记看起来像是没保存。
  void invalidateScan() {
    _scan = null;
    _stampsCache = null;
  }

  Future<({List<File> files, List<Directory> dirs})> _scanVault() async {
    final ({List<File> files, List<Directory> dirs})? cached = _scan;
    if (cached != null) return cached;
    final List<File> files = <File>[];
    final List<Directory> dirs = <Directory>[];
    try {
      // 顺手把崩溃残骸收拾掉：这一遍递归本来就要 `list` 每个目录，让
      // `recover` 再走一遍等于把八百多次 `list` 做两次。恢复出来的文件
      // 直接进清单——它现在就是一篇正式笔记。
      await _walk(vault, files: files, dirs: dirs, recover: DateTime.now());
    } on FileSystemException {
      // 一个读不了的子目录不该藏起整个库。
    }
    final ({List<File> files, List<Directory> dirs}) scan = (
      files: files,
      dirs: dirs,
    );
    _scan = scan;
    return scan;
  }

  Future<List<File>> _mdFiles() async => (await _scanVault()).files;

  /// 开 [readConcurrency] 条并发把 [count] 件事做完。
  ///
  /// 单文件读盘是 0.5~1ms 的延迟型开销，串行做八百多次就是一秒；并发跑只是
  /// 把等待叠在一起，不增加任何 CPU 工作。条数不能再高：Windows 上同时开
  /// 几十个句柄反而会因为杀毒软件逐个扫描而变慢。
  Future<void> _forEachConcurrently(
    int count,
    Future<void> Function(int index) body,
  ) async {
    if (count == 0) return;
    int next = 0;
    Future<void> worker() async {
      while (true) {
        final int i = next++;
        if (i >= count) return;
        await body(i);
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < readConcurrency; i++) worker(),
    ]);
  }

  /// 读盘并发度。
  static const int readConcurrency = 16;

  /// [loadAll] 顺手攒下来的指纹。
  ///
  /// 启动时 `refresh()` 先要 `stamps()` 再要 `loadAll()`，两者都要对每个
  /// 文件 stat 一次——八百多篇就是八百多次重复的 open/close。读正文的时候
  /// 反正已经开过句柄了，把 `stat` 的结果留下来，`stamps()` 直接取。
  List<NoteFileStamp>? _stampsCache;

  /// 老命名 `<slug>-<6 位 id>.md` 的识别正则。
  ///
  /// 提成 static：它在 [loadAll] 里对每一篇笔记都要跑，八百多篇每次现编一个
  /// 正则，光编译就是白白的一笔开销。
  static final RegExp _legacyStem = RegExp(r'^(.+)-([0-9a-z]{6})$');
  static final RegExp _mdSuffix = RegExp(r'\.md$', caseSensitive: false);

  /// Walks the vault without descending into the app's own bookkeeping
  /// directories. Their `.md` files are snapshots, not notes.
  ///
  /// 传了 [recover] 就在这一遍里把 `.nrs-bak` / `.nrs-tmp-*` 收拾掉（[recover]
  /// 是「现在几点」，整遍共用一个时刻）。
  Future<void> _walk(
    Directory dir, {
    List<File>? files,
    List<Directory>? dirs,
    DateTime? recover,
  }) async {
    try {
      await for (final FileSystemEntity entity
          in dir.list(followLinks: false)) {
        if (entity is Directory) {
          if (_isInternalDirName(_baseName(entity.path))) continue;
          dirs?.add(entity);
          await _walk(entity, files: files, dirs: dirs, recover: recover);
        } else if (entity is File) {
          final String path = entity.path;
          if (recover != null && AtomicFileWriter.isRecoverable(path)) {
            final File? restored = await _writer.recoverFile(
              entity,
              now: recover,
            );
            if (restored != null &&
                files != null &&
                _mdSuffix.hasMatch(restored.path)) {
              files.add(restored);
            }
            continue;
          }
          if (files != null && _mdSuffix.hasMatch(path)) files.add(entity);
        }
      }
    } on FileSystemException {
      // One unreadable subtree must not hide the rest of the vault.
    }
  }

  bool _isInternalDirName(String name) {
    final String lower = name.toLowerCase();
    return lower == TrashStore.dirName || lower == HistoryStore.dirName;
  }

  /// `/`-separated path below the vault root, the form [Note.relativePath] uses.
  String _relativeOf(FileSystemEntity entity) => entity.path
      .substring(vault.path.length)
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'^/+'), '');

  String _pathFor(String relativePath) {
    final List<String> parts = relativePath
        .split('/')
        .where((String p) => p.isNotEmpty)
        .toList();
    return <String>[vault.path, ...parts].join(Platform.pathSeparator);
  }

  String _baseName(String fileName) => fileName.split(RegExp(r'[\\/]')).last;

  String _folderOf(String relativePath) {
    final int slash = relativePath.lastIndexOf('/');
    return slash < 0 ? '' : relativePath.substring(0, slash);
  }

  String _join(String folderPath, String fileName) {
    final String folder = Note.normalizeFolderPath(folderPath);
    return folder.isEmpty ? fileName : '$folder/$fileName';
  }

  @override
  Future<List<String>> listFolders() async {
    final List<Directory> found = (await _scanVault()).dirs;
    final List<String> folders = found
        .map(_relativeOf)
        .where((String p) => p.isNotEmpty)
        .where(
          (String p) => !p
              .split('/')
              .any((String segment) => segment.toLowerCase() == 'assets'),
        )
        .toList();
    folders.sort(
      (String a, String b) => a.toLowerCase().compareTo(b.toLowerCase()),
    );
    return folders;
  }

  @override
  Future<String> createFolder(String folderPath) async {
    invalidateScan();
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return '';
    await Directory(_pathFor(folder)).create(recursive: true);
    return folder;
  }

  @override
  Future<bool> renameFolder(String from, String to) async {
    invalidateScan();
    final String source = Note.normalizeFolderPath(from);
    final String target = Note.normalizeFolderPath(to);
    if (source.isEmpty || target.isEmpty || source == target) return false;
    final Directory sourceDir = Directory(_pathFor(source));
    if (!await sourceDir.exists()) return false;
    if (await Directory(_pathFor(target)).exists()) return false;
    try {
      await sourceDir.rename(_pathFor(target));
      return true;
    } on FileSystemException {
      // A folder in use, or a permission problem: report it rather than
      // pretending the rename happened.
      return false;
    }
  }

  @override
  Future<bool> folderHoldsOnlyNotes(
    String folderPath,
    Set<String> notePaths,
  ) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    if (_isInternalDirName(folder.split('/').first)) return false;
    final Directory dir = Directory(_pathFor(folder));
    if (!await dir.exists()) return false;
    final Set<String> known = <String>{
      for (final String path in notePaths)
        path.replaceAll('\\', '/').toLowerCase(),
    };
    return _holdsOnlyKnownNotes(dir, known);
  }

  /// Every file below [dir] has to be one of [known]. Links and unreadable
  /// entries count as unknown: they cannot be put in the note trash, so the
  /// folder stays.
  Future<bool> _holdsOnlyKnownNotes(Directory dir, Set<String> known) async {
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          // The app's own bookkeeping has no business inside a note folder, and
          // deleting it would take snapshots the trash cannot restore.
          if (_isInternalDirName(_baseName(entity.path))) return false;
          if (!await _holdsOnlyKnownNotes(entity, known)) return false;
        } else if (entity is File) {
          if (!known.contains(_relativeOf(entity).toLowerCase())) return false;
        } else {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<bool> deleteFolder(String folderPath) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (folder.isEmpty) return false;
    if (_isInternalDirName(folder.split('/').first)) return false;
    final Directory dir = Directory(_pathFor(folder));
    if (!await dir.exists()) return false;
    return _removeEmptyTree(dir);
  }

  /// Deletes [dir] only after every child directory is gone and no non-directory
  /// entry is left. The non-recursive delete is the final guard: if anything
  /// appeared while walking, the directory stays.
  Future<bool> _removeEmptyTree(Directory dir) async {
    try {
      await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
        if (entity is Directory) {
          if (!await _removeEmptyTree(entity)) return false;
        } else {
          return false;
        }
      }
      await dir.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<List<NoteFileStamp>> stamps() async {
    final List<NoteFileStamp>? cached = _stampsCache;
    if (cached != null) return cached;

    final List<File> files = await _mdFiles();
    final List<NoteFileStamp?> stamps = List<NoteFileStamp?>.filled(
      files.length,
      null,
    );
    await _forEachConcurrently(files.length, (int i) async {
      final File file = files[i];
      try {
        final FileStat stat = await file.stat();
        stamps[i] = NoteFileStamp(
          relativePath: _relativeOf(file),
          modifiedAt: stat.modified,
          size: stat.size,
        );
      } on FileSystemException {
        // Vanished mid-scan: it simply is not part of this snapshot.
      }
    });
    final List<NoteFileStamp> result = stamps
        .whereType<NoteFileStamp>()
        .toList();
    _stampsCache = result;
    return result;
  }

  @override
  Future<NoteFileStamp?> stampOf(String relativePath) async {
    final File file = File(_pathFor(relativePath.replaceAll('\\', '/')));
    try {
      if (!await file.exists()) return null;
      final FileStat stat = await file.stat();
      return NoteFileStamp(
        relativePath: _relativeOf(file),
        modifiedAt: stat.modified,
        size: stat.size,
      );
    } on FileSystemException {
      return null;
    }
  }

  /// 一个文件读出来的原始内容。
  ///
  /// 只是「盘上有什么」，还没变成 [Note]：解析放在主 isolate 里做，
  /// 因为那是纯计算，几十毫秒的量级，为它多传一趟数据不值。
  static Future<List<_RawFile>> _readChunk(List<String> paths) {
    return Isolate.run(() async {
      final List<_RawFile> out = <_RawFile>[];
      for (final String path in paths) {
        try {
          final File f = File(path);
          final List<Object> both = await Future.wait(<Future<Object>>[
            f.readAsString(),
            f.stat(),
          ]);
          final FileStat stat = both[1] as FileStat;
          out.add((
            path: path,
            raw: both[0] as String,
            modified: stat.modified,
            size: stat.size,
          ));
        } on FileSystemException {
          // 一个文件读不了不该带走整批。
        }
      }
      return out;
    });
  }

  /// 把文件摊成 [chunkCount] 份。
  static List<List<String>> _split(List<File> files, int chunkCount) {
    final List<List<String>> batches = <List<String>>[
      for (int i = 0; i < chunkCount; i++) <String>[],
    ];
    for (int i = 0; i < files.length; i++) {
      batches[i % chunkCount].add(files[i].path);
    }
    return batches;
  }

  /// 读正文用的 isolate 数。
  ///
  /// 不能只靠「多开几个 Future」：`dart:io` 的文件操作走一个很小的线程池，
  /// 实测并发 16 也只比串行快一倍半，剩下的全在排队。开 isolate 才是真并行
  /// ——859 篇从 400ms 降到 60ms 量级。
  static const int readIsolates = 4;

  /// 文件少于这个数就不值得开 isolate（启动一个 isolate 本身要一两毫秒）。
  static const int isolateThreshold = 40;

  @override
  Future<List<Note>> loadAll() async {
    final List<File> files = await _mdFiles();
    if (files.isEmpty) {
      _stampsCache = const <NoteFileStamp>[];
      return const <Note>[];
    }

    final List<_RawFile> raws;
    if (files.length < isolateThreshold) {
      // 小库直接读：isolate 的启动开销比省下的时间还多。
      raws = await _readChunk(<String>[for (final File f in files) f.path]);
    } else {
      final int chunks = math.min(readIsolates, files.length);
      final List<List<_RawFile>> parts = await Future.wait(
        <Future<List<_RawFile>>>[
          for (final List<String> b in _split(files, chunks)) _readChunk(b),
        ],
      );
      raws = <_RawFile>[for (final List<_RawFile> p in parts) ...p];
    }

    final List<Note> notes = <Note>[];
    final List<NoteFileStamp> stamps = <NoteFileStamp>[];
    for (final _RawFile raw in raws) {
      final File file = File(raw.path);
      final String relative = _relativeOf(file);
      final String folder = _folderOf(relative);
      final String name = _baseName(relative);
      final String fileName = await _migrateLegacyName(
        file,
        name,
        folder,
        raw.raw,
      );
      notes.add(
        Note.fromMarkdown(
          raw.raw,
          fileName,
          raw.modified,
          folderPath: folder,
        ),
      );
      // 顺手把指纹攒下来：`stamps()` 紧接着就会被调用，它要的是同一批
      // 数据，再 stat 一遍纯属重复。
      stamps.add(
        NoteFileStamp(
          relativePath: relative,
          modifiedAt: raw.modified,
          size: raw.size,
        ),
      );
    }
    _stampsCache = stamps;
    return sortNotes(notes);
  }

  /// Renames a file written by the old `<title>-<id>.md` scheme to `<title>.md`,
  /// inside its own folder.
  ///
  /// NRS used to hide a short id in the file name to keep names unique. The
  /// file name is now the note's name, so that suffix is not just noise — it
  /// would show up *in the title*. The migration is deliberately conservative:
  /// it only fires when the stem is exactly `<slug>-<6 chars>` **and** the slug
  /// is the slug of the note's own title, i.e. a file this app named itself.
  /// Anything the user renamed by hand is left alone, as is any target that is
  /// already taken in that folder.
  Future<String> _migrateLegacyName(
    File file,
    String fileName,
    String folderPath,
    String raw,
  ) async {
    final String stem = fileName.replaceAll(_mdSuffix, '');
    final Match? m = _legacyStem.firstMatch(stem);
    if (m == null) return fileName;
    final String title = Note.splitFrontMatter(raw).meta['title'] ?? '';
    if (title.trim().isEmpty) return fileName;
    final String slug = Note.slugify(title);
    if (slug.isEmpty || slug != m.group(1)) return fileName;
    final String target = '$slug.md';
    final String targetPath = _pathFor(_join(folderPath, target));
    if (await File(targetPath).exists()) return fileName;
    try {
      await file.rename(targetPath);
      return target;
    } on FileSystemException {
      // Read-only folder, or the name is taken in another case. Keep the old
      // name: it still opens, and the title simply carries the suffix.
      return fileName;
    }
  }

  @override
  Future<String?> saveAsset(
    String folderPath,
    String fileName,
    Uint8List bytes,
  ) async {
    if (_vault == null) await init();
    final String folder = Note.normalizeFolderPath(folderPath);
    final String assetsRel = folder.isEmpty ? 'assets' : '$folder/assets';
    final Directory dir = Directory(_pathFor(assetsRel));
    await dir.create(recursive: true);

    String base = _baseName(fileName.trim());
    base = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
    base = base.replaceAll('..', '_');
    String stem = base
        .replaceAll(RegExp(r'\.png$', caseSensitive: false), '')
        .trim();
    if (stem.isEmpty || stem == '.') stem = 'image';

    final String candidate = await _freeAssetName(dir, stem);
    final File target = File('${dir.path}${Platform.pathSeparator}$candidate');
    // The same temp-then-rename rule the note writer uses: a crash leaves a
    // `.tmp` beside the picture, never a half-written PNG the editor will read.
    final File temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
    return 'assets/$candidate';
  }

  Future<String> _freeAssetName(Directory dir, String stem) async {
    String candidate = '$stem.png';
    for (int i = 2; i < 1000; i++) {
      final File file = File('${dir.path}${Platform.pathSeparator}$candidate');
      if (!await file.exists()) return candidate;
      candidate = '${stem}_$i.png';
    }
    return '${stem}_${DateTime.now().microsecondsSinceEpoch}.png';
  }

  @override
  String? assetPath(String folderPath, String source) {
    final Directory? root = _vault;
    if (root == null) return null;
    final String raw = source.trim();
    if (raw.isEmpty) return null;
    final String lower = raw.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:')) {
      return null;
    }
    if (raw.startsWith('/') ||
        raw.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:').hasMatch(raw)) {
      return null;
    }

    String decoded;
    try {
      decoded = Uri.decodeComponent(raw);
    } on ArgumentError {
      return null;
    }
    decoded = decoded.replaceAll('\\', '/');
    if (decoded.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(decoded)) {
      return null;
    }
    if (decoded.split('/').any((String part) => part == '..')) return null;

    final String relative = _join(
      Note.normalizeFolderPath(folderPath),
      decoded,
    );
    final String absolute = _pathFor(relative);
    final String vaultPrefix = '${root.path}${Platform.pathSeparator}'
        .toLowerCase();
    if (!absolute.toLowerCase().startsWith(vaultPrefix)) return null;
    return absolute;
  }

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    invalidateScan();
    final String folder = Note.normalizeFolderPath(note.folderPath);
    final String targetName = _baseName(note.fileName);
    final String target = _join(folder, targetName);
    final File targetFile = File(_pathFor(target));
    await targetFile.parent.create(recursive: true);

    final String contents = note.toMarkdown();
    final String? previousRelative = previousPath?.replaceAll('\\', '/');
    final bool samePath =
        previousRelative != null &&
        previousRelative.toLowerCase() == target.toLowerCase();
    if (samePath) {
      await _captureBeforeWrite(note, targetFile, contents);
      await _writer.replace(targetFile, contents);
      return;
    }

    // A different name means this save is a rename or a move. If something
    // already sits on the target name, it is not ours to write over: the
    // controller resolves the clash with the same ` 2` rule it uses in memory.
    if (await targetFile.exists()) {
      throw NotePathTaken(target);
    }

    final File? previousFile = previousRelative == null
        ? null
        : File(_pathFor(previousRelative));
    final bool hadPrevious =
        previousFile != null && await previousFile.exists();

    if (hadPrevious) {
      // Land the new contents on the file we own, then move that file. A crash
      // between the two leaves the note saved under its old name — never two
      // copies of the same note on disk.
      await _captureBeforeWrite(note, previousFile, contents);
      await _writer.replace(previousFile, contents);
      try {
        await previousFile.rename(targetFile.path);
        return;
      } on FileSystemException {
        // Renaming can fail across volumes, or because the name appeared in
        // the meantime. The check below tells the two apart.
      }
      if (await targetFile.exists()) {
        throw NotePathTaken(target);
      }
    }

    await _writer.replace(targetFile, contents);
    if (hadPrevious) await _deleteQuietly(previousRelative!);
  }

  /// Keeps the content that is about to be overwritten.
  ///
  /// The interval check comes before the file read, so ordinary autosaves pay
  /// nothing once a snapshot exists. Pure renames and moves are skipped by
  /// comparing bodies: the front matter's `updated` changes on every save, but
  /// the prose did not.
  Future<void> _captureBeforeWrite(
    Note note,
    File file,
    String next,
  ) async {
    try {
      if (!await _historyStore.shouldCapture(note.id)) return;
      if (!await file.exists()) return;
      final String previous = await file.readAsString();
      if (Note.splitFrontMatter(previous).body ==
          Note.splitFrontMatter(next).body) {
        return;
      }
      await _historyStore.capture(note.id, previous);
    } catch (_) {
      // A history snapshot must never take a save down with it.
    }
  }

  @override
  Future<TrashEntry?> delete(Note note) async {
    invalidateScan();
    final File file = File(_pathFor(note.relativePath));
    if (!await file.exists()) return null;
    return _trashStore.move(file, note.relativePath);
  }

  @override
  Future<List<TrashEntry>> listTrash() async {
    if (_vault == null) await init();
    return _trashStore.list();
  }

  @override
  Future<Note?> restoreTrash(String entryId) async {
    if (_vault == null) await init();
    final TrashRecord? record = await _trashStore.read(entryId);
    if (record == null) return null;
    final ({String folder, String fileName}) path = _restorePath(record);
    final Note note = await writeNewMarkdown(
      record.markdown,
      path.fileName,
      folderPath: path.folder,
    );
    await _trashStore.purge(entryId);
    return note;
  }

  @override
  Future<void> purgeTrash(String entryId) async {
    if (_vault == null) return;
    await _trashStore.purge(entryId);
  }

  @override
  Future<void> emptyTrash() async {
    if (_vault == null) return;
    await _trashStore.empty();
  }

  /// Turns untrusted metadata back into a path inside the vault. An absolute
  /// path, a drive letter or `..` can never make the restore escape the vault.
  ({String folder, String fileName}) _restorePath(TrashRecord record) {
    final List<String> parts = record.entry.originalPath
        .replaceAll('\\', '/')
        .split('/')
        .map((String part) => part.trim())
        .where(
          (String part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              !part.contains(':'),
        )
        .toList();
    String fileName = parts.isEmpty ? '' : parts.removeLast();
    if (fileName.isEmpty) fileName = record.fileName;
    fileName = _baseName(fileName);
    if (fileName.isEmpty) fileName = '未命名.md';
    if (!fileName.toLowerCase().endsWith('.md')) fileName = '$fileName.md';
    return (
      folder: Note.normalizeFolderPath(parts.join('/')),
      fileName: fileName,
    );
  }

  @override
  Future<List<NoteVersion>> historyOf(Note note) async {
    if (_vault == null) await init();
    return _historyStore.list(note.id);
  }

  @override
  Future<String?> readVersion(Note note, String versionId) async {
    if (_vault == null) return null;
    return _historyStore.read(note.id, versionId);
  }

  @override
  Future<bool> restoreVersion(Note note, String versionId) async {
    if (_vault == null) await init();
    final String? raw = await _historyStore.read(note.id, versionId);
    if (raw == null) return false;
    final Note version = Note.fromMarkdown(
      raw,
      note.fileName,
      _clock(),
      folderPath: note.folderPath,
    );
    final Note restored = note.copyWith(
      body: version.body,
      updatedAt: _clock(),
    );
    // Make the restore itself reversible before touching the current file.
    await captureVersion(note);
    final File target = File(_pathFor(restored.relativePath));
    await target.parent.create(recursive: true);
    await _writer.replace(target, restored.toMarkdown());
    return true;
  }

  @override
  Future<void> captureVersion(Note note) async {
    if (_vault == null) return;
    try {
      final File file = File(_pathFor(note.relativePath));
      if (!await file.exists()) return;
      final String raw = await file.readAsString();
      await _historyStore.capture(note.id, raw, force: true);
    } catch (_) {
      // Force capture is best effort; the caller's own operation is the point.
    }
  }

  Future<void> _deleteQuietly(String relativePath) async {
    final File f = File(_pathFor(relativePath));
    try {
      if (await f.exists()) await f.delete();
    } on FileSystemException {
      // Ignore: the note is gone from the UI either way.
    }
  }

  @override
  Future<bool> reveal() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return false;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', <String>[vault.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', <String>[vault.path]);
      } else {
        await Process.run('xdg-open', <String>[vault.path]);
      }
      return true;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<Note?> importMarkdown(
    String raw,
    String preferredName, {
    String folderPath = '',
  }) async {
    return writeNewMarkdown(raw, preferredName, folderPath: folderPath);
  }

  @override
  Future<String?> readMarkdownFile(String path) async {
    try {
      final File file = File(path);
      if (!await file.exists()) return null;
      final String raw = await file.readAsString();
      // Notepad on Windows writes a BOM; it is not part of the note.
      return raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
    } on FileSystemException {
      return null;
    } on FormatException {
      // Not UTF-8: refuse rather than import a page of U+FFFD.
      return null;
    }
  }

  @override
  Future<Note> writeNewMarkdown(
    String raw,
    String fileName, {
    String folderPath = '',
  }) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    final String base = _baseName(fileName);
    final String withExtension = base.toLowerCase().endsWith('.md')
        ? base
        : '$base.md';
    final Note parsed = Note.fromMarkdown(
      raw,
      withExtension,
      DateTime.now(),
      folderPath: folder,
    );
    final Note note = parsed.copyWith(
      // The caller's file name is the name that comes back: imports keep the
      // dropped file's name, and a trash restore keeps the original. A file
      // already sitting there forces the ` 2` rule instead of being replaced.
      fileName: await _freeName(folder, withExtension, ''),
      updatedAt: DateTime.now(),
    );
    await save(note);
    return note;
  }

  /// [wanted], or ` 2`/` 3` … when that file already exists in [folderPath] and
  /// is not [excluding] itself (the file being rewritten).
  Future<String> _freeName(
    String folderPath,
    String wanted,
    String excluding,
  ) async {
    final String folder = Note.normalizeFolderPath(folderPath);
    if (wanted.toLowerCase() == excluding.toLowerCase()) return wanted;
    if (!await File(_pathFor(_join(folder, wanted))).exists()) return wanted;
    final String stem = wanted.replaceAll(
      RegExp(r'\.md$', caseSensitive: false),
      '',
    );
    for (int i = 2; i < 1000; i++) {
      final String next = '$stem $i.md';
      if (!await File(_pathFor(_join(folder, next))).exists()) return next;
    }
    return wanted;
  }
}

NoteStore createNoteStore() => IoNoteStore();
