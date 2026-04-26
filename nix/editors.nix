# Editor integrations — Wire DSL tree-sitter grammar packages.
#
# Outputs:
#   packages.tree-sitter-wire         — parser .so in $out/parser/wire.so
#   packages.tree-sitter-wire-plugin  — neovim-plugin shape: parser + queries
{...}: {
  perSystem = {pkgs, ...}: let
    grammarSrc = ../editors/tree-sitter-wire;
    queriesSrc = ../editors/tree-sitter-wire/queries;

    tree-sitter-wire = pkgs.tree-sitter.buildGrammar {
      language = "wire";
      version = "0.1.0";
      src = grammarSrc;
      meta = {
        description = "Tree-sitter grammar for the Cortex Wire DSL";
        homepage = "https://github.com/Digimuoto/cortex";
        license = pkgs.lib.licenses.asl20;
      };
    };

    # Neovim-plugin-shaped derivation (parser/<lang>.so + queries/<lang>/*.scm).
    # `buildGrammar` emits the parser as a FILE at `$out/parser`; rename into
    # the directory shape Neovim / nvim-treesitter expect.
    tree-sitter-wire-plugin =
      pkgs.runCommand "vimplugin-tree-sitter-wire-0.1.0" {
        meta = {
          description = "Neovim plugin bundling tree-sitter-wire parser + queries";
          license = pkgs.lib.licenses.asl20;
        };
      } ''
        mkdir -p $out/parser $out/queries/wire
        cp ${tree-sitter-wire}/parser $out/parser/wire.so
        cp ${queriesSrc}/highlights.scm $out/queries/wire/highlights.scm
        cp ${queriesSrc}/folds.scm      $out/queries/wire/folds.scm
        cp ${queriesSrc}/indents.scm    $out/queries/wire/indents.scm
      '';
  in {
    packages.tree-sitter-wire = tree-sitter-wire;
    packages.tree-sitter-wire-plugin = tree-sitter-wire-plugin;
  };
}
