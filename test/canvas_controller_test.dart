import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/data/storage/canvas_store_factory.dart';
import 'package:nrs/state/canvas_controller.dart';

/// 内存里的假存储。`write` 可以按需失败，用来测「写不进去时脏标记不能丢」。
class FakeStore implements CanvasStore {
  final Map<String, String> files = <String, String>{};
  int writes = 0;
  bool failWrites = false;

  @override
  String get location => '内存';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<void> init() async {}

  @override
  Future<List<CanvasRef>> list() async => <CanvasRef>[
    for (final String path in files.keys)
      CanvasRef(relativePath: path, title: canvasTitleOf(path)),
  ];

  @override
  Future<String> read(String relativePath) async {
    final String? text = files[relativePath];
    if (text == null) throw StateError('没有这个文件');
    return text;
  }

  @override
  Future<void> write(String relativePath, String contents) async {
    if (failWrites) throw StateError('磁盘满了');
    writes++;
    files[relativePath] = contents;
  }

  @override
  Future<String> create(String folderPath, {String? title}) async {
    final String name = canvasFileName(title);
    final String path = folderPath.isEmpty ? '$name.nrs' : '$folderPath/$name.nrs';
    files[path] = encodeCanvas(CanvasDocument());
    return path;
  }
}

CanvasDocument oneCard() => CanvasDocument(
  nodes: <CanvasNode>[
    TextNode(id: 'a', x: 0, y: 0, width: 250, height: 120, text: '一张'),
  ],
  edges: <CanvasEdge>[],
);

void main() {
  group('新建与打开', () {
    test('新建之后就有文档，文件也已经落地', () async {
      final FakeStore store = FakeStore();
      final CanvasController c = CanvasController(store: store);

      expect(await c.createNew('项目'), isTrue);

      expect(c.hasDocument, isTrue);
      expect(c.path, '项目/未命名白板.nrs');
      expect(store.files.containsKey(c.path), isTrue);
      expect(c.isDirty, isFalse);
    });

    test('打开会读盘并解析', () async {
      final FakeStore store = FakeStore();
      store.files['a.nrs'] = encodeCanvas(oneCard());
      final CanvasController c = CanvasController(store: store);

      expect(await c.open('a.nrs'), isTrue);
      expect(c.path, 'a.nrs');
      expect(c.document!.nodes.length, 1);
    });

    test('文件坏掉时保留原来打开的那一份', () async {
      final FakeStore store = FakeStore();
      store.files['good.nrs'] = encodeCanvas(oneCard());
      store.files['bad.nrs'] = '{ 这不是 JSON';
      final CanvasController c = CanvasController(store: store);

      await c.open('good.nrs');
      final CanvasDocument before = c.document!;

      expect(await c.open('bad.nrs'), isFalse);
      expect(c.document, same(before), reason: '打不开就把白板清空是最糟的处理');
      expect(c.error, isNotNull);
      expect(c.path, 'good.nrs');
    });

    test('读不到文件也算失败，不抛给界面', () async {
      final CanvasController c = CanvasController(store: FakeStore());
      expect(await c.open('没有这个.nrs'), isFalse);
      expect(c.error, isNotNull);
    });
  });

  group('保存', () {
    test('改了之后 flush 就落盘，内容能原样读回来', () async {
      final FakeStore store = FakeStore();
      final CanvasController c = CanvasController(store: store);
      await c.createNew('');
      c.document!.nodes.add(
        TextNode(id: 'x', x: 40, y: 60, width: 250, height: 120, text: '写点'),
      );

      c.markDirty();
      expect(c.isDirty, isTrue);

      await c.flush();
      expect(c.isDirty, isFalse);

      final CanvasDocument saved = parseCanvas(store.files[c.path]!);
      expect(saved.nodes.single.x, 40);
      expect((saved.nodes.single as TextNode).text, '写点');
    });

    test('没改过就不写盘', () async {
      final FakeStore store = FakeStore();
      final CanvasController c = CanvasController(store: store);
      await c.createNew('');
      final int before = store.writes;

      await c.flush();
      expect(store.writes, before);
    });

    test('自动保存：改完等一小会儿自己写', () async {
      final FakeStore store = FakeStore();
      final CanvasController c = CanvasController(
        store: store,
        autosaveDelay: const Duration(milliseconds: 30),
      );
      await c.createNew('');
      final int before = store.writes;

      c.markDirty();
      expect(store.writes, before);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(store.writes, before + 1);
      expect(c.isDirty, isFalse);
    });

    test('连着改几次只写一次', () async {
      final FakeStore store = FakeStore();
      final CanvasController c = CanvasController(
        store: store,
        autosaveDelay: const Duration(milliseconds: 30),
      );
      await c.createNew('');
      final int before = store.writes;

      c.markDirty();
      c.markDirty();
      c.markDirty();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(store.writes, before + 1);
    });

    test('写失败时脏标记留着，下次还会再试', () async {
      final FakeStore store = FakeStore();
      final CanvasController c = CanvasController(store: store);
      await c.createNew('');
      store.failWrites = true;

      c.markDirty();
      await c.flush();

      expect(c.isDirty, isTrue, reason: '写失败不能假装干净了');
      expect(c.error, contains('保存白板失败'));
    });

    test('关掉之前会先落盘', () async {
      final FakeStore store = FakeStore();
      final CanvasController c = CanvasController(store: store);
      await c.createNew('');
      c.document!.nodes.add(
        TextNode(id: 'x', x: 0, y: 0, width: 250, height: 120, text: '留个证据'),
      );
      c.markDirty();

      await c.close();

      expect(c.hasDocument, isFalse);
      expect(
        (parseCanvas(store.files['未命名白板.nrs']!).nodes.single as TextNode).text,
        '留个证据',
      );
    });
  });

  group('通知', () {
    test('打开、新建会通知；markDirty 不通知', () async {
      final CanvasController c = CanvasController(store: FakeStore());
      int notified = 0;
      c.addListener(() => notified++);

      await c.createNew('');
      expect(notified, 1);

      c.markDirty();
      expect(notified, 1, reason: '每敲一个字都通知会把整棵外壳重建');
    });
  });
}
