{- |
Module      : Cortex.PublicPreludeSpec
Description : Tests for Cortex.PublicPrelude.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.PublicPreludeSpec
  ( spec
  )
where

import Data.Text qualified as T
import Test.Hspec

import Cortex qualified

import Platform qualified

spec :: Spec
spec =
  describe "public preludes" $ do
    it "exposes representative Cortex substrate and Nous types" $ do
      Cortex.unNodeId (Cortex.NodeId "root") `shouldBe` "root"
      Cortex.researchChunkHasVisibleContent emptyChunk `shouldBe` False
      Cortex.emptyCortexAgentBudget `shouldBe` Cortex.CortexAgentBudget Nothing Nothing
      Cortex.nousArchetypeDefinitionPath Cortex.logosDefinition
        `shouldBe` "Cortex.Nous.Archetypes.Logos"
      Cortex.nousCapabilityBundlePath Cortex.logosCapabilityBundle
        `shouldBe` "Cortex.Nous.Archetypes.Logos.Activation"
      Cortex.nousCapabilityBundleStatus Cortex.logosCapabilityBundle
        `shouldBe` Cortex.NousCapabilityBundleStub

    it "keeps Nous archetype paths and bundle component slots in sync" $ do
      length Cortex.allNousArchetypeDefinitions `shouldBe` length Cortex.allNousArchetypes
      fmap Cortex.nousArchetypeDefinitionArchetype Cortex.allNousArchetypeDefinitions
        `shouldBe` Cortex.allNousArchetypes
      mapM_ assertNousDefinitionPath Cortex.allNousArchetypeDefinitions
      mapM_ assertNousCapabilityBundlePath Cortex.allNousArchetypes
      fmap
        Cortex.nousCapabilityComponentKind
        (Cortex.nousCapabilityBundleComponents Cortex.logosCapabilityBundle)
        `shouldBe` [minBound .. maxBound]

    it "exposes representative Platform runtime helpers" $ do
      Platform.runStatusToText Platform.Pending `shouldBe` "pending"
      Platform.stripNonEmptyText "  cortex  " `shouldBe` Just "cortex"
      Platform.toolValidationError "field" "missing" "value"
        `shouldBe` "Error: missing: value"

emptyChunk :: Cortex.ResearchChunk
emptyChunk =
  Cortex.ResearchChunk
    { Cortex.researchChunkSectionId = "section"
    , Cortex.researchChunkTitle = "Section"
    , Cortex.researchChunkSummary = Nothing
    , Cortex.researchChunkParagraphs = []
    , Cortex.researchChunkFindings = []
    , Cortex.researchChunkTables = []
    , Cortex.researchChunkEvidenceRefs = []
    , Cortex.researchChunkExternalRefs = []
    , Cortex.researchChunkOpenGaps = []
    }

assertNousDefinitionPath :: Cortex.NousArchetypeDefinition -> Expectation
assertNousDefinitionPath definition =
  Cortex.nousArchetypeDefinitionPath definition
    `shouldBe` ("Cortex.Nous.Archetypes." <> T.pack (show (Cortex.nousArchetypeDefinitionArchetype definition)))

assertNousCapabilityBundlePath :: Cortex.NousArchetype -> Expectation
assertNousCapabilityBundlePath archetype =
  let definition = Cortex.nousArchetypeDefinition archetype
      bundle = Cortex.nousCapabilityBundle archetype
   in Cortex.nousCapabilityBundlePath bundle
        `shouldBe` (Cortex.nousArchetypeDefinitionPath definition <> ".Activation")
