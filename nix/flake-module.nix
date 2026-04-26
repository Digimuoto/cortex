# Central flake-parts module for Cortex.
# Imports the per-concern Nix modules.
#
#   nix/
#   ├── flake-module.nix  <- You are here
#   ├── haskell.nix       <- haskell.nix project (Haskell libs + executables)
#   ├── devshell.nix      <- Development shell
#   ├── docs.nix          <- repo-docs integration (cortex site at routeBase "/")
#   ├── editors.nix       <- Tree-sitter grammar packages
#   └── ci/
#       └── formatter.nix <- treefmt config
{
  imports = [
    ./haskell.nix
    ./lean.nix
    ./devshell.nix
    ./docs.nix
    ./editors.nix
    ./ci
  ];
}
