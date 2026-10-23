/// Moment-style date formatting for `tp.date.*`.
///
/// Only the tokens the template API documents are recognised; everything else
/// is copied through, so `YYYY年MM月DD日` and `[第]W[周]` read the way they were
/// written. Chinese month and weekday names match what a Chinese Moment build
/// produces, because templates copied from Obsidian expect them.
String formatNtlDate(DateTime date, String pattern) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < pattern.length) {
    final String ch = pattern[i];

    if (ch == '[') {
      final int close = pattern.indexOf(']', i + 1);
      if (close < 0) {
        out.write(pattern.substring(i + 1));
        break;
      }
      out.write(pattern.substring(i + 1, close));
      i = close + 1;
      continue;
    }
    if (ch == r'\') {
      if (i + 1 < pattern.length) {
        out.write(pattern[i + 1]);
        i += 2;
      } else {
        out.write(ch);
        i++;
      }
      continue;
    }

    final String? token = _tokenAt(pattern, i);
    if (token == null) {
      out.write(ch);
      i++;
      continue;
    }
    out.write(_renderToken(token, date));
    i += token.length;
  }
  return out.toString();
}

const List<String> _tokensLongestFirst = <String>[
  'YYYY',
  'MMMM',
  'dddd',
  'SSS',
  'MMM',
  'ddd',
  'YY',
  'MM',
  'DD',
  'HH',
  'hh',
  'mm',
  'ss',
  'M',
  'D',
  'H',
  'h',
  'm',
  's',
];

String? _tokenAt(String pattern, int at) {
  for (final String token in _tokensLongestFirst) {
    if (pattern.startsWith(token, at)) return token;
  }
  return null;
}

String _renderToken(String token, DateTime date) {
  switch (token) {
    case 'YYYY':
      return date.year.toString().padLeft(4, '0');
    case 'YY':
      return (date.year % 100).toString().padLeft(2, '0');
    case 'MMMM':
      return _monthName(date.month);
    case 'MMM':
      return '${date.month}月';
    case 'MM':
      return date.month.toString().padLeft(2, '0');
    case 'M':
      return date.month.toString();
    case 'DD':
      return date.day.toString().padLeft(2, '0');
    case 'D':
      return date.day.toString();
    case 'dddd':
      return _weekdayName(date.weekday);
    case 'ddd':
      return '周${_weekdayShort(date.weekday)}';
    case 'HH':
      return date.hour.toString().padLeft(2, '0');
    case 'H':
      return date.hour.toString();
    case 'hh':
      return _hour12(date.hour).toString().padLeft(2, '0');
    case 'h':
      return _hour12(date.hour).toString();
    case 'mm':
      return date.minute.toString().padLeft(2, '0');
    case 'm':
      return date.minute.toString();
    case 'ss':
      return date.second.toString().padLeft(2, '0');
    case 's':
      return date.second.toString();
    case 'SSS':
      return date.millisecond.toString().padLeft(3, '0');
    default:
      return token;
  }
}

int _hour12(int hour) {
  final int value = hour % 12;
  return value == 0 ? 12 : value;
}

const List<String> _months = <String>[
  '一月',
  '二月',
  '三月',
  '四月',
  '五月',
  '六月',
  '七月',
  '八月',
  '九月',
  '十月',
  '十一月',
  '十二月',
];

const List<String> _weekdays = <String>[
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];

String _monthName(int month) => _months[(month - 1).clamp(0, 11)];

String _weekdayName(int weekday) => _weekdays[(weekday - 1).clamp(0, 6)];

String _weekdayShort(int weekday) {
  const List<String> names = <String>['一', '二', '三', '四', '五', '六', '日'];
  return names[(weekday - 1).clamp(0, 6)];
}
