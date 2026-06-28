{- |
Module      : Cortex.Wire.FormatSpec
Description : Tests for Cortex.Wire.Format.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises the public Wire formatter through the same Nix-backed test surface used by CI.
-}
module Cortex.Wire.FormatSpec (spec) where

import Data.Foldable (for_)
import Data.List (sort)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Data.Traversable (for)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

import Cortex.Wire

spec :: Spec
spec = do
  describe "formatWireSource" $ do
    it "formats connect chains as vertical causal stages" $ do
      formatWireSource "test" "a=>b=>c"
        `shouldBe` Right "a\n  => b\n  => c\n"

    it "formats small frontiers horizontally inside connect chains" $ do
      formatWireSource "test" "a=>(b<>c<>d)=>e"
        `shouldBe` Right "a\n  => b <> c <> d\n  => e\n"

    it "formats large frontiers with stage-aligned leading overlay operators" $ do
      formatWireSource "test" "a=>(b<>c<>d<>e<>f)=>g"
        `shouldBe` Right "a\n  => b\n  <> c\n  <> d\n  <> e\n  <> f\n  => g\n"

    it "preserves explicit right-nested connect groups without redundant frontier parens" $ do
      formatWireSource "test" "a=>b=>((c<>d)=>e)"
        `shouldBe` Right "a\n  => b\n  => (\n    c <> d\n      => e\n  )\n"

    it "formats star adapters as topology stages" $ do
      formatWireSource "test" "a*b=>c"
        `shouldBe` Right "a\n  * b\n  => c\n"

    it "formats star adapters after overlay stages" $ do
      formatWireSource "test" "(a<>b)*sink"
        `shouldBe` Right "a <> b\n  * sink\n"

    it "preserves explicit right-nested star groups" $ do
      formatWireSource "test" "a*(b*c)"
        `shouldBe` Right "a\n  * (\n    b\n      * c\n  )\n"

    it "formats contract record shapes" $ do
      formatWireSource "test" "contract Result{summary: Text;};"
        `shouldBe` Right "contract Result {\n  summary: Text;\n};\n"

    it "normalizes same-name record fields to inherit" $ do
      let source =
            "node summarize\n\
            \  <- input: BuildReport;\n\
            \  -> summary: Text = summary;\n\
            \  where let\n\
            \    summary = input.summary;\n\
            \  in\n\
            \  { summary = summary; };\n"
          expected =
            "node summarize\n\
            \  <- input: BuildReport;\n\
            \  -> summary: Text = summary;\n\
            \  where let\n\
            \    summary = input.summary;\n\
            \  in\n\
            \  {\n\
            \    inherit summary;\n\
            \  };\n"
      formatWireSource "test" source `shouldBe` Right expected

    it "is idempotent" $ do
      let source = "a\n  => b <> c <> d\n  => e\n"
      formatted <- requireRight (formatWireSource "test" source)
      formatWireSource "test" formatted `shouldBe` Right formatted

    it "preserves comment-bearing source rather than dropping comments" $ do
      let source = "a\n# keep me\n  => b\n"
      formatWireSource "test" source `shouldBe` Right source

    it "does not treat # inside strings as a comment" $ do
      formatWireSource "test" "let flake = \".#wire\";\na\n  => b\n"
        `shouldBe` Right "let flake = \".#wire\";\n\na\n  => b\n"

    it "allows non-cyclic graph-domain compile errors before formatting" $ do
      let source =
            "contract T;\n\
            \node a\n\
            \  <- input: T;\n\
            \  -> input: T = input;\n\
            \a=>a\n"
          expected =
            "contract T;\n\nnode a\n  <- input: T;\n  -> input: T = input;\n\na\n  => a\n"
      formatWireSource "test" source `shouldBe` Right expected

    it "preserves kind declarations rather than expanding them" $ do
      let source =
            "contract T;\n\
            \kind ident_kind(label: PortLabel) =\n\
            \  <- label: T;\n\
            \  -> label: T = label;\n\
            \node a = ident_kind(input);\n\
            \a\n"
      formatWireSource "test" source `shouldBe` Right source

    it "preserves form declarations rather than expanding them" $ do
      let source =
            "contract T;\n\
            \form pair(label: PortLabel) = {\n\
            \  let a = label;\n\
            \  a;\n\
            \};\n\
            \let result = pair(input);\n\
            \result\n"
      formatWireSource "test" source `shouldBe` Right source

    it "treats kind as an identifier suffix, not a declaration" $ do
      let source =
            "let some_kind = 1.0;\n\
            \some_kind\n"
      formatWireSource "test" source
        `shouldBe` Right "let some_kind = 1;\n\nsome_kind\n"

    it "preserves CorePure string interpolation rather than desugaring it" $ do
      let source =
            "node greet\n\
            \  <- name: Text;\n\
            \  -> greeting: Text = \"Hello, ${name}!\";\n\
            \greet\n"
      formatWireSource "test" source `shouldBe` Right source

    it "preserves multiline string bodies verbatim" $ do
      let source = "let blob = ''hello'';\nblob\n"
      formatWireSource "test" source
        `shouldBe` Right "let blob = ''hello'';\n\nblob\n"

    it "preserves multiline strings whose bodies start and end with newlines" $ do
      let source = "let blob = ''\nhello\n'';\nblob\n"
      formatWireSource "test" source
        `shouldBe` Right "let blob = ''\nhello\n'';\n\nblob\n"

    it "parenthesizes right-nested merge to preserve associativity" $ do
      let source = "let merged = a // (b // c);\nmerged\n"
      formatWireSource "test" source
        `shouldBe` Right "let merged = a // (b // c);\n\nmerged\n"

    it "parenthesizes right-nested concat to preserve associativity" $ do
      let source = "let joined = a ++ (b ++ c);\njoined\n"
      formatWireSource "test" source
        `shouldBe` Right "let joined = a ++ (b ++ c);\n\njoined\n"

    it "leaves left-nested merge chains without redundant parens" $ do
      let source = "let merged = a // b // c;\nmerged\n"
      formatWireSource "test" source
        `shouldBe` Right "let merged = a // b // c;\n\nmerged\n"

    it "renders very small decimals without scientific notation" $ do
      let source = "let small = 0.05;\nsmall\n"
      formatWireSource "test" source
        `shouldBe` Right "let small = 0.05;\n\nsmall\n"

    it "renders large round decimals without scientific notation" $ do
      let source = "let big = 10000000.0;\nbig\n"
      formatWireSource "test" source
        `shouldBe` Right "let big = 10000000;\n\nbig\n"

    it "preserves explicit right-nested overlay groups" $ do
      let source = "let frontier = a <> (b <> c);\nfrontier\n"
      formatWireSource "test" source
        `shouldBe` Right "let frontier = a <> (b <> c);\n\nfrontier\n"

    it "keeps nested large frontiers aligned with their graph stage" $ do
      let source =
            "let pipeline =\n\
            \  a\n\
            \    => (\n\
            \      b\n\
            \      <> c\n\
            \      <> d\n\
            \      <> e\n\
            \      <> f\n\
            \    )\n\
            \    => g;\n\
            \pipeline\n"
          expected =
            "let pipeline =\n\
            \  a\n\
            \    => b\n\
            \    <> c\n\
            \    <> d\n\
            \    <> e\n\
            \    <> f\n\
            \    => g;\n\
            \\n\
            \pipeline\n"
      formatWireSource "test" source `shouldBe` Right expected

    it "does not reject manual CorePure concat and toString calls" $ do
      let source =
            "node report\n\
            \  <- score: Score;\n\
            \  -> text: Text = concat [toString score];\n\
            \report\n"
      formatWireSource "test" source
        `shouldBe` Right
          "node report\n\
          \  <- score: Score;\n\
          \  -> text: Text = concat [toString score];\n\
          \\n\
          \report\n"

    it "does not confuse Wire interpolation-like strings with manual CorePure concat calls" $ do
      let source =
            "let home = \"${HOME}\";\n\
            \node report\n\
            \  <- score: Score;\n\
            \  -> text: Text = concat [toString score];\n\
            \home => report\n"
      formatWireSource "test" source
        `shouldBe` Right
          "let home = \"${HOME}\";\n\
          \\n\
          \node report\n\
          \  <- score: Score;\n\
          \  -> text: Text = concat [toString score];\n\
          \\n\
          \home\n\
          \  => report\n"

    it "preserves CorePure field access on a parenthesised ident" $ do
      let source = "let x = (a).b;\nx\n"
      formatWireSource "test" source
        `shouldBe` Right "let x = (a).b;\n\nx\n"

    it "preserves nullary CorePure calls in let RHS position" $ do
      let source = "let x = f();\nx\n"
      formatWireSource "test" source
        `shouldBe` Right "let x = f();\n\nx\n"

    it "preserves source include call syntax" $ do
      let source =
            "let prompt = include_str(\"prompts/build.md\");\n\
            \let entries = include_dir(\"src\");\n\
            \prompt\n"
      formatWireSource "test" source `shouldBe` Right source

    it "parenthesises a chained CorePure field-access base in a let RHS" $ do
      let source = "let x = (a).b.c;\nx\n"
      formatWireSource "test" source
        `shouldBe` Right "let x = (a).b.c;\n\nx\n"

    it "does not over-parenthesise field access in CorePure-only contexts" $ do
      let source =
            "contract T;\n\
            \node n\n\
            \  <- input: T;\n\
            \  -> out: T = input.field.subfield;\n"
      formatWireSource "test" source
        `shouldBe` Right
          "contract T;\n\n\
          \node n\n\
          \  <- input: T;\n\
          \  -> out: T = input.field.subfield;\n"

    it "parenthesises nested lambda bodies" $ do
      let source = "let f = x: (y: y);\nf\n"
      formatWireSource "test" source
        `shouldBe` Right "let f = x: (y: y);\n\nf\n"

    it "preserves Wire-level strings that contain literal ${...} text" $ do
      let source = "let home = \"${HOME}\";\nhome\n"
      formatWireSource "test" source
        `shouldBe` Right "let home = \"${HOME}\";\n\nhome\n"

  describe "format round-trip over the Wire corpus" $ do
    corpusFiles <- runIO discoverWireCorpus
    it "discovers a non-trivial corpus" $
      length corpusFiles `shouldSatisfy` (>= 15)
    for_ corpusFiles $ \path ->
      it ("round-trips " <> path) $ do
        source <- TIO.readFile path
        expanded <- requireRightIO (expandWireSourceIncludes path source)
        -- A successful format already verifies its own reparse equality (or
        -- deliberately preserves the source); the second pass pins idempotence:
        -- formatted output is the formatter's fixed point.
        formatted <- requireRight (formatWireSourceWithExpanded path source expanded)
        expandedFormatted <- requireRightIO (expandWireSourceIncludes path formatted)
        formatWireSourceWithExpanded path formatted expandedFormatted
          `shouldBe` Right formatted

discoverWireCorpus :: IO [FilePath]
discoverWireCorpus = do
  exampleFiles <- listWireFilesRecursively "examples/wire"
  fixtureFiles <- listWireFilesRecursively "test/fixtures/wire"
  pure (sort (exampleFiles <> fixtureFiles))

listWireFilesRecursively :: FilePath -> IO [FilePath]
listWireFilesRecursively dir = do
  entries <- listDirectory dir
  fmap concat . for entries $ \entry -> do
    let path = dir </> entry
    isDir <- doesDirectoryExist path
    if isDir
      then listWireFilesRecursively path
      else pure [path | takeExtension path == ".wire"]

requireRightIO :: Show err => IO (Either err a) -> IO a
requireRightIO action =
  action >>= \case
    Right value -> pure value
    Left err -> expectationFailure ("expected Right, got Left " <> show err) >> pure (error "unreachable")

requireRight :: Either WireFormatError Text -> IO Text
requireRight = \case
  Right value -> pure value
  Left err -> expectationFailure (show err) >> pure ""
