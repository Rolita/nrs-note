import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/image_markup.dart';

/// `ImageMarkup` is the pure value layer behind「图片行」: if it accepts a line,
/// the editor may draw a picture there; if it rejects one, the line stays
/// source. The tests below pin down exactly which spellings count and how the
/// line is regenerated after a resize.
void main() {
  group('Markdown 图片行', () {
    test('parses alt and a relative source', () {
      final ImageMarkup markup = ImageMarkup.parseLine(
        '![图片](assets/image_20261024_153012.png)',
      )!;
      expect(markup.source, 'assets/image_20261024_153012.png');
      expect(markup.alt, '图片');
      expect(markup.width, isNull);
      expect(markup.isExternal, isFalse);
    });

    test('an empty alt is null', () {
      final ImageMarkup markup = ImageMarkup.parseLine('![](assets/x.png)')!;
      expect(markup.alt, isNull);
      expect(markup.source, 'assets/x.png');
    });

    test('accepts an angle-bracketed destination and a title', () {
      expect(
        ImageMarkup.parseLine('![图](<assets/x y.png>)')!.source,
        'assets/x y.png',
      );
      final ImageMarkup titled = ImageMarkup.parseLine('![a](x.png "说明")')!;
      expect(titled.source, 'x.png');
      expect(titled.alt, 'a');
      final ImageMarkup single = ImageMarkup.parseLine("![a](x.png '说明')")!;
      expect(single.source, 'x.png');
      final ImageMarkup paren = ImageMarkup.parseLine('![a](x.png (说明))')!;
      expect(paren.source, 'x.png');
    });

    test('trims surrounding whitespace', () {
      final ImageMarkup markup = ImageMarkup.parseLine('  ![a](x.png)  ')!;
      expect(markup.source, 'x.png');
    });

    test('decodes escaped brackets and quotes in the alt', () {
      final ImageMarkup markup = ImageMarkup.parseLine(
        r'![a\]b&quot;c](x.png)',
      )!;
      expect(markup.alt, 'a]b"c');
    });

    test('keeps balanced parentheses inside the destination', () {
      expect(
        ImageMarkup.parseLine('![a](assets/a(b).png)')!.source,
        'assets/a(b).png',
      );
    });

    test('marks remote sources as external', () {
      expect(
        ImageMarkup.parseLine('![a](https://example.com/x.png)')!.isExternal,
        isTrue,
      );
      expect(
        ImageMarkup.parseLine('![a](HTTP://example.com/x.png)')!.isExternal,
        isTrue,
      );
      expect(
        ImageMarkup.parseLine('![a](data:image/png;base64,AAA)')!.isExternal,
        isTrue,
      );
    });

    test('rejects anything that is not the whole line', () {
      const List<String> rejected = <String>[
        '',
        '文字 ![a](x.png)',
        '![a](x.png) 文字',
        '![a](x.png) ![b](y.png)',
        '> ![a](x.png)',
        '- ![a](x.png)',
        '| ![a](x.png) |',
        '![](   )',
        '![a](x.png',
        '![a]()',
        '![a](x.png "title" extra)',
        '![a](x.png "unterminated)',
        '[[a]](x.png)',
        '<img src="x.png"',
      ];
      for (final String line in rejected) {
        expect(ImageMarkup.parseLine(line), isNull, reason: line);
      }
    });
  });

  group('img 标签图片行', () {
    test('parses src, width and alt', () {
      final ImageMarkup markup = ImageMarkup.parseLine(
        '<img src="assets/x.png" width="320" alt="图片">',
      )!;
      expect(markup.source, 'assets/x.png');
      expect(markup.width, 320);
      expect(markup.alt, '图片');
    });

    test('accepts any attribute order, quotes and case', () {
      final ImageMarkup markup = ImageMarkup.parseLine(
        "<IMG ALT='图' WIDTH=320px SRC='assets/x.png'/>",
      )!;
      expect(markup.source, 'assets/x.png');
      expect(markup.width, 320);
      expect(markup.alt, '图');
    });

    test('parses fractional widths and spacing', () {
      expect(
        ImageMarkup.parseLine('<img width="320.5" src="x.png">')!.width,
        320.5,
      );
      expect(
        ImageMarkup.parseLine('<img src=x.png width=" 320 ">')!.width,
        320,
      );
    });

    test('accepts a quoted > inside an attribute', () {
      final ImageMarkup markup = ImageMarkup.parseLine(
        '<img alt="a > b" src="x.png">',
      )!;
      expect(markup.alt, 'a > b');
      expect(markup.source, 'x.png');
    });

    test('a tag without a width has a null width', () {
      expect(ImageMarkup.parseLine('<img src="x.png">')!.width, isNull);
    });

    test('rejects a missing src, a bad width and trailing text', () {
      const List<String> rejected = <String>[
        '<img>',
        '<img src="">',
        '<img width="320">',
        '<img src="x.png" width="wide">',
        '<img src="x.png" width="">',
        '<img src="x.png" width>',
        '<img src="x.png"> 文字',
        '<img src="x.png" <img src="y.png">',
      ];
      for (final String line in rejected) {
        expect(ImageMarkup.parseLine(line), isNull, reason: line);
      }
    });
  });

  group('靠边浮动', () {
    test('align 写在 width 之后、alt 之前', () {
      const ImageMarkup markup = ImageMarkup(
        source: 'assets/x.png',
        alt: '图片',
        width: 320,
        align: ImageAlign.right,
      );
      expect(
        markup.toMarkdown(),
        '<img src="assets/x.png" width="320" align="right" alt="图片">',
      );
      // 没有宽度也得是标签：`![…](…)` 没有放属性的地方。
      expect(
        const ImageMarkup(source: 'assets/x.png', align: ImageAlign.left)
            .toMarkdown(),
        '<img src="assets/x.png" align="left">',
      );
    });

    test('解析时认大小写与单引号，认不出的值当没写', () {
      expect(
        ImageMarkup.parseLine(
          '<img src="a.png" ALIGN=\'Left\' alt="图">',
        )!.align,
        ImageAlign.left,
      );
      expect(
        ImageMarkup.parseLine('<img src="a.png" align="right">')!.align,
        ImageAlign.right,
      );
      expect(
        ImageMarkup.parseLine('<img src="a.png" align="center">')!.align,
        isNull,
        reason: '一行 <img> 不该因为一个不认识的属性整行退回源码',
      );
      expect(ImageMarkup.parseLine('![图](a.png)')!.align, isNull);
    });

    test('带 align 的行能原样读回来', () {
      for (final ImageAlign side in ImageAlign.values) {
        final ImageMarkup markup = ImageMarkup(
          source: 'assets/x.png',
          alt: '图',
          width: 240,
          align: side,
        );
        final ImageMarkup again = ImageMarkup.parseLine(markup.toMarkdown())!;
        expect(again.align, side);
        expect(again.width, 240);
        expect(again.alt, '图');
      }
    });
  });

  group('toMarkdown', () {
    test('writes standard Markdown when there is no width', () {
      const ImageMarkup markup = ImageMarkup(source: 'assets/x.png', alt: '图片');
      expect(markup.toMarkdown(), '![图片](assets/x.png)');
      expect(
        const ImageMarkup(source: 'assets/x.png').toMarkdown(),
        '![](assets/x.png)',
      );
    });

    test('angle-brackets a destination that contains spaces', () {
      const ImageMarkup markup = ImageMarkup(
        source: 'assets/x y.png',
        alt: '图',
      );
      expect(markup.toMarkdown(), '![图](<assets/x y.png>)');
    });

    test('writes an img tag with the fixed attribute order', () {
      const ImageMarkup markup = ImageMarkup(
        source: 'assets/x.png',
        alt: '图片',
        width: 320,
      );
      expect(
        markup.toMarkdown(),
        '<img src="assets/x.png" width="320" alt="图片">',
      );
      expect(
        const ImageMarkup(source: 'assets/x.png').toMarkdown(width: 240),
        '<img src="assets/x.png" width="240">',
      );
      expect(
        markup.toMarkdown(width: 320.5),
        '<img src="assets/x.png" width="320.5" alt="图片">',
      );
    });

    test('escapes alt text', () {
      const ImageMarkup markup = ImageMarkup(source: 'x.png', alt: 'a]b"c\\d');
      expect(markup.toMarkdown(), r'![a\]b&quot;c\\d](x.png)');
      expect(
        markup.toMarkdown(width: 100),
        r'<img src="x.png" width="100" alt="a\]b&quot;c\\d">',
      );
    });

    test('asTag 在没有宽度时也写标签：插入图片走这条路', () {
      const ImageMarkup markup = ImageMarkup(source: 'assets/x.png', alt: '图片');
      expect(
        markup.toMarkdown(asTag: true),
        '<img src="assets/x.png" alt="图片">',
        reason: '同一份文件里不该同时出现两种图片语法',
      );
      expect(
        const ImageMarkup(source: 'assets/x.png').toMarkdown(asTag: true),
        '<img src="assets/x.png">',
      );
      // 有宽度时两种调用写出同一行。
      expect(
        markup.toMarkdown(width: 320, asTag: true),
        markup.toMarkdown(width: 320),
      );
      // 还是要能读回来。
      final ImageMarkup again = ImageMarkup.parseLine(
        markup.toMarkdown(asTag: true),
      )!;
      expect(again.source, 'assets/x.png');
      expect(again.alt, '图片');
      expect(again.width, isNull);
    });

    test('round-trips both forms', () {
      const List<ImageMarkup> cases = <ImageMarkup>[
        ImageMarkup(source: 'assets/x.png'),
        ImageMarkup(source: 'assets/x.png', alt: '图片'),
        ImageMarkup(source: 'assets/x y.png', alt: 'a]b"c'),
        ImageMarkup(source: 'https://example.com/x.png', alt: '远程'),
        ImageMarkup(source: 'assets/x.png', alt: '图片', width: 320),
        ImageMarkup(source: 'assets/x.png', width: 320.5),
      ];
      for (final ImageMarkup markup in cases) {
        final ImageMarkup again = ImageMarkup.parseLine(markup.toMarkdown())!;
        expect(again.source, markup.source, reason: markup.toMarkdown());
        expect(again.alt, markup.alt, reason: markup.toMarkdown());
        expect(again.width, markup.width, reason: markup.toMarkdown());
      }
    });
  });

  group('moveSourceLine', () {
    test('往下搬：整行连着自己的换行一起走', () {
      const String text = 'a\nb\nc';
      final ({String text, int caret, int delta})? moved = moveSourceLine(
        text: text,
        lineStart: 0,
        lineEnd: 1,
        insertAt: 4,
      );
      expect(moved, isNotNull);
      expect(moved!.text, 'b\na\nc');
      expect(moved.caret, 2, reason: '光标落在搬完之后这一行的行首');
      expect(moved.delta, 2);
    });

    test('往上搬：文末那一行没有自己的换行，就吃掉上一行那个', () {
      const String text = 'a\nb\nc';
      final ({String text, int caret, int delta})? moved = moveSourceLine(
        text: text,
        lineStart: 4,
        lineEnd: 5,
        insertAt: 0,
      );
      expect(moved!.text, 'c\na\nb');
      expect(moved.caret, 0);
      expect(moved.delta, -4);
    });

    test('搬到文末：不留下多余的换行', () {
      const String text = 'a\nb';
      final ({String text, int caret, int delta})? moved = moveSourceLine(
        text: text,
        lineStart: 0,
        lineEnd: 1,
        insertAt: 3,
      );
      expect(moved!.text, 'b\na');
      expect(moved.caret, 2);
    });

    test('落在自己身上或紧挨着自己：搬了等于没搬，返回 null', () {
      const String text = 'a\nb\nc';
      for (final int at in <int>[0, 2]) {
        expect(
          moveSourceLine(text: text, lineStart: 0, lineEnd: 1, insertAt: at),
          isNull,
          reason: 'insertAt=$at',
        );
      }
    });

    test('越界的落点一律不动', () {
      const String text = 'a\nb';
      expect(
        moveSourceLine(text: text, lineStart: 0, lineEnd: 1, insertAt: 99),
        isNull,
      );
      expect(
        moveSourceLine(text: text, lineStart: 0, lineEnd: 99, insertAt: 0),
        isNull,
      );
    });

    test('图片行搬家后仍然是自成一段的一整行', () {
      const String img = '<img src="a.png" width="200" alt="图">';
      final String text = '正文\n$img\n结尾';
      final int start = text.indexOf(img);
      final ({String text, int caret, int delta})? moved = moveSourceLine(
        text: text,
        lineStart: start,
        lineEnd: start + img.length,
        insertAt: text.length,
      );
      expect(moved!.text, '正文\n结尾\n$img');
      expect(ImageMarkup.parseLine(img), isNotNull);
    });
  });

  group('insertImageBlock', () {
    const String image = '![图片](assets/x.png)';

    test('an empty document becomes an image line plus a blank line', () {
      final ({String text, int caret}) out = insertImageBlock(
        text: '',
        at: 0,
        end: 0,
        imageLine: image,
      );
      expect(out.text, '$image\n');
      expect(out.caret, out.text.length);
    });

    test('at the start of the document the image owns the first paragraph', () {
      final ({String text, int caret}) out = insertImageBlock(
        text: '正文',
        at: 0,
        end: 0,
        imageLine: image,
      );
      expect(out.text, '$image\n正文');
      expect(out.caret, image.length + 1);
    });

    test('in the middle of a line the remainder moves below', () {
      final ({String text, int caret}) out = insertImageBlock(
        text: 'abc\ndef',
        at: 1,
        end: 1,
        imageLine: image,
      );
      expect(out.text, 'a\n$image\nbc\ndef');
      expect(out.caret, out.text.indexOf('bc'));
    });

    test('at an existing line start no extra leading newline is added', () {
      final ({String text, int caret}) out = insertImageBlock(
        text: 'abc\ndef',
        at: 4,
        end: 4,
        imageLine: image,
      );
      expect(out.text, 'abc\n$image\ndef');
      expect(out.caret, out.text.indexOf('def'));
    });

    test('at the end of a non-empty document the caret lands below', () {
      final ({String text, int caret}) out = insertImageBlock(
        text: 'abc',
        at: 3,
        end: 3,
        imageLine: image,
      );
      expect(out.text, 'abc\n$image\n');
      expect(out.caret, out.text.length);
    });

    test('at the end of a document that already ends in a newline', () {
      final ({String text, int caret}) out = insertImageBlock(
        text: 'abc\n',
        at: 4,
        end: 4,
        imageLine: image,
      );
      expect(out.text, 'abc\n$image\n');
      expect(out.caret, out.text.length);
    });

    test('replaces a selection and leaves the caret after the image', () {
      final ({String text, int caret}) out = insertImageBlock(
        text: 'abcdef',
        at: 2,
        end: 4,
        imageLine: image,
      );
      expect(out.text, 'ab\n$image\nef');
      expect(out.caret, out.text.indexOf('ef'));
    });
  });
}
