# tree-sitter-wire

Tree-sitter grammar for the Cortex **Wire** DSL. Checked-in examples and regression fixtures use
`.wire` files under `test/fixtures/wire/`.

Source of truth for the syntax: `docs/Reference/Wire/grammar.md`. The production parser is
`src/Cortex/Wire/Parser.hs`.

## What's here

```
grammar.js                grammar definition
tree-sitter.json          grammar metadata (ABI 15)
package.json              node package + tree-sitter CLI config
binding.gyp               node-gyp config
Cargo.toml                rust crate metadata
queries/
  highlights.scm          syntax highlighting
  folds.scm               code folding
  indents.scm             auto-indent rules
src/                      generated parser (checked in)
test/
  corpus/*.txt            tree-sitter test corpus
  parse-fixtures.sh       validates checked-in .wire fixtures
```

## Language coverage

**Top-level constructs**

- contract assertions: `contract EvidenceBundle;`
- node-body kind declarations:
  `kind pass(label: PortLabel) = <- label: Qubit ; -> label: Qubit = @executor (label) ;`
- graph form declarations: `form pair() = { node a = pass(x); node b = pass(x); a => b; };`
- executor node declarations with typed clauses:
  `node name <- input: Contract ; -> output: Contract ; = @executor (input) ;`
- kind applications that still introduce vertices with `node`: `node concrete = pass(input);`
- form applications that bind graph values with `let` / `export let`, or as nested form-local
  bindings: `let concrete = pair();`
- bounded node generation with `make(N, K)` in bound graph lets
- pure node output equations: `node name <- input: Contract ; -> output: Contract = input.score ;`
- configured executor values: `let analyst = @llm.analyst { temperature = 0.2 ; } ;`
- CorePure helper bindings: `export let acceptedItem = x: x.score >= 0.7 ;`
- imports: `import { a, b } from "path";`
- optional file-return expression with no trailing semicolon

**Graph expressions**

- connect: `a => b => c`
- record↔ports adapter: `(a <> b) * sink`
- overlay: `a <> b`
- overlay binds tighter than connect and star: `a => b <> c` parses as `a => (b <> c)`
- endpoints: node and composed graph expressions

**Values**

- strings, numbers, booleans (`true`/`false`), `null`
- attribute sets `{ k = v; ... }` (nested), including `inherit name;` shorthand
- lists `[item1, item2]`
- qualified refs `a.b.c` and bare identifiers
- configured executor values: `@qualified.name { config = value; }`
- executor calls in node bodies: `@qualified.name { config = value; } (input)` or `analyst (input)`
- config constructors: `topological { preset = "analyst"; }`
- operators: record merge `//` and string/list concat `++`
- CorePure expressions inside output equations and executor input arguments: field access, indexing,
  lambdas, application, `if ... then ... else ...`, pipes `|>`, arithmetic/comparison/boolean
  operators, records, lists, string interpolation, and builtins such as `map`, `filter`, `zipWith`,
  `joinWith`, `toJson`, and `fromJson`

**Comments**

- line: `#` to end of line
- block: `/* ... */`

## Generate and test

Requires `tree-sitter` ≥ 0.22 (NixOS: `nix-shell -p tree-sitter`).

```bash
# regenerate parser from grammar.js
tree-sitter generate

# corpus tests (test/corpus/*.txt)
tree-sitter test

# parse a specific file
tree-sitter parse path/to/file.wire

# validate checked-in Wire fixtures
./test/parse-fixtures.sh
```

The generated `src/parser.c`, `src/grammar.json`, `src/node-types.json`, and
`src/tree_sitter/parser.h` are checked in by convention so consumers don't need the CLI.

## Editor integrations

See the sibling directories:

- `../neovim/` — nvim-treesitter registration instructions
- `../helix/` — `languages.toml` fragment + query copies
- `../vscode/` — VS Code extension

## Known Divergences From The Production Parser

This grammar is deliberately syntax-focused. Semantic checks are still owned by the Megaparsec
parser and compiler:

- **Semantic checks are out of scope.** Tree-sitter accepts syntactically valid records, lists,
  configured executors, executor calls, and graph expressions even when the compiler would reject
  unknown contracts, unknown executors, bad port contracts, invalid runtime config, `@pure`, or
  topology expressions that violate linear endpoint rules.

Regression coverage lives in `test/corpus/v1.txt` and `test/parse-fixtures.sh`.

## License

Apache-2.0 — same as the parent repo.
