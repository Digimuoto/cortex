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
      specVersion = "1.10";
      identifier = { name = "safe-money-aeson"; version = "0.1.1"; };
      license = "BSD-3-Clause";
      copyright = "Copyright (c) Renzo Carbonara 2016-2018";
      maintainer = "renλren!zone";
      author = "Renzo Carbonara";
      homepage = "https://github.com/k0001/safe-money";
      url = "";
      synopsis = "Instances from the aeson library for the safe-money library.";
      description = "This library exports @FromJSON@ and @ToJSON@ instances (from the\n@aeson@ library) for many of the types exported by the @safe-money@\nlibrary.\n\nNote: The code in this library used to be part of the @safe-money@\nlibrary itself, so these instances are intended to be backwards\ncompatible with older versions of @safe-money@.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."safe-money" or (errorHandler.buildDepError "safe-money"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
        ];
        buildable = true;
      };
      tests = {
        "test" = {
          depends = [
            (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."safe-money" or (errorHandler.buildDepError "safe-money"))
            (hsPkgs."safe-money-aeson" or (errorHandler.buildDepError "safe-money-aeson"))
            (hsPkgs."tasty" or (errorHandler.buildDepError "tasty"))
            (hsPkgs."tasty-hunit" or (errorHandler.buildDepError "tasty-hunit"))
            (hsPkgs."tasty-quickcheck" or (errorHandler.buildDepError "tasty-quickcheck"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/safe-money-aeson-0.1.1.tar.gz";
      sha256 = "43b0724c1b708322ade366f886e19a581846c67c517e4cd52d540cf3fbe31cd5";
    });
  }) // {
    package-description-override = "name: safe-money-aeson\nversion: 0.1.1\nlicense: BSD3\nlicense-file: LICENSE\ncopyright: Copyright (c) Renzo Carbonara 2016-2018\nauthor: Renzo Carbonara\nmaintainer: renλren!zone\nstability: Experimental\ntested-with: GHC==8.4.1\nhomepage: https://github.com/k0001/safe-money\nbug-reports: https://github.com/k0001/safe-money/issues\ncategory: Money\nbuild-type: Simple\ncabal-version: >=1.10\nextra-source-files: README.md changelog.md\nsynopsis: Instances from the aeson library for the safe-money library.\ndescription:\n  This library exports @FromJSON@ and @ToJSON@ instances (from the\n  @aeson@ library) for many of the types exported by the @safe-money@\n  library.\n  .\n  Note: The code in this library used to be part of the @safe-money@\n  library itself, so these instances are intended to be backwards\n  compatible with older versions of @safe-money@.\n\nsource-repository head\n  type: git\n  location: https://github.com/k0001/safe-money\n\nlibrary\n  default-language: Haskell2010\n  hs-source-dirs: src\n  ghc-options: -Wall -O2\n  build-depends:\n    aeson,\n    base >=4.8 && <5.0,\n    safe-money >=0.8,\n    text\n  exposed-modules:\n    Money.Aeson\n\ntest-suite test\n  default-language: Haskell2010\n  type: exitcode-stdio-1.0\n  hs-source-dirs: test\n  main-is: Main.hs\n  build-depends:\n    aeson,\n    base,\n    bytestring,\n    safe-money,\n    safe-money-aeson,\n    tasty,\n    tasty-hunit,\n    tasty-quickcheck,\n    text\n";
  }