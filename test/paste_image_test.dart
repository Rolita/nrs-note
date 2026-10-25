import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/ui/common/notices.dart';
import 'package:nrs/ui/editor/editor_context_menu.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// The paste route in full: text first, the clipboard bitmap only when the
/// clipboard holds no text, and every refusal leaving the document untouched.
void main() {
  const MethodChannel imageChannel = MethodChannel('nrs/clipboard');
  final Uint8List png = Uint8List.fromList(<int>[
    137,
    80,
    78,
    71,
    13,
    10,
    26,
    10,
  ]);

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The platform clipboard as the editor sees it. A null [text] is the
  /// screenshot case: copying an image writes no text flavour at all.
  void clipboard(String? text) {
    messenger().setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      if (call.method == 'Clipboard.getData') {
        if (text == null) return null;
        return <String, dynamic>{'text': text};
      }
      return null;
    });
    addTearDown(
      () => messenger().setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  /// The native `nrs/clipboard` channel. [reads] counts how often the editor
  /// went looking for an image.
  List<String> mockImageChannel({Uint8List? bytes}) {
    final List<String> reads = <String>[];
    messenger().setMockMethodCallHandler(imageChannel, (MethodCall call) async {
      reads.add(call.method);
      if (bytes == null) return null;
      return <String, Object?>{'png': bytes};
    });
    addTearDown(() => messenger().setMockMethodCallHandler(imageChannel, null));
    return reads;
  }

  Future<void> paste(WidgetTester tester, FocusNode focus) async {
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> undo(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  /// Mounts the real editor (and nothing else) over [controller], with the
  /// notice controller in reach so refusals are observable.
  Future<void> pump(
    WidgetTester tester, {
    required MarkdownSourceController controller,
    required FocusNode focus,
    required NoticeController notices,
    Future<String?> Function(Uint8List pngBytes)? save,
    String documentId = 'note-a',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.dark),
        home: NoticeScope(
          controller: notices,
          child: Scaffold(
            body: MarkdownEditor(
              controller: controller,
              focusNode: focus,
              scrollController: ScrollController(),
              fontSize: 15.5,
              documentId: documentId,
              savePastedImage: save,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('剪贴板有文字时走文本粘贴，绝不去读图片', (WidgetTester tester) async {
    clipboard('粘进来的字');
    final List<String> reads = mockImageChannel(bytes: png);
    bool saved = false;
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '正文',
    );
    controller.selection = const TextSelection.collapsed(offset: 2);
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: (Uint8List bytes) async {
        saved = true;
        return 'assets/image_1.png';
      },
    );

    await paste(tester, focus);

    expect(controller.text, '正文粘进来的字');
    expect(reads, isEmpty, reason: '文字优先：有文本就不该碰图片通道');
    expect(saved, isFalse);
  });

  testWidgets('剪贴板没有文字时粘贴图片，一次撤销即可整行消失', (WidgetTester tester) async {
    clipboard(null);
    final List<String> reads = mockImageChannel(bytes: png);
    Uint8List? received;
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '正文',
    );
    controller.selection = const TextSelection.collapsed(offset: 2);
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: (Uint8List bytes) async {
        received = bytes;
        return 'assets/image_20261024_120000.png';
      },
    );

    await paste(tester, focus);

    expect(reads, <String>['readImage']);
    expect(received, png);
    expect(
      controller.text,
      '正文\n<img src="assets/image_20261024_120000.png" alt="图片">\n',
      reason: '图片必须独占一段，前后都要换行；写法是标签，和拖过宽度的那些一致',
    );
    expect(notices.current, isNull, reason: '成功粘贴不提示');

    await undo(tester);

    expect(controller.text, '正文', reason: '粘贴只占一步撤销，Ctrl+Z 应整行还原');
  });

  testWidgets('右键「粘贴」可用图片，「以纯文本形式粘贴」永远不用', (WidgetTester tester) async {
    clipboard(null);
    mockImageChannel(bytes: png);
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '正文',
    );
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: (Uint8List bytes) async => 'assets/from_menu.png',
    );

    int imageAttempts = 0;
    final LineEditableTextState state = tester.state<LineEditableTextState>(
      find.byType(LineEditableText),
    );
    List<MenuNode> menu() => buildEditorMenu(
      value: controller.value,
      onApply: (fn) {},
      state: state,
      onPasteImage: () async {
        imageAttempts++;
        return true;
      },
    );

    MenuAction row(List<MenuNode> nodes, String label) => nodes
        .whereType<MenuAction>()
        .firstWhere((MenuAction a) => a.label == label);

    row(menu(), '以纯文本形式粘贴').onPressed!();
    await tester.pumpAndSettle();
    expect(imageAttempts, 0, reason: '纯文本粘贴绝不能悄悄塞一张图进来');

    row(menu(), '粘贴').onPressed!();
    await tester.pumpAndSettle();
    expect(imageAttempts, 1);
  });

  testWidgets('代码围栏里拒绝粘贴图片，正文不变', (WidgetTester tester) async {
    clipboard(null);
    final List<String> reads = mockImageChannel(bytes: png);
    bool saved = false;
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '```\ncode\n```',
    );
    controller.selection = const TextSelection.collapsed(offset: 6);
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: (Uint8List bytes) async {
        saved = true;
        return 'assets/x.png';
      },
    );

    await paste(tester, focus);

    expect(controller.text, '```\ncode\n```');
    expect(notices.current?.message, '表格或代码块里不能粘贴图片');
    expect(notices.current?.kind, NoticeKind.error);
    expect(reads, isEmpty, reason: '拒绝发生在读剪贴板之前');
    expect(saved, isFalse);
  });

  testWidgets('表格行上拒绝粘贴图片，正文不变', (WidgetTester tester) async {
    clipboard(null);
    mockImageChannel(bytes: png);
    bool saved = false;
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '| 甲 | 乙 |\n| --- | --- |\n',
    );
    controller.selection = const TextSelection.collapsed(offset: 2);
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: (Uint8List bytes) async {
        saved = true;
        return 'assets/x.png';
      },
    );

    await paste(tester, focus);

    expect(controller.text, '| 甲 | 乙 |\n| --- | --- |\n');
    expect(notices.current?.message, '表格或代码块里不能粘贴图片');
    expect(saved, isFalse);
  });

  testWidgets('读取图片期间切换笔记，图片不会插进新笔记', (WidgetTester tester) async {
    clipboard(null);
    mockImageChannel(bytes: png);
    final Completer<void> saveStarted = Completer<void>();
    final Completer<String?> saveDone = Completer<String?>();
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '甲笔记正文',
    );
    controller.selection = const TextSelection.collapsed(offset: 5);
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    Future<String?> save(Uint8List bytes) {
      if (!saveStarted.isCompleted) saveStarted.complete();
      return saveDone.future;
    }

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: save,
    );

    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();
    expect(saveStarted.isCompleted, isTrue, reason: '保存还没开始，测试前提不成立');

    // 宿主切到另一篇笔记：同一个 State，documentId 变了。
    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: save,
      documentId: 'note-b',
    );
    saveDone.complete('assets/late.png');
    await tester.pumpAndSettle();

    expect(controller.text, '甲笔记正文', reason: '等待期间换了笔记，迟到的图片不能落进当前正文');
    expect(notices.current, isNull);
  });

  testWidgets('保存抛异常时提示「图片保存失败」，正文不变', (WidgetTester tester) async {
    clipboard(null);
    mockImageChannel(bytes: png);
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '正文',
    );
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: (Uint8List bytes) async => throw StateError('disk full'),
    );

    await paste(tester, focus);

    expect(controller.text, '正文');
    expect(notices.current?.message, '图片保存失败');
    expect(notices.current?.kind, NoticeKind.error);
  });

  testWidgets('存储不支持时提示，正文不变', (WidgetTester tester) async {
    clipboard(null);
    mockImageChannel(bytes: png);
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '正文',
    );
    final FocusNode focus = FocusNode();
    final NoticeController notices = NoticeController();
    addTearDown(focus.dispose);
    addTearDown(controller.dispose);

    await pump(
      tester,
      controller: controller,
      focus: focus,
      notices: notices,
      save: (Uint8List bytes) async => null,
    );

    await paste(tester, focus);

    expect(controller.text, '正文');
    expect(notices.current?.message, '当前存储不支持保存图片');
  });
}
