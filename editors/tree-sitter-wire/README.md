# tree-sitter-wire

Tree-sitter grammar for the Cortex **Wire** DSL. Checked-in examples
and regression fixtures use `.wire` files under `test/fixtures/wire-v1/`.

Source of truth for the syntax: `docs/Reference/Wire/grammar.md`.
The production parser is `src/Cortex/Wire/V1/Parser.hs`.

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
  corpus/*.txt            tree-sitter test corpus (25 cases)
  parse-fixtures.sh       validates checked-in .wire fixtures
```

## Language coverage

**Top-level constructs**

- contract assertions: `contract EvidenceBundle;`
- node declarations: `node name : <- Contract -> Contract = @executor { ... };`
- let bindings: `let shared_prompt = "..." ++ "...";`
- imports: `import { a, b } from "path";`
- optional file-return expression with no trailing semicolon

**Graph expressions** (precedence: parens > connect `=>` > overlay `,`/`<>`)

- connect (right-associative): `a => b => c`
- overlay (left-associative): `a, b` or `a <> b`
- grouping: `(a, b) => (c, d)`
- endpoints: `node` or `node.port`

**Values**

- strings, integers, booleans (`true`/`false`), `null`
- attribute sets `{ k = v; ... }` (nested)
- lists `[item1, item2]`
- qualified refs `a.b.c` and bare identifiers
- executors: `@qualified.name { config = value; }`
- config constructors: `topological { preset = "analyst"; }`
- operators: record merge `//` and string/list concat `++`

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

The generated `src/parser.c`, `src/grammar.json`, `src/node-types.json`, and `src/tree_sitter/parser.h` are checked in by convention so consumers don't need the CLI.

## Editor integrations

See the sibling directories:

- `../neovim/` — nvim-treesitter registration instructions
- `../helix/` — `languages.toml` fragment + query copies
- `../vscode/` — VS Code extension

## Known Divergences From The V1 Parser

This grammar is deliberately a *parseable superset* of what the Megaparsec parser accepts, except where editor recovery benefits from accepting incomplete buffers:

- **Identifiers do not accept `:`.** The grammar uses `[A-Za-z_][A-Za-z0-9_\-]*` so port labels like `<- input: Contract` disambiguate cleanly. Values like `"SPY:US"` remain string literals.
- **Semantic checks are out of scope.** Tree-sitter accepts syntactically valid records, lists, executor applications, and graph expressions even when the compiler would reject unknown contracts, unknown executors, bad port contracts, or invalid runtime config.

Outside these points, every production form accepted by the V1 parser should parse here. Regression coverage lives in `test/corpus/v1.txt` and `test/parse-fixtures.sh`.

## License

Apache-2.0 — same as the parent repo.
