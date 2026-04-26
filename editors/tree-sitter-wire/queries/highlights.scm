;; Tree-sitter highlight queries for Wire v1.
;; Capture names follow the tree-sitter convention; editors map them to themes.

; ── Keywords ─────────────────────────────────────────────────────────────

"contract" @keyword
"node"     @keyword
"let"      @keyword
"import"   @keyword
"from"     @keyword

(boolean) @constant.builtin

; ── Operators ───────────────────────────────────────────────────────────

"=>"   @operator  ; connect
"<>"   @operator  ; overlay
"//"   @operator  ; right-biased merge (records, partial nodes)
"++"   @operator  ; concatenation (strings, lists)
"<-"   @operator  ; input-port marker
"->"   @operator  ; output-port marker
"|"    @operator  ; sum-group separator
"="    @operator
"@"    @operator

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

; node <name> : <sig> = <body>;
(node_decl name: (identifier) @function)

; let <name> = <expr>;
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

; @qualified.name { ... }
(executor_apply name: (qualified_ident) @function.builtin)

; qualified.name { ... }  — tagged-record config constructor (no @)
(constructor_expr name: (qualified_ident) @constructor)

; ── Fields in records ──────────────────────────────────────────────────

(field path: (field_path (identifier) @property))

; ── Port labels ────────────────────────────────────────────────────────

(labeled_port_prefix (identifier) @tag)

; ── Identifier references ──────────────────────────────────────────────

(ident_ref) @variable

; ── Literals ───────────────────────────────────────────────────────────

(string)          @string
(indented_string) @string
(escape_sequence) @string.escape
(number)          @number

; ── Comments ───────────────────────────────────────────────────────────

(line_comment)  @comment
(block_comment) @comment
