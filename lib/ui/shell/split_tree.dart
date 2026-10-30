import 'package:flutter/widgets.dart';

/// 一棵二叉分割树。
///
/// 编辑区和侧边栏共用这一个模型：每次分割只把一个叶子换成「两个叶子 + 一条
/// 分割线」，所以任意叶子的任意一条边都能继续切。网格（行列对齐）做不到这点
/// ——切一刀会牵连整行整列。
///
/// 树是不可变的：所有修改都返回一棵新树。`setState` 里换掉根节点即可，
/// 不需要在节点上挂监听，也不会出现「改了一半」的中间态。
///
/// 泛型 [T] 是叶子装的东西：编辑区装「哪个文档」，侧边栏装「哪个视图」。
/// 这棵树本身不知道 [T] 是什么，也不碰 UI。
@immutable
sealed class SplitNode<T> {
  const SplitNode();
}

/// 一个格子。
@immutable
final class SplitLeaf<T> extends SplitNode<T> {
  const SplitLeaf({required this.id, required this.value});

  /// 稳定标识。重建树时用它认人——按下标认会在分割后全乱。
  final String id;

  final T value;
}

/// 两个格子 + 一条分割线。
@immutable
final class SplitBranch<T> extends SplitNode<T> {
  const SplitBranch({
    required this.id,
    required this.axis,
    required this.ratio,
    required this.first,
    required this.second,
  });

  final String id;

  /// [Axis.horizontal] = 左右并排；[Axis.vertical] = 上下叠放。
  final Axis axis;

  /// [first] 占的比例，0–1。
  final double ratio;

  final SplitNode<T> first;
  final SplitNode<T> second;

  SplitBranch<T> withRatio(double value) => SplitBranch<T>(
    id: id,
    axis: axis,
    ratio: value.clamp(SplitLimits.min, SplitLimits.max),
    first: first,
    second: second,
  );
}

/// 比例的上下限。
///
/// 不是 0 和 1：留一点边，格子永远拖不到「看不见」，也就永远能拖回来。
abstract final class SplitLimits {
  static const double min = 0.12;
  static const double max = 0.88;
}

/// 树的编辑操作。全部是纯函数，返回新树。
abstract final class SplitTree {
  /// 把 [leafId] 那个格子换成「原来的它 + 一个新格子」。
  ///
  /// [before] 为真时新格子排在前面（左 / 上）。找不到 [leafId] 就原样返回。
  static SplitNode<T> split<T>({
    required SplitNode<T> root,
    required String leafId,
    required Axis axis,
    required T value,
    required String newLeafId,
    required String newBranchId,
    bool before = false,
  }) {
    final SplitNode<T>? replaced = _replace<T>(root, leafId, (
      SplitLeaf<T> old,
    ) {
      final SplitLeaf<T> fresh = SplitLeaf<T>(id: newLeafId, value: value);
      return SplitBranch<T>(
        id: newBranchId,
        axis: axis,
        ratio: 0.5,
        first: before ? fresh : old,
        second: before ? old : fresh,
      );
    });
    return replaced ?? root;
  }

  /// 去掉一个格子，让它的兄弟顶上来。
  ///
  /// 只剩一个格子时不删——那是「关掉整个容器」，不属于树的职责。
  static SplitNode<T>? remove<T>(SplitNode<T> root, String leafId) {
    if (root is SplitLeaf<T>) return null;
    final SplitBranch<T> branch = root as SplitBranch<T>;

    if (branch.first is SplitLeaf<T> &&
        (branch.first as SplitLeaf<T>).id == leafId) {
      return branch.second;
    }
    if (branch.second is SplitLeaf<T> &&
        (branch.second as SplitLeaf<T>).id == leafId) {
      return branch.first;
    }

    final SplitNode<T>? first = remove<T>(branch.first, leafId);
    if (first != null) {
      return SplitBranch<T>(
        id: branch.id,
        axis: branch.axis,
        ratio: branch.ratio,
        first: first,
        second: branch.second,
      );
    }
    final SplitNode<T>? second = remove<T>(branch.second, leafId);
    if (second != null) {
      return SplitBranch<T>(
        id: branch.id,
        axis: branch.axis,
        ratio: branch.ratio,
        first: branch.first,
        second: second,
      );
    }
    return null;
  }

