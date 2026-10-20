import 'package:flutter/material.dart';

import 'syntax_highlighter.dart';

/// Colour set for highlighted code, derived from the active brightness.
///
/// Kept in its own file so both the rendered view and the live editor can share
/// one definition — a code block must not change colour just because the user
/// moved the caret.
///
/// These ten constants are **deliberately** outside the palette system: syntax
/// highlighting is a discipline of its own (a shifted hue on a keyword is a
/// different language), and two well-tuned sets keyed off brightness read better
/// than 25 tokens re-tinted per scheme. The honest cost: a user's custom
/// palette does not reach code blocks. Revisiting that is a later job, not an
/// oversight.
@immutable
class CodePalette {
  const CodePalette({
    required this.plain,
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

  /// The colour of everything the highlighter has no opinion about. The
  /// reference draws code brighter than prose secondary, so plain tokens do not
  /// disappear next to the coloured ones.
  final Color plain;
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
    plain: Color(0xFF5C5C66),
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
    plain: Color(0xFFDADADA),
    keyword: Color(0xFFE0DE71),
    string: Color(0xFF44CF6E),
    number: Color(0xFFE0A46A),
    comment: Color(0xFF686868),
    type: Color(0xFFE2C27A),
    func: Color(0xFF53DFDD),
    punct: Color(0xFFDADADA),
    meta: Color(0xFF9E90F7),
    badge: Color(0xFFB3B3B3),
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
