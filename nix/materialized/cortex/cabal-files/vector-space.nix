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
      identifier = { name = "vector-space"; version = "0.19"; };
      license = "BSD-3-Clause";
      copyright = "(c) 2008-2012 by Conal Elliott";
      maintainer = "conal@conal.net";
      author = "Conal Elliott ";
      homepage = "";
      url = "";
      synopsis = "Vector & affine spaces, linear maps, and derivatives";
      description = "/vector-space/ provides classes and generic operations for vector\nspaces and affine spaces.  It also defines a type of infinite towers\nof generalized derivatives.  A generalized derivative is a linear\ntransformation rather than one of the common concrete representations\n(scalars, vectors, matrices, ...).\n\n/Warning/: this package depends on type families working fairly well,\nrequiring GHC version at least 6.9.\n\nProject wiki page: <http://haskell.org/haskellwiki/vector-space>\n\n&#169; 2008-2012 by Conal Elliott; BSD3 license.";
      buildType = "Simple";
    };
    components = {
      "library" = {
        depends = (([
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."MemoTrie" or (errorHandler.buildDepError "MemoTrie"))
          (hsPkgs."Boolean" or (errorHandler.buildDepError "Boolean"))
          (hsPkgs."NumInstances" or (errorHandler.buildDepError "NumInstances"))
        ] ++ pkgs.lib.optional (!(compiler.isGhc && compiler.version.ge "7.6")) (hsPkgs."ghc-prim" or (errorHandler.buildDepError "ghc-prim"))) ++ pkgs.lib.optional (!(compiler.isGhc && compiler.version.ge "7.9")) (hsPkgs."void" or (errorHandler.buildDepError "void"))) ++ pkgs.lib.optional (!(compiler.isGhc && compiler.version.ge "8.0")) (hsPkgs."semigroups" or (errorHandler.buildDepError "semigroups"));
        buildable = if compiler.isGhc && compiler.version.lt "6.10"
          then false
          else true;
      };
    };
  } // {
    src = pkgs.lib.mkDefault (pkgs.fetchurl {
      url = "http://hackage.haskell.org/package/vector-space-0.19.tar.gz";
      sha256 = "8917d1041232165f090c9200af07dd98e793fb89e2e0bc0a83ea900f309feb25";
    });
  }) // {
    package-description-override = "Name:                vector-space\r\nVersion:             0.19\r\nx-revision: 1\r\nCabal-Version:       >= 1.10\r\nSynopsis:            Vector & affine spaces, linear maps, and derivatives\r\nCategory:            math\r\nDescription:\r\n  /vector-space/ provides classes and generic operations for vector\r\n  spaces and affine spaces.  It also defines a type of infinite towers\r\n  of generalized derivatives.  A generalized derivative is a linear\r\n  transformation rather than one of the common concrete representations\r\n  (scalars, vectors, matrices, ...).\r\n  .\r\n  /Warning/: this package depends on type families working fairly well,\r\n  requiring GHC version at least 6.9.\r\n  .\r\n  Project wiki page: <http://haskell.org/haskellwiki/vector-space>\r\n  .\r\n  &#169; 2008-2012 by Conal Elliott; BSD3 license.\r\nAuthor:              Conal Elliott \r\nMaintainer:          conal@conal.net\r\nCopyright:           (c) 2008-2012 by Conal Elliott\r\nLicense:             BSD3\r\nLicense-File:        COPYING\r\nStability:           experimental\r\nbuild-type:          Simple\r\n\r\nsource-repository head\r\n  type:     git\r\n  location: git://github.com/conal/vector-space.git\r\n\r\nLibrary\r\n  default-language:  Haskell2010\r\n  hs-Source-Dirs:      src\r\n  Extensions:          \r\n  Build-Depends:       base >= 4.18 && <5, MemoTrie >= 0.5\r\n                     , Boolean >= 0.1.0\r\n                     , NumInstances >= 1.0\r\n  Exposed-Modules:     \r\n                     Data.AdditiveGroup\r\n                     Data.VectorSpace\r\n                     Data.Basis\r\n                     Data.LinearMap\r\n                     Data.Maclaurin\r\n--                   Data.Horner\r\n                     Data.Derivative\r\n                     Data.Cross\r\n                     Data.AffineSpace\r\n  Other-Modules:     \r\n                     Data.VectorSpace.Generic\r\n\r\n  -- This library relies on type families working as well as in 6.10.\r\n  if  impl(ghc < 6.10) { buildable: False }\r\n  if !impl(ghc >= 7.6) { Build-Depends: ghc-prim >= 0.2 }\r\n  if !impl(ghc >= 7.9) { Build-Depends: void >= 0.4 }\r\n  if !impl(ghc >= 8.0) { Build-Depends: semigroups >= 0.16 }\r\n";
  }