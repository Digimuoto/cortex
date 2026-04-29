{- |
Module      : Logos.Memory.ConflictSpec
Description : Tests for Logos.Memory.Conflict.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Memory.ConflictSpec (spec) where

import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Logos.Memory.Conflict (resolveMemoryConflicts)
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryEntityConfig (..)
  , LogosMemoryPassage (..)
  , LogosMemoryRankedPassage (..)
  , LogosMemoryRetrievalSource (..)
  , defaultLogosMemoryEntityConfig
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "resolveMemoryConflicts" $ do
    it "keeps the newer conflicting passage" $ do
      let rows =
            resolveMemoryConflicts
              testStanceConfig
              [ mkRanked
                  [LogosMemoryRetrievedFromLexical]
                  (mkPassage (uuidFromWord 1) "AMD thesis" "Gross margin view" "AMD remains bullish." olderTime)
              , mkRanked
                  [LogosMemoryRetrievedFromLexical]
                  (mkPassage (uuidFromWord 2) "AMD thesis" "Gross margin view" "AMD downside risk is rising." newerTime)
              ]

      fmap ((.logosMemoryPassageId) . (.logosRankedPassage)) rows
        `shouldBe` [uuidFromWord 2]
      fmap (.logosRankedConflictNote) rows
        `shouldBe` [ Just
                       "A newer or explicitly targeted passage superseded an older conflicting memory passage. Re-verify any recommendation before relying on it."
                   ]

    it "prefers explicit targets over newer conflicting passages" $ do
      let rows =
            resolveMemoryConflicts
              testStanceConfig
              [ mkRanked
                  [LogosMemoryRetrievedFromDirectTarget]
                  (mkPassage (uuidFromWord 3) "AMD target" "Positioning" "AMD remains bullish." olderTime)
              , mkRanked
                  [LogosMemoryRetrievedFromLexical]
                  (mkPassage (uuidFromWord 4) "AMD note" "Positioning" "AMD downside risk is rising." newerTime)
              ]

      fmap ((.logosMemoryPassageId) . (.logosRankedPassage)) rows
        `shouldBe` [uuidFromWord 3]

olderTime :: UTCTime
olderTime = UTCTime (fromGregorian 2026 3 1) (secondsToDiffTime 0)

newerTime :: UTCTime
newerTime = UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0)

mkRanked :: [LogosMemoryRetrievalSource] -> LogosMemoryPassage -> LogosMemoryRankedPassage
mkRanked sources passage =
  LogosMemoryRankedPassage
    { logosRankedPassage = passage
    , logosRankedCandidate =
        LogosMemoryCandidate
          { logosCandidatePassage = passage
          , logosCandidateLexicalScore = Just 0.5
          , logosCandidateFuzzyScore = Nothing
          , logosCandidateSemanticScore = Nothing
          , logosCandidateMatchedTerms = ["amd"]
          , logosCandidateMatchedFields = []
          , logosCandidateSources = sources
          , logosCandidateFusionScore = 0
          }
    , logosRankedFinalScore = 0.7
    , logosRankedConflictNote = Nothing
    }

mkPassage :: UUID -> Text -> Text -> Text -> UTCTime -> LogosMemoryPassage
mkPassage passageId' title' heading' body' updatedAt' =
  LogosMemoryPassage
    { logosMemoryPassageId = passageId'
    , logosMemorySourceKind = "saved_report"
    , logosMemorySourceItemId = Just (uuidFromWord 9)
    , logosMemorySourceCheckpointId = Nothing
    , logosMemorySourceVersionId = passageId'
    , logosMemoryChatSessionId = Nothing
    , logosMemoryPassageOrder = 0
    , logosMemorySourceTitle = title'
    , logosMemorySectionHeading = Just heading'
    , logosMemoryPassageText = body'
    , logosMemoryEntities = ["AMD"]
    , logosMemoryReportType = Just "report"
    , logosMemoryTimeRange = Nothing
    , logosMemoryPassageTokenCount = 8
    , logosMemorySourceCreatedAt = updatedAt'
    , logosMemorySourceUpdatedAt = updatedAt'
    }

testStanceConfig :: LogosMemoryEntityConfig
testStanceConfig =
  defaultLogosMemoryEntityConfig
    { logosMemoryPositiveStanceTerms = ["bullish", "constructive", "upside", "positive"]
    , logosMemoryNegativeStanceTerms = ["bearish", "downside", "negative", "risk-off"]
    }

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0
