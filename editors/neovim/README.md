# Neovim integration for tree-sitter-wire

Three install paths depending on how you manage Neovim. Pick one.

## 1. Nixvim flake module (recommended if you already use nixvim)

The repo exposes `nixvimModules.default` at the flake level. In your nixvim config flake:

```nix
{
  inputs.cortex.url = "github:Digimuoto/cortex";
  # ... plus your usual nixvim / nixpkgs inputs ...

  outputs = { self, nixpkgs, nixvim, cortex, ... }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      # ...
      modules = [
        nixvim.nixosModules.nixvim
        ({ ... }: {
          programs.nixvim = {
            enable = true;
            plugins.treesitter.enable = true;  # prerequisite
            imports = [ cortex.nixvimModules.default ];
          };
        })
      ];
    };
  };
}
```

What you get:

- Tree-sitter grammar package (`tree-sitter-wire`) added to `plugins.treesitter.grammarPackages`
- `.wire` extension → `wire` filetype
- `highlights.scm` / `folds.scm` / `indents.scm` installed into the nvim runtime

No further config needed — open any `.wire` file and highlighting, folds, and indent kick in.

The module lives at `nix/modules/nixvim-wire.nix` and is safe to import even into configs that
manage treesitter differently: it only _adds_ to `grammarPackages` and never force-enables
treesitter itself.

## 2. Raw nix package (home-manager, custom nvim setup, overlay)

The flake also exposes packages for non-nixvim setups:

```nix
# Build the grammar directly
packages.tree-sitter-wire         # $out/parser (the .so file)

# Nvim-treesitter-shaped plugin (parser + queries in the layout nvim expects)
packages.tree-sitter-wire-plugin  # $out/parser/wire.so + $out/queries/wire/*.scm
```

Use `tree-sitter-wire-plugin` in home-manager's `programs.neovim.plugins` or any place that accepts
vim plugins.

## 3. Manual nvim-treesitter install (non-nix setups)

For Neovim configs that aren't flake-managed, add this to your config (`init.lua` or a plugin spec):

```lua
-- File: ~/.config/nvim/after/plugin/tree-sitter-wire.lua   (or inline in init.lua)

local parser_config = require("nvim-treesitter.parsers").get_parser_configs()

parser_config.wire = {
  install_info = {
    url = "/absolute/path/to/cortex/editors/tree-sitter-wire",
    files = { "src/parser.c" },
    branch = "main",
    generate_requires_npm = false,
    requires_generate_from_grammar = false,
  },
  filetype = "wire",
}

vim.filetype.add({ extension = { wire = "wire" } })
```

Then:

```
:TSInstall wire
```

Queries need to land in `~/.config/nvim/queries/wire/` (or `after/queries/wire/`):

```bash
mkdir -p ~/.config/nvim/queries/wire
cp editors/tree-sitter-wire/queries/*.scm ~/.config/nvim/queries/wire/
```

## Verification (all paths)

Open a checked-in fixture such as `test/fixtures/wire/thesis-parallel-claim-branches.wire`, or any
local `.wire` file:

- Keywords highlight (`contract`, `node`, `let`, `import`, `from`, `select`)
- Contract types (capitalized identifiers after `<-` / `->`) highlight distinctly
- Strings, comments, numbers, operators all styled
- `:InspectTree` shows a live parse tree
- Folding with `zc` / `za` collapses `{ ... }` blocks
- Indentation follows `{` / `[` / `(`

Enable folding in your config:

```lua
vim.opt.foldmethod = "expr"
vim.opt.foldexpr = "nvim_treesitter#foldexpr()"
```

Enable tree-sitter highlighting + indentation (nvim-treesitter config):

```lua
require("nvim-treesitter.configs").setup({
  indent = { enable = true },
  highlight = { enable = true },
})
```
