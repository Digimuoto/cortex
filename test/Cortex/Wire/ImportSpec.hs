{- |
Module      : Cortex.Wire.ImportSpec
Description : Tests for compiled Wire file imports.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Wire.ImportSpec (spec) where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cortex.Wire (CircuitNodeRef (..), CompiledCircuit (..), renderWireError)
import Cortex.Wire.Compile (compileWireModules)
import Cortex.Wire.Contract (emptyWireCompileEnv)
import Cortex.Wire.Import
  ( WireImportError (..)
  , loadWireModuleClosure
  , renderWireImportError
  )

{- | Load the import closure of a root file and compile it; both load and
compile failures surface as rendered text so specs can match messages.
-}
compileAtPath :: FilePath -> IO (Either Text CompiledCircuit)
compileAtPath path =
  loadWireModuleClosure path >>= \case
    Left importError -> pure (Left (renderWireImportError importError))
    Right modules ->
      pure (first renderWireError (compileWireModules emptyWireCompileEnv modules))

-- | Each spec gets its own scratch directory for fixture files.
itInTempDir :: String -> (FilePath -> IO ()) -> Spec
itInTempDir name action =
  it name (withSystemTempDirectory "wire-import" action)

writeFixture :: FilePath -> [Text] -> IO ()
writeFixture path sourceLines = do
  TIO.writeFile path (T.unlines sourceLines)

helperLibrary :: [Text]
helperLibrary =
  [ "use std.io.{@stdin};"
  , ""
  , "contract GreetingText;"
  , ""
  , "let politeness = \"please\";"
  , ""
  , "export let greeting = name: \"hello ${name}, ${politeness}\";"
  , ""
  , "node greet_source"
  , "  -> message: GreetingText = @stdin { prompt = \"Name: \"; } (null);"
  , ""
  , "export let greeter = greet_source;"
  ]

importerBody :: Text -> [Text]
importerBody importLine =
  [ "use std.io.{@stdout};"
  , ""
  , importLine
  , ""
  , "contract Rendered;"
  , ""
  , "node render"
  , "  <- message: GreetingText;"
  , "  -> rendered: Rendered = greeting message;"
  , ""
  , "node emit"
  , "  <- rendered: Rendered;"
  , "  = @stdout { newline = true; } (rendered);"
  , ""
  , "greeter => render => emit"
  ]

spec :: Spec
spec = do
  describe "Wire file imports" $ do
    itInTempDir "compiles an exported graph let and pure helper imported from a library" $ \dir -> do
      writeFixture (dir </> "helpers.wire") helperLibrary
      writeFixture
        (dir </> "main.wire")
        (importerBody "import { greeting, greeter } from \"./helpers.wire\";")
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right compiled -> do
          fmap (.unCircuitNodeRef) compiled.compiledCircuitEntryNodes `shouldBe` ["greet_source"]
          fmap (.unCircuitNodeRef) compiled.compiledCircuitExitNodes `shouldBe` ["emit"]

    itInTempDir "compiles a file-return import through the named form" $ \dir -> do
      writeFixture
        (dir </> "pipeline.wire")
        [ "use std.io.{@stdin};"
        , ""
        , "contract GreetingText;"
        , ""
        , "node greet_source"
        , "  -> message: GreetingText = @stdin { prompt = \"Name: \"; } (null);"
        , ""
        , "greet_source"
        ]
      writeFixture
        (dir </> "main.wire")
        [ "use std.io.{@stdout};"
        , ""
        , "import pipeline from \"./pipeline.wire\";"
        , ""
        , "node emit"
        , "  <- message: GreetingText;"
        , "  = @stdout { newline = true; } (message);"
        , ""
        , "pipeline => emit"
        ]
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right compiled ->
          fmap (.unCircuitNodeRef) compiled.compiledCircuitEntryNodes `shouldBe` ["greet_source"]

    itInTempDir "keeps contracts ambient and accepts identical local redeclaration" $ \dir -> do
      writeFixture (dir </> "helpers.wire") helperLibrary
      writeFixture
        (dir </> "main.wire")
        ( [ "use std.io.{@stdout};"
          , ""
          , "import { greeting, greeter } from \"./helpers.wire\";"
          , ""
          , "contract GreetingText;"
          ]
            <> drop 4 (importerBody "")
        )
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right compiled ->
          fmap (.unCircuitNodeRef) compiled.compiledCircuitExitNodes `shouldBe` ["emit"]

    itInTempDir "resolves include_str relative to the imported file" $ \dir -> do
      let subDir = dir </> "lib"
      createDirectoryIfMissing True subDir
      writeFixture (dir </> "noop.txt") ["wrong directory"]
      TIO.writeFile (subDir </> "data.txt") "embedded"
      writeFixture
        (subDir </> "helper.wire")
        [ "export let payload = include_str(\"data.txt\");"
        ]
      writeFixture
        (dir </> "main.wire")
        [ "use std.io.{@stdout};"
        , ""
        , "import { payload } from \"./lib/helper.wire\";"
        , ""
        , "contract Payload;"
        , ""
        , "node source"
        , "  -> body: Payload = payload;"
        , ""
        , "node emit"
        , "  <- body: Payload;"
        , "  = @stdout { newline = true; } (body);"
        , ""
        , "source => emit"
        ]
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> expectationFailure (T.unpack err)
        Right _compiled -> pure ()

    itInTempDir "rejects importing a name that exists but is not exported" $ \dir -> do
      writeFixture (dir </> "helpers.wire") helperLibrary
      writeFixture
        (dir </> "main.wire")
        (importerBody "import { politeness, greeting, greeter } from \"./helpers.wire\";")
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> do
          err `shouldSatisfy` T.isInfixOf "does not export it"
          err `shouldSatisfy` T.isInfixOf "politeness"
        Right _compiled -> expectationFailure "expected a visibility error"

    itInTempDir "rejects importing a name the file never defines" $ \dir -> do
      writeFixture (dir </> "helpers.wire") helperLibrary
      writeFixture
        (dir </> "main.wire")
        (importerBody "import { missing_name, greeting, greeter } from \"./helpers.wire\";")
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> err `shouldSatisfy` T.isInfixOf "does not export missing_name"
        Right _compiled -> expectationFailure "expected an unknown-name error"

    itInTempDir "rejects a missing import path with the importing file in the message" $ \dir -> do
      writeFixture
        (dir </> "main.wire")
        (importerBody "import { greeting, greeter } from \"./absent.wire\";")
      result <- loadWireModuleClosure (dir </> "main.wire")
      case result of
        Left (WireImportFileNotFound missingPath (Just requestedBy)) -> do
          missingPath `shouldSatisfy` \path -> "absent.wire" == T.unpack (T.takeWhileEnd (/= '/') (T.pack path))
          requestedBy `shouldSatisfy` \path -> "main.wire" == T.unpack (T.takeWhileEnd (/= '/') (T.pack path))
        Left otherError ->
          expectationFailure ("unexpected error: " <> T.unpack (renderWireImportError otherError))
        Right _modules -> expectationFailure "expected a missing-file error"

    itInTempDir "rejects a local binding that collides with an imported name" $ \dir -> do
      writeFixture (dir </> "helpers.wire") helperLibrary
      writeFixture
        (dir </> "main.wire")
        ( importerBody "import { greeting, greeter } from \"./helpers.wire\";"
            <> [ ""
               , "let greeting = \"shadowed\";"
               ]
        )
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> err `shouldSatisfy` T.isInfixOf "greeting"
        Right _compiled -> expectationFailure "expected a duplicate-binding error"

    itInTempDir "rejects an import cycle with the chain in the message" $ \dir -> do
      writeFixture
        (dir </> "a.wire")
        [ "import { b_value } from \"./b.wire\";"
        , ""
        , "export let a_value = \"a\";"
        ]
      writeFixture
        (dir </> "b.wire")
        [ "import { a_value } from \"./a.wire\";"
        , ""
        , "export let b_value = \"b\";"
        ]
      result <- loadWireModuleClosure (dir </> "a.wire")
      case result of
        Left cycleError@(WireImportCycle chain) -> do
          length chain `shouldSatisfy` (>= 3)
          renderWireImportError cycleError `shouldSatisfy` T.isInfixOf "cycle"
        Left otherError ->
          expectationFailure ("unexpected error: " <> T.unpack (renderWireImportError otherError))
        Right _modules -> expectationFailure "expected a cycle error"

    itInTempDir "rejects the named form against a declaration-only file" $ \dir -> do
      writeFixture
        (dir </> "decls.wire")
        [ "contract GreetingText;"
        , ""
        , "export let greeting = name: \"hello ${name}\";"
        ]
      writeFixture
        (dir </> "main.wire")
        (importerBody "import pipeline from \"./decls.wire\";")
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> err `shouldSatisfy` T.isInfixOf "no graph-valued file-return"
        Right _compiled -> expectationFailure "expected a declaration-only error"

    itInTempDir "keeps use imports source-local across file imports" $ \dir -> do
      writeFixture (dir </> "helpers.wire") helperLibrary
      writeFixture
        (dir </> "main.wire")
        -- The importer references @stdin without its own `use`; the
        -- helper's `use std.io.{@stdin}` must not leak through the import.
        [ "import { greeting, greeter } from \"./helpers.wire\";"
        , ""
        , "node probe"
        , "  -> message: GreetingText = @stdin { prompt = \"x\"; } (null);"
        , ""
        , "greeter => probe"
        ]
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> err `shouldSatisfy` T.isInfixOf "not in Wire source scope"
        Right _compiled -> expectationFailure "expected a use-scope error"

    itInTempDir "rejects a local node colliding with a node inside an imported graph" $ \dir -> do
      writeFixture (dir </> "helpers.wire") helperLibrary
      writeFixture
        (dir </> "main.wire")
        ( [ "use std.io.{@stdout};"
          , ""
          , "import { greeting, greeter } from \"./helpers.wire\";"
          , ""
          , "contract Rendered;"
          , ""
          , "node greet_source"
          , "  <- message: GreetingText;"
          , "  -> rendered: Rendered = greeting message;"
          , ""
          , "node emit"
          , "  <- rendered: Rendered;"
          , "  = @stdout { newline = true; } (rendered);"
          , ""
          , "greeter => greet_source => emit"
          ]
        )
      result <- compileAtPath (dir </> "main.wire")
      case result of
        Left err -> err `shouldSatisfy` T.isInfixOf "collides with a node"
        Right _compiled -> expectationFailure "expected a node collision error"
