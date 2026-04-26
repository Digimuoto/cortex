# Shared nixpkgs customisation for flake-parts modules.
{inputs, ...}: {
  perSystem = {system, ...}: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = [
        (final: prev: {
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
