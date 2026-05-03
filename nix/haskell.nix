# haskell.nix project configuration for Cortex.
#
# GHC 9.10 pinned (GHC 9.12 is blocked on haskell.nix PR #2441).
# Materialization eliminates plan-to-nix IFD; run `just update-materialized`
# after any cortex.cabal edit.
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

          # Pin Hackage index for reproducibility.
          index-state = "2026-04-02T00:00:00Z";

          # GHC 9.10 compatibility: some packages haven't updated upper bounds.
          # Keep upstream package extra-source-files such as README.md and
          # NOTICE at the package root, or regenerate materialization after
          # changing them.
          cabalProjectLocal = ''
            packages:
              ${inputs.haskell-platform-src.outPath}

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
      # Pulse executor — substrate shell; consumers bind their own task registry.
      cortex-pulse = projectFlake.packages."cortex:exe:cortex-pulse" or null;
      # Wire source CLI — local build/run workflows for .wire files.
      wire = projectFlake.packages."cortex:exe:wire" or null;
      # Opt-in Criterion benchmark for Wire pure evaluation.
      pure-wire-bench = projectFlake.packages."cortex:bench:pure-wire-bench" or null;
      # Test suite (built, not run — `nix run .#cortex-tests` to execute).
      cortex-tests = projectFlake.packages."cortex:test:cortex-test" or null;
      # Locked upstream source snapshot for dependency visibility.
      haskell-platform-source = pkgs.runCommand "haskell-platform-source" {} ''
        ln -s ${inputs.haskell-platform-src.outPath} "$out"
      '';
    };

    # Expose flake checks; test-suites excluded from `nix flake check`
    # to keep it deterministic without a DB (some Pulse specs need one).
    checks =
      lib.filterAttrs
      (
        name: v:
          v
          != null
          && name != "cortex:test:cortex-test"
          && name != "cortex:bench:pure-wire-bench"
          && name != "haskell-platform:test:platform-test"
          && name != "haskell-platform:test:platform-integration-test"
      )
      (projectFlake.checks or {});

    # Regenerate materialized plans: `nix run .#update-materialized`.
    apps = {
      wire = {
        type = "app";
        program = "${projectFlake.packages."cortex:exe:wire"}/bin/wire";
        meta.description = "Work with Wire source files";
      };
      pure-wire-bench = {
        type = "app";
        program = "${projectFlake.packages."cortex:bench:pure-wire-bench"}/bin/pure-wire-bench";
        meta.description = "Run Criterion benchmarks for Wire pure evaluation";
      };
      update-materialized = {
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
  };
}
