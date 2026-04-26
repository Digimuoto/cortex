{ system
  , compiler
  , flags
  , pkgs
  , hsPkgs
  , pkgconfPkgs
  , errorHandler
  , config
  , ... }:
  ({
    flags = {};
    package = {
      specVersion = "1.8";
      identifier = { name = "NumInstances"; version = "1.4"; };
      license = "BSD-3-Clause";
      copyright = "";
      maintainer = "conal@conal.net";
      author = "Conal Elliott";
      homepage = "https://github.com/conal/NumInstances";
      url = "";
      synopsis = "Instances of numeric classes for functions and tuples";
      description = "Instances of numeric classes for functions and tuples.\nImport \"Data.NumInstances\" to get all the instances.\nIf you want only function or only tuple instances, import\n\"Data.NumInstances.Function\" or \"Data.NumInstances.Tuple\".";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [ (hsPkgs."base" or (errorHandler.buildDepError "base")) ];
        buildable = true;
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/NumInstances-1.4.tar.gz";
      sha256 = "cbdb2a49346f59ceb5ab38592d7bc52e5205580d431d0ac6d852fd9880e59679";
    });
  }) // {
    package-description-override = "Name:                NumInstances\nVersion:             1.4\nSynopsis:            Instances of numeric classes for functions and tuples\nDescription:         Instances of numeric classes for functions and tuples.\n                     Import \"Data.NumInstances\" to get all the instances.\n                     If you want only function or only tuple instances, import\n                     \"Data.NumInstances.Function\" or \"Data.NumInstances.Tuple\".\nLicense:             BSD3\nLicense-file:        LICENSE\nAuthor:              Conal Elliott\nMaintainer:          conal@conal.net\nCategory:            Data\nBuild-type:          Simple\nCabal-version:       >=1.8\nHomepage:            https://github.com/conal/NumInstances\nExtra-Source-Files:  src-draconian-Num/Data/NumInstances/PreRequisites.hs,\n                     src-relaxed-Num/Data/NumInstances/PreRequisites.hs\n\nSource-Repository head\n  type:     git\n  location: git://github.com/conal/NumInstances.git\n\nLibrary\n  hs-Source-Dirs:      src\n  Exposed-modules:     Data.NumInstances, Data.NumInstances.Function, Data.NumInstances.Tuple\n  Build-Depends:       base<5\n  Other-modules:       Data.NumInstances.Util, Data.NumInstances.PreRequisites\n\n  if impl(ghc < 7.4)\n    hs-Source-Dirs:    src-draconian-Num\n  else\n    hs-Source-Dirs:    src-relaxed-Num\n\n-- This module used to be part of vector-space\n\n ghc-prof-options:    -prof -auto-all \n";
  }