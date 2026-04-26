{inputs, ...}: {
  perSystem = {
    config,
    pkgs,
    haskellNixPkgs,
    system,
    ...
  }: let
    # Terminal-highlight a .wire file using the bundled tree-sitter grammar.
    hl-wire = pkgs.writeShellScriptBin "hl-wire" ''
      set -eu
      if [ -z "''${TREE_SITTER_DIR:-}" ]; then
        echo "hl-wire: TREE_SITTER_DIR is not set. Run from inside \`nix develop\`." >&2
        exit 1
      fi
      target="''${1:-}"
      if [ -z "$target" ]; then
        echo "usage: hl-wire <path.wire>" >&2
        exit 1
      fi
      if [ ! -f "$target" ]; then
        echo "hl-wire: not a file: $target" >&2
        exit 1
      fi
      exec ${pkgs.tree-sitter}/bin/tree-sitter highlight "$target"
    '';
  in {
    devShells.default = pkgs.mkShell {
      name = "cortex-dev";

      packages =
        (with haskellNixPkgs; [
          haskellPackages.fourmolu
          haskellPackages.ormolu
        ])
        ++ (with pkgs; [
          pkg-config
          zlib
          xz

          # Dev tooling
          git
          jq
          ripgrep
          fd
          just

          # Formatters
          alejandra
          config.pre-commit.settings.package
          config.treefmt.build.wrapper

          # Wire DSL
          tree-sitter
          hl-wire

          # Lean 4 mechanization track (theory/).
          # `elan` resolves the toolchain version pinned in
          # `theory/lean-toolchain` and provides `lake`, `lean`, `leanc`.
          elan
        ]);

      shellHook = ''
        ${config.pre-commit.installationScript or ""}

        # Tree-sitter grammar discovery for `hl-wire` and bare `tree-sitter`.
        export TREE_SITTER_DIR=''${TREE_SITTER_DIR:-$PWD/.cache/tree-sitter}
        mkdir -p "$TREE_SITTER_DIR"
        cat > "$TREE_SITTER_DIR/config.json" <<JSON
        { "parser-directories": ["$PWD/editors"] }
        JSON

        cat << 'EOF'
        Cortex Development Shell
        ========================

        Use 'just' for all commands:
          just --list      # Show all commands
          just build       # Build the library
          just build-pulse # Build cortex-pulse
          just test        # Run test suite
          just fmt         # Format code
          just docs-dev    # Docs dev server

        Wire DSL:
          hl-wire <path.wire>   # Terminal-highlight a .wire file

        Lean 4 theory:
          just lean-build       # Build the proof tree
          just lean-run         # Build + run the smoke executable

        EOF
      '';
    };
  };
}
