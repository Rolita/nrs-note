import '../data/models/note.dart';

/// What the sync pass should do with the note the editor is showing.
enum DraftAction {
  /// Leave the draft alone: the disk still matches the baseline, or this is a
  /// new note whose first write has not landed yet.
  untouched,

  /// The file moved or was renamed outside the app while the draft was being
  /// edited. Keep the edits, follow the file.
  adoptDiskPath,

  /// Take the disk version, edits included.
  reload,

  /// Both sides changed. Stop autosave and let the user choose.
  conflict,

  /// The file is gone while the draft has unsaved edits.
  orphan,

  /// The file is gone and the draft is clean: close it.
  removed,
}

/// The outcome of comparing the vault with what the UI already holds.
class ReconcileResult {
  const ReconcileResult({
    required this.notes,
    required this.draftAction,
    this.diskDraft,
    this.repairs = const <({Note note, String previousPath})>[],
  });

  /// The vault as it now is, with any still-unsaved draft folded back in.
  final List<Note> notes;

  final DraftAction draftAction;

  /// The disk version of the open note, for [DraftAction.reload],
  /// [DraftAction.adoptDiskPath] and [DraftAction.conflict]. Null when the file
  /// is gone.
  final Note? diskDraft;

  /// Two files shared an id; the older one has to move to a fresh name and id.
  final List<({Note note, String previousPath})> repairs;
}

/// Compares the notes in memory with the notes now on disk.
///
/// Pure on purpose: every "what should happen when someone edits the vault in
/// another program" rule lives here, away from file IO and widgets.
///
/// [draftBaseline] is the version of the open note that the draft started from
/// — the last one read from or written to disk. Without it a local edit and an
/// external edit look identical from the outside, and a file that only moved
/// would be mistaken for a conflict.
ReconcileResult reconcileVault({
  required List<Note> current,
  required List<Note> disk,
  required String? draftId,
  required bool draftDirty,
  Note? draftBaseline,
}) {
  final List<({Note note, String previousPath})> repairs =
      <({Note note, String previousPath})>[];
  final List<Note> resolved = _resolveDuplicateIds(disk, repairs);

  final Map<String, Note> currentById = <String, Note>{
    for (final Note n in current) n.id: n,
  };
  final Map<String, Note> diskById = <String, Note>{
    for (final Note n in resolved) n.id: n,
  };

  final List<Note> notes = List<Note>.of(resolved);
  final Note? draft = draftId == null ? null : currentById[draftId];
  final Note? diskDraft = draftId == null ? null : diskById[draftId];
  final bool dirty =
      draft != null &&
      draftDirty &&
      (draftBaseline == null || !_sameContent(draft, draftBaseline));

  DraftAction action = DraftAction.untouched;
  if (draft != null) {
    if (diskDraft == null) {
      if (draftBaseline == null && draftDirty) {
        // The first write of a brand-new note has not landed (or failed). That
        // is a pending creation, not a file someone deleted.
        notes.add(draft);
      } else if (dirty) {
        notes.add(draft);
        action = DraftAction.orphan;
      } else {
        action = DraftAction.removed;
      }
    } else {
      final Note baseline = draftBaseline ?? draft;
      final bool diskChanged = !_sameContent(diskDraft, baseline);
      final bool sameAsDisk = _sameContent(draft, diskDraft);
      if (sameAsDisk) {
        action = DraftAction.reload;
      } else if (!diskChanged) {
        // Only the path changed outside; the prose is still the baseline, so
        // the local edits are safe to keep.
        action = dirty ? DraftAction.adoptDiskPath : DraftAction.reload;
      } else {
        action = dirty ? DraftAction.conflict : DraftAction.reload;
      }
      if (action == DraftAction.conflict ||
          action == DraftAction.adoptDiskPath) {
        final int index = notes.indexWhere((Note n) => n.id == draft.id);
        if (index >= 0) notes[index] = draft;
      }
    }
  }

  return ReconcileResult(
    notes: notes,
    draftAction: action,
    diskDraft: diskDraft,
    repairs: repairs,
  );
}

bool _sameContent(Note a, Note b) =>
    a.body == b.body && a.title == b.title;

/// Keeps one file per id. The most recently updated copy wins; the others are
/// moved aside as `… (冲突副本).md` with a fresh id, so editing one never
/// silently overwrites the other.
List<Note> _resolveDuplicateIds(
  List<Note> disk,
  List<({Note note, String previousPath})> repairs,
) {
  final Map<String, List<Note>> byId = <String, List<Note>>{};
  for (final Note note in disk) {
    byId.putIfAbsent(note.id, () => <Note>[]).add(note);
  }

  final List<Note> resolved = <Note>[];
  for (final List<Note> group in byId.values) {
    if (group.length == 1) {
      resolved.add(group.single);
      continue;
    }
    group.sort((Note a, Note b) {
      final int byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime != 0
          ? byTime
          : a.relativePath.toLowerCase().compareTo(
              b.relativePath.toLowerCase(),
            );
    });
    resolved.add(group.first);
    for (final Note loser in group.skip(1)) {
      final String title = '${loser.title} (冲突副本)';
      final String fileName = _freeName(
        resolved,
        loser.folderPath,
        Note.buildFileName(title),
      );
      final Note copy = loser.copyWith(
        id: Note.newId(),
        title: title,
        fileName: fileName,
      );
      repairs.add((note: copy, previousPath: loser.relativePath));
      resolved.add(copy);
    }
  }
  return resolved;
}

String _freeName(List<Note> pool, String folderPath, String candidate) {
  final Set<String> taken = <String>{
    for (final Note n in pool)
      if (n.folderPath.toLowerCase() == folderPath.toLowerCase())
        n.fileName.toLowerCase(),
  };
  if (!taken.contains(candidate.toLowerCase())) return candidate;
  final String stem = candidate.replaceAll(
    RegExp(r'\.md$', caseSensitive: false),
    '',
  );
  for (int i = 2; i < 1000; i++) {
    final String next = '$stem $i.md';
    if (!taken.contains(next.toLowerCase())) return next;
  }
  return candidate;
}
