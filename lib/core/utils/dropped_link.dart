import 'dart:convert';

import 'package:flutter/services.dart';

import 'image_markup.dart';

/// 从一次拖放里认出来的一条网页链接。
///
/// 拖进来的东西五花八门：浏览器给的是 `UniformResourceLocator`（Windows）或
/// `public.url`（macOS），地址栏拖出来的是纯文本 URL，拖一个标签页还会附带
/// 一小段 `<a href=…>标题</a>` 的 HTML。这里把它们归一到「地址 + 标题」两件事，
/// 编辑器只负责把它写成 `[标题](地址)`。
///
/// 拖进来的**不是**链接时（一段文字、一段富文本），由 [parseDroppedText] 接手
/// 读成纯文本；两者是同一个载荷的两种归宿，所以放在一起。
class DroppedLink {
  const DroppedLink({required this.url, this.title});

  /// 已经规范成 `http`/`https` 的地址。
  final String url;

  /// 载荷里带来的标题（浏览器的锚文本、macOS 的链接名）；没有则 `null`，
  /// 由 [markdownLinkFor] 退回域名。
  final String? title;

  @override
  bool operator ==(Object other) =>
      other is DroppedLink && other.url == url && other.title == title;

  @override
  int get hashCode => Object.hash(url, title);

  @override
  String toString() => 'DroppedLink($url, title: $title)';
}

/// 把一次拖放的各个载荷拼成一条链接；认不出网页地址时返回 `null`。
///
/// [uri] / [name] 是系统给的 URL 与链接名（`name` 只有 macOS/iOS 有），
/// [html] 是浏览器附带的 `<a href=…>标题</a>`，[plainText] 是最后的兜底
/// ——「复制链接」再拖、或从纯文本编辑器里拖过来的那种。
///
/// 认不出链接就返回 `null`，调用处交给 [parseDroppedText]：一段拖进来的文字
/// 里恰好有个网址，那是这段文字的一部分，不该被当成链接、更不该把其余内容
/// 吞掉。
DroppedLink? parseDroppedLink({
  String? uri,
  String? name,
  String? html,
  String? plainText,
}) {
  html = html == null ? null : _repairPackedUtf8(html);
  final List<String> lines = _lines(plainText).toList();

  // 地址：系统 URL 最准，其次纯文本里的一行，最后才是 HTML 的锚点。
  String? url = _cleanUrl(uri);
  if (url == null) {
    // 两行以上的纯文本是「一段文字」，不是链接：拖一段带着网址的笔记过来，
    // 只能原样落字。链接拖放的纯文本永远是空的或者一行。
    if (lines.length > 1) return null;
    for (final String line in lines) {
      final String? candidate = _cleanUrl(line);
      if (candidate == null) continue;
      url = candidate;
      break;
    }
  }
  if (url == null) {
    final _Anchor? first = _firstAnchor(html);
    url = _cleanUrl(first?.href);
    if (url == null) return null;
  }

  // 标题：系统给的链接名 → 对得上的锚文本 → 纯文本里的另一行。
  // 最后一条是给「浏览器只发了 URL 和文字、没发 HTML」那种拖放兜底的。
  String? title = _cleanTitle(name);
  title ??= _cleanTitle(_anchorLabelFor(html, url));
  title ??= _titleLine(lines);
  return DroppedLink(url: url, title: title);
}

/// 写进正文的 Markdown：`[标题](地址)`。
///
/// 没有标题就用域名（去掉 `www.`），比把整条地址当文字好看，也不会让一行
/// 被 URL 撑爆。方括号、圆括号和换行都按 Markdown 的规矩转义。
String markdownLinkFor(DroppedLink link) {
  final String label = link.title?.trim().isNotEmpty == true
      ? link.title!.trim()
      : (_hostLabel(link.url) ?? link.url);
  return '[${_escapeLabel(label)}](${_escapeUrl(link.url)})';
}

// ------------------------------------------------------------------ 图片

/// 从一次拖放里认出来的一张**网页图片**。
///
/// 和 [DroppedLink] 是同一个载荷的两种归宿：拖一张图写 `<img>`，拖一条链接写
/// `[标题](地址)`。认错一边都很难受——把图写成链接，正文里多一行看不懂的网址；
/// 把链接写成图，一行 `<img src=网页地址>` 加载不出来，只剩一块破图。
class DroppedImage {
  const DroppedImage({required this.url, this.alt});

  /// 已经规范成 `http`/`https` 的图片地址。
  final String url;

  /// 页面上那张图的 `alt`；没有、或者看着像个地址时是 `null`。
  final String? alt;

