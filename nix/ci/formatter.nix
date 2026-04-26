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
        ormolu.enable = true; # Haskell
      };

      settings = {
        global = {
          excludes = [
            "nix/materialized/*"
            ".git/*"
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
