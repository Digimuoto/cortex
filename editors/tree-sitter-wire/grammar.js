/**
 * Tree-sitter grammar for the Wire language.
 *
 * Source of truth: docs/Reference/Wire/grammar.md. Mirrors the Haskell parser
 * at src/Cortex/Wire/Parser.hs.
 *
 * Top-level forms: contract, use, kind, form, node, let/export let, import,
 * and optional file-return expression.
 * Executor values: @qualified.name { config }
 * Executor calls:  @qualified.name { config } (input) | configured (input)
 * Pure outputs:    -> label: Contract = <CorePure expr> ;
 * Graph operators: <> (overlay), => (connect), * (record↔ports adapter).
 *                  Overlay binds tighter than connect and star.
 * Value operators: // (record merge), ++ (string/list concat)
 * Port clauses:    <- label: Contract ; | -> label: Contract ;
 * Literals:        "..." single-line, ''...'' indented multi-line,
 *                  decimal numbers, true/false/null, ()
 * Line comments:   #
 * Block comments:  slash-star ... star-slash (non-nesting)
 */

const PREC = {
  topology_connect: 1,
  topology_overlay: 2,
  select: 4,
  merge: 5,
  core_lambda: 1,
  core_pipe: 2,
  core_merge: 3,
  core_or: 4,
  core_and: 5,
  core_compare: 6,
  core_add: 7,
  core_mul: 8,
  core_unary: 9,
  core_call: 10,
  core_postfix: 11,
};

