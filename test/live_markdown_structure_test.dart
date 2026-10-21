import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_tokens.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// A document that exercises every block kind and every inline marker the
/// renderer knows. The only thing a `part` split must never change is the
/// **shape** of the tree this produces, so the assertions here are about
/// structure, not pixels.
const String document = r'''# 标题一

正文 **粗体** *斜体* ~~删除~~ ==高亮== `代码` $公式$ %%注释%% [[双链]] ![[嵌入]] [链接](https://example.com) ![图](x.png) #标签

> 引用一行

- 项目一
  - 子项目
- [ ] 待办
- [x] 完成

---

```dart
void main() {}
```

| h1 | h2 |
| --- | ---: |
| a | 1 |
| b | 2 |
''';

void main() {
  const AppPalette palette = AppPalette.light;
  const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);

  final List<InlineSpan> spans = buildLiveSpans(
    text: document,
    base: base,
    p: palette,
    selection: const TextSelection.collapsed(offset: -1),
  );

  String painted() => spans.map((InlineSpan s) => s.toPlainText()).join();

  void walk(InlineSpan span, void Function(InlineSpan) visit) {
    visit(span);
    if (span is TextSpan && span.children != null) {
      for (final InlineSpan child in span.children!) {
        walk(child, visit);
      }
    }
  }

  List<T> collect<T extends InlineSpan>() {
    final List<T> out = <T>[];
    for (final InlineSpan span in spans) {
      walk(span, (InlineSpan s) {
        if (s is T) out.add(s);
      });
    }
    return out;
  }

  /// The style a character is actually painted with: every ancestor's style
  /// merged into the leaf's own. A highlighted token carries only its colour;
  /// the mono family lives on the code line's parent span.
  TextStyle? paintedStyle(String needle) {
    TextStyle? found;
    void visit(InlineSpan span, TextStyle? inherited) {
      if (found != null) return;
      final TextStyle? merged = span.style == null
          ? inherited
          : (inherited == null ? span.style : inherited.merge(span.style));
      if (span is TextSpan) {
        final bool hit = span.text != null && span.text!.contains(needle);
        if (hit) {
          found = merged;
          return;
        }
        for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
          visit(child, merged);
        }
      }
    }

    for (final InlineSpan span in spans) {
      visit(span, null);
    }
    return found;
  }

  test('the painted tree is exactly as long as the source', () {
    final String tree = painted();
    expect(tree.length, document.length, reason: 'span tree length changed');

    // Put the source back: every decoration stands in for one character.
    final StringBuffer rebuilt = StringBuffer();
    for (int i = 0; i < tree.length; i++) {
      rebuilt.write(tree[i] == '\uFFFC' ? document[i] : tree[i]);
    }
    expect(rebuilt.toString(), document, reason: 'source was reshaped');
  });

  test('every decoration is a WidgetSpan at its own source position', () {
    final List<WidgetSpan> widgets = collect<WidgetSpan>();
    // A fixture with one new decoration should make this number change on
    // purpose, which is exactly what a structure guard is for. 表格行不再是
    // 装饰：整行由行引擎自绘，不占段落里的字符位。
    expect(widgets.length, 13);
    expect(
      widgets.where((WidgetSpan w) => w.child is MarkdownTodoCheckbox).length,
      2,
    );
    expect(
      widgets.where((WidgetSpan w) => w.child is MarkdownDividerLine).length,
      1,
    );
    expect(
      widgets.where((WidgetSpan w) => w.child is MarkdownIndentGuides).length,
      1,
    );
  });

  test('heading, code and table keep their key styles', () {
    expect(paintedStyle('标题一')?.fontWeight, FontWeight.w600);
    expect(
      paintedStyle('标题一')!.fontSize!,
      greaterThan(base.fontSize!),
    );

    expect(paintedStyle('main')?.fontFamily, AppFonts.mono);

    // 表格不在段落里排版：整行由 `LiveTableBlocks` 自绘，所以这里改为断言
    // 同一套测量仍然把这块切成「表头 + 两行正文」，且首行仍认作表头。
    final List<TableGeometry> tables = measureTables(
      text: document,
      base: base,
      p: palette,
      contentWidth: 680,
    );
    expect(tables, hasLength(1));
    expect(tables.single.rows, hasLength(3));
    expect(tables.single.rows.first.header, isTrue);
    expect(tables.single.rows[1].header, isFalse);
  });
}
