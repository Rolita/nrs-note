import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/canvas_document.dart';
import 'package:nrs/data/storage/canvas_store.dart';
import 'package:nrs/data/storage/canvas_store_io.dart';

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
  });
}
