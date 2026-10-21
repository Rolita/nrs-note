part of '../live_markdown.dart';

/// Everything the inline scanner needs besides the text itself.
class _Ctx {
  _Ctx({
    required this.p,
    required this.caretA,
    required this.caretB,
    required this.selA,
    required this.selB,
    required this.contentWidth,
    this.direction = TextDirection.ltr,
    this.textScaler = TextScaler.noScaling,
    this.plain = false,
    this.hoverA = -1,
    this.hoverB = -1,
    this.onTagTap,
    this.onWikilinkTap,
  });

  final AppPalette p;
  final int caretA;
  final int caretB;

  /// The **live** selection, which the wash follows even while [caretA]/[caretB]
  /// are frozen for a pointer gesture. A rendered chip cannot show the wash
  /// painted behind the field, so it tints itself from this instead.
  final int selA;
  final int selB;

  final double contentWidth;
  final TextDirection direction;

  /// The scale the paragraph will lay the text out at. A table column is sized
  /// from measured text, so the measurement has to be taken under the same
  /// scale the painted text will get — otherwise every column is off by the
  /// user's font-size setting.
  final TextScaler textScaler;

  /// True while laying out text that will be **repainted** by a render object
  /// (a table cell): chips need a [BuildContext] to build, so inside a cell
  /// every inline token falls back to its plain styled text instead.
  final bool plain;

  /// 指针悬停的标签区间（这一行内部偏移）。按行排版没有 widget 可以接
  /// `MouseRegion`，悬停状态由编辑器命中后传进来，只影响标签的颜色。
  final int hoverA;
  final int hoverB;
  final void Function(String tag)? onTagTap;
  final void Function(String target)? onWikilinkTap;

  /// True when the caret (or the reveal selection) overlaps `[a, b]`.
  bool touched(int a, int b) => caretA >= 0 && caretB >= a && caretA <= b;

  /// [a, b] 是否就是指针悬停的那一个标签。
  bool hovered(int a, int b) =>
      hoverA >= 0 && hoverA <= a && hoverB >= b;

  /// True when a **range** of the live selection intersects `[a, b]`.
  bool selected(int a, int b) => selA >= 0 && selB > selA && selB > a && selA < b;
}

