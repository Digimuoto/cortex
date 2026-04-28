/**
 * Tree-sitter grammar for the Wire language.
 *
 * Source of truth: docs/Reference/Wire/grammar.md (accepted
 * 2026-04-23). Mirrors the Haskell parser at src/Cortex/Wire/V1.
 *
 * Top-level forms:          contract; node; let; import; and optional
 *                           file-return expression.
 * Executors:                @qualified.name { config }
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
      $.let_binding,
      $.import_stmt,
    ),

    // contract Name;
    contract_decl: $ => seq(
      'contract',
      field('name', $.contract_name),
      ';',
    ),

    // node name : <port-sig> = <expr>;
    node_decl: $ => seq(
      'node',
      field('name', $.identifier),
      ':',
      field('ports', $.port_signature),
      '=',
      field('body', $.expression),
      ';',
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
