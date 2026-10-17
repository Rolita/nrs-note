import 'dart:async';

/// Collapses a burst of calls into a single trailing invocation.
///
/// Used for auto-save so that typing does not write to disk on every keystroke.
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 600)});

  final Duration delay;
  Timer? _timer;

  bool get isPending => _timer?.isActive ?? false;

  void run(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Runs any pending action immediately (e.g. before switching notes).
  void flush(void Function() action) {
    if (!isPending) return;
    _timer?.cancel();
    _timer = null;
    action();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}

/// Formats a timestamp the way a note list wants it: relative for recent items,
/// absolute once the note has aged.
String formatRelativeTime(DateTime time) {
  final Duration diff = DateTime.now().difference(time);
  if (diff.isNegative) return '刚刚';
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime that = DateTime(time.year, time.month, time.day);
  final int dayGap = today.difference(that).inDays;
  if (dayGap == 1) return '昨天';
  if (dayGap < 7) return '$dayGap 天前';
  if (time.year == now.year) {
    return '${time.month} 月 ${time.day} 日';
  }
  return '${time.year} 年 ${time.month} 月 ${time.day} 日';
}

String formatFullTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}
