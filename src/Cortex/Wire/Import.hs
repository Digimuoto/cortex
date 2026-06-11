{- |
Module      : Cortex.Wire.Import
Description : Wire file-import closure loading.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Loads the import closure of a Wire source file: reads each file, expands its
Rust-style includes relative to that file, parses it, and resolves its
@import@ paths relative to the importing file. The result is a
dependency-ordered module list (dependencies first, root last) that
"Cortex.Wire.Compile" consumes purely through 'compileWireModules'. Import
cycles, missing files, and per-module parse failures are reported with the
full requesting context.
-}
module Cortex.Wire.Import
  ( WireImportError (..)
  , loadWireModuleClosure
  , renderWireImportError
  )
where

import Control.Exception (IOException, try)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (isAbsolute, normalise, takeDirectory, (</>))

import Cortex.Wire.Compile (WireModule (..))
import Cortex.Wire.Include (expandWireSourceIncludes)
import Cortex.Wire.Parser (WireParseInfo, parseWireFileWithInfo, renderParseError)
import Cortex.Wire.Syntax (ImportSpec (..), TopForm (..), WireFile (..))

data WireImportError
  = {- | The imported path does not exist; carries the importing file when
    the missing file is not the root itself.
    -}
    WireImportFileNotFound !FilePath !(Maybe FilePath)
  | WireImportReadError !FilePath !Text
  | WireImportIncludeError !FilePath !Text
  | WireImportModuleParseError !FilePath !Text
  | -- | Import chain from the root to the repeated module, root first.
    WireImportCycle ![FilePath]
  deriving stock (Eq, Show)

renderWireImportError :: WireImportError -> Text
renderWireImportError = \case
  WireImportFileNotFound path requestedBy ->
    "imported Wire file not found: "
      <> T.pack path
      <> maybe "" (\importer -> " (imported from " <> T.pack importer <> ")") requestedBy
  WireImportReadError path err ->
    "failed to read Wire file " <> T.pack path <> ": " <> err
  WireImportIncludeError path err ->
    "failed to expand includes in " <> T.pack path <> ": " <> err
  WireImportModuleParseError path err ->
    "failed to parse imported Wire file " <> T.pack path <> ":\n" <> err
  WireImportCycle chain ->
    "Wire import cycle: " <> T.intercalate " -> " (fmap T.pack chain)

data LoadState = LoadState
  { loadVisited :: !(Map FilePath WireModule)
  , loadOrdered :: ![WireModule]
  -- ^ Reverse dependency order; reversed once at the end.
  }

{- | Load a Wire file and every file it transitively imports. The returned
list is dependency-ordered with the root module last, ready for
'Cortex.Wire.Compile.compileWireModules'.
-}
loadWireModuleClosure :: FilePath -> IO (Either WireImportError (NonEmpty WireModule))
loadWireModuleClosure rootPath = do
  result <- loadModule [] emptyLoadState Nothing rootPath
  pure $ do
    finalState <- result
    case NE.nonEmpty (reverse finalState.loadOrdered) of
      Just modules -> Right modules
      Nothing ->
        Left (WireImportFileNotFound rootPath Nothing)
  where
    emptyLoadState = LoadState {loadVisited = Map.empty, loadOrdered = []}

loadModule
  :: [FilePath]
  -> LoadState
  -> Maybe FilePath
  -> FilePath
  -> IO (Either WireImportError LoadState)
loadModule stack state requestedBy rawPath = do
  exists <- doesFileExist rawPath
  if not exists
    then pure (Left (WireImportFileNotFound (normalise rawPath) requestedBy))
    else do
      path <- canonicalizePath rawPath
      if Map.member path state.loadVisited
        then pure (Right state)
        else
          if path `elem` stack
            then pure (Left (WireImportCycle (reverse (path : stack))))
            else loadNewModule stack state path (normalise rawPath)

loadNewModule
  :: [FilePath]
  -> LoadState
  -> FilePath
  -> FilePath
  -> IO (Either WireImportError LoadState)
loadNewModule stack state path displayPath = do
  sourceResult <- try @IOException (TIO.readFile path)
  case sourceResult of
    Left ioError' -> pure (Left (WireImportReadError displayPath (T.pack (show ioError'))))
    Right source ->
      expandWireSourceIncludes path source >>= \case
        Left includeError -> pure (Left (WireImportIncludeError displayPath includeError))
        Right expanded ->
          case parseWireFileWithInfo path expanded of
            Left parseError ->
              pure (Left (WireImportModuleParseError displayPath (renderParseError parseError)))
            Right (parseInfo, wireFile) ->
              loadImports stack state path displayPath parseInfo wireFile

loadImports
  :: [FilePath]
  -> LoadState
  -> FilePath
  -> FilePath
  -> WireParseInfo
  -> WireFile
  -> IO (Either WireImportError LoadState)
loadImports stack state path displayPath parseInfo wireFile =
  go state (importPathTexts wireFile) Map.empty
  where
    go currentState [] resolvedPaths =
      let wireModule =
            WireModule
              { wireModulePath = path
              , wireModuleDisplayPath = T.pack displayPath
              , wireModuleParseInfo = parseInfo
              , wireModuleFile = wireFile
              , wireModuleImportPaths = resolvedPaths
              }
       in pure
            ( Right
                currentState
                  { loadVisited = Map.insert path wireModule currentState.loadVisited
                  , loadOrdered = wireModule : currentState.loadOrdered
                  }
            )
    go currentState (pathText : rest) resolvedPaths = do
      let targetRaw = resolveImportPath path pathText
      loadModule (path : stack) currentState (Just displayPath) targetRaw >>= \case
        Left err -> pure (Left err)
        Right nextState -> do
          targetCanonical <- canonicalizePath targetRaw
          go nextState rest (Map.insert pathText targetCanonical resolvedPaths)

importPathTexts :: WireFile -> [Text]
importPathTexts wireFile =
  [ importSpecPathText importSpec
  | TopImport importSpec <- wireFile.wireFileTopForms
  ]

importSpecPathText :: ImportSpec -> Text
importSpecPathText = \case
  ImportNamed _name path -> path
  ImportExplicit _names path -> path

resolveImportPath :: FilePath -> Text -> FilePath
resolveImportPath importerPath pathText =
  let target = T.unpack pathText
   in if isAbsolute target
        then target
        else takeDirectory importerPath </> target
