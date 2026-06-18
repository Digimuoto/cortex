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

          fourmolu = {
            enable = true;
            name = "fourmolu";
            description = "Format staged Haskell sources and normalize imports";
            entry = "${pkgs.haskellPackages.fourmolu}/bin/fourmolu --mode inplace";
            language = "system";
            pass_filenames = true;
            files = "^(src|app|test)/.*\\.hs$";
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

          language-pragmas = {
            enable = true;
            name = "language-pragmas";
            description = "Reject non-allowlisted Haskell LANGUAGE pragmas";
            entry = "${config.packages.check-language-pragmas}/bin/check-language-pragmas";
            language = "system";
            pass_filenames = true;
            files = "^(src|app|test)/.*\\.hs$|^cortex\\.cabal$|^scripts/check-language-pragma-allowlist\\.sh$";
          };

          module-haddock = {
            enable = true;
            name = "module-haddock";
            description = "Require combined module Haddock frontmatter";
            entry = "${config.packages.check-module-haddock}/bin/check-module-haddock";
            language = "system";
            pass_filenames = true;
            files = "^(src|app|test)/.*\\.hs$|^scripts/check-module-haddock\\.sh$|^\\.license-header\\.txt$";
          };

          logos-boundary = {
            enable = true;
            name = "logos-boundary";
            description = "Reject Cortex imports of Logos";
            entry = "${config.packages.check-logos-boundary}/bin/check-logos-boundary";
            language = "system";
            pass_filenames = true;
            files = "^(src|app|test)/.*\\.hs$|^scripts/check-logos-boundary\\.sh$";
          };

          lean-lint = {
            enable = true;
            name = "lean-lint";
            description = "Run strict Lean theory lint checks";
            entry = "${config.packages.lean-lint}/bin/lean-lint";
            language = "system";
            pass_filenames = false;
            files = "^theory/.*|^scripts/lean-lint$|^nix/(agent-.*\\.nix|lean\\.nix|ci/.*)$|^justfile$";
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

          docs-lint = {
            enable = true;
            name = "docs-lint";
            description = "Run strict Markdown/docs lint checks";
            entry = "${config.packages.docs-lint}/bin/docs-lint";
            language = "system";
            pass_filenames = false;
            files = "^docs/.*|^scripts/docs-lint$|^nix/(agent-.*\\.nix|docs\\.nix|ci/.*)$|^justfile$";
          };

          wire-style = {
            enable = true;
            name = "wire-style";
            description = "Run strict Wire source style checks";
            entry = "${config.packages.check-wire-style}/bin/check-wire-style";
            language = "system";
            pass_filenames = false;
            files = "^.*\\.wire$|^docs/(Architecture|Reference|Usage)/.*\\.md$|^docs/index\\.md$|^scripts/check-wire-style$|^nix/ci/.*$|^justfile$";
          };

          doc-wire-examples = {
            enable = true;
            name = "doc-wire-examples";
            description = "Parse and highlight Wire code fences embedded in Markdown docs";
            entry = "${config.packages.check-doc-wire-examples}/bin/check-doc-wire-examples";
            language = "system";
            pass_filenames = false;
            files = "^docs/.*\\.md$|^editors/tree-sitter-wire/.*|^scripts/check-doc-wire-examples$|^nix/ci/.*$|^justfile$";
          };
        };
      };
    };
  };
}