  @override
  bool operator ==(Object other) =>
      other is DroppedImage && other.url == url && other.alt == alt;

  @override
  int get hashCode => Object.hash(url, alt);

  @override
  String toString() => 'DroppedImage($url, alt: $alt)';
}

/// 把一次拖放的载荷认成一张图片；不是图片时返回 `null`。
///
/// 判据按可靠程度排：
/// 1. **HTML 里有 `<img src>`**——浏览器拖图片元素时给的就是这个，最准。`src`
///    是相对地址时按系统 URL 补全（很多站点写 `/img/a.png`）。
/// 2. **地址本身就是一张图**（`.jpg` / `.png` 之类），而且 HTML 里没有指向同一
///    处的锚点——拖一个指向图片的链接、或从图片站点的地址栏拖下来都算。
/// 3. 其余交给 [parseDroppedLink]：认不出图就还是链接。
///
/// 只有「能写进 `<img src>` 的地址」才算图：`data:`、`blob:` 这两种拖出来的是
/// 一段内存里的数据，写进笔记也加载不出来，宁可退回链接让用户自己决定。
DroppedImage? parseDroppedImage({
  String? uri,
  String? html,
  String? plainText,
}) {
  final String? markup = html == null ? null : _repairPackedUtf8(html);

  final DroppedImage? inline = _imageFromHtml(markup, uri);
  if (inline != null) return inline;

  // HTML 里没有图，就看地址本身像不像一张图。纯文本超过一行是「一段文字」，
  // 不是链接也不是图——和 [parseDroppedLink] 同一条规矩。
  final List<String> lines = _lines(plainText).toList();
  String? candidate = _cleanUrl(uri);
  if (candidate == null && lines.length <= 1) {
    candidate = lines.isEmpty ? null : _cleanUrl(lines.first);
  }
  if (candidate == null || !_looksLikeImageUrl(candidate)) return null;
  // 同一个地址在 HTML 里是个锚点：拖的是链接，不是图。
  if (_anchorHrefMatches(markup, candidate)) return null;
  return DroppedImage(url: candidate);
}

/// 写进正文的那一行：`<img src="…">`（带 `alt` 时一起写）。
///
/// 和粘贴图片走同一种写法——同一份文件里，一张图不该有两种长相。宽度不写：
/// 网页图片的原始尺寸千奇百怪，让正文列去约束它，比抄一个 `width=` 稳。
String markdownImageFor(DroppedImage image) => ImageMarkup(
  source: image.url,
  alt: image.alt,
).toMarkdown(asTag: true);

/// 把一次拖放的载荷读成一段可以直接写进正文的纯文本；没有文字时返回 `null`。
///
/// 拖进来的东西只有一部分该变成链接，其余——选中的一段网页文字、一段代码、
/// 一个文件名——都该**原样**落进 `.md`：和 Ctrl+V 完全一致，不替用户转义
/// Markdown 记号（拖进来的 `*强调*` 就是强调，源文件里也该是 `*强调*`）。
///
/// [html] 是富文本拖放（浏览器里选中一段拖过来）的另一份载荷：纯文本缺失或
/// 为空时按块级标签折行读成文字，比丢掉整段内容好。[file] 表示这是一次
/// **文件**拖放（系统给了 `file://`），文件名不是正文，直接放弃。
String? parseDroppedText({
  String? html,
  String? plainText,
  bool file = false,
}) {
  if (file) return null;
  final String? text = _normalizeDroppedText(plainText);
  if (text != null) return text;
  return _normalizeDroppedText(_plainFromHtml(html));
}

/// 把 [markdown] 插到 [offset] 处，光标停在它后面。
///
/// 纯函数：编辑器只管把它交给控制器，撤销、重排都走既有的那条路。
TextEditingValue insertDroppedLink(
  TextEditingValue value,
  int offset,
  String markdown,
) {
  final String text = value.text;
  final int at = offset.clamp(0, text.length);
  return TextEditingValue(
    text: text.replaceRange(at, at, markdown),
    selection: TextSelection.collapsed(offset: at + markdown.length),
  );
}

// ------------------------------------------------------------------ 调试输出

/// 调试输出用：把一次拖放的 HTML 载荷还原成能读的样子，并截断到 [max] 个字符。
///
/// 日志里直接打原始载荷就是满屏乱码——那恰恰是 [parseDroppedLink] 内部会修好的
/// 东西，原样打出来只会让人以为出了错（用户就真的把日志当成正文里的乱码来问过
/// 一次：「这个是什么？正常的吗？」）。
String describeDroppedHtml(String html, {int max = 400}) =>
    clipForLog(_repairPackedUtf8(html), max: max);

