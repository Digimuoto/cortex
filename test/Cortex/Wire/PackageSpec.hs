{- |
Module      : Cortex.Wire.PackageSpec
Description : Tests for ADR 0054 Wire packages and namespace `use` resolution.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Resolving @use@ against a composed namespace registry: a non-@std.io@ package
namespace resolves leaves and contracts, unknown namespaces and items are rejected,
and @std.io@ still resolves as one entry among others.
-}
module Cortex.Wire.PackageSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec

import Cortex.Wire.Package
import Cortex.Wire.Syntax (QName (..), UseItem (..), UseSpec (..))
import Cortex.Wire.Use

quantumCore :: NamespaceEntry
quantumCore =
  NamespaceEntry
    { nsNamespace = "quantum.core"
    , nsResolveExecutorLeaf = \leaf ->
        if leaf == "realize" then Just "quantum.realize" else Nothing
    , nsResolveContract = \name ->
        if name == "QuantumResult" then Just "quantum.QuantumResult" else Nothing
    }

registry :: NamespaceRegistry
registry = namespaceRegistryFromEntries [stdNamespaceEntry, quantumCore]

useQuantum :: UseSpec
useQuantum =
  UseSpec
    { useSpecNamespace = QName ("quantum" :| ["core"])
    , useSpecItems = UseExecutor "realize" Nothing :| [UseContract "QuantumResult" Nothing]
    }

useStdOut :: UseSpec
useStdOut =
  UseSpec
    { useSpecNamespace = QName ("std" :| ["io"])
    , useSpecItems = UseExecutor "stdout" Nothing :| []
    }

notTaken :: Text -> Bool
notTaken = const False

spec :: Spec
spec = do
  describe "applyWireUseSpecs against a composed registry" $ do
    it "resolves a non-std package namespace's executor and contract leaves" $
      case applyWireUseSpecs registry notTaken [useQuantum] of
        Left err -> expectationFailure ("unexpected: " <> show err)
        Right scope -> do
          Map.lookup "realize" (wireUseExecutors scope) `shouldBe` Just "quantum.realize"
          Map.lookup "QuantumResult" (wireUseContracts scope) `shouldBe` Just "quantum.QuantumResult"

    it "still resolves std.io as one entry among others" $
      case applyWireUseSpecs registry notTaken [useStdOut] of
        Left err -> expectationFailure ("unexpected: " <> show err)
        Right scope ->
          Map.lookup "stdout" (wireUseExecutors scope) `shouldBe` Just "std.io.stdout"

    it "rejects an unknown namespace" $
      applyWireUseSpecs registry notTaken [useQuantum {useSpecNamespace = QName ("nope" :| [])}]
        `shouldBe` Left (WireUseUnknownNamespace "nope")

    it "rejects an unknown item in a known namespace" $
      applyWireUseSpecs
        registry
        notTaken
        [useQuantum {useSpecItems = UseExecutor "teleport" Nothing :| []}]
        `shouldBe` Left (WireUseUnknownItem "quantum.core" "@teleport")

  describe "packageNamespaceRegistry" . it "composes std.io with package namespaces" $ do
    let reg = packageNamespaceRegistry [WirePackage "quantum" [quantumCore] [] []]
    namespaceRegistryNamespaces reg `shouldMatchList` ["std.io", "quantum.core"]
