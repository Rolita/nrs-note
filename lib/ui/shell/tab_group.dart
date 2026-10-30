import 'package:flutter/foundation.dart';

/// 一格里的标签组：一组标签 + 当前那一页。
///
/// 分块之后「开着哪些东西」不再是窗口上的一份列表，而是**每一格自己的一份**
/// ——顶栏那条统一的标签条因此拆成了每格顶上的一条（用户原话：「顶部的 tab
/// 并不是顶部栏的一部分，其实也是跟着自己的编辑栏的」）。
///
/// 所有方法都是纯函数：改完返回一个新的组，原组不动。树那边（`SplitTree`）
/// 也这么干，两层加起来就是「一次手势 = 一次不可变重写 + 一次 setState」。
///
/// 泛型是为了两处共用：编辑区装 [PaneDoc]，侧边栏装 [SidebarView]。元素按
/// `==` 认身份——[PaneDoc] 的相等性就是它的 `identity`，枚举本来就是值相等。
@immutable
class TabGroup<T> {
  const TabGroup(this.tabs, this.index);

  /// 只有一页的组。
  factory TabGroup.of(T tab) => TabGroup<T>(<T>[tab], 0);

  /// 至少一页。⛔ 别让它空着：空组没有 `current`，而画一格总得画点什么。
  final List<T> tabs;

  /// 当前那一页在 [tabs] 里的下标，永远落在合法范围内。
  final int index;

  T get current => tabs[index];

  int get length => tabs.length;

  bool get hasMany => tabs.length > 1;

  bool contains(T tab) => tabs.contains(tab);

  int indexOf(T tab) => tabs.indexOf(tab);

  TabGroup<T> select(int at) => at == index ? this : TabGroup<T>(tabs, at);

  /// 打开一页：已经开着就切过去，没开着就加在最后。
  TabGroup<T> open(T tab) {
    final int at = indexOf(tab);
    if (at >= 0) return select(at);
    return TabGroup<T>(<T>[...tabs, tab], tabs.length);
  }

  /// 加一页但**不切过去**。
  ///
  /// 用在「文档来了、人还在看别的」上：启动时恢复的那块白板，标签得有，
  /// 但不能把主区从正在写的笔记手里抢走。
  TabGroup<T> appended(T tab) {
    if (contains(tab)) return this;
    return TabGroup<T>(<T>[...tabs, tab], index);
  }

  /// 换掉当前这一页（「把这一格换成别的东西」）。
  TabGroup<T> replaceCurrent(T tab) => replaceAt(index, tab);

  TabGroup<T> replaceAt(int at, T tab) {
    if (tabs[at] == tab) return this;
    final List<T> next = <T>[...tabs]..[at] = tab;
    return TabGroup<T>(next, index);
  }

  /// 关掉第 [at] 页。
  ///
  /// 关到一页不剩时留 [fallback]——容器总得有一格，一格总得有一页。
  TabGroup<T> closeAt(int at, T fallback) {
    if (tabs.length <= 1) return TabGroup<T>(<T>[fallback], 0);
    final List<T> next = <T>[...tabs]..removeAt(at);
    // 关掉的是当前页左边的：当前页整体左移一位。右边的不动。
    final int kept = at < index ? index - 1 : index;
    return TabGroup<T>(next, kept.clamp(0, next.length - 1));
  }

  /// 把某一页摘掉（它被别的格子拿走了）。摘空了就留 [fallback]。
  TabGroup<T> without(T tab, T fallback) {
    final int at = indexOf(tab);
    if (at < 0) return this;
    return closeAt(at, fallback);
  }
}
