/// 白板文件（`.nrs`）的数据模型。
///
/// 这是 NRS 自己的格式，**不是** JSON Canvas：白板是一张自由坐标的场景图，
/// 坐标没有网格、没有取整，节点想放在哪儿就放在哪儿。
///
///   * 所有几何量都是自由浮点。落盘只压到小数点后三位，避免拖动产生
///     `12.300000000000001` 这种噪声把文件搞脏。
///   * 节点数组的顺序就是绘制顺序：靠前的先画（在下面）。
///   * 不认识的字段原样保留：文件可能在别的工具里被改过。
///   * 摄像机（当前看哪儿、缩放多少）**不落盘**。白板文件描述的是内容，
///     不是某个人上一次的视线；打开时按内容自适应。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Rect;

/// 白板文件的后缀。
const String canvasExtension = '.nrs';

/// 当前文件格式版本。读写都从 `version` 字段判断。
const int canvasFormatVersion = 1;

/// 新建卡片的默认尺寸。
///
/// 这是**兜底**用的：文件里缺 `width` / `height` 时才落到这里，也是文件卡片、
/// 链接卡片的宽度。双击新建的文字卡片**没有自己的常量**——它和打完字的卡片
/// 走同一套「贴合内容」，只是空着的时候内容就是那三个点（`canvasEmptyDots`）。
const double canvasDefaultWidth = 250;
const double canvasDefaultHeight = 120;

/// 文字卡片贴合内容时，最多能长到多宽。
///
/// 卡片宽度跟着文字走（空着的时候是一张小卡，写多了自己长），但总得有个头：
/// 一行写三千字，卡片就成了一条贯穿整块板子的线。
const double canvasTextMaxWidth = 420;

/// 卡片能被缩到多小。再小就没法点，也没法把光标放进去。
const double canvasMinSize = 40;

/// 白板文件的格式错误。
///
/// 抛这个异常时**绝对不能覆盖原文件**——用户的东西比我们的解析器重要。
class CanvasFormatException implements Exception {
  CanvasFormatException(this.message);

  final String message;

  @override
  String toString() => 'CanvasFormatException: $message';
}

/// 卡片的四种类型。
enum CanvasNodeType { text, file, link, group }

/// 画布上的一张卡片。
///
/// 字段是**可变**的：拖动、缩放、换色都直接改它，撤销靠 [encodeCanvas] 的
/// 字符串快照，不靠深拷贝。
sealed class CanvasNode {
  CanvasNode({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.color,
    this.groupId,
    double scale = 1,
    Map<String, Object?> extra = const <String, Object?>{},
  }) : _scale = _validScale(scale) ? scale : 1,
       extra = Map<String, Object?>.of(extra);

  /// 唯一 id，16 位小写十六进制。
  final String id;

  double x;
  double y;
  double width;
  double height;

  double _scale;

  /// 内容倍率：**字号**放大缩小的倍数，不是框的尺寸。
  ///
  /// `Ctrl+=` / `Ctrl+-` 改的就是它。文字卡片会把卡片重新贴合到放大后的
  /// 文字上，所以「字变大、卡片跟着变大」是一次操作。
  ///
  /// **没有上下限**（和画布的缩放一样）：想放大到多少就多少，别按 4 倍
  /// 之类的值设墙。只挡 0 / 负数 / NaN——那几个值会让字彻底消失且再也乘
  /// 不回来（0 × 1.25 还是 0）。
  ///
  /// 不写进 JSON 当 1：没调过大小的卡片不该因为这个字段多出一行 diff。
  double get scale => _scale;

  set scale(double value) {
    if (_validScale(value)) _scale = value;
  }

  /// `'1'`–`'6'` 预设色，或 `'#RRGGBB'` / `'#RRGGBBAA'`；`null` = 默认色。
  String? color;

  /// 所属分组的 id。`null` = 不在任何分组里。
  ///
  /// **成员关系是显式的**：只有「打包成框」、`Alt` 点组移入、`Alt` 拖出去
  /// 这几步会改它。画布不再按几何位置自动认领——一张卡落在框里不等于它归
  /// 这个组（§14.35）。
  ///
  /// 分组自己也可以有 `groupId`（嵌套），所以每个节点都带这个字段。
  String? groupId;

