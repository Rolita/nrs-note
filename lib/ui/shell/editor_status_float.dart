import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../editor/editor_pane.dart' show EditorCaret;

/// 编辑区右下角那枚共用的状态浮片。
///
/// 每格底部的信息条已经删除；这一枚不跟着某一格走，固定贴在编辑区右下角，
/// 显示**聚焦那一格**的保存状态、行列、待办和字数。分屏时点哪格，内容就换成
/// 哪格——位置永远不动，也不接收指针（压在正文上照样能落光标）。
class EditorStatusFloat extends StatelessWidget {
  const EditorStatusFloat({
    super.key,
    required this.noteId,
    required this.caret,
  });

  /// 聚焦格当前页钉住的笔记；`null` = 跟着全局选中走（活笔记）。
  ///
  /// 与 [EditorPane] 取值同一条规则，浮片和正文不会各说各的。
  final String? noteId;

  /// 聚焦格发布的当前行列。只读格不发布，所以切换聚焦格时由外壳把同一个
  /// notifier 交给新的活格子。
  final ValueListenable<EditorCaret> caret;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();
    final String? pinned = noteId;
    final Note? note = pinned == null
        ? (notes.draft ?? notes.selectedNote)
        : notes.noteById(pinned);
    if (note == null) return const SizedBox.shrink();

    // 保存状态是整个应用唯一宣布自动保存的地方：只有「已保存」配得上颜色，
    // 其余三种是静止状态或写盘前那 300ms 的等待，涂成警告色会让打字本身
    // 变成一条橙色横幅。
    final (String stateLabel, Color dotColor) = switch (notes.saveState) {
      SaveState.saving => ('保存中…', p.textTertiary),
      SaveState.dirty => ('未保存', p.textTertiary),
      SaveState.saved => ('已保存', p.success),
      SaveState.idle => ('已同步', p.textTertiary),
    };

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 编辑区最窄时只有约 386px，六项排不下。按可用宽度逐级收：阅读时间和
        // 字符数先走，字数和待办最后走——它们比前两项常用。
        final double width = c.maxWidth;
        final bool showTime = width >= 480;
        final bool showChars = width >= 420;
        final bool showWords = width >= 300;

        final TextStyle style = TextStyle(
          fontSize: AppText.caption,
          color: p.textTertiary,
          // 等宽数字：字数每变一位，整枚浮片不会跟着抖。
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: p.surfaceRaised,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.outlineSoft),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.75),
                offset: const Offset(0, 10),
                blurRadius: 24,
                spreadRadius: -14,
              ),
            ],
          ),
          child: ValueListenableBuilder<EditorCaret>(
            valueListenable: caret,
            builder: (BuildContext context, EditorCaret c, Widget? _) {
              final List<Widget> children = <Widget>[
                AnimatedContainer(
                  duration: AppMotion.fast,
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
                _item(Text(stateLabel, style: style)),
                // 行列写成「行 X, 列 Y」——逗号后留一格，读起来是两组数，
                // 不是一串。
                _item(_ClipText('行 ${c.line + 1}, 列 ${c.column}', style)),
                if (showWords && note.taskTotal > 0)
                  _item(
                    _ClipText('待办 ${note.taskDone}/${note.taskTotal}', style),
                  ),
                if (showWords)
                  _item(_ClipText('${_group(note.wordCount)} 字', style)),
                if (showChars)
                  _item(_ClipText('${_group(note.characterCount)} 字符', style)),
                if (showTime && note.readingMinutes > 0)
                  _item(_ClipText('约 ${note.readingMinutes} 分钟', style)),
              ];
              return Row(mainAxisSize: MainAxisSize.min, children: children);
            },
          ),
        );
      },
    );
  }

  /// 项与项之间留 12（视觉稿的 flex gap）；圆点后也是 12，别单独收窄。
  Widget _item(Widget child) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[const SizedBox(width: 12), child],
  );

  /// 862 → 862，1946 → 1,946。只处理正数，字数不会是别的。
  static String _group(int value) {
    final String digits = value.toString();
    if (digits.length <= 3) return digits;
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

/// 一行里可以压缩的文本：浮片再窄也不横向溢出，宁可省略尾巴。
class _ClipText extends StatelessWidget {
  const _ClipText(this.text, this.style);

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Flexible(
    child: Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: style,
    ),
  );
}
