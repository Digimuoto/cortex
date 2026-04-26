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
      specVersion = "2.2";
      identifier = { name = "insert-ordered-containers"; version = "0.2.7"; };
      license = "BSD-3-Clause";
      copyright = "";
      maintainer = "Erik de Castro Lopo <erikd@mega-nerd.com>, Oleg Grenrus <oleg.grenrus@iki.fi>";
      author = "Oleg Grenrus <oleg.grenrus@iki.fi>";
      homepage = "https://github.com/erikd/insert-ordered-containers#readme";
      url = "";
      synopsis = "Associative containers retaining insertion order for traversals.";
      description = "Associative containers retaining insertion order for traversals.\n\nThe implementation is based on `unordered-containers`.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."deepseq" or (errorHandler.buildDepError "deepseq"))
          (hsPkgs."hashable" or (errorHandler.buildDepError "hashable"))
          (hsPkgs."indexed-traversable" or (errorHandler.buildDepError "indexed-traversable"))
          (hsPkgs."lens" or (errorHandler.buildDepError "lens"))
          (hsPkgs."optics-core" or (errorHandler.buildDepError "optics-core"))
          (hsPkgs."optics-extra" or (errorHandler.buildDepError "optics-extra"))
          (hsPkgs."semigroupoids" or (errorHandler.buildDepError "semigroupoids"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."transformers" or (errorHandler.buildDepError "transformers"))
          (hsPkgs."unordered-containers" or (errorHandler.buildDepError "unordered-containers"))
        ];
        buildable = true;
      };
      tests = {
        "ins-ord-containers-tests" = {
          depends = [
            (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."base-compat" or (errorHandler.buildDepError "base-compat"))
            (hsPkgs."hashable" or (errorHandler.buildDepError "hashable"))
            (hsPkgs."insert-ordered-containers" or (errorHandler.buildDepError "insert-ordered-containers"))
            (hsPkgs."lens" or (errorHandler.buildDepError "lens"))
            (hsPkgs."QuickCheck" or (errorHandler.buildDepError "QuickCheck"))
            (hsPkgs."semigroupoids" or (errorHandler.buildDepError "semigroupoids"))
            (hsPkgs."tasty" or (errorHandler.buildDepError "tasty"))
            (hsPkgs."tasty-quickcheck" or (errorHandler.buildDepError "tasty-quickcheck"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."unordered-containers" or (errorHandler.buildDepError "unordered-containers"))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/insert-ordered-containers-0.2.7.tar.gz";
      sha256 = "77edbb1b76e6598aeb05f0711942976432b52178cbfd2a62f4a87f3baf623617";
    });
  }) // {
    package-description-override = "cabal-version:      2.2\r\nname:               insert-ordered-containers\r\nversion:            0.2.7\r\nx-revision: 2\r\nsynopsis:\r\n  Associative containers retaining insertion order for traversals.\r\n\r\ndescription:\r\n  Associative containers retaining insertion order for traversals.\r\n  .\r\n  The implementation is based on `unordered-containers`.\r\n\r\ncategory:           Web\r\nhomepage:           https://github.com/erikd/insert-ordered-containers#readme\r\nbug-reports:        https://github.com/erikd/insert-ordered-containers/issues\r\nauthor:             Oleg Grenrus <oleg.grenrus@iki.fi>\r\nmaintainer:         Erik de Castro Lopo <erikd@mega-nerd.com>, Oleg Grenrus <oleg.grenrus@iki.fi>\r\nlicense:            BSD-3-Clause\r\nlicense-file:       LICENSE\r\nbuild-type:         Simple\r\ntested-with:\r\n  GHC ==8.6.5\r\n   || ==8.8.4\r\n   || ==8.10.7\r\n   || ==9.0.2\r\n   || ==9.2.8\r\n   || ==9.4.8\r\n   || ==9.6.7\r\n   || ==9.8.4\r\n   || ==9.10.1\r\n   || ==9.12.1\r\n\r\nextra-source-files:\r\n  CHANGELOG.md\r\n  README.md\r\n\r\nsource-repository head\r\n  type:     git\r\n  location: https://github.com/erikd/insert-ordered-containers\r\n\r\nlibrary\r\n  default-language: Haskell2010\r\n  hs-source-dirs:   src\r\n  ghc-options:      -Wall\r\n  build-depends:\r\n    , aeson                 >=2.2.3.0  && <2.3\r\n    , base                  >=4.12.0.0 && <4.22\r\n    , deepseq               >=1.4.4.0  && <1.6\r\n    , hashable              >=1.4.7.0  && <1.6\r\n    , indexed-traversable   >=0.1.4    && <0.2\r\n    , lens                  >=5.2.3    && <5.4\r\n    , optics-core           >=0.4.1.1  && <0.5\r\n    , optics-extra          >=0.4.2.1  && <0.5\r\n    , semigroupoids         >=6.0.1    && <6.1\r\n    , text                  >=1.2.3.0  && <1.3  || >=2.0     && <2.2\r\n    , transformers          >=0.5.6.2  && <0.7\r\n    , unordered-containers  >=0.2.20   && <0.3\r\n\r\n  exposed-modules:\r\n    Data.HashMap.Strict.InsOrd\r\n    Data.HashSet.InsOrd\r\n\r\n  other-modules:    Data.HashMap.InsOrd.Internal\r\n\r\ntest-suite ins-ord-containers-tests\r\n  default-language: Haskell2010\r\n  type:             exitcode-stdio-1.0\r\n  main-is:          Tests.hs\r\n  hs-source-dirs:   test\r\n  ghc-options:      -Wall\r\n\r\n  -- inherited from library\r\n  build-depends:\r\n    , aeson\r\n    , base\r\n    , base-compat\r\n    , hashable\r\n    , insert-ordered-containers\r\n    , lens\r\n    , QuickCheck                 >=2.13.2   && <2.19\r\n    , semigroupoids\r\n    , tasty                      >=0.10.1.2 && <1.6\r\n    , tasty-quickcheck           >=0.8.3.2  && <0.12\r\n    , text\r\n    , unordered-containers\r\n";
  }