/// 调试输出用：日志里放不下一整段载荷，截断到 [max] 个字符并标出总长。
String clipForLog(String text, {int max = 400}) => text.length <= max
    ? text
    : '${text.substring(0, max)}…（共 ${text.length} 字符）';

// ------------------------------------------------------------------ helpers

/// 修「UTF-8 字节被当成 UTF-16 解」的乱码。
///
/// `super_clipboard` 0.9.1 在 Windows 上把浏览器的 `text/html`（UTF-8）按 UTF-16
/// 解了一遍：每个 UTF-8 字节对拼成一个 U+XXYY 字符，`<a data-v-…>游戏中心</a>`
/// 变成 `愼搠瑡ⵡ…㰾룦辈룤莿⼼㹡`，锚点正则自然一条都找不到，标题只能退回域名。
///
/// 判据是 `<`：真正的 HTML 一定有标签，而乱码里永远没有 `<`（0x3C 会和下一个
/// 字节拼成一个汉字）。确认是乱码后，把每个字符拆回两个字节、按 UTF-8 重解。
String _repairPackedUtf8(String html) {
  if (html.isEmpty || html.contains('<')) return html;
  final List<int> bytes = <int>[];
  for (final int unit in html.codeUnits) {
    bytes.add(unit & 0xFF);
    bytes.add((unit >> 8) & 0xFF);
  }
  // 末尾可能留着一个补零的高位字节。
  while (bytes.isNotEmpty && bytes.last == 0) {
    bytes.removeLast();
  }
  try {
    final String decoded = utf8.decode(bytes);
    return decoded.contains('<') ? decoded : html;
  } on FormatException {
    return html;
  }
}

/// 只认能交给浏览器的地址：`http` / `https`，`www.` 补上 `https://`。
String? _cleanUrl(String? raw) {
  if (raw == null) return null;
  String url = raw.trim();
  if (url.isEmpty) return null;
  // uri-list 一行一个地址；粘贴过来的还可能带引号或尖括号。
  url = url.split(RegExp(r'[\r\n]')).first.trim();
  url = url.replaceAll(RegExp(r'^[<"“”]+|[>"“”]+$'), '').trim();
  if (url.isEmpty) return null;
  if (RegExp(r'^www\.', caseSensitive: false).hasMatch(url)) {
    url = 'https://$url';
  }
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null) return null;
  final String scheme = parsed.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (parsed.host.isEmpty) return null;
  return url;
}

String? _hostLabel(String url) {
  final String host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return null;
  return host.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
}

Iterable<String> _lines(String? text) =>
    (text ?? '').split(RegExp(r'[\r\n]+')).where((String l) => l.trim().isNotEmpty);

/// 标题：压成一行、去掉多余空白；看着像地址的不算标题。
String? _cleanTitle(String? raw) {
  if (raw == null) return null;
  final String text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  if (_cleanUrl(text) != null) return null;
  return text;
}

/// 纯文本里第一行「不像地址」的文字，当作标题。
///
/// 有些拖放只带 URL 和一段文字（没有 HTML），那行文字往往就是链接的显示
/// 文字——比域名好看得多。
String? _titleLine(List<String> lines) {
  for (final String line in lines) {
    final String? title = _cleanTitle(line);
    if (title != null) return title;
  }
  return null;
}

/// 归一拖进来的文字：统一换行、去掉首尾的空行与 BOM。
///
/// 只动「边界」，不动正文——中间的换行、缩进、行尾空格都是用户拖过来的东西，
/// 编辑器没有资格替它删。全是空白就当作没拖进来文字。
String? _normalizeDroppedText(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  String text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceFirst(RegExp(r'^\uFEFF'), '');
  // 拖一个「整行」过来时，末尾那个换行是拖拽边界，不是要插进来的空行。
  text = text.replaceFirst(RegExp(r'^\n+'), '');
  text = text.replaceFirst(RegExp(r'\n+$'), '');
  if (text.trim().isEmpty) return null;
  return text;
}

