import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/dropped_link.dart';

/// 拖进来一条网页链接：认地址、认标题、写成 `[标题](地址)`。
/// 复刻 `super_clipboard` 在 Windows 上的那个解码 bug：把 UTF-8 字节按
/// UTF-16LE 每两个字节拼成一个字符（真机上浏览器给的 `text/html` 就是这样）。
String packAsUtf16(String text) {
  final List<int> bytes = utf8.encode(text);
  final List<int> units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

void main() {
  test('只有系统 URL：标题退回域名', () {
    final DroppedLink? link = parseDroppedLink(uri: 'https://www.bing.com/');
    expect(link, const DroppedLink(url: 'https://www.bing.com/'));
    expect(markdownLinkFor(link!), '[bing.com](https://www.bing.com/)');
  });

  test('浏览器附带的 HTML 里有锚文本：用它当标题', () {
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://www.bing.com/',
      html:
          '<meta charset="utf-8"><a href="https://www.bing.com/">必应 搜索</a>',
    );
    expect(link?.title, '必应 搜索');
    expect(markdownLinkFor(link!), '[必应 搜索](https://www.bing.com/)');
  });

  test('锚文本对不上这个地址时不乱用', () {
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://example.com/a',
      html: '<a href="https://other.test/x">别人的标题</a>',
    );
    expect(link?.title, isNull);
    expect(markdownLinkFor(link!), '[example.com](https://example.com/a)');
  });

  test('省协议的 href（//host/path）也认得出标题', () {
    // bilibili 这类站点导航里常见 `//game.bilibili.com/platform`：
    // 它不是完整 URL，但按拖进来的地址解析之后就是同一条链接。
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://game.bilibili.com/platform',
      html: '<a href="//game.bilibili.com/platform">游戏中心</a>',
    );
    expect(link?.title, '游戏中心');
    expect(
      markdownLinkFor(link!),
      '[游戏中心](https://game.bilibili.com/platform)',
    );
  });

  test('相对 href（/path）也认得出标题', () {
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://example.com/docs/start',
      html: '<a href="/docs/start">开始使用</a>',
    );
    expect(link?.title, '开始使用');
  });

  test('带追踪参数的同路径链接仍是同一条', () {
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://example.com/a',
      html: '<a href="https://example.com/a?spm_id_from=333.1">标题</a>',
    );
    expect(link?.title, '标题');
  });

  test('路径对不上但全页只有一个同站锚点时也用它', () {
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://game.bilibili.com/platform',
      html: '<a href="https://game.bilibili.com/">游戏中心</a>',
    );
    expect(link?.title, '游戏中心');
  });

  test('macOS 给的链接名优先', () {
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://example.com/a',
      name: '示例站点',
      html: '<a href="https://example.com/a">HTML 标题</a>',
    );
    expect(link?.title, '示例站点');
  });

  test('Windows 上被按 UTF-16 解坏的 HTML 也能还原出标题', () {
    // 真机日志里的形状：`<a data-v-…><span …>游戏中心</span></a>`，UTF-8 字节
    // 被当成 UTF-16 拼了一遍，正则一条锚点都找不到。
    const String html =
        '<a data-v-ec16de5b="" href="//game.bilibili.com/platform" '
        'target="_blank" class="left-entry__item-triiger"><!---->'
        '<span data-v-ec16de5b="" class="trigger-text">游戏中心</span>'
        '<!----></a>';
    final String broken = packAsUtf16(html);
    expect(broken.contains('<'), isFalse, reason: '乱码里不该有标签');

    final DroppedLink? link = parseDroppedLink(
      uri: 'https://game.bilibili.com/platform',
      html: broken,
    );
    expect(link?.title, '游戏中心');
    expect(
      markdownLinkFor(link!),
      '[游戏中心](https://game.bilibili.com/platform)',
    );
  });

  test('只有 URL 和一段文字、没有 HTML：用那段文字当标题', () {
    // 有些浏览器拖链接只给 URL + 显示文字，不给 HTML 片段。
    final DroppedLink? link = parseDroppedLink(
      uri: 'https://game.bilibili.com/platform',
      plainText: '游戏中心',
    );
    expect(link?.title, '游戏中心');
  });

  test('纯文本里夹着一行地址：两行以上是「一段文字」，不当链接', () {
    // 拖一段带着网址的笔记过来，网址只是这段文字的一部分；当成链接会把
    // 其余内容吞掉。它落到 `parseDroppedText` 手里，原样插入。
    const String text = '必应搜索\nhttps://www.bing.com/\n';
    expect(parseDroppedLink(plainText: text), isNull);
    expect(parseDroppedText(plainText: text), '必应搜索\nhttps://www.bing.com/');
  });

  test('纯文本只有一行地址：标题退回域名', () {
    final DroppedLink? link = parseDroppedLink(
      plainText: '  https://example.com/a  ',
    );
    expect(link, const DroppedLink(url: 'https://example.com/a'));
  });

  test('没有 URL 时用 HTML 里的第一个锚点', () {
    final DroppedLink? link = parseDroppedLink(
      html: '<a href="https://example.com/x">标题</a>',
    );
    expect(link, const DroppedLink(url: 'https://example.com/x', title: '标题'));
  });

  test('www. 补上 https，路径与查询原样保留', () {
    final DroppedLink? link = parseDroppedLink(
      uri: 'www.example.org/a/b?q=1#top',
    );
    expect(link?.url, 'https://www.example.org/a/b?q=1#top');
    expect(markdownLinkFor(link!), '[example.org](https://www.example.org/a/b?q=1#top)');
  });

  test('不是网页的东西一概不认', () {
    expect(parseDroppedLink(uri: 'file:///C:/notes/a.md'), isNull);
    expect(parseDroppedLink(uri: 'javascript:alert(1)'), isNull);
    expect(parseDroppedLink(uri: 'ftp://example.com/a'), isNull);
    expect(parseDroppedLink(plainText: '一段普通的文字'), isNull);
    expect(parseDroppedLink(), isNull);
  });

  test('标题里的方括号、地址里的圆括号都转义', () {
    final DroppedLink link = DroppedLink(
      url: 'https://example.com/a(b)',
      title: '标题 [一]',
    );
    expect(
      markdownLinkFor(link),
      '[标题 \\[一\\]](https://example.com/a%28b%29)',
    );
  });

  test('插入：落在指定偏移处，光标停在链接后面', () {
    const TextEditingValue before = TextEditingValue(
      text: '开头结尾',
      selection: TextSelection.collapsed(offset: 2),
    );
    final TextEditingValue after = insertDroppedLink(
      before,
      2,
      '[示例](https://example.com)',
    );
    expect(after.text, '开头[示例](https://example.com)结尾');
    expect(after.selection, const TextSelection.collapsed(offset: 2 + 25));
  });
}
