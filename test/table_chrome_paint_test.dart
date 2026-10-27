import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/app_theme.dart';
import 'package:nrs/core/utils/table_selection.dart';
import 'package:nrs/ui/editor/line_layout/line_editable_text.dart';
import 'package:nrs/ui/editor/line_layout/render_line_editable.dart';
import 'package:nrs/ui/editor/live_markdown.dart';
import 'package:nrs/ui/editor/markdown_editor.dart';

/// 抓手 chrome 的绘制回归测试。
///
/// 命中判定、悬停可见性与光标全走全局坐标，绘制却有两处坏过：一处把行内
/// 坐标的控件矩形减掉 `_globalOrigin` 再平移文档原点（画布是文档坐标系，
/// 结果落在行内原始坐标上）；一处是字段的绘制裁剪只看自己的盒子，而块行
/// `insets` 为零、行抓手落在负 x 上，永远被裁掉。两处叠加的结果正是
/// 「按得动、拖得动，悬停就是看不见」：按下命中在滚动视图的 padding 里
/// 成立，绘制却被字段的裁剪吃掉。
///
/// 这里把编辑器放进带偏移的 Padding（真实应用里标题栏 + 侧栏必然推离
/// 窗口原点），从真实管线抓像素确认按钮真的画在 chrome 报告的全局矩形上。
void main() {
  testWidgets('偏移编辑器里悬停后，抓手按钮画在全局矩形上', (WidgetTester tester) async {
    tablePointerPosition.value = null;
    tableDragPreview.value = null;
    tableResizePreview.value = null;
    addTearDown(() {
      tablePointerPosition.value = null;
      tableDragPreview.value = null;
      tableResizePreview.value = null;
    });
    final MarkdownSourceController controller = MarkdownSourceController(
      text: '| a | b |\n| --- | --- |\n| c | d |',
    );
    final FocusNode focus = FocusNode();
    addTearDown(focus.dispose);
    final GlobalKey boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.midnight),
        home: Scaffold(
          body: RepaintBoundary(
            key: boundaryKey,
            child: Padding(
              padding: const EdgeInsets.only(left: 200, top: 120),
              child: ColoredBox(
                color: AppPalette.midnight.surface,
                child: MarkdownEditor(
                  controller: controller,
                  focusNode: focus,
                  scrollController: ScrollController(),
                  fontSize: 15.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    focus.requestFocus();
    await tester.pumpAndSettle();

    final List<TableRowChrome> rows = tester.allRenderObjects
        .whereType<RenderLineEditable>()
        .first
        .tableRows()
        .toList()
      ..sort(
        (TableRowChrome a, TableRowChrome b) =>
            a.chromeRowIndex.compareTo(b.chromeRowIndex),
      );
    final List<TableChromeTarget> grips = <TableChromeTarget>[
      for (final TableRowChrome row in rows)
        ...row.chromeTargets().where(
          (TableChromeTarget t) => t.kind == TableChromeKind.rowHandle,
        ),
    ];
    expect(grips, hasLength(2), reason: '表头 + 数据行（分隔行不渲染）');

    // 真实悬停事件落在第一枚抓手的全局中心上。
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(grips.first.rect.center));
    await tester.pump();

    final LineEditableText field = tester.widget<LineEditableText>(
      find.byKey(const Key('nrs-editor-field')),
    );
    expect(field.mouseCursor, SystemMouseCursors.grab);
    final List<TableChromeTarget> visible = <TableChromeTarget>[
      for (final TableRowChrome r in rows) ...r.chromeVisible(),
    ];
    expect(
      visible.where(
        (TableChromeTarget t) => t.kind == TableChromeKind.rowHandle,
      ),
      hasLength(1),
      reason: '指针在哪一行，就只露那一行的抓手',
    );

    final RenderRepaintBoundary boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    // ⛔ `toImage` 在别的线程上光栅化：widget 测试里必须走 `runAsync`，
    // 直接调用永远等不到完成，测试挂到被框架杀死。
    late ByteData bytes;
    late int width;
    late int height;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      width = image.width;
      height = image.height;
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    final double scale = width / boundary.size.width;

    bool isColor(int x, int y, Color color) {
      if (x < 0 || y < 0 || x >= width || y >= height) return false;
      final int fill = color.toARGB32();
      final int i = (y * width + x) * 4;
      return (bytes.getUint8(i) - (fill >> 16 & 0xFF)).abs() <= 4 &&
          (bytes.getUint8(i + 1) - (fill >> 8 & 0xFF)).abs() <= 4 &&
          (bytes.getUint8(i + 2) - (fill & 0xFF)).abs() <= 4;
    }

    int countIn(Rect logical, Color color) {
      final int x0 = (logical.left * scale).round();
      final int y0 = (logical.top * scale).round();
      final int x1 = (logical.right * scale).round();
      final int y1 = (logical.bottom * scale).round();
      int n = 0;
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          if (isColor(x, y, color)) n++;
        }
      }
      return n;
    }

    // 指针停在第一枚抓手上：只有那一枚反相成 accent，另一枚根本不露。
    expect(
      countIn(grips.first.rect, AppPalette.midnight.accent),
      greaterThan(120),
      reason: '被指的抓手按钮反相画在全局矩形里',
    );
    expect(
      countIn(grips.last.rect, AppPalette.midnight.surfaceRaised),
      0,
      reason: '指针不在的那一行不该露抓手',
    );
    // 悬停帧里还没有选区，浮起层色应该只出现在指针那枚按钮上——按钮之外
    // 不该再有（旧的裁剪 bug 会把按钮整个吃掉，图里一处都找不到）。
    int outside = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if (!isColor(x, y, AppPalette.midnight.surfaceRaised)) continue;
        final Offset p = Offset(x / scale, y / scale);
        if (grips.any((TableChromeTarget g) => g.rect.contains(p))) continue;
        outside++;
      }
    }
    expect(outside, lessThan(20), reason: '按钮之外不该再有任何浮起层像素');

    // 贴着行分界悬停（旧逻辑里相邻两行的 ±6 带重叠 12px，第二枚会一起
    // 画出来）：跨界的瞬间旧抓手必须让位，画面上不能残留两枚。
    final double rowBoundary = rows.first.chromeBounds().bottom;
    await tester.sendEventToBinding(
      mouse.hover(Offset(grips.first.rect.center.dx, rowBoundary - 2)),
    );
    await tester.pump();
    final List<TableChromeTarget> atBoundary = <TableChromeTarget>[
      for (final TableRowChrome r in rows) ...r.chromeVisible(),
    ];
    expect(
      atBoundary.where(
        (TableChromeTarget t) => t.kind == TableChromeKind.rowHandle,
      ),
      hasLength(1),
      reason: '贴着行分界也只有指针那一行的抓手',
    );
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage();
      bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
    });
    expect(
      countIn(grips.last.rect, AppPalette.midnight.surfaceRaised),
      0,
      reason: '上一枚抓手的按钮底色不得残留',
    );
    expect(
      countIn(grips.last.rect, AppPalette.midnight.accent),
      0,
      reason: '上一枚抓手也不得反相残留',
    );

    // 按下路径也走同一套全局矩形：点第二枚抓手选中第二行。
    await tester.tapAt(grips.last.rect.center);
    await tester.pumpAndSettle();
    expect(controller.intendedRange?.kind, TableRangeKind.rows);
    expect(controller.intendedRange?.firstRow, 1);
    expect(controller.intendedRange?.lastRow, 1);
  });
}
