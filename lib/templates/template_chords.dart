import 'package:flutter/services.dart';

import '../state/template_settings.dart';

/// Chords the app already answers to, as `label → chord`.
///
/// A template shortcut is refused when it lands on one of these: two handlers
/// for the same key would make the template fire at random (or, worse, replace
/// 「新建笔记」). Text-editing chords are here for the same reason — a global
/// binding would otherwise swallow Ctrl+C inside the editor.
final List<({String label, int keyId, bool control, bool alt, bool shift})>
reservedTemplateChords =
    <({String label, int keyId, bool control, bool alt, bool shift})>[
      _chord('新建笔记', LogicalKeyboardKey.keyN, control: true),
      _chord('立即保存', LogicalKeyboardKey.keyS, control: true),
      _chord('插入链接', LogicalKeyboardKey.keyK, control: true),
      _chord('加粗', LogicalKeyboardKey.keyB, control: true),
      _chord('斜体', LogicalKeyboardKey.keyI, control: true),
      _chord('行内代码', LogicalKeyboardKey.keyE, control: true),
      _chord(
        '代码块',
        LogicalKeyboardKey.keyE,
        control: true,
        shift: true,
      ),
      _chord('标题 1', LogicalKeyboardKey.digit1, control: true),
      _chord('标题 2', LogicalKeyboardKey.digit2, control: true),
      _chord('标题 3', LogicalKeyboardKey.digit3, control: true),
      _chord('正文', LogicalKeyboardKey.digit0, control: true),
      _chord(
        '上一篇笔记',
        LogicalKeyboardKey.arrowUp,
        control: true,
        alt: true,
      ),
      _chord(
        '下一篇笔记',
        LogicalKeyboardKey.arrowDown,
        control: true,
        alt: true,
      ),
      _chord('收起侧边栏', LogicalKeyboardKey.backslash, control: true),
      _chord(
        '显示大纲',
        LogicalKeyboardKey.keyO,
        control: true,
        shift: true,
      ),
      _chord(
        '专注模式',
        LogicalKeyboardKey.keyF,
        control: true,
        shift: true,
      ),
      _chord('打开设置', LogicalKeyboardKey.comma, control: true),
      _chord('打开模板', LogicalKeyboardKey.keyP, control: true),
      _chord('切换标签', LogicalKeyboardKey.tab, control: true),
      _chord(
        '切换标签',
        LogicalKeyboardKey.tab,
        control: true,
        shift: true,
      ),
      _chord('撤销', LogicalKeyboardKey.keyZ, control: true),
      _chord('重做', LogicalKeyboardKey.keyZ, control: true, shift: true),
      _chord('重做', LogicalKeyboardKey.keyY, control: true),
      _chord('全选', LogicalKeyboardKey.keyA, control: true),
      _chord('复制', LogicalKeyboardKey.keyC, control: true),
      _chord('粘贴', LogicalKeyboardKey.keyV, control: true),
      _chord('剪切', LogicalKeyboardKey.keyX, control: true),
    ];

({String label, int keyId, bool control, bool alt, bool shift}) _chord(
  String label,
  LogicalKeyboardKey key, {
  bool control = false,
  bool alt = false,
  bool shift = false,
}) => (
  label: label,
  keyId: key.keyId,
  control: control,
  alt: alt,
  shift: shift,
);

/// The built-in action [binding] would collide with, or null.
String? reservedChordConflict(TemplateHotkey binding) {
  for (final ({String label, int keyId, bool control, bool alt, bool shift})
      chord in reservedTemplateChords) {
    if (binding.keyId == chord.keyId &&
        binding.control == chord.control &&
        binding.alt == chord.alt &&
        binding.shift == chord.shift) {
      return chord.label;
    }
  }
  return null;
}

/// `Ctrl + Shift + N`, the way the settings page writes shortcuts.
String chordLabel(TemplateHotkey binding) => chordLabelFor(
  binding.keyId,
  control: binding.control,
  alt: binding.alt,
  shift: binding.shift,
);

String chordLabelFor(
  int keyId, {
  required bool control,
  required bool alt,
  required bool shift,
}) {
  final String key =
      LogicalKeyboardKey.findKeyByKeyId(keyId)?.keyLabel ?? '按键 $keyId';
  return <String>[
    if (control) 'Ctrl',
    if (alt) 'Alt',
    if (shift) 'Shift',
    key,
  ].join(' + ');
}
