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
    flags = { developer = false; };
    package = {
      specVersion = "1.8";
      identifier = { name = "configurator"; version = "0.3.0.0"; };
      license = "BSD-3-Clause";
      copyright = "Copyright 2011 MailRank, Inc.\nCopyright 2011-2014 Bryan O'Sullivan";
      maintainer = "Bryan O'Sullivan <bos@serpentine.com>";
      author = "Bryan O'Sullivan <bos@serpentine.com>";
      homepage = "http://github.com/bos/configurator";
      url = "";
      synopsis = "Configuration management";
      description = "A configuration management library for programs and daemons.\n\nFeatures include:\n\n* Automatic, dynamic reloading in response to modifications to\nconfiguration files.\n\n* A simple, but flexible, configuration language, supporting several\nof the most commonly needed types of data, along with\ninterpolation of strings from the configuration or the system\nenvironment (e.g. @$(HOME)@).\n\n* Subscription-based notification of changes to configuration\nproperties.\n\n* An @import@ directive allows the configuration of a complex\napplication to be split across several smaller files, or common\nconfiguration data to be shared across several applications.\n\nFor details of the configuration file format, see\n<http://hackage.haskell.org/packages/archive/configurator/latest/doc/html/Data-Configurator.html>.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."attoparsec" or (errorHandler.buildDepError "attoparsec"))
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
          (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
          (hsPkgs."hashable" or (errorHandler.buildDepError "hashable"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."unix-compat" or (errorHandler.buildDepError "unix-compat"))
          (hsPkgs."unordered-containers" or (errorHandler.buildDepError "unordered-containers"))
        ];
        buildable = true;
      };
      tests = {
        "tests" = {
          depends = [
            (hsPkgs."HUnit" or (errorHandler.buildDepError "HUnit"))
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."configurator" or (errorHandler.buildDepError "configurator"))
            (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
            (hsPkgs."filepath" or (errorHandler.buildDepError "filepath"))
            (hsPkgs."test-framework" or (errorHandler.buildDepError "test-framework"))
            (hsPkgs."test-framework-hunit" or (errorHandler.buildDepError "test-framework-hunit"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/configurator-0.3.0.0.tar.gz";
      sha256 = "6eb9996b672e9f7112ca23482c42fa533553312c3c13f38a8a06476e67c031b4";
    });
  }) // {
    package-description-override = "name:            configurator\nversion:         0.3.0.0\nlicense:         BSD3\nlicense-file:    LICENSE\ncategory:        Configuration, Data\ncopyright:       Copyright 2011 MailRank, Inc.\n                 Copyright 2011-2014 Bryan O'Sullivan\nauthor:          Bryan O'Sullivan <bos@serpentine.com>\nmaintainer:      Bryan O'Sullivan <bos@serpentine.com>\nstability:       experimental\ntested-with:     GHC == 7.0, GHC == 7.2, GHC == 7.4, GHC == 7.6, GHC == 7.8\nsynopsis:        Configuration management\ncabal-version:   >= 1.8\nhomepage:        http://github.com/bos/configurator\nbug-reports:     http://github.com/bos/configurator/issues\nbuild-type:      Simple\ndescription:\n  A configuration management library for programs and daemons.\n  .\n  Features include:\n  .\n  * Automatic, dynamic reloading in response to modifications to\n    configuration files.\n  .\n  * A simple, but flexible, configuration language, supporting several\n    of the most commonly needed types of data, along with\n    interpolation of strings from the configuration or the system\n    environment (e.g. @$(HOME)@).\n  .\n  * Subscription-based notification of changes to configuration\n    properties.\n  .\n  * An @import@ directive allows the configuration of a complex\n    application to be split across several smaller files, or common\n    configuration data to be shared across several applications.\n  .\n  For details of the configuration file format, see\n  <http://hackage.haskell.org/packages/archive/configurator/latest/doc/html/Data-Configurator.html>.\n\nextra-source-files:\n    README.markdown\n\ndata-files: tests/resources/*.cfg\n\nflag developer\n  description: operate in developer mode\n  default: False\n  manual: True\n\nlibrary\n  exposed-modules:\n    Data.Configurator\n    Data.Configurator.Types\n\n  other-modules:\n    Data.Configurator.Instances\n    Data.Configurator.Parser\n    Data.Configurator.Types.Internal\n\n  build-depends:\n    attoparsec >= 0.10.0.2,\n    base == 4.*,\n    bytestring,\n    directory,\n    hashable,\n    text >= 0.11.1.0,\n    unix-compat,\n    unordered-containers\n\n  if flag(developer)\n    ghc-options: -Werror\n    ghc-prof-options: -auto-all\n\n  ghc-options:      -Wall\n\nsource-repository head\n  type:     git\n  location: http://github.com/bos/configurator\n\nsource-repository head\n  type:     mercurial\n  location: http://bitbucket.org/bos/configurator\n\ntest-suite tests\n  type:           exitcode-stdio-1.0\n  main-is:        Test.hs\n  hs-source-dirs: tests\n  build-depends:\n    HUnit,\n    base,\n    bytestring,\n    configurator,\n    directory,\n    filepath,\n    test-framework,\n    test-framework-hunit,\n    text\n  ghc-options: -Wall -fno-warn-unused-do-bind\n";
  }