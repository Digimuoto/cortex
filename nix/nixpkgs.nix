# Shared nixpkgs customisation for flake-parts modules.
{inputs, ...}: {
  perSystem = {system, ...}: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [
        (final: prev: {
          haskellPackages = prev.haskellPackages.override {
            overrides = hfinal: hprev: {
              # repo-docs' generated Haddock integration uses nixpkgs
              # callCabal2nix, while the main Cortex build uses
              # haskell.nix with allow-newer policy. Apply the same
              # upper-bound posture to docs-only Haddock generation.
              callCabal2nix = name: src: args:
                final.haskell.lib.doJailbreak (hprev.callCabal2nix name src args);

              rel8 =
                final.haskell.lib.overrideCabal hprev.rel8
                (_old: {
                  doCheck = false;
                  testHaskellDepends = [];
                });
            };
          };

          # `tree-sitter build --wasm` downloads wasi-sdk unless this env var
          # points at a local SDK-shaped compiler. repo-docs calls tree-sitter
          # inside a Nix sandbox, so provide the SDK and linker via the wrapper.
          tree-sitter =
            (final.runCommand "${prev.tree-sitter.name}-with-wasi-sdk" {
                nativeBuildInputs = [final.makeWrapper];
                meta = prev.tree-sitter.meta;
              } ''
                mkdir -p "$out/bin"
                makeWrapper ${prev.tree-sitter}/bin/tree-sitter "$out/bin/tree-sitter" \
                  --set TREE_SITTER_WASI_SDK_PATH ${final.pkgsCross.wasi32.stdenv.cc} \
                  --prefix PATH : ${final.lib.makeBinPath [
                  final.pkgsCross.wasi32.stdenv.cc
                  final.llvmPackages_21.lld
                ]}
              '')
            // {
              inherit (prev.tree-sitter) buildGrammar;
            };
        })
      ];
    };
  };
}
