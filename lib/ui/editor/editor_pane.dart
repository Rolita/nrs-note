import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/markdown_actions.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../common/app_widgets.dart';
import 'live_markdown.dart';
import 'markdown_editor.dart';

/// The centre pane: note header, the live editor and a status bar. The outline
/// lives beside it as its own region, driven by the cursor line reported here.
class EditorPane extends StatefulWidget {
  const EditorPane({
    super.key,
    required this.onDelete,
    this.onCursorLineChanged,
    this.onOpenSearch,
  });

  final void Function(Note note) onDelete;
  final ValueChanged<int>? onCursorLineChanged;

  /// Called when a `#tag` in the text is clicked: the shell switches the
  /// sidebar to search so the results are actually on screen.
  final VoidCallback? onOpenSearch;

  @override
  State<EditorPane> createState() => EditorPaneState();
}

class EditorPaneState extends State<EditorPane> {
  /// Matches the editor's own padding; the pane needs it to map a source line
  /// onto a scroll offset.
  static const EdgeInsets _editorPadding = EdgeInsets.fromLTRB(40, 28, 40, 200);

  final TextEditingController _title = TextEditingController();
  late final MarkdownSourceController _body;
  final FocusNode _bodyFocus = FocusNode();
  final FocusNode _titleFocus = FocusNode();
  final ScrollController _editorScroll = ScrollController();

  String? _boundNoteId;
  int _cursorLine = 0;
  int _cursorColumn = 1;

  /// 同一个笔记 id 的正文被整段替换过几次。
  ///
  /// 它参与正文输入框的重建 key：外部版本覆盖草稿后，撤销栈里还留着替换
  /// 前的旧正文，Ctrl+Z 会把它恢复回来，自动保存再写回磁盘——还是覆盖。
  int _bodyEpoch = 0;

  /// The line the outline is highlighting. It follows the caret while the user
  /// writes, and the top of the viewport while the user only scrolls.
  int _outlineLine = 0;

  /// When the caret last moved. A scroll that happens right after a keystroke is
  /// the field keeping the caret in view, not the reader scrolling, and it must
  /// not drag the outline away from the line being written.
  DateTime _lastCaretMove = DateTime.fromMillisecondsSinceEpoch(0);

  /// True while the editor is animating to a heading, so the scroll events that
  /// animation produces do not fight the heading that was just clicked.
  bool _jumping = false;

  double _contentWidth = AppLayout.proseMaxWidth;

  /// 「源码行 → 文档坐标 y」，由编辑器注册；未挂载时为 `null`。
  double? Function(int line)? _lineTopProbe;

  bool _binding = false;

  @override
  void initState() {
    super.initState();
    _body = MarkdownSourceController();
    _body.addListener(_onBodyChanged);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    _titleFocus.dispose();
    _editorScroll.dispose();
    super.dispose();
  }

  void _onBodyChanged() {
    // Binding a note writes the controller from inside `build`; swallowing the
    // notification there keeps us out of "setState during build" territory.
    if (_binding) return;
    final TextSelection sel = _body.selection;
    final String text = _body.text;
    final int caret = sel.baseOffset.clamp(0, text.length);
    final ({int line, int column}) position = _caretPosition(text, caret);
    final int line = position.line;
    final int column = position.column;
    if (line != _cursorLine || column != _cursorColumn) {
      final bool lineMoved = line != _cursorLine;
      setState(() {
        _cursorLine = line;
        _cursorColumn = column;
      });
      if (lineMoved) {
        _lastCaretMove = DateTime.now();
        _reportOutlineLine(line);
        _maybeTypewriter(line);
      }
    }
  }

  /// 光标所在的源码行（从 0 开始）与列（从 1 开始）。
  ///
  /// 旧实现先 `substring(0, caret)` 再 `allMatches`：每次击键都要复制整个
  /// 前缀，还要为每个换行造一个 `Match`。换行只是一个 UTF-16 码元，直接
  /// 数 `codeUnitAt` 结果完全相同，且不再分配临时字符串。
  ({int line, int column}) _caretPosition(String text, int caret) {
    int line = 0;
    for (int i = 0; i < caret; i++) {
      if (text.codeUnitAt(i) == 0x0A) line++;
    }
    // Shared with the action layer, so the readout can never disagree with what
    // the toolbar thinks the caret's line is.
    return (line: line, column: caret - lineStartOf(text, caret) + 1);
  }

