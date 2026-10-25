import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../templates/template_dialog_frame.dart';

/// 白板上「挑一篇笔记」「填一个网址」这两个小弹窗。
///
/// 和模板选择器不同，这里要的是**一个值**，所以不复制那套分组列表，
/// 只做一个带搜索框的平铺列表——白板上的文件卡片通常只放几篇，
/// 找的时候是「我记得它叫什么」，不是「我记得它在哪个文件夹」。

/// 挑一篇笔记。返回相对路径，取消返回 null。
Future<String?> showCanvasFilePicker(
  BuildContext context, {
  required List<({String path, String title})> files,
}) {
  final AppPalette p = context.palette;
  return showDialog<String>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) =>
        _FilePickerDialog(files: files),
  );
}

class _FilePickerDialog extends StatefulWidget {
  const _FilePickerDialog({required this.files});

  final List<({String path, String title})> files;

  @override
  State<_FilePickerDialog> createState() => _FilePickerDialogState();
}

class _FilePickerDialogState extends State<_FilePickerDialog> {
  final TextEditingController _query = TextEditingController();
  bool _done = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _pick(String path) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(path);
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop();
  }

  List<({String path, String title})> get _matches {
    final String q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.files;
    return widget.files
        .where(
          (r) =>
              r.title.toLowerCase().contains(q) ||
              r.path.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final List<({String path, String title})> matches = _matches;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (matches.isNotEmpty) _pick(matches.first.path);
        },
      },
      child: TemplateDialogFrame(
        icon: LucideIcons.fileText,
        title: '放一篇笔记到白板',
        subtitle: '卡片上显示文件名，双击卡片会打开这篇笔记',
        width: 460,
        onClose: _cancel,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                decoration: BoxDecoration(
                  color: p.surfaceSunken,
                  borderRadius: AppRadius.mdAll,
                  border: Border.all(color: p.outline),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  cursorColor: p.accent,
                  cursorWidth: 1.3,
                  style: TextStyle(
                    fontSize: AppText.ui,
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
                    hintText: '搜索标题或路径',
                    hintStyle: TextStyle(
                      fontSize: AppText.ui,
                      color: p.textTertiary,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: matches.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          widget.files.isEmpty ? '库里还没有笔记' : '没有匹配的笔记',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: AppText.ui,
                            color: p.textTertiary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: matches.length,
                        itemBuilder: (BuildContext context, int i) {
                          final ({String path, String title}) row = matches[i];
                          return _FileRow(
                            title: row.title,
                            path: row.path,
                            onTap: () => _pick(row.path),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({
    required this.title,
    required this.path,
    required this.onTap,
  });

  final String title;
  final String path;
  final VoidCallback onTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.sm,
            vertical: AppSpace.sm,
          ),
          decoration: BoxDecoration(
            color: _hovered ? p.accentSoft : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: Row(
            children: <Widget>[
              Icon(LucideIcons.fileText, size: 14, color: p.textTertiary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppText.ui, color: p.textPrimary),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Flexible(
                child: Text(
                  widget.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppText.caption,
                    color: p.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 填一个网址。返回整理好的 URL，取消返回 null。
Future<String?> showCanvasLinkDialog(
  BuildContext context, {
  String? initial,
}) {
  final AppPalette p = context.palette;
  return showDialog<String>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) => _LinkDialog(initial: initial),
  );
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({this.initial});

  final String? initial;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initial ?? '',
  );
  bool _done = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    if (_done) return;
    final String value = normalizeCanvasUrl(_url.text);
    if (value.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(value);
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
        icon: LucideIcons.link,
        title: '放一个链接到白板',
        subtitle: '不带协议就按 https 处理',
        width: 420,
        onClose: _cancel,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                decoration: BoxDecoration(
                  color: p.surfaceSunken,
                  borderRadius: AppRadius.mdAll,
                  border: Border.all(color: p.accent),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: TextField(
                  controller: _url,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  cursorColor: p.accent,
                  cursorWidth: 1.3,
                  style: TextStyle(
                    fontSize: AppText.ui,
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
                    hintText: 'https://',
                    hintStyle: TextStyle(
                      fontSize: AppText.ui,
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
      ),
    );
  }
}

/// 把用户随手填的东西补成一个能点的地址。
///
/// 只认 http/https：`file://` 之类的东西从一个笔记文件里点开，是那种
/// 「本来只想试试」的漏洞。没有协议就补 `https://`。
String normalizeCanvasUrl(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return '';
  final Uri? uri = Uri.tryParse(value);
  if (uri == null) return '';
  if (uri.hasScheme) {
    return (uri.scheme == 'http' || uri.scheme == 'https') ? value : '';
  }
  return 'https://$value';
}
