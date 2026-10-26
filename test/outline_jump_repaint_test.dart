import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/data/models/note.dart';
import 'package:nrs/data/storage/canvas_store.dart';
import 'package:nrs/data/storage/note_store.dart';
import 'package:nrs/state/canvas_controller.dart';
import 'package:nrs/state/notes_controller.dart';
import 'package:nrs/state/settings_controller.dart';
import 'package:nrs/ui/editor/editor_pane.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/shell/app_shell.dart';

/// 大纲跳转必须「点击即显示」：位置瞬到、第一帧就画出目标行，不依赖鼠标
/// hover、也不依赖后续帧。
String longNote() {
  final List<String> lines = <String>[];
  for (int i = 0; i < 240; i++) {
    if (i % 20 == 5) {
      lines.add('## 小节 ${i ~/ 20}');
    } else if (i % 7 == 0) {
      lines.add('');
    } else {
      lines.add('第 $i 行的正文内容，用来把视口撑满。');
    }
  }
  return lines.join('\n');
}

class _VaultStore extends NoteStore {
  _VaultStore(this.notes);

  final List<Note> notes;

  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<Note>> loadAll() async => List<Note>.of(notes);

  @override
  Future<void> save(Note note, {String? previousPath}) async {
    notes.removeWhere((Note n) => n.id == note.id);
    notes.add(note);
  }

  @override
  Future<TrashEntry?> delete(Note note) async => null;
}

/// 文件树会读白板清单。这些用例只关心正文的绘制，所以给一个永远空着的
/// 存储——为了一份空清单去建真目录，只会让测试多一条失败的理由。
class _NoCanvasStore implements CanvasStore {
  @override
  Future<void> init() async {}

  @override
  String get location => 'memory:';

  @override
  bool get supportsNativeFiles => false;

  @override
  Future<List<CanvasRef>> list() async => const <CanvasRef>[];

  @override
  Future<String> read(String relativePath) async =>
      throw UnimplementedError();

  @override
  Future<void> write(String relativePath, String contents) async {}

  @override
  Future<String> create(String folderPath, {String? title}) async => '';
}

void main() {
  testWidgets('大纲跳转后第一帧就画出目标段落，不靠 hover', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final String text = longNote();
    final List<String> lines = text.split('\n');
    final Note note = Note(
      id: 'a',
      title: '长文',
      body: text,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = await SettingsController.load();
    final NotesController notes = NotesController(store: _VaultStore(<Note>[note]));
    addTearDown(notes.dispose);
    await notes.bootstrap();
    notes.select(note.id);
    final CanvasController canvas = CanvasController(store: _NoCanvasStore());
    addTearDown(canvas.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<NotesController>.value(value: notes),
          ChangeNotifierProvider<CanvasController>.value(value: canvas),
        ],
        child: MaterialApp(
          theme: AppTheme.build(settings.paletteFor(Brightness.light)),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final EditorPaneState pane = tester.state<EditorPaneState>(
      find.byType(EditorPane),
    );

    // 一段远离首屏的标题。
    final int target = 165;
    expect(lines[target].startsWith('## '), isTrue);

    field.debugFullLayouts = 0;
    pane.goToHeading(target);
    // 点击后的**第一帧**：内容就必须已经画出来，不能等到鼠标移动。
    await tester.pump();

    expect(
      field.debugPaintedLines,
      greaterThan(0),
      reason: '跳转后的第一帧必须画出正文，空白留到 hover 才出现就是 bug',
    );
    final ({double top, double bottom}) band = field.visibleDocumentBounds;
    final double lineTop = field.lineTopFor(target);
    expect(
      lineTop <= band.bottom && lineTop >= band.top - 1,
      isTrue,
      reason: '目标行必须落在这一帧的可见区间里（band=$band lineTop=$lineTop）',
    );
    expect(
      band.bottom - band.top,
      greaterThan(0),
      reason: '可见区间不能是空段',
    );
    expect(field.debugFullLayouts, 0, reason: '跳转不该触发整篇重排');

    await tester.pump();
    expect(pane.jumping, isFalse, reason: '跳转收尾必须复位，否则大纲不再跟随');
  });

  testWidgets('跳到最后一行时可见区间仍然有效', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final String text = longNote();
    final Note note = Note(
      id: 'a',
      title: '长文',
      body: text,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 2),
    );

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsController settings = await SettingsController.load();
    final NotesController notes = NotesController(store: _VaultStore(<Note>[note]));
    addTearDown(notes.dispose);
    await notes.bootstrap();
    notes.select(note.id);
    final CanvasController canvas = CanvasController(store: _NoCanvasStore());
    addTearDown(canvas.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsController>.value(value: settings),
          ChangeNotifierProvider<NotesController>.value(value: notes),
          ChangeNotifierProvider<CanvasController>.value(value: canvas),
        ],
        child: MaterialApp(
          theme: AppTheme.build(settings.paletteFor(Brightness.light)),
          home: const AppShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final RenderLineEditable field = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first;
    final EditorPaneState pane = tester.state<EditorPaneState>(
      find.byType(EditorPane),
    );

    pane.goToHeading(text.split('\n').length - 1);
    await tester.pump();

    final ({double top, double bottom}) band = field.visibleDocumentBounds;
    expect(band.bottom - band.top, greaterThan(0));
    expect(field.debugPaintedLines, greaterThan(0));
  });
}
