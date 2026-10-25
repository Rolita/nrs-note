/// 行内 Markdown 的**语法**——只管「哪一段是什么」，不管画成什么样。
///
/// 放在 core 而不是编辑器里，是因为它有三个互不相干的消费者：
///
/// * 排版层（`live_markdown/inline.dart`）把 token 画成粗体、胶囊、链接；
/// * 按行样式（`line_layout/live_line_style.dart`）找出可点击的双链区间；
/// * 关系图谱（`core/utils/note_graph.dart`）从正文里抽边。
///
/// 三方共用同一个扫描器，才不会出现「正文里没画成链接，图谱里却有一条边」
/// 这种自相矛盾。颜色、字体、命中区域这些表现层的东西一概不在这里。
library;

/// 行内语法的扫描器，从左到右扫，先长后短。
///
/// 顺序要紧：同一位置上更长的、更具体的构造必须先赢，否则 `**粗**` 会被
/// 拆成两个 `*斜*`，`` `[[x]]` `` 里的双链会被当成真链接。
final RegExp markdownInlinePattern = RegExp(
  r'!?\[\[[^\]\n]+\]\]'
  r'|!?\[[^\]\n]{0,200}\]\([^)\n]{0,500}\)'
  r'|`[^`\n]*`'
  r'|\*\*[^*\n]+\*\*|__[^_\n]+__'
  r'|~~[^~\n]+~~'
  r'|==[^=\n]+=='
  r'|\*[^*\n]+\*|(?<![A-Za-z0-9_])_[^_\n]+_(?![A-Za-z0-9_])'
  r'|#[A-Za-z0-9_\u4e00-\u9fff][A-Za-z0-9_\u4e00-\u9fff\-/\.]*',
);

/// 围栏行的语法：缩进、围栏字符与 info string。
///
/// 和 [markdownInlinePattern] 放在一起，是为了让「哪一段是代码」也只有一份
/// 判定：块层用它切代码块卡片，图谱用它跳过代码块里的 `[[...]]`。两边各写
/// 一个正则，迟早会有一个先改。
final RegExp fenceLinePattern = RegExp(r'^(\s{0,3})(`{3,}|~{3,})(.*)$');

/// `[[目标]]` / `![[目标]]` 里的链接目标；不是双链或目标为空时返回 `null`。
///
/// 渲染、点击命中和图谱抽边都经过这一个入口，三方对「什么才算双链」不会
/// 各说各话。
///
/// 注意返回值是**原样**的内部文本：`[[标题|别名]]` 得到的是 `标题|别名`。
/// 这是编辑器当前的行为（点击时按整个字符串去找笔记），图谱跟着它走——
/// 「图上画的那条边」和「点一下会跳到哪」必须是同一件事。
String? wikilinkTarget(String token) {
  if (!token.startsWith('[[') && !token.startsWith('![[')) return null;
  final int open = token.startsWith('!') ? 3 : 2;
  if (token.length < open + 2) return null;
  final String inner = token.substring(open, token.length - 2);
  return inner.trim().isEmpty ? null : inner;
}

/// 一段文本里的双链：行内区间（含方括号）与链接目标。
///
/// 与排版层共用 [markdownInlinePattern]，所以反引号里的 `[[...]]` 不算链接
/// ——扫描器从头扫，先吃掉了整个代码 span。
///
/// [embed] 为 true 表示这是 `![[...]]`（图片/附件嵌入）。嵌入和链接共用同一
/// 套括号，调用方要自己决定要不要区别对待：图谱会跳过嵌入，因为
/// `![[图片.png]]` 连的是一张图，不是一篇笔记。
List<({int start, int end, String target, bool embed})> wikilinkRuns(
  String text,
) {
  if (!text.contains('[[')) {
    return const <({int start, int end, String target, bool embed})>[];
  }
  final List<({int start, int end, String target, bool embed})> runs =
      <({int start, int end, String target, bool embed})>[];
  for (final RegExpMatch m in markdownInlinePattern.allMatches(text)) {
    final String token = m.group(0)!;
    final String? target = wikilinkTarget(token);
    if (target != null) {
      runs.add((
        start: m.start,
        end: m.end,
        target: target,
        embed: token.startsWith('!'),
      ));
    }
  }
  return runs;
}

/// 一段文字**整个就是**一个双链时，返回它的区间与内部文字；否则 `null`。
///
/// 「取消链接」的判据：`[[笔记]]` 算，`看 [[笔记]]` 不算——后者里还有正文，
/// 照双链处理会连正文一起吞掉。前后允许有空白（拖选很容易多带一个空格），
/// 返回的区间不含那点空白，替换时原地保留。
///
/// `![[图片]]` 不算：那是嵌入，不是双链，去掉方括号等于把图片换成文件名。
({int start, int end, String label})? soleWikilink(String text) {
  final int first = text.indexOf('[[');
  if (first < 0) return null;
  // `![[…]]` 的第一个 `[[` 前面是 `!`，这里直接判掉嵌入。
  if (text.substring(0, first).trim().isNotEmpty) return null;
  for (final ({int start, int end, String target, bool embed}) run
      in wikilinkRuns(text)) {
    if (run.embed || run.start != first) continue;
    if (text.substring(run.end).trim().isNotEmpty) return null;
    return (start: run.start, end: run.end, label: run.target);
  }
  return null;
}

