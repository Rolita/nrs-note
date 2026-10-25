import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/dropped_link.dart';
import 'package:nrs/core/utils/image_markup.dart';

/// 拖一张**网页图片**进来：要认出它是图，写成 `<img src="…">`；而拖一条链接
/// 仍然是 `[标题](地址)`。两者是同一个载荷的两种归宿，认错一边都很难受。
///
/// 复刻 `super_clipboard` 在 Windows 上的那个解码 bug：把 UTF-8 字节按
/// UTF-16LE 每两个字节拼成一个字符（真机上浏览器给的 `text/html` 就是这样）。
///
/// 奇数字节时补一个空格：这里两个字节才能拼一个字符，丢掉最后一个字节会把
/// HTML 结尾的 `>` 也一起丢掉——浏览器发的是完整载荷，不会少这一下。
String packAsUtf16(String text) {
  List<int> bytes = utf8.encode(text);
  if (bytes.length.isOdd) bytes = <int>[...bytes, 0x20];
  final List<int> units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

void main() {
  group('认图片', () {
    test('HTML 里的 <img>：地址与 alt 都认出来', () {
      final DroppedImage? image = parseDroppedImage(
        uri: 'https://img.test/cat.png',
        html: '<meta charset="utf-8"><img src="https://img.test/cat.png" '
            'alt="一只猫" width="640">',
      );
      expect(
        image,
        const DroppedImage(url: 'https://img.test/cat.png', alt: '一只猫'),
      );
      expect(
        markdownImageFor(image!),
        '<img src="https://img.test/cat.png" alt="一只猫">',
      );
    });

    test('写出来的那一行能被图片块认回去', () {
      final DroppedImage image = parseDroppedImage(
        uri: 'https://img.test/a.png',
        html: '<img src="https://img.test/a.png" alt="图">',
      )!;
      final ImageMarkup? parsed = ImageMarkup.parseLine(markdownImageFor(image));
      expect(parsed?.source, 'https://img.test/a.png');
      expect(parsed?.alt, '图');
    });

    test('相对 src 按系统 URL 补全', () {
      final DroppedImage? image = parseDroppedImage(
        uri: 'https://site.test/post/1',
        html: '<img src="/img/a.png">',
      );
      expect(image?.url, 'https://site.test/img/a.png');
      expect(image?.alt, isNull);
    });

    test('懒加载：src 是 data: 占位图时用 data-src', () {
      final DroppedImage? image = parseDroppedImage(
        uri: 'https://site.test/post/1',
        html: '<img src="data:image/gif;base64,R0lGOD" '
            'data-src="https://cdn.test/real.jpg">',
      );
      expect(image?.url, 'https://cdn.test/real.jpg');
    });

    test('只有 srcset 时取第一个候选', () {
      final DroppedImage? image = parseDroppedImage(
        uri: 'https://site.test/post/1',
        html: '<img srcset="/a-1x.png 1x, /a-2x.png 2x">',
      );
      expect(image?.url, 'https://site.test/a-1x.png');
    });

    test('alt 看着像个地址时不拿它当标题', () {
      final DroppedImage? image = parseDroppedImage(
        html: '<img src="https://img.test/a.png" '
            'alt="https://site.test/a.png">',
      );
      expect(image?.alt, isNull);
      expect(
        markdownImageFor(image!),
        '<img src="https://img.test/a.png">',
      );
    });

    test('没有 HTML，但地址本身是张图', () {
      expect(
        parseDroppedImage(uri: 'https://img.test/photo.JPG')?.url,
        'https://img.test/photo.JPG',
      );
      expect(
        parseDroppedImage(plainText: 'https://img.test/a.webp')?.url,
        'https://img.test/a.webp',
      );
    });

    test('图床把格式写在查询参数里', () {
      expect(
        parseDroppedImage(uri: 'https://img.test/show?id=9&format=webp')?.url,
        isNotNull,
      );
    });

    test('Windows 上那份「UTF-8 被当 UTF-16 解」的 HTML 也能认', () {
      final DroppedImage? image = parseDroppedImage(
        uri: 'https://img.test/a.png',
        html: packAsUtf16(
          '<img src="https://img.test/a.png" alt="中文标题">',
        ),
      );
      expect(image?.url, 'https://img.test/a.png');
      expect(image?.alt, '中文标题');
    });
  });

  group('不认成图片', () {
    test('拖的是锚点：还是链接', () {
      const String html = '<a href="https://site.test/a.jpg">看图</a>';
      expect(
        parseDroppedImage(uri: 'https://site.test/a.jpg', html: html),
        isNull,
        reason: '指向 .jpg 的链接也是链接，别把图贴进正文',
      );
      final DroppedLink? link = parseDroppedLink(
        uri: 'https://site.test/a.jpg',
        html: html,
      );
      expect(markdownLinkFor(link!), '[看图](https://site.test/a.jpg)');
    });

    test('普通网页地址不是图片', () {
      expect(
        parseDroppedImage(
          uri: 'https://site.test/post/1',
          html: '<a href="https://site.test/post/1">标题</a>',
        ),
        isNull,
      );
    });

    test('多行纯文本是「一段文字」，不是图片', () {
      expect(
        parseDroppedImage(
          plainText: 'https://img.test/a.png\n第二行',
        ),
        isNull,
      );
    });

    test('只有 data: / blob: 的图认不出来，退回链接', () {
      expect(
        parseDroppedImage(html: '<img src="data:image/png;base64,AAAA">'),
        isNull,
      );
      expect(
        parseDroppedImage(html: '<img src="blob:https://site.test/x">'),
        isNull,
      );
    });

    test('file:// 的图片文件不当作网页图片', () {
      expect(
        parseDroppedImage(uri: 'file:///C:/pics/a.png'),
        isNull,
        reason: '本地图片要走文件那条路，不能写进 <img src> 当网址',
      );
    });
  });

  group('图片与链接不会互相抢', () {
    test('同一份载荷：先认图，不再认成链接', () {
      const String html = '<img src="https://img.test/a.png" alt="图">';
      const String url = 'https://img.test/a.png';
      expect(parseDroppedImage(uri: url, html: html)?.url, url);
      // 链接解析对它也成立（就是那张图的地址），所以判定顺序必须是图在前。
      expect(parseDroppedLink(uri: url, html: html)?.url, url);
    });

    test('链接里的图片（<a><img></a>）算图片', () {
      final DroppedImage? image = parseDroppedImage(
        uri: 'https://img.test/a.png',
        html: '<a href="https://site.test/p">'
            '<img src="https://img.test/a.png"></a>',
      );
      expect(image?.url, 'https://img.test/a.png');
    });
  });
}
