{inputs, ...}: {
  imports = [
    ./formatter.nix
    ./pre-commit.nix
  ];

  perSystem = {pkgs, ...}: let
    check-format = pkgs.writeShellApplication {
      name = "check-format";
      runtimeInputs = [pkgs.nix];
      text = ''
        set -euo pipefail
        exec nix fmt -- --fail-on-change
      '';
    };

    check-haskell-format = pkgs.writeShellApplication {
      name = "check-haskell-format";
      runtimeInputs = [
        pkgs.fd
        pkgs.haskellPackages.fourmolu
      ];
      text = ''
        set -euo pipefail
        fd -e hs . src app test -0 \
          | xargs -0 fourmolu --mode check
      '';
    };

    lint-haskell = pkgs.writeShellApplication {
      name = "lint-haskell";
      runtimeInputs = [pkgs.haskellPackages.hlint];
      text = ''
        set -euo pipefail
        exec hlint src app test
      '';
    };

    check-language-pragmas = pkgs.writeShellApplication {
      name = "check-language-pragmas";
      runtimeInputs = [
        pkgs.findutils
        pkgs.perl
      ];
      text = ''
        set -euo pipefail
        exec scripts/check-language-pragma-allowlist.sh "$@"
      '';
    };

    check-module-haddock = pkgs.writeShellApplication {
      name = "check-module-haddock";
      runtimeInputs = [pkgs.python3];
      text = ''
        set -euo pipefail
        exec scripts/check-module-haddock.sh "$@"
      '';
    };

    check-logos-boundary = pkgs.writeShellApplication {
      name = "check-logos-boundary";
      runtimeInputs = [
        pkgs.findutils
        pkgs.perl
      ];
      text = ''
        set -euo pipefail
        exec scripts/check-logos-boundary.sh "$@"
      '';
    };

    lean-lint = pkgs.writeShellApplication {
      name = "lean-lint";
      runtimeInputs = [pkgs.python3];
      text = ''
        set -euo pipefail
        exec python3 scripts/lean-lint
      '';
    };

    docs-lint = pkgs.writeShellApplication {
      name = "docs-lint";
      runtimeInputs = [pkgs.python3];
      text = ''
        set -euo pipefail
        exec python3 scripts/docs-lint
      '';
    };

    check-theory = pkgs.writeShellApplication {
      name = "check-theory";
      runtimeInputs = [pkgs.nix];
      text = ''
        set -euo pipefail
        exec nix build .#cortex-theory --no-link --print-build-logs
      '';
    };

    ci-check = pkgs.writeShellApplication {
      name = "ci-check";
      runtimeInputs = [
        check-format
        check-haskell-format
        check-language-pragmas
        check-logos-boundary
        check-module-haddock
        docs-lint
        lean-lint
        lint-haskell
        check-theory
        pkgs.nix
      ];
      text = ''
        set -euo pipefail

        echo "Step 1: formatting"
        check-format
        echo

        echo "Step 2: Haskell formatting"
        check-haskell-format
        echo

        echo "Step 3: Haskell lint"
        lint-haskell
        echo

        echo "Step 4: Haskell language pragmas"
        check-language-pragmas
        echo

        echo "Step 5: Haskell module Haddock"
        check-module-haddock
        echo

        echo "Step 6: Logos import boundary"
        check-logos-boundary
        echo

        echo "Step 7: Lean lint"
        lean-lint
        echo

        echo "Step 8: docs lint"
        docs-lint
        echo

        echo "Step 9: Lean theory"
        check-theory
        echo

        echo "Step 10: flake checks"
        nix flake check --print-build-logs
      '';
    };
  in {
    packages = {
      _check-format = check-format;
      _check-theory = check-theory;
      _ci-check = ci-check;
      check-haskell-format = check-haskell-format;
      check-logos-boundary = check-logos-boundary;
      check-language-pragmas = check-language-pragmas;
      check-module-haddock = check-module-haddock;
      docs-lint = docs-lint;
      lean-lint = lean-lint;
      lint-haskell = lint-haskell;
    };

    apps = {
      _check-format = {
        type = "app";
        program = "${check-format}/bin/check-format";
        meta.description = "Fail when repo formatting drifts";
      };

      _check-theory = {
        type = "app";
        program = "${check-theory}/bin/check-theory";
        meta.description = "Build the Lean theory through the flake surface";
      };

      check-haskell-format = {
        type = "app";
        program = "${check-haskell-format}/bin/check-haskell-format";
        meta.description = "Fail when Fourmolu formatting drifts";
      };

      check-language-pragmas = {
        type = "app";
        program = "${check-language-pragmas}/bin/check-language-pragmas";
        meta.description = "Reject non-allowlisted file-local LANGUAGE pragmas";
      };

      check-module-haddock = {
        type = "app";
        program = "${check-module-haddock}/bin/check-module-haddock";
        meta.description = "Require combined module Haddock frontmatter";
      };

      check-logos-boundary = {
        type = "app";
        program = "${check-logos-boundary}/bin/check-logos-boundary";
        meta.description = "Reject Cortex imports of Logos";
      };

      _ci-check = {
        type = "app";
        program = "${ci-check}/bin/ci-check";
        meta.description = "Run the CI-aligned local check suite";
      };

      lint-haskell = {
        type = "app";
        program = "${lint-haskell}/bin/lint-haskell";
        meta.description = "Run HLint across Cortex Haskell sources";
      };

      lean-lint = {
        type = "app";
        program = "${lean-lint}/bin/lean-lint";
        meta.description = "Run strict mechanical lint checks over Lean theory files";
      };

      docs-lint = {
        type = "app";
        program = "${docs-lint}/bin/docs-lint";
        meta.description = "Run strict mechanical lint checks over Markdown docs";
      };
    };
  };
}
