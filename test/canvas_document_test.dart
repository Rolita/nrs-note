import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/canvas_document.dart';

/// 一份「像 Obsidian 导出的」白板：四类节点、带 label 的边、group、颜色都齐。
const String _fixture = '''
{
  "nodes": [
    {
      "id": "1111111111111111",
      "type": "text",
      "text": "想法：把白板做成主区视图",
      "x": 0,
      "y": 0,
      "width": 250,
      "height": 120,
      "color": "1"
    },
    {
      "id": "2222222222222222",
      "type": "file",
      "file": "项目/白板功能.md",
      "subpath": "#方案",
      "x": 320,
      "y": 0,
      "width": 300,
      "height": 200
    },
    {
      "id": "3333333333333333",
      "type": "link",
      "url": "https://jsoncanvas.org/spec/1.0/",
      "x": 0,
      "y": 200,
      "width": 250,
      "height": 120,
      "color": "#4A90D9"
    },
    {
      "id": "4444444444444444",
      "type": "group",
      "label": "第一期",
      "background": "assets/bg.png",
      "backgroundStyle": "cover",
      "x": -40,
      "y": -40,
      "width": 700,
      "height": 420
    }
  ],
  "edges": [
    {
      "id": "aaaaaaaaaaaaaaaa",
      "fromNode": "1111111111111111",
      "fromSide": "right",
      "toNode": "2222222222222222",
      "toSide": "left",
      "toEnd": "arrow",
      "label": "落地方案",
      "color": "4"
    },
    {
      "id": "bbbbbbbbbbbbbbbb",
      "fromNode": "2222222222222222",
      "toNode": "3333333333333333"
    }
  ]
}
''';

CanvasDocument parse(String s) => parseCanvas(s);

Map<String, Object?> decode(String s) =>
    jsonDecode(s) as Map<String, Object?>;

