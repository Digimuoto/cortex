{
  perSystem = {
    lib,
    pkgs,
    ...
  }: let
    cortexTheory = pkgs.leanPackages.buildLakePackage {
      pname = "cortex-theory";
      version = "0.1.0";
      src = ../theory;
      leanPackageName = "cortex-theory";
      lakeHash = "sha256-wZ0y94pkNWerPhDPTIZByZ7Yu3f2OGy+/1/ioDEg8Lg=";
      leanDeps = with pkgs.leanPackages; [
        batteries
        aesop
        Qq
        proofwidgets
        plausible
        LeanSearchClient
        importGraph
        Cli
      ];

      # Build the proof surface through Nix. The smoke executable remains a
      # direct Lake workflow because native executable builds try to export
      # dependency objects into read-only Nix store paths.
      buildTargets = ["Cortex"];

      meta = {
        description = "Lean 4 mechanization of the Cortex substrate";
      };
    };
  in {
    packages.cortex-theory = cortexTheory;

    checks.cortex-theory = cortexTheory;
  };
}
