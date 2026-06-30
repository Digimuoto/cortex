# VS Code integration for Cortex Wire

Syntax highlighting + auto-indent + comment handling for `.wire` files.

This uses a TextMate grammar (the default VS Code tokenizer). It doesn't wire up tree-sitter
directly — VS Code doesn't natively support tree-sitter grammars yet. The normative syntax spec is
`docs/Reference/Wire/grammar.md`, the production parser is `src/Cortex/Wire/Parser.hs`, and the
tree-sitter grammar in the sibling `tree-sitter-wire/` directory powers Neovim/Helix; this extension
is the pragmatic VS Code fallback.

## Install (local, for development)

1. Open this directory in VS Code.
2. Press `F5` to launch a new Extension Development Host window.
3. Open a `.wire` file — highlighting should apply.

## Install (permanently, local)

Copy this directory into your VS Code extensions folder:

- Linux: `~/.vscode/extensions/cortex-wire/`
- macOS: `~/.vscode/extensions/cortex-wire/`
- Windows: `%USERPROFILE%\.vscode\extensions\cortex-wire\`

Restart VS Code.

## Package for distribution

```
npm install -g @vscode/vsce
vsce package
```

Produces `cortex-wire-0.1.0.vsix`. Install via:

```
code --install-extension cortex-wire-0.1.0.vsix
```

## What's covered

- **Comments**: `#` line + `/* */` block, with `Ctrl+/` and `Ctrl+Shift+A` toggling
- **Keywords**: `contract`, `node`, `let`, `export`, `import`, `from`, `pure`, `if`, `then`, `else`,
  `select`, `true`, `false`, `null`
- **Record fields**: common config fields such as `prompt`, `tools`, `memory`, `model`, `timeout`,
  `retry`, `stepBudget`, and `maxOutputTokens`
- **Graph and CorePure operators**: `=>`, `<>`, `<-`, `->`, `|>`, `//`, `++`, comparisons,
  arithmetic, and boolean operators
- **Strings** (including escape sequences), integers, `true`/`false`/`null`
- **Contracts**: capitalized identifiers after `<-`/`->` or in type positions
- **Executors**: `@qualified.name` gets a distinct scope
- **Auto-indent**: follows `{`/`[`/`(`; dedents on closing brackets
- **Bracket matching**: `{}`, `[]`, `()`, quotes

## What's NOT covered (vs the tree-sitter grammar)

- No incremental parse tree — this is pattern-based, not AST-based
- Semantic checks such as configured-executor admission, port matching, and CorePure typing are out
  of scope for TextMate highlighting

For the full experience (incremental parsing, AST queries, folding per precise rule) use Neovim or
Helix with the tree-sitter grammar in `editors/tree-sitter-wire/`.