  /// 我们不认识的键。**原样保留**，否则用户在别的工具里设的新字段会被吃掉。
  final Map<String, Object?> extra;

  CanvasNodeType get type;

  String get typeName => switch (type) {
    CanvasNodeType.text => 'text',
    CanvasNodeType.file => 'file',
    CanvasNodeType.link => 'link',
    CanvasNodeType.group => 'group',
  };

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  /// 写回 JSON。键顺序固定，因为白板文件会进 git，键序抖动会让每次保存
  /// 都产生整文件 diff。
  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
      'id': id,
      'type': typeName,
      'x': _wireNumber(x),
      'y': _wireNumber(y),
      'width': _wireNumber(width),
      'height': _wireNumber(height),
      if (color != null) 'color': color,
      // 只在属于某个分组时写。不在组里的卡片不该多一行。
      if (groupId != null) 'groupId': groupId,
      // 只在调过大小的时候写。默认 1 不写，免得每张卡都多一行。
      if (scale != 1) 'scale': _wireNumber(scale),
    };
    _writeSpecific(out);
    _writeExtra(out);
    return out;
  }

  /// 子类把自己的专有字段写进去。
  void _writeSpecific(Map<String, Object?> out) {}

  void _writeExtra(Map<String, Object?> out) {
    if (extra.isEmpty) return;
    for (final String key in extra.keys.toList()..sort()) {
      out[key] = extra[key];
    }
  }
}

/// 文字卡片：`text` 是卡片的正文，可以多行。
final class TextNode extends CanvasNode {
  TextNode({
    required super.id,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    this.text = '',
    super.color,
    super.groupId,
    super.scale,
    super.extra,
  });

  String text;

  @override
  CanvasNodeType get type => CanvasNodeType.text;

  @override
  void _writeSpecific(Map<String, Object?> out) => out['text'] = text;
}

/// 文件卡片：引用库里的一篇笔记。
final class FileNode extends CanvasNode {
  FileNode({
    required super.id,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    this.file = '',
    this.subpath,
    this.expanded = false,
    super.color,
    super.groupId,
    super.scale,
    super.extra,
  });

  /// 相对 vault 根的文件路径（正斜杠），和 `Note.relativePath` 同一种写法。
  String file;

  /// 指向笔记里的某个标题或块，以 `#` 开头。
  String? subpath;

  /// 展开着吗。收起 = 只显示标题一行（默认），展开 = 标题下面是被引用
  /// 笔记的正文窗口。只在展开时写进 JSON——没展开过的卡片不该多一行 diff；
  /// 老文件没有这个键就是收起。
  bool expanded;

  @override
  CanvasNodeType get type => CanvasNodeType.file;

  @override
  void _writeSpecific(Map<String, Object?> out) {
    out['file'] = file;
    if (subpath != null) out['subpath'] = subpath;
    if (expanded) out['expanded'] = true;
  }
}

/// 链接卡片：一个外部网址。
final class LinkNode extends CanvasNode {
  LinkNode({
    required super.id,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    this.url = '',
    super.color,
    super.groupId,
    super.scale,
    super.extra,
  });

  String url;

  @override
  CanvasNodeType get type => CanvasNodeType.link;

  @override
  void _writeSpecific(Map<String, Object?> out) => out['url'] = url;
}

/// 分组：一个框住若干卡片的大矩形，可以带标题。
///
/// 分组和卡片一样只有世界坐标，没有「子节点相对坐标」。谁在分组里由成员的
/// [`CanvasNode.groupId`] 显式指回来（见 `canvas_board.dart` 的贴合逻辑）：
/// 一个组的孩子 = `groupId` 等于它的那些节点，分组自己也能有 `groupId`，
/// 嵌套因此天然成立，也不会出现「坐标存了两份、改了一处另一处不对」。
final class GroupNode extends CanvasNode {
  GroupNode({
    required super.id,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    this.label,
    this.autoFit = true,
    super.color,
    super.groupId,
    super.scale,
    super.extra,
  });

  String? label;

