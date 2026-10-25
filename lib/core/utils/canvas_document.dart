/// 白板文件（`.nrs`）的数据模型。
///
/// 文件**内容**是 [JSON Canvas 1.0](https://jsoncanvas.org/spec/1.0/)：
/// 字段、枚举值、默认值全部照规范，后缀换成了 `.nrs`。之所以不自己发明格式，
/// 是因为规范的字段集已经被现实打磨过（`group` / `subpath` / `fromEnd` / 六色预设），
/// 自己设计一套大概率会漏；而且想和 Obsidian 互通只要改个后缀直接写出去。
///
/// 三个容易写反的地方，改之前先读：
///
/// * **`toEnd` 缺省是 `arrow`，`fromEnd` 缺省是 `none`**。两个默认值不一样。
/// * **`x/y/width/height` 在规范里是整数**。内存里留 `double` 是为了拖动平滑，
///   落盘时 [encodeCanvas] 会 `round()`。
/// * **节点数组的顺序就是 z-index**：第一个在最底层，最后一个在最上层。
///   所以命中测试要倒序遍历，绘制要正序遍历。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Rect;

/// 白板文件的后缀。想和 Obsidian 直接互通就把这里改回 `'.canvas'`。
const String canvasExtension = '.nrs';

/// 新建卡片的默认尺寸。
const double canvasDefaultWidth = 250;
const double canvasDefaultHeight = 120;

/// 卡片能被缩到多小。再小就没法点了，也没法把光标放进去。
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
    Map<String, Object?> extra = const <String, Object?>{},
  }) : extra = Map<String, Object?>.of(extra);

  /// 唯一 id，16 位小写十六进制（与 Obsidian 同长度）。
  final String id;

  double x;
  double y;
  double width;
  double height;

  /// `'1'`–`'6'` 预设色，或 `'#RRGGBB'` / `'#RRGGBBAA'`；`null` = 默认色。
  String? color;

  /// 规范之外、我们不认识的键。**原样保留**，否则用户在别的工具里设的
  /// 新字段会被我们吃掉。
  final Map<String, Object?> extra;

  CanvasNodeType get type;

  String get typeName => switch (type) {
    CanvasNodeType.text => 'text',
    CanvasNodeType.file => 'file',
    CanvasNodeType.link => 'link',
    CanvasNodeType.group => 'group',
  };

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  /// 写回 JSON。键顺序固定（`id/type/x/y/width/height/color`，再按类型追加），
  /// 因为白板文件会进 git，键序抖动会让每次保存都产生整文件 diff。
  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
      'id': id,
      'type': typeName,
      'x': _wireNumber(x),
      'y': _wireNumber(y),
      'width': _wireNumber(width),
      'height': _wireNumber(height),
      if (color != null) 'color': color,
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

/// 文字卡片：`text` 里是 Markdown。
final class TextNode extends CanvasNode {
  TextNode({
    required super.id,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    this.text = '',
    super.color,
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
    super.color,
    super.extra,
  });

  /// 相对 vault 根的文件路径（正斜杠），和 `Note.relativePath` 同一种写法。
  String file;

  /// 指向笔记里的某个标题或块，**始终以 `#` 开头**（规范要求）。
  String? subpath;

  @override
  CanvasNodeType get type => CanvasNodeType.file;

  @override
  void _writeSpecific(Map<String, Object?> out) {
    out['file'] = file;
    if (subpath != null) out['subpath'] = subpath;
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
    super.extra,
  });

  String url;

  @override
  CanvasNodeType get type => CanvasNodeType.link;

  @override
  void _writeSpecific(Map<String, Object?> out) => out['url'] = url;
}

/// 分组：一个框住若干卡片的大矩形，可以带标题和背景图。
final class GroupNode extends CanvasNode {
  GroupNode({
    required super.id,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    this.label,
    this.background,
    this.backgroundStyle,
    super.color,
    super.extra,
  });

  String? label;