  /// 改某条分割线的比例。
  static SplitNode<T> setRatio<T>(
    SplitNode<T> root,
    String branchId,
    double ratio,
  ) {
    if (root is SplitLeaf<T>) return root;
    final SplitBranch<T> branch = root as SplitBranch<T>;
    if (branch.id == branchId) return branch.withRatio(ratio);
    return SplitBranch<T>(
      id: branch.id,
      axis: branch.axis,
      ratio: branch.ratio,
      first: setRatio<T>(branch.first, branchId, ratio),
      second: setRatio<T>(branch.second, branchId, ratio),
    );
  }

  /// 换掉某个叶子的内容，树形不变。
  static SplitNode<T> replaceValue<T>(
    SplitNode<T> root,
    String leafId,
    T value,
  ) {
    if (root is SplitLeaf<T>) {
      return root.id == leafId ? SplitLeaf<T>(id: root.id, value: value) : root;
    }
    final SplitBranch<T> branch = root as SplitBranch<T>;
    return SplitBranch<T>(
      id: branch.id,
      axis: branch.axis,
      ratio: branch.ratio,
      first: replaceValue<T>(branch.first, leafId, value),
      second: replaceValue<T>(branch.second, leafId, value),
    );
  }

  /// 按先序拿所有叶子。
  static List<SplitLeaf<T>> leaves<T>(SplitNode<T> root) {
    final List<SplitLeaf<T>> out = <SplitLeaf<T>>[];
    void walk(SplitNode<T> node) {
      if (node is SplitLeaf<T>) {
        out.add(node);
        return;
      }
      final SplitBranch<T> branch = node as SplitBranch<T>;
      walk(branch.first);
      walk(branch.second);
    }

    walk(root);
    return out;
  }

  /// 贴着容器末端（右边 / 下边）的那几个叶子。
  ///
  /// 用来回答「哪几格的标签条尾巴会被浮在窗口右上角的按钮压住」：左右切分时
  /// 只有右半边贴右边，上下切分时两半都贴右边。
  static List<SplitLeaf<T>> leavesTouchingEnd<T>(
    SplitNode<T> root,
    Axis axis,
  ) {
    final List<SplitLeaf<T>> out = <SplitLeaf<T>>[];
    void walk(SplitNode<T> node) {
      if (node is SplitLeaf<T>) {
        out.add(node);
        return;
      }
      final SplitBranch<T> branch = node as SplitBranch<T>;
      // 沿着 [axis] 切的那一层，第二个孩子才在末端；横着切的那一层两边都在。
      if (branch.axis == axis) {
        walk(branch.second);
      } else {
        walk(branch.first);
        walk(branch.second);
      }
    }

    walk(root);
    return out;
  }

  /// 第一个叶子。容器至少要有内容，用它兜底。
  static SplitLeaf<T> firstLeaf<T>(SplitNode<T> root) {
    SplitNode<T> node = root;
    while (node is SplitBranch<T>) {
      node = node.first;
    }
    return node as SplitLeaf<T>;
  }

  /// 找叶子，找不到返回 null。
  static SplitLeaf<T>? findLeaf<T>(SplitNode<T> root, String leafId) {
    for (final SplitLeaf<T> leaf in leaves<T>(root)) {
      if (leaf.id == leafId) return leaf;
    }
    return null;
  }

  /// 用一次替换把 [leafId] 换成一棵新子树。
  ///
  /// 用回调而不是直接给新节点：分割和删除都要看原来的叶子长什么样，
  /// 在外面先 find 一次再 replace 一次会多走一遍树。
  static SplitNode<T>? _replace<T>(
    SplitNode<T> node,
    String leafId,
    SplitNode<T> Function(SplitLeaf<T> old) swap,
  ) {
    if (node is SplitLeaf<T>) {
      return node.id == leafId ? swap(node) : null;
    }
    final SplitBranch<T> branch = node as SplitBranch<T>;
    final SplitNode<T>? first = _replace<T>(branch.first, leafId, swap);
    if (first != null) {
      return SplitBranch<T>(
        id: branch.id,
        axis: branch.axis,
        ratio: branch.ratio,
        first: first,
        second: branch.second,
      );
    }
    final SplitNode<T>? second = _replace<T>(branch.second, leafId, swap);
    if (second != null) {
      return SplitBranch<T>(
        id: branch.id,
        axis: branch.axis,
        ratio: branch.ratio,
        first: branch.first,
        second: second,
      );
    }
    return null;
  }
}