  /// 分组的框**始终自动包裹**它的成员（§14.25）。
  ///
  /// 成员移到哪组跟到哪，宽高跟着变。白板里只有这一种框，旧文件里的
  /// `autoFit: false` 读入时也按 true 处理。
  bool autoFit;

  @override
  CanvasNodeType get type => CanvasNodeType.group;

  @override
  void _writeSpecific(Map<String, Object?> out) {
    if (label != null) out['label'] = label;
    if (autoFit) out['autoFit'] = true;
  }
}

/// 一条连线。
class CanvasEdge {
  CanvasEdge({
    required this.id,
    required this.fromNode,
    required this.toNode,
    this.fromSide,
    this.toSide,
    this.fromEnd,
    this.toEnd,
    this.color,
    this.label,
    Map<String, Object?> extra = const <String, Object?>{},
  }) : extra = Map<String, Object?>.of(extra);

  final String id;

  final String fromNode;
  final String toNode;

  /// `top` / `right` / `bottom` / `left`；`null` = 自动选最近的一条边。
  String? fromSide;
  String? toSide;

  /// `none` / `arrow`。
  String? fromEnd;
  String? toEnd;

  String? color;
  String? label;

  final Map<String, Object?> extra;

  /// 起点有没有箭头。缺省 `none`。
  bool get fromIsArrow => fromEnd == 'arrow';

  /// 终点有没有箭头。缺省 **`arrow`**——写反了就会「一条箭头都看不见」。
  bool get toIsArrow => toEnd != 'none';

  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
      'id': id,
      'from': fromNode,
      'to': toNode,
      if (fromSide != null) 'fromSide': fromSide,
      if (toSide != null) 'toSide': toSide,
      if (fromEnd != null) 'fromEnd': fromEnd,
      if (toEnd != null) 'toEnd': toEnd,
      if (color != null) 'color': color,
      if (label != null) 'label': label,
    };
    if (extra.isNotEmpty) {
      for (final String key in extra.keys.toList()..sort()) {
        out[key] = extra[key];
      }
    }
    return out;
  }
}

/// 一个白板文件。
class CanvasDocument {
  CanvasDocument({
    List<CanvasNode>? nodes,
    List<CanvasEdge>? edges,
    Map<String, Object?> extra = const <String, Object?>{},
  }) : nodes = nodes ?? <CanvasNode>[],
       edges = edges ?? <CanvasEdge>[],
       extra = Map<String, Object?>.of(extra);

  /// 顺序即绘制顺序：靠前的在下面。
  final List<CanvasNode> nodes;

  final List<CanvasEdge> edges;

  /// 顶层未知键。
  final Map<String, Object?> extra;

  bool get isEmpty => nodes.isEmpty && edges.isEmpty;

  bool get isNotEmpty => nodes.isNotEmpty || edges.isNotEmpty;

  CanvasNode? nodeById(String id) {
    for (final CanvasNode n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// 连到某个节点上的所有边（出 + 入）。删卡片时要连带删这些。
  List<CanvasEdge> edgesOf(String nodeId) => <CanvasEdge>[
    for (final CanvasEdge e in edges)
      if (e.fromNode == nodeId || e.toNode == nodeId) e,
  ];

  /// [groupId] 这个分组的**直接**成员（含子分组）。
  List<CanvasNode> childrenOf(String groupId) => <CanvasNode>[
    for (final CanvasNode n in nodes)
      if (n.groupId == groupId) n,
  ];

  /// 节点在分组树里的深度：0 = 顶层，1 = 某个组的孩子，依此类推。
  ///
  /// 顺着 `groupId` 往上走；遇到断链（父组不在了）或成环就停，保证
  /// 画布那边永远不会因为一个坏文件转不出来。
  int groupDepthOf(CanvasNode node) {
    int depth = 0;
    final Set<String> seen = <String>{node.id};
    String? parent = node.groupId;
    while (parent != null && seen.add(parent)) {
      final CanvasNode? p = nodeById(parent);
      if (p is! GroupNode) break;
      depth++;
      parent = p.groupId;
    }
    return depth;
  }

  /// [nodeId] 的全部后代 id（子节点、孙节点……），含自己。
  ///
  /// 拖一个分组时要把它带走的东西就是「后代减去自己」。成环的文件也能
  /// 停下来（[seen] 只进不出）。
  Set<String> descendantsOf(String nodeId) {
    final Set<String> out = <String>{nodeId};
    final List<String> queue = <String>[nodeId];
    while (queue.isNotEmpty) {
      final String id = queue.removeLast();
      for (final CanvasNode n in nodes) {
        if (n.groupId != id) continue;
        if (out.add(n.id)) queue.add(n.id);
      }
    }
    return out;
  }

  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
      'version': canvasFormatVersion,
      'nodes': <Object?>[for (final CanvasNode n in nodes) n.toJson()],
      'edges': <Object?>[for (final CanvasEdge e in edges) e.toJson()],
    };
    if (extra.isNotEmpty) {
      for (final String key in extra.keys.toList()..sort()) {
        out[key] = extra[key];
      }
    }
    return out;
  }
}

