import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/utils/html_source.dart';

/// 图片行的源码是 `<img …>`：这一行要按 HTML 词法着色，而不是整行一个颜色。
///
/// 词法只服务「一行源码的着色」，所以这里盯两件事：切出来的区间必须首尾相接、
/// 不重叠，且拼起来逐字符等于原文（否则着色会让字错位）；每个词的角色要对。
void main() {
  const String line =
      '<img src="assets/image_20261025_135654.png" width="677" alt="图片">';

  List<String> slices(String text) => <String>[
    for (final HtmlToken t in htmlTokens(text)) text.substring(t.start, t.end),
  ];

  test('区间递增、不重叠，拼起来就是原文', () {
    int cursor = 0;
    for (final HtmlToken t in htmlTokens(line)) {
      expect(t.start, greaterThanOrEqualTo(cursor), reason: '不能重叠或倒退');
      expect(t.end, greaterThan(t.start), reason: '不产出空片段');
      expect(t.end, lessThanOrEqualTo(line.length));
      cursor = t.end;
    }
  });

  test('标签名、属性名、属性值、标点各归各位', () {
    // 空格不产出片段（它们只是分隔符），所以这里是「去掉空格后的词表」。
    final List<(String, HtmlTokenKind)> expected = <(String, HtmlTokenKind)>[
      ('<', HtmlTokenKind.punctuation),
      ('img', HtmlTokenKind.tag),
      ('src', HtmlTokenKind.attribute),
      ('=', HtmlTokenKind.punctuation),
      ('"', HtmlTokenKind.punctuation),
      ('assets/image_20261025_135654.png', HtmlTokenKind.value),
      ('"', HtmlTokenKind.punctuation),
      ('width', HtmlTokenKind.attribute),
      ('=', HtmlTokenKind.punctuation),
      ('"', HtmlTokenKind.punctuation),
      ('677', HtmlTokenKind.value),
      ('"', HtmlTokenKind.punctuation),
      ('alt', HtmlTokenKind.attribute),
      ('=', HtmlTokenKind.punctuation),
      ('"', HtmlTokenKind.punctuation),
      ('图片', HtmlTokenKind.value),
      ('"', HtmlTokenKind.punctuation),
      ('>', HtmlTokenKind.punctuation),
    ];

    final List<HtmlToken> tokens = htmlTokens(line);
    final List<String> parts = slices(line);
    expect(parts, <String>[for (final (String t, _) in expected) t]);
    for (int i = 0; i < expected.length; i++) {
      expect(
        tokens[i].kind,
        expected[i].$2,
        reason: '「${expected[i].$1}」的角色不对',
      );
    }
  });

  test('自闭合标签与单引号也能认', () {
    final List<(String, HtmlTokenKind)> got = <(String, HtmlTokenKind)>[
      for (final HtmlToken t in htmlTokens("<img src='a.png' />"))
        ("<img src='a.png' />".substring(t.start, t.end), t.kind),
    ];
    expect(got, <(String, HtmlTokenKind)>[
      ('<', HtmlTokenKind.punctuation),
      ('img', HtmlTokenKind.tag),
      ('src', HtmlTokenKind.attribute),
      ('=', HtmlTokenKind.punctuation),
      ("'", HtmlTokenKind.punctuation),
      ('a.png', HtmlTokenKind.value),
      ("'", HtmlTokenKind.punctuation),
      ('/>', HtmlTokenKind.punctuation),
    ]);
  });

  test('不是标签的行整段当普通文字，不吞字', () {
    const String text = '![图](a.png)';
    final List<HtmlToken> tokens = htmlTokens(text);
    expect(tokens, <HtmlToken>[
      const HtmlToken(start: 0, end: text.length, kind: HtmlTokenKind.plain),
    ]);
    expect(
      htmlSourceSpan(text, const TextStyle(), AppPalette.light).toPlainText(),
      text,
    );
  });

  test('着色的结果逐字符等于原文，颜色按角色分开', () {
    const TextStyle base = TextStyle(fontSize: 15.5);
    final AppPalette p = AppPalette.light;
    final TextSpan span = htmlSourceSpan(line, base, p);

    expect(span.toPlainText(), line, reason: '着色不能动字');

    final List<TextSpan> children = span.children!.cast<TextSpan>();
    Color? colorOf(String text, HtmlTokenKind kind) => children
        .firstWhere((TextSpan s) => s.text == text && s.style?.color != null)
        .style
        ?.color;

    expect(colorOf('img', HtmlTokenKind.tag), p.danger);
    expect(colorOf('src', HtmlTokenKind.attribute), p.warning);
    expect(
      colorOf('assets/image_20261025_135654.png', HtmlTokenKind.value),
      p.success,
    );
    expect(colorOf('<', HtmlTokenKind.punctuation), p.textTertiary);
  });
}
