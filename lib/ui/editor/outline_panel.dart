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
      decoration: BoxDecoration(
        // Same step as the sidebar: the editor is the only bright surface, and
        // both side columns read as chrome around it.
        color: p.sidebar,
        border: Border(left: BorderSide(color: p.outline)),
      ),
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
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                      color: p.textTertiary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${headings.length}',
                    style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
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
                        fontSize: 11.5,
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
                      final double indent =
                          (h.level - 1) * AppLayout.rowIndent;

                      return HoverBuilder(
                        cursor: SystemMouseCursors.click,
                        builder: (BuildContext context, bool hovered) => GestureDetector(
                          onTap: () => onSelect(h.line),
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: EdgeInsets.only(
                              left: AppSpace.md + indent,
                              right: AppSpace.sm,
                            ),
                            child: AnimatedContainer(
                              duration: AppMotion.fast,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpace.sm,
                                vertical: AppSpace.xs,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? p.accentSoft
                                    : (hovered ? p.surfaceRaised : Colors.transparent),
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
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  if (h.level > 1) ...<Widget>[
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4.5),
                                      child: Container(
                                        width: 4,
                                        height: 4,
                                        decoration: BoxDecoration(
                                          color: p.textTertiary.withValues(
                                            alpha: 0.6,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      h.plainText.isEmpty ? '(空标题)' : h.plainText,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: h.level == 1 ? 12.5 : 11.8,
                                        height: 1.45,
                                        fontWeight: h.level <= 2
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: selected
                                            ? p.textPrimary
                                            : (h.level <= 2
                                                  ? p.textSecondary
                                                  : p.textTertiary),
                                      ),
                                    ),
                                  ),
                                ],
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
