import 'dart:io';

import 'package:flutter/scheduler.dart';

/// 启动各阶段花了多少毫秒。
///
/// 只在**启动明显偏慢**时落一个文件（`%TEMP%\nrs-boot.log`）：正常启动什么都
/// 不写，用户磁盘上不会多出一个自己没要的文件；慢的时候才有据可查——不用让
/// 用户开着控制台复现，也不用靠猜。设 `NRS_BOOT_TRACE=1` 则每次都写。
///
/// 记录的边界是「Dart 的 `main()` 进来」到「首屏画完」。引擎自己的初始化
/// （进程启动到 `main()` 之前）不在这里，那一段是 350ms 上下的固定成本，
/// 代码改不动它；能改的都在这条时间轴上。
abstract final class BootTrace {
  static final Stopwatch _watch = Stopwatch()..start();
  static final List<String> _lines = <String>[];
  static int _last = 0;
  static int _frames = 0;
  static bool _slow = false;

  /// 最后一个阶段超过这个数就算慢启动。
  static const int slowMarkMs = 600;

  /// 单帧超过这个数就算慢：建树和光栅化分开看。
  static const double slowBuildMs = 50;
  static const double slowRasterMs = 80;

  /// 设 `NRS_BOOT_TRACE=1` 就每次启动都记一份，不管快慢。
  static final bool _forced = Platform.environment['NRS_BOOT_TRACE'] == '1';

  /// 记一个阶段。
  static void mark(String label) {
    final int now = _watch.elapsedMilliseconds;
    _lines.add(
      '${now.toString().padLeft(5)}ms  '
      '+${(now - _last).toString().padLeft(4)}ms  $label',
    );
    _last = now;
    if (now > slowMarkMs) _slow = true;
  }

  /// 从零开始记一条新的时间轴（关窗口时用：那时候「启动第几毫秒」没有意义）。
  static void restart(String label) {
    _lines.clear();
    _watch.reset();
    _last = 0;
    _slow = false;
    // 墙上时间：外部计时器（点击、进程退出）只有这个能对上。
    _lines.add('wall ${DateTime.now().toIso8601String()}');
    mark(label);
  }

  /// 不管快慢都写一份。关窗口时要在进程消失之前落盘，所以不能等判定。
  static Future<void> flushNow() async {
    _lines.add('${_last}ms  total');
    await _write();
  }

  static Future<void> _write() async {
    try {
      await File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}nrs-boot.log',
      ).writeAsString(_lines.join('\n'));
    } on FileSystemException {
      // 写不下就算了：性能记录不该让启动失败。
    }
  }

  /// 记下前几帧的 build / raster 用时。
  ///
  /// 这一条决定了「数据到了但屏幕还没变」到底花在 Dart 建树还是光栅化上，
  /// 两者的修法完全不同。
  static void watchFrames() {
    SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
      for (final FrameTiming t in timings) {
        if (_frames >= 8) return;
        _frames++;
        final double build = t.buildDuration.inMicroseconds / 1000;
        final double raster = t.rasterDuration.inMicroseconds / 1000;
        if (build > slowBuildMs || raster > slowRasterMs) _slow = true;
        _lines.add(
          '        frame $_frames  build=${build.toStringAsFixed(1)}ms '
          'raster=${raster.toStringAsFixed(1)}ms',
        );
      }
    });
  }

  /// 启动偏慢时写一份记录。正常启动什么都不做。
  static Future<void> flushIfSlow() async {
    if (!_forced && !_slow) return;
    _lines.add('${_last}ms  content ready（不含进程启动到 main() 的那一段）');
    await _write();
  }
}
