import 'package:flutter/material.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/debouncer.dart';
import '../../data/models/note.dart';
import '../common/app_widgets.dart';

/// One row in the note list.
class NoteListTile extends StatelessWidget {
  const NoteListTile({
    super.key,
    required this.note,
    required this.selected,
    required this.onTap,
    required this.onTogglePin,
    required this.onToggleFavorite,
    required this.onDelete,
    this.query = '',
  });

  final Note note;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDelete;
  final String query;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String title = note.title.trim().isEmpty
        ? (note.derivedTitle.isEmpty ? '未命名笔记' : note.derivedTitle)
        : note.title.trim();
    final String snippet = note.snippet;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm + 2, vertical: 2),
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) {
          final Color bg = selected
              ? p.accent.withValues(alpha: p.isDark ? 0.18 : 0.10)
              : (hovered ? p.surfaceRaised : Colors.transparent);

          return GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: AppRadius.mdAll,
                border: Border.all(
                  color: selected
                      ? p.accent.withValues(alpha: 0.22)
                      : Colors.transparent,
                ),
              ),
              child: Stack(
                children: <Widget>[
                  if (selected)
                    Positioned(
                      left: 0,
                      top: 11,
                      bottom: 11,
                      child: Container(
                        width: 2.5,
                        decoration: BoxDecoration(
                          color: p.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(13, 10, 10, 11),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            if (note.pinned) ...<Widget>[
                              Padding(
                                padding: const EdgeInsets.only(top: 1.5, right: 5),
                                child: Icon(
                                  Icons.push_pin_rounded,
                                  size: 11.5,
                                  color: p.accent,
                                ),
                              ),
                            ],
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: _highlight(
                                    title,
                                    query,
                                    TextStyle(
                                      fontSize: 13.5,
                                      height: 1.35,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      letterSpacing: -0.1,
                                      color: p.textPrimary,
                                    ),
                                    p.accent,
                                    p.isDark
                                        ? const Color(0x33FFFFFF)
                                        : const Color(0x22FFD54F),
                                  ),
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                formatRelativeTime(note.updatedAt),
                                style: TextStyle(
                                  fontSize: 10.5,
                                  height: 1.35,
                                  color: p.textTertiary,
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (snippet.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            snippet,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: p.textTertiary,
                            ),
                          ),
                        ],
                        const SizedBox(height: 7),
                        Row(
                          children: <Widget>[
                            ...note.tags.take(3).map(
                              (String t) => Padding(
                                padding: const EdgeInsets.only(right: 5),
                                child: TagPill(label: t, compact: true),
                              ),
                            ),
                            if (note.taskTotal > 0) ...<Widget>[
                              _Meta(
                                icon: note.taskDone == note.taskTotal
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                text: '${note.taskDone}/${note.taskTotal}',
                                color: note.taskDone == note.taskTotal
                                    ? p.success
                                    : p.textTertiary,
                              ),
                              const SizedBox(width: 8),
                            ],
                            _Meta(
                              text: '${note.wordCount} 字',
                              color: p.textTertiary,
                            ),
                            const Spacer(),
                            AnimatedOpacity(
                              duration: AppMotion.fast,
                              opacity: hovered || selected ? 1 : 0,
                              child: Row(
                                children: <Widget>[
                                  AppIconButton(
                                    icon: note.favorite
                                        ? Icons.star_rounded
                                        : Icons.star_outline_rounded,
                                    tooltip: note.favorite ? '取消收藏' : '收藏',
                                    size: 22,
                                    iconSize: 13,
                                    active: note.favorite,
                                    activeColor: p.warning,
                                    onPressed: onToggleFavorite,
                                  ),
                                  AppIconButton(
                                    icon: note.pinned
                                        ? Icons.push_pin_rounded
                                        : Icons.push_pin_outlined,
                                    tooltip: note.pinned ? '取消置顶' : '置顶',
                                    size: 22,
                                    iconSize: 13,
                                    active: note.pinned,
                                    onPressed: onTogglePin,
                                  ),
                                  AppIconButton(
                                    icon: Icons.delete_outline_rounded,
                                    tooltip: '删除',
                                    size: 22,
                                    iconSize: 13,
                                    tone: p.danger,
                                    onPressed: onDelete,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.text, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
        ],
        Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }
}

/// Bolds every occurrence of [query] inside [text].
List<InlineSpan> _highlight(
  String text,
  String query,
  TextStyle style,
  Color accent,
  Color markBackground,
) {
  final String needle = query.trim();
  if (needle.isEmpty) return <InlineSpan>[TextSpan(text: text, style: style)];

  final String haystack = text.toLowerCase();
  final String lower = needle.toLowerCase();
  final List<InlineSpan> spans = <InlineSpan>[];
  int index = 0;
  while (true) {
    final int hit = haystack.indexOf(lower, index);
    if (hit < 0) {
      spans.add(TextSpan(text: text.substring(index), style: style));
      break;
    }
    if (hit > index) {
      spans.add(TextSpan(text: text.substring(index, hit), style: style));
    }
    spans.add(
      TextSpan(
        text: text.substring(hit, hit + needle.length),
        style: style.copyWith(
          backgroundColor: markBackground,
          color: accent,
        ),
      ),
    );
    index = hit + needle.length;
  }
  return spans;
}
