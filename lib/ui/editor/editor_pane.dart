import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/utils/external_link.dart';
import '../../core/utils/markdown_actions.dart';
import '../../core/utils/note_image.dart';
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
    this.showSearchHighlights = false,
    this.bodyValue,
    this.noteId,
    this.readOnly = false,
    this.onSplit,
    this.onClosePane,
  });

  /// 把这一格切成两半：`Axis.horizontal` 是左右，`Axis.vertical` 是上下。
  ///
  /// 切哪一格、切出来的新格装什么，都由外壳决定——面板只负责把按钮画在
  /// 自己头上。`null` 时这两颗按钮不画。
  final ValueChanged<Axis>? onSplit;

  /// 关掉这一格。只剩一格时外壳传 `null`——容器总得留一格。
  final VoidCallback? onClosePane;

  /// 只看这一篇，不跟着全局选中走。
  ///
  /// 分屏时非聚焦的那几格用得上：它们各看各的，只有聚焦的那格绑草稿。
  /// `null` = 老行为（`draft ?? selectedNote`）。
  final String? noteId;

  /// 只读。非聚焦的笔记格用它——分屏是为了同时看，不是为了同时写。
  ///
  /// 真正能写的那一格由「点一下它」决定：点了才绑草稿，撤销栈、自动保存
  /// 和冲突检测都只服务那一格，不用把这三套东西复制成多份。
  final bool readOnly;

  final void Function(Note note) onDelete;
  final ValueChanged<int>? onCursorLineChanged;

  /// Called when a `#tag` in the text is clicked: the shell switches the
  /// sidebar to search so the results are actually on screen.
  final VoidCallback? onOpenSearch;

  /// 侧栏停在搜索视图时为 true：正文里所有命中搜索词的文字都铺色带，
  /// 让用户不必逐行找。离开搜索视图即关掉。
  final bool showSearchHighlights;

  /// The live value of the body field, published for panels outside the pane
  /// (the table tools read the table at the caret). Written here instead of
  /// being read through the state's key, which is not available while the
  /// shell is still building.
  final ValueNotifier<TextEditingValue>? bodyValue;

  @override
  State<EditorPane> createState() => EditorPaneState();
}

class EditorPaneState extends State<EditorPane> {
  /// The minimum gutter between the pane's edge and the prose column.
  static const double _proseGutter = 40;

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

  /// 让正文输入框立刻重排并重绘一次，由编辑器注册；未挂载时为 `null`。
  ///
  /// 跳转收尾时用：按行绘制只看当前视口区间，万一收尾那一帧把区间算成了空段
  /// （或该帧被跳过），动画结束后又不会再有新帧，屏幕上就一直是空白，直到
  /// 指针 hover 触发重建。这里显式补一帧，把结果落定。
  VoidCallback? _settleJumpRepaint;

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
    _publishBody();
    // 用户动过正文（落点、移动光标、输入）：打开笔记时的静默揭示解除。
    _body.revealSuppressed = false;
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

  /// Hands the current body value to whoever listens (the table tools).
  ///
  /// Called from the controller's own notification, never from `build`, so a
  /// listener that rebuilds cannot land in the middle of a layout pass. A bind
  /// is the exception — it writes the controller inside `build` — and goes
  /// through [publishBodyAfterFrame] instead.
  void _publishBody() {
    final ValueNotifier<TextEditingValue>? out = widget.bodyValue;
    if (out == null || !mounted) return;
    out.value = _body.value;
  }

