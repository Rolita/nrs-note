import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/data/storage/web_sync.dart';

/// In-memory [WebKeyValue] whose writes can fail like an exhausted quota.
class _FakeKv implements WebKeyValue {
  _FakeKv({Map<String, String>? values, this.failAfter = -1})
    : values = values ?? <String, String>{};

  final Map<String, String> values;
  final int failAfter;
  final List<String> written = <String>[];
  final List<String> removed = <String>[];
  int _writes = 0;

  @override
  void setItem(String key, String value) {
    if (failAfter >= 0 && _writes >= failAfter) {
      throw StateError('quota exceeded');
    }
    _writes++;
    written.add(key);
    values[key] = value;
  }

  @override
  void removeItem(String key) {
    removed.add(key);
    values.remove(key);
  }
}

void main() {
  const String prefix = 'nrs/v1/file/';

  test('only changed keys are written, stale keys after that', () {
    final Map<String, String> persisted = <String, String>{
      'a.md': 'A',
      'b.md': 'B',
    };
    final WebSyncPlan plan = WebSyncPlan.between(
      persisted: persisted,
      next: <String, String>{'a.md': 'A', 'b.md': 'B2', 'c.md': 'C'},
    );
    expect(plan.write, <String, String>{'b.md': 'B2', 'c.md': 'C'});
    expect(plan.remove, isEmpty);

    final Map<String, String> lastWrite = <String, String>{...persisted};
    final _FakeKv kv = _FakeKv(
      values: <String, String>{
        '${prefix}a.md': 'A',
        '${prefix}b.md': 'B',
      },
    );
    plan.apply(kv, lastWrite, prefix: prefix);
    expect(kv.written, <String>['${prefix}b.md', '${prefix}c.md']);
    expect(kv.removed, isEmpty);
    expect(lastWrite, <String, String>{'a.md': 'A', 'b.md': 'B2', 'c.md': 'C'});
  });

  test('a re-save of an unchanged library touches nothing', () {
    final Map<String, String> persisted = <String, String>{
      'a.md': 'A',
      'b.md': 'B',
    };
    final _FakeKv kv = _FakeKv(values: <String, String>{...persisted});
    WebSyncPlan.between(
      persisted: persisted,
      next: <String, String>{'a.md': 'A', 'b.md': 'B'},
    ).apply(kv, persisted, prefix: prefix);
    expect(kv.written, isEmpty);
    expect(kv.removed, isEmpty);
  });

  test('a quota failure keeps old values and stale keys', () {
    final Map<String, String> persisted = <String, String>{
      'a.md': 'A',
      'b.md': 'B',
    };
    final Map<String, String> lastWrite = <String, String>{...persisted};
    final WebSyncPlan plan = WebSyncPlan.between(
      persisted: persisted,
      next: <String, String>{'a.md': 'A2', 'c.md': 'C'},
    );
    // 第一笔（a.md）写得进去，第二笔（c.md）配额超限。
    final _FakeKv kv = _FakeKv(
      values: <String, String>{
        '${prefix}a.md': 'A',
        '${prefix}b.md': 'B',
      },
      failAfter: 1,
    );
    expect(() => plan.apply(kv, lastWrite, prefix: prefix), throwsStateError);

    expect(kv.values['${prefix}a.md'], 'A2', reason: '已写成功的项保留新值');
    expect(kv.values['${prefix}b.md'], 'B', reason: '过期键不能提前删');
    expect(kv.values.containsKey('${prefix}c.md'), isFalse);
    expect(kv.removed, isEmpty);
    expect(lastWrite['a.md'], 'A2');
    expect(lastWrite['b.md'], 'B', reason: '失败时不改持久化快照');
  });

  test('stale keys are removed after all writes succeed', () {
    final Map<String, String> persisted = <String, String>{
      'a.md': 'A',
      'b.md': 'B',
    };
    final WebSyncPlan plan = WebSyncPlan.between(
      persisted: persisted,
      next: <String, String>{'a.md': 'A2'},
    );
    expect(plan.remove, <String>['b.md']);

    final _FakeKv kv = _FakeKv(
      values: <String, String>{
        '${prefix}a.md': 'A',
        '${prefix}b.md': 'B',
      },
    );
    final Map<String, String> lastWrite = <String, String>{...persisted};
    plan.apply(kv, lastWrite, prefix: prefix);
    expect(kv.removed, <String>['${prefix}b.md']);
    expect(lastWrite, <String, String>{'a.md': 'A2'});
  });
}
