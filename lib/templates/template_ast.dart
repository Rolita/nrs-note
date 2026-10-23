/// Parsed form of one NRS template.
///
/// The AST is deliberately small: templates are prose with a few commands, not
/// a general-purpose program. Anything outside this shape is a syntax error the
/// user can read, never something silently ignored.
library;

class NtlTemplate {
  const NtlTemplate(this.nodes);

  final List<TemplateNode> nodes;
}

sealed class TemplateNode {
  const TemplateNode();
}

/// Literal template text, already trimmed by the surrounding whitespace
/// controls.
class TemplateText extends TemplateNode {
  const TemplateText(this.text);

  final String text;
}

/// `<% expression %>` / `<%+ expression %>`: the value joins the output.
class TemplateExpressionTag extends TemplateNode {
  const TemplateExpressionTag({
    required this.expression,
    required this.line,
    required this.column,
    required this.source,
  });

  final NtlExpression expression;
  final int line;
  final int column;
  final String source;
}

/// `<%* statements %>`: executed for its side effects (`tR += …`).
class TemplateCodeTag extends TemplateNode {
  const TemplateCodeTag({
    required this.statements,
    required this.line,
    required this.column,
    required this.source,
  });

  final List<NtlStatement> statements;
  final int line;
  final int column;
  final String source;
}

sealed class NtlExpression {
  const NtlExpression();
}

class NtlLiteral extends NtlExpression {
  const NtlLiteral(this.value);

  final Object? value;
}

class NtlVariable extends NtlExpression {
  const NtlVariable(this.name);

  final String name;
}

class NtlArrayLiteral extends NtlExpression {
  const NtlArrayLiteral(this.elements);

  final List<NtlExpression> elements;
}

class NtlUnary extends NtlExpression {
  const NtlUnary(this.operator, this.operand);

  final String operator;
  final NtlExpression operand;
}

class NtlBinary extends NtlExpression {
  const NtlBinary(this.operator, this.left, this.right);

  final String operator;
  final NtlExpression left;
  final NtlExpression right;
}

class NtlConditional extends NtlExpression {
  const NtlConditional(this.condition, this.whenTrue, this.whenFalse);

  final NtlExpression condition;
  final NtlExpression whenTrue;
  final NtlExpression whenFalse;
}

class NtlMember extends NtlExpression {
  const NtlMember(this.object, this.name);

  final NtlExpression object;
  final String name;
}

class NtlCall extends NtlExpression {
  const NtlCall(this.callee, this.arguments);

  final NtlExpression callee;
  final List<NtlExpression> arguments;
}

/// `await` is accepted because Templater examples carry it; every built-in
/// call is awaited anyway, so it changes nothing at run time.
class NtlAwait extends NtlExpression {
  const NtlAwait(this.expression);

  final NtlExpression expression;
}

sealed class NtlStatement {
  const NtlStatement();
}

class NtlVariableDeclaration extends NtlStatement {
  const NtlVariableDeclaration({
    required this.name,
    required this.isConst,
    this.initializer,
  });

  final String name;
  final bool isConst;
  final NtlExpression? initializer;
}

class NtlAssignment extends NtlStatement {
  const NtlAssignment({
    required this.name,
    required this.operator,
    required this.value,
  });

  final String name;
  final String operator;
  final NtlExpression value;
}

class NtlIf extends NtlStatement {
  const NtlIf({
    required this.condition,
    required this.thenBranch,
    required this.elseBranch,
  });

  final NtlExpression condition;
  final List<NtlStatement> thenBranch;
  final List<NtlStatement> elseBranch;
}

class NtlExpressionStatement extends NtlStatement {
  const NtlExpressionStatement(this.expression);

  final NtlExpression expression;
}
