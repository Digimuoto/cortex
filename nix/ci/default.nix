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

    lint-haskell = pkgs.writeShellApplication {
      name = "lint-haskell";
      runtimeInputs = [pkgs.haskellPackages.hlint];
      text = ''
        set -euo pipefail
        exec hlint src src-platform app test
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

        echo "Step 2: Haskell lint"
        lint-haskell
        echo

        echo "Step 3: Lean lint"
        lean-lint
        echo

        echo "Step 4: docs lint"
        docs-lint
        echo

        echo "Step 5: Lean theory"
        check-theory
        echo

        echo "Step 6: flake checks"
        nix flake check --print-build-logs
      '';
    };
  in {
    packages = {
      _check-format = check-format;
      _check-theory = check-theory;
      _ci-check = ci-check;
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
