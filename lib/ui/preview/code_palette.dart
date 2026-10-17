import 'package:flutter/material.dart';

import 'syntax_highlighter.dart';

/// Colour set for highlighted code, derived from the active brightness.
///
/// Kept in its own file so both the rendered view and the live editor can share
/// one definition — a code block must not change colour just because the user
/// moved the caret.
@immutable
class CodePalette {
  const CodePalette({
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.type,
    required this.func,
    required this.punct,
    required this.meta,
    required this.badge,
  });

  final Color keyword;
  final Color string;
  final Color number;
  final Color comment;
  final Color type;
  final Color func;
  final Color punct;
  final Color meta;
  final Color badge;

  static const CodePalette light = CodePalette(
    keyword: Color(0xFF9C36B5),
    string: Color(0xFF3F8F4F),
    number: Color(0xFFB76B01),
    comment: Color(0xFF98938A),
    type: Color(0xFFB07D18),
    func: Color(0xFF3E6FD6),
    punct: Color(0xFF8A857C),
    meta: Color(0xFF6B5BD2),
    badge: Color(0xFF9C968B),
  );

  static const CodePalette dark = CodePalette(
    keyword: Color(0xFFC88BE8),
    string: Color(0xFF8FCB92),
    number: Color(0xFFE0A46A),
    comment: Color(0xFF6A7180),
    type: Color(0xFFE2C27A),
    func: Color(0xFF6FAEF0),
    punct: Color(0xFF8B93A1),
    meta: Color(0xFF9E90F7),
    badge: Color(0xFF71717E),
  );

  Color operator [](TokenKind kind) => switch (kind) {
    TokenKind.keyword => keyword,
    TokenKind.string => string,
    TokenKind.number => number,
    TokenKind.comment => comment,
    TokenKind.type => type,
    TokenKind.func => func,
    TokenKind.punct => punct,
    TokenKind.meta => meta,
    TokenKind.plain => const Color(0x00000000),
  };

  static CodePalette forDark(bool isDark) => isDark ? dark : light;
}
