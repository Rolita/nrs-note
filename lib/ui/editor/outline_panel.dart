import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_outline.dart';
import '../common/app_widgets.dart';

/// Document outline. Doubles as a progress indicator: the heading you are
/// currently writing under stays highlighted.
class OutlinePanel extends StatelessWidget {
  const OutlinePanel({
    super.key,
    required this.headings,
    required this.currentLine,
    required this.onSelect,
    this.width = 210,
  });

  final List<Heading> headings;
  final int currentLine;
  final ValueChanged<int> onSelect;
  final double width;

  int get _activeIndex {
    int active = -1;
    for (int i = 0; i < headings.length; i++) {
      if (headings[i].line <= currentLine) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final int active = _activeIndex;

    return Container(
      width: width,
      // Same step as the sidebar: the editor is the only bright surface, and
      // both side columns read as chrome around it.
      //
      // No left border here: the resize handle to its left already draws the
      // hairline, on this exact pixel. Both drawn at the same time added up to
      // two lines 3px apart — invisible while they were the faint `outlineSoft`
      // step, a doubled edge the moment the palette stepped them up to
      // `outline`.
      color: p.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: AppLayout.panelHeaderHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.sm, 0),
              child: Row(
                children: <Widget>[
                  Text(
                    '大纲',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: p.textTertiary,
                    ),
                  ),
                  const SizedBox(width: AppSpace.xs + 2),
                  Text(
                    '${headings.length}',
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: headings.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                    child: Text(
                      '用 # 写下标题,\n大纲会出现在这里。',
                      style: TextStyle(
                        fontSize: AppText.caption,
                        height: 1.6,
                        color: p.textTertiary,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: AppSpace.xl),
                    itemCount: headings.length,
                    itemBuilder: (BuildContext context, int i) {
                      final Heading h = headings[i];
                      final bool selected = i == active;
                      final double indent = (h.level - 1) * AppLayout.rowIndent;

                      // Level is carried by weight and colour, not by a bullet:
                      // at 28px a row can hold one signal, and indentation plus
                      // a lighter step already say "this is a sub-heading".
                      final double size = switch (h.level) {
                        1 => AppText.ui,
                        2 => 12.5,
                        _ => AppText.label,
                      };
                      final FontWeight weight = h.level == 1
                          ? FontWeight.w600
                          : FontWeight.w500;
                      final Color tone = selected
                          ? p.textPrimary
                          : (h.level <= 2 ? p.textSecondary : p.textTertiary);

                      return HoverBuilder(
                        cursor: SystemMouseCursors.click,
                        builder: (BuildContext context, bool hovered) =>
                            GestureDetector(
                              onTap: () => onSelect(h.line),
                              behavior: HitTestBehavior.opaque,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  left: AppSpace.sm + indent,
                                  right: AppSpace.xs,
                                ),
                                child: AnimatedContainer(
                                  duration: AppMotion.fast,
                                  height: AppLayout.rowHeight,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpace.sm,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? p.accentSoft
                                        : (hovered
                                              ? p.surfaceRaised
                                              : Colors.transparent),
                                    borderRadius: AppRadius.smAll,
                                    border: selected
                                        ? Border(
                                            left: BorderSide(
                                              color: p.accent,
                                              width: 2,
                                            ),
                                          )
                                        : null,
                                  ),
                                  child: Text(
                                    h.plainText.isEmpty ? '(空标题)' : h.plainText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: size,
                                      height: 1.4,
                                      fontWeight: weight,
                                      color: selected ? p.accent : tone,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
