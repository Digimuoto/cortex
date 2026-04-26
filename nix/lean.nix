{
  perSystem = {pkgs, ...}: let
    cortexTheory = pkgs.leanPackages.buildLakePackage {
      pname = "cortex-theory";
      version = "0.1.0";
      src = ../theory;
      leanPackageName = "cortex-theory";

      # Build the smoke executable target explicitly; Lake's default build
      # surface is library-oriented, but the flake should expose something
      # runnable via `nix run .#cortex-theory`.
      buildTargets = ["cortex-theory"];

      meta = {
        description = "Lean 4 mechanization of the Cortex substrate";
        mainProgram = "cortex-theory";
      };
    };
  in {
    packages.cortex-theory = cortexTheory;

    apps.cortex-theory = {
      type = "app";
      program = "${cortexTheory}/bin/cortex-theory";
      meta.description = "Run the Cortex Lean theory smoke executable";
    };

    checks.cortex-theory = cortexTheory;
  };
}
