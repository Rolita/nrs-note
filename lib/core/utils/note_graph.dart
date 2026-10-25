import '../../data/models/note.dart';
import 'inline_syntax.dart';

/// 关系图谱的一个节点 = 一篇笔记。
///
/// 边用**下标**存（不是 id、不是对象），因为物理层每帧都要按边遍历几十上百次，
/// 下标是唯一不用查 Map 的表示。
class GraphNode {
  GraphNode({
    required this.index,
    required this.id,
    required this.title,
    required this.folder,
    required this.tags,
  });

  /// 在本图 `nodes` 里的下标。
  final int index;

  /// `Note.id`。双击跳转直接用它，所以图谱不关心标题是否重名。
  final String id;

  final String title;

  /// **顶层**文件夹（`a/b/c` → `a`），`''` 表示根目录。分组配色按它来，
  /// 用顶层而不是完整路径，否则嵌套两层就会在图上炸出十几种颜色。
  final String folder;

  final List<String> tags;

  /// 出链数 / 入链数。同一篇里重复写 `[[A]]` 只算一次——否则一句话重复五遍
  /// 就能把节点撑大，那是误导读图的人。
  int outDegree = 0;
  int inDegree = 0;

  /// **全局**无向度（去重后的邻居数）。半径按它算，这样切到局部图谱、拖深度
  /// 滑块时节点不会忽大忽小。
  int globalDegree = 0;

  /// 本图内的邻居下标。子图里只包含子图内部的邻居，BFS 和高亮都读它。
  final List<int> neighbours = <int>[];

  /// 本图内的连接数（局部图谱里会小于 [globalDegree]）。
  int get degree => neighbours.length;

  /// 一条边都没有——「孤立笔记」筛选看的就是这个。
  bool get isOrphan => globalDegree == 0;

  @override
  String toString() => 'GraphNode($index, $title)';
}

/// 一条无向边，`a < b` 恒成立。
///
/// `a < b` 只是为了去重和物理层好写，**和链接方向无关**：正文里真正写下的
/// 那一头在 [from]/[to] 里。图谱按「起点亮、终点暗」画光带，靠的就是它。
class GraphEdge {
  const GraphEdge(this.a, this.b, {this.from, this.to});

  final int a;
  final int b;

  /// 这条线的方向：正文里写 `[[目标]]` 的那一篇是 [from]，被指向的是 [to]。
  ///
  /// 互相链接（A→B 且 B→A）时两者都是 `null`——两个方向都成立，
  /// 画任何一个都是在撒谎，所以干脆不画方向。
  final int? from;
  final int? to;

  /// 双向边：不画箭头，也不跑光点。
  bool get isBidirectional => from == null || to == null;

  /// 抹掉方向（发现反向链接时用）。
  GraphEdge undirected() => GraphEdge(a, b);
}

/// 从整个 vault 抽出来的链接结构。
///
/// 纯数据 + 纯函数，不碰 widget：单测可以直接构造 [Note] 列表断言，不用起
/// 一个应用。
class NoteGraph {
  NoteGraph._(this.nodes, this.edges, this._byId);

  /// 空图。库里一篇笔记都没有时用它，调用处不用再判空。
  NoteGraph.empty() : nodes = const <GraphNode>[], edges = const <GraphEdge>[], _byId = const <String, int>{};

  final List<GraphNode> nodes;
  final List<GraphEdge> edges;

  /// `Note.id` → 下标。子图里只包含子图内的笔记。
  final Map<String, int> _byId;

  bool get isEmpty => nodes.isEmpty;

  bool get isNotEmpty => nodes.isNotEmpty;

  /// 标题归一：去首尾空格 + 转小写。
  ///
  /// 与 `NotesController.openOrCreateByTitle` 用的是同一条规则，改这里就要一起
  /// 改那边，否则「图上连着」和「点了跳不过去」会分家。
  static String key(String title) => title.trim().toLowerCase();

  int get orphanCount => nodes.where((GraphNode n) => n.isOrphan).length;

  /// 按 `id` 找节点下标；不在本图里返回 `null`。
  int? indexOfId(String? id) => id == null ? null : _byId[id];

  /// 以 [from] 为心，[depth] 跳以内的所有节点下标（含自己）。
  ///
  /// 深度滑块的唯一实现。`depth <= 0` 时只剩自己。
  Set<int> neighbourhood(int from, int depth) {
    final Set<int> keep = <int>{from};
    List<int> frontier = <int>[from];
    for (int d = 0; d < depth && frontier.isNotEmpty; d++) {
      final List<int> next = <int>[];
      for (final int i in frontier) {
        for (final int j in nodes[i].neighbours) {
          if (keep.add(j)) next.add(j);
        }
      }
      frontier = next;
    }
    return keep;
  }

