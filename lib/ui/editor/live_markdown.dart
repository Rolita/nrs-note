/// Typora / Obsidian-style *live* Markdown styling.
///
/// The whole trick is that this is still one plain `TextEditingController`: the
/// editor text is byte-for-byte the Markdown the user typed, and only the
/// *painting* changes. Markup punctuation that has nothing to reveal is drawn at
/// zero size so it visually disappears while still occupying its exact character
/// positions — which is what keeps the caret, selection and IME in sync.
///
/// ## The invariant: the tree must be exactly as long as the text
///
/// `RenderEditable` computes pointer hit-testing and caret positions from the
/// tree [TextEditingController.buildTextSpan] returns; `TextEditingValue`
/// selections are offsets into the *source*. One character more or less in the
/// tree and every offset after it slides — the caret lands left of the click and
/// clicking a line reveals its neighbour.
///
/// A [WidgetSpan] is not free: it occupies exactly one character position in the
/// paragraph (the object-replacement character `U+FFFC`). So a decoration may
/// only ever stand in for **one** source character — the first character of the
/// syntax it replaces — and the rest of that syntax has to be emitted as
/// collapsed text behind it. [_decoration] + [_swallowed] are the only
/// sanctioned way to draw a widget here; nothing else may change the length.
///
/// Two rules decide what is revealed:
///
/// * **Inline markers** (`**`, `` ` ``, `[[…]]`, `#tag`) come back only when the
///   caret actually touches that token — the line you are typing on otherwise
///   looks finished, which is what makes live editing feel calm.
/// * **Block markers** (`#`, `>`, a fence, a rule) come back when the caret
///   enters the block, so the raw syntax is one keystroke away. Bullets and
///   checkboxes are the exception: they are drawn as markers *even on the caret's
///   line*, because otherwise typing `- ` and a space produces no visible change
///   at all and the editor looks broken.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/theme/app_palette.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/markdown_outline.dart';
import '../../core/theme/app_tokens.dart';
import '../preview/code_palette.dart';
import '../preview/syntax_highlighter.dart';

// Layer direction: block_syntax → typography → widgets → table_model →
// table_measure / table_render → spans. Every part shares this library's
// private scope on purpose, so the arrow is a convention, not a compiler
// guarantee: a lower layer reaching up is a sign the symbol belongs elsewhere.
part 'live_markdown/block_syntax.dart';
part 'live_markdown/spans.dart';
part 'live_markdown/layout.dart';
part 'live_markdown/inline.dart';
part 'live_markdown/typography.dart';
part 'live_markdown/table_model.dart';
part 'live_markdown/table_measure.dart';
part 'live_markdown/table_render.dart';
part 'live_markdown/table_api.dart';
part 'live_markdown/widgets.dart';
part 'live_markdown/widgets_render.dart';
