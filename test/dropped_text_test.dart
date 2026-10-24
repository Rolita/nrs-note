import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/dropped_link.dart';

/// 拖进来一段文字：原样落进 `.md`，只归一换行与首尾空行。
///
/// 与 `dropped_link_test.dart` 里同一个复刻：`super_clipboard` 在 Windows 上
/// 会把 UTF-8 字节按 UTF-16LE 拼一遍。
String packAsUtf16(String text) {
  final List<int> bytes = utf8.encode(text);
  final List<int> units = <int>[];
  for (int i = 0; i < bytes.length; i += 2) {
    final int low = bytes[i];
    final int high = i + 1 < bytes.length ? bytes[i + 1] : 0;
    units.add(low | (high << 8));
  }
  return String.fromCharCodes(units);
}

void main() {
  test('一段普通文字原样读出来', () {
    expect(parseDroppedText(plainText: '一段普通的文字'), '一段普通的文字');
  });

  test('中间的换行、缩进、行尾空格都不动', () {
    const String text = '第一行\n  缩进的一行  \n第三行';
    expect(parseDroppedText(plainText: text), text);
  });

  test('CRLF / CR 统一成 LF', () {
    expect(parseDroppedText(plainText: '甲\r\n乙\r丙'), '甲\n乙\n丙');
  });

  test('拖一整行时末尾那个换行是拖拽边界，不插空行', () {
    expect(parseDroppedText(plainText: '一整行\n'), '一整行');
    expect(parseDroppedText(plainText: '\n\n一整行\n\n'), '一整行');
  });

  test('开头的 BOM 去掉', () {
    expect(parseDroppedText(plainText: '\uFEFF标题'), '标题');
  });

  test('全是空白等于没拖进来文字', () {
    expect(parseDroppedText(plainText: '   '), isNull);
    expect(parseDroppedText(plainText: '\n\n\n'), isNull);
    expect(parseDroppedText(plainText: ''), isNull);
    expect(parseDroppedText(), isNull);
  });

  test('Markdown 记号不替用户转义：拖进来什么就是什么', () {
    // 和 Ctrl+V 一致。转义会让源文件变成一堆反斜杠，比渲染出强调更难读。
    expect(parseDroppedText(plainText: '*强调*'), '*强调*');
    expect(parseDroppedText(plainText: '# 不是标题'), '# 不是标题');
    expect(parseDroppedText(plainText: '[不是链接]'), '[不是链接]');
  });

  test('富文本拖放没有纯文本时，按块级标签折行读成文字', () {
    const String html =
        '<meta charset="utf-8"><p>第一段</p><p>第二段<br>换行</p>';
    expect(parseDroppedText(html: html), '第一段\n\n第二段\n换行');
  });

  test('列表项折行、脚本与样式不算正文', () {
    const String html =
        '<style>.a{color:red}</style><ul><li>甲</li><li>乙</li></ul>'
        '<script>alert(1)</script>';
    expect(parseDroppedText(html: html), '甲\n乙');
  });

  test('实体与数字引用都解开', () {
    const String html = '<p>a &amp; b &lt;c&gt; &#20320;&#x597d;</p>';
    expect(parseDroppedText(html: html), 'a & b <c> 你好');
  });

  test('纯文本和富文本都在时，以纯文本为准', () {
    expect(
      parseDroppedText(plainText: '纯文本', html: '<p>富文本</p>'),
      '纯文本',
    );
  });

  test('文件拖放不当作文字：文件名不是正文', () {
    // 拖一张图或一个 pdf 进来，系统也会给一份「路径」文字，不能落进正文。
    expect(parseDroppedText(plainText: r'C:\Users\a\图片.png', file: true), isNull);
    expect(parseDroppedText(html: '<p>截图</p>', file: true), isNull);
  });

  test('被按 UTF-16 解坏的 HTML 也能降级成文字', () {
    final String broken = packAsUtf16('<p>游戏中心</p><p>第二段</p>');
    expect(broken.contains('<'), isFalse);
    expect(parseDroppedText(html: broken), '游戏中心\n\n第二段');
  });

  test('调试日志里的 HTML 是还原过的、截断过的', () {
    // 原始载荷是满屏乱码，原样打进日志会让人以为正文坏了。
    final String broken = packAsUtf16('<p>游戏中心</p>');
    expect(describeDroppedHtml(broken), '<p>游戏中心</p>');

    final String long = describeDroppedHtml('<p>${'甲' * 500}</p>', max: 10);
    expect(long.startsWith('<p>甲'), isTrue);
    expect(long, contains('共 507 字符'));
    expect(long.length, lessThan(40));
  });
}
