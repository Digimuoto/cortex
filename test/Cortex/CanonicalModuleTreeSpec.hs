{- |
Module      : Cortex.CanonicalModuleTreeSpec
Description : Tests for Cortex.CanonicalModuleTree.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
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

    it "does not keep split upstream source trees in the Cortex repo" $ do
      existing <- filterM doesDirectoryExist splitUpstreamDirectories
      existing `shouldBe` []

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
  , "Logos"
  , "Logos.hs"
  , "Memory"
  , "Memory.hs"
  , "MemoryCompaction.hs"
  , "Nous"
  , "Nous.hs"
  , "Provider"
  , "Research"
  , "Run"
  , "Task"
  , "Text.hs"
  ]

splitUpstreamDirectories :: [FilePath]
splitUpstreamDirectories =
  [ "src-platform"
  , "src-logos"
  , "test-logos"
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
    , "Cortex.Logos"
    , "Cortex.Memory"
    , "Cortex.MemoryCompaction"
    , "Cortex.Nous"
    , "Cortex.Provider"
    , "Cortex.Research"
    , "Cortex.Run"
    , "Cortex.Task"
    , "Cortex.Text"
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
    , "Cortex.Logos"
    , "Cortex.Memory"
    , "Cortex.MemoryCompaction"
    , "Cortex.Nous"
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
