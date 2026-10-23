import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../common/app_widgets.dart';
import 'template_dialog_frame.dart';

/// `tp.system.suggester`: pick one option, or cancel the whole render.
///
/// Returns the option's index in the original [options] list, even while the
/// search field is filtering the visible rows.
Future<int?> showTemplateSuggesterDialog(
  BuildContext context, {
  required List<String> options,
  required String placeholder,
}) {
  final AppPalette p = context.palette;
  return showDialog<int>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) =>
        TemplateSuggesterDialog(options: options, placeholder: placeholder),
  );
}

class TemplateSuggesterDialog extends StatefulWidget {
  const TemplateSuggesterDialog({
    super.key,
    required this.options,
    required this.placeholder,
  });

  final List<String> options;
  final String placeholder;

  @override
  State<TemplateSuggesterDialog> createState() =>
      _TemplateSuggesterDialogState();
}

class _TemplateSuggesterDialogState extends State<TemplateSuggesterDialog> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'template-suggester');
  bool _done = false;
  int _selected = 0;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Index and label of every option the query still matches.
  List<({int index, String label})> get _matches {
    final String q = _search.text.trim().toLowerCase();
    return <({int index, String label})>[
      for (int i = 0; i < widget.options.length; i++)
        if (q.isEmpty || widget.options[i].toLowerCase().contains(q))
          (index: i, label: widget.options[i]),
    ];
  }

  int get _selectedIndex {
    final int count = _matches.length;
    if (count == 0) return -1;
    return _selected.clamp(0, count - 1);
  }

  void _submit() {
    final int at = _selectedIndex;
    if (at < 0) return;
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(_matches[at].index);
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop();
  }

  void _move(int delta) {
    final int count = _matches.length;
    if (count == 0) return;
    final int next = (_selectedIndex + delta).clamp(0, count - 1);
    if (next == _selectedIndex) return;
    setState(() => _selected = next);
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final List<({int index, String label})> matches = _matches;
    final int selected = _selectedIndex;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: TemplateDialogFrame(
        icon: LucideIcons.listChecks,
        title: widget.placeholder.trim().isEmpty
            ? '选择一个选项'
            : widget.placeholder.trim(),
        subtitle: '模板 · tp.system.suggester',
        width: 400,
        maxHeight: 460,
        onClose: _cancel,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
              child: TemplateSearchField(
                controller: _search,
                focusNode: _searchFocus,
                autofocus: true,
                hint: '搜索选项…',
                onChanged: (_) => setState(() => _selected = 0),
                onSubmitted: (_) => _submit(),
              ),
            ),
            Flexible(
              child: matches.isEmpty
                  ? _noMatches(p)
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          for (int i = 0; i < matches.length; i++)
                            _option(p, matches[i], i, i == selected),
                        ],
                      ),
                    ),
            ),
          ],
        ),
        footer: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '↑↓ 选择 · Enter 确定',
                style: TextStyle(
                  fontSize: 10.5,
                  color: p.textTertiary,
                  fontFamily: AppFonts.ui,
                  fontFamilyFallback: AppFonts.uiFallback,
                ),
              ),
            ),
            TemplateDialogButton(label: '取消', onPressed: _cancel),
            const SizedBox(width: AppSpace.sm),
            TemplateDialogButton(
              label: '确定',
              primary: true,
              onPressed: matches.isEmpty ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _option(
    AppPalette p,
    ({int index, String label}) match,
    int position,
    bool selected,
  ) {
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _selected = position);
            _searchFocus.requestFocus();
          },
          onDoubleTap: () {
            setState(() => _selected = position);
            _submit();
          },
          child: AnimatedContainer(
            duration: AppMotion.fast,
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected
                  ? p.accentSoft
                  : (hovered ? p.surfaceSunken : Colors.transparent),
              borderRadius: AppRadius.mdAll,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    match.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: selected ? p.textPrimary : p.textSecondary,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                    ),
                  ),
                ),
                if (selected) ...<Widget>[
                  const SizedBox(width: AppSpace.sm),
                  Icon(LucideIcons.check, size: 13, color: p.accent),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _noMatches(AppPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(LucideIcons.searchX, size: 18, color: p.textTertiary),
          const SizedBox(height: 8),
          Text(
            '没有匹配的选项',
            style: TextStyle(
              fontSize: 12,
              color: p.textSecondary,
              fontFamily: AppFonts.ui,
              fontFamilyFallback: AppFonts.uiFallback,
            ),
          ),
        ],
      ),
    );
  }
}
