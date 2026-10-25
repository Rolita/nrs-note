import 'package:flutter_test/flutter_test.dart';
import 'package:nrs/core/utils/note_graph.dart';
import 'package:nrs/data/models/note.dart';

/// 造一篇笔记。正文是唯一有意义的入参，其余都给个稳定的默认值。
Note note(String title, {String body = '', String folder = '', String? id}) {
  final DateTime t = DateTime(2026, 1, 1);
  return Note(
    id: id ?? 'id:$title',
    title: title,
    body: body,
    createdAt: t,
    updatedAt: t,
    folderPath: folder,
  );
}

/// 边用标题对表示，断言比下标好读。
Set<String> edgeSet(NoteGraph g) => <String>{
  for (final GraphEdge e in g.edges)
    '${g.nodes[e.a].title}—${g.nodes[e.b].title}',
};

GraphNode nodeOf(NoteGraph g, String title) =>
    g.nodes.firstWhere((GraphNode n) => n.title == title);

void main() {
  group('抽边', () {
    test('A→B 与 B→A 只画一条边，但出/入链各算各的', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '见 [[B]]'),
        note('B', body: '回 [[A]]'),
      ]);

      expect(g.edges, hasLength(1));
      expect(edgeSet(g), <String>{'A—B'});
      expect(nodeOf(g, 'A').outDegree, 1);
      expect(nodeOf(g, 'A').inDegree, 1);
      expect(nodeOf(g, 'B').outDegree, 1);
      expect(nodeOf(g, 'B').inDegree, 1);
      expect(nodeOf(g, 'A').globalDegree, 1);
    });

    test('单向链接只有一条边，出链在源、入链在靶', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '见 [[B]]'),
        note('B'),
      ]);

      expect(nodeOf(g, 'A').outDegree, 1);
      expect(nodeOf(g, 'A').inDegree, 0);
      expect(nodeOf(g, 'B').outDegree, 0);
      expect(nodeOf(g, 'B').inDegree, 1);
    });

    test('![[图片.png]] 是嵌入，不产生边', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '![[图片.png]]'),
        note('图片.png'),
      ]);

      expect(g.edges, isEmpty);
      expect(nodeOf(g, 'A').globalDegree, 0);
    });

    test('死链不产生边，也不产生节点', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '[[还不存在的标题]]'),
      ]);

      expect(g.edges, isEmpty);
      expect(g.nodes, hasLength(1));
      expect(g.orphanCount, 1);
    });

    test('[[自己]] 不产生自环', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '[[A]]'),
      ]);

      expect(g.edges, isEmpty);
      expect(nodeOf(g, 'A').outDegree, 0);
    });

    test('标题匹配不区分大小写、忽略首尾空格', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '[[  rust 所有权 ]]'),
        note('Rust 所有权'),
      ]);

      expect(edgeSet(g), <String>{'A—Rust 所有权'});
    });

    test('同名标题取先出现的那篇（与 openOrCreateByTitle 一致）', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '[[同名]]'),
        note('同名', folder: '甲', id: 'id:first'),
        note('同名', folder: '乙', id: 'id:second'),
      ]);

      expect(g.edges, hasLength(1));
      expect(g.nodes[g.edges.single.b].id, 'id:first');
    });

    test('一句话里重复 [[A]] 三次：一条边、度数 1', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '[[B]] 和 [[B]] 还有 [[B]]'),
        note('B'),
      ]);

      expect(g.edges, hasLength(1));
      expect(nodeOf(g, 'A').outDegree, 1);
    });

    test('反引号里的 [[x]] 不算链接', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '写成 `[[B]]` 就是字面量'),
        note('B'),
      ]);

      expect(g.edges, isEmpty);
    });

    test('代码块里的 [[x]] 不算链接', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '```\n[[B]]\n```'),
        note('B'),
      ]);

      expect(g.edges, isEmpty);
    });

    test('[[标题|别名]] 的目标是完整字符串（锁住现状）', () {
      // 编辑器目前就是这么解析的：点击时拿整串去找笔记，找不到就新建一篇
      // 名叫「标题|别名」的。图谱跟着它走，不单独发明一套。
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '[[B|别名]]'),
        note('B'),
        note('B|别名'),
      ]);

      expect(edgeSet(g), <String>{'A—B|别名'});
    });

    test('空库、单篇、全孤立都不崩', () {
      expect(buildNoteGraph(<Note>[]).isEmpty, isTrue);
      expect(buildNoteGraph(<Note>[]).orphanCount, 0);

      final NoteGraph single = buildNoteGraph(<Note>[note('A')]);
      expect(single.nodes, hasLength(1));
      expect(single.orphanCount, 1);

      final NoteGraph lonely = buildNoteGraph(<Note>[note('A'), note('B')]);
      expect(lonely.edges, isEmpty);
      expect(lonely.orphanCount, 2);
    });
  });

  group('度数', () {
    test('度数是去重后的邻居数，不是边数', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', body: '[[B]] [[C]]'),
        note('B', body: '[[A]]'),
        note('C'),
      ]);

      expect(g.edges, hasLength(2));
      expect(nodeOf(g, 'A').globalDegree, 2);
      expect(nodeOf(g, 'B').globalDegree, 1);
      expect(g.orphanCount, 0);
    });

    test('顶层文件夹取第一段', () {
      final NoteGraph g = buildNoteGraph(<Note>[
        note('A', folder: '项目/2026/Q4'),
        note('B', folder: '日记'),
        note('C'),
      ]);

      expect(nodeOf(g, 'A').folder, '项目');
      expect(nodeOf(g, 'B').folder, '日记');
      expect(nodeOf(g, 'C').folder, '');
    });
  });

  group('邻域与子图', () {
    /// A—B—C—D 一条链，外加一个孤立的 E。
    NoteGraph chain() => buildNoteGraph(<Note>[
      note('A', body: '[[B]]'),
      note('B', body: '[[C]]'),
      note('C', body: '[[D]]'),
      note('D'),
      note('E'),
    ]);

    test('深度 1 只有直接邻居', () {
      final NoteGraph g = chain();
      final Set<int> keep = g.neighbourhood(g.indexOfId('id:B')!, 1);
      expect(
        keep.map((int i) => g.nodes[i].title).toSet(),
        <String>{'A', 'B', 'C'},
      );
    });

    test('深度 2 / 3 依次扩大', () {
      final NoteGraph g = chain();
      final int from = g.indexOfId('id:B')!;
      expect(g.neighbourhood(from, 2).length, 4); // A B C D
      expect(g.neighbourhood(from, 3).length, 4);
    });

    test('孤立笔记的邻域只有自己', () {
      final NoteGraph g = chain();
      expect(g.neighbourhood(g.indexOfId('id:E')!, 4), <int>{4});
    });

    test('子图重新编号，出/入链与全局度数原样保留', () {
      final NoteGraph g = chain();
      final NoteGraph sub = g.subgraph(g.neighbourhood(g.indexOfId('id:B')!, 1));

      expect(sub.nodes, hasLength(3));
      expect(sub.edges, hasLength(2));
      // 子图里 B 是中心，编号打乱但 id 还在
      final GraphNode b = sub.nodes.firstWhere((GraphNode n) => n.title == 'B');
      expect(b.outDegree, 1); // 全局出链：B → C
      expect(b.inDegree, 1); // 全局入链：A → B
      expect(b.globalDegree, 2);
      expect(sub.indexOfId('id:D'), isNull);
    });

    test('子图的邻居表只含子图内的节点', () {
      final NoteGraph g = chain();
      final NoteGraph sub = g.subgraph(<int>{
        g.indexOfId('id:C')!,
        g.indexOfId('id:D')!,
      });

      final GraphNode c = sub.nodes.firstWhere((GraphNode n) => n.title == 'C');
      expect(c.neighbours, hasLength(1));
      expect(sub.nodes[c.neighbours.single].title, 'D');
      // 全局度数不变：C 连 B 和 D
      expect(c.globalDegree, 2);
    });

    test('全选时原样返回，不复制', () {
      final NoteGraph g = chain();
      final Set<int> all = <int>{
        for (int i = 0; i < g.nodes.length; i++) i,
      };
      expect(identical(g.subgraph(all), g), isTrue);
    });
  });

  test('indexOfId 认 null 与不存在的 id', () {
    final NoteGraph g = buildNoteGraph(<Note>[note('A')]);
    expect(g.indexOfId(null), isNull);
    expect(g.indexOfId('不存在'), isNull);
    expect(g.indexOfId('id:A'), 0);
  });
}