  /// 背景图路径。
  String? background;

  /// `cover` / `ratio` / `repeat`。
  String? backgroundStyle;

  @override
  CanvasNodeType get type => CanvasNodeType.group;

  @override
  void _writeSpecific(Map<String, Object?> out) {
    if (label != null) out['label'] = label;
    if (background != null) out['background'] = background;
    if (backgroundStyle != null) out['backgroundStyle'] = backgroundStyle;
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

  /// `none` / `arrow`。**缺省值两边不一样**，见 [fromIsArrow] / [toIsArrow]。
  String? fromEnd;
  String? toEnd;

  String? color;
  String? label;

  final Map<String, Object?> extra;

  /// 起点有没有箭头。规范缺省 `none`。
  bool get fromIsArrow => fromEnd == 'arrow';

  /// 终点有没有箭头。规范缺省 **`arrow`**——写反了就会「一条箭头都看不见」。
  bool get toIsArrow => toEnd != 'none';

  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
      'id': id,
      'fromNode': fromNode,
      'toNode': toNode,
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

  /// 顺序即 z-index：靠前的在下面。
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

  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
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
  'text',
  'file',
  'subpath',
  'url',
  'label',
  'background',
  'backgroundStyle',
};

const Set<String> _knownEdgeKeys = <String>{
  'id',
  'fromNode',
  'toNode',
  'fromSide',
  'toSide',
  'fromEnd',
  'toEnd',
  'color',
  'label',
};

const Set<String> _knownTopKeys = <String>{'nodes', 'edges'};

const Set<String> _sides = <String>{'top', 'right', 'bottom', 'left'};

const Set<String> _backgroundStyles = <String>{'cover', 'ratio', 'repeat'};

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
      if (edge.fromNode == edge.toNode) continue;             // 自环
      if (!seenIds.contains(edge.fromNode)) continue;         // 指向不存在的节点
      if (!seenIds.contains(edge.toNode)) continue;
      if (!edgeIds.add(edge.id)) continue;
      edges.add(edge);
    }
  }

  return CanvasDocument(
    nodes: nodes,
    edges: edges,
    extra: <String, Object?>{
      for (final MapEntry<String, Object?> e in raw.entries)
        if (!_knownTopKeys.contains(e.key)) e.key: e.value,
    },
  );
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
        color: color,
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
        background: _textOrNull(json['background']),
        backgroundStyle: _backgroundStyles.contains(json['backgroundStyle'])
            ? json['backgroundStyle']! as String
            : null,
        color: color,
        extra: extra,
      );
    default:
      // 不认识的类型：整张卡片跳过。将来规范加类型时我们不该崩。
      return null;
  }
}

CanvasEdge? _edgeOf(Map<String, Object?> json) {
  final Object? from = json['fromNode'];
  final Object? to = json['toNode'];
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
        if (!_knownEdgeKeys.contains(e.key)) e.key: e.value,
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

String? _textOrNull(Object? raw) {
  if (raw is! String) return null;
  final String trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// 规范要求 `subpath` 始终以 `#` 开头；缺了就补上，不丢内容。
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

/// 落盘用：规范要求 `x/y/width/height` 是整数，所以一律取整。
///
/// 内存里保留小数（拖动是连续的，取整会让卡片一顿一顿地跳），只在写文件时圆整。
/// 这样既不会写出 `249.99999` 把文件搞脏，拖动过程中也不会抖。
Object _wireNumber(double v) => v.isFinite ? v.round() : 0;

// ------------------------------------------------------------------ 写出

/// 把白板写成文件内容。
///
/// 缩进两空格、键序固定、坐标取整——这样同一个白板反复保存不会产生无意义的 diff。
String encodeCanvas(CanvasDocument doc) =>
    const JsonEncoder.withIndent('  ').convert(doc.toJson());

// ------------------------------------------------------------------ 新建

/// 生成一个 16 位小写十六进制的 id，长度与 Obsidian 一致。
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
