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
      identifier = { name = "raw-strings-qq"; version = "1.1"; };
      license = "BSD-3-Clause";
      copyright = "(c) Mikhail Glushenkov 2013-2015";
      maintainer = "mikhail.glushenkov@gmail.com";
      author = "Mikhail Glushenkov";
      homepage = "https://github.com/23Skidoo/raw-strings-qq";
      url = "";
      synopsis = "Raw string literals for Haskell.";
      description = "A quasiquoter for raw string literals - that is, string literals that don't\nrecognise the standard escape sequences (such as @\\'\\\\n\\'@). Basically, they\nmake your code more readable by freeing you from the responsibility to\nescape backslashes. They are useful when working with regular expressions,\nDOS/Windows paths and markup languages (such as XML).\n\nSee @examples/RawRegex.hs@ for a usage example.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."template-haskell" or (errorHandler.buildDepError "template-haskell"))
        ];
        buildable = true;
      };
      tests = {
        "tests" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."raw-strings-qq" or (errorHandler.buildDepError "raw-strings-qq"))
            (hsPkgs."HUnit" or (errorHandler.buildDepError "HUnit"))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/raw-strings-qq-1.1.tar.gz";
      sha256 = "2e011ec26aeaa53ab43c30b7d9b5b0f661f24b4ebef8884c12c571353c0fbed3";
    });
  }) // {
    package-description-override = "name:                raw-strings-qq\nversion:             1.1\nsynopsis:            Raw string literals for Haskell.\ndescription:\n\n    A quasiquoter for raw string literals - that is, string literals that don't\n    recognise the standard escape sequences (such as @\\'\\\\n\\'@). Basically, they\n    make your code more readable by freeing you from the responsibility to\n    escape backslashes. They are useful when working with regular expressions,\n    DOS/Windows paths and markup languages (such as XML).\n    .\n    See @examples/RawRegex.hs@ for a usage example.\n\nhomepage:            https://github.com/23Skidoo/raw-strings-qq\nbug-reports:         https://github.com/23Skidoo/raw-strings-qq/issues\nlicense:             BSD3\nlicense-file:        LICENSE\nauthor:              Mikhail Glushenkov\nmaintainer:          mikhail.glushenkov@gmail.com\ncopyright:           (c) Mikhail Glushenkov 2013-2015\ncategory:            Text\nbuild-type:          Simple\ncabal-version:       >=1.8\nextra-source-files:  examples/RawRegex.hs\n                     ChangeLog\n\nsource-repository head\n  type:     git\n  location: https://github.com/23Skidoo/raw-strings-qq.git\n\nlibrary\n  exposed-modules:     Text.RawString.QQ\n  build-depends:       base <= 10, template-haskell >= 2.5\n\ntest-suite tests\n  hs-source-dirs: test\n  main-is:        Test.hs\n  type:           exitcode-stdio-1.0\n  build-depends:  base,\n                  raw-strings-qq,\n                  HUnit\n  ghc-options:    -Wall\n";
  }