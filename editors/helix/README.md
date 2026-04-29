# Helix integration for tree-sitter-wire

Configures Helix to recognize `.wire` files, fetch and build the tree-sitter grammar, and apply
highlights/folds/indents.

## Install

1. Append the contents of `languages.toml` here to `~/.config/helix/languages.toml`. Edit the
   `[[grammar]]` `source.path` to point at your local checkout of `editors/tree-sitter-wire/`.

2. Copy the query files from the canonical source into Helix's runtime directory:

   ```
   mkdir -p ~/.config/helix/runtime/queries/wire
   cp editors/tree-sitter-wire/queries/*.scm ~/.config/helix/runtime/queries/wire/
   ```

   There is intentionally no `editors/helix/queries/` duplicate — the queries at
   `editors/tree-sitter-wire/queries/` are the single source of truth, so Helix and Neovim can never
   drift out of sync.

3. Fetch and build the grammar:

   ```
   hx --grammar fetch
   hx --grammar build
   ```

4. Restart Helix. Open a checked-in fixture such as
   `test/fixtures/wire/thesis-parallel-claim-branches.wire`, or any local `.wire` file; highlighting
   should render immediately.

## Query locations Helix reads

Helix looks for queries under `runtime/queries/<language>/`. The files must match exactly:

- `highlights.scm` — syntax highlighting
- `indents.scm` — indentation rules
- `folds.scm` — fold regions
- `textobjects.scm` — (optional) for `mi`/`ma` motions; not provided yet

## Verify

Open a `.wire` file and:

- keywords (`contract`, `node`, `let`, `import`, `from`, `select`) should highlight
- `{ ... }` blocks should fold with `zc` / `za`
- indentation should follow `{`/`[`/`(`

Run `:tree-sitter-subtree` on a node to inspect the live parse.
