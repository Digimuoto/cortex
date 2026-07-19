;; Tree-sitter highlight queries for Wire.
;; Capture names follow the tree-sitter convention; editors map them to themes.

; ── Keywords ─────────────────────────────────────────────────────────────

"contract" @keyword
"form"     @keyword
"kind"     @keyword
"make"     @keyword
"node"     @keyword
"export"   @keyword
"let"      @keyword
"in"       @keyword
"import"   @keyword
"from"     @keyword
"use"      @keyword
"as"       @keyword
"inherit"  @keyword
"select"   @keyword
"if"       @keyword
"then"     @keyword
"else"     @keyword
"where"    @keyword

(boolean) @constant.builtin
(null)    @constant.builtin
(ellipsis) @comment

; ── Operators ───────────────────────────────────────────────────────────

"=>"   @operator  ; connect (graph) — promoted to @keyword.operator below
"<>"   @operator  ; overlay (graph) — promoted to @keyword.operator below
"//"   @operator  ; right-biased record merge
"++"   @operator  ; concatenation (strings, lists)
"|>"   @operator  ; CorePure pipe
"<-"   @operator  ; input-port marker
"->"   @operator  ; output-port marker
"|"    @operator  ; sum-group separator
"="    @operator
"@"    @operator
"+"    @operator
"-"    @operator
"*"    @operator
"/"    @operator
"=="   @operator
"!="   @operator
"<"    @operator
"<="   @operator
">"    @operator
">="   @operator
"&&"   @operator
"||"   @operator
"!"    @operator

; ── Punctuation ─────────────────────────────────────────────────────────

":"    @punctuation.delimiter
";"    @punctuation.delimiter
","    @punctuation.delimiter
"."    @punctuation.delimiter

"{"    @punctuation.bracket
"}"    @punctuation.bracket
"["    @punctuation.bracket
"]"    @punctuation.bracket
"("    @punctuation.bracket
")"    @punctuation.bracket

; ── Declarations ────────────────────────────────────────────────────────

; node <name>
(node_decl name: (identifier) @function)

; kind <name>(...)
(kind_decl name: (identifier) @type)
(kind_param class: (kind_param_class) @type)
(kind_application name: (identifier) @type)

; form <name>(...)
(form_decl name: (identifier) @type)
(form_param class: (form_param_class) @type)
(form_application name: (identifier) @type)
(make_application kind: (identifier) @type)

; [export] let <name> = <expr>;
(let_binding target: (let_target name: (identifier) @constant))
(form_let_binding target: (let_target name: (identifier) @constant))

; contract <Name>;
(contract_decl
  name: (contract_name
    (contract) @type))

; import <name> from "path";  |  import { a, b } from "path";
(import_stmt binding: (identifier) @namespace)

; use std.io.{@executor, Contract};
(use_stmt namespace: (use_namespace) @namespace)
(use_executor_item name: (identifier) @function.builtin)
(use_executor_item alias: (identifier) @function.builtin)
(use_contract_item name: (identifier) @type)
(use_contract_item alias: (identifier) @type)

; ── Types and contracts ────────────────────────────────────────────────

(contract) @type

; ── Executor application ───────────────────────────────────────────────

; @qualified.name authority values and zero/one-argument calls
(executor_value name: (qualified_ident) @function.builtin)
(inline_executor_call name: (qualified_ident) @function.builtin)

; qualified.name { ... }  — tagged-record config constructor (no @)
(constructor_expr name: (qualified_ident) @constructor)

; ── Fields in records ──────────────────────────────────────────────────

(field path: (field_path (identifier) @property))
(core_pure_field path: (field_path (identifier) @property))
(core_pure_binding name: (identifier) @constant)

; ── Port labels ────────────────────────────────────────────────────────

(input_clause label: (identifier) @tag)
(output_variant label: (identifier) @tag)
(contract_field name: (identifier) @property)

; ── Identifier references ──────────────────────────────────────────────

(ident_ref) @variable
(core_pure_ident) @variable
(family_projection family: (identifier) @variable)

; ── Graph topology ─────────────────────────────────────────────────────

; Connect (=>) and overlay (<>) compose graphs — themed apart from
; value operators so editors can style topology structure distinctly.
(topology_expression op: _ @keyword.operator)

; Endpoints on either side of a topology operator reference declared
; nodes (or graph-valued bindings used as nodes); highlight them like
; the node decls themselves rather than as plain variables.
(topology_expression left: (ident_ref) @function)
(topology_expression right: (ident_ref) @function)

; ── Literals ───────────────────────────────────────────────────────────

(string)          @string
(indented_string) @string
(escape_sequence) @string.escape

; ${...} antiquotation inside "..." and ''...'' strings.
(string_interpolation)          @string.special
(indented_string_interpolation) @string.special

(number)          @number

; ── Comments ───────────────────────────────────────────────────────────

(line_comment)  @comment
(block_comment) @comment
