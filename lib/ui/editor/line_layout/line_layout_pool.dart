import 'dart:collection';

import 'package:flutter/material.dart';

import 'line_layout_engine.dart';

/// 跨文档挂起一份行布局的键。
///
/// 键必须包含全部影响排版的输入：文档身份（笔记 id 加外部版本）、正文、
/// 可用宽度、文本缩放、正文样式、折叠集合与标记揭示行。任何一项变了都不该
/// 命中——宁可重排一次，也不接受旧几何。
typedef LineLayoutPoolKey = ({
  String document,
  String body,
  double width,
  TextScaler textScaler,
  TextStyle style,
  String folds,
  int? markerRevealLine,
});

/// 挂起的一份布局：连同它的 painter 池与「按哪份揭示选区排出」。
///
/// painter 池必须一起搬走：`LineDocumentLayout` 里 `fromCache == true` 的行
/// 由池持有，渲染对象销毁时若把池释放掉，挂起的布局就拿着已释放的 painter。
class ParkedLineLayout {
  ParkedLineLayout({
    required this.layout,
    required this.cache,
    required this.reveal,
  });

  final LineDocumentLayout layout;
  final LineLayoutCache cache;

  /// 这份布局是按哪一份揭示选区排出来的；再次采用时用它和新选区求差分。
  final TextSelection? reveal;
}

/// 容量固定的跨文档布局缓存（LRU，最久未用的先释放）。
///
/// 切走笔记时把布局整份挂起而不是 dispose，切回时直接采用，再用 P2 的
/// 揭示签名算出要重排的少数几行。容量只保留最近两篇：长笔记的整篇布局
/// 带着每行的 `TextPainter`，留下更多份只是白占内存。
class LineLayoutPool {
  LineLayoutPool({this.capacity = 2}) : assert(capacity > 0);

  final int capacity;
  final LinkedHashMap<LineLayoutPoolKey, ParkedLineLayout> _entries =
      LinkedHashMap<LineLayoutPoolKey, ParkedLineLayout>();

  /// 被挤出去而释放的份数，供测试断言容量确实生效。
  @visibleForTesting
  int debugEvictions = 0;

  int get length => _entries.length;

  /// 挂起一份布局；同键的旧份、超容量的最久未用份都会在这里释放。
  void park(
    LineLayoutPoolKey key,
    LineDocumentLayout layout,
    LineLayoutCache cache,
    TextSelection? reveal,
  ) {
    _release(_entries.remove(key));
    _entries[key] = ParkedLineLayout(
      layout: layout,
      cache: cache,
      reveal: reveal,
    );
    while (_entries.length > capacity) {
      final LineLayoutPoolKey oldest = _entries.keys.first;
      _release(_entries.remove(oldest));
      debugEvictions++;
    }
  }

  /// 取走一份布局；命中后它就归调用方所有，池不再释放。
  ParkedLineLayout? take(LineLayoutPoolKey key) => _entries.remove(key);

  /// 释放全部挂起的布局。
  void clear() {
    for (final ParkedLineLayout entry in _entries.values) {
      _release(entry);
    }
    _entries.clear();
  }

  void dispose() => clear();

  /// 布局与 painter 池的所有权在这里终结：非池化 painter 由布局释放，
  /// 池化 painter 由池释放，两者互不重叠。
  void _release(ParkedLineLayout? entry) {
    if (entry == null) return;
    entry.layout.dispose();
    entry.cache.dispose();
  }
}