void main() {
  group('解析', () {
    test('四类节点的专有字段都读出来', () {
      final CanvasDocument doc = parse(_fixture);

      expect(doc.nodes.length, 4);

      final TextNode text = doc.nodes[0] as TextNode;
      expect(text.type, CanvasNodeType.text);
      expect(text.text, '想法：把白板做成主区视图');
      expect(text.color, '1');

      final FileNode file = doc.nodes[1] as FileNode;
      expect(file.file, '项目/白板功能.md');
      expect(file.subpath, '#方案');

      final LinkNode link = doc.nodes[2] as LinkNode;
      expect(link.url, 'https://jsoncanvas.org/spec/1.0/');
      expect(link.color, '#4A90D9');

      final GroupNode group = doc.nodes[3] as GroupNode;
      expect(group.label, '第一期');
      expect(group.background, 'assets/bg.png');
      expect(group.backgroundStyle, 'cover');
    });

    test('坐标与尺寸读成 double', () {
      final TextNode text = parse(_fixture).nodes[0] as TextNode;

      expect(text.x, 0);
      expect(text.y, 0);
      expect(text.width, 250);
      expect(text.height, 120);
      expect(text.rect, const Rect.fromLTWH(0, 0, 250, 120));
    });

    test('边读出 side / label / color', () {
      final CanvasEdge e = parse(_fixture).edges[0];

      expect(e.fromNode, '1111111111111111');
      expect(e.toNode, '2222222222222222');
      expect(e.fromSide, 'right');
      expect(e.toSide, 'left');
      expect(e.label, '落地方案');
      expect(e.color, '4');
    });

    test('缺 nodes / edges 当作空文档', () {
      expect(parse('{}').isEmpty, isTrue);
      expect(parse('{"nodes": []}').isEmpty, isTrue);
      expect(parse('{"edges": []}').isEmpty, isTrue);
    });

    test('顶层未知键原样保留', () {
      final CanvasDocument doc = parse('{"nodes":[],"edges":[],"zoom":1.5}');

      expect(doc.extra, <String, Object?>{'zoom': 1.5});
    });

    test('节点和边上的未知键原样保留', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"n1","type":"text","x":0,"y":0,"width":10,"height":10,
"text":"a","pinned":true}],
 "edges":[{"id":"e1","fromNode":"n1","toNode":"n1","style":"dashed"}]}
''');

      expect(doc.nodes.single.extra, <String, Object?>{'pinned': true});
      // 自环被丢了，所以这里没有边可查；单独验一下边的 extra 用下面那条。
      expect(doc.edges, isEmpty);

      final CanvasDocument two = parse('''
{"nodes":[{"id":"n1","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"n2","type":"text","x":20,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"n1","toNode":"n2","style":"dashed"}]}
''');
      expect(two.edges.single.extra, <String, Object?>{'style': 'dashed'});
    });
  });

  group('序列化', () {
    test('解析再写出，结构与原来一致', () {
      final CanvasDocument doc = parse(_fixture);

      // 逐字段比：拿一次 encode 的结果解回 Map，再和重新解析后的 encode 比。
      final String once = encodeCanvas(doc);
      final String twice = encodeCanvas(parse(once));

      expect(twice, once, reason: '写出再读回来应该完全一样');
    });

    test('写出是幂等的（键序稳定，不会每次保存都抖）', () {
      final String a = encodeCanvas(parse(_fixture));
      final String b = encodeCanvas(parse(_fixture));

      expect(a, b);
    });

    test('坐标落盘取整，内存里仍是小数', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"n1","type":"text","x":10.4,"y":-3.6,"width":250.7,"height":120.2}]}
''');
      final TextNode n = doc.nodes.single as TextNode;

      expect(n.x, 10.4, reason: '内存保留小数，拖动才不会一顿一顿');
      expect(n.y, -3.6);

      final Map<String, Object?> wire = decode(encodeCanvas(doc));
      final Map<String, Object?> node =
          (wire['nodes']! as List<Object?>).single! as Map<String, Object?>;

      expect(node['x'], 10);
      expect(node['y'], -4);
      expect(node['width'], 251);
      expect(node['height'], 120);
      expect(node['x'], isA<int>(), reason: '规范要求 integer');
    });

    test('toEnd 缺省补 arrow，fromEnd 缺省补 none', () {
      final CanvasEdge e = parse('''
{"nodes":[{"id":"n1","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"n2","type":"text","x":20,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"n1","toNode":"n2"}]}
''').edges.single;

      expect(e.toEnd, 'arrow');
      expect(e.fromEnd, 'none');
      expect(e.toIsArrow, isTrue);
      expect(e.fromIsArrow, isFalse);

      // 写回去时也照缺省值写出来，读的人不用猜。
      final Map<String, Object?> wire = decode(encodeCanvas(parse('''
{"nodes":[{"id":"n1","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"n2","type":"text","x":20,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"n1","toNode":"n2"}]}
''')));

      final Map<String, Object?> edge =
          (wire['edges']! as List<Object?>).single! as Map<String, Object?>;
      expect(edge['toEnd'], 'arrow');
      expect(edge['fromEnd'], 'none');
    });

    test('两空格缩进', () {
      final String out = encodeCanvas(parse('{}'));

      expect(out.contains('\n  "nodes"'), isTrue);
    });
  });

  group('容错', () {
    test('不是 JSON 就抛，不静默吞掉', () {
      expect(
        () => parse('这不是 JSON'),
        throwsA(isA<CanvasFormatException>()),
      );
    });

    test('顶层是数组也抛', () {
      expect(() => parse('[]'), throwsA(isA<CanvasFormatException>()));
    });

    test('缺 id 就生成一个 16 位十六进制', () {
      final CanvasNode n = parse('''
{"nodes":[{"type":"text","x":0,"y":0,"width":10,"height":10}]}
''').nodes.single;

      expect(n.id.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(n.id), isTrue);
    });

    test('宽高非正数抬到最小值', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":0,"height":-5},
{"id":"b","type":"text","x":0,"y":0,"width":10,"height":10}]}
''');

      expect(doc.nodes[0].width, canvasMinSize);
      expect(doc.nodes[0].height, canvasMinSize);
      expect(doc.nodes[1].width, canvasMinSize, reason: '10 小于最小值也要抬');
    });

    test('缺坐标当 0，缺宽高用默认值', () {
      final CanvasNode n = parse('''
{"nodes":[{"id":"a","type":"text"}]}
''').nodes.single;

      expect(n.x, 0);
      expect(n.y, 0);
      expect(n.width, canvasDefaultWidth);
      expect(n.height, canvasDefaultHeight);
    });

    test('不认识的类型跳过，引用它的边也一起丢', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"b","type":"mindmap","x":0,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"a","toNode":"b"}]}
''');

      expect(doc.nodes.length, 1);
      expect(doc.nodes.single.id, 'a');
      expect(doc.edges, isEmpty);
    });

    test('边指向不存在的节点就丢', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"a","toNode":"幽灵"}]}
