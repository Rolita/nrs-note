/// 图片后缀的两份清单。
///
/// 为什么是两份：文件树里给 `svg` / `heic` / `tif` 也画图片图标（它们在别的
/// 程序里确实是图片），但 Flutter 的 `Image` 解不了这三种——点开只会得到一块
/// 「这张图打不开」。所以「树里算图片」和「应用内看得见」是两件事，分开列，
/// 别为了省一个常量把 svg 塞进能看的那一份。
library;

/// 文件树认作图片的后缀，全小写。
const Set<String> kImageExtensions = <String>{
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'avif',
  'bmp',
  'svg',
  'heic',
  'tif',
  'tiff',
};

/// 应用内能真正解码出来的后缀，全小写。
///
/// 比 [kImageExtensions] 少了 `svg` / `heic` / `tif(f)`：这三种没有解码器，
/// 点了仍然交给系统程序。
const Set<String> kViewableImageExtensions = <String>{
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'avif',
  'bmp',
};

/// [name] 的后缀（不带点，小写）。没有后缀时是空串。
String imageExtensionOf(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 文件树要不要给它画图片图标。
bool isImageFileName(String name) =>
    kImageExtensions.contains(imageExtensionOf(name));

/// 应用内能不能直接看这张图。
///
/// 判不了就当「不能」：让系统程序去开，比在应用里显示一块空白强。
bool isViewableImageFileName(String name) =>
    kViewableImageExtensions.contains(imageExtensionOf(name));
