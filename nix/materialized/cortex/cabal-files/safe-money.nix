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
      identifier = { name = "safe-money"; version = "0.9.1"; };
      license = "BSD-3-Clause";
      copyright = "Copyright (c) Renzo Carbonara 2016-2019";
      maintainer = "renλren!zone";
      author = "Renzo Carbonara";
      homepage = "https://github.com/k0001/safe-money";
      url = "";
      synopsis = "Type-safe and lossless encoding and manipulation of money, fiat\ncurrencies, crypto currencies and precious metals.";
      description = "The Haskell @safe-money@ library offers type-safe and lossless encoding and\noperations for monetary values in all world currencies, including fiat\ncurrencies, precious metals and crypto-currencies.\n\nUseful instances for the many types defined by @safe-money@ can be found\nin these other libraries:\n\n* [safe-money-aeson](https://hackage.haskell.org/package/safe-money-aeson):\n@FromJSON@ and @ToJSON@ instances (from the [aeson](https://hackage.haskell.org/package/aeson) library).\n\n* [safe-money-cereal](https://hackage.haskell.org/package/safe-money-cereal):\n@Serialize@ instances (from the [cereal](https://hackage.haskell.org/package/cereal) library).\n\n* [safe-money-serialise](https://hackage.haskell.org/package/safe-money-serialise):\n@Serialise@ instances (from the [serialise](https://hackage.haskell.org/package/serialise) library).\n\n* [safe-money-store](https://hackage.haskell.org/package/safe-money-store):\n@Store@ instances (from the [store](https://hackage.haskell.org/package/store) library).\n\n* [safe-money-xmlbf](https://hackage.haskell.org/package/safe-money-xmlbf):\n@FromXml@ and @ToXml@ instances (from the [xmlbf](https://hackage.haskell.org/package/xmlbf) library).";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."binary" or (errorHandler.buildDepError "binary"))
          (hsPkgs."constraints" or (errorHandler.buildDepError "constraints"))
          (hsPkgs."hashable" or (errorHandler.buildDepError "hashable"))
          (hsPkgs."deepseq" or (errorHandler.buildDepError "deepseq"))
          (hsPkgs."QuickCheck" or (errorHandler.buildDepError "QuickCheck"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."vector-space" or (errorHandler.buildDepError "vector-space"))
        ];
        buildable = true;
      };
      tests = {
        "test" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."binary" or (errorHandler.buildDepError "binary"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."constraints" or (errorHandler.buildDepError "constraints"))
            (hsPkgs."deepseq" or (errorHandler.buildDepError "deepseq"))
            (hsPkgs."hashable" or (errorHandler.buildDepError "hashable"))
            (hsPkgs."safe-money" or (errorHandler.buildDepError "safe-money"))
            (hsPkgs."tasty" or (errorHandler.buildDepError "tasty"))
            (hsPkgs."tasty-hunit" or (errorHandler.buildDepError "tasty-hunit"))
            (hsPkgs."tasty-quickcheck" or (errorHandler.buildDepError "tasty-quickcheck"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."vector-space" or (errorHandler.buildDepError "vector-space"))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/safe-money-0.9.1.tar.gz";
      sha256 = "453be3217f75e72966597a2b5222e4a1bea9aeac4de490cdf4f4208f0cffd10d";
    });
  }) // {
    package-description-override = "name: safe-money\nversion: 0.9.1\nlicense: BSD3\nlicense-file: LICENSE\ncopyright: Copyright (c) Renzo Carbonara 2016-2019\nauthor: Renzo Carbonara\nmaintainer: renλren!zone\nstability: Experimental\ntested-with: GHC==8.4.1\nhomepage: https://github.com/k0001/safe-money\nbug-reports: https://github.com/k0001/safe-money/issues\ncategory: Money\nbuild-type: Simple\ncabal-version: >=1.10\nextra-source-files: README.md changelog.md\nsynopsis:\n  Type-safe and lossless encoding and manipulation of money, fiat\n  currencies, crypto currencies and precious metals.\ndescription:\n  The Haskell @safe-money@ library offers type-safe and lossless encoding and\n  operations for monetary values in all world currencies, including fiat\n  currencies, precious metals and crypto-currencies.\n  .\n  Useful instances for the many types defined by @safe-money@ can be found\n  in these other libraries:\n  .\n  * [safe-money-aeson](https://hackage.haskell.org/package/safe-money-aeson):\n    @FromJSON@ and @ToJSON@ instances (from the [aeson](https://hackage.haskell.org/package/aeson) library).\n  .\n  * [safe-money-cereal](https://hackage.haskell.org/package/safe-money-cereal):\n    @Serialize@ instances (from the [cereal](https://hackage.haskell.org/package/cereal) library).\n  .\n  * [safe-money-serialise](https://hackage.haskell.org/package/safe-money-serialise):\n    @Serialise@ instances (from the [serialise](https://hackage.haskell.org/package/serialise) library).\n  .\n  * [safe-money-store](https://hackage.haskell.org/package/safe-money-store):\n    @Store@ instances (from the [store](https://hackage.haskell.org/package/store) library).\n  .\n  * [safe-money-xmlbf](https://hackage.haskell.org/package/safe-money-xmlbf):\n    @FromXml@ and @ToXml@ instances (from the [xmlbf](https://hackage.haskell.org/package/xmlbf) library).\n\nsource-repository head\n  type: git\n  location: https://github.com/k0001/safe-money\n\nlibrary\n  default-language: Haskell2010\n  hs-source-dirs: src\n  ghc-options: -Wall -O2\n  build-depends:\n    base (>=4.8 && <5.0),\n    binary,\n    constraints,\n    hashable,\n    deepseq,\n    QuickCheck,\n    text,\n    vector-space\n  exposed-modules:\n    Money\n    Money.Internal\n\ntest-suite test\n  default-language: Haskell2010\n  type: exitcode-stdio-1.0\n  hs-source-dirs: test\n  main-is: Main.hs\n  build-depends:\n    base,\n    binary,\n    bytestring,\n    constraints,\n    deepseq,\n    hashable,\n    safe-money,\n    tasty,\n    tasty-hunit,\n    tasty-quickcheck,\n    text,\n    vector-space\n";
  }