import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';

/// One entry in the command palette.
class PaletteAction {
  const PaletteAction({
    required this.label,
    required this.icon,
    required this.run,
    this.hint,
  });

  final String label;
  final IconData icon;
  final VoidCallback run;
  final String? hint;
}

/// Quick-open / command palette (Ctrl+P).
///
/// Two things in one surface: jump to a note, or run a command. Ranking is a
/// simple prefix-then-substring score, which is plenty for a personal vault and
/// has the virtue of being instantly predictable.
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.notes,
    required this.actions,
    required this.onSelectNote,
  });

  final List<Note> notes;
  final List<PaletteAction> actions;
  final ValueChanged<Note> onSelectNote;

  static Future<void> show(
    BuildContext context, {
    required List<Note> notes,
    required List<PaletteAction> actions,
    required ValueChanged<Note> onSelectNote,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: const Color(0x38000000),
      barrierDismissible: true,
      builder: (BuildContext context) => CommandPalette(
        notes: notes,
        actions: actions,
        onSelectNote: onSelectNote,
      ),
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  int _index = 0;
  List<_Row> _rows = <_Row>[];

  @override
  void initState() {
    super.initState();
    _recompute('');
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _recompute(String query) {
    final String q = query.trim().toLowerCase();
    final List<_Row> rows = <_Row>[];

    final List<Note> matched = q.isEmpty
        ? widget.notes.take(7).toList()
        : (widget.notes.where((Note n) {
            return n.title.toLowerCase().contains(q) ||
                n.body.toLowerCase().contains(q) ||
                n.tags.any((String t) => t.toLowerCase().contains(q));
          }).toList()
          ..sort((Note a, Note b) {
            final int at = a.title.toLowerCase().indexOf(q);
            final int bt = b.title.toLowerCase().indexOf(q);
            final int ar = at < 0 ? 1 : 0;
            final int br = bt < 0 ? 1 : 0;
            if (ar != br) return ar - br;
            if (at != bt) return at - bt;
            return b.updatedAt.compareTo(a.updatedAt);
          }))
        .take(40)
        .toList();

    for (final Note n in matched) {
      rows.add(_Row.note(n));
    }

    final List<PaletteAction> actions = q.isEmpty
        ? widget.actions
        : widget.actions
              .where(
                (PaletteAction a) =>
                    a.label.toLowerCase().contains(q) ||
                    (a.hint ?? '').toLowerCase().contains(q),
              )
              .toList();
    for (final PaletteAction a in actions) {
      rows.add(_Row.action(a));
    }

    setState(() {
      _rows = rows;
      _index = 0;
    });
  }

  void _move(int delta) {
    if (_rows.isEmpty) return;
    setState(() {
      _index = (_index + delta).clamp(0, _rows.length - 1);
    });
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    // Approximate: a row plus its share of the section header above it. Only
    // ever used to keep the keyboard cursor on screen, so it does not have to
    // be exact — it has to be *close*, or the list jumps a row too far.
    const double rowHeight = 38;
    final double target = _index * rowHeight;
    final double viewStart = _scroll.offset;
    final double viewEnd = viewStart + _scroll.position.viewportDimension;
    if (target < viewStart) {
      _scroll.jumpTo(target);
    } else if (target + rowHeight > viewEnd) {
      _scroll.jumpTo(target + rowHeight - _scroll.position.viewportDimension);
    }
  }

  void _activate() {
    if (_rows.isEmpty) return;
    final _Row row = _rows[_index];
    Navigator.of(context).pop();
    if (row.note != null) {
      widget.onSelectNote(row.note!);
    } else {
      row.action!.run();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 60, left: 24, right: 24, bottom: 24),
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Container(
              decoration: BoxDecoration(
                color: p.surfaceRaised,
                borderRadius: AppRadius.xlAll,
                border: Border.all(color: p.outline),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: p.shadow,
                    blurRadius: 32,
                    spreadRadius: -8,
                    offset: const Offset(0, 16),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    height: 46,
                    child: Row(
                      children: <Widget>[
                        const SizedBox(width: AppSpace.lg),
                        Icon(
                          Icons.search_rounded,
                          size: 16,
                          color: p.textTertiary,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: <ShortcutActivator, VoidCallback>{
                              const SingleActivator(
                                LogicalKeyboardKey.arrowDown,
                              ): () => _move(1),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowUp,
                              ): () => _move(-1),
                              const SingleActivator(LogicalKeyboardKey.escape):
                                  () => Navigator.of(context).pop(),
                            },
                            child: TextField(
                              controller: _input,
                              autofocus: true,
                              onChanged: _recompute,
                              onSubmitted: (_) => _activate(),
                              cursorColor: p.accent,
                              cursorWidth: 1.6,
                              style: TextStyle(
                                fontSize: AppText.title,
                                color: p.textPrimary,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                                hintText: '搜索笔记或输入命令…',
                                hintStyle: TextStyle(
                                  fontSize: AppText.title,
                                  color: p.textTertiary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpace.lg),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: p.surfaceSunken,
                            borderRadius: BorderRadius.circular(AppRadius.xs),
                            border: Border.all(color: p.outlineSoft),
                          ),
                          child: Text(
                            'ESC',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                              color: p.textTertiary,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpace.lg),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: p.outlineSoft),
                  if (_rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpace.xxl,
                      ),
                      child: Text(
                        '没有找到匹配的内容',
                        style: TextStyle(
                          fontSize: AppText.ui,
                          color: p.textTertiary,
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 396),
                      child: ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpace.xs,
                        ),
                        itemCount: _rows.length,
                        itemBuilder: (BuildContext context, int i) {
                          final _Row row = _rows[i];
                          final bool selected = i == _index;
                          return _buildRow(p, row, selected, i);
                        },
                      ),
                    ),
                  Divider(height: 1, color: p.outlineSoft),
                  Container(
                    height: AppLayout.footerHeight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md,
                    ),
                    child: Row(
                      children: <Widget>[
                        _Hint(p: p, keys: '↑ ↓', label: '选择'),
                        const SizedBox(width: AppSpace.md),
                        _Hint(p: p, keys: 'Enter', label: '打开'),
                        const Spacer(),
                        Text(
                          '${widget.notes.length} 篇笔记',
                          style: TextStyle(
                            fontSize: AppText.caption,
                            color: p.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(AppPalette p, _Row row, bool selected, int index) {
    final bool isFirstAction =
        row.action != null && (index == 0 || _rows[index - 1].action == null);
    final bool isFirstNote =
        row.note != null && (index == 0 || _rows[index - 1].note == null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (isFirstAction && row.action != null && index != 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              AppSpace.sm,
              AppSpace.md,
              AppSpace.xxs,
            ),
            child: Text(
              '操作',
              style: TextStyle(
                fontSize: AppText.label,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: p.textTertiary,
              ),
            ),
          ),
        if (isFirstNote && index == 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              AppSpace.xs,
              AppSpace.md,
              AppSpace.xxs,
            ),
            child: Text(
              '笔记',
              style: TextStyle(
                fontSize: AppText.label,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: p.textTertiary,
              ),
            ),
          ),
        Container(
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
          decoration: BoxDecoration(
            color: selected ? p.accentSoft : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: Row(
            children: <Widget>[
              Icon(
                row.note != null
                    ? Icons.description_outlined
                    : row.action!.icon,
                size: 14.5,
                color: selected ? p.accent : p.textTertiary,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  row.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.ui,
                    fontWeight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                ),
              ),
              if (row.subtitle != null)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 200),
                  child: Text(
                    row.subtitle!,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Row {
  _Row.note(Note this.note)
    : action = null,
      title = note.title.trim().isEmpty ? '未命名笔记' : note.title.trim(),
      subtitle = note.snippet;

  _Row.action(PaletteAction this.action)
    : note = null,
      title = action.label,
      subtitle = action.hint;

  final Note? note;
  final PaletteAction? action;
  final String title;
  final String? subtitle;
}

class _Hint extends StatelessWidget {
  const _Hint({required this.p, required this.keys, required this.label});

  final AppPalette p;
  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
          decoration: BoxDecoration(
            color: p.surfaceSunken,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            border: Border.all(color: p.outlineSoft),
          ),
          child: Text(
            keys,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: p.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: AppSpace.xs + 2),
        Text(
          label,
          style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
        ),
      ],
    );
  }
}
