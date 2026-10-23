/// A template could not be parsed.
///
/// [line] and [column] point into the template file as the user sees it, not
/// into the tag's source, so an error can be found by opening the template.
class TemplateSyntaxError implements Exception {
  const TemplateSyntaxError(
    this.message, {
    required this.line,
    required this.column,
    this.source,
  });

  final String message;
  final int line;
  final int column;

  /// The tag text that failed, when it has already been isolated.
  final String? source;

  @override
  String toString() {
    final String where = '模板第 $line 行第 $column 列';
    final String detail = source == null || source!.trim().isEmpty
        ? ''
        : '：${source!.trim()}';
    return '$where：$message$detail';
  }
}

/// The template parsed, but evaluating it failed.
class TemplateRuntimeError implements Exception {
  const TemplateRuntimeError(
    this.message, {
    required this.line,
    required this.column,
    this.source,
  });

  final String message;
  final int line;
  final int column;
  final String? source;

  @override
  String toString() => '模板第 $line 行第 $column 列：$message';
}

/// The user dismissed a `tp.system.prompt` or `tp.system.suggester`.
///
/// A cancel is not a failure: it means the whole render stops before anything
/// is written, exactly like closing the template picker.
class TemplateCancelled implements Exception {
  const TemplateCancelled();

  @override
  String toString() => '已取消';
}
