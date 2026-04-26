module Cortex.PublicPreludeSpec
  ( spec,
  )
where

import Cortex qualified
import Platform qualified
import Test.Hspec

spec :: Spec
spec =
  describe "public preludes" $ do
    it "exposes representative Cortex substrate and Logoi types" $ do
      Cortex.unNodeId (Cortex.NodeId "root") `shouldBe` "root"
      Cortex.researchChunkHasVisibleContent emptyChunk `shouldBe` False
      Cortex.emptyCortexAgentBudget `shouldBe` Cortex.CortexAgentBudget Nothing Nothing

    it "exposes representative Platform runtime helpers" $ do
      Platform.runStatusToText Platform.Pending `shouldBe` "pending"
      Platform.stripNonEmptyText "  cortex  " `shouldBe` Just "cortex"
      Platform.toolValidationError "field" "missing" "value"
        `shouldBe` "Error: missing: value"

emptyChunk :: Cortex.ResearchChunk
emptyChunk =
  Cortex.ResearchChunk
    { Cortex.researchChunkSectionId = "section",
      Cortex.researchChunkTitle = "Section",
      Cortex.researchChunkSummary = Nothing,
      Cortex.researchChunkParagraphs = [],
      Cortex.researchChunkFindings = [],
      Cortex.researchChunkTables = [],
      Cortex.researchChunkEvidenceRefs = [],
      Cortex.researchChunkExternalRefs = [],
      Cortex.researchChunkOpenGaps = []
    }