module.exports = grammar({
  name: 'wire',

  extras: $ => [
    /\s+/,
    $.line_comment,
    $.block_comment,
  ],

  word: $ => $.identifier,

  conflicts: $ => [
    [$.core_pure_record, $.record],
    [$.core_pure_list, $.list],
    [$._core_pure_atom, $._expr_atom],
    [$._core_pure_atom, $.qualified_ident],
  ],

  rules: {
    source_file: $ => seq(
      repeat($._top_form),
      optional(field('file_return', $.expression)),
    ),

    _top_form: $ => choice(
      $.contract_decl,
      $.use_stmt,
      $.kind_decl,
      $.form_decl,
      $.node_decl,
      $.let_binding,
      $.import_stmt,
    ),

    contract_decl: $ => seq(
      'contract',
      field('name', $.contract_name),
      ';',
    ),

    use_stmt: $ => seq(
      'use',
      field('namespace', $.use_namespace),
      '.',
      '{',
      field('items', seq(
        $.use_item,
        repeat(seq(',', $.use_item)),
        optional(','),
      )),
      '}',
      ';',
    ),

    use_item: $ => choice(
      $.use_executor_item,
      $.use_contract_item,
    ),

    use_executor_item: $ => seq(
      '@',
      field('name', $.identifier),
      optional(seq(
        'as',
        '@',
        field('alias', $.identifier),
      )),
    ),

    use_contract_item: $ => seq(
      field('name', $.identifier),
      optional(seq(
        'as',
        field('alias', $.identifier),
      )),
    ),

    use_namespace: _ => token(/[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*/),

    let_binding: $ => seq(
      optional(field('visibility', 'export')),
      'let',
      field('name', $.identifier),
      '=',
      field('value', choice($.make_application, $.form_application, $.core_pure_expr, $.expression)),
      ';',
    ),

    import_stmt: $ => seq(
      'import',
      choice(
        field('binding', $.identifier),
        seq(
          '{',
          optional(seq(
            $.identifier,
            repeat(seq(',', $.identifier)),
            optional(','),
          )),
          '}',
        ),
      ),
      'from',
      field('path', $.string),
      ';',
    ),

    kind_decl: $ => seq(
      'kind',
      field('name', $.identifier),
      '(',
      optional(field('params', seq(
        $.kind_param,
        repeat(seq(',', $.kind_param)),
        optional(','),
      ))),
      ')',
      '=',
      field('inputs', repeat($.input_clause)),
      field('body', choice(
        $.pure_body,
        $.executor_single_output_body,
        $.executor_body,
      )),
      optional(field('where', $.where_clause)),
    ),

    kind_param: $ => seq(
      field('name', $.identifier),
      ':',
      field('class', $.kind_param_class),
    ),

    kind_param_class: _ => choice(
      'PortLabel',
      'Contract',
      'Value',
      'ConfiguredExecutor',
    ),

    form_decl: $ => seq(
      'form',
      field('name', $.identifier),
      '(',
      optional(field('params', seq(
        $.form_param,
        repeat(seq(',', $.form_param)),
        optional(','),
      ))),
      ')',
      '=',
      '{',
      field('items', repeat($.form_item)),
      field('result', $.expression),
      ';',
      '}',
      ';',
    ),

    form_item: $ => choice(
      $.node_decl,
      $.form_let_binding,
    ),

    form_let_binding: $ => seq(
      'let',
      field('name', $.identifier),
      '=',
      field('value', choice($.make_application, $.form_application, $.core_pure_expr, $.expression)),
      ';',
    ),

    form_param: $ => seq(
      field('name', $.identifier),
      ':',
      field('class', $.form_param_class),
    ),

    form_param_class: _ => choice(
      'PortLabel',
      'Contract',
      'Value',
      'Graph',
      'ConfiguredExecutor',
    ),

    node_decl: $ => seq(
      'node',
      field('name', $.identifier),
      choice(
        seq(
          '=',
          field('kind', $.kind_application),
          ';',
        ),
        seq(
          field('inputs', repeat($.input_clause)),
          field('body', choice(
            $.pure_body,
            $.executor_single_output_body,
            $.executor_body,
          )),
          optional(field('where', $.where_clause)),
        ),
      ),
    ),

    kind_application: $ => seq(
      field('name', $.identifier),
      '(',
      optional(field('args', seq(
        $.expression,
        repeat(seq(',', $.expression)),
        optional(','),
      ))),
      ')',
    ),

    form_application: $ => prec(PREC.core_call + 1, seq(
      field('name', $.identifier),
      '(',
      optional(field('args', seq(
        $.expression,
        repeat(seq(',', $.expression)),
        optional(','),
      ))),
      ')',
    )),

    make_application: $ => seq(
      'make',
      '(',
      field('count', $.number),
      ',',
      field('kind', $.identifier),
      optional(','),
      ')',
    ),

    input_clause: $ => seq(
      '<-',
      field('label', $.identifier),
      ':',
      field('contract', $.contract_name),
      ';',
    ),

    pure_body: $ => repeat1($.pure_output_equation),

    pure_output_equation: $ => seq(
      '->',
      field('output', $.output_variant),
      '=',
      field('body', $.pure_output_expr),
      ';',
    ),

    pure_output_expr: $ => field('expr', $.core_pure_expr),

    executor_single_output_body: $ => seq(
      '->',
      field('output', $.output_variant),
      '=',
      field('call', $.inline_executor_call),
      ';',
    ),

    executor_body: $ => seq(
      field('outputs', repeat($.executor_output_clause)),
      '=',
      field('call', $.executor_call),
      ';',
    ),

    executor_output_clause: $ => seq(
      '->',
      field('output', $.output_body),
      ';',
    ),

    output_body: $ => choice(
      prec(1, seq(
        $.output_variant,
        repeat1(seq('|', $.output_variant)),
      )),
      $.output_variant,
    ),

    output_variant: $ => seq(
      field('label', $.identifier),
      ':',
      field('contract', $.contract_name),
    ),

    executor_call: $ => choice(
      $.inline_executor_call,
      $.configured_executor_call,
    ),

    inline_executor_call: $ => seq(
      '@',
      field('name', $.qualified_ident),
      optional(field('config', $.record)),
      '(',
      field('input', $.core_pure_expr),
      ')',
    ),

    configured_executor_call: $ => seq(
      field('name', $.identifier),
      '(',
      field('input', $.core_pure_expr),
      ')',
    ),

    where_clause: $ => seq(
      'where',
      field('expr', $.core_pure_expr),
      ';',
    ),

    contract_name: $ => alias($.identifier, $.contract),

    expression: $ => choice(
      $.topology_expression,
      $.select_expression,
      $.merge_expression,
      $._expr_atom,
    ),

    topology_expression: $ => choice(
      $._connect_expression,
      $._overlay_expression,
    ),

    _connect_expression: $ => prec.left(PREC.topology_connect, seq(
      field('left', choice($._connect_expression, $._overlay_expression, $.select_expression, $.merge_expression, $._expr_atom)),
      field('op', choice('=>', '*')),
      field('right', choice($._overlay_expression, $.select_expression, $.merge_expression, $._expr_atom)),
    )),

    _overlay_expression: $ => prec.left(PREC.topology_overlay, seq(
      field('left', choice($._overlay_expression, $.select_expression, $.merge_expression, $._expr_atom)),
      field('op', '<>'),
      field('right', choice($.select_expression, $.merge_expression, $._expr_atom)),
    )),

    select_expression: $ => prec.left(PREC.select, seq(
      field('selector', choice($.select_expression, $.merge_expression, $._expr_atom)),
      field('suffix', $.select_suffix),
    )),

    select_suffix: $ => seq(
      'select',
      '(',
      $.select_arm,
      repeat(seq(',', $.select_arm)),
      optional(','),
      ')',
    ),

    select_arm: $ => seq(
      field('key', $.identifier),
      ':',
      field('body', $.expression),
    ),

    merge_expression: $ => prec.left(PREC.merge, seq(
      field('left', choice($.merge_expression, $._expr_atom)),
      field('op', choice('//', '++')),
      field('right', $._expr_atom),
    )),

    _expr_atom: $ => choice(
      $.configured_executor_value,
      $.constructor_expr,
      $.record,
      $.list,
      $.string,
      $.indented_string,
      $.number,
      $.boolean,
      $.unit,
      $.paren_expression,
      alias($.qualified_ident, $.ident_ref),
    ),

    configured_executor_value: $ => seq(
      '@',
      field('name', $.qualified_ident),
      field('config', $.record),
    ),

    constructor_expr: $ => prec(1, seq(
      field('name', $.qualified_ident),
      field('body', $.record),
    )),

    record: $ => seq(
      '{',
      repeat(seq(choice($.field, $.inherit_field), ';')),
      '}',
    ),

    field: $ => seq(
      field('path', $.field_path),
      '=',
      field('value', $.expression),
    ),

    inherit_field: $ => seq(
      'inherit',
      repeat1(field('name', $.identifier)),
    ),

    field_path: $ => seq(
      $.identifier,
      repeat(seq('.', $.identifier)),
    ),

    list: $ => seq(
      '[',
      optional(seq(
        $.expression,
        repeat(seq(',', $.expression)),
        optional(','),
      )),
      ']',
    ),

    paren_expression: $ => seq(
      '(',
      $.expression,
      ')',
    ),

    core_pure_binding: $ => seq(
      field('name', $.identifier),
      '=',
      field('value', $.core_pure_expr),
      ';',
    ),

    core_pure_expr: $ => choice(
      $.core_pure_let,
      $.core_pure_if,
      $.core_pure_lambda,
      $.core_pure_pipe,
      $._core_pure_merge,
    ),

    core_pure_let: $ => seq(
      'let',
      repeat1($.core_pure_binding),
      'in',
      field('body', $.core_pure_expr),
    ),

    core_pure_if: $ => seq(
      'if',
      field('condition', $.core_pure_expr),
      'then',
      field('then', $.core_pure_expr),
      'else',
      field('else', $.core_pure_expr),
    ),

    core_pure_lambda: $ => prec.right(PREC.core_lambda, seq(
      repeat1(seq(field('param', $.identifier), ':')),
      field('body', $.core_pure_expr),
    )),

    core_pure_pipe: $ => prec.left(PREC.core_pipe, seq(
      field('left', choice($.core_pure_pipe, $._core_pure_merge)),
      '|>',
      field('right', $._core_pure_merge),
    )),

    _core_pure_merge: $ => choice(
      prec.left(PREC.core_merge, seq(
        field('left', $._core_pure_merge),
        field('op', '//'),
        field('right', $._core_pure_or),
      )),
      $._core_pure_or,
    ),

    _core_pure_or: $ => choice(
      prec.left(PREC.core_or, seq(
        field('left', $._core_pure_or),
        field('op', '||'),
        field('right', $._core_pure_and),
      )),
      $._core_pure_and,
    ),

    _core_pure_and: $ => choice(
      prec.left(PREC.core_and, seq(
        field('left', $._core_pure_and),
        field('op', '&&'),
        field('right', $._core_pure_compare),
      )),
      $._core_pure_compare,
    ),

    _core_pure_compare: $ => choice(
      prec.left(PREC.core_compare, seq(
        field('left', $._core_pure_compare),
        field('op', choice('==', '!=', '<=', '>=', '<', '>')),
        field('right', $._core_pure_add),
      )),
      $._core_pure_add,
    ),

    _core_pure_add: $ => choice(
      prec.left(PREC.core_add, seq(
        field('left', $._core_pure_add),
        field('op', choice('+', '-')),
        field('right', $._core_pure_mul),
      )),
      $._core_pure_mul,
    ),

    _core_pure_mul: $ => choice(
      prec.left(PREC.core_mul, seq(
        field('left', $._core_pure_mul),
        field('op', choice('*', '/')),
        field('right', $._core_pure_unary),
      )),
      $._core_pure_unary,
    ),

    _core_pure_unary: $ => choice(
      prec.right(PREC.core_unary, seq(
        field('op', choice('!', '-')),
        field('expr', $._core_pure_unary),
      )),
      $._core_pure_call,
    ),

    _core_pure_call: $ => choice(
      prec.left(PREC.core_call, seq(
        field('function', $._core_pure_call),
        field('argument', $._core_pure_postfix),
      )),
      $._core_pure_postfix,
    ),

    _core_pure_postfix: $ => choice(
      prec.left(PREC.core_postfix, seq(
        field('target', $._core_pure_postfix),
        '.',
        field('field', $.identifier),
      )),
      prec.left(PREC.core_postfix, seq(
        field('target', $._core_pure_postfix),
        '[',
        field('index', $.core_pure_expr),
        ']',
      )),
      $._core_pure_atom,
    ),

    _core_pure_atom: $ => choice(
      $.string,
      $.indented_string,
      $.number,
      $.boolean,
      $.null,
      $.core_pure_record,
      $.core_pure_list,
      seq('(', $.core_pure_expr, ')'),
      alias($.identifier, $.core_pure_ident),
    ),

    core_pure_record: $ => seq(
      '{',
      repeat(seq(choice($.core_pure_field, $.inherit_field), ';')),
      '}',
    ),

    core_pure_field: $ => seq(
      field('path', $.field_path),
      '=',
      field('value', $.core_pure_expr),
    ),

    core_pure_list: $ => seq(
      '[',
      optional(seq(
        $.core_pure_expr,
        repeat(seq(',', $.core_pure_expr)),
        optional(','),
      )),
      ']',
    ),

    qualified_ident: $ => seq(
      $.identifier,
      repeat(seq('.', $.identifier)),
    ),

    string: $ => seq(
      token('"'),
      repeat(choice(
        $.escape_sequence,
        $._string_interpolation,
        $._string_content,
      )),
      token.immediate('"'),
    ),

    indented_string: $ => seq(
      token("''"),
      repeat(choice(
        $._indented_string_interpolation,
        $._indented_string_content,
        $._indented_string_single_quote,
      )),
      token.immediate("''"),
    ),

    escape_sequence: _ => token.immediate(seq('\\', /[ntr"\\$]/)),
    _string_interpolation: _ => token.immediate(prec(2, /\$\{[^}\n\r]*\}/)),
    _string_content: _ => token.immediate(prec(1, /([^"\\\n\r$]+|\$)/)),
    _indented_string_interpolation: _ => token.immediate(prec(2, /\$\{[^}]*\}/)),
    _indented_string_content: _ => token.immediate(prec(1, /[^']+/)),
    _indented_string_single_quote: _ => token.immediate(prec(1, /'[^']/)),
    number: _ => token(/-?[0-9]+(\.[0-9]+)?/),
    boolean: _ => choice('true', 'false'),
    null: _ => 'null',
    unit: _ => seq('(', ')'),

    identifier: _ => token(/[A-Za-z_][A-Za-z0-9_]*/),

    line_comment: _ => token(prec(-1, seq('#', /.*/))),
    block_comment: _ => token(seq('/*', /([^*]|\*[^/])*/, '*/')),
  },
});
