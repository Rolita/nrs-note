import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_tokens.dart';
import '../../data/models/note.dart';
import '../../state/notes_controller.dart';
import '../../state/settings_controller.dart';
import '../../templates/template_service.dart';
import '../common/app_widgets.dart';
import 'template_dialog_frame.dart';

/// 模板库上能做的五件事。由页面抛给外壳，外壳负责真正去做。
enum TemplatePickerAction {
  /// Render into the open note at the caret / selection.
  insert,

  /// Create a blank note in the current folder and render into it.
  newNote,

  /// Bring the templates folder into view in the file tree.
  openFolder,

  /// Create a blank note inside the templates folder.
  newTemplate,

  /// Close the picker and open the selected template in the editor.
  edit,
}

/// 模板库，编辑区里的一页。
///
/// 以前是 `showTemplatePicker` 弹窗：插一次模板开一次、关一次。现在它是一页，
/// 可以一直摆在旁边（甚至分屏和正文并排），插完还留在原处。
///
/// 它自己从 provider 里读笔记库和模板目录：新建 / 改名 / 删掉一个模板，这一页
/// 立刻跟上。⛔ 别改成让外壳把清单传进来——外壳只在错误横幅变化时重建，传进
/// 来的清单会一直是旧的。
///
/// [templates] / [templatesFolder] / [canInsert] 只在测试里给：给了就用给的
/// 那一份，不去读 provider。
class TemplatesPage extends StatefulWidget {
  const TemplatesPage({
    super.key,
    required this.onAction,
    required this.onClose,
    this.templates,
    this.templatesFolder,
    this.canInsert,
  });

  /// 插入 / 新建 / 打开模板目录 / 新建模板 / 去编辑这一份。
  final void Function(TemplatePickerAction action, Note? template) onAction;

  /// 关掉这一页（Esc；× 在标签条上）。
  final VoidCallback onClose;

  /// 测试用的固定清单；null = 从 provider 里现算。
  final List<Note>? templates;
  final String? templatesFolder;
  final bool? canInsert;

