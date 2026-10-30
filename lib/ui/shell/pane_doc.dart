import 'main_view.dart';

/// 一个编辑区格子里装的东西。
///
/// 以前「主区显示什么」是外壳上的一个枚举（[MainView]），全窗口只有一份；
/// 分块之后每格各有一份，所以它变成了叶子里的值，而不是窗口的状态。
///
/// 四种都进格子：笔记、图谱、白板、图片。后三者的视口 / 相机 / 物理状态
/// 活在 widget 的 State 里，所以它们从一格搬到另一格、或者暂时没有格子
/// 装着的时候，靠 `GlobalKey` 在树上换位置把 State 带走（见 `app_shell`
/// 的停靠区）。⛔ 别改成「没格子就重建」——白板的视角、图谱的相机一转就没了。
sealed class PaneDoc {
  const PaneDoc();

  MainView get view;

  /// 同一种文档的身份。
  ///
  /// 笔记按 id 分（`NoteDoc(null)` 是「跟着选中走」的那一份，单独一个身份）；
  /// 其余三种全局只有一份，所以身份是个常量——树里最多只能有一个。
  String get identity;

  /// 树里最多只能有一份。笔记之外都算。
  bool get isSingleton => this is! NoteDoc;

  /// 相等性就是身份。
  ///
  /// 标签组（`TabGroup`）按 `==` 认「这一页是不是已经开着」，所以
  /// `NoteDoc('a')` 必须等于另一个 `NoteDoc('a')`——它们指同一篇笔记。
  @override
  bool operator ==(Object other) =>
      other is PaneDoc && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;
}

/// 一篇笔记。[noteId] 为 null 表示「跟着全局选中走」——聚焦的那一格用这个，
/// 它才绑得住草稿、自动保存和撤销栈。
final class NoteDoc extends PaneDoc {
  const NoteDoc(this.noteId);

  final String? noteId;

  bool get isLive => noteId == null;

  @override
  MainView get view => MainView.note;

  @override
  String get identity => 'note:${noteId ?? '*'}';
}

final class GraphDoc extends PaneDoc {
  const GraphDoc();

  @override
  MainView get view => MainView.graph;

  @override
  String get identity => 'graph';
}

final class CanvasDoc extends PaneDoc {
  const CanvasDoc();

  @override
  MainView get view => MainView.canvas;

  @override
  String get identity => 'canvas';
}

/// 图片页。**所有图片共用同一页**，所以它不带路径——正在看哪张由外壳的
/// `_imagePath` 说了算，从文件树点第二张只是换那一页的内容。
final class ImageDoc extends PaneDoc {
  const ImageDoc();

  @override
  MainView get view => MainView.image;

  @override
  String get identity => 'image';
}