  void _publishBodyAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishBody();
    });
  }

  /// Called by the shell so global shortcuts can reach the live controllers.
  void applyEdit(MarkdownEditFn fn) {
    final TextEditingValue next = fn(_body.value);
    _body.value = next;
    context.read<NotesController>().updateBody(next.text);
    _bodyFocus.requestFocus();
  }

  /// The body text selected in the editor, or an empty string.
  ///
  /// A template is rendered with this as `tp.file.selection()`, and a partial
  /// replacement is why "insert" is not simply "append".
  String get selectedBodyText {
    final TextSelection selection = _body.selection;
    if (!selection.isValid || selection.isCollapsed) return '';
    return selection.textInside(_body.text);
  }

  /// Replaces the selection with an already-rendered template in one edit.
  ///
  /// The caller renders first; a failed or cancelled render never reaches this
  /// method, so a bad template cannot leave half a block in the prose.
  void insertTemplate(String text, {int? cursorOffset}) {
    applyEdit(insertTemplateText(text, cursorOffset: cursorOffset));
  }

  /// Places the caret after the body was replaced from outside — the
  /// template-new-note flow, whose cursor marker is only known once the note
  /// exists and has rendered.
  void placeCaretAt(int offset) {
    final int at = offset.clamp(0, _body.text.length);
    _body.revealSuppressed = false;
    _body.selection = TextSelection.collapsed(offset: at);
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
    // 光标停在文首是绑定的副产物，不是用户在编辑第一行：按住揭示，等正文里
    // 真正落点 / 移动光标 / 输入之后再摊开标记。
    _body.revealSuppressed = true;
    final bool hadCursor = _cursorLine != 0 || _outlineLine != 0;
    _cursorLine = 0;
    _cursorColumn = 1;
    _outlineLine = 0;
    _binding = false;
    _publishBodyAfterFrame();
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
    _publishBodyAfterFrame();
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
  double _lineTop(int line, TextStyle style) {
    final double? Function(int line)? lineTopProbe = _lineTopProbe;
    final double? probed = lineTopProbe?.call(line);
    return probed ??
        textHeightAbove(
          text: _body.text,
          base: style,
          p: context.palette,
          line: line,
          contentWidth: _contentWidth,
        );
  }

  /// 一次跳转的收尾：复位 `_jumping`，并让正文输入框补一次排版 + 重绘。
  ///
  /// 两件事都必须无条件发生：`_jumping` 若残留，之后滚动时大纲再也不跟随；
  /// 收尾那一帧若画空，没有新帧时屏幕会一直空白到下一次 hover。
  void _settleJump() {
    // 补一帧，顺带保证下面那个 post-frame 一定有帧可挂。
    _settleJumpRepaint?.call();
    // 让这次跳转产生的滚动通知先走完再复位，避免大纲被拽到视口首行。
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumping = false);
  }

  /// 跳转到某一行：**瞬时**把滚动位置放到目标，并让输入框立刻补一帧。
  ///
  /// 这里刻意不做动画（Obsidian 的大纲也是瞬到）：动画期间每一帧的可见区间
  /// 都在变，收尾那一帧一旦画空，动画结束就没有新帧了——屏幕会一直空白到
  /// 下一次指针 hover。瞬时跳转只产生一次位置变化、一次重算、一次重绘，
  /// 点击后的第一帧就是最终画面。
  void _jumpToLine(int line, {required TextStyle style, double anchor = 0.2}) {
    if (!_editorScroll.hasClients) return;
    final ScrollPosition pos = _editorScroll.position;
    // The probe already reports scroll-content coordinates (padding and the
    // scrolled title included), so nothing is added here.
    final double contentY = _lineTop(line, style);
    final double target = (contentY - pos.viewportDimension * anchor).clamp(
      0.0,
      pos.maxScrollExtent,
    );
    // The heading that was clicked is the one the outline must keep lit, even
    // though the jump lands it a fifth of the way down and the lines above it
    // are what the viewport now starts on.
    _jumping = true;
    pos.jumpTo(target);
    _settleJump();
  }

  /// 跳转后是否还在收尾（复位前的那一帧）；测试用。
  @visibleForTesting
  bool get jumping => _jumping;

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
    _jumpToLine(target, style: style, anchor: 0.12);
  }

  /// Used by the far-right outline region, which lives outside this pane and so
  /// cannot hand over the current prose style.
  void goToHeading(int line) {
    final SettingsController settings = context.read<SettingsController>();
    _goToHeading(line, editorProseStyle(context.palette, settings.proseSize));
  }

  /// Used by the table tools' index: parks the caret on [offset] and scrolls
  /// that line into view. Moving the caret is the whole point — it is also what
  /// makes the panel switch from the file's table list to that table's tools.
  void goToOffset(int offset) {
    final String text = _body.text;
    final int at = offset.clamp(0, text.length);
    int line = 0;
    for (int i = 0; i < at; i++) {
      if (text.codeUnitAt(i) == 0x0A) line++;
    }
    _body.selection = TextSelection.collapsed(offset: at);
    final SettingsController settings = context.read<SettingsController>();
    _jumpToLine(
      line,
      style: editorProseStyle(context.palette, settings.proseSize),
      anchor: 0.12,
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();
    final SettingsController settings = context.watch<SettingsController>();
    final String? pinned = widget.noteId;
    final Note? note = pinned == null
        ? (notes.draft ?? notes.selectedNote)
        : notes.noteById(pinned);

    if (note == null) return _noSelection(p, notes);

    final DraftConflict? conflict = notes.conflict;

    _bind(note);
    if (_title.text != note.title && !_titleFocus.hasFocus) {
      _title.text = note.title;
    }

    // The task checkboxes drawn by the live renderer write straight back into
    // the draft. 只读的那一格不写回：它显示的不是草稿，是另一篇笔记。
    _body.onExternalChange = widget.readOnly ? null : notes.updateBody;

    return Container(
      color: p.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(p, note, notes, settings),
          if (conflict != null && conflict.noteId == note.id)
            _conflictBar(p, conflict, notes),
          // No formatting ribbon: every action lives in the editor's own
          // right-click menu now, and the shortcuts are unchanged.
          // ⛔ 快捷键只包住正文编辑器：包住整个面板会把标题框的 Ctrl+Z 也
          // 抢去撤销正文，正文里存的是没按标题改过的内容，自动保存再写回
          // 文件就是一次覆盖。标题现在随正文一起滚动，仍由编辑器把它们挡在
          // 字段之外（见 `MarkdownEditor.shortcuts`）。
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return _workspace(p, note, notes, c.maxWidth);
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
          // 分割 / 关掉这一格。放在专注模式左边：它们是「这一格怎么摆」，
          // 专注模式是「整个窗口怎么摆」，越靠右的越关乎全局。
          if (widget.onSplit != null) ...<Widget>[
            AppIconButton(
              icon: LucideIcons.columns2,
              tooltip: '左右分屏',
              size: AppLayout.buttonHeight,
              iconSize: AppIconSize.sm - 2,
              onPressed: () => widget.onSplit!(Axis.horizontal),
            ),
            AppIconButton(
              icon: LucideIcons.rows2,
              tooltip: '上下分屏',
              size: AppLayout.buttonHeight,
              iconSize: AppIconSize.sm - 2,
              onPressed: () => widget.onSplit!(Axis.vertical),
            ),
          ],
          if (widget.onClosePane != null)
            AppIconButton(
              icon: LucideIcons.x,
              tooltip: '关掉这一格',
              size: AppLayout.buttonHeight,
              iconSize: AppIconSize.sm - 2,
              onPressed: widget.onClosePane,
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

  /// The note's H1, scrolled with the document above the first line.
  ///
  /// [MarkdownEditor] already pads the scroll content out to the prose column,
  /// so this adds only the vertical breathing room.
  Widget _titleRow(AppPalette p, Note note, NotesController notes) {
    // H1, as the live renderer draws it: body size scaled by 1.74 with the
    // same tracking and weight (see `_headingStyle` in live_markdown.dart).
    // The title field *is* the note's H1 — there is no separate file-name row.
    final double h1Size = context.read<SettingsController>().proseSize * 1.74;

    return Padding(
      // The bottom padding is the gap the body used to get from its own top
      // padding; the title and the first line still sit 36px apart.
      padding: const EdgeInsets.only(
        top: AppSpace.md,
        bottom: AppSpace.sm + AppSpace.xxl,
      ),
      // ⛔ 标题框的撤销栈也必须随笔记清空：它由同一个控制器跨笔记复用，
      // Ctrl+Z 会把上一份笔记的标题恢复进当前标题，`updateTitle` 随即按旧
      // 标题重命名当前文件，等于拿旧名字覆盖一条文件记录。
      child: KeyedSubtree(
        key: ValueKey<String>('title-${note.id}'),
        child: TextField(
          controller: _title,
          focusNode: _titleFocus,
          // 只读的那一格标题也不许改：改的是另一篇笔记的名字，用户没打算动它。
          onChanged: widget.readOnly ? null : notes.updateTitle,
          readOnly: widget.readOnly,
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
  /// title and the body share this padding: they are the same paragraph as far
  /// as the eye is concerned, and a 20px step between them was the most
  /// visible misalignment in the whole pane.
  double _proseSide(double availableWidth) =>
      math.max(_proseGutter, (availableWidth - AppLayout.proseMaxWidth) / 2);

  Widget _workspace(
    AppPalette p,
    Note note,
    NotesController notes,
    double availableWidth,
  ) {
    // The *field* stays full width, because the padding is what moves the text:
    // constraining the widget instead would leave the gutter beside the column
    // dead to clicks, and "click the paper to start typing" has to keep working
    // everywhere.
    final double side = _proseSide(availableWidth);
    // No top padding: the title is the first thing in the scroll content and
    // brings its own spacing, so it can leave with the text.
    final EdgeInsets padding = EdgeInsets.fromLTRB(side, 0, side, 200);

    // Exactly the width the laid-out text gets, so the few spans that draw a
    // real widget (rules, images) can span the column without overflowing it.
    final double contentWidth = (availableWidth - padding.horizontal).clamp(
      60.0,
      AppLayout.proseMaxWidth,
    );
    _contentWidth = contentWidth;

    // 查询里的 `tag:` 是筛选条件，不是要找的字；色带只跟自由文本走。
    final String needle = widget.showSearchHighlights
        ? NotesController.parseQuery(notes.query).text
        : '';

    return MarkdownEditor(
      controller: _body,
      focusNode: _bodyFocus,
      scrollController: _editorScroll,
      fontSize: context.read<SettingsController>().proseSize,
      padding: padding,
      // Scrolled with the text; the editor keeps every shortcut and pointer
      // handler strictly below it, so the title keeps its own undo stack.
      header: _titleRow(p, note, notes),
      // Given to the editor rather than wrapped around it: only the field may
      // see them. Around the whole editor they would also catch the title's
      // keys — Ctrl+Z there must undo the title, not the body.
      shortcuts: _editorShortcuts(),
      actions: _editorActions(notes),
      // 带上 [_bodyEpoch]：id 相同但正文被外部整段替换时，输入框也要
      // 重建，撤销栈才不会把替换前的正文恢复回来。
      documentId: '${(notes.draft ?? notes.selectedNote)?.id}#$_bodyEpoch',
      // 剪贴板里的截图落在笔记同目录的 `assets/`；渲染时再按同一规则解析回来。
      savePastedImage: notes.saveAsset,
      imageProviderFor: (String source) =>
          imageProviderFor(notes.assetPathFor(source), source),
      // 「查看大图」要知道原图多大，尺寸得从磁盘上那张文件读。
      imagePathFor: (String source) => notes.assetPathFor(source),
      onChanged: widget.readOnly ? null : notes.updateBody,
      readOnly: widget.readOnly,
      onTopLineChanged: _onTopLine,
      onLineTopProbe: (double? Function(int line)? probe) =>
          _lineTopProbe = probe,
      onJumpSettled: (VoidCallback? settle) => _settleJumpRepaint = settle,
      onTagTap: (String tag) {
        notes.toggleTag(tag);
        widget.onOpenSearch?.call();
      },
      // `[[还不存在的标题]]` 不是坏链接：打开即创建，这是双链的写法。
      onWikilinkTap: notes.openOrCreateByTitle,
      // `[标签](https://…)` 交给系统默认浏览器；相对路径不认，留给双链。
      onLinkTap: openExternal,
      searchHighlight: needle.isEmpty
          ? null
          : (needle: needle, caseSensitive: notes.caseSensitive),
      searchHighlightColor: p.accentSoft,
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
