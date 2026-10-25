import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/ui/canvas/canvas_history.dart';

void main() {
  group('撤销栈', () {
    test('空栈退不了也重做不了', () {
      final CanvasHistory h = CanvasHistory();
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
      expect(h.undo('现在'), isNull);
      expect(h.redo('现在'), isNull);
    });

    test('记一步就能退一步，退完能走回来', () {
      final CanvasHistory h = CanvasHistory();
      h.push('A');
      expect(h.canUndo, isTrue);

      expect(h.undo('B'), 'A');
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isTrue);

      expect(h.redo('A'), 'B');
      expect(h.canRedo, isFalse);
      expect(h.canUndo, isTrue);
    });

    test('一路退到底再一路走回来', () {
      final CanvasHistory h = CanvasHistory();
      h.push('1');
      h.push('2');
      h.push('3');

      expect(h.undo('4'), '3');
      expect(h.undo('3'), '2');
      expect(h.undo('2'), '1');
      expect(h.undo('1'), isNull);

      expect(h.redo('1'), '2');
      expect(h.redo('2'), '3');
      expect(h.redo('3'), '4');
      expect(h.redo('4'), isNull);
    });

    test('新动作会作废重做栈', () {
      final CanvasHistory h = CanvasHistory();
      h.push('A');
      h.undo('B');
      expect(h.canRedo, isTrue);

      h.push('A2');
      expect(h.canRedo, isFalse, reason: '从历史中间改一笔，原来的未来不成立');
    });

    test('超过上限就丢最老的那一步', () {
      final CanvasHistory h = CanvasHistory(limit: 3);
      h.push('1');
      h.push('2');
      h.push('3');
      h.push('4');

      expect(h.undoDepth, 3);
      expect(h.undo('5'), '4');
      expect(h.undo('4'), '3');
      expect(h.undo('3'), '2');
      expect(h.undo('2'), isNull, reason: '1 已经被挤掉了');
    });

    test('clear 之后两头都空', () {
      final CanvasHistory h = CanvasHistory();
      h.push('A');
      h.undo('B');
      h.clear();

      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
    });
  });
}
