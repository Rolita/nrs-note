import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/note_images.dart';

/// 图片侧边栏列出来的，必须和正文里**画成图的**是同一批。
/// 判定复用 `ImageMarkup.parseLine`，所以这里量的是「哪些行算图片」。
void main() {
  group('extractImages', () {
    test('没有图片就是空表', () {
      expect(extractImages(''), isEmpty);
      expect(extractImages('只有字，没有图。'), isEmpty);
    });

    test('标准 Markdown 图片行：行号与行首偏移都对得上', () {
      const String body = '# 标题\n\n![一只猫](assets/a.png)\n\n后面还有字。';
      final List<NoteImage> images = extractImages(body);
      expect(images, hasLength(1));
      expect(images.single.line, 2);
      expect(images.single.offset, body.indexOf('!['));
      expect(images.single.source, 'assets/a.png');
      expect(images.single.alt, '一只猫');
      expect(images.single.width, isNull);
      expect(images.single.isExternal, isFalse);
    });

    test('<img> 行：宽度、对齐与远程地址都读得出来', () {
      const String body =
          '<img src="https://img.test/a.png" width="320" align="right" alt="图">\n正文';
      final NoteImage image = extractImages(body).single;
      expect(image.source, 'https://img.test/a.png');
      expect(image.width, 320);
      expect(image.alt, '图');
      expect(image.isExternal, isTrue);
    });

    test('行内混着文字的图片不算：正文里那也只是一行字', () {
      expect(extractImages('前面 ![a](b.png) 后面'), isEmpty);
      expect(extractImages('- 列表项 ![a](b.png)'), isEmpty);
    });

    test('多张按出现顺序排列，行号连续递增', () {
      const String body = '![a](1.png)\n字\n![b](2.png)\n![c](3.png)';
      final List<NoteImage> images = extractImages(body);
      expect(images.map((NoteImage i) => i.line), <int>[0, 2, 3]);
      expect(images.map((NoteImage i) => i.source), <String>[
        '1.png',
        '2.png',
        '3.png',
      ]);
    });

    test('行首缩进不影响判定', () {
      final List<NoteImage> images = extractImages('   ![a](1.png)   ');
      expect(images, hasLength(1));
      expect(images.single.source, '1.png');
    });

    test('末尾有换行也不会多出一行空图', () {
      expect(extractImages('![a](1.png)\n'), hasLength(1));
      expect(extractImages('![a](1.png)\n\n\n'), hasLength(1));
    });
  });

  group('面板上的标题', () {
    test('有 alt 用 alt', () {
      final NoteImage image = extractImages('![一只猫](assets/a.png)').single;
      expect(image.label, '一只猫');
    });

    test('没有 alt 用文件名', () {
      final NoteImage image = extractImages('![   ](assets/cat-01.png)').single;
      expect(image.label, 'cat-01.png');
    });

    test('远程地址带查询串时只取到问号，一行放得下', () {
      final NoteImage image = extractImages(
        '<img src="https://img.test/a.png?token=abc&x=1">',
      ).single;
      expect(image.label, 'a.png');
    });
  });
}
