{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Memory.ConflictSpec (spec) where

import Cortex.Memory.Conflict (resolveMemoryConflicts)
import Cortex.Memory.Types
  ( CortexMemoryCandidate (..),
    CortexMemoryEntityConfig (..),
    CortexMemoryPassage (..),
    CortexMemoryRankedPassage (..),
    CortexMemoryRetrievalSource (..),
    defaultCortexMemoryEntityConfig,
  )
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Test.Hspec

spec :: Spec
spec = do
  describe "resolveMemoryConflicts" $ do
    it "keeps the newer conflicting passage" $ do
      let rows =
            resolveMemoryConflicts
              testStanceConfig
              [ mkRanked
                  [CortexMemoryRetrievedFromLexical]
                  (mkPassage (uuidFromWord 1) "AMD thesis" "Gross margin view" "AMD remains bullish." olderTime),
                mkRanked
                  [CortexMemoryRetrievedFromLexical]
                  (mkPassage (uuidFromWord 2) "AMD thesis" "Gross margin view" "AMD downside risk is rising." newerTime)
              ]

      fmap ((.cortexMemoryPassageId) . (.cortexRankedPassage)) rows
        `shouldBe` [uuidFromWord 2]
      fmap (.cortexRankedConflictNote) rows
        `shouldBe` [Just "A newer or explicitly targeted passage superseded an older conflicting memory passage. Re-verify any recommendation before relying on it."]

    it "prefers explicit targets over newer conflicting passages" $ do
      let rows =
            resolveMemoryConflicts
              testStanceConfig
              [ mkRanked
                  [CortexMemoryRetrievedFromDirectTarget]
                  (mkPassage (uuidFromWord 3) "AMD target" "Positioning" "AMD remains bullish." olderTime),
                mkRanked
                  [CortexMemoryRetrievedFromLexical]
                  (mkPassage (uuidFromWord 4) "AMD note" "Positioning" "AMD downside risk is rising." newerTime)
              ]

      fmap ((.cortexMemoryPassageId) . (.cortexRankedPassage)) rows
        `shouldBe` [uuidFromWord 3]

olderTime :: UTCTime
olderTime = UTCTime (fromGregorian 2026 3 1) (secondsToDiffTime 0)

newerTime :: UTCTime
newerTime = UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0)

mkRanked :: [CortexMemoryRetrievalSource] -> CortexMemoryPassage -> CortexMemoryRankedPassage
mkRanked sources passage =
  CortexMemoryRankedPassage
    { cortexRankedPassage = passage,
      cortexRankedCandidate =
        CortexMemoryCandidate
          { cortexCandidatePassage = passage,
            cortexCandidateLexicalScore = Just 0.5,
            cortexCandidateFuzzyScore = Nothing,
            cortexCandidateSemanticScore = Nothing,
            cortexCandidateMatchedTerms = ["amd"],
            cortexCandidateMatchedFields = [],
            cortexCandidateSources = sources,
            cortexCandidateFusionScore = 0
          },
      cortexRankedFinalScore = 0.7,
      cortexRankedConflictNote = Nothing
    }

mkPassage :: UUID -> Text -> Text -> Text -> UTCTime -> CortexMemoryPassage
mkPassage passageId' title' heading' body' updatedAt' =
  CortexMemoryPassage
    { cortexMemoryPassageId = passageId',
      cortexMemorySourceKind = "saved_report",
      cortexMemorySourceItemId = Just (uuidFromWord 9),
      cortexMemorySourceCheckpointId = Nothing,
      cortexMemorySourceVersionId = passageId',
      cortexMemoryChatSessionId = Nothing,
      cortexMemoryPassageOrder = 0,
      cortexMemorySourceTitle = title',
      cortexMemorySectionHeading = Just heading',
      cortexMemoryPassageText = body',
      cortexMemoryEntities = ["AMD"],
      cortexMemoryReportType = Just "report",
      cortexMemoryTimeRange = Nothing,
      cortexMemoryPassageTokenCount = 8,
      cortexMemorySourceCreatedAt = updatedAt',
      cortexMemorySourceUpdatedAt = updatedAt'
    }

testStanceConfig :: CortexMemoryEntityConfig
testStanceConfig =
  defaultCortexMemoryEntityConfig
    { cortexMemoryPositiveStanceTerms = ["bullish", "constructive", "upside", "positive"],
      cortexMemoryNegativeStanceTerms = ["bearish", "downside", "negative", "risk-off"]
    }

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0
