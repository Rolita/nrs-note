import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../templates/template_error.dart';
import '../../templates/template_service.dart';
import 'template_prompt_dialog.dart';
import 'template_suggester_dialog.dart';

/// Supplies the real dialogs and clipboard to `tp.system.*`.
///
/// The shell owns this for the duration of one render; the dialogs are modal,
/// so a prompt cannot race the editor behind it.
class TemplateDialogInteraction implements TemplateInteraction {
  TemplateDialogInteraction(this.context);

  final BuildContext context;

  @override
  Future<String?> prompt({
    required String text,
    required String defaultValue,
    required bool multiline,
  }) {
    if (!context.mounted) throw const TemplateCancelled();
    return showTemplatePromptDialog(
      context,
      text: text,
      defaultValue: defaultValue,
      multiline: multiline,
    );
  }

  @override
  Future<int?> suggester({
    required List<String> options,
    required String placeholder,
  }) {
    if (!context.mounted) throw const TemplateCancelled();
    return showTemplateSuggesterDialog(
      context,
      options: options,
      placeholder: placeholder,
    );
  }

  @override
  Future<String> clipboard() async {
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text ?? '';
    } on PlatformException {
      return '';
    }
  }
}