// ------------------------------------------------------------------ 解析

const Set<String> _knownNodeKeys = <String>{
  'id',
  'type',
  'x',
  'y',
  'width',
  'height',
  'color',
  'groupId',
  'scale',
  'text',
  'file',
  'subpath',
  'expanded',
  'url',
  'label',
  'autoFit',
};

const Set<String> _knownEdgeKeys = <String>{
  'id',
  'from',
  'to',
  'fromSide',
  'toSide',
  'fromEnd',
  'toEnd',
  'color',
  'label',
};

const Set<String> _knownTopKeys = <String>{'version', 'nodes', 'edges'};

const Set<String> _sides = <String>{'top', 'right', 'bottom', 'left'};

final RegExp _hexColor = RegExp(r'^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

/// 读一个白板文件。
///
/// 容错原则：**能救的救，救不了的丢，绝不因为一个坏字段整份文件读不出来**。
/// 只有「根本不是 JSON」才抛 [CanvasFormatException]。
CanvasDocument parseCanvas(String source) {
  Object? raw;
  try {
    raw = jsonDecode(source);
  } on FormatException catch (e) {
    throw CanvasFormatException('不是合法的 JSON：${e.message}');
  }
  if (raw is! Map<String, Object?>) {
    throw CanvasFormatException('顶层不是一个对象');
  }

  final List<CanvasNode> nodes = <CanvasNode>[];
  final Set<String> seenIds = <String>{};
  final Object? rawNodes = raw['nodes'];
  if (rawNodes is List) {
    for (final Object? item in rawNodes) {
      if (item is! Map<String, Object?>) continue;
      final CanvasNode? node = _nodeOf(item);
      // 重复 id 会让连线指向哪一个变得不确定，后来者丢掉。
      if (node == null || !seenIds.add(node.id)) continue;
      nodes.add(node);
    }
  }

  final List<CanvasEdge> edges = <CanvasEdge>[];
  final Set<String> edgeIds = <String>{};
  final Object? rawEdges = raw['edges'];
  if (rawEdges is List) {
    for (final Object? item in rawEdges) {
      if (item is! Map<String, Object?>) continue;
      final CanvasEdge? edge = _edgeOf(item);
      if (edge == null) continue;
      if (edge.fromNode == edge.toNode) continue; // 自环
      if (!seenIds.contains(edge.fromNode)) continue; // 指向不存在的节点
      if (!seenIds.contains(edge.toNode)) continue;
      if (!edgeIds.add(edge.id)) continue;
      edges.add(edge);
    }
  }

  _migrateLegacyGroups(nodes);

  return CanvasDocument(
    nodes: nodes,
    edges: edges,
    extra: <String, Object?>{
      for (final MapEntry<String, Object?> e in raw.entries)
        if (!_knownTopKeys.contains(e.key)) e.key: e.value,
    },
  );
}

/// 旧文件迁移：整份文档一个 `groupId` 都没有时，按几何**一次性**推断归属。
///
/// 老格式没有成员字段，谁在框里靠中心点算。新规则是「显式才归组」，不迁移
/// 的话旧板打开后每个组都是空组，会在第一次编辑时被自动删掉——用户的分组
/// 全没了。所以载入时把几何关系**写死**成 `groupId`，从那以后就只由显式
/// 操作改。
///
/// 推断顺序：面积小的组先认（里层先占住自己的成员），外层的组再认剩下的
/// 节点。子分组按**左上角**在不在框内算——中心在框里的可能是一个半截搭在
/// 外面的父组，那不该变成孩子。
void _migrateLegacyGroups(List<CanvasNode> nodes) {
  final List<GroupNode> groups = <GroupNode>[
    for (final CanvasNode n in nodes)
      if (n is GroupNode) n,
  ];
  if (groups.isEmpty) return;
  // 已经带 groupId = 新格式（或迁移过），不再猜。
  if (nodes.any((CanvasNode n) => n.groupId != null)) return;
  groups.sort(
    (GroupNode a, GroupNode b) =>
        (a.width * a.height).compareTo(b.width * b.height),
  );
  for (final GroupNode group in groups) {
    final Rect box = group.rect;
    for (final CanvasNode node in nodes) {
      if (identical(node, group) || node.groupId != null) continue;
      final bool inside = node is GroupNode
          ? box.contains(node.rect.topLeft)
          : box.contains(node.rect.center);
      if (inside) node.groupId = group.id;
    }
  }
}

CanvasNode? _nodeOf(Map<String, Object?> json) {
  final String? typeName = json['type'] is String
      ? (json['type']! as String)
      : null;
  final String id = _idOf(json['id']);
  final double width = _sizeOf(json['width'], canvasDefaultWidth);
  final double height = _sizeOf(json['height'], canvasDefaultHeight);
  final double x = _doubleOf(json['x']);
  final double y = _doubleOf(json['y']);
  final String? color = _colorOf(json['color']);
  final String? groupId = _textOrNull(json['groupId']);
  final double scale = _scaleOf(json['scale']);
  final Map<String, Object?> extra = <String, Object?>{
    for (final MapEntry<String, Object?> e in json.entries)
      if (!_knownNodeKeys.contains(e.key)) e.key: e.value,
  };

  switch (typeName) {
    case 'text':
      return TextNode(
        id: id,
        x: x,
        y: y,
        width: width,
        height: height,
        text: json['text'] is String ? json['text']! as String : '',
        color: color,
        groupId: groupId,
        scale: scale,
        extra: extra,
      );
    case 'file':
      return FileNode(
        id: id,
        x: x,
        y: y,
        width: width,
        height: height,
        file: json['file'] is String ? json['file']! as String : '',
        subpath: _subpathOf(json['subpath']),
        expanded: json['expanded'] == true,
        color: color,
        groupId: groupId,
        scale: scale,
        extra: extra,
      );
    case 'link':
      return LinkNode(
        id: id,
        x: x,
        y: y,
        width: width,
        height: height,
        url: json['url'] is String ? json['url']! as String : '',
        color: color,
        groupId: groupId,
        scale: scale,
        extra: extra,
      );
    case 'group':
      return GroupNode(
        id: id,
        x: x,
        y: y,
        width: width,
        height: height,
        label: _textOrNull(json['label']),
        autoFit: true,
        color: color,
        groupId: groupId,
        scale: scale,
        extra: extra,
      );
    default:
      // 不认识的类型：整张卡片跳过。将来加类型时我们不该崩。
      return null;
  }
}

CanvasEdge? _edgeOf(Map<String, Object?> json) {
  // 新格式用 `from` / `to`；顺手认一下旧的 `fromNode` / `toNode`，
  // 让手改过的文件不至于整条边消失。
  final Object? from = json['from'] ?? json['fromNode'];
  final Object? to = json['to'] ?? json['toNode'];
  if (from is! String || to is! String || from.isEmpty || to.isEmpty) {
    return null;
  }
  return CanvasEdge(
    id: _idOf(json['id']),
    fromNode: from,
    toNode: to,
    fromSide: _sides.contains(json['fromSide'])
        ? json['fromSide']! as String
        : null,
    toSide: _sides.contains(json['toSide']) ? json['toSide']! as String : null,
    fromEnd: _endOf(json['fromEnd'], fallback: 'none'),
    toEnd: _endOf(json['toEnd'], fallback: 'arrow'),
    color: _colorOf(json['color']),
    label: _textOrNull(json['label']),
    extra: <String, Object?>{
      for (final MapEntry<String, Object?> e in json.entries)
        if (!_knownEdgeKeys.contains(e.key) &&
            e.key != 'fromNode' &&
            e.key != 'toNode')
          e.key: e.value,
    },
  );
}

/// `fromEnd` / `toEnd` 只认 `none` / `arrow`，其余一律退回缺省值。
///
/// 注意两边缺省值不同：`fromEnd` 缺省 `none`，`toEnd` 缺省 `arrow`。
/// 这里把缺省值**显式写进模型**，读回来就是确定的，不用到处判 null。
String _endOf(Object? raw, {required String fallback}) {
  if (raw == 'none' || raw == 'arrow') return raw! as String;
  return fallback;
}

String _idOf(Object? raw) {
  if (raw is String) {
    final String trimmed = raw.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return newCanvasId();
}

double _doubleOf(Object? raw) {
  if (raw is num && raw.isFinite) return raw.toDouble();
  if (raw is String) {
    final double? parsed = double.tryParse(raw.trim());
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return 0;
}

/// 宽高：缺省用默认值，非正数抬到 [canvasMinSize]。
double _sizeOf(Object? raw, double fallback) {
  if (raw == null) return fallback;
  final double value = _doubleOf(raw);
  if (value <= 0) return canvasMinSize;
  return value < canvasMinSize ? canvasMinSize : value;
}

/// 字号倍率。缺省是 1；写坏了（0、负数、NaN）也回 1，不能因为一个字段
/// 把整张卡的字弄没。**不设上下限**。
double _scaleOf(Object? raw) {
  if (raw == null) return 1;
  final double value = _doubleOf(raw);
  return _validScale(value) ? value : 1;
}

/// 倍率得是正的有限数。0 会让字消失且再也乘不回来，NaN / ∞ 会把排版搞崩。
bool _validScale(double value) => value.isFinite && value > 0;

String? _textOrNull(Object? raw) {
  if (raw is! String) return null;
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// `subpath` 以 `#` 开头；缺了就补上，不丢内容。
String? _subpathOf(Object? raw) {
  final String? text = _textOrNull(raw);
  if (text == null) return null;
  return text.startsWith('#') ? text : '#$text';
}

/// 颜色只认 `'1'`–`'6'` 和 `#RRGGBB` / `#RRGGBBAA`，其余当没设。
String? _colorOf(Object? raw) {
  if (raw is! String) return null;
  final String s = raw.trim();
  if (s.length == 1) {
    final int code = s.codeUnitAt(0);
    if (code >= 0x31 && code <= 0x36) return s;
  }
  if (_hexColor.hasMatch(s)) return s.toUpperCase();
  return null;
}

/// 落盘用：保留三位小数。
///
/// 坐标是自由的（不吸附网格、不取整），但拖动一帧能产生
/// `12.300000000000001` 这种浮点噪声。压到三位既不影响手感，也不会让
/// 每次保存都产生一长串无意义的 diff。
Object _wireNumber(double v) {
  if (!v.isFinite) return 0;
  final double rounded = (v * 1000).roundToDouble() / 1000;
  return rounded == rounded.truncateToDouble() ? rounded.toInt() : rounded;
}

// ------------------------------------------------------------------ 写出

/// 把白板写成文件内容。
///
/// 缩进两空格、键序固定——同一个白板反复保存不会产生无意义的 diff。
String encodeCanvas(CanvasDocument doc) =>
    const JsonEncoder.withIndent('  ').convert(doc.toJson());

// ------------------------------------------------------------------ 新建

/// 生成一个 16 位小写十六进制的 id。
///
/// [random] 只在测试里传，用来拿到确定的 id。
String newCanvasId([Random? random]) {
  final Random rng = random ?? _secureRandom();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < 16; i++) {
    out.write(rng.nextInt(16).toRadixString(16));
  }
  return out.toString();
}

Random _secureRandom() {
  try {
    return Random.secure();
  } on UnsupportedError {
    // 某些 Web 运行环境没有安全随机源；白板 id 不需要密码学强度。
    return Random();
  }
}
