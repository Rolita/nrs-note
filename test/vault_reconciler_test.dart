import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/state/vault_reconciler.dart';

Note _note(
  String id, {
  String title = '随笔',
  String body = '第一行',
  String folder = '',
  DateTime? updated,
}) => Note(
  id: id,
  title: title,
  body: body,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: updated ?? DateTime(2026, 1, 1),
  folderPath: folder,
);

void main() {
  test('a clean note changed on disk is reloaded', () {
    final Note current = _note('a');
    final Note disk = current.copyWith(body: '外部改过');

    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[disk],
      draftId: 'a',
      draftDirty: false,
      draftBaseline: current,
    );

    expect(result.draftAction, DraftAction.reload);
    expect(result.diskDraft?.body, '外部改过');
  });

  test('a dirty note changed on disk becomes a conflict, never a write', () {
    final Note current = _note('a', body: '本地改过');
    final Note baseline = _note('a');
    final Note disk = baseline.copyWith(body: '外部改过');

    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[disk],
      draftId: 'a',
      draftDirty: true,
      draftBaseline: baseline,
    );

    expect(result.draftAction, DraftAction.conflict);
    expect(result.diskDraft?.body, '外部改过');
    expect(
      result.notes.single.body,
      '本地改过',
      reason: '冲突时内存里必须还是用户正在写的那份',
    );
    expect(result.repairs, isEmpty);
  });

  test('the same edit on both sides is not a conflict', () {
    final Note current = _note('a', body: '同一句');
    final Note baseline = _note('a');
    final Note disk = baseline.copyWith(body: '同一句');

    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[disk],
      draftId: 'a',
      draftDirty: true,
      draftBaseline: baseline,
    );

    expect(result.draftAction, DraftAction.reload);
  });

  test('a clean note deleted outside is removed', () {
    final Note current = _note('a');
    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[],
      draftId: 'a',
      draftDirty: false,
      draftBaseline: current,
    );

    expect(result.draftAction, DraftAction.removed);
    expect(result.notes, isEmpty);
    expect(result.diskDraft, isNull);
  });

  test('a dirty note deleted outside becomes an orphan, not a loss', () {
    final Note current = _note('a', body: '本地改过');
    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[],
      draftId: 'a',
      draftDirty: true,
      draftBaseline: _note('a'),
    );

    expect(result.draftAction, DraftAction.orphan);
    expect(result.notes.single.body, '本地改过');
  });

  test('a file that only moved keeps the local edits and follows the path', () {
    final Note baseline = _note('a');
    final Note current = baseline.copyWith(body: '本地改过');
    final Note moved = baseline.copyWith(folderPath: '工作');

    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[moved],
      draftId: 'a',
      draftDirty: true,
      draftBaseline: baseline,
    );

    expect(result.draftAction, DraftAction.adoptDiskPath);
    expect(result.notes.single.body, '本地改过');
    expect(result.diskDraft?.relativePath, '工作/随笔.md');
  });

  test('a new note whose first write has not landed is not called deleted', () {
    final Note current = _note('new', body: '还没写下去');

    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[],
      draftId: 'new',
      draftDirty: true,
      draftBaseline: null,
    );

    expect(result.draftAction, DraftAction.untouched);
    expect(result.notes.single.id, 'new');
  });

  test('notes added outside show up without stealing the selection', () {
    final Note current = _note('a');
    final Note added = _note('b', title: '新的', body: '别人写的');

    final ReconcileResult result = reconcileVault(
      current: <Note>[current],
      disk: <Note>[current, added],
      draftId: 'a',
      draftDirty: false,
      draftBaseline: current,
    );

    expect(result.notes.map((Note n) => n.id), containsAll(<String>['a', 'b']));
    expect(result.draftAction, DraftAction.reload);
  });

  test('two files with one id become two distinct notes', () {
    final Note older = _note('a', body: '旧', updated: DateTime(2026, 1, 1));
    final Note newer = older.copyWith(
      body: '新',
      updatedAt: DateTime(2026, 2, 1),
    );

    final ReconcileResult result = reconcileVault(
      current: <Note>[],
      disk: <Note>[older, newer],
      draftId: null,
      draftDirty: false,
    );

    expect(result.notes, hasLength(2));
    expect(
      result.notes.map((Note n) => n.id).toSet(),
      hasLength(2),
      reason: '副本必须换一个 id，否则下次启动还会撞',
    );
    expect(result.repairs, hasLength(1));
    expect(result.repairs.single.previousPath, older.relativePath);
    expect(result.repairs.single.note.body, '旧');
    expect(
      result.repairs.single.note.relativePath,
      isNot(older.relativePath),
      reason: '副本要挪到另一个文件名',
    );
  });
}
