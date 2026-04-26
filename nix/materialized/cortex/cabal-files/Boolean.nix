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
      specVersion = "1.6";
      identifier = { name = "Boolean"; version = "0.2.4"; };
      license = "BSD-3-Clause";
      copyright = "(c) 2009-2013 by Conal Elliott";
      maintainer = "conal@conal.net";
      author = "Conal Elliott";
      homepage = "";
      url = "";
      synopsis = "Generalized booleans and numbers";
      description = "Some classes for generalized boolean operations.\nStarting with 0.1.0, this package uses type families.\nUp to version 0.0.2, it used MPTCs with functional dependencies.\nMy thanks to Andy Gill for suggesting & helping with the change.\nThanks also to Alex Horsman for Data.Boolean.Overload and to\nJan Bracker for Data.Boolean.Numbers.\n\nCopyright 2009-2013 Conal Elliott; BSD3 license.";
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
      url = "http://hackage.haskell.org/package/Boolean-0.2.4.tar.gz";
      sha256 = "67216013b02b8ac5b534a1ef25f409f930eea1a85eae801933a01ad43145eef8";
    });
  }) // {
    package-description-override = "Name:                Boolean\r\nVersion:             0.2.4\r\nx-revision:          1\r\nSynopsis:            Generalized booleans and numbers\r\nCategory:            Data\r\nCabal-Version:       >= 1.6\r\nDescription:\r\n  Some classes for generalized boolean operations.\r\n  Starting with 0.1.0, this package uses type families.\r\n  Up to version 0.0.2, it used MPTCs with functional dependencies.\r\n  My thanks to Andy Gill for suggesting & helping with the change.\r\n  Thanks also to Alex Horsman for Data.Boolean.Overload and to\r\n  Jan Bracker for Data.Boolean.Numbers.\r\n  .\r\n  Copyright 2009-2013 Conal Elliott; BSD3 license.\r\nAuthor:              Conal Elliott\r\nMaintainer:          conal@conal.net\r\nCopyright:           (c) 2009-2013 by Conal Elliott\r\nLicense:             BSD3\r\nLicense-File:        COPYING\r\nStability:           experimental\r\nbuild-type:          Simple\r\n\r\nsource-repository head\r\n  type:     git\r\n  location: https://github.com/conal/Boolean.git\r\n\r\nLibrary\r\n  hs-Source-Dirs:      src\r\n  Extensions:\r\n  Build-Depends:       base<5\r\n  Exposed-Modules:\r\n                       Data.Boolean\r\n                       Data.Boolean.Overload\r\n                       Data.Boolean.Numbers\r\n  ghc-options:         -Wall\r\n\r\n--  ghc-prof-options:    -prof -auto-all \r\n";
  }