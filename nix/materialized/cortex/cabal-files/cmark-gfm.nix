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
    flags = { pkgconfig = false; };
    package = {
      specVersion = "1.12";
      identifier = { name = "cmark-gfm"; version = "0.2.6"; };
      license = "BSD-3-Clause";
      copyright = "(C) 2015--17 John MacFarlane, (C) 2017--19 Ashe Connor";
      maintainer = "ashe@kivikakk.ee";
      author = "Asherah Connor";
      homepage = "https://github.com/kivikakk/cmark-gfm-hs";
      url = "";
      synopsis = "Fast, accurate GitHub Flavored Markdown parser and renderer";
      description = "This package provides Haskell bindings for\n<https://github.com/github/cmark-gfm libcmark-gfm>, the reference\nparser for <https://github.github.com/gfm/ GitHub Flavored Markdown>, a fully\nspecified variant of Markdown. It includes sources for\nlibcmark-gfm (0.29.0.gfm.13) and does not require prior installation of the\nC library.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
        ] ++ pkgs.lib.optional (compiler.isGhc && compiler.version.lt "7.6") (hsPkgs."ghc-prim" or (errorHandler.buildDepError "ghc-prim"));
        libs = pkgs.lib.optionals (flags.pkgconfig) [
          (pkgs."cmark-gfm" or (errorHandler.sysDepError "cmark-gfm"))
          (pkgs."cmark-gfm-extensions" or (errorHandler.sysDepError "cmark-gfm-extensions"))
        ];
        buildable = true;
      };
      tests = {
        "test-cmark-gfm" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cmark-gfm" or (errorHandler.buildDepError "cmark-gfm"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."HUnit" or (errorHandler.buildDepError "HUnit"))
          ];
          buildable = true;
        };
      };
      benchmarks = {
        "bench-cmark-gfm" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."cmark-gfm" or (errorHandler.buildDepError "cmark-gfm"))
            (hsPkgs."criterion" or (errorHandler.buildDepError "criterion"))
            (hsPkgs."sundown" or (errorHandler.buildDepError "sundown"))
            (hsPkgs."cheapskate" or (errorHandler.buildDepError "cheapskate"))
            (hsPkgs."markdown" or (errorHandler.buildDepError "markdown"))
            (hsPkgs."discount" or (errorHandler.buildDepError "discount"))
            (hsPkgs."blaze-html" or (errorHandler.buildDepError "blaze-html"))
          ];
          buildable = true;
        };
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/cmark-gfm-0.2.6.tar.gz";
      sha256 = "958cfb3bd54b1bfa9e1e2d9cd1748e76c10d2b30a3cceeab3f6a852205c1a869";
    });
  }) // {
    package-description-override = "name:                cmark-gfm\r\nversion:             0.2.6\r\nx-revision: 1\r\nsynopsis:            Fast, accurate GitHub Flavored Markdown parser and renderer\r\ndescription:\r\n  This package provides Haskell bindings for\r\n  <https://github.com/github/cmark-gfm libcmark-gfm>, the reference\r\n  parser for <https://github.github.com/gfm/ GitHub Flavored Markdown>, a fully\r\n  specified variant of Markdown. It includes sources for\r\n  libcmark-gfm (0.29.0.gfm.13) and does not require prior installation of the\r\n  C library.\r\n\r\nhomepage:            https://github.com/kivikakk/cmark-gfm-hs\r\nlicense:             BSD3\r\nlicense-file:        LICENSE\r\nauthor:              Asherah Connor\r\nmaintainer:          ashe@kivikakk.ee\r\ncopyright:           (C) 2015--17 John MacFarlane, (C) 2017--19 Ashe Connor\r\ncategory:            Text\r\nbuild-type:          Simple\r\nextra-source-files:  README.md\r\n                     changelog\r\n                     cbits/chunk.h\r\n                     cbits/cmark-gfm_export.h\r\n                     cbits/debug.h\r\n                     cbits/inlines.h\r\n                     cbits/cmark-gfm.h\r\n                     cbits/houdini.h\r\n                     cbits/references.h\r\n                     cbits/utf8.h\r\n                     cbits/parser.h\r\n                     cbits/cmark-gfm_version.h\r\n                     cbits/html_unescape.h\r\n                     cbits/iterator.h\r\n                     cbits/node.h\r\n                     cbits/buffer.h\r\n                     cbits/render.h\r\n                     cbits/cmark_ctype.h\r\n                     cbits/config.h\r\n                     cbits/scanners.h\r\n                     cbits/case_fold_switch.inc\r\n                     cbits/entities.inc\r\n                     cbits/cmark-gfm-extension_api.h\r\n                     cbits/html.h\r\n                     cbits/plugin.h\r\n                     cbits/registry.h\r\n                     cbits/syntax_extension.h\r\n                     cbits/autolink.h\r\n                     cbits/cmark-gfm-core-extensions.h\r\n                     cbits/ext_scanners.h\r\n                     cbits/strikethrough.h\r\n                     cbits/table.h\r\n                     cbits/tagfilter.h\r\n                     cbits/tasklist.h\r\n                     cbits/map.h\r\n                     cbits/footnotes.h\r\n                     bench/sample.md\r\n                     bench/full-sample.md\r\ncabal-version:       1.14\r\n\r\nSource-repository head\r\n  type:              git\r\n  location:          git://github.com/kivikakk/cmark-gfm-hs.git\r\n\r\nflag pkgconfig\r\n  default:     False\r\n  description: Use system libcmark-gfm via pkgconfig\r\n\r\nlibrary\r\n  exposed-modules:     CMarkGFM\r\n  build-depends:       base >=4.5 && < 5.0,\r\n                       text >= 1.0 && < 2.2,\r\n                       bytestring >= 0.11.5 && < 0.13\r\n  if impl(ghc < 7.6)\r\n    build-depends:     ghc-prim >= 0.2\r\n  default-language:    Haskell2010\r\n  ghc-options:         -Wall -fno-warn-unused-do-bind\r\n  if flag(pkgconfig)\r\n    Extra-Libraries: cmark-gfm cmark-gfm-extensions\r\n  else\r\n    cc-options:        -Wall -std=c99\r\n    Include-dirs:      cbits\r\n    Includes:          cmark-gfm.h\r\n    c-sources:         cbits/houdini_html_u.c\r\n                       cbits/references.c\r\n                       cbits/utf8.c\r\n                       cbits/inlines.c\r\n                       cbits/blocks.c\r\n                       cbits/cmark.c\r\n                       cbits/iterator.c\r\n                       cbits/node.c\r\n                       cbits/buffer.c\r\n                       cbits/cmark_ctype.c\r\n                       cbits/houdini_html_e.c\r\n                       cbits/houdini_href_e.c\r\n                       cbits/scanners.c\r\n                       cbits/html.c\r\n                       cbits/man.c\r\n                       cbits/commonmark.c\r\n                       cbits/latex.c\r\n                       cbits/xml.c\r\n                       cbits/render.c\r\n                       cbits/arena.c\r\n                       cbits/linked_list.c\r\n                       cbits/plaintext.c\r\n                       cbits/plugin.c\r\n                       cbits/registry.c\r\n                       cbits/syntax_extension.c\r\n                       cbits/autolink.c\r\n                       cbits/core-extensions.c\r\n                       cbits/ext_scanners.c\r\n                       cbits/strikethrough.c\r\n                       cbits/table.c\r\n                       cbits/tagfilter.c\r\n                       cbits/tasklist.c\r\n                       cbits/footnotes.c\r\n                       cbits/map.c\r\n\r\nbenchmark bench-cmark-gfm\r\n  type:             exitcode-stdio-1.0\r\n  hs-source-dirs:   bench\r\n  main-is:          bench-cmark.hs\r\n  build-depends:    base, text, cmark-gfm, criterion,\r\n                    sundown >= 0.6 && < 0.7,\r\n                    cheapskate >= 0.1 && < 0.2,\r\n                    markdown >= 0.1 && < 0.2,\r\n                    discount >= 0.1 && < 0.2,\r\n                    blaze-html >= 0.7 && < 0.10\r\n  ghc-options:      -O2\r\n  default-language: Haskell2010\r\n\r\nTest-Suite test-cmark-gfm\r\n  type:           exitcode-stdio-1.0\r\n  main-is:        test-cmark.hs\r\n  hs-source-dirs: test\r\n  build-depends:  base, cmark-gfm, text, HUnit >= 1.2 && < 1.7\r\n  ghc-options:    -Wall -fno-warn-unused-do-bind -threaded\r\n  default-language: Haskell2010\r\n";
  }