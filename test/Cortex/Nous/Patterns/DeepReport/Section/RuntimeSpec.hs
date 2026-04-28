module Cortex.Nous.Patterns.DeepReport.Section.RuntimeSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  )
import Cortex.Nous.Patterns.DeepReport.Section
  ( ChunkCompileFailure (..)
  , ChunkFailureType (..)
  , ResearchChunk (..)
  , ResearchFinding (..)
  , ResearchSectionPlan (..)
  , ResearchSectionSpec (..)
  , defaultResearchChunkLimits
  )
import Cortex.Nous.Patterns.DeepReport.Section.Runtime
  ( ResearchChunkCompileSuccess (..)
  , classifyResearchChunkFailureFromErrorText
  , parseResearchChunkChoice
  , parseResearchSectionPlanChoice
  )

spec :: Spec
spec = do
  describe "parseResearchSectionPlanChoice" $ do
    it "renders section-plan validation failures as text" $ do
      parseResearchSectionPlanChoice (jsonChoice invalidPlan)
        `shouldBe` Left "The first section must be executive_summary."

  describe "parseResearchChunkChoice" $ do
    it "applies local layout repairs and reports them" $ do
      let result =
            parseResearchChunkChoice
              testShapeChunk
              executiveSummarySpec
              1
              defaultResearchChunkLimits
              []
              (jsonChoice overflowChunk)
      case result of
        Left err -> expectationFailure ("Expected compile success, got: " <> show err)
        Right success -> do
          success.researchChunkCompileRepairSummary
            `shouldSatisfy` maybe
              False
              (\summary -> "removed 1 paragraph" `T.isInfixOf` summary || "clipped summary" `T.isInfixOf` summary)
          success.researchChunkCompileChunk.researchChunkSummary `shouldBe` Nothing
          success.researchChunkCompileChunk.researchChunkParagraphs
            `shouldBe` ["First paragraph"]

    it "rejects chunks that use the wrong section id" $ do
      let wrongChunk = overflowChunk {researchChunkSectionId = "other_section"}
          result =
            parseResearchChunkChoice
              testShapeChunk
              executiveSummarySpec
              1
              defaultResearchChunkLimits
              []
              (jsonChoice wrongChunk)
      case result of
        Right _ -> expectationFailure "Expected section-id validation failure"
        Left failure -> failure.chunkFailureType `shouldBe` ChunkFailureStructuredOutput

    it "promotes finding refs to the section when body content is otherwise unreferenced" $ do
      let chunkWithFindingRefsOnly =
            overflowChunk
              { researchChunkSummary = Just "Summary retained from supported findings."
              , researchChunkParagraphs = []
              , researchChunkEvidenceRefs = []
              , researchChunkFindings =
                  [ ResearchFinding
                      { researchFindingText = "Evidence-backed finding."
                      , researchFindingEvidenceRefs = ["tool_call_1"]
                      , researchFindingExternalRefs = []
                      }
                  ]
              }
          result =
            parseResearchChunkChoice
              (\_ chunk -> chunk)
              executiveSummarySpec
              1
              defaultResearchChunkLimits
              []
              (jsonChoice chunkWithFindingRefsOnly)
      case result of
        Left err -> expectationFailure ("Expected compile success, got: " <> show err)
        Right success -> do
          success.researchChunkCompileChunk.researchChunkEvidenceRefs `shouldBe` ["tool_call_1"]
          success.researchChunkCompileChunk.researchChunkSummary
            `shouldBe` Just "Summary retained from supported findings."

    it "rejects unsupported body content when no refs survive compilation" $ do
      let unsupportedChunk =
            overflowChunk
              { researchChunkSummary = Just "This paragraph has no refs."
              , researchChunkParagraphs = ["This section body should not render without refs."]
              , researchChunkFindings =
                  [ ResearchFinding
                      { researchFindingText = "Unsupported finding."
                      , researchFindingEvidenceRefs = []
                      , researchFindingExternalRefs = []
                      }
                  ]
              , researchChunkEvidenceRefs = []
              , researchChunkExternalRefs = []
              }
          result =
            parseResearchChunkChoice
              (\_ chunk -> chunk)
              executiveSummarySpec
              1
              defaultResearchChunkLimits
              []
              (jsonChoice unsupportedChunk)
      case result of
        Right _ -> expectationFailure "Expected reference coverage failure"
        Left failure ->
          failure.chunkFailureMessage
            `shouldSatisfy` T.isInfixOf "Rendered section body must carry at least one evidenceRef or externalRef."

    it "rejects chunks that collapse to open-gaps only after workflow shaping" $ do
      let openGapOnlyChunk =
            overflowChunk
              { researchChunkSummary = Nothing
              , researchChunkParagraphs = []
              , researchChunkFindings = []
              , researchChunkTables = []
              , researchChunkEvidenceRefs = []
              , researchChunkExternalRefs = []
              , researchChunkOpenGaps = ["Need more current cited evidence."]
              }
          result =
            parseResearchChunkChoice
              (\_ chunk -> chunk)
              executiveSummarySpec
              1
              defaultResearchChunkLimits
              []
              (jsonChoice openGapOnlyChunk)
      case result of
        Right _ -> expectationFailure "Expected renderable-content failure"
        Left failure -> failure.chunkFailureMessage `shouldSatisfy` T.isInfixOf "did not produce any renderable content"

  describe "classifyResearchChunkFailureFromErrorText" $ do
    it "treats provider schema rejections as external errors" $ do
      classifyResearchChunkFailureFromErrorText "output_config.format.schema rejected"
        `shouldBe` ChunkFailureExternalError

