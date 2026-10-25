import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/storage/canvas_store_factory.dart';
import '../templates/template_dialog_frame.dart';

/// 「打开白板」的选择结果。
sealed class CanvasPickerResult {
  const CanvasPickerResult();
}

/// 打开已有的那一块。
final class OpenCanvas extends CanvasPickerResult {
  const OpenCanvas(this.relativePath);

  final String relativePath;
}

/// 新建一块。
final class NewCanvas extends CanvasPickerResult {
  const NewCanvas();
}

/// 列出 vault 里所有白板，让用户挑一块，或者新建一块。
///
/// 只列 `.nrs`：白板不是笔记，混在笔记列表里会让人以为「这篇笔记怎么
/// 打不开」。这块弹窗只负责「挑」，打开和新建的动作交给 CanvasController。
Future<CanvasPickerResult?> showCanvasPicker(
  BuildContext context, {
  required List<CanvasRef> canvases,
}) {
  final AppPalette p = context.palette;
  return showDialog<CanvasPickerResult>(
    context: context,
    barrierColor: p.overlay,
    builder: (BuildContext context) => _CanvasPickerDialog(canvases: canvases),
  );
}

class _CanvasPickerDialog extends StatefulWidget {
  const _CanvasPickerDialog({required this.canvases});

  final List<CanvasRef> canvases;

  @override
  State<_CanvasPickerDialog> createState() => _CanvasPickerDialogState();
}

class _CanvasPickerDialogState extends State<_CanvasPickerDialog> {
  bool _done = false;

  void _pick(CanvasPickerResult result) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(result);
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
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
      },
      child: TemplateDialogFrame(
        icon: LucideIcons.squareDashed,
        title: '打开白板',
        subtitle: widget.canvases.isEmpty
            ? '还没有白板'
            : '${widget.canvases.length} 块白板，都在 vault 里',
        width: 480,
        onClose: _cancel,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: widget.canvases.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          '新建一块，然后往里拖卡片',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: AppText.ui,
                            color: p.textTertiary,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: widget.canvases.length,
                        itemBuilder: (BuildContext context, int i) {
                          final CanvasRef ref = widget.canvases[i];
                          return _CanvasRow(
                            ref: ref,
                            onTap: () => _pick(OpenCanvas(ref.relativePath)),
                          );
                        },
                      ),
              ),
              const SizedBox(height: AppSpace.md),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _pick(const NewCanvas()),
                  icon: Icon(LucideIcons.squarePlus, size: 15, color: p.accent),
                  label: Text(
                    '新建白板',
                    style: TextStyle(fontSize: AppText.ui, color: p.accent),
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

class _CanvasRow extends StatefulWidget {
  const _CanvasRow({required this.ref, required this.onTap});

  final CanvasRef ref;
  final VoidCallback onTap;

  @override
  State<_CanvasRow> createState() => _CanvasRowState();
}

class _CanvasRowState extends State<_CanvasRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final String path = widget.ref.relativePath;
    final String folder = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
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
              Icon(LucideIcons.squareDashed, size: 14, color: p.textTertiary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  widget.ref.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppText.ui, color: p.textPrimary),
                ),
              ),
              if (folder.isNotEmpty) ...<Widget>[
                const SizedBox(width: AppSpace.sm),
                Flexible(
                  child: Text(
                    folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppText.caption,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
