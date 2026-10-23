import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../../state/template_settings.dart';
import '../../templates/template_chords.dart';
import '../../templates/template_service.dart';
import '../common/app_widgets.dart';
import 'template_dialog_frame.dart';

/// Binds one shortcut per template.
///
/// A chord is written as soon as it is recorded — there is no Save button to
/// forget. A chord that is already taken (by the app or another template) is
/// refused on the spot, so the settings never hold a binding that cannot fire.
Future<void> showTemplateHotkeysDialog(BuildContext context) {
  final AppPalette p = context.palette;
  return showDialog<void>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) => const TemplateHotkeysDialog(),
  );
}

class TemplateHotkeysDialog extends StatefulWidget {
  const TemplateHotkeysDialog({super.key});

  @override
  State<TemplateHotkeysDialog> createState() => _TemplateHotkeysDialogState();
}

class _TemplateHotkeysDialogState extends State<TemplateHotkeysDialog> {
  final FocusNode _keys = FocusNode(debugLabel: 'template-hotkeys');
  final TemplateService _templates = const TemplateService();
  String? _recordingId;
  String? _problem;

  static final Set<LogicalKeyboardKey> _modifiers = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
  };

  @override
  void dispose() {
    _keys.dispose();
    super.dispose();
  }

  void _record(String templateId) {
    setState(() {
      _recordingId = templateId;
      _problem = null;
    });
    _keys.requestFocus();
  }

  void _stopRecording() {
    if (_recordingId == null) return;
    setState(() => _recordingId = null);
  }

  void _save(Map<String, TemplateHotkey> next) {
    context.read<SettingsController>().templateHotkeys = next;
  }

  void _clear(String templateId) {
    final Map<String, TemplateHotkey> next = Map<String, TemplateHotkey>.of(
      context.read<SettingsController>().templateHotkeys,
    )..remove(templateId);
    _save(next);
    setState(() {
      _recordingId = null;
      _problem = null;
    });
  }

  void _clearStale(Set<String> stale) {
    final Map<String, TemplateHotkey> next = Map<String, TemplateHotkey>.of(
      context.read<SettingsController>().templateHotkeys,
    )..removeWhere((String id, TemplateHotkey _) => stale.contains(id));
    _save(next);
    setState(() => _problem = null);
  }

  void _changeAction(String templateId, TemplateAction action) {
    final Map<String, TemplateHotkey> current = context
        .read<SettingsController>()
        .templateHotkeys;
    final TemplateHotkey? binding = current[templateId];
    if (binding == null || binding.action == action) return;
    _save(<String, TemplateHotkey>{
      ...current,
      templateId: TemplateHotkey(
        templateId: templateId,
        keyId: binding.keyId,
        action: action,
        control: binding.control,
        alt: binding.alt,
        shift: binding.shift,
      ),
    });
    if (_recordingId == templateId) _stopRecording();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final String? templateId = _recordingId;
    if (templateId == null) return KeyEventResult.ignored;
    if (event is KeyUpEvent || event is KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _stopRecording();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      _clear(templateId);
      return KeyEventResult.handled;
    }
    if (_modifiers.contains(key)) return KeyEventResult.handled;

    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed) {
      setState(() => _problem = '暂不支持 Win 键组合，请改用 Ctrl、Alt 或 Shift。');
      return KeyEventResult.handled;
    }

    final TemplateHotkey candidate = TemplateHotkey(
      templateId: templateId,
      keyId: key.keyId,
      action: _actionOf(templateId),
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
    if (!candidate.hasModifier) {
      setState(() => _problem = '快捷键至少要带 Ctrl、Alt 或 Shift 中的一个，否则会抢走普通输入。');
      return KeyEventResult.handled;
    }

    final String? reserved = reservedChordConflict(candidate);
    if (reserved != null) {
      setState(() => _problem = '${chordLabel(candidate)} 已经被「$reserved」使用，未注册。');
      return KeyEventResult.handled;
    }

    final Map<String, TemplateHotkey> current = context
        .read<SettingsController>()
        .templateHotkeys;
    final String? other = templateHotkeyConflict(current, candidate);
    if (other != null) {
      final String title = _titleOf(other);
      setState(() => _problem = '${chordLabel(candidate)} 已被模板「$title」使用，未注册。');
      return KeyEventResult.handled;
    }

    _save(<String, TemplateHotkey>{...current, templateId: candidate});
    setState(() {
      _recordingId = null;
      _problem = null;
    });
    return KeyEventResult.handled;
  }

  TemplateAction _actionOf(String templateId) =>
      context.read<SettingsController>().templateHotkeys[templateId]?.action ??
      TemplateAction.insert;

  String _titleOf(String templateId) {
    for (final Note note in context.read<NotesController>().allNotes) {
      if (note.id == templateId) {
        return note.title.trim().isEmpty ? '未命名' : note.title;
      }
    }
    return '已删除的模板';
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final SettingsController settings = context.watch<SettingsController>();
    final NotesController notes = context.watch<NotesController>();
    final List<Note> templates = _templates.discoverTemplates(
      notes.allNotes,
      settings.templatesFolder,
    );
    final Map<String, TemplateHotkey> bindings = settings.templateHotkeys;
    final Set<String> templateIds = <String>{
      for (final Note note in templates) note.id,
    };
    final Set<String> stale = <String>{
      for (final String id in bindings.keys)
        if (!templateIds.contains(id)) id,
    };
    final int bound = bindings.length - stale.length;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: TemplateDialogFrame(
          icon: LucideIcons.keyboard,
          title: '模板快捷键',
          subtitle: '点击按键框，然后直接按下组合键 · 需要至少一个修饰键',
          width: 620,
          maxHeight: 620,
          onClose: () => Navigator.of(context).pop(),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_problem != null) _problemBanner(p),
              Flexible(
                child: templates.isEmpty
                    ? _empty(p, settings.templatesFolder)
                    : _list(p, templates, bindings),
              ),
              if (stale.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 10, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${stale.length} 个快捷键指向已删除的模板',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: p.textTertiary,
                            fontFamily: AppFonts.ui,
                            fontFamilyFallback: AppFonts.uiFallback,
                          ),
                        ),
                      ),
                      AppTextButton(
                        label: '清除',
                        onPressed: () => _clearStale(stale),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          footer: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  templates.isEmpty
                      ? '没有模板可绑定'
                      : '${templates.length} 个模板 · $bound 个已绑定',
                  style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                ),
              ),
              const TemplateEscHint(text: '关闭'),
              const SizedBox(width: AppSpace.sm),
              TemplateDialogButton(
                label: '完成',
                primary: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _problemBanner(AppPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: p.dangerSoft,
          borderRadius: AppRadius.smAll,
          border: Border.all(color: p.danger.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: <Widget>[
            Icon(LucideIcons.triangleAlert, size: 13, color: p.danger),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                _problem!,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: p.danger,
                  fontFamily: AppFonts.ui,
                  fontFamilyFallback: AppFonts.uiFallback,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(
    AppPalette p,
    List<Note> templates,
    Map<String, TemplateHotkey> bindings,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < templates.length; i++) ...<Widget>[
            if (i > 0) Divider(height: 1, color: p.outlineSoft),
            _row(p, templates[i], bindings[templates[i].id]),
          ],
        ],
      ),
    );
  }

  Widget _row(AppPalette p, Note template, TemplateHotkey? binding) {
    final bool recording = _recordingId == template.id;
    final String title = template.title.trim().isEmpty
        ? '未命名'
        : template.title.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
      child: Row(
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: p.surfaceSunken,
              borderRadius: AppRadius.mdAll,
              border: Border.all(color: p.outlineSoft),
            ),
            child: Icon(
              LucideIcons.fileText,
              size: AppIconSize.xs,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: p.textPrimary,
                    fontFamily: AppFonts.ui,
                    fontFamilyFallback: AppFonts.uiFallback,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  template.relativePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: p.textTertiary,
                    fontFamily: AppFonts.mono,
                    fontFamilyFallback: AppFonts.monoFallback,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          _RecorderField(
            binding: binding,
            recording: recording,
            onTap: () => _record(template.id),
          ),
          const SizedBox(width: 6),
          _ActionDropdown(
            action: binding?.action ?? TemplateAction.insert,
            enabled: binding != null,
            onChanged: (TemplateAction action) =>
                _changeAction(template.id, action),
          ),
          SizedBox(
            width: 28,
            height: 28,
            child: binding == null
                ? null
                : AppIconButton(
                    icon: LucideIcons.x,
                    tooltip: '清除快捷键',
                    size: 24,
                    iconSize: 12,
                    onPressed: () => _clear(template.id),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty(AppPalette p, String folder) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: p.surfaceSunken,
              borderRadius: AppRadius.lgAll,
              border: Border.all(color: p.outlineSoft),
            ),
            child: Icon(
              LucideIcons.keyboard,
              size: 17,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '还没有可绑定快捷键的模板',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: p.textPrimary,
              fontFamily: AppFonts.ui,
              fontFamilyFallback: AppFonts.uiFallback,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '在「$folder」文件夹里新建一篇笔记，它就会出现在这里。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: p.textTertiary,
              fontFamily: AppFonts.ui,
              fontFamilyFallback: AppFonts.uiFallback,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecorderField extends StatelessWidget {
  const _RecorderField({
    required this.binding,
    required this.recording,
    required this.onTap,
  });

  final TemplateHotkey? binding;
  final bool recording;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String label = recording
        ? '按下按键…'
        : binding == null
        ? '未绑定'
        : chordLabel(binding!);
    final Color ink = recording
        ? p.accent
        : binding == null
        ? p.textTertiary
        : p.textSecondary;

    return Tooltip(
      message: recording ? '按 Esc 取消录制' : '点击后按下新的组合键',
      waitDuration: const Duration(milliseconds: 600),
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (BuildContext context, bool hovered) {
          return GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: AppMotion.fast,
              width: 138,
              height: 28,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: recording
                    ? p.accentSoft
                    : (hovered ? p.surfaceRaised : p.surfaceSunken),
                borderRadius: AppRadius.smAll,
                border: Border.all(
                  color: recording
                      ? p.accent
                      : (hovered ? p.outline : p.outlineSoft),
                ),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: recording ? FontWeight.w600 : FontWeight.w500,
                    color: ink,
                    fontFamily: AppFonts.mono,
                    fontFamilyFallback: AppFonts.monoFallback,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ActionDropdown extends StatelessWidget {
  const _ActionDropdown({
    required this.action,
    required this.enabled,
    required this.onChanged,
  });

  final TemplateAction action;
  final bool enabled;
  final ValueChanged<TemplateAction> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final Color ink = enabled ? p.textPrimary : p.textTertiary;
    return Container(
      width: 132,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: enabled ? p.surfaceRaised : p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outline),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<TemplateAction>(
          value: action,
          isDense: true,
          isExpanded: true,
          borderRadius: AppRadius.mdAll,
          dropdownColor: p.surfaceRaised,
          icon: Icon(
            LucideIcons.chevronDown,
            size: 14,
            color: enabled ? p.textTertiary : p.textTertiary.withValues(alpha: 0.5),
          ),
          style: TextStyle(
            fontSize: 11.5,
            color: ink,
            fontFamily: AppFonts.ui,
            fontFamilyFallback: AppFonts.uiFallback,
          ),
          onChanged: enabled
              ? (TemplateAction? value) {
                  if (value != null) onChanged(value);
                }
              : null,
          items: <DropdownMenuItem<TemplateAction>>[
            for (final TemplateAction action in TemplateAction.values)
              DropdownMenuItem<TemplateAction>(
                value: action,
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
