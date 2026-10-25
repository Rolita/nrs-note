import 'package:flutter/material.dart' show InlineSpan, TextSpan, TextStyle;

import '../theme/app_palette.dart';

/// 一行 HTML 源码里的一段，按它在标签里的角色分类。
///
/// 图片行的源码是 `<img src="…" width="677" alt="图片">`：这一行不是散文，
/// 是一个标签。整行染成一个颜色（链接色）会让人以为它是可点的链接，所以按
/// 词法着色——标签名、属性名、属性值、标点各一个色，和代码编辑器一样。
enum HtmlTokenKind {
  /// `<`、`>`、`/>`、`=`、引号：标点，压暗。
  punctuation,

  /// 标签名：`img`。
  tag,

  /// 属性名：`src`、`width`、`alt`。
  attribute,

  /// 属性值，**不含**两边的引号。
  value,

  /// 标签之外的字。
  plain,
}

/// [HtmlTokenKind] 的一段源码区间，左闭右开。
class HtmlToken {
  const HtmlToken({
    required this.start,
    required this.end,
    required this.kind,
  });

  final int start;
  final int end;
  final HtmlTokenKind kind;

  @override
  String toString() => 'HtmlToken($start..$end, $kind)';

  @override
  bool operator ==(Object other) =>
      other is HtmlToken &&
      other.start == start &&
      other.end == end &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(start, end, kind);
}

/// 把 [text] 切成带角色的片段。
///
/// 只认「标签」这一层：一个 `<`、标签名、若干 `name=value`、一个 `>`。不建树、
/// 不配对，因为这个函数只服务于**一行**源码的着色。认不出来的字符一律当标点，
/// 保证不死循环、也保证区间始终递增不重叠。
List<HtmlToken> htmlTokens(String text) {
  final List<HtmlToken> out = <HtmlToken>[];
  int i = 0;

  while (i < text.length) {
    if (text[i] != '<') {
      final int start = i;
      while (i < text.length && text[i] != '<') {
        i++;
      }
      out.add(HtmlToken(start: start, end: i, kind: HtmlTokenKind.plain));
      continue;
    }

    out.add(HtmlToken(start: i, end: i + 1, kind: HtmlTokenKind.punctuation));
    i++;
    if (i < text.length && text[i] == '/') {
      out.add(HtmlToken(start: i, end: i + 1, kind: HtmlTokenKind.punctuation));
      i++;
    }

    final int nameStart = i;
    while (i < text.length && _isNameChar(text.codeUnitAt(i))) {
      i++;
    }
    if (i > nameStart) {
      out.add(HtmlToken(start: nameStart, end: i, kind: HtmlTokenKind.tag));
    }

    // 属性区。空格不产出片段——[htmlSourceSpan] 会把缝补成 plain。
    while (i < text.length) {
      final int code = text.codeUnitAt(i);
      if (_isSpace(code)) {
        i++;
        continue;
      }
      if (text[i] == '>') {
        out.add(HtmlToken(start: i, end: i + 1, kind: HtmlTokenKind.punctuation));
        i++;
        break;
      }
      if (text[i] == '/' && i + 1 < text.length && text[i + 1] == '>') {
        out.add(HtmlToken(start: i, end: i + 2, kind: HtmlTokenKind.punctuation));
        i += 2;
        break;
      }

      final int attrStart = i;
      while (i < text.length && _isAttrChar(text.codeUnitAt(i))) {
        i++;
      }
      if (i == attrStart) {
        // 认不出来的字符（游离的引号、中文标点）：当一个字符的标点，往前走一格。
        out.add(HtmlToken(start: i, end: i + 1, kind: HtmlTokenKind.punctuation));
        i++;
        continue;
      }
      out.add(HtmlToken(start: attrStart, end: i, kind: HtmlTokenKind.attribute));

      while (i < text.length && _isSpace(text.codeUnitAt(i))) {
        i++;
      }
      if (i >= text.length || text[i] != '=') continue;
      out.add(HtmlToken(start: i, end: i + 1, kind: HtmlTokenKind.punctuation));
      i++;
      while (i < text.length && _isSpace(text.codeUnitAt(i))) {
        i++;
      }
      if (i < text.length && (text[i] == '"' || text[i] == "'")) {
        final String quote = text[i];
        out.add(HtmlToken(start: i, end: i + 1, kind: HtmlTokenKind.punctuation));
        i++;
        final int valueStart = i;
        while (i < text.length && text[i] != quote) {
          i++;
        }
        if (i > valueStart) {
          out.add(
            HtmlToken(start: valueStart, end: i, kind: HtmlTokenKind.value),
          );
        }
        if (i < text.length) {
          out.add(
            HtmlToken(start: i, end: i + 1, kind: HtmlTokenKind.punctuation),
          );
          i++;
        }
      } else {
        final int valueStart = i;
        while (i < text.length &&
            !_isSpace(text.codeUnitAt(i)) &&
            text[i] != '>') {
          i++;
        }
        if (i > valueStart) {
          out.add(
            HtmlToken(start: valueStart, end: i, kind: HtmlTokenKind.value),
          );
        }
      }
    }
  }
  return out;
}

/// [kind] 在这一套配色下的颜色。
///
/// 用的是主题里现成的语义色，不另开一套调色板：标签取 `danger`（红）、属性名
/// 取 `warning`（琥珀）、属性值取 `success`（绿）、标点取 `textTertiary`。这三
/// 个色本来就是给「需要区分的东西」准备的，两套明暗配色下都验过对比度。
TextStyle htmlTokenStyle(HtmlTokenKind kind, TextStyle base, AppPalette p) =>
    switch (kind) {
      HtmlTokenKind.punctuation => base.copyWith(color: p.textTertiary),
      HtmlTokenKind.tag => base.copyWith(color: p.danger),
      HtmlTokenKind.attribute => base.copyWith(color: p.warning),
      HtmlTokenKind.value => base.copyWith(color: p.success),
      HtmlTokenKind.plain => base,
    };

/// 一行 HTML 源码的着色结果。拼起来的字与 [text] 逐字符相等。
TextSpan htmlSourceSpan(String text, TextStyle base, AppPalette p) {
  final List<InlineSpan> children = <InlineSpan>[];
  int cursor = 0;
  for (final HtmlToken token in htmlTokens(text)) {
    if (token.start > cursor) {
      children.add(TextSpan(text: text.substring(cursor, token.start)));
    }
    children.add(
      TextSpan(
        text: text.substring(token.start, token.end),
        style: htmlTokenStyle(token.kind, base, p),
      ),
    );
    cursor = token.end;
  }
  if (cursor < text.length) {
    children.add(TextSpan(text: text.substring(cursor)));
  }
  return TextSpan(style: base, children: children);
}

bool _isSpace(int code) =>
    code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

bool _isNameChar(int code) =>
    (code >= 0x41 && code <= 0x5A) ||
    (code >= 0x61 && code <= 0x7A) ||
    (code >= 0x30 && code <= 0x39) ||
    code == 0x2D || // -
    code == 0x5F; // _

bool _isAttrChar(int code) =>
    _isNameChar(code) ||
    code == 0x3A || // :
    code == 0x2E; // .
