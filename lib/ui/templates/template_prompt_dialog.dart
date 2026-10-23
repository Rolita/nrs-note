import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'template_dialog_frame.dart';

/// `tp.system.prompt`: one question, answered or cancelled as a whole.
///
/// A cancel returns null — the caller turns that into [TemplateCancelled], so
/// the render stops before anything is written. An empty answer is a real
/// answer and comes back as `''`.
Future<String?> showTemplatePromptDialog(
  BuildContext context, {
  required String text,
  required String defaultValue,
  required bool multiline,
}) {
  final AppPalette p = context.palette;
  return showDialog<String>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) => TemplatePromptDialog(
      text: text,
      defaultValue: defaultValue,
      multiline: multiline,
    ),
  );
}

class TemplatePromptDialog extends StatefulWidget {
  const TemplatePromptDialog({
    super.key,
    required this.text,
    required this.defaultValue,
    required this.multiline,
  });

  final String text;
  final String defaultValue;
  final bool multiline;

  @override
  State<TemplatePromptDialog> createState() => _TemplatePromptDialogState();
}

class _TemplatePromptDialogState extends State<TemplatePromptDialog> {
  late final TextEditingController _value = TextEditingController(
    text: widget.defaultValue,
  )..selection = TextSelection.collapsed(offset: widget.defaultValue.length);
  final FocusNode _focus = FocusNode(debugLabel: 'template-prompt');
  bool _done = false;

  @override
  void dispose() {
    _value.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(_value.text);
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String title = widget.text.trim().isEmpty
        ? '模板需要输入'
        : widget.text.trim();

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (!widget.multiline)
          const SingleActivator(LogicalKeyboardKey.enter): _submit,
        if (widget.multiline)
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              _submit,
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: TemplateDialogFrame(
        icon: LucideIcons.messageSquareText,
        title: title,
        subtitle: '模板 · tp.system.prompt',
        width: 400,
        onClose: _cancel,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '模板需要这个信息才能生成正文。取消会放弃整次渲染，不会写入任何内容。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: p.textTertiary,
                  fontFamily: AppFonts.ui,
                  fontFamilyFallback: AppFonts.uiFallback,
                ),
              ),
              const SizedBox(height: 9),
              _field(p),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Icon(LucideIcons.info, size: 12, color: p.textTertiary),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      widget.multiline
                          ? 'Ctrl+Enter 确定 · Esc 取消整个模板'
                          : 'Esc 取消整个模板',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: p.textTertiary,
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        footer: Row(
          children: <Widget>[
            const Spacer(),
            TemplateDialogButton(label: '取消', onPressed: _cancel),
            const SizedBox(width: AppSpace.sm),
            TemplateDialogButton(
              label: '确定',
              primary: true,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(AppPalette p) {
    return AnimatedContainer(
      duration: AppMotion.fast,
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: p.accent),
        boxShadow: <BoxShadow>[
          BoxShadow(color: p.accent.withValues(alpha: 0.18), spreadRadius: 2),
        ],
      ),
      padding: EdgeInsets.symmetric(
        horizontal: 10,
        vertical: widget.multiline ? 7 : 0,
      ),
      child: TextField(
        controller: _value,
        focusNode: _focus,
        autofocus: true,
        minLines: widget.multiline ? 3 : 1,
        maxLines: widget.multiline ? 6 : 1,
        keyboardType: widget.multiline
            ? TextInputType.multiline
            : TextInputType.text,
        textInputAction: widget.multiline
            ? TextInputAction.newline
            : TextInputAction.done,
        onSubmitted: widget.multiline ? null : (_) => _submit(),
        cursorColor: p.accent,
        cursorWidth: 1.3,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: p.textPrimary,
          fontFamily: AppFonts.ui,
          fontFamilyFallback: AppFonts.uiFallback,
        ),
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(
            vertical: widget.multiline ? 2 : 9,
          ),
          hintText: '在这里输入…',
          hintStyle: TextStyle(
            fontSize: 13,
            color: p.textTertiary,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
          ),
        ),
      ),
    );
  }
}
