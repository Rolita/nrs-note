import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import 'template_dialog_frame.dart';

/// Asks for the title of the note a template is about to create.
///
/// An empty answer is allowed and means 「未命名」, exactly like the + button.
/// A cancel returns null, and no note is created at all.
Future<String?> showTemplateNewNoteDialog(
  BuildContext context, {
  required String templateTitle,
}) {
  final AppPalette p = context.palette;
  return showDialog<String>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) =>
        TemplateNewNoteDialog(templateTitle: templateTitle),
  );
}

class TemplateNewNoteDialog extends StatefulWidget {
  const TemplateNewNoteDialog({super.key, required this.templateTitle});

  final String templateTitle;

  @override
  State<TemplateNewNoteDialog> createState() => _TemplateNewNoteDialogState();
}

class _TemplateNewNoteDialogState extends State<TemplateNewNoteDialog> {
  final TextEditingController _title = TextEditingController();
  bool _done = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(_title.text.trim());
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: TemplateDialogFrame(
        icon: LucideIcons.filePlus2,
        title: '用模板新建笔记',
        subtitle: '模板：${widget.templateTitle}',
        width: 400,
        onClose: _cancel,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '标题也是文件名。留空会得到「未命名」，之后仍可重命名。',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.6,
                  color: p.textTertiary,
                  fontFamily: AppFonts.ui,
                  fontFamilyFallback: AppFonts.uiFallback,
                ),
              ),
              const SizedBox(height: 9),
              Container(
                decoration: BoxDecoration(
                  color: p.surfaceSunken,
                  borderRadius: AppRadius.mdAll,
                  border: Border.all(color: p.accent),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.18),
                      spreadRadius: 2,
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: TextField(
                  controller: _title,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
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
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    hintText: '未命名',
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: p.textTertiary,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        footer: Row(
          children: <Widget>[
            const TemplateEscHint(text: '取消'),
            const Spacer(),
            TemplateDialogButton(label: '取消', onPressed: _cancel),
            const SizedBox(width: AppSpace.sm),
            TemplateDialogButton(
              label: '新建',
              icon: LucideIcons.cornerDownLeft,
              primary: true,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