  /// 只保留 [keep] 里的节点，重新编号。
  ///
  /// 全局图建一次就够，局部图谱靠这个方法切片——比每次重扫正文便宜得多。
  /// 出/入链与 [GraphNode.globalDegree] 原样带过来（它们是笔记自身的属性），
  /// 只有 [GraphNode.neighbours] 换成子图内的邻居。
  NoteGraph subgraph(Set<int> keep) {
    if (keep.length == nodes.length) return this;
    final List<int> order = <int>[];
    for (int i = 0; i < nodes.length; i++) {
      if (keep.contains(i)) order.add(i);
    }
    final Map<int, int> remap = <int, int>{};
    final List<GraphNode> sub = <GraphNode>[];
    for (int k = 0; k < order.length; k++) {
      final GraphNode src = nodes[order[k]];
      remap[order[k]] = k;
      sub.add(
        GraphNode(
          index: k,
          id: src.id,
          title: src.title,
          folder: src.folder,
          tags: src.tags,
        )
          ..outDegree = src.outDegree
          ..inDegree = src.inDegree
          ..globalDegree = src.globalDegree,
      );
    }
    final List<GraphEdge> subEdges = <GraphEdge>[];
    for (final GraphEdge e in edges) {
      final int? a = remap[e.a];
      final int? b = remap[e.b];
      if (a == null || b == null) continue;
      subEdges.add(
        GraphEdge(
          a,
          b,
          from: e.from == null ? null : remap[e.from],
          to: e.to == null ? null : remap[e.to],
        ),
      );
      sub[a].neighbours.add(b);
      sub[b].neighbours.add(a);
    }
    final Map<String, int> byId = <String, int>{};
    for (final GraphNode n in sub) {
      byId[n.id] = n.index;
    }
    return NoteGraph._(sub, subEdges, byId);
  }

  @override
  String toString() => 'NoteGraph(${nodes.length} nodes, ${edges.length} edges)';
}

/// 扫全库，抽出所有 `[[双链]]`。
///
/// ## 三条硬规则
///
/// 1. **同一个扫描器**：只用 [wikilinkRuns]，它和正文渲染、点击命中是同一个
///    正则。所以反引号和代码块里的 `[[x]]` 天然不算——不会出现「正文里没画成
///    链接，图谱里却有一条边」。
/// 2. **排除嵌入**：`![[图片.png]]` 连的是一张图，不是一篇笔记。
/// 3. **目标解析与点击一致**：用 [NoteGraph.key] 全等匹配、**先出现的赢**，
///    与 `NotesController.openOrCreateByTitle` 完全同一条规则。这样「图上这条
///    边」和「点一下会跳到哪」永远是同一件事。
///
/// 死链（目标不存在）不产生边也不产生节点：图谱表示已经存在的结构，
/// 一堆幽灵节点会把真实结构淹掉。自环（`[[自己]]`）同理丢弃。
NoteGraph buildNoteGraph(List<Note> notes) {
  if (notes.isEmpty) return NoteGraph.empty();

  final List<GraphNode> nodes = <GraphNode>[];
  final Map<String, int> byTitle = <String, int>{};
  final Map<String, int> byId = <String, int>{};
  for (int i = 0; i < notes.length; i++) {
    final Note note = notes[i];
    nodes.add(
      GraphNode(
        index: i,
        id: note.id,
        title: note.title,
        folder: topFolder(note.folderPath),
        tags: note.tags,
      ),
    );
    // 同名标题取先出现的那篇——`putIfAbsent` 就是「先到先得」。
    byTitle.putIfAbsent(NoteGraph.key(note.title), () => i);
    byId.putIfAbsent(note.id, () => i);
  }

  final Map<int, int> drawn = <int, int>{};
  final List<GraphEdge> edges = <GraphEdge>[];
  for (int i = 0; i < notes.length; i++) {
    final Set<int> targets = <int>{};
    for (final String raw in _linkTargets(notes[i].body)) {
      final int? j = byTitle[NoteGraph.key(raw)];
      if (j == null || j == i) continue;
      // 同一篇里重复 [[A]] 三次：度数只加一次。
      if (!targets.add(j)) continue;
      nodes[i].outDegree++;
      nodes[j].inDegree++;
      final int lo = i < j ? i : j;
      final int hi = i < j ? j : i;
      // A→B 与 B→A 同时存在时只画一条线，但上面的出/入链各算各的。
      final int key = lo * nodes.length + hi;
      final int? seen = drawn[key];
      if (seen != null) {
        // 反向链接也出现了：这条线是双向的，方向抹掉。
        edges[seen] = edges[seen].undirected();
        continue;
      }
      drawn[key] = edges.length;
      // 方向记成 `i → j`：正文里写链接的那一篇是起点。
      edges.add(GraphEdge(lo, hi, from: i, to: j));
      nodes[lo].neighbours.add(hi);
      nodes[hi].neighbours.add(lo);
    }
  }

  for (final GraphNode n in nodes) {
    n.globalDegree = n.neighbours.length;
  }
  return NoteGraph._(nodes, edges, byId);
}

/// 顶层文件夹名。`a/b/c` → `a`，空路径 → `''`。
String topFolder(String folderPath) {
  final String path = folderPath.trim();
  if (path.isEmpty) return '';
  final int slash = path.indexOf('/');
  return slash < 0 ? path : path.substring(0, slash);
}

/// 正文里的链接目标，按出现顺序。
///
/// 逐行扫（`[[` 不跨行），跳过两类：
///
/// * `![[...]]` —— 图片/附件嵌入，连的不是笔记；
/// * 围栏代码块里的行 —— 用 [fenceLinePattern] 判定，和块层切代码块卡片是同
///   一条规则。翻转到「在围栏里」只翻状态、不配字符，因为渲染层也是这么做的：
///   两边对「哪一段是代码」必须给出同一个答案。
Iterable<String> _linkTargets(String body) sync* {
  if (!body.contains('[[')) return;
  bool fenced = false;
  int start = 0;
  while (start <= body.length) {
    final int newline = body.indexOf('\n', start);
    final int end = newline < 0 ? body.length : newline;
    final String line = body.substring(start, end);
    if (fenceLinePattern.hasMatch(line)) {
      fenced = !fenced;
    } else if (!fenced) {
      for (final ({int start, int end, String target, bool embed}) run
          in wikilinkRuns(line)) {
        if (run.embed) continue;
        yield run.target;
      }
    }
    if (newline < 0) break;
    start = newline + 1;
  }
}
