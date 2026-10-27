import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/data/storage/canvas_store.dart';
import 'package:nrs/data/storage/canvas_store_io.dart';
import 'package:nrs/data/storage/note_store.dart' show TrashEntry;

/// 一张带文字的卡片：用来验证「删了再恢复，内容没变」。
CanvasDocument oneCard() => CanvasDocument(
  nodes: <CanvasNode>[
    TextNode(id: 'a', x: 0, y: 0, width: 250, height: 120, text: '一张'),
  ],
  edges: <CanvasEdge>[],
);

void main() {
  group('文件名', () {
    test('空名字退化成「未命名白板」', () {
      expect(canvasFileName(null), '未命名白板');
      expect(canvasFileName('   '), '未命名白板');
    });

    test('路径分隔符和 Windows 不认的字符换成空格', () {
      expect(canvasFileName('a/b\\c:d*e?f"g<h>i|j'), 'a b c d e f g h i j');
    });

    test('连续的空白收成一个，首尾去掉', () {
      expect(canvasFileName('  我的   白板  '), '我的 白板');
    });

    test('太长就截断，别把文件系统搞崩', () {
      expect(canvasFileName('あ' * 200).length, 80);
    });
  });

  group('标题', () {
    test('去掉 .nrs 后缀，大小写都认', () {
      expect(canvasTitleOf('项目/计划.nrs'), '计划');
      expect(canvasTitleOf('计划.NRS'), '计划');
    });

    test('没有后缀就原样返回', () {
      expect(canvasTitleOf('随手一块'), '随手一块');
    });
  });

  group('路径安全', () {
    test('普通相对路径是安全的', () {
      expect(isSafeCanvasPath('a.nrs'), isTrue);
      expect(isSafeCanvasPath('项目/子目录/a.nrs'), isTrue);
      expect(isSafeCanvasPath('项目\\a.nrs'), isTrue);
    });

    test('绝对路径和上跳都不安全', () {
      expect(isSafeCanvasPath('/etc/passwd'), isFalse);
      expect(isSafeCanvasPath('C:/windows/a.nrs'), isFalse);
      expect(isSafeCanvasPath('../a.nrs'), isFalse);
      expect(isSafeCanvasPath('项目/../../a.nrs'), isFalse);
      expect(isSafeCanvasPath(''), isFalse);
    });
  });

  group('真文件', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('nrs-canvas-test');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('新建、写入、读回来，坐标和文字都在', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      final String path = await store.create('项目', title: '计划');
      expect(path, '项目/计划.nrs');
      expect(File('${root.path}/项目/计划.nrs').existsSync(), isTrue);

      final CanvasDocument doc = CanvasDocument(
        nodes: <CanvasNode>[
          TextNode(
            id: 'a',
            x: 40,
            y: 60,
            width: 250,
            height: 120,
            text: '连线之前',
            color: '2',
          ),
        ],
        edges: <CanvasEdge>[],
      );
      await store.write(path, encodeCanvas(doc));

      final CanvasDocument back = parseCanvas(await store.read(path));
      expect(back.nodes.single.x, 40);
      expect((back.nodes.single as TextNode).text, '连线之前');
      expect(back.nodes.single.color, '2');
    });

    test('重名不覆盖，自动加 2', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      final String first = await store.create('', title: '白板');
      final String second = await store.create('', title: '白板');

      expect(first, '白板.nrs');
      expect(second, '白板 2.nrs');
    });

    test('列表只列 .nrs，跳过回收站和版本目录', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      await store.create('', title: '甲');
      await store.create('项目', title: '乙');
      await File('${root.path}/笔记.md').writeAsString('# 不是白板');
      await Directory('${root.path}/.nrs-trash/x').create(recursive: true);
      await File('${root.path}/.nrs-trash/x/旧.nrs').writeAsString('{}');

      final List<CanvasRef> refs = await store.list();
      expect(
        refs.map((CanvasRef r) => r.relativePath),
        <String>['甲.nrs', '项目/乙.nrs'],
      );
      expect(refs.first.title, '甲');
    });

    test('写到不安全的路径直接拒绝', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      expect(
        () => store.write('../跑出去.nrs', '{}'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('父目录不存在时会自己建', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      await store.write('深/几/层/a.nrs', encodeCanvas(CanvasDocument()));
      expect(File('${root.path}/深/几/层/a.nrs').existsSync(), isTrue);
    });

    test('删除是移进回收站，不是抹掉', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      final String path = await store.create('项目', title: '计划');
      await store.write(path, encodeCanvas(oneCard()));

      final TrashEntry? entry = await store.delete(path);

      expect(entry, isNotNull);
      expect(entry!.originalPath, '项目/计划.nrs');
      // 回收站里显示的名字不带后缀，和笔记条目一个样子。
      expect(entry.title, '计划');
      expect(File('${root.path}/项目/计划.nrs').existsSync(), isFalse);
      expect(await store.list(), isEmpty);
      // 原文件还在 vault 里，只是换了位置：不开 NRS 也能在资源管理器里找回。
      expect(
        Directory('${root.path}/.nrs-trash')
            .listSync(recursive: true)
            .whereType<File>()
            .map((File f) => f.uri.pathSegments.last),
        contains('计划.nrs'),
      );
    });

    test('恢复回到原文件夹，内容一个字节都不少', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      final String path = await store.create('项目', title: '计划');
      await store.write(path, encodeCanvas(oneCard()));
      final TrashEntry entry = (await store.delete(path))!;

      expect(await store.restoreTrash(entry.id), isTrue);

      expect(File('${root.path}/项目/计划.nrs').existsSync(), isTrue);
      final CanvasDocument back = parseCanvas(await store.read('项目/计划.nrs'));
      expect((back.nodes.single as TextNode).text, '一张');
      // 条目搬回来了就该从回收站消失，否则会留下「已经回来的一份副本」。
      expect(
        Directory('${root.path}/.nrs-trash').listSync().whereType<Directory>(),
        isEmpty,
      );
    });

    test('恢复时原位置被占了，退到「 2」，不覆盖新的那块', () async {
      final IoCanvasStore store = IoCanvasStore(rootPath: root.path);
      final String path = await store.create('', title: '白板');
      await store.write(path, encodeCanvas(oneCard()));
      final TrashEntry entry = (await store.delete(path))!;
      // 删完之后又建了一块同名的。
      await store.create('', title: '白板');
      await store.write('白板.nrs', encodeCanvas(CanvasDocument()));

      expect(await store.restoreTrash(entry.id), isTrue);

      final List<String> paths = (await store.list())
          .map((CanvasRef ref) => ref.relativePath)
          .toList();
      expect(paths, <String>['白板 2.nrs', '白板.nrs']);
      // 新那块没被动过。
      expect(parseCanvas(await store.read('白板.nrs')).nodes, isEmpty);
      expect(
        (parseCanvas(await store.read('白板 2.nrs')).nodes.single as TextNode).text,
        '一张',
      );
    });
  });
}
