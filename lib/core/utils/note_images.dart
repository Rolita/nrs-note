import 'image_markup.dart';

/// 正文里的一张图片：它在哪一行、引用什么、写没写宽度。
///
/// 只是给「图片侧边栏」用的一次扫描结果，不参与排版——排版那边有自己的一套
/// 块缓存（`LiveImageBlocks`），按行首偏移复用解码结果。
class NoteImage {
  const NoteImage({
    required this.offset,
    required this.line,
    required this.markup,
  });

  /// 这一行在正文里的起始偏移。跳转直接用它，不用再数行。
  final int offset;

  /// 行号，从 0 起。面板上显示给人看时加一。
  final int line;

  final ImageMarkup markup;

  String get source => markup.source;
  String? get alt => markup.alt;
  double? get width => markup.width;

  /// 远程图（`http(s):` / `data:`）——面板上标一下，免得有人以为它跟着笔记走。
  bool get isExternal => markup.isExternal;

  /// 面板上的标题：有 alt 用 alt，没有就用文件名。
  String get label {
    final String? text = alt?.trim();
    if (text != null && text.isNotEmpty) return text;
    final String tail = source.split(RegExp(r'[/\\]')).last;
    if (tail.isEmpty) return source;
    // 带查询串的远程地址（`a.png?x=1`）只取到问号，不然一行放不下。
    final int query = tail.indexOf('?');
    return query <= 0 ? tail : tail.substring(0, query);
  }

  @override
  String toString() => 'NoteImage(line $line, $source)';
}

/// 扫一遍正文，按出现顺序列出所有图片。
///
/// 判定用的是 [ImageMarkup.parseLine]——和渲染层同一个函数，所以「面板里列出来
/// 的」与「正文里画成图的」永远是同一批：`![a](b)` 和 `<img src>` 都算，混在
/// 文字中间的不算（那种在正文里也只是一行字，点过去看到的还是字）。
///
/// 纯函数，不碰 widget：列表随正文变化重算，代价只有一次逐行 trim + 前缀判断。
List<NoteImage> extractImages(String body) {
  final List<NoteImage> images = <NoteImage>[];
  int line = 0;
  int start = 0;
  while (start <= body.length) {
    final int newline = body.indexOf('\n', start);
    final int end = newline < 0 ? body.length : newline;
    final ImageMarkup? markup = ImageMarkup.parseLine(
      body.substring(start, end),
    );
    if (markup != null) {
      images.add(NoteImage(offset: start, line: line, markup: markup));
    }
    if (newline < 0) break;
    start = newline + 1;
    line++;
  }
  return images;
}
