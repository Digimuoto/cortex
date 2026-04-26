{...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    check-theory-hook = pkgs.writeShellApplication {
      name = "check-theory-hook";
      runtimeInputs = [pkgs.nix];
      text = ''
        set -euo pipefail
        exec nix build .#cortex-theory --no-link --print-build-logs
      '';
    };
  in {
    pre-commit = {
      check.enable = false;

      settings = {
        hooks = {
          treefmt = {
            enable = true;
            name = "treefmt";
            description = "Run treefmt over the repository and fail on drift";
            entry = "${config.treefmt.build.wrapper}/bin/treefmt --fail-on-change --no-cache";
            language = "system";
            pass_filenames = false;
          };

          hlint = {
            enable = true;
            name = "hlint";
            description = "Run HLint on Cortex Haskell sources";
            entry = "${config.packages.lint-haskell}/bin/lint-haskell";
            language = "system";
            pass_filenames = false;
            files = "(^|/).+\\.(hs|lhs)$|(^|/)cortex\\.cabal$|(^|/)\\.hlint\\.yaml$";
          };

          lean-theory = {
            enable = true;
            name = "lean-theory";
            description = "Build the Lean theory when theory inputs change";
            entry = "${check-theory-hook}/bin/check-theory-hook";
            language = "system";
            pass_filenames = false;
            files = "^theory/.*\\.(lean|json)$|^theory/(lakefile\\.lean|lean-toolchain)$|^nix/lean\\.nix$";
          };
        };
      };
    };
  };
}
