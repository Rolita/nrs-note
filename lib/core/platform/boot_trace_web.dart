/// 浏览器里没有「启动读盘」这一段，也不该往用户的磁盘写日志。
library;

abstract final class BootTrace {
  static void mark(String label) {}

  static void watchFrames() {}

  static Future<void> flushIfSlow() async {}
}
