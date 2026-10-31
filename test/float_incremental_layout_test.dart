import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// 一张靠右浮动的图会让它下面那几行变窄。这些行的宽度不是自己的属性，
/// 增量重排只按行高平移——**重建**它们就会丢掉图片让出的那一段：
/// 图片旁边整块变空、正文掉到图片下面（用户原话「图片旁边怎么变成空白了」）。
///
/// 所以引擎必须认识「哪些行不能增量重建」，并且只在**最终重建区间**碰到
/// 它们时才退回全量。这个文件锁住这两条。
void main() {
  const TextStyle base = TextStyle(fontSize: 15, height: 1.6);

  String document() {
    final StringBuffer b = StringBuffer();
    b.writeln('# 标题');
    b.writeln();
    b.writeln('```dart');
    b.writeln('void main() {}');
    b.writeln('```');
    b.writeln();
    b.writeln('<img src="a.png" width="200" align="right" alt="图">');
    b.writeln();
    for (int i = 0; i < 12; i++) {
      b.writeln('图片旁边的正文第 $i 行，长长长长长长长长长长长长长长长长');
      b.writeln();
    }
    for (int i = 0; i < 30; i++) {
      b.writeln('图片下方的正文第 $i 行');
      b.writeln();
    }
    return b.toString();
  }

  /// 每行（顶部，高度，左内边距，右内边距）。
  List<(double, double, double, double)> geometry(LineDocumentLayout l) =>
      <(double, double, double, double)>[
        for (final LaidOutLine line in l.laidOut)
          (line.top, line.height, line.insets.left, line.insets.right),
      ];

  test('靠右浮动的图会把下面几行挤窄', () {
    final String text = document();
    final LiveImageBlocks images = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => text,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => null,
      onLineInvalidated: (_) {},
    );
    addTearDown(images.dispose);

    final LineDocumentLayout layout = layoutLines(
      text: text,
      baseStyle: base,
      contentWidth: 600,
      blockFor: images.blockFor,
    );
    addTearDown(layout.dispose);

    expect(layout.hasFloats, isTrue, reason: '这份文档里有一张靠右浮动的图');
    expect(
      layout.laidOut.any((LaidOutLine line) => line.insets.right > 0),
      isTrue,
      reason: '图片下面应该有几行被挤窄',
    );
  });

  test('在图片下方改字：要么退回全量，要么与全量重排逐行一致', () {
    final String before = document();
    final LiveImageBlocks images = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => before,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => null,
      onLineInvalidated: (_) {},
    );
    addTearDown(images.dispose);

    final LineDocumentLayout old = layoutLines(
      text: before,
      baseStyle: base,
      contentWidth: 600,
      blockFor: images.blockFor,
    );
    addTearDown(old.dispose);

    final int at = before.indexOf('图片下方的正文第 25 行');
    expect(at, greaterThan(0));
    final String after = before.replaceRange(at, at, 'x');

    final LineDocumentLayout? incremental = relayoutOnEdit(
      previous: old,
      text: after,
      editStart: at,
      removedLength: 0,
      insertedLength: 1,
      baseStyle: base,
      contentWidth: 600,
      blockFor: images.blockFor,
    );
    final LineDocumentLayout full = layoutLines(
      text: after,
      baseStyle: base,
      contentWidth: 600,
      blockFor: images.blockFor,
    );
    addTearDown(full.dispose);
    if (incremental == null) return;
    addTearDown(incremental.dispose);
    expect(geometry(incremental), geometry(full));
  });

  test('在绕排区里改字必须退回全量', () {
    final String before = document();
    final LiveImageBlocks images = LiveImageBlocks(
      palette: AppPalette.midnight,
      text: () => before,
      selection: () => const TextSelection.collapsed(offset: -1),
      imageProviderFor: (_) => null,
      onLineInvalidated: (_) {},
    );
    addTearDown(images.dispose);

    final LineDocumentLayout old = layoutLines(
      text: before,
      baseStyle: base,
      contentWidth: 600,
      blockFor: images.blockFor,
    );
    addTearDown(old.dispose);

    final int wrapped = old.laidOut.indexWhere(
      (LaidOutLine line) => line.insets.right > 0,
    );
    expect(wrapped, greaterThanOrEqualTo(0), reason: '要有一行被图片挤窄');
    final int at = old.laidOut[wrapped].source.start + 1;
    final String after = before.replaceRange(at, at, 'x');

    expect(
      relayoutOnEdit(
        previous: old,
        text: after,
        editStart: at,
        removedLength: 0,
        insertedLength: 1,
        baseStyle: base,
        contentWidth: 600,
        blockFor: images.blockFor,
      ),
      isNull,
      reason: '绕排区里的行重建会丢掉图片让出的宽度',
    );
  });
}
