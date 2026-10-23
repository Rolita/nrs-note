import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nrs/core/utils/markdown_actions.dart';

TextEditingValue _value(String text, int start, [int? end]) =>
    TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end ?? start),
    );

void main() {
  test('替换选区，一次编辑写入渲染结果', () {
    final TextEditingValue result = insertTemplateText('# 日报')(_value(
      '前文【旧占位】后文',
      2,
      7,
    ));

    expect(result.text, '前文# 日报后文');
    expect(result.selection.isCollapsed, isTrue);
    expect(result.selection.baseOffset, 2 + '# 日报'.length);
  });

  test('tp.file.cursor 的位置决定落点', () {
    final TextEditingValue result = insertTemplateText(
      '标题\n正文\n',
      cursorOffset: 3,
    )(_value('', 0));

    expect(result.text, '标题\n正文\n');
    expect(result.selection.baseOffset, 3, reason: '光标落在「标题」之后');
  });

  test('越界的光标标记被夹在插入内容内，不会跳进后面的正文', () {
    final TextEditingValue result = insertTemplateText(
      '短模板',
      cursorOffset: 999,
    )(_value('前面后面', 2));

    expect(result.selection.baseOffset, 2 + '短模板'.length);
    expect(result.selection.baseOffset, lessThanOrEqualTo(result.text.length));
  });

  test('模板结果为空时选区被删除，光标停在原处', () {
    final TextEditingValue result = insertTemplateText('')(_value('甲乙丙', 1, 2));

    expect(result.text, '甲丙');
    expect(result.selection.baseOffset, 1);
  });
}
