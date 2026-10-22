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
