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
      identifier = { name = "cabal-doctest"; version = "1.0.12"; };
      license = "BSD-3-Clause";
      copyright = "(c) 2017-2020 Oleg Grenrus, 2020- package maintainers";
      maintainer = "Max Ulidtko <ulidtko@gmail.com>";
      author = "Oleg Grenrus <oleg.grenrus@iki.fi>";
      homepage = "https://github.com/ulidtko/cabal-doctest";
      url = "";
      synopsis = "A Setup.hs helper for running doctests";
      description = "As of now (end of 2024), there isn't @cabal doctest@\ncommand. Yet, to properly work, @doctest@ needs plenty of configuration.\nThis library provides the common bits for writing a custom @Setup.hs@.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."Cabal" or (errorHandler.buildDepError "Cabal"))
          (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
          (hsPkgs."filepath" or (errorHandler.buildDepError "filepath"))
        ];
        buildable = true;
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/cabal-doctest-1.0.12.tar.gz";
      sha256 = "3111f0d23045fe650637f73bd7dc9537760317495c6ccce8549e7ec59aa39b2c";
    });
  }) // {
    package-description-override = "name:               cabal-doctest\r\nversion:            1.0.12\r\nx-revision: 1\r\nsynopsis:           A Setup.hs helper for running doctests\r\ndescription:\r\n  As of now (end of 2024), there isn't @cabal doctest@\r\n  command. Yet, to properly work, @doctest@ needs plenty of configuration.\r\n  This library provides the common bits for writing a custom @Setup.hs@.\r\n\r\nhomepage:           https://github.com/ulidtko/cabal-doctest\r\nlicense:            BSD3\r\nlicense-file:       LICENSE\r\nauthor:             Oleg Grenrus <oleg.grenrus@iki.fi>\r\nmaintainer:         Max Ulidtko <ulidtko@gmail.com>\r\ncopyright:          (c) 2017-2020 Oleg Grenrus, 2020- package maintainers\r\ncategory:           Distribution\r\nbuild-type:         Simple\r\ncabal-version:      >=1.10\r\nextra-source-files:\r\n  changelog.md\r\n  README.md\r\n\r\ntested-with:\r\n  GHC == 9.14.1\r\n  GHC == 9.12.2\r\n  GHC == 9.10.3\r\n  GHC == 9.8.4\r\n  GHC == 9.6.7\r\n  GHC == 9.4.8\r\n  GHC == 9.2.8\r\n  GHC == 9.0.2\r\n  GHC == 8.10.7\r\n  GHC == 8.8.4\r\n  GHC == 8.6.5\r\n  GHC == 8.4.4\r\n  GHC == 8.2.2\r\n  GHC == 8.0.2\r\n  -- 2023-10-14: Dropped CI support for GHC 7.x\r\n\r\nsource-repository head\r\n  type:     git\r\n  location: https://github.com/ulidtko/cabal-doctest\r\n\r\nlibrary\r\n  exposed-modules:  Distribution.Extra.Doctest\r\n  other-modules:\r\n  other-extensions:\r\n  build-depends:\r\n    -- NOTE: contrary to PVP, some upper-bounds are intentionally set to major-major.\r\n    -- This is to increase signal-to-noise ratio of CI failures. \"Too tight bounds\"\r\n    -- is an extremely boring (and practically guaranteed, repeatedly) failure mode.\r\n    -- OTOH, genuine build failures due to breaking changes in dependencies are:\r\n    --  1) unlikely to occur, as this package is so small, moreso regularly;\r\n    --  2) best caught in CI pipelines that don't induce alert fatigue.\r\n    -- In any case, revisions may set tighter bounds afterwards, if exceptional\r\n    -- circumstances would warrant that.\r\n      base       >=4.9  && <5\r\n    , Cabal      >=1.24 && <3.18\r\n    , directory  >=1.3  && <2\r\n    , filepath   >=1.4  && <2\r\n\r\n  hs-source-dirs:   src\r\n  default-language: Haskell2010\r\n  ghc-options:      -Wall\r\n";
  }