  /// Tells the outline which line to light up, once.
  void _reportOutlineLine(int line) {
    if (line == _outlineLine) return;
    _outlineLine = line;
    widget.onCursorLineChanged?.call(line);
  }

  /// The viewport was scrolled: follow the first line the reader can see.
  ///
  /// Two scrolls are not the reader's: the animation started by a click in the
  /// outline, and the field keeping the caret in view a moment after a
  /// keystroke. Both are ignored — the caret already names the right section.
  void _onTopLine(int line) {
    if (_jumping) return;
    if (DateTime.now().difference(_lastCaretMove) <
        const Duration(milliseconds: 300)) {
      return;
    }
    _reportOutlineLine(line);
  }

  /// Called by the shell so global shortcuts can reach the live controllers.
  void applyEdit(MarkdownEditFn fn) {
    final TextEditingValue next = fn(_body.value);
    _body.value = next;
    context.read<NotesController>().updateBody(next.text);
    _bodyFocus.requestFocus();
  }

  // ---------------------------------------------------------------- binding

  void _bind(Note note) {
    if (_boundNoteId == note.id) {
      _syncBoundBody(note);
      return;
    }
    _boundNoteId = note.id;
    _binding = true;
    _title.text = note.title;
    _body.text = note.body;
    _body.selection = const TextSelection.collapsed(offset: 0);
    final bool hadCursor = _cursorLine != 0 || _outlineLine != 0;
    _cursorLine = 0;
    _cursorColumn = 1;
    _outlineLine = 0;
    _binding = false;
    if (hadCursor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onCursorLineChanged?.call(0);
      });
    }
    // A brand-new note should let the user start typing a title right away —
    // and since a new note *is* named 未命名 (the file is `未命名.md`), the
    // placeholder is selected so the first keystroke replaces it instead of
    // being appended to it.
    final bool fresh =
        note.body.isEmpty &&
        DateTime.now().difference(note.createdAt).inSeconds < 4;
    if (fresh) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _titleFocus.requestFocus();
        _title.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _title.text.length,
        );
      });
    }
  }

  /// 同一个 id 不等于同一份内容：磁盘上的版本可能被外部改过，控制器也可能
  /// 刚「采用磁盘版本」（见 `refresh` 的 reload 分支与 `takeTheirs`）。
  ///
  /// 只按 id 判断是否绑定，编辑器就会一直显示旧正文，下一次敲键又把旧正文存
  /// 回去，覆盖掉外部更新；所以正文不同就整段换成这份笔记的正文，并清掉撤销
  /// 栈（[_bodyEpoch] 参与输入框的重建 key）。
  void _syncBoundBody(Note note) {
    if (note.body == _body.text) return;
    final TextSelection selection = _body.selection;
    final bool fits =
        selection.isValid &&
        selection.baseOffset <= note.body.length &&
        selection.extentOffset <= note.body.length;
    final TextSelection nextSelection = fits
        ? selection
        : TextSelection.collapsed(offset: note.body.length);
    _binding = true;
    try {
      _body.value = TextEditingValue(text: note.body, selection: nextSelection);
    } finally {
      _binding = false;
    }
    _bodyEpoch++;
    // `_binding` 挡住了 `_onBodyChanged`，这里自己把状态栏的行列数算回去。
    final int caret = nextSelection.baseOffset.clamp(0, note.body.length);
    final ({int line, int column}) position = _caretPosition(note.body, caret);
    _cursorLine = position.line;
    _cursorColumn = position.column;
  }

  // ------------------------------------------------------------ navigation

  /// Height of the laid-out text above `line`.
  ///
  /// 行高由行引擎按每行自己的字号量出来（标题、代码、正文各不相同），宿主
  /// 推算会一路累积误差；只有编辑器还没排版时（首帧）才退回旧推算。
  double _lineTop(int line, TextStyle style) =>
      _lineTopProbe?.call(line) ??
      textHeightAbove(
        text: _body.text,
        base: style,
        p: context.palette,
        line: line,
        contentWidth: _contentWidth,
      );

  Future<void> _scrollToLine(
    int line, {
    required TextStyle style,
    double anchor = 0.2,
    Duration duration = AppMotion.slow,
  }) async {
    if (!_editorScroll.hasClients) return;
    final ScrollPosition pos = _editorScroll.position;
    final double contentY = _editorPadding.top + _lineTop(line, style);
    final double target = (contentY - pos.viewportDimension * anchor).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    // The heading that was clicked is the one the outline must keep lit, even
    // though the jump lands it a fifth of the way down and the lines above it
    // are what the viewport now starts on.
    _jumping = true;
    try {
      await _editorScroll.animateTo(
        target,
        duration: duration,
        curve: AppMotion.enter,
      );
    } finally {
      // One more frame: the last scroll notification of the animation arrives
      // after `animateTo` completes.
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumping = false);
    }
  }

  /// Jumping from the outline also parks the caret on that heading, so the raw
  /// markers of the block you landed on reveal themselves.
  void _goToHeading(int line, TextStyle style) {
    final List<String> lines = _body.text.split('\n');
    if (lines.isEmpty) return;
    final int target = line.clamp(0, lines.length - 1);
    int offset = 0;
    for (int i = 0; i < target; i++) {
      offset += lines[i].length + 1;
    }
    _body.selection = TextSelection.collapsed(
      offset: offset.clamp(0, _body.text.length),
    );
    unawaited(_scrollToLine(target, style: style, anchor: 0.12));
  }

  /// Used by the far-right outline region, which lives outside this pane and so
  /// cannot hand over the current prose style.
  void goToHeading(int line) {
    final SettingsController settings = context.read<SettingsController>();
    _goToHeading(line, editorProseStyle(context.palette, settings.proseSize));
  }

  void _maybeTypewriter(int line) {
    if (!mounted) return;
    if (!_bodyFocus.hasFocus) return;
    if (!context.read<SettingsController>().typewriter) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _scrollToLine(
          line,
          style: editorProseStyle(
            context.palette,
            context.read<SettingsController>().proseSize,
          ),
          anchor: 0.5,
          duration: AppMotion.fast,
        ),
      );
    });
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();
    final SettingsController settings = context.watch<SettingsController>();
    final Note? note = notes.draft ?? notes.selectedNote;

    if (note == null) return _noSelection(p, notes);

    final DraftConflict? conflict = notes.conflict;

    _bind(note);
    if (_title.text != note.title && !_titleFocus.hasFocus) {
      _title.text = note.title;
    }

    // The task checkboxes drawn by the live renderer write straight back into
    // the draft.
    _body.onExternalChange = notes.updateBody;

    return Container(
      color: p.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(p, note, notes, settings),
          if (conflict != null && conflict.noteId == note.id)
            _conflictBar(p, conflict, notes),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) => _titleRow(
              p,
              note,
              notes,
              _proseSide(c.maxWidth),
            ),
          ),
          // No formatting ribbon: every action lives in the editor's own
          // right-click menu now, and the shortcuts are unchanged.
          // ⛔ 快捷键只包住正文编辑器：包住整个面板会把标题框的 Ctrl+Z 也
          // 抢去撤销正文，正文里存的是没按标题改过的内容，自动保存再写回
          // 文件就是一次覆盖。
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return _workspace(notes, c.maxWidth);
              },
            ),
          ),
          _statusBar(p, note, notes, settings),
        ],
      ),
    );
  }

  Map<ShortcutActivator, Intent> _editorShortcuts() {
    return <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.keyB, control: true):
          const _EditIntent(_EditKind.bold),
      const SingleActivator(LogicalKeyboardKey.keyI, control: true):
          const _EditIntent(_EditKind.italic),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true):
          const _EditIntent(_EditKind.inlineCode),
      const SingleActivator(
        LogicalKeyboardKey.keyE,
        control: true,
        shift: true,
      ): const _EditIntent(
        _EditKind.codeBlock,
      ),
      const SingleActivator(LogicalKeyboardKey.keyK, control: true):
          const _EditIntent(_EditKind.link),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true):
          const _EditIntent(_EditKind.save),
      const SingleActivator(LogicalKeyboardKey.digit1, control: true):
          const _EditIntent(_EditKind.h1),
      const SingleActivator(LogicalKeyboardKey.digit2, control: true):
          const _EditIntent(_EditKind.h2),
      const SingleActivator(LogicalKeyboardKey.digit3, control: true):
          const _EditIntent(_EditKind.h3),
      const SingleActivator(LogicalKeyboardKey.digit0, control: true):
          const _EditIntent(_EditKind.plain),
      const SingleActivator(
        LogicalKeyboardKey.digit7,
        control: true,
        shift: true,
      ): const _EditIntent(
        _EditKind.orderedList,
      ),
      const SingleActivator(
        LogicalKeyboardKey.digit8,
        control: true,
        shift: true,
      ): const _EditIntent(
        _EditKind.bulletList,
      ),
      const SingleActivator(
        LogicalKeyboardKey.keyT,
        control: true,
        shift: true,
      ): const _EditIntent(
        _EditKind.table,
      ),
      const SingleActivator(
        LogicalKeyboardKey.keyQ,
        control: true,
        shift: true,
      ): const _EditIntent(
        _EditKind.quote,
      ),
    };
  }

  Map<Type, Action<Intent>> _editorActions(NotesController notes) {
    return <Type, Action<Intent>>{
      _EditIntent: CallbackAction<_EditIntent>(
        onInvoke: (_EditIntent intent) {
          switch (intent.kind) {
            case _EditKind.save:
              // A manual save is the *same* save as the automatic one, so it
              // says nothing: the status bar already carries the state, and a
              // toast on top of it is the second "已保存到磁盘" the user asked to
              // stop showing.
              unawaited(notes.saveNow());
            case _EditKind.bold:
              applyEdit(wrapSelection('**', '**'));
            case _EditKind.italic:
              applyEdit(wrapSelection('*', '*'));
            case _EditKind.inlineCode:
              applyEdit(wrapSelection('`', '`', placeholder: 'code'));
            case _EditKind.codeBlock:
              applyEdit(codeBlock());
            case _EditKind.link:
              applyEdit(insertLink());
            case _EditKind.h1:
              applyEdit(applyBlockStyle(BlockStyle.h1));
            case _EditKind.h2:
              applyEdit(applyBlockStyle(BlockStyle.h2));
            case _EditKind.h3:
              applyEdit(applyBlockStyle(BlockStyle.h3));
            case _EditKind.plain:
              applyEdit(applyBlockStyle(BlockStyle.paragraph));
            case _EditKind.orderedList:
              applyEdit(applyBlockStyle(BlockStyle.ordered));
            case _EditKind.bulletList:
              applyEdit(applyBlockStyle(BlockStyle.bullet));
            case _EditKind.task:
              applyEdit(applyBlockStyle(BlockStyle.task));
            case _EditKind.orderedTask:
              applyEdit(applyBlockStyle(BlockStyle.orderedTask));
            case _EditKind.quote:
              applyEdit(applyBlockStyle(BlockStyle.quote));
            case _EditKind.table:
              applyEdit(insertBlock(kTableSkeleton.trim()));
          }
          return null;
        },
      ),
    };
  }

  // ----------------------------------------------------------------- header

  Widget _header(
    AppPalette p,
    Note note,
    NotesController notes,
    SettingsController settings,
  ) {
    // Where the note lives. The title is the H1 directly below, so repeating it
    // here would only take room away from the one thing the header can say that
    // the page cannot: its place in the vault.
    final String where = note.folderPath.trim().isEmpty
        ? '笔记库'
        : note.folderPath.replaceAll(RegExp(r'[/\\]'), ' / ');

    return Container(
      height: AppLayout.toolbarHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: p.outlineSoft)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              where,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          AppIconButton(
            icon: LucideIcons.alignVerticalJustifyCenter,
            tooltip: '打字机模式',
            active: settings.typewriter,
            onPressed: () => settings.typewriter = !settings.typewriter,
          ),
          AppIconButton(
            icon: LucideIcons.maximize,
            tooltip: '专注模式',
            shortcut: 'Ctrl+Shift+F',
            active: settings.focusMode,
            onPressed: () => settings.focusMode = !settings.focusMode,
          ),
          _TypographyMenu(settings: settings),
          _MoreMenu(
            note: note,
            notes: notes,
            onDelete: () => widget.onDelete(note),
          ),
        ],
      ),
    );
  }

  /// A quiet strip, not a dialog: the file changed under the note, and the user
  /// has to pick a side before autosave resumes. Typing keeps working while it
  /// is visible.
  Widget _conflictBar(
    AppPalette p,
    DraftConflict conflict,
    NotesController notes,
  ) {
    final bool deleted = conflict.isDeleted;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpace.md, 4, AppSpace.sm, 4),
      decoration: BoxDecoration(
        color: p.warningSoft,
        border: Border(
          bottom: BorderSide(color: p.warning.withValues(alpha: 0.35)),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(LucideIcons.refreshCwOff, size: 15, color: p.warning),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              deleted ? '磁盘上的这篇笔记已被删除。' : '磁盘上的这篇笔记已在外部修改。',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textSecondary,
              ),
            ),
          ),
          if (deleted) ...<Widget>[
            AppTextButton(
              label: '另存为副本',
              onPressed: () {
                notes.saveConflictCopy();
              },
            ),
            AppTextButton(
              label: '放弃我的',
              onPressed: () {
                notes.takeTheirs();
              },
            ),
          ] else ...<Widget>[
            AppTextButton(
              label: '载入磁盘版本',
              onPressed: () {
                notes.takeTheirs();
              },
            ),
            AppTextButton(
              label: '保留我的',
              tone: p.accent,
              onPressed: () {
                notes.keepMine();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _titleRow(
    AppPalette p,
    Note note,
    NotesController notes,
    double side,
  ) {
    // H1, as the live renderer draws it: body size scaled by 1.74 with the
    // same tracking and weight (see `_headingStyle` in live_markdown.dart).
    // The title field *is* the note's H1 — there is no separate file-name row.
    final double h1Size = context.read<SettingsController>().proseSize * 1.74;

    return Padding(
      padding: EdgeInsets.fromLTRB(side, AppSpace.md, side, AppSpace.sm),
      // ⛔ 标题框的撤销栈也必须随笔记清空：它由同一个控制器跨笔记复用，
      // Ctrl+Z 会把上一份笔记的标题恢复进当前标题，`updateTitle` 随即按旧
      // 标题重命名当前文件，等于拿旧名字覆盖一条文件记录。
      child: KeyedSubtree(
        key: ValueKey<String>('title-${note.id}'),
        child: TextField(
          controller: _title,
          focusNode: _titleFocus,
          onChanged: notes.updateTitle,
          cursorColor: p.accent,
          cursorWidth: 1.8,
          // Same rule as the body: highlight the title's glyphs, not the
          // whole field width (Flutter's desktop default is `max`).
          selectionWidthStyle: ui.BoxWidthStyle.tight,
          style: TextStyle(
            fontFamily: AppFonts.prose,
            fontFamilyFallback: AppFonts.proseFallback,
            fontSize: h1Size,
            height: snapLineHeight(h1Size, 1.3),
            fontWeight: FontWeight.w600,
            letterSpacing: -0.45,
            color: p.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            hintText: '未命名',
            hintStyle: TextStyle(
              fontFamily: AppFonts.prose,
              fontFamilyFallback: AppFonts.proseFallback,
              fontSize: h1Size,
              height: snapLineHeight(h1Size, 1.3),
              fontWeight: FontWeight.w600,
              letterSpacing: -0.45,
              color: p.textTertiary.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- workspace

  /// Where the prose column starts inside [availableWidth].
  ///
  /// The column is capped and centred, the way the design sheet draws it. The
  /// title row and the body share this number: they are the same paragraph as
  /// far as the eye is concerned, and a 20px step between them was the most
  /// visible misalignment in the whole pane.
  double _proseSide(double availableWidth) => math.max(
    _editorPadding.left,
    (availableWidth - AppLayout.proseMaxWidth) / 2,
  );

  Widget _workspace(NotesController notes, double availableWidth) {
    // The *field* stays full width, because the padding is what moves the text:
    // constraining the widget instead would leave the gutter beside the column
    // dead to clicks, and "click the paper to start typing" has to keep working
    // everywhere.
    final double side = _proseSide(availableWidth);
    final EdgeInsets padding = EdgeInsets.fromLTRB(side, 28, side, 200);

    // Exactly the width the laid-out text gets, so the few spans that draw a
    // real widget (rules, images) can span the column without overflowing it.
    final double contentWidth = (availableWidth - padding.horizontal).clamp(
      60.0,
      AppLayout.proseMaxWidth,
    );
    _contentWidth = contentWidth;

    return Shortcuts(
      shortcuts: _editorShortcuts(),
      child: Actions(
        actions: _editorActions(notes),
        child: MarkdownEditor(
          controller: _body,
          focusNode: _bodyFocus,
          scrollController: _editorScroll,
          fontSize: context.read<SettingsController>().proseSize,
          padding: padding,
          // 带上 [_bodyEpoch]：id 相同但正文被外部整段替换时，输入框也要
          // 重建，撤销栈才不会把替换前的正文恢复回来。
          documentId: '${(notes.draft ?? notes.selectedNote)?.id}#$_bodyEpoch',
          onChanged: notes.updateBody,
          onTopLineChanged: _onTopLine,
          onLineTopProbe: (double? Function(int line)? probe) =>
              _lineTopProbe = probe,
          onTagTap: (String tag) {
            notes.toggleTag(tag);
            widget.onOpenSearch?.call();
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------ status bar

  Widget _statusBar(
    AppPalette p,
    Note note,
    NotesController notes,
    SettingsController settings,
  ) {
    // The status bar is the *only* place the save state is announced: saving is
    // automatic, so a toast on every write would be a toast per sentence. Only
    // "已保存" is allowed a colour — the other three are the resting state or the
    // 300ms wait before the write, and painting that window orange made a
    // warning banner out of simply typing.
    final (String label, Color color) = switch (notes.saveState) {
      SaveState.saving => ('保存中…', p.textTertiary),
      SaveState.dirty => ('未保存', p.textTertiary),
      SaveState.saved => ('已保存', p.success),
      SaveState.idle => ('已同步', p.textTertiary),
    };

    return Container(
      height: AppLayout.footerHeight,
      padding: kEditorChromePadding,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.outlineSoft)),
      ),
      child: Row(
        children: <Widget>[
          AnimatedContainer(
            duration: AppMotion.fast,
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(fontSize: AppText.caption, color: p.textTertiary),
          ),
          const SizedBox(width: 14),
          _Stat(
            text: '行 ${_cursorLine + 1},列 $_cursorColumn',
            color: p.textTertiary,
          ),
          if (settings.typewriter) ...<Widget>[
            const SizedBox(width: 14),
            _Stat(text: '打字机', color: p.accent),
          ],
          const Spacer(),
          if (note.taskTotal > 0) ...<Widget>[
            _Stat(
              text: '待办 ${note.taskDone}/${note.taskTotal}',
              color: note.taskDone == note.taskTotal
                  ? p.success
                  : p.textTertiary,
            ),
            const SizedBox(width: 14),
          ],
          _Stat(text: '${note.wordCount} 字', color: p.textTertiary),
          const SizedBox(width: 14),
          _Stat(text: '${note.characterCount} 字符', color: p.textTertiary),
          if (note.readingMinutes > 0) ...<Widget>[
            const SizedBox(width: 14),
            _Stat(text: '约 ${note.readingMinutes} 分钟', color: p.textTertiary),
          ],
          const SizedBox(width: AppSpace.sm),
        ],
      ),
    );
  }

  Widget _noSelection(AppPalette p, NotesController notes) {
    if (notes.isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: p.accent),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(
              '正在打开笔记库…',
              style: TextStyle(fontSize: AppText.ui, color: p.textTertiary),
            ),
          ],
        ),
      );
    }
    return EmptyState(
      icon: LucideIcons.fileText,
      title: '选择一篇笔记开始',
      message: notes.allNotes.isEmpty
          ? '或者用 Ctrl+N 创建你的第一篇笔记。'
          : '左侧列表里挑一篇,或者按 Ctrl+N 新建。',
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: AppText.caption, color: color),
  );
}

enum _EditKind {
  bold,
  italic,
  inlineCode,
  codeBlock,
  link,
  save,
  h1,
  h2,
  h3,
  plain,
  orderedList,
  bulletList,
  task,
  orderedTask,
  quote,
  table,
}

class _EditIntent extends Intent {
  const _EditIntent(this.kind);
  final _EditKind kind;
}

/// Body typography preference.
class _TypographyMenu extends StatelessWidget {
  const _TypographyMenu({required this.settings});

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return PopupMenuButton<int>(
      tooltip: '正文字号',
      position: PopupMenuPosition.under,
      color: p.surfaceRaised,
      constraints: const BoxConstraints(minWidth: 260),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        PopupMenuItem<int>(
          enabled: false,
          height: 96,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setLocal) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        '正文字号',
                        style: TextStyle(fontSize: 12, color: p.textSecondary),
                      ),
                      const Spacer(),
                      Text(
                        settings.proseSize.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: AppFonts.mono,
                          color: p.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: settings.proseSize,
                    min: 13,
                    max: 22,
                    divisions: 18,
                    onChanged: (double v) {
                      settings.proseSize = v;
                      setLocal(() {});
                    },
                  ),
                ],
              );
            },
          ),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: _MenuTrigger(icon: LucideIcons.aLargeSmall, tooltip: '正文字号'),
      ),
    );
  }
}

