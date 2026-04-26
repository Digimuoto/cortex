{-# LANGUAGE OverloadedStrings #-}

module Cortex.Research.SectionSpec (spec) where

import Cortex.Research.Section
  ( ResearchChunk (..),
    ResearchFinding (..),
    ResearchSectionPlan (..),
    ResearchSectionSpec (..),
    ResearchTable (..),
    ResearchTableAlignment (..),
    SectionValidationError (..),
    compressedResearchChunkLimits,
    defaultResearchChunkLimits,
    normalizeResearchChunkToLimits,
    researchChunkSchema,
    researchSectionPlanSchema,
    validateResearchChunk,
    validateResearchSectionPlan,
  )
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.List (isInfixOf)
import Data.Text qualified as T
import Test.Hspec

spec :: Spec
spec = do
  describe "validateResearchSectionPlan" $ do
    it "accepts a bounded section plan with executive_summary first" $ do
      validateResearchSectionPlan validPlan `shouldBe` Right validPlan

    it "rejects plans whose first section is not executive_summary" $ do
      validateResearchSectionPlan invalidPlan
        `shouldBe` Left [SectionValidationError "The first section must be executive_summary."]

  describe "validateResearchChunk" $ do
    it "accepts a bounded research chunk under the default limits" $ do
      validateResearchChunk defaultResearchChunkLimits validChunk `shouldBe` Right validChunk

    it "rejects ragged table rows" $ do
      validateResearchChunk defaultResearchChunkLimits raggedTableChunk
        `shouldBe` Left [SectionValidationError "Table row width must match the column count."]

    it "rejects tables on compressed retries" $ do
      validateResearchChunk compressedResearchChunkLimits validChunkWithTable
        `shouldBe` Left [SectionValidationError "Chunk tables are disabled for this retry profile."]

    it "rejects chunks with no renderable content" $ do
      validateResearchChunk defaultResearchChunkLimits emptyChunk
        `shouldBe` Left [SectionValidationError "Chunk must include at least one summary, paragraph, finding, table, or open gap."]

    it "normalizes count overflows (paragraphs, refs, open gaps) so repaired chunks validate cleanly" $ do
      let repaired = normalizeResearchChunkToLimits defaultResearchChunkLimits overflowingChunk
      validateResearchChunk defaultResearchChunkLimits repaired `shouldBe` Right repaired
      -- Count caps still fire: paragraphs/findings/refs/open-gaps get
      -- truncated to the configured max. Character-length caps no longer
      -- apply — long strings pass through untouched (DIG-507 dogfood
      -- 2026-04-22: mid-word truncation was corrupting user output).
      length (researchChunkParagraphs repaired) `shouldBe` 4
      length (researchChunkEvidenceRefs repaired) `shouldBe` 16
      length (researchChunkOpenGaps repaired) `shouldBe` 5
      fmap researchFindingText (researchChunkFindings repaired)
        `shouldBe` [T.replicate 280 "x"]

  describe "structured output schemas" $ do
    it "omits provider-incompatible array item bounds from the section plan schema" $ do
      let encoded = LBS8.unpack (Aeson.encode researchSectionPlanSchema)
      encoded `shouldSatisfy` (not . isInfixOf "\"maxItems\"")
      encoded `shouldSatisfy` (not . isInfixOf "\"minItems\"")

    it "omits provider-incompatible array item bounds from the research chunk schema" $ do
      let encoded = LBS8.unpack (Aeson.encode (researchChunkSchema defaultResearchChunkLimits))
      encoded `shouldSatisfy` (not . isInfixOf "\"maxItems\"")
      encoded `shouldSatisfy` (not . isInfixOf "\"minItems\"")

    it "keeps nullable table alignments in the required set for strict providers" $ do
      let encoded = LBS8.unpack (Aeson.encode (researchChunkSchema defaultResearchChunkLimits))
      encoded `shouldSatisfy` isInfixOf "\"required\":[\"columns\",\"alignments\",\"rows\"]"

    it "keeps nullable section summary in the required set for strict providers" $ do
      let encoded = LBS8.unpack (Aeson.encode (researchChunkSchema defaultResearchChunkLimits))
      encoded `shouldSatisfy` isInfixOf "\"required\":[\"sectionId\",\"title\",\"summary\",\"paragraphs\",\"findings\",\"tables\",\"evidenceRefs\",\"externalRefs\",\"openGaps\"]"

validPlan :: ResearchSectionPlan
validPlan =
  ResearchSectionPlan
    { researchSectionPlanTitle = "Weekly IBKR Portfolio Analysis",
      researchSectionPlanSections =
        [ ResearchSectionSpec
            { researchSectionId = "executive_summary",
              researchSectionTitle = "Executive summary",
              researchSectionBrief = "Summarize the week's portfolio outcome."
            },
          ResearchSectionSpec
            { researchSectionId = "risk",
              researchSectionTitle = "Risk",
              researchSectionBrief = "Highlight concentration and sector risks."
            }
        ]
    }

invalidPlan :: ResearchSectionPlan
invalidPlan =
  validPlan
    { researchSectionPlanSections =
        [ ResearchSectionSpec
            { researchSectionId = "performance",
              researchSectionTitle = "Performance",
              researchSectionBrief = "Summarize portfolio performance."
            },
          ResearchSectionSpec
            { researchSectionId = "risk",
              researchSectionTitle = "Risk",
              researchSectionBrief = "Highlight concentration and sector risks."
            }
        ]
    }

validChunk :: ResearchChunk
validChunk =
  ResearchChunk
    { researchChunkSectionId = "executive_summary",
      researchChunkTitle = "Executive summary",
      researchChunkSummary = Just "The portfolio outperformed its benchmark over the week.",
      researchChunkParagraphs =
        [ "Performance was driven by technology holdings and disciplined cash management."
        ],
      researchChunkFindings =
        [ ResearchFinding
            { researchFindingText = "AAPL and NVDA contributed most of the weekly gains.",
              researchFindingEvidenceRefs = ["call_prices"],
              researchFindingExternalRefs = []
            }
        ],
      researchChunkTables = [],
      researchChunkEvidenceRefs = ["call_prices", "call_positions"],
      researchChunkExternalRefs = [],
      researchChunkOpenGaps = []
    }

validChunkWithTable :: ResearchChunk
validChunkWithTable =
  validChunk
    { researchChunkTables =
        [ ResearchTable
            { researchTableColumns = ["Asset", "Weekly Return"],
              researchTableAlignments = Just [ResearchAlignLeft, ResearchAlignRight],
              researchTableRows = [["AAPL", "+2.1%"], ["NVDA", "+3.4%"]]
            }
        ]
    }

raggedTableChunk :: ResearchChunk
raggedTableChunk =
  validChunkWithTable
    { researchChunkTables =
        [ ResearchTable
            { researchTableColumns = ["Asset", "Weekly Return"],
              researchTableAlignments = Just [ResearchAlignLeft, ResearchAlignRight],
              researchTableRows = [["AAPL"], ["NVDA", "+3.4%"]]
            }
        ]
    }

emptyChunk :: ResearchChunk
emptyChunk =
  validChunk
    { researchChunkSummary = Just "   ",
      researchChunkParagraphs = [],
      researchChunkFindings = [],
      researchChunkTables = [],
      researchChunkEvidenceRefs = [],
      researchChunkExternalRefs = [],
      researchChunkOpenGaps = []
    }

overflowingChunk :: ResearchChunk
overflowingChunk =
  validChunk
    { researchChunkParagraphs = replicate 6 (T.replicate 1300 "p"),
      researchChunkFindings =
        [ ResearchFinding
            { researchFindingText = T.replicate 280 "x",
              researchFindingEvidenceRefs = replicate 30 "call_prices",
              researchFindingExternalRefs = []
            }
        ],
      researchChunkEvidenceRefs = replicate 24 "call_positions",
      researchChunkOpenGaps = replicate 9 (T.replicate 320 "g")
    }
