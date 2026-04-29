;; Tree-sitter highlight queries for Wire.
;; Capture names follow the tree-sitter convention; editors map them to themes.

; ── Keywords ─────────────────────────────────────────────────────────────

"contract" @keyword
"node"     @keyword
"export"   @keyword
"let"      @keyword
"in"       @keyword
"import"   @keyword
"from"     @keyword
"pure"     @keyword
"if"       @keyword
"then"     @keyword
"else"     @keyword
"where"    @keyword

(boolean) @constant.builtin
(null)    @constant.builtin

; ── Operators ───────────────────────────────────────────────────────────

"=>"   @operator  ; connect
"<>"   @operator  ; overlay
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

; [export] let <name> = <expr>;
(let_binding name: (identifier) @constant)

; contract <Name>;
(contract_decl
  name: (contract_name
    (contract) @type))

; import <name> from "path";  |  import { a, b } from "path";
(import_stmt binding: (identifier) @namespace)

; ── Types and contracts ────────────────────────────────────────────────

(contract) @type

; ── Executor application ───────────────────────────────────────────────

; @qualified.name { ... } and @qualified.name { ... } (input)
(configured_executor_value name: (qualified_ident) @function.builtin)
(inline_executor_call name: (qualified_ident) @function.builtin)
(configured_executor_call name: (identifier) @function.builtin)

; qualified.name { ... }  — tagged-record config constructor (no @)
(constructor_expr name: (qualified_ident) @constructor)

; ── Fields in records ──────────────────────────────────────────────────

(field path: (field_path (identifier) @property))
(core_pure_field path: (field_path (identifier) @property))
(core_pure_binding name: (identifier) @constant)

; ── Port labels ────────────────────────────────────────────────────────

(input_clause label: (identifier) @tag)
(output_variant label: (identifier) @tag)

; ── Identifier references ──────────────────────────────────────────────

(ident_ref) @variable
(core_pure_ident) @variable

; ── Literals ───────────────────────────────────────────────────────────

(string)          @string
(indented_string) @string
(escape_sequence) @string.escape
(number)          @number

; ── Comments ───────────────────────────────────────────────────────────

(line_comment)  @comment
(block_comment) @comment
