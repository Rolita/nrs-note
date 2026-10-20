import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

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
  bool _binding = false;

  TextEditingController get bodyController => _body;

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
    final int line = '\n'.allMatches(text.substring(0, caret)).length;
    // Shared with the action layer, so the readout can never disagree with what
    // the toolbar thinks the caret's line is.
    final int lineStart = lineStartOf(text, caret);
    final int column = caret - lineStart + 1;
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

  void focusEditor() => _bodyFocus.requestFocus();

  void focusTitle() => _titleFocus.requestFocus();

  // ---------------------------------------------------------------- binding

  void _bind(Note note) {
    if (_boundNoteId == note.id) return;
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

  // ------------------------------------------------------------ navigation

  /// Height of the laid-out text above `line`.
  ///
  /// Measured by the renderer itself ([textHeightAbove]) so it carries the
  /// heading line boxes: a heading is not a body row, and treating it as one
  /// used to land a jump short by a margin that grew with every heading above
  /// the target. Wrapped paragraphs come out exact; a wrapped heading and an
  /// inline image stay approximate.
  double _lineTop(int line, TextStyle style) => textHeightAbove(
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

  /// Clicking a `#tag` in the text searches for it.
  ///
  /// The tag becomes a `tag:#name` query rather than a hidden filter, so the
  /// search box shows what is being filtered and the user can keep typing after
  /// it. Switching the sidebar to search is part of the gesture: setting a query
  /// nobody can see, in a panel that is showing the file tree, looks like the
  /// click did nothing.
  void _openTag(String tag) {
    context.read<NotesController>().setQuery('tag:#$tag');
    widget.onOpenSearch?.call();
  }

  /// Follows a `[[wikilink]]`, writing the note when nothing matches its title.
  ///
  /// A link to a note that does not exist yet is the normal way to start one, so
  /// the click creates it and drops you in — with an empty body, ready to type.
  /// Searching for the title instead left the link dead and the name to be
  /// retyped by hand.
  void _openWikilink(String target) {
    if (target.trim().isEmpty) return;
    context.read<NotesController>().openOrCreateByTitle(target);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    final NotesController notes = context.watch<NotesController>();
    final SettingsController settings = context.watch<SettingsController>();
    final Note? note = notes.draft ?? notes.selectedNote;

    if (note == null) return _noSelection(p, notes);

    _bind(note);
    if (_title.text != note.title && !_titleFocus.hasFocus) {
      _title.text = note.title;
    }

    // The task checkboxes, tag pills and wikilinks drawn by the live renderer
    // write straight back into the draft and the filters.
    _body.onExternalChange = notes.updateBody;
    _body.onTagTap = _openTag;
    _body.onWikilinkTap = _openWikilink;

    return Shortcuts(
      shortcuts: _editorShortcuts(),
      child: Container(
        color: p.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(p, note, notes, settings),
            _titleRow(p, notes),
            // No formatting ribbon: every action lives in the editor's own
            // right-click menu now, and the shortcuts are unchanged.
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
            icon: Icons.vertical_align_center_outlined,
            tooltip: '打字机模式',
            active: settings.typewriter,
            onPressed: () => settings.typewriter = !settings.typewriter,
          ),
          AppIconButton(
            icon: Icons.fullscreen_outlined,
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

  Widget _titleRow(AppPalette p, NotesController notes) {
    // H1, as the live renderer draws it: body size scaled by 1.62 with the
    // same tracking and weight (see `_headingStyle` in live_markdown.dart).
    // The title field *is* the note's H1 — there is no separate file-name row.
    final double h1Size = context.read<SettingsController>().proseSize * 1.62;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.md,
        AppSpace.xl,
        AppSpace.sm,
      ),
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
          height: snapLineHeight(h1Size, 1.5),
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
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
            height: snapLineHeight(h1Size, 1.5),
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            color: p.textTertiary.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------- workspace

  Widget _workspace(NotesController notes, double availableWidth) {
    // Exactly the width the laid-out text gets, so the few spans that draw a
    // real widget (rules, images) can span the column without overflowing it.
    final double contentWidth = (availableWidth - _editorPadding.horizontal)
        .clamp(60.0, AppLayout.proseMaxWidth);
    _contentWidth = contentWidth;

    return Actions(
      actions: _editorActions(notes),
      child: MarkdownEditor(
        controller: _body,
        focusNode: _bodyFocus,
        scrollController: _editorScroll,
        fontSize: context.read<SettingsController>().proseSize,
        padding: _editorPadding,
        onChanged: notes.updateBody,
        onTopLineChanged: _onTopLine,
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
      icon: Icons.article_outlined,
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
        child: _MenuTrigger(icon: Icons.format_size_outlined, tooltip: '正文字号'),
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
        _entry(p, 'copy', Icons.content_copy_outlined, '复制 Markdown'),
        _entry(p, 'duplicate', Icons.copy_all_outlined, '创建副本'),
        if (notes.supportsNativeFiles)
          _entry(p, 'reveal', Icons.folder_open_outlined, '打开笔记库文件夹'),
        _entry(p, 'reload', Icons.refresh, '从磁盘重新载入'),
        const PopupMenuDivider(),
        _entry(p, 'delete', Icons.delete_outline, '删除笔记', danger: true),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 2),
        child: _MenuTrigger(icon: Icons.more_horiz_outlined, tooltip: '更多操作'),
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
