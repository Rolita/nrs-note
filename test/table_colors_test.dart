import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/theme/app_palette.dart';
import 'package:nrs/core/theme/table_colors.dart';
import 'package:nrs/core/utils/table_model.dart';
import 'package:nrs/ui/editor/line_layout/line_layout_engine.dart';
import 'package:nrs/ui/editor/live_markdown.dart';

/// Cell colors: the directive stores a name or a literal, and the renderer
/// resolves both against the live palette.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const TableCellStyle amberFill = TableCellStyle(
    fill: CellColor.token(CellColorToken.amber),
  );
  const TableCellStyle redText = TableCellStyle(
    text: CellColor.token(CellColorToken.red),
  );
  const TableCellStyle customFill = TableCellStyle(
    fill: CellColor.custom(0xFF111111),
  );

  group('resolution', () {
    test('fill tokens follow the palette', () {
      expect(
        tableCellFill(AppPalette.midnight, amberFill),
        const Color(0xFF634A12),
      );
      expect(
        tableCellFill(AppPalette.midnight, amberFill),
        isNot(AppPalette.midnight.warningSoft),
        reason: '高亮底色是专用的深底，不是面板的浅软色',
      );
      expect(
        tableCellFill(AppPalette.midnight, customFill),
        const Color(0xFF111111),
      );
      expect(tableCellFill(AppPalette.midnight, const TableCellStyle()), isNull);
    });

    test('dark fills and inks are one highlighter set that clears AA', () {
      const Map<CellColorToken, (Color, Color)> expected =
          <CellColorToken, (Color, Color)>{
            CellColorToken.gray: (Color(0xFF36383F), Color(0xFFC2C5CC)),
            CellColorToken.amber: (Color(0xFF634A12), Color(0xFFF2C35C)),
            CellColorToken.green: (Color(0xFF235C3F), Color(0xFF6CDEA0)),
            CellColorToken.blue: (Color(0xFF1D4A73), Color(0xFF7FC4F0)),
            CellColorToken.purple: (Color(0xFF402C6B), Color(0xFFC3A6ED)),
            CellColorToken.red: (Color(0xFF632727), Color(0xFFF09288)),
          };

      for (final MapEntry<CellColorToken, (Color, Color)> entry
          in expected.entries) {
        final CellColor token = CellColor.token(entry.key);
        final (Color fill, Color ink) = entry.value;
        expect(
          tableCellFill(AppPalette.midnight, TableCellStyle(fill: token)),
          fill,
          reason: '${entry.key.name} 的深色底',
        );
        expect(
          tableCellInk(AppPalette.midnight, TableCellStyle(text: token)),
          ink,
          reason: '${entry.key.name} 的深色彩字',
        );
        expect(
          tableCellInk(AppPalette.midnight, TableCellStyle(fill: token)),
          isNull,
          reason: '令牌填充保留正文色，只有 fg 才换彩字',
        );
        expect(
          AppPalette.contrastRatio(ink, fill),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key.name} 的彩字在该填充上低于 AA',
        );
        expect(
          AppPalette.contrastRatio(AppPalette.midnight.textPrimary, fill),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key.name} 的正文在该填充上低于 AA',
        );
      }
    });

    test(
      'text tokens are full strength; unfilled cells keep the prose ink',
      () {
        expect(
          tableCellInk(AppPalette.midnight, redText),
          const Color(0xFFF09288),
          reason: '彩字取那一档在深底上够 AA 的提亮版，不是 palette.danger 本身',
        );
        expect(tableCellInk(AppPalette.midnight, amberFill), isNull);
        expect(tableCellInk(AppPalette.midnight, const TableCellStyle()), isNull);
      },
    );

    test('a literal fill picks readable text from its composited color', () {
      final Color over = Color.alphaBlend(
        const Color(0xFF111111),
        AppPalette.midnight.surface,
      );
      expect(
        tableCellInk(AppPalette.midnight, customFill),
        AppPalette.readableOn(over),
      );

      const TableCellStyle explicit = TableCellStyle(
        fill: CellColor.custom(0xFF111111),
        text: CellColor.token(CellColorToken.blue),
      );
      expect(
        tableCellInk(AppPalette.midnight, explicit),
        isNot(AppPalette.readableOn(over)),
        reason: '显式文字色优先于自动对比色',
      );
    });
  });

  group('renderer', () {
    const AppPalette palette = AppPalette.midnight;
    const TextStyle base = TextStyle(fontSize: 15.5, height: 1.78);
    const LineBlockContext context = LineBlockContext(
      contentWidth: 680,
      textScaler: TextScaler.noScaling,
      textDirection: TextDirection.ltr,
    );

    late String text;
    late LiveTableBlocks blocks;

    setUp(() {
      text = '| <!--nrs fg=red-->x | y |\n| --- | --- |\n| a | b |';
      blocks = LiveTableBlocks(
        base: base,
        palette: palette,
        text: () => text,
        selection: () => const TextSelection.collapsed(offset: -1),
      );
    });

    tearDown(() => blocks.dispose());

    SourceLine headerLine() => scanSourceLines(
      text,
    ).firstWhere((SourceLine line) => line.kind == LineBlockKind.tableHeader);

    Color? inkOf(LineBlockView block, int cell) {
      final TextSpan span =
          (block as TableRowChrome).chromeCellSpans()[cell] as TextSpan;
      return span.style?.color;
    }

    Color? redInk() =>
        tableInkColor(palette, const CellColor.token(CellColorToken.red));
    Color? greenInk() =>
        tableInkColor(palette, const CellColor.token(CellColorToken.green));

    test('the directive ink is painted, and a new ink rebuilds that cell', () {
      final LineBlockView block = blocks.blockFor(headerLine(), context)!;
      expect(inkOf(block, 0), redInk());
      expect(inkOf(block, 1), isNot(redInk()));
      final int builds = blocks.debugCellSpanBuilds;

      text = text.replaceFirst('fg=red', 'fg=green');
      final LineBlockView recolored = blocks.blockFor(headerLine(), context)!;
      expect(inkOf(recolored, 0), greenInk());
      expect(
        blocks.debugCellSpanBuilds,
        builds + 1,
        reason: '只有换色的那一格重建 span 树',
      );
    });

    test('a custom fill without a text color gets readable ink', () {
      text = '| <!--nrs bg=#111111-->x | y |\n| --- | --- |\n| a | b |';
      final LineBlockView block = blocks.blockFor(headerLine(), context)!;

      expect(
        inkOf(block, 0),
        AppPalette.readableOn(
          Color.alphaBlend(const Color(0xFF111111), palette.surface),
        ),
      );
      expect(inkOf(block, 1), isNot(inkOf(block, 0)));
    });
  });
}