  @override
  State<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends State<TemplatesPage> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'template-search');
  final FocusNode _pageFocus = FocusNode(debugLabel: 'templates-page');
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  int _selected = 0;

  /// 这一帧看到的模板清单 / 目录 / 能不能插入。
  ///
  /// 在 `build` 里刷新、存在字段上：`_move` / `_insert` 是在 build 之外跑的，
  /// 那时候再去 `context.watch` 会被框架拦下来。
  List<Note> _templates = const <Note>[];
  String _folder = '';
  bool _canInsert = false;

  @override
  void initState() {
    super.initState();
    // 这一页开在编辑区里，而外壳切到非正文页时会把焦点收回自己（见
    // `AppShell._afterPaneSwitch`）。那一下发生在挂载之前，于是 `autofocus`
    // 被判成「这个作用域里已经有焦点」，白写：↑↓ / Enter / Esc 一个都收不到。
    // 挂载完再要一次，让这一页自己握住键盘。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _pageFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _pageFocus.dispose();
    super.dispose();
  }

  List<Note> get _results {
    final String q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _templates;
    return <Note>[
      for (final Note note in _templates)
        if (note.title.toLowerCase().contains(q) ||
            note.relativePath.toLowerCase().contains(q))
          note,
    ];
  }

  int get _selectedIndex {
    final int count = _results.length;
    if (count == 0) return -1;
    return _selected.clamp(0, count - 1);
  }

  Note? get _selectedTemplate {
    final int index = _selectedIndex;
    return index < 0 ? null : _results[index];
  }

  void _finish(TemplatePickerAction action, [Note? template]) {
    widget.onAction(action, template);
  }

  void _move(int delta) {
    final int count = _results.length;
    if (count == 0) return;
    final int next = (_selectedIndex + delta).clamp(0, count - 1);
    if (next == _selectedIndex) return;
    setState(() => _selected = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final BuildContext? row = _rowKeys[_results[next].id]?.currentContext;
      if (row == null) return;
      Scrollable.ensureVisible(
        row,
        duration: AppMotion.fast,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _insert() {
    if (!_canInsert) return;
    final Note? template = _selectedTemplate;
    if (template == null) return;
    _finish(TemplatePickerAction.insert, template);
  }

  void _newNote() {
    final Note? template = _selectedTemplate;
    if (template == null) return;
    _finish(TemplatePickerAction.newNote, template);
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    // 清单在这里现取：给了就用给的（测试），没给就看库——新建一个模板笔记，
    // 这一页下一帧就跟上了。
    final List<Note>? given = widget.templates;
    if (given != null) {
      _templates = given;
      _folder = widget.templatesFolder ?? '';
      _canInsert = widget.canInsert ?? true;
    } else {
      final NotesController notes = context.watch<NotesController>();
      final SettingsController settings = context.watch<SettingsController>();
      _folder = settings.templatesFolder;
      _templates = const TemplateService().discoverTemplates(
        notes.allNotes,
        _folder,
      );
      _canInsert = notes.selectedNote != null;
    }
    final List<Note> results = _results;
    final Note? selected = _selectedTemplate;
    final bool hasTemplates = _templates.isNotEmpty;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _insert,
        const SingleActivator(LogicalKeyboardKey.enter, control: true):
            _newNote,
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      // 打开时焦点落在这层，而不是搜索框：方向键 / Enter 仍然可用，
      // 但输入法不会一进来就接管，搜索要用户自己点进输入框。
      child: Focus(
        focusNode: _pageFocus,
        autofocus: true,
        child: ColoredBox(
          color: p.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: hasTemplates
                    ? _browser(p, results, selected)
                    : _empty(p),
              ),
              Divider(height: 1, color: p.outlineSoft),
              _footer(p, selected),
            ],
          ),
        ),
      ),
    );
  }

  /// 双栏主体：左栏模板库（搜索 + 分组列表），右栏正文预览。
  ///
  /// 模板是「先看内容再决定插不插」的东西，标题和路径不足以判断，所以把
  /// 正文放在与列表同一屏里，而不是再点开一层。
  Widget _browser(AppPalette p, List<Note> results, Note? selected) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(width: 292, child: _library(p, results, selected)),
        Expanded(child: _preview(p, selected)),
      ],
    );
  }

  Widget _library(AppPalette p, List<Note> results, Note? selected) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: p.outlineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: TemplateSearchField(
              controller: _search,
              focusNode: _searchFocus,
              hint: '搜索模板…',
              onChanged: (_) => setState(() => _selected = 0),
              onSubmitted: (_) => _insert(),
            ),
          ),
          Expanded(
            child: results.isEmpty
                ? _noMatches(p)
                : _list(p, results, selected),
          ),
        ],
      ),
    );
  }

  /// 右栏：标题 / 路径 / 修改时间，下面是渲染后的正文，底部是模板代码。
  Widget _preview(AppPalette p, Note? note) {
    if (note == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              LucideIcons.blocks,
              size: AppIconSize.sm,
              color: p.textTertiary,
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              '选择一个模板查看正文',
              style: TextStyle(
                fontSize: AppText.caption,
                color: p.textTertiary,
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
            ),
          ],
        ),
      );
    }

    final String title = note.title.trim().isEmpty ? '未命名' : note.title;
    final List<String> expressions = _expressions(note.body);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 15, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.25,
                        color: p.textPrimary,
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            note.relativePath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: p.textTertiary,
                              fontFamily: AppFonts.mono,
                              fontFamilyFallback: AppFonts.monoFallback,
                            ),
                          ),
                        ),
                        Container(
                          width: 3,
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 7),
                          decoration: BoxDecoration(
                            color: p.textTertiary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Text(
                          _modifiedLabel(note.updatedAt),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: p.textTertiary,
                            fontFamily: AppFonts.mono,
                            fontFamilyFallback: AppFonts.monoFallback,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              AppIconButton(
                icon: LucideIcons.pencil,
                tooltip: '编辑这个模板',
                size: 24,
                iconSize: AppIconSize.xs,
                onPressed: () => _finish(TemplatePickerAction.edit, note),
              ),
            ],
          ),
        ),
        Container(height: 1, color: p.outlineSoft),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
            child: note.body.trim().isEmpty
                ? Text(
                    '这个模板还没有正文。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.6,
                      color: p.textTertiary,
                      fontFamily: AppFonts.ui,
                      fontFamilyFallback: AppFonts.uiFallback,
                    ),
                  )
                : _MarkdownPreview(body: note.body),
          ),
        ),
        if (expressions.isNotEmpty) _variablesStrip(p, expressions),
      ],
    );
  }

  Widget _variablesStrip(AppPalette p, List<String> expressions) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 9, 22, 9),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.outlineSoft)),
      ),
      child: Row(
        children: <Widget>[
          Text('模板代码', style: TextStyle(fontSize: 10.5, color: p.textTertiary)),
          const SizedBox(width: 9),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final String expression in expressions)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          expression,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: p.textSecondary,
                            fontFamily: AppFonts.mono,
                            fontFamilyFallback: AppFonts.monoFallback,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '插入时求值',
            style: TextStyle(fontSize: 10.5, color: p.textTertiary),
          ),
        ],
      ),
    );
  }

  /// 模板里出现过的 `<% … %>` 表达式，按首次出现去重。
  static final RegExp _expression = RegExp(r'<%[\s\S]*?%>');

  List<String> _expressions(String body) {
    final List<String> found = <String>[];
    for (final RegExpMatch match in _expression.allMatches(body)) {
      final String expression = match.group(0)!.replaceAll('\n', ' ').trim();
      if (!found.contains(expression)) found.add(expression);
      if (found.length >= 4) break;
    }
    return found;
  }

  Widget _list(AppPalette p, List<Note> results, Note? selected) {
    final List<({String label, List<Note> notes})> groups = _groups(results);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final ({String label, List<Note> notes}) group
              in groups) ...<Widget>[
            if (group.label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 5),
                child: Text(
                  group.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.55,
                    color: p.textTertiary,
                    fontFamily: AppFonts.ui,
                    fontFamilyFallback: AppFonts.uiFallback,
                  ),
                ),
              ),
            for (final Note note in group.notes)
              _row(p, note, identical(note, selected)),
          ],
        ],
      ),
    );
  }

  /// Groups templates by their folder *inside* the templates folder. Root
  /// templates come first; the rest follow by path, matching discovery order.
  List<({String label, List<Note> notes})> _groups(List<Note> notes) {
    final String root = Note.normalizeFolderPath(_folder);
    final String lowerRoot = root.toLowerCase();
    final Map<String, List<Note>> grouped = <String, List<Note>>{};
    for (final Note note in notes) {
      String sub = Note.normalizeFolderPath(note.folderPath);
      final String lower = sub.toLowerCase();
      if (lower == lowerRoot) {
        sub = '';
      } else if (lower.startsWith('$lowerRoot/')) {
        sub = sub.substring(root.length + 1);
      }
      grouped.putIfAbsent(sub, () => <Note>[]).add(note);
    }
    final List<String> keys = grouped.keys.toList()
      ..sort((String a, String b) {
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return <({String label, List<Note> notes})>[
      for (final String key in keys) (label: key, notes: grouped[key]!),
    ];
  }

  Widget _row(AppPalette p, Note note, bool selected) {
    final GlobalKey key = _rowKeys.putIfAbsent(note.id, () => GlobalKey());
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (BuildContext context, bool hovered) {
        return GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final int index = _results.indexWhere((Note n) => n.id == note.id);
            if (index >= 0) setState(() => _selected = index);
          },
          onDoubleTap: _insert,
          child: SizedBox(
            height: 44,
            child: Stack(
              children: <Widget>[
                AnimatedContainer(
                  duration: AppMotion.fast,
                  decoration: BoxDecoration(
                    color: selected
                        ? p.accentSoft
                        : (hovered
                              ? p.accent.withValues(alpha: 0.05)
                              : Colors.transparent),
                    borderRadius: AppRadius.mdAll,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              note.title.trim().isEmpty ? '未命名' : note.title,
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
                              _modifiedLabel(note.updatedAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: p.textTertiary,
                                fontFamily: AppFonts.mono,
                                fontFamilyFallback: AppFonts.monoFallback,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selected) ...<Widget>[
                        const SizedBox(width: AppSpace.sm),
                        _Kbd('Enter'),
                      ],
                    ],
                  ),
                ),
                if (selected)
                  Positioned(
                    left: 0,
                    top: 9,
                    bottom: 9,
                    width: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _empty(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              LucideIcons.blocks,
              size: AppIconSize.lg,
              color: p.textTertiary,
            ),
            const SizedBox(height: 10),
            Text(
              '还没有模板',
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
              '在「$_folder」文件夹里放任意 Markdown 笔记，它就会出现在这里。模板也是普通笔记，可以直接编辑。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.6,
                color: p.textTertiary,
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                TemplateDialogButton(
                  label: '打开模板文件夹',
                  icon: LucideIcons.folderOpen,
                  onPressed: () => _finish(TemplatePickerAction.openFolder),
                ),
                const SizedBox(width: AppSpace.sm),
                TemplateDialogButton(
                  label: '新建模板',
                  icon: LucideIcons.filePlus2,
                  onPressed: () => _finish(TemplatePickerAction.newTemplate),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _noMatches(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(LucideIcons.searchX, size: 19, color: p.textTertiary),
            const SizedBox(height: 8),
            Text(
              '没有找到模板',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: p.textSecondary,
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '没有标题或路径包含「${_search.text.trim()}」。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: p.textTertiary,
                fontFamily: AppFonts.ui,
                fontFamilyFallback: AppFonts.uiFallback,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(AppPalette p, Note? selected) {
    final bool canAct = selected != null;
    return Row(
      children: <Widget>[
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            // The hints are one quiet line; when the buttons leave them less
            // room than they need (wide glyphs, larger text), shrink rather
            // than paint an overflow stripe.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _Kbd('↑'),
                  _Kbd('↓'),
                  const SizedBox(width: 5),
                  Text(
                    '选择',
                    style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  _Kbd('Enter'),
                  const SizedBox(width: 5),
                  Text(
                    '插入',
                    style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  _Kbd('Ctrl+Enter'),
                  const SizedBox(width: 5),
                  Text(
                    '新建',
                    style: TextStyle(fontSize: 10.5, color: p.textTertiary),
                  ),
                ],
              ),
            ),
          ),
        ),
        TemplateDialogButton(
          label: '打开文件夹',
          icon: LucideIcons.folderOpen,
          onPressed: () => _finish(TemplatePickerAction.openFolder),
        ),
        const SizedBox(width: AppSpace.sm),
        TemplateDialogButton(
          label: '新建笔记',
          icon: LucideIcons.filePlus2,
          onPressed: canAct ? _newNote : null,
        ),
        const SizedBox(width: AppSpace.sm),
        TemplateDialogButton(
          label: '插入到当前笔记',
          icon: LucideIcons.cornerDownLeft,
          primary: true,
          autofocus: false,
          onPressed: _canInsert && canAct ? _insert : null,
        ),
      ],
    );
  }
}

/// 模板选择器里的只读正文预览。
///
/// 选择模板时真正要判断的是「正文长什么样」。编辑器那套按行排版引擎服务于
/// 光标、选区和输入法，搬进预览属于过度设计；这里只按块解析预览需要的几类
/// 内容：标题、段落、列表、任务、引用、代码块与分隔线。
class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({required this.body});

  final String body;

  static final RegExp _heading = RegExp(r'^(#{1,6})\s+(.*)$');
  static final RegExp _rule = RegExp(r'^(-{3,}|\*{3,}|_{3,})$');
  static final RegExp _item = RegExp(r'^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$');
  static final RegExp _task = RegExp(r'^\[([ xX])\]\s*(.*)$');
  static final RegExp _tagAt = RegExp(
    r'^#([A-Za-z0-9_\u4e00-\u9fff][A-Za-z0-9_\u4e00-\u9fff\-/\.]*)',
  );
  static final RegExp _tagBoundary = RegExp(r'[\s([{>（【「]');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _blocks(context.palette),
    );
  }

  List<Widget> _blocks(AppPalette p) {
    final List<String> lines = body
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final List<Widget> blocks = <Widget>[];
    bool first = true;

    void add(Widget child, {double top = 6, double bottom = 0}) {
      blocks.add(
        Padding(
          padding: EdgeInsets.only(top: first ? 0 : top, bottom: bottom),
          child: child,
        ),
      );
      first = false;
    }

    int i = 0;
    while (i < lines.length) {
      final String line = lines[i];
      final String trimmed = line.trim();
      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // 代码围栏：内部原样输出，不再解析。
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        final String fence = trimmed.substring(0, 3);
        final List<String> code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trimRight().startsWith(fence)) {
          code.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        add(_codeBlock(p, code.join('\n')), top: 8, bottom: 2);
        continue;
      }

      final RegExpMatch? heading = _heading.firstMatch(line);
      if (heading != null) {
        final int level = heading.group(1)!.length;
        add(
          _rich(p, heading.group(2)!.trim(), _headingStyle(p, level)),
          top: level <= 2 ? 16 : 12,
          bottom: 2,
        );
        i++;
        continue;
      }

      if (_rule.hasMatch(trimmed)) {
        add(Container(height: 1, color: p.rule), top: 12, bottom: 4);
        i++;
        continue;
      }

      if (trimmed.startsWith('>')) {
        final List<String> quote = <String>[];
        while (i < lines.length && lines[i].trimLeft().startsWith('>')) {
          quote.add(lines[i].trimLeft().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        add(_quote(p, quote.join('\n')), top: 8, bottom: 2);
        continue;
      }

      if (_item.hasMatch(line)) {
        final List<Widget> items = <Widget>[];
        while (i < lines.length) {
          final RegExpMatch? item = _item.firstMatch(lines[i]);
          if (item == null) break;
          items.add(_listItem(p, item));
          i++;
        }
        add(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: items),
          top: 5,
        );
        continue;
      }

      final List<String> paragraph = <String>[];
      while (i < lines.length) {
        final String current = lines[i];
        final String t = current.trim();
        if (t.isEmpty || _startsBlock(current)) break;
        paragraph.add(t);
        i++;
      }
      if (paragraph.isEmpty) {
        i++;
        continue;
      }
      add(_rich(p, paragraph.join('\n'), _bodyStyle(p)), top: 6, bottom: 1);
    }
    return blocks;
  }

  bool _startsBlock(String line) {
    final String trimmed = line.trim();
    return trimmed.startsWith('```') ||
        trimmed.startsWith('~~~') ||
        _heading.hasMatch(line) ||
        _rule.hasMatch(trimmed) ||
        trimmed.startsWith('>') ||
        _item.hasMatch(line);
  }

  TextStyle _bodyStyle(AppPalette p) => TextStyle(
    fontSize: 12.5,
    height: 1.72,
    color: p.textSecondary,
    fontFamily: AppFonts.ui,
    fontFamilyFallback: AppFonts.uiFallback,
  );

  TextStyle _headingStyle(AppPalette p, int level) {
    final double size = switch (level) {
      1 => 19,
      2 => 14.5,
      3 => 13,
      _ => 12.5,
    };
    return TextStyle(
      fontSize: size,
      height: level == 1 ? 1.35 : 1.45,
      fontWeight: FontWeight.w600,
      letterSpacing: level == 1 ? -0.25 : 0,
      color: p.textPrimary,
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
    );
  }

  Widget _rich(AppPalette p, String text, TextStyle style) {
    return Text.rich(TextSpan(style: style, children: _inline(p, text, style)));
  }

  Widget _codeBlock(AppPalette p, String code) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
      decoration: BoxDecoration(
        color: p.surfaceSunken,
        borderRadius: AppRadius.smAll,
        border: Border.all(color: p.outlineSoft),
      ),
      child: Text(
        code,
        style: TextStyle(
          fontSize: 11,
          height: 1.55,
          color: p.textSecondary,
          fontFamily: AppFonts.mono,
          fontFamilyFallback: AppFonts.monoFallback,
        ),
      ),
    );
  }

  Widget _quote(AppPalette p, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(left: 11, top: 1, bottom: 1),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: p.accent, width: 2)),
      ),
      child: _rich(p, text, _bodyStyle(p).copyWith(height: 1.65)),
    );
  }

  Widget _listItem(AppPalette p, RegExpMatch match) {
    final String indent = (match.group(1) ?? '').replaceAll('\t', '    ');
    final int depth = indent.length ~/ 2;
    final String marker = match.group(2)!;
    String text = match.group(3)!;
    final bool ordered = RegExp(r'\d').hasMatch(marker);

    final RegExpMatch? task = _task.firstMatch(text);
    final bool checked = task != null && task.group(1)!.toLowerCase() == 'x';
    if (task != null) text = task.group(2)!;

    final Widget markerWidget;
    if (task != null) {
      markerWidget = Container(
        width: 11,
        height: 11,
        decoration: BoxDecoration(
          color: checked ? p.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: checked ? p.accent : p.rule),
        ),
        child: checked
            ? Icon(
                LucideIcons.check,
                size: 8,
                color: AppPalette.readableOn(p.accent),
              )
            : null,
      );
    } else if (ordered) {
      markerWidget = Text(
        marker,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.72,
          color: p.textTertiary,
          fontFamily: AppFonts.mono,
          fontFamilyFallback: AppFonts.monoFallback,
        ),
      );
    } else {
      markerWidget = Text(
        '•',
        style: TextStyle(fontSize: 12.5, height: 1.72, color: p.textTertiary),
      );
    }

    final TextStyle style = _bodyStyle(p).copyWith(
      color: checked ? p.textTertiary : p.textSecondary,
      decoration: checked ? TextDecoration.lineThrough : null,
    );

    return Padding(
      padding: EdgeInsets.only(left: depth * 16.0, top: 1, bottom: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 22,
            height: 12.5 * 1.72,
            child: Align(alignment: Alignment.centerLeft, child: markerWidget),
          ),
          Expanded(child: _rich(p, text, style)),
        ],
      ),
    );
  }

  List<InlineSpan> _inline(AppPalette p, String text, TextStyle base) {
    final List<InlineSpan> spans = <InlineSpan>[];
    final StringBuffer buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString()));
      buffer.clear();
    }

    int i = 0;
    while (i < text.length) {
      final String ch = text[i];

      if (ch == '`') {
        final int close = text.indexOf('`', i + 1);
        if (close > i + 1) {
          flush();
          spans.add(
            TextSpan(
              text: text.substring(i + 1, close),
              style: base.copyWith(
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                fontSize: (base.fontSize ?? 12.5) - 1,
                color: p.textPrimary,
                backgroundColor: p.surfaceSunken,
              ),
            ),
          );
          i = close + 1;
          continue;
        }
      }

      if (text.startsWith('<%', i)) {
        final int close = text.indexOf('%>', i + 2);
        if (close >= 0) {
          flush();
          spans.add(
            TextSpan(
              text: text.substring(i, close + 2),
              style: base.copyWith(
                fontFamily: AppFonts.mono,
                fontFamilyFallback: AppFonts.monoFallback,
                fontSize: (base.fontSize ?? 12.5) - 1.5,
                color: p.accent,
              ),
            ),
          );
          i = close + 2;
          continue;
        }
      }

      if (text.startsWith('**', i)) {
        final int close = text.indexOf('**', i + 2);
        if (close > i + 2) {
          flush();
          spans.add(
            TextSpan(
              text: text.substring(i + 2, close),
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                color: p.textPrimary,
              ),
            ),
          );
          i = close + 2;
          continue;
        }
      }

      if (text.startsWith('==', i)) {
        final int close = text.indexOf('==', i + 2);
        if (close > i + 2) {
          flush();
          spans.add(
            TextSpan(
              text: text.substring(i + 2, close),
              style: base.copyWith(
                backgroundColor: p.accentSoft,
                color: p.textPrimary,
              ),
            ),
          );
          i = close + 2;
          continue;
        }
      }

      if ((ch == '*' || ch == '_') &&
          (i == 0 || _tagBoundary.hasMatch(text[i - 1]))) {
        final int close = text.indexOf(ch, i + 1);
        if (close > i + 1) {
          flush();
          spans.add(
            TextSpan(
              text: text.substring(i + 1, close),
              style: base.copyWith(fontStyle: FontStyle.italic),
            ),
          );
          i = close + 1;
          continue;
        }
      }

      if (ch == '#' && (i == 0 || _tagBoundary.hasMatch(text[i - 1]))) {
        final RegExpMatch? tag = _tagAt.firstMatch(text.substring(i));
        if (tag != null) {
          final String name = tag.group(0)!;
          flush();
          spans.add(
            TextSpan(
              text: name,
              style: base.copyWith(color: p.accent),
            ),
          );
          i += name.length;
          continue;
        }
      }

      buffer.write(ch);
      i++;
    }
    flush();
    if (spans.isEmpty) spans.add(TextSpan(text: text));
    return spans;
  }
}

class _Kbd extends StatelessWidget {
  const _Kbd(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppPalette p = context.palette;
    return Container(
      margin: const EdgeInsets.only(right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border.all(color: p.outline),
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9.5,
          height: 1.6,
          color: p.textTertiary,
          fontFamily: AppFonts.mono,
          fontFamilyFallback: AppFonts.monoFallback,
        ),
      ),
    );
  }
}

String _modifiedLabel(DateTime at) {
  final DateTime now = DateTime.now();
  final DateTime local = at.toLocal();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(local.year, local.month, local.day);
  final int days = today.difference(day).inDays;
  String two(int v) => v.toString().padLeft(2, '0');
  if (days == 0) return '今天 ${two(local.hour)}:${two(local.minute)}';
  if (days == 1) return '昨天 ${two(local.hour)}:${two(local.minute)}';
  if (local.year == now.year) return '${local.month}月${local.day}日';
  return '${local.year}年${local.month}月${local.day}日';
}