/// Builds the styled span tree for live mode.
///
/// [liveSelection] is the selection the wash follows when it differs from
/// [selection]: a pointer gesture freezes [selection] to keep markers from
/// reflowing text, but the bands — and a chip's selected tint — still have to
/// follow the pointer.
List<InlineSpan> buildLiveSpans({
  required String text,
  required TextStyle base,
  required AppPalette p,
  required TextSelection selection,
  TextSelection? liveSelection,
  double contentWidth = 680,
  TextScaler textScaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
  void Function(String tag)? onTagTap,
  void Function(String target)? onWikilinkTap,
}) {
  final List<String> lines = text.split('\n');
  final int n = lines.length;
  final List<int> starts = List<int>.filled(n + 1, 0);
  for (int i = 0; i < n; i++) {
    starts[i + 1] = starts[i] + lines[i].length + 1;
  }

  final List<_Kind> kinds = List<_Kind>.filled(n, _Kind.paragraph);
  final List<int> levels = List<int>.filled(n, 0);
  final List<int> fences = List<int>.filled(n, -1);
  final List<_Fence> blocks = <_Fence>[];

  // ---------------------------------------------------------------- pass one
  bool inFence = false;
  int current = -1;
  for (int i = 0; i < n; i++) {
    final String line = lines[i];
    final Match? f = _fenceRe.firstMatch(line);
    if (f != null) {
      if (!inFence) {
        current = blocks.length;
        blocks.add(_Fence(open: i, language: _fenceLanguage(f.group(3) ?? '')));
        inFence = true;
      } else {
        blocks[current].close = i;
        inFence = false;
        current = -1;
      }
      kinds[i] = _Kind.fence;
      fences[i] = current < 0 ? blocks.length - 1 : current;
      continue;
    }
    if (inFence) {
      kinds[i] = _Kind.code;
      fences[i] = current;
      continue;
    }
    if (_setextRe.hasMatch(line) &&
        i > 0 &&
        kinds[i - 1] == _Kind.paragraph &&
        lines[i - 1].trim().isNotEmpty) {
      kinds[i - 1] = _Kind.heading;
      levels[i - 1] = 1;
      kinds[i] = _Kind.setext;
      continue;
    }

    final Match? h = _headingRe.firstMatch(line);
    if (h != null) {
      kinds[i] = _Kind.heading;
      levels[i] = h.group(2)!.length;
      continue;
    }
    if (line.trimLeft().startsWith('|')) {
      final bool divider = isTableDivider(line);
      if (divider && i > 0 && kinds[i - 1] == _Kind.table) {
        kinds[i - 1] = _Kind.tableHeader;
      }
      kinds[i] = divider ? _Kind.tableDivider : _Kind.table;
      continue;
    }
    if (_taskRe.hasMatch(line)) {
      kinds[i] = _Kind.task;
      continue;
    }
    if (_orderedRe.hasMatch(line)) {
      kinds[i] = _Kind.ordered;
      continue;
    }
    if (_ruleRe.hasMatch(line) && line.trim().isNotEmpty) {
      kinds[i] = _Kind.rule;
      continue;
    }
    if (_bulletRe.hasMatch(line)) {
      kinds[i] = _Kind.bullet;
      continue;
    }
    if (_quoteRe.hasMatch(line)) {
      kinds[i] = _Kind.quote;
      continue;
    }
  }

  // Only a closed fence has a known body; highlight it once, up front.
  for (final _Fence b in blocks) {
    final int end = b.close < 0 ? n : b.close;
    final List<String> body = lines.sublist(b.open + 1, end.clamp(0, n));
    if (body.isEmpty) continue;
    final List<List<CodeToken>> tokens = highlightCode(
      body.join('\n'),
      b.language,
    );
    // Defensive: a mismatch would mean the highlighter reshaped the source,
    // and a reshaped source would desynchronise the caret.
    b.tokens = tokens.length == body.length ? tokens : null;
  }

  // ---------------------------------------------------------------- the caret
  final Set<int> active = <int>{};
  int caretA = -1;
  int caretB = -1;
  if (selection.isValid && selection.start >= 0) {
    caretA = selection.start.clamp(0, text.length);
    caretB = selection.end.clamp(0, text.length);
    final int la = _lineOf(text, caretA);
    final int lb = _lineOf(text, caretB);
    for (int i = la; i <= lb && i < n; i++) {
      active.add(i);
    }
  }

  final Set<int> revealedFences = <int>{};
  for (final int i in active) {
    if (fences[i] >= 0) revealedFences.add(fences[i]);
  }

  /// Where the **wash** sits, as opposed to where the markers are revealed.
  /// During a drag the reveal is frozen at pointer-down so markers cannot
  /// reflow text under the pointer, but the wash still has to track the live
  /// selection — measuring table bands from the frozen caret painted a strip of
  /// *prose* rows (one full-width band per table row) for the whole gesture.
  final TextSelection bandsSel = liveSelection ?? selection;
  int bandA = -1;
  int bandB = -1;
  if (bandsSel.isValid && bandsSel.start >= 0) {
    bandA = bandsSel.start.clamp(0, text.length);
    bandB = bandsSel.end.clamp(0, text.length);
  }

  // --------------------------------------------------------------- the tables
  //
  // A table is the one block that is not painted as text. Cells only line up
  // with the row above them if something decides the column widths for the
  // whole table at once, and a line of text cannot ask its neighbours how wide
  // they are. So every table block is measured here, once, and each row is
  // handed a fixed width and the share each column gets of it.
  final _Ctx ctx = _Ctx(
    p: p,
    caretA: caretA,
    caretB: caretB,
    selA: bandA,
    selB: bandB,
    contentWidth: contentWidth,
    direction: direction,
    textScaler: textScaler,
    onTagTap: onTagTap,
    onWikilinkTap: onWikilinkTap,
  );

  // ---------------------------------------------------------------- pass two
  final double row = _lineHeightOf(base);
  final List<InlineSpan> out = <InlineSpan>[];
  for (int i = 0; i < n; i++) {
    final String line = lines[i];
    final bool on = active.contains(i);
    final int at = starts[i];
    // The break belongs to the line it closes, and a fenced block's rows are
    // shorter than prose. Leaving the newline at the body style made every code
    // row step by the body's line height (28px) instead of the code's (20px) —
    // the compact block the reference shows was impossible.
    TextStyle? breakStyle;

    switch (kinds[i]) {
      case _Kind.fence:
        final int fenceId = fences[i];
        final _Fence? block = _blockAt(blocks, fenceId);
        final bool revealed = on || revealedFences.contains(fenceId);
        if (revealed) {
          out.add(
            TextSpan(
              text: line,
              style: _markerVisible(base, p, accented: true),
            ),
          );
          break;
        }
        // The fence line is folded away. The slab behind the whole block is
        // painted by `CodeBlockPainter` — a `TextStyle` background can only hug
        // a run, which is what turned every line into a stripe of its own
        // width. The opening fence only reserves the card's header row; the
        // closing one collapses to nothing and leaves the bottom air to the
        // slab. The language label is painted with the slab, in the top-right
        // corner, so it does not push the code down a whole line.
        final bool opens = block != null && block.open == i;
        out.add(
          _codeFenceSpacer(
            ctx.contentWidth,
            opens ? _kCodeHeaderHeight : 0,
          ),
        );
        out.add(_swallowed(line, base));
        breakStyle = _collapsed(base);

      case _Kind.code:
        final _Fence? block = _blockAt(blocks, fences[i]);
        final int index = block == null ? -1 : i - block.open - 1;
        final List<List<CodeToken>>? all = block?.tokens;
        final List<CodeToken>? tokens =
            (all != null && index >= 0 && index < all.length)
            ? all[index]
            : null;
        final TextStyle style = _codeLine(base, p);
        breakStyle = style;
        out.add(
          TextSpan(
            style: style,
            children: tokens == null
                ? <InlineSpan>[TextSpan(text: line)]
                : codeHighlightSpans(tokens, p.isDark),
          ),
        );

      case _Kind.setext:
        // The `===` underline has done its job once the heading is styled. It
        // is painted transparent rather than hidden size so the row keeps its
        // height and a caret landing on it stays visible.
        out.add(
          TextSpan(
            text: line,
            style: on ? _markerVisible(base, p) : _invisible(base),
          ),
        );

      case _Kind.heading:
        final Match? m = _headingRe.firstMatch(line);
        final TextStyle h = _headingStyle(base, p, levels[i]);
        if (m == null) {
          // A setext heading: the line itself is the heading.
          out.addAll(_inline(line, h, at, ctx));
          break;
        }
        out.add(TextSpan(text: m.group(1), style: base));
        // On the caret's line the markers scale with the heading, exactly like
        // Typora — a 12px `#` next to a 26px heading looks broken.
        out.add(
          TextSpan(
            text: m.group(2),
            style: on ? _markerVisible(h, p, accented: true) : _collapsed(base),
          ),
        );
        out.add(
          TextSpan(
            text: m.group(3),
            style: on ? _markerVisible(h, p) : _collapsed(base),
          ),
        );
        out.addAll(
          _inline(
            m.group(4) ?? '',
            h,
            at + m.group(1)!.length + m.group(2)!.length + m.group(3)!.length,
            ctx,
          ),
        );
        final String? tail = m.group(5);
        if (tail != null) {
          out.add(
            TextSpan(
              text: tail,
              style: on ? _markerVisible(h, p) : _collapsed(base),
            ),
          );
        }

      case _Kind.bullet:
        final Match? m = _bulletRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        // ⭐ The bullet is drawn as a bullet *even on the caret's line*: the
        // moment the user taps space after `-` the line has to look like a list,
        // otherwise the keystroke appears to have done nothing.
        final String marker = '${m.group(2)}${m.group(3)}';
        out.addAll(_indentRun(m.group(1)!, base, p));
        out.add(_bulletDot(p));
        out.add(_swallowed(marker, base));
        out.addAll(
          _inline(
            m.group(4)!,
            base,
            at + m.group(1)!.length + marker.length,
            ctx,
          ),
        );

      case _Kind.ordered:
        final Match? m = _orderedRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        out.addAll(_indentRun(m.group(1)!, base, p));
        out.add(
          TextSpan(
            text: '${m.group(2)}${m.group(3)}',
            style: _numberStyle(base, p),
          ),
        );
        out.add(TextSpan(text: m.group(4), style: base));
        out.addAll(
          _inline(
            m.group(5)!,
            base,
            at +
                m.group(1)!.length +
                m.group(2)!.length +
                m.group(3)!.length +
                m.group(4)!.length,
            ctx,
          ),
        );

      case _Kind.task:
        final Match? m = _taskRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        final bool done = m.group(4)!.toLowerCase().contains('x');
        final String lead = m.group(2)!;
        final int gap = m.group(3)!.length;
        out.addAll(_indentRun(m.group(1)!, base, p));
        final String marker = '$lead${m.group(3)}${m.group(4)}${m.group(5)}';
        final TextStyle body = done
            // A ticked item steps *one* rung down the text ramp and stays
            // legible; the deletion is carried by the rule, not by fading the
            // words into the page. Dropping it two rungs (to `textTertiary`)
            // made the whole line — rule included — a grey smudge, which is
            // what "删除线不够明显" was about. This is the level the reference
            // (Obsidian's done list) keeps its struck lines at.
            ? _struck(base.copyWith(color: p.textSecondary))
            : base;
        final int contentAt = at + m.group(1)!.length + marker.length;
        // The box stays a box on the caret's line too; the raw `- [ ] ` is one
        // keystroke away in any other editor, and a box that turns into text
        // when you click it is just confusing.
        //
        // A numbered list can carry a box as well (`1. [ ] 事`, which is what
        // the toolbar's "ordered task list" writes). The number is *not* hidden
        // there — it is part of the marker column, so the box lines up with the
        // checkbox of a plain `- [ ]` item rather than replacing the number.
        if (_isOrderedLead(lead)) {
          // The number belongs to the sentence, so a ticked item strikes it
          // too, and it recedes with the rest of the line instead of staying
          // lit up in accent next to greyed-out words. `_numberStyle` is kept
          // underneath for its tabular figures: only the colour and the rule
          // change, so the digit column does not reflow the moment the box is
          // ticked.
          out.add(
            TextSpan(
              text: lead,
              style: done
                  ? _struck(
                      _numberStyle(base, p).copyWith(color: p.textSecondary),
                    )
                  : _numberStyle(base, p),
            ),
          );
          // The gap keeps the space's width but paints nothing: dropping it to a
          // zero-size span would butt the box up against the number.
          out.add(TextSpan(text: m.group(3)!, style: _invisible(base)));
          out.add(
            _taskBox(p, done, at + m.group(1)!.length + lead.length + gap),
          );
          // Skip the `[` — the box stands in for it.
          out.add(
            TextSpan(
              text: marker.substring(lead.length + gap + 1),
              style: _collapsed(base),
            ),
          );
        } else {
          out.add(_taskBox(p, done, at + m.group(1)!.length));
          out.add(_swallowed(marker, base));
        }
        out.addAll(
          _inline(m.group(6)!, base, contentAt, ctx, forceStyle: body),
        );

      case _Kind.quote:
        final Match? m = _quoteRe.firstMatch(line);
        if (m == null) {
          out.addAll(_inline(line, base, at, ctx));
          break;
        }
        final TextStyle quoted = base.copyWith(color: p.textSecondary);
        out.add(TextSpan(text: m.group(1), style: quoted));
        final String marker = '${m.group(2)}${m.group(3)}';
        if (on) {
          out.add(
            TextSpan(
              text: marker,
              style: _markerVisible(base, p, accented: true),
            ),
          );
        } else {
          out.add(_quoteBar(p, base, marker, ctx.textScaler));
          out.add(_swallowed(marker, base));
        }
        out.addAll(
          _inline(
            m.group(4)!,
            quoted,
            at + m.group(1)!.length + marker.length,
            ctx,
          ),
        );

      case _Kind.rule:
        if (on) {
          out.add(TextSpan(text: line, style: _markerVisible(base, p)));
          break;
        }
        // A real horizontal rule: the first dash becomes the line itself and
        // the remaining ones collapse behind it, so the row keeps its height
        // and the line spans the column whatever the window width.
        out.add(
          _decoration(MarkdownDividerLine(color: p.rule, height: row)),
        );
        out.add(_swallowed(line, base));

      case _Kind.tableHeader:
      case _Kind.table:
      case _Kind.tableDivider:
        // 实时表格不在段落里排版：整行由 `LiveTableBlocks` 自绘（见
        // `line_layout/line_block_view.dart`），段落里只剩源码。这条分支只服务
        // 旧接口与行内语法测试，表格在编辑器里不会走到这里。
        out.add(TextSpan(text: line, style: base));

      case _Kind.paragraph:
        out.addAll(_inline(line, base, at, ctx));
    }

    if (i != n - 1) {
      out.add(TextSpan(text: '\n', style: breakStyle ?? base));
    }
  }
  return out;
}
