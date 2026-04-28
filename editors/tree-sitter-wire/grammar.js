/**
 * Tree-sitter grammar for the Wire language.
 *
 * Source of truth: docs/Reference/Wire/grammar.md (accepted
 * 2026-04-23). Mirrors the Haskell parser at src/Cortex/Wire/Parser.hs.
 *
 * Top-level forms:          contract; node; let; CorePure helper let;
 *                           import; and optional file-return expression.
 * Executors:                @qualified.name { config }
 * Pure nodes:               -> output: Contract = pure (<CorePure expr>)
 * Graph operators:          <> (overlay, infixl 2), => (connect, infixl 3)
 * Value operators:          // (record/partial merge, infixl 5),
 *                           ++ (string/list concat, infixl 5)
 * Port signatures:          <- [label:] Contract | <- [label:] [Contract]
 *                           -> [label:] Contract | -> variant (| variant)+
 * Literals:                 "..." single-line (escapes), ''...'' multi-line
 *                           verbatim, decimal numbers, true/false, ()
 * Line comments:            #
 * Block comments:           slash-star ... star-slash (non-nesting)
 */

const PREC = {
  overlay: 2, // infixl 2 — <>
  connect: 3, // infixl 3 — =>
  select:  4, // postfix 4 — select(...)
  merge:   5, // infixl 5 — // and ++ share a level
  core_lambda: 1,
  core_or: 2,
  core_and: 3,
  core_compare: 4,
  core_add: 5,
  core_mul: 6,
  core_unary: 7,
  core_call: 8,
  core_postfix: 9,
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
    // Port-label-with-colon vs bare contract: `<- label: Contract` vs
    // `<- Contract`. Both start with an identifier; the `:` is the
    // discriminator. Tree-sitter lookahead resolves this.
    [$.labeled_port_prefix, $._identifier_ref],
    [$.pure_node_decl, $.port_signature],
    [$.pure_output_port, $.output_body],
  ],

  rules: {
    // ─── Top level ──────────────────────────────────────────────────────
    //
    // A .wire file is zero or more top-level forms, optionally terminated
    // by a single file-return expression with no trailing semicolon.

    source_file: $ => seq(
      repeat($._top_form),
      optional(field('file_return', $.expression)),
    ),

    _top_form: $ => choice(
      $.contract_decl,
      $.node_decl,
      $.pure_let_binding,
      $.let_binding,
      $.import_stmt,
    ),

    // contract Name;
    contract_decl: $ => seq(
      'contract',
      field('name', $.contract_name),
      ';',
    ),

    node_decl: $ => choice(
      $.executor_node_decl,
      $.pure_node_decl,
    ),

    // node name : <port-sig> = <expr>;
    executor_node_decl: $ => seq(
      'node',
      field('name', $.identifier),
      ':',
      field('ports', $.port_signature),
      '=',
      field('body', $.expression),
      ';',
    ),

    // node name :
    //   <- input: Contract
    //   let shared = ...; in
    //   -> output: Contract = pure (...);
    pure_node_decl: $ => seq(
      'node',
      field('name', $.identifier),
      ':',
      field('inputs', repeat($.input_port)),
      optional(field('bindings', $.pure_let_block)),
      field('outputs', repeat1($.pure_output_equation)),
      ';',
    ),

    pure_let_block: $ => seq(
      'let',
      repeat1($.core_pure_binding),
      'in',
    ),

    pure_output_equation: $ => seq(
      field('port', $.pure_output_port),
      '=',
      field('body', $.pure_output_expr),
    ),

    pure_output_port: $ => seq(
      '->',
      field('variant', $.output_variant),
    ),

    pure_output_expr: $ => seq(
      'pure',
      choice(
        seq('(', field('expr', $.core_pure_expr), ')'),
        seq('{', field('expr', $.core_pure_expr), optional(';'), '}'),
      ),
    ),

    // let helper = x: ...;   |   let helper = let ... in ...;
    pure_let_binding: $ => seq(
      'let',
      field('name', $.identifier),
      '=',
      field('value', $.core_pure_shared_expr),
      ';',
    ),

    core_pure_shared_expr: $ => choice(
      $.core_pure_lambda,
      $.core_pure_let,
    ),

    // let name = <expr>;
    let_binding: $ => seq(
      'let',
      field('name', $.identifier),
      '=',
      field('value', $.expression),
      ';',
    ),

    // import name from "path";  |  import { a, b } from "path";
    import_stmt: $ => seq(
      'import',
      choice(
        field('binding', $.identifier),
        seq(
          '{',
          field(
            'bindings',
            seq(
              $.identifier,
              repeat(seq(',', $.identifier)),
              optional(','),
            ),
          ),
          '}',
        ),
      ),
      'from',
      field('path', $.string),
      ';',
    ),

    // ─── Port signatures ────────────────────────────────────────────────

    port_signature: $ => repeat1(choice($.input_port, $.output_port)),

    input_port: $ => seq(
      '<-',
      field('label', optional($.labeled_port_prefix)),
      field('contract', choice($.input_singular, $.input_list)),
    ),

    input_singular: $ => $.contract_name,

    input_list: $ => seq('[', $.contract_name, ']'),

    output_port: $ => seq(
      '->',
      field('body', $.output_body),
    ),

    // A bare variant, or a sum-group of two or more variants.
    output_body: $ => choice(
      // Sum group must have at least two variants; parser lookahead
      // handles the single-variant fallback.
      prec(1, seq(
        $.output_variant,
        repeat1(seq('|', $.output_variant)),
      )),
      $.output_variant,
    ),

    output_variant: $ => seq(
      field('label', optional($.labeled_port_prefix)),
      field('contract', $.contract_name),
    ),

    // Just the `label:` prefix (consumed by the port rules above).
    labeled_port_prefix: $ => seq($.identifier, ':'),

    contract_name: $ => alias($.identifier, $.contract),

    // ─── Expressions ────────────────────────────────────────────────────
    //
    // Stratified by precedence: overlay (lowest) → connect → postfix
    // select → merge/concat (highest) → atom. Binary operators are
    // left-associative; select chains as a left-folded postfix suffix.

    expression: $ => $._expr_overlay,

    _expr_overlay: $ => choice(
      prec.left(PREC.overlay, seq(
        field('left', $._expr_overlay),
        field('op', '<>'),
        field('right', $._expr_connect),
      )),
      $._expr_connect,
    ),

    _expr_connect: $ => choice(
      prec.left(PREC.connect, seq(
        field('left', $._expr_connect),
        field('op', '=>'),
        field('right', $._expr_select),
      )),
      $._expr_select,
    ),

    _expr_select: $ => choice(
      prec.left(PREC.select, seq(
        field('selector', $._expr_select),
        field('suffix', $.select_suffix),
      )),
      $._expr_merge,
    ),

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

    _expr_merge: $ => choice(
      prec.left(PREC.merge, seq(
        field('left', $._expr_merge),
        field('op', choice('//', '++')),
        field('right', $._expr_atom),
      )),
      $._expr_atom,
    ),

    _expr_atom: $ => choice(
      $.executor_apply,
      $.constructor_expr,
      $.record,
      $.list,
      $.string,
      $.indented_string,
      $.number,
      $.boolean,
      $.unit,
      $.paren_or_tuple,
      alias($.qualified_ident, $.ident_ref),
    ),

    // @qualified.name { field = ...; ... }
    executor_apply: $ => seq(
      '@',
      field('name', $.qualified_ident),
      field('config', $.record),
    ),

    // qualified.name { ... }  — tagged-record config constructor (no @).
    // Must be distinguished from a bare qualified_ident followed by a
    // separate record (there is no such thing at the expression atom
    // level, so we bind this form eagerly).
    constructor_expr: $ => prec(1, seq(
      field('name', $.qualified_ident),
      field('body', $.record),
    )),

    record: $ => seq(
      '{',
      repeat(seq($.field, ';')),
      optional($.field),
      '}',
    ),

    field: $ => seq(
      field('path', $.field_path),
      '=',
      field('value', $.expression),
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

    // ─── CorePure expressions ──────────────────────────────────────────

    core_pure_binding: $ => seq(
      field('name', $.identifier),
      '=',
      field('value', $.core_pure_expr),
      ';',
    ),

    core_pure_expr: $ => choice(
      $.core_pure_let,
      $.core_pure_lambda,
      $._core_pure_or,
    ),

    core_pure_let: $ => seq(
      'let',
      repeat1($.core_pure_binding),
      'in',
      field('body', $.core_pure_expr),
    ),

    core_pure_lambda: $ => prec.right(PREC.core_lambda, seq(
      field('param', $.identifier),
      ':',
      field('body', $.core_pure_expr),
    )),

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
      repeat(seq($.core_pure_field, ';')),
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

    // ( a )             — parenthesization
    // ( a, b, c )       — tuple
    // ()                — empty wire / unit (handled by $.unit)
    //
    // the grammar rejects singleton trailing-comma tuples `(a,)`.
    paren_or_tuple: $ => seq(
      '(',
      choice(
        $.expression,
        seq(
          $.expression,
          ',',
          $.expression,
          repeat(seq(',', $.expression)),
          optional(','),
        ),
      ),
      ')',
    ),

    // ─── Identifiers ────────────────────────────────────────────────────

    qualified_ident: $ => seq(
      $.identifier,
      repeat(seq('.', $.identifier)),
    ),

    // Internal helper for the conflict declaration above; points at the
    // bare-identifier-ref form.
    _identifier_ref: $ => $.qualified_ident,

    // ─── Literals ───────────────────────────────────────────────────────

    string: $ => seq(
      '"',
      repeat(choice(
        $.escape_sequence,
        /[^"\\\n\r]/,
      )),
      '"',
    ),

    escape_sequence: $ => token.immediate(seq(
      '\\',
      /[nt"\\]/,
    )),

    // ''...'' — verbatim, no escape processing, may span lines.
    // Closing delimiter is the next literal '' sequence.
    indented_string: $ => token(seq(
      "''",
      repeat(choice(
        /[^']/,
        /'[^']/,
      )),
      "''",
    )),

    number: $ => /-?[0-9]+(\.[0-9]+)?/,

    boolean: $ => choice('true', 'false'),

    null: $ => 'null',

    // The empty wire () lives in the grammar alongside paren_or_tuple;
    // authors can equivalently write `()` to denote the empty wire.
    unit: $ => prec(-1, seq('(', ')')),

    identifier: $ => /[A-Za-z_][A-Za-z0-9_]*/,

    // ─── Comments ───────────────────────────────────────────────────────

    line_comment: $ => token(seq('#', /[^\n]*/)),

    block_comment: $ => token(seq(
      '/*',
      /[^*]*\*+([^/*][^*]*\*+)*/,
      '/',
    )),
  },
});
