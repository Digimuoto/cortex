# haskell.nix project configuration for Cortex.
#
# GHC 9.10 pinned (tracks Portman upstream — GHC 9.12 is blocked on
# haskell.nix PR #2441). Materialization eliminates plan-to-nix IFD;
# run `just update-materialized` after any cortex.cabal edit.
{inputs, ...}: {
  perSystem = {
    config,
    system,
    lib,
    ...
  }: let
    overlays = [
      inputs.haskell-nix.overlay
      (final: _prev: {
        cortexProject = final.haskell-nix.project' {
          src = ../.;
          name = "cortex";
          compiler-nix-name = "ghc910";

          # Use committed materialized plans so flake evaluation stays
          # IFD-free. Regenerate with `just update-materialized` after
          # editing `cortex.cabal` or other project inputs that affect the
          # Cabal plan.
          materialized = ./materialized/cortex;
          checkMaterialization = false;

          # Pin Hackage index for reproducibility (tracks Portman's pin).
          index-state = "2026-04-02T00:00:00Z";

          # GHC 9.10 compatibility: some packages haven't updated upper bounds.
          cabalProjectLocal = ''
            allow-newer: all:ghc-prim
            allow-newer: all:base
            allow-newer: all:template-haskell
            allow-newer: all:text
            allow-newer: jose:*
            allow-newer: monad-time:*
          '';

          modules = [
            {
              packages.rel8.doCheck = false;
            }
          ];

          shell = {
            tools = {
              cabal = {};
              hlint = {};
              haskell-language-server = {};
              apply-refact = {};
            };
            buildInputs = with pkgs; [
              haskellPackages.fourmolu
              pkg-config
              zlib
              xz
            ];
          };
        };
      })
    ];

    pkgs = import inputs.nixpkgs {
      inherit system overlays;
      config = inputs.haskell-nix.config;
    };

    projectFlake = pkgs.cortexProject.flake {};
  in {
    _module.args.haskellNixPkgs = pkgs;
    _module.args.haskellProject = pkgs.cortexProject;

    packages = lib.filterAttrs (_: v: v != null) {
      # Main library (named "cortex" to match package name).
      cortex = projectFlake.packages."cortex:lib:cortex" or null;
      # Public sub-library exposing the Platform.* runtime substrate.
      platform-runtime = projectFlake.packages."cortex:lib:platform-runtime" or null;
      # Public sub-library exposing the downstream Logos reasoning layer.
      logos = projectFlake.packages."cortex:lib:logos" or null;
      # Pulse executor — substrate shell; consumers bind their own task registry.
      cortex-pulse = projectFlake.packages."cortex:exe:cortex-pulse" or null;
      # Test suite (built, not run — `nix run .#cortex-tests` to execute).
      cortex-tests = projectFlake.packages."cortex:test:cortex-test" or null;
      # Logos test suite (built, not run — `nix run .#logos-tests` to execute).
      logos-tests = projectFlake.packages."cortex:test:logos-test" or null;
    };

    # Expose flake checks; test-suites excluded from `nix flake check`
    # to keep it deterministic without a DB (some Pulse specs need one).
    checks =
      lib.filterAttrs
      (name: v: v != null && name != "cortex:test:cortex-test" && name != "cortex:test:logos-test")
      (projectFlake.checks or {});

    # Regenerate materialized plans: `nix run .#update-materialized`.
    apps.update-materialized = {
      type = "app";
      program = toString (pkgs.writeShellScript "update-materialized" ''
        set -e
        echo "🔄 Regenerating materialized haskell.nix plans..."
        ${pkgs.cortexProject.plan-nix.passthru.generateMaterialized} nix/materialized/cortex
        echo "✅ Materialized plans regenerated in nix/materialized/cortex/"
        echo "   Don't forget to commit the changes."
      '');
      meta.description = "Regenerate materialized haskell.nix plans under nix/materialized/cortex";
    };
  };
}
