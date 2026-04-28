{inputs, ...}: {
  imports = [
    inputs.treefmt-nix.flakeModule
  ];

  perSystem = {config, ...}: {
    treefmt = {
      projectRootFile = "flake.nix";

      programs = {
        alejandra.enable = true; # Nix
        just.enable = true; # justfile
        fourmolu.enable = true; # Haskell
        prettier = {
          enable = true; # Markdown
          includes = ["*.md"];
          settings = {
            printWidth = 100;
            proseWrap = "always";
            tabWidth = 2;
          };
        };
      };

      settings = {
        global = {
          excludes = [
            "nix/materialized/*"
            ".git/*"
            "docs/Templates/*"
            # Golden Markdown fixtures intentionally match renderer output.
            "test/fixtures/ir/*"
            "theory/.lake/*"
            # Generated tree-sitter parser (do not reformat).
            "editors/*/src/parser.c"
            "editors/*/src/grammar.json"
            "editors/*/src/node-types.json"
          ];
        };
      };
    };

    formatter = config.treefmt.build.wrapper;
  };
}