/// 富文本拖放降级成文字：块级标签折行，行内标签拆成空格。
///
/// 只在纯文本那份载荷缺失时用（Safari 之类只给 `public.html` 的场合）。
/// 折行点按「段落」而不是按「标签」取：`<p>` 之间要空一行，`<br>` 只换行。
String? _plainFromHtml(String? html) {
  if (html == null || html.isEmpty) return null;
  String text = _repairPackedUtf8(html);
  if (!text.contains('<')) return null;
  text = text
      // 脚本和样式不是正文，先整段摘掉，否则它们的内容会漏进文字里。
      .replaceAll(
        RegExp(
          r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(r'</(p|div|h[1-6]|blockquote|pre|tr)\s*>', caseSensitive: false),
        '\n\n',
      )
      .replaceAll(RegExp(r'</(li|dt|dd|td|th)\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), ' ');
  text = _unescapeEntities(text);
  final List<String> lines = <String>[];
  for (final String line in text.split('\n')) {
    // 浏览器里的换行在 HTML 里是空白，折行只由标签决定。
    final String cleaned = line
        .replaceAll(RegExp(r'[ \t\u00A0]+'), ' ')
        .trim();
    if (cleaned.isEmpty && (lines.isEmpty || lines.last.isEmpty)) continue;
    lines.add(cleaned);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return null;
  return lines.join('\n');
}

/// 解开 HTML 实体：常见命名实体 + 十进制/十六进制数字引用。
String _unescapeEntities(String text) {
  const Map<String, String> named = <String, String>{
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&nbsp;': '\u00A0',
  };
  String out = text;
  named.forEach((String from, String to) => out = out.replaceAll(from, to));
  return out.replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|[0-9]+);'), (
    Match m,
  ) {
    final String body = m.group(1)!;
    final int? code = body.startsWith('x') || body.startsWith('X')
        ? int.tryParse(body.substring(1), radix: 16)
        : int.tryParse(body);
    if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(code);
  });
}

String _escapeLabel(String label) => label
    .replaceAll('\n', ' ')
    .replaceAll('[', '\\[')
    .replaceAll(']', '\\]');

String _escapeUrl(String url) => url
    .replaceAll(' ', '%20')
    .replaceAll('(', '%28')
    .replaceAll(')', '%29');

// ------------------------------------------------------------- 图片的判据

final RegExp _imgRe = RegExp(
  r'<img\b[^>]*>',
  caseSensitive: false,
  dotAll: true,
);

/// HTML 里第一张**能拿出可用地址**的 `<img>`。
///
/// 一个 `<img>` 上的候选地址要按顺序试：`src` 最正，但懒加载的站点把真地址放
/// 在 `data-src` / `data-original`，`src` 只是一张 `data:` 占位图；`srcset` 里
/// 则是「地址 2x, 地址 3x」。某一个候选是 `data:` 不代表这张图不能用，所以
/// 逐个解析，第一个解得出的才算数。
DroppedImage? _imageFromHtml(String? html, String? base) {
  if (html == null || html.isEmpty) return null;
  for (final RegExpMatch m in _imgRe.allMatches(html)) {
    final String tag = m.group(0)!;
    final String? alt = _cleanTitle(_attr(tag, 'alt'));
    final List<String?> candidates = <String?>[
      _attr(tag, 'src'),
      _attr(tag, 'data-src'),
      _attr(tag, 'data-original'),
      _firstSrcset(_attr(tag, 'srcset')),
    ];
    for (final String? candidate in candidates) {
      if (candidate == null) continue;
      final String? url = _resolveImageUrl(candidate, base);
      if (url != null) return DroppedImage(url: url, alt: alt);
    }
  }
  return null;
}

/// 取一个标签里某个属性的值，解掉实体；没有这个属性返回 `null`。
///
/// 名字前面只认空白，不认 `\b`：`\bsrc` 会把 `data-src` 也一起匹配上，懒加载
/// 的站点于是拿到的是一张占位图。
String? _attr(String tag, String name) {
  final RegExp re = RegExp(
    r'(?:^|\s)' + RegExp.escape(name) + r'''\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );
  final RegExpMatch? m = re.firstMatch(tag);
  if (m == null) return null;
  return _unescapeEntities(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');
}

/// `srcset` 里第一个候选地址：`a.png 1x, b.png 2x` 取 `a.png`。
String? _firstSrcset(String? srcset) {
  if (srcset == null || srcset.trim().isEmpty) return null;
  final String first = srcset.split(',').first.trim();
  if (first.isEmpty) return null;
  return first.split(RegExp(r'\s+')).first;
}

/// 把 `<img src>` 变成能写进笔记的绝对地址。
///
/// 绝对地址直接用；相对的按这次拖放的系统 URL 补全（浏览器给的 `src` 常常是
/// `/img/a.png`）；`data:` / `blob:` 是一段内存里的数据，写进笔记加载不出来，
/// 当作没有地址。
String? _resolveImageUrl(String src, String? base) {
  final String raw = src.trim();
  if (raw.isEmpty) return null;
  final String lower = raw.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('blob:')) return null;
  final String? direct = _cleanUrl(raw);
  if (direct != null) return direct;
  final String? origin = _cleanUrl(base);
  if (origin == null) return null;
  try {
    final Uri? resolved = Uri.tryParse(origin)?.resolve(raw);
    return resolved == null ? null : _cleanUrl(resolved.toString());
  } on FormatException {
    return null;
  }
}

const List<String> _imageExtensions = <String>[
  '.png',
  '.jpg',
  '.jpeg',
  '.jfif',
  '.gif',
  '.webp',
  '.bmp',
  '.svg',
  '.avif',
  '.ico',
  '.tif',
  '.tiff',
];

/// 地址本身是不是一张图：看路径扩展名，其次看查询参数里有没有 `format=webp`
/// 这种图床写法。
bool _looksLikeImageUrl(String url) {
  final Uri? parsed = Uri.tryParse(url);
  if (parsed == null) return false;
  final String path = parsed.path.toLowerCase();
  for (final String ext in _imageExtensions) {
    if (path.endsWith(ext)) return true;
  }
  final String query = parsed.query.toLowerCase();
  return RegExp(
    r'(?:^|&)(?:format|fm|type|ext)=(?:png|jpe?g|gif|webp|avif|bmp|svg)',
  ).hasMatch(query);
}

/// HTML 里有没有指向 [url] 的锚点。
///
/// 有，说明这次拖的是**链接**：`<a href="https://x/a.jpg">看图</a>` 拖出来也是
/// 一条 `.jpg` 地址，但用户要的是链接，不是把这张图贴进正文。
bool _anchorHrefMatches(String? html, String url) {
  if (html == null || html.isEmpty) return false;
  final Uri? base = Uri.tryParse(url);
  if (base == null) return false;
  for (final RegExpMatch m in _anchorRe.allMatches(html)) {
    final String href = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
    if (href.isEmpty) continue;
    final Uri? resolved;
    try {
      resolved = base.resolve(href);
    } on FormatException {
      continue;
    }
    if (_samePath(resolved.toString(), url)) return true;
  }
  return false;
}

bool _samePath(String a, String b) => _trimSlash(a) == _trimSlash(b);

String _trimSlash(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;

class _Anchor {
  const _Anchor(this.href, this.label);

  final String href;
  final String label;
}

final RegExp _anchorRe = RegExp(
  r'''<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a>''',
  caseSensitive: false,
  dotAll: true,
);

/// HTML 里第一个有文字的锚点。
_Anchor? _firstAnchor(String? html) {
  if (html == null || html.isEmpty) return null;
  for (final RegExpMatch m in _anchorRe.allMatches(html)) {
    final String href = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
    if (href.isEmpty) continue;
    return _Anchor(href, _htmlText(m.group(4) ?? ''));
  }
  return null;
}

/// HTML 里跟 [url] 同属一个地址的那个锚点的文字。
///
/// 浏览器给的 href 往往不是完整 URL：站点导航里 `//game.bilibili.com/platform`
/// （省协议）、`/platform`（相对）都常见，所以先按 [url] 解析再比，比的是
/// host + path——带追踪参数的 `?spm_id_from=…` 也算同一条。整段 HTML 里只有
/// 一个同站锚点时直接用它：拖的本来就是那一个链接，路径对不上也认。
String? _anchorLabelFor(String? html, String url) {
  if (html == null || html.isEmpty) return null;
  final Uri? base = Uri.tryParse(url);
  if (base == null || base.host.isEmpty) return null;
  String? sameSite;
  int sameSiteCount = 0;
  for (final RegExpMatch m in _anchorRe.allMatches(html)) {
    final String href = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
    if (href.isEmpty) continue;
    final String label = _htmlText(m.group(4) ?? '');
    if (label.isEmpty) continue;
    final Uri? resolved;
    try {
      resolved = base.resolve(href);
    } on FormatException {
      continue;
    }
    final String scheme = resolved.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') continue;
    if (resolved.host != base.host) continue;
    if (_samePath(resolved.path, base.path)) return label;
    sameSite ??= label;
    sameSiteCount++;
  }
  return sameSiteCount == 1 ? sameSite : null;
}

/// 锚文本去掉标签、解开常见实体。
String _htmlText(String html) {
  final String text = _unescapeEntities(
    html.replaceAll(RegExp(r'<[^>]*>'), ' '),
  );
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}