class _MenuTrigger extends StatefulWidget {
  const _MenuTrigger({required this.icon, required this.tooltip});

  final IconData icon;
  final String tooltip;

  @override
  State<_MenuTrigger> createState() => _MenuTriggerState();
}

class _MenuTriggerState extends State<_MenuTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: AppMotion.fast,
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: _hovered ? p.surfaceRaised : Colors.transparent,
            borderRadius: AppRadius.smAll,
          ),
          child: Icon(
            widget.icon,
            size: 16.5,
            color: _hovered ? p.textPrimary : p.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.note,
    required this.notes,
    required this.onDelete,
  });

  final Note note;
  final NotesController notes;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      position: PopupMenuPosition.under,
      color: p.surfaceRaised,
      onSelected: (String action) async {
        switch (action) {
          case 'copy':
            await Clipboard.setData(
              ClipboardData(text: notes.exportSelectedMarkdown()),
            );
          case 'duplicate':
            notes.duplicate(note);
          case 'reveal':
            await notes.revealVault();
          case 'reload':
            await notes.refresh();
          case 'delete':
            onDelete();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        _entry(p, 'copy', LucideIcons.copy, '复制 Markdown'),
        _entry(p, 'duplicate', LucideIcons.copyPlus, '创建副本'),
        if (notes.supportsNativeFiles)
          _entry(p, 'reveal', LucideIcons.folderOpen, '打开笔记库文件夹'),
        _entry(p, 'reload', LucideIcons.refreshCw, '从磁盘重新载入'),
        const PopupMenuDivider(),
        _entry(p, 'delete', LucideIcons.trash2, '删除笔记', danger: true),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: _MenuTrigger(icon: LucideIcons.ellipsis, tooltip: '更多操作'),
      ),
    );
  }

  PopupMenuItem<String> _entry(
    AppPalette p,
    String value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 15, color: danger ? p.danger : p.textSecondary),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: danger ? p.danger : p.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
