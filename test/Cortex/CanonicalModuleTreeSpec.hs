module Cortex.CanonicalModuleTreeSpec
  ( spec
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isPrefixOf)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

spec :: Spec
spec =
  describe "canonical Cortex module tree" $ do
    it "does not keep removed roots as direct source-tree entries" $ do
      entries <- listDirectory "src/Cortex"
      filter (`elem` entries) removedRootEntries `shouldBe` []

    it "does not expose removed public module roots" $ do
      cabal <- readFile "cortex.cabal"
      filter (`isInfixOf` cabal) removedExposedModulePrefixes `shouldBe` []

    it "does not declare source modules under removed roots" $ do
      files <- listHaskellFiles "src/Cortex"
      offenders <- filterM declaresRemovedRootModule files
      offenders `shouldBe` []

removedRootEntries :: [FilePath]
removedRootEntries =
  [ "Agent"
  , "Circuit"
  , "Document"
  , "Event.hs"
  , "Events.hs"
  , "Graph"
  , "Json"
  , "Memory"
  , "Memory.hs"
  , "MemoryCompaction.hs"
  , "Provider"
  , "Research"
  , "Run"
  , "Task"
  , "Text.hs"
  ]

removedExposedModulePrefixes :: [String]
removedExposedModulePrefixes =
  fmap
    ("        " <>)
    [ "Cortex.Agent"
    , "Cortex.Circuit"
    , "Cortex.Document"
    , "Cortex.Event"
    , "Cortex.Events"
    , "Cortex.Graph"
    , "Cortex.Json"
    , "Cortex.Memory"
    , "Cortex.MemoryCompaction"
    , "Cortex.Provider"
    , "Cortex.Research"
    , "Cortex.Run"
    , "Cortex.Task"
    , "Cortex.Text"
    , "Cortex.Nous.Episteme"
    , "Cortex.Nous.Kritikos"
    , "Cortex.Nous.Logos"
    , "Cortex.Nous.Poiesis"
    , "Cortex.Nous.Sophia"
    , "Cortex.Nous.Techne"
    , "Cortex.Nous.Themis"
    ]

removedModuleDeclarationPrefixes :: [String]
removedModuleDeclarationPrefixes =
  fmap
    ("module " <>)
    [ "Cortex.Agent"
    , "Cortex.Circuit"
    , "Cortex.Document"
    , "Cortex.Event"
    , "Cortex.Events"
    , "Cortex.Graph"
    , "Cortex.Json"
    , "Cortex.Memory"
    , "Cortex.MemoryCompaction"
    , "Cortex.Provider"
    , "Cortex.Research"
    , "Cortex.Run"
    , "Cortex.Task"
    , "Cortex.Text"
    ]

declaresRemovedRootModule :: FilePath -> IO Bool
declaresRemovedRootModule path = do
  content <- readFile path
  pure (any hasRemovedModulePrefix (lines content))

hasRemovedModulePrefix :: String -> Bool
hasRemovedModulePrefix line =
  any (`isPrefixOf` line) removedModuleDeclarationPrefixes

listHaskellFiles :: FilePath -> IO [FilePath]
listHaskellFiles root = do
  entries <- listDirectory root
  concat
    <$> traverse
      ( \entry -> do
          let path = root </> entry
          isDirectory <- doesDirectoryExist path
          if isDirectory
            then listHaskellFiles path
            else pure [path | takeExtension path == ".hs"]
      )
      entries
