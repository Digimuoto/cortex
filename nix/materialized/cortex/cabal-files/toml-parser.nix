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
      specVersion = "3.0";
      identifier = { name = "toml-parser"; version = "2.0.2.0"; };
      license = "ISC";
      copyright = "2023 Eric Mertens";
      maintainer = "emertens@gmail.com";
      author = "Eric Mertens";
      homepage = "";
      url = "";
      synopsis = "TOML 1.1.0 parser";
      description = "TOML parser using generated lexers and parsers with\ncareful attention to the TOML 1.1.0 semantics for\ndefining tables.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."array" or (errorHandler.buildDepError "array"))
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
          (hsPkgs."prettyprinter" or (errorHandler.buildDepError "prettyprinter"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."time" or (errorHandler.buildDepError "time"))
          (hsPkgs."transformers" or (errorHandler.buildDepError "transformers"))
        ];
        build-tools = [
          (hsPkgs.pkgsBuildBuild.alex.components.exes.alex or (pkgs.pkgsBuildBuild.alex or (errorHandler.buildToolDepError "alex:alex")))
          (hsPkgs.pkgsBuildBuild.happy.components.exes.happy or (pkgs.pkgsBuildBuild.happy or (errorHandler.buildToolDepError "happy:happy")))
        ];
        buildable = true;
      };
      exes = {
        "toml-benchmarker" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."toml-parser" or (errorHandler.buildDepError "toml-parser"))
            (hsPkgs."time" or (errorHandler.buildDepError "time"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
          ];
          buildable = false;
        };
      };
      tests = {
        "unittests" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
            (hsPkgs."hspec" or (errorHandler.buildDepError "hspec"))
            (hsPkgs."template-haskell" or (errorHandler.buildDepError "template-haskell"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."time" or (errorHandler.buildDepError "time"))
            (hsPkgs."toml-parser" or (errorHandler.buildDepError "toml-parser"))
          ];
          build-tools = [
            (hsPkgs.pkgsBuildBuild.hspec-discover.components.exes.hspec-discover or (pkgs.pkgsBuildBuild.hspec-discover or (errorHandler.buildToolDepError "hspec-discover:hspec-discover")))
          ];
          buildable = true;
        };
        "readme" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."toml-parser" or (errorHandler.buildDepError "toml-parser"))
            (hsPkgs."hspec" or (errorHandler.buildDepError "hspec"))
            (hsPkgs."template-haskell" or (errorHandler.buildDepError "template-haskell"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
          ];
          build-tools = [
            (hsPkgs.pkgsBuildBuild.markdown-unlit.components.exes.markdown-unlit or (pkgs.pkgsBuildBuild.markdown-unlit or (errorHandler.buildToolDepError "markdown-unlit:markdown-unlit")))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/toml-parser-2.0.2.0.tar.gz";
      sha256 = "9e8b5ee5eea9bea2441732347839a8e32e98789055a621f55a72c2df7a8de1a8";
    });
  }) // {
    package-description-override = "cabal-version:      3.0\r\nname:               toml-parser\r\nversion:            2.0.2.0\r\nx-revision: 1\r\nsynopsis:           TOML 1.1.0 parser\r\ndescription:\r\n    TOML parser using generated lexers and parsers with\r\n    careful attention to the TOML 1.1.0 semantics for\r\n    defining tables.\r\nlicense:            ISC\r\nlicense-file:       LICENSE\r\nauthor:             Eric Mertens\r\nmaintainer:         emertens@gmail.com\r\ncopyright:          2023 Eric Mertens\r\ncategory:           Text\r\nbuild-type:         Simple\r\ntested-with:        GHC == {8.10.7, 9.0.2, 9.2.8, 9.4.8, 9.6.7, 9.8.4, 9.10.3, 9.12.2}\r\n\r\nextra-doc-files:\r\n    ChangeLog.md\r\n    README.md\r\n\r\nsource-repository head\r\n    type: git\r\n    location: https://github.com/glguy/toml-parser\r\n    tag: main\r\n\r\ncommon extensions\r\n    default-language:   Haskell2010\r\n    default-extensions:\r\n        BlockArguments\r\n        DeriveDataTypeable\r\n        DeriveGeneric\r\n        DeriveTraversable\r\n        EmptyCase\r\n        FlexibleContexts\r\n        FlexibleInstances\r\n        GeneralizedNewtypeDeriving\r\n        ImportQualifiedPost\r\n        LambdaCase\r\n        ScopedTypeVariables\r\n        TypeOperators\r\n        TypeSynonymInstances\r\n        ViewPatterns\r\n\r\nlibrary\r\n    import:             extensions\r\n    hs-source-dirs:     src\r\n    default-language:   Haskell2010\r\n    exposed-modules:\r\n        Toml\r\n        Toml.Pretty\r\n        Toml.Schema\r\n        Toml.Schema.FromValue\r\n        Toml.Schema.Generic\r\n        Toml.Schema.Generic.FromValue\r\n        Toml.Schema.Generic.ToValue\r\n        Toml.Schema.Matcher\r\n        Toml.Schema.ParseTable\r\n        Toml.Schema.ToValue\r\n        Toml.Semantics\r\n        Toml.Semantics.Ordered\r\n        Toml.Semantics.Types\r\n        Toml.Syntax\r\n        Toml.Syntax.Lexer\r\n        Toml.Syntax.Parser\r\n        Toml.Syntax.Position\r\n        Toml.Syntax.Token\r\n        Toml.Syntax.Types\r\n    other-modules:\r\n        Toml.Syntax.LexerUtils\r\n        Toml.Syntax.ParserUtils\r\n    build-depends:\r\n        array           ^>= 0.5,\r\n        base            ^>= {4.14, 4.15, 4.16, 4.17, 4.18, 4.19, 4.20, 4.21, 4.22},\r\n        containers      ^>= {0.5, 0.6, 0.7, 0.8},\r\n        prettyprinter   ^>= 1.7,\r\n        text            >= 0.2 && < 3,\r\n        time            ^>= {1.9, 1.10, 1.11, 1.12, 1.14, 1.15},\r\n        transformers    ^>= {0.5, 0.6},\r\n    build-tool-depends:\r\n        alex:alex       >= 3.2,\r\n        happy:happy     >= 1.19,\r\n    if impl(ghc >= 9.8)\r\n        ghc-options: -Wno-x-partial\r\n\r\ntest-suite unittests\r\n    import:             extensions\r\n    type:               exitcode-stdio-1.0\r\n    hs-source-dirs:     test\r\n    main-is:            Main.hs\r\n    default-extensions:\r\n        QuasiQuotes\r\n    build-tool-depends:\r\n        hspec-discover:hspec-discover ^>= {2.10, 2.11}\r\n    build-depends:\r\n        base,\r\n        containers,\r\n        hspec           ^>= {2.10, 2.11},\r\n        template-haskell ^>= {2.16, 2.17, 2.18, 2.19, 2.20, 2.21, 2.22, 2.23, 2.24},\r\n        text,\r\n        time,\r\n        toml-parser,\r\n    other-modules:\r\n        DecodeSpec\r\n        DerivingViaSpec\r\n        FromValueSpec\r\n        HieDemoSpec\r\n        LexerSpec\r\n        PrettySpec\r\n        QuoteStr\r\n        TomlSpec\r\n        ToValueSpec\r\n\r\ntest-suite readme\r\n    import:             extensions\r\n    type:               exitcode-stdio-1.0\r\n    main-is:            README.lhs\r\n    ghc-options:        -pgmL markdown-unlit -optL \"haskell toml\"\r\n    default-extensions:\r\n        QuasiQuotes\r\n        DerivingVia\r\n    other-modules:\r\n        QuoteStr\r\n    hs-source-dirs:\r\n        .\r\n        test\r\n    build-depends:\r\n        base,\r\n        toml-parser,\r\n        hspec           ^>= {2.10, 2.11},\r\n        template-haskell ^>= {2.16, 2.17, 2.18, 2.19, 2.20, 2.21, 2.22, 2.23},\r\n        text,\r\n    build-tool-depends:\r\n        markdown-unlit:markdown-unlit ^>= {0.5.1, 0.6.0},\r\n\r\nexecutable toml-benchmarker\r\n    buildable: False\r\n    main-is: benchmarker.hs\r\n    default-language: Haskell2010\r\n    build-depends: base, toml-parser, time, text\r\n    hs-source-dirs: benchmarker\r\n";
  }