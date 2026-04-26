# Nixvim module — Cortex Wire DSL support.
#
# Adds the tree-sitter grammar and query files to a nixvim configuration,
# registers the `.wire` file extension with the `wire` filetype, and gives
# Neovim everything it needs to produce highlighting, folds, and indentation
# for Wire source.
#
# Usage — in your nixvim flake:
#
#   inputs.cortex.url = "github:Digimuoto/cortex";
#
#   # Inside the nixvim module imports:
#   imports = [ inputs.cortex.nixvimModules.default ];
#
# Prerequisites:
#   - plugins.treesitter.enable = true;   (nixvim's native treesitter module)
#
# This module is a pure contribution: it adds a grammar package, the filetype
# binding, and the query files. It does NOT force-enable treesitter itself —
# if the user has not enabled it, our grammar simply is not loaded. That keeps
# the module safe to import even into configs that manage treesitter
# differently.
{self}: {
  pkgs,
  lib,
  config,
  ...
}: let
  # Rebuild against the user's nixpkgs so buildGrammar's tree-sitter runtime
  # matches the one nixvim drives its plugin set with.
  tree-sitter-wire = pkgs.tree-sitter.buildGrammar {
    language = "wire";
    version = "0.1.0";
    src = "${self}/editors/tree-sitter-wire";
  };

  # Reshape `buildGrammar` output (`$out/parser` FILE) into the nvim-treesitter
  # grammar layout (`$out/parser/<lang>.so`) that nixvim's `grammarPackages`
  # consumes. Queries ride along in the same derivation.
  tree-sitter-wire-plugin = pkgs.runCommand "vimplugin-tree-sitter-wire-0.1.0" {} ''
    mkdir -p $out/parser $out/queries/wire
    cp ${tree-sitter-wire}/parser $out/parser/wire.so
    cp ${self}/editors/tree-sitter-wire/queries/highlights.scm $out/queries/wire/highlights.scm
    cp ${self}/editors/tree-sitter-wire/queries/folds.scm      $out/queries/wire/folds.scm
    cp ${self}/editors/tree-sitter-wire/queries/indents.scm    $out/queries/wire/indents.scm
  '';
in {
  # Append to the user's grammar set. Lists merge by concatenation across
  # imports, so this slots in without conflicting with other grammars they
  # already configure.
  plugins.treesitter.grammarPackages = [tree-sitter-wire-plugin];

  # Register `.wire` as the `wire` filetype, alongside whatever other filetype
  # rules the user has.
  extraConfigLua = ''
    vim.filetype.add({ extension = { wire = "wire" } })
  '';
}