''');

      expect(doc.edges, isEmpty);
    });

    test('自环丢掉', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"a","toNode":"a"}]}
''');

      expect(doc.edges, isEmpty);
    });

    test('同一对节点之间多条边保留', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"b","type":"text","x":30,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"a","toNode":"b"},
          {"id":"e2","fromNode":"b","toNode":"a"}]}
''');

      expect(doc.edges.length, 2);
    });

    test('重复的节点 id 只留第一个', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":1,"y":0,"width":10,"height":10},
{"id":"a","type":"text","x":99,"y":0,"width":10,"height":10}]}
''');

      expect(doc.nodes.length, 1);
      expect(doc.nodes.single.x, 1);
    });

    test('非法 color 当没设', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10,"color":"9"},
{"id":"b","type":"text","x":0,"y":0,"width":10,"height":10,"color":"red"},
{"id":"c","type":"text","x":0,"y":0,"width":10,"height":10,"color":"#GGGGGG"}]}
''');

      for (final CanvasNode n in doc.nodes) {
        expect(n.color, isNull, reason: '${n.id} 的颜色应该被拒');
      }
    });

    test('合法的预设色和十六进制色都收', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10,"color":"6"},
{"id":"b","type":"text","x":0,"y":0,"width":10,"height":10,"color":"#ff8800"}]}
''');

      expect(doc.nodes[0].color, '6');
      expect(doc.nodes[1].color, '#FF8800');
    });

    test('非法 side 当自动', () {
      final CanvasEdge e = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"b","type":"text","x":30,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"a","toNode":"b","fromSide":"north","toSide":"RIGHT"}]}
''').edges.single;

      expect(e.fromSide, isNull);
      expect(e.toSide, isNull);
    });

    test('非法 end 退回缺省值', () {
      final CanvasEdge e = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"b","type":"text","x":30,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"a","toNode":"b","fromEnd":"triangle","toEnd":"none"}]}
''').edges.single;

      expect(e.fromEnd, 'none');
      expect(e.toEnd, 'none');
      expect(e.toIsArrow, isFalse);
    });

    test('subpath 缺 # 就补上', () {
      final FileNode n = parse('''
{"nodes":[{"id":"a","type":"file","x":0,"y":0,"width":10,"height":10,
"file":"a.md","subpath":"标题"}]}
''').nodes.single as FileNode;

      expect(n.subpath, '#标题');
    });

    test('非法 backgroundStyle 当没设', () {
      final GroupNode g = parse('''
{"nodes":[{"id":"a","type":"group","x":0,"y":0,"width":10,"height":10,
"backgroundStyle":"stretch"}]}
''').nodes.single as GroupNode;

      expect(g.backgroundStyle, isNull);
    });
  });

  group('id', () {
    test('16 位、全小写十六进制', () {
      for (int i = 0; i < 50; i++) {
        final String id = newCanvasId();
        expect(id.length, 16);
        expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(id), isTrue);
      }
    });

    test('传固定种子就能复现', () {
      expect(
        newCanvasId(Random(7)),
        newCanvasId(Random(7)),
      );
    });
  });

  group('查询', () {
    test('edgesOf 出边入边都算', () {
      final CanvasDocument doc = parse('''
{"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":10,"height":10},
{"id":"b","type":"text","x":30,"y":0,"width":10,"height":10},
{"id":"c","type":"text","x":60,"y":0,"width":10,"height":10}],
 "edges":[{"id":"e1","fromNode":"a","toNode":"b"},
          {"id":"e2","fromNode":"c","toNode":"a"}]}
''');

      expect(doc.edgesOf('a').map((CanvasEdge e) => e.id), <String>['e1', 'e2']);
      expect(doc.edgesOf('b').map((CanvasEdge e) => e.id), <String>['e1']);
      expect(doc.edgesOf('c').map((CanvasEdge e) => e.id), <String>['e2']);
      expect(doc.edgesOf('幽灵'), isEmpty);
    });

    test('nodeById 找得到也找得空', () {
      final CanvasDocument doc = parse(_fixture);

      expect(doc.nodeById('1111111111111111'), isA<TextNode>());
      expect(doc.nodeById('nope'), isNull);
    });

    test('节点顺序就是 z-index，解析后不重排', () {
      final CanvasDocument doc = parse(_fixture);

      expect(
        doc.nodes.map((CanvasNode n) => n.id),
        <String>[
          '1111111111111111',
          '2222222222222222',
          '3333333333333333',
          '4444444444444444',
        ],
      );
    });
  });
}
