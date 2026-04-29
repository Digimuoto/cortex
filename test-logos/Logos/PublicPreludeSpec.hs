{- |
Module      : Logos.PublicPreludeSpec
Description : Tests for the public Logos surface.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public Logos behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.PublicPreludeSpec
  ( spec
  )
where

import Data.Text qualified as T
import Logos qualified
import Test.Hspec

spec :: Spec
spec =
  describe "public Logos surface" $ do
    it "exposes representative Logos archetype and capability types" $ do
      Logos.logosArchetypeDefinitionPath Logos.logosDefinition
        `shouldBe` "Logos.Archetypes.Logos"
      Logos.logosCapabilityBundlePath Logos.logosCapabilityBundle
        `shouldBe` "Logos.Archetypes.Logos.Activation"
      Logos.logosCapabilityBundleStatus Logos.logosCapabilityBundle
        `shouldBe` Logos.LogosCapabilityBundleStub
      Logos.researchChunkHasVisibleContent emptyChunk `shouldBe` False
      Logos.emptyLogosAgentBudget `shouldBe` Logos.LogosAgentBudget Nothing Nothing

    it "keeps Logos archetype paths and bundle component slots in sync" $ do
      length Logos.allLogosArchetypeDefinitions `shouldBe` length Logos.allLogosArchetypes
      fmap Logos.logosArchetypeDefinitionArchetype Logos.allLogosArchetypeDefinitions
        `shouldBe` Logos.allLogosArchetypes
      mapM_ assertLogosDefinitionPath Logos.allLogosArchetypeDefinitions
      mapM_ assertLogosCapabilityBundlePath Logos.allLogosArchetypes
      fmap
        Logos.logosCapabilityComponentKind
        (Logos.logosCapabilityBundleComponents Logos.logosCapabilityBundle)
        `shouldBe` [minBound .. maxBound]

assertLogosDefinitionPath :: Logos.LogosArchetypeDefinition -> Expectation
assertLogosDefinitionPath definition =
  Logos.logosArchetypeDefinitionPath definition
    `shouldBe` ( "Logos.Archetypes."
                   <> T.pack (show (Logos.logosArchetypeDefinitionArchetype definition))
               )

assertLogosCapabilityBundlePath :: Logos.LogosArchetype -> Expectation
assertLogosCapabilityBundlePath archetype =
  let definition = Logos.logosArchetypeDefinition archetype
      bundle = Logos.logosCapabilityBundleFor archetype
   in Logos.logosCapabilityBundlePath bundle
        `shouldBe` (Logos.logosArchetypeDefinitionPath definition <> ".Activation")

emptyChunk :: Logos.ResearchChunk
emptyChunk =
  Logos.ResearchChunk
    { Logos.researchChunkSectionId = "section"
    , Logos.researchChunkTitle = "Section"
    , Logos.researchChunkSummary = Nothing
    , Logos.researchChunkParagraphs = []
    , Logos.researchChunkFindings = []
    , Logos.researchChunkTables = []
    , Logos.researchChunkEvidenceRefs = []
    , Logos.researchChunkExternalRefs = []
    , Logos.researchChunkOpenGaps = []
    }
