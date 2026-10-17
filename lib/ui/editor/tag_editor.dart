import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../common/app_widgets.dart';

/// Inline editor for a note's tags — add by typing, remove with the pill's ×.
class TagEditor extends StatefulWidget {
  const TagEditor({
    super.key,
    required this.tags,
    required this.onChanged,
    this.suggestions = const <String>[],
  });

  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final List<String> suggestions;

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  bool _editing = false;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing && _input.text.trim().isEmpty) {
        setState(() => _editing = false);
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final String raw = _input.text.trim().replaceAll('#', '');
    if (raw.isEmpty) {
      setState(() => _editing = false);
      return;
    }
    final List<String> parts = raw
        .split(RegExp(r'[,，\s]+'))
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
    final List<String> next = List<String>.of(widget.tags);
    for (final String tag in parts) {
      if (!next.contains(tag)) next.add(tag);
    }
    _input.clear();
    widget.onChanged(next);
    setState(() => _editing = false);
  }

  List<String> get _unusedSuggestions => widget.suggestions
      .where((String s) => !widget.tags.contains(s))
      .take(6)
      .toList();

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final List<String> suggestions = _unusedSuggestions;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (final String tag in widget.tags)
          TagPill(
            label: tag,
            onRemove: () => widget.onChanged(
              widget.tags.where((String t) => t != tag).toList(),
            ),
          ),
        if (_editing)
          Container(
            width: 132,
            height: 24,
            decoration: BoxDecoration(
              color: p.surfaceRaised,
              borderRadius: AppRadius.pillAll,
              border: Border.all(color: p.accent.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: <Widget>[
                const SizedBox(width: 9),
                Text(
                  '#',
                  style: TextStyle(fontSize: 11.5, color: p.accent),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    autofocus: true,
                    style: TextStyle(fontSize: 11.5, color: p.textPrimary),
                    cursorColor: p.accent,
                    cursorWidth: 1.3,
                    cursorHeight: 13,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _commit(),
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.deny(RegExp(r'[\n\r]')),
                    ],
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      hintText: '标签名',
                      hintStyle: TextStyle(
                        fontSize: 11.5,
                        color: p.textTertiary,
                      ),
                    ),
                  ),
                ),
                AppIconButton(
                  icon: Icons.check_rounded,
                  tooltip: '添加',
                  size: 22,
                  iconSize: 12,
                  active: true,
                  onPressed: _commit,
                ),
              ],
            ),
          )
        else
          TagPill(
            label: widget.tags.isEmpty ? '＋ 添加标签' : '＋',
            onTap: () => setState(() => _editing = true),
          ),
        if (_editing && suggestions.isNotEmpty)
          ...suggestions.take(3).map(
            (String s) => TagPill(
              label: s,
              compact: true,
              onTap: () {
                widget.onChanged(<String>[...widget.tags, s]);
                setState(() => _editing = false);
              },
            ),
          ),
      ],
    );
  }
}
