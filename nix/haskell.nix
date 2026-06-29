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
      (final: prev: let
        patchDarwinBootstrapGhc = compiler:
          compiler.overrideAttrs (old: {
            postConfigure =
              (old.postConfigure or "")
              + final.lib.optionalString (final.stdenv.hostPlatform.isDarwin && final.stdenv.hostPlatform.isAarch64) ''
                for config in mk/config.mk hadrian/cfg/system.config; do
                  if grep -q '${final.stdenv.cc}/bin/cc -std=gnu23' "$config"; then
                    substituteInPlace "$config" \
                      --replace-fail "${final.stdenv.cc}/bin/cc -std=gnu23" "${final.stdenv.cc}/bin/cc"
                  fi
                done
              '';
            preConfigure =
              final.lib.optionalString (final.stdenv.hostPlatform.isDarwin && final.stdenv.hostPlatform.isAarch64) ''
                export ac_cv_prog_cc_c23=
                export CXX_STD_LIB_LIBS="c++ c++abi"
                export CXX_STD_LIB_LIB_DIRS="${final.darwin.libcxx}/lib"
                export CXX_STD_LIB_DYN_LIB_DIRS="${final.darwin.libcxx}/lib"
              ''
              + (old.preConfigure or "");
            preInstall =
              final.lib.optionalString (final.stdenv.hostPlatform.isDarwin && final.stdenv.hostPlatform.isAarch64) ''
                export ac_cv_prog_cc_c23=
                export CXX_STD_LIB_LIBS="c++ c++abi"
                export CXX_STD_LIB_LIB_DIRS="${final.darwin.libcxx}/lib"
                export CXX_STD_LIB_DYN_LIB_DIRS="${final.darwin.libcxx}/lib"
              ''
              + (old.preInstall or "");
            postInstall =
              (old.postInstall or "")
              + final.lib.optionalString (final.stdenv.hostPlatform.isDarwin && final.stdenv.hostPlatform.isAarch64) ''
                packageDb=$(find "$out/lib" -path '*/package.conf.d' -type d | head -n1)
                if [ -n "$packageDb" ]; then
                  mkdir -p "$out/envDeps" "$out/exactDeps"
                  for pkgId in $("$out/bin/ghc-pkg" -v0 --global-package-db="$packageDb" list --simple-output); do
                    if name=$("$out/bin/ghc-pkg" -v0 --global-package-db="$packageDb" field "$pkgId" name --simple-output 2>/dev/null); then
                      id=$("$out/bin/ghc-pkg" -v0 --global-package-db="$packageDb" field "$pkgId" id --simple-output)
                      ver=$("$out/bin/ghc-pkg" -v0 --global-package-db="$packageDb" field "$pkgId" version --simple-output)
                      mkdir -p "$out/exactDeps/$name"
                      echo "--dependency=$name=$id" > "$out/exactDeps/$name/configure-flags"
                      {
                        echo "constraint: $name == $ver"
                        echo "constraint: $name installed"
                      } > "$out/exactDeps/$name/cabal.config"
                      echo "package-id $id" > "$out/envDeps/$name"
                    fi
                  done
                fi
              '';
            buildInputs =
              (old.buildInputs or [])
              ++ final.lib.optionals (final.stdenv.hostPlatform.isDarwin && final.stdenv.hostPlatform.isAarch64) [
                final.darwin.libcxx
              ];
            passthru =
              (old.passthru or {})
              // final.lib.optionalAttrs (compiler ? buildGHC) {
                buildGHC = compiler.buildGHC;
              }
              // final.lib.optionalAttrs (compiler ? raw-src) {
                raw-src = compiler.raw-src;
              };
          });
      in {
        haskell =
          prev.haskell
          // {
            compiler =
              prev.haskell.compiler
              // {
                # GHC 9.10's Darwin toolchain may bootstrap through older GHCs.
                # When that compiler has to build from source on aarch64-darwin,
                # its configure script probes libc++ linkage via CC without LDFLAGS.
                ghc948 = patchDarwinBootstrapGhc prev.haskell.compiler.ghc948;
                ghc967 = patchDarwinBootstrapGhc prev.haskell.compiler.ghc967;
              };
          };
      })
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
      # Native Wire -> Amazon Braket runners (wrapped by nix/quantum.nix under the
      # public wire-quantum-* names; kept under -bin keys to avoid a name clash).
      wire-quantum-braket-bin = projectFlake.packages."cortex:exe:wire-quantum-braket" or null;
      wire-quantum-qec-repetition-braket-bin = projectFlake.packages."cortex:exe:wire-quantum-qec-repetition-braket" or null;
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
