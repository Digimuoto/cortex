{
  description = "Cortex — durable runtime and Wire language substrate";

  nixConfig = {
    extra-substituters = [
      "https://cache.digimuoto.com/digimuoto"
      "https://cache.iog.io"
    ];
    extra-trusted-public-keys = [
      "digimuoto:GwbeTccfYk+oeV3BLGKC5gzqDJmbHYetR5x0TOBEBCA="
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGkljaxJfsF5+0="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-nix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    repo-docs = {
      url = "github:Digimuoto/repo-docs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    haskell-platform-src = {
      url = "git+ssh://git@github.com/Digimuoto/haskell-platform.git";
      flake = false;
    };
    logos-src = {
      url = "git+ssh://git@github.com/Digimuoto/logos.git";
      flake = false;
    };
  };

  outputs = inputs @ {
    self,
    flake-parts,
    nixpkgs,
    haskell-nix,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      # Initial scaffold targets only x86_64-linux. Additional systems can
      # be added once the Haskell layer is exercised there too.
      systems = ["x86_64-linux"];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.pre-commit-hooks.flakeModule
        inputs.repo-docs.flakeModules.default

        ./nix/flake-module.nix
      ];

      flake = {
        nixvimModules.default = import ./nix/modules/nixvim-wire.nix {inherit self;};
        nixvimModules.wire = import ./nix/modules/nixvim-wire.nix {inherit self;};
      };
    };
}
