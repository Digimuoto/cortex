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
      specVersion = "1.12";
      identifier = { name = "aeson-qq"; version = "0.8.4"; };
      license = "MIT";
      copyright = "";
      maintainer = "Simon Hengel <sol@typeful.net>";
      author = "Oscar Finnsson";
      homepage = "https://github.com/sol/aeson-qq#readme";
      url = "";
      synopsis = "JSON quasiquoter for Haskell";
      description = "@aeson-qq@ provides a JSON quasiquoter for Haskell.\n\nThis package exposes the function `aesonQQ` that compile-time\nconverts a string representation of a JSON value into a\n`Data.Aeson.Value`.  `aesonQQ` has the signature\n\n>aesonQQ :: QuasiQuoter\n\nConsult the @README@ for documentation:\n<https://github.com/sol/aeson-qq#readme>";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
          (hsPkgs."attoparsec" or (errorHandler.buildDepError "attoparsec"))
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."base-compat" or (errorHandler.buildDepError "base-compat"))
          (hsPkgs."haskell-src-meta" or (errorHandler.buildDepError "haskell-src-meta"))
          (hsPkgs."parsec" or (errorHandler.buildDepError "parsec"))
          (hsPkgs."scientific" or (errorHandler.buildDepError "scientific"))
          (hsPkgs."template-haskell" or (errorHandler.buildDepError "template-haskell"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."vector" or (errorHandler.buildDepError "vector"))
        ];
        buildable = true;
      };
      tests = {
        "spec" = {
          depends = [
            (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
            (hsPkgs."attoparsec" or (errorHandler.buildDepError "attoparsec"))
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."base-compat" or (errorHandler.buildDepError "base-compat"))
            (hsPkgs."ghc-prim" or (errorHandler.buildDepError "ghc-prim"))
            (hsPkgs."haskell-src-meta" or (errorHandler.buildDepError "haskell-src-meta"))
            (hsPkgs."hspec" or (errorHandler.buildDepError "hspec"))
            (hsPkgs."parsec" or (errorHandler.buildDepError "parsec"))
            (hsPkgs."scientific" or (errorHandler.buildDepError "scientific"))
            (hsPkgs."template-haskell" or (errorHandler.buildDepError "template-haskell"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."vector" or (errorHandler.buildDepError "vector"))
          ];
          build-tools = [
            (hsPkgs.pkgsBuildBuild.hspec-discover.components.exes.hspec-discover or (pkgs.pkgsBuildBuild.hspec-discover or (errorHandler.buildToolDepError "hspec-discover:hspec-discover")))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/aeson-qq-0.8.4.tar.gz";
      sha256 = "d053eb1c4111dfde709eba87287ac78399faad6cee1fd6727833c3d605a6f336";
    });
  }) // {
    package-description-override = "cabal-version: 1.12\n\n-- This file has been generated from package.yaml by hpack version 0.34.4.\n--\n-- see: https://github.com/sol/hpack\n\nname:             aeson-qq\nversion:          0.8.4\nsynopsis:         JSON quasiquoter for Haskell\ndescription:      @aeson-qq@ provides a JSON quasiquoter for Haskell.\n                  .\n                  This package exposes the function `aesonQQ` that compile-time\n                  converts a string representation of a JSON value into a\n                  `Data.Aeson.Value`.  `aesonQQ` has the signature\n                  .\n                  >aesonQQ :: QuasiQuoter\n                  .\n                  Consult the @README@ for documentation:\n                  <https://github.com/sol/aeson-qq#readme>\nhomepage:         https://github.com/sol/aeson-qq#readme\nbug-reports:      https://github.com/sol/aeson-qq/issues\nlicense:          MIT\nlicense-file:     LICENSE\nauthor:           Oscar Finnsson\nmaintainer:       Simon Hengel <sol@typeful.net>\ncategory:         JSON\nbuild-type:       Simple\n\nsource-repository head\n  type: git\n  location: https://github.com/sol/aeson-qq\n\nlibrary\n  ghc-options: -Wall\n  hs-source-dirs:\n      src\n  exposed-modules:\n      Data.Aeson.QQ\n  other-modules:\n      Data.JSON.QQ\n      Paths_aeson_qq\n  default-language: Haskell2010\n  build-depends:\n      aeson >=0.6\n    , attoparsec\n    , base >=4.5 && <5\n    , base-compat\n    , haskell-src-meta >=0.1.0\n    , parsec\n    , scientific\n    , template-haskell\n    , text\n    , vector\n\ntest-suite spec\n  type: exitcode-stdio-1.0\n  ghc-options: -Wall\n  build-tool-depends:\n      hspec-discover:hspec-discover\n  hs-source-dirs:\n      src\n      test\n  main-is: Spec.hs\n  other-modules:\n      Data.Aeson.QQ\n      Data.JSON.QQ\n      Data.Aeson.QQSpec\n      Data.JSON.QQSpec\n      Person\n      Paths_aeson_qq\n  default-language: Haskell2010\n  build-depends:\n      aeson >=0.6\n    , attoparsec\n    , base >=4.5 && <5\n    , base-compat\n    , ghc-prim\n    , haskell-src-meta >=0.1.0\n    , hspec\n    , parsec\n    , scientific\n    , template-haskell\n    , text\n    , vector\n";
  }