jsonChoice :: Aeson.ToJSON a => a -> CortexChoice
jsonChoice value =
  CortexChoice
    { cortexChoiceContent = TE.decodeUtf8 (BSL.toStrict (Aeson.encode value))
    , cortexChoiceSourceLinks = []
    , cortexChoiceToolCalls = []
    , cortexChoiceFinishReason = Nothing
    , cortexChoiceUsage = Nothing
    , cortexChoiceReasoning = Nothing
    , cortexChoiceReasoningDetails = Nothing
    }

invalidPlan :: ResearchSectionPlan
invalidPlan =
  ResearchSectionPlan
    { researchSectionPlanTitle = "Invalid plan"
    , researchSectionPlanSections =
        [ ResearchSectionSpec
            { researchSectionId = "portfolio_snapshot"
            , researchSectionTitle = "Portfolio snapshot"
            , researchSectionBrief = "Summarize the portfolio."
            }
        ]
    }

executiveSummarySpec :: ResearchSectionSpec
executiveSummarySpec =
  ResearchSectionSpec
    { researchSectionId = "executive_summary"
    , researchSectionTitle = "Executive summary"
    , researchSectionBrief = "Summarize the overall report outcome."
    }

overflowChunk :: ResearchChunk
overflowChunk =
  ResearchChunk
    { researchChunkSectionId = "executive_summary"
    , researchChunkTitle = "Executive summary"
    , researchChunkSummary = Just "Summary text that should be removed when paragraphs are present."
    , researchChunkParagraphs =
        [ "First paragraph"
        , "Second paragraph"
        ]
    , researchChunkFindings =
        [ ResearchFinding
            { researchFindingText = "Evidence-backed finding."
            , researchFindingEvidenceRefs = ["tool_call_1"]
            , researchFindingExternalRefs = []
            }
        ]
    , researchChunkTables = []
    , researchChunkEvidenceRefs = ["tool_call_1"]
    , researchChunkExternalRefs = []
    , researchChunkOpenGaps = []
    }

testShapeChunk :: ResearchSectionSpec -> ResearchChunk -> ResearchChunk
testShapeChunk _spec chunk =
  chunk
    { researchChunkSummary = Nothing
    , researchChunkParagraphs = take 1 chunk.researchChunkParagraphs
    }
