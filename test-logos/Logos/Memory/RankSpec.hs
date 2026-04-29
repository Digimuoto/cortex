{- |
Module      : Logos.Memory.RankSpec
Description : Tests for Logos.Memory.Rank.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Memory.RankSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Logos.Memory.Query (parseMemoryQuery)
import Logos.Memory.Rank
  ( defaultLogosMemoryRankWeights
  , rankMemoryCandidates
  )
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryPassage (..)
  , LogosMemoryRankedPassage (..)
  , LogosMemoryRetrievalSource (..)
  , defaultLogosMemoryEntityConfig
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "rankMemoryCandidates" $ do
    it "ranks direct-target semantic hits above weaker lexical-only matches" $ do
      let query = parseMemoryQuery defaultLogosMemoryEntityConfig "AMD downside" [] (Just (uuidFromWord 10))
          lexicalOnly =
            ( mkCandidate
                [LogosMemoryRetrievedFromLexical]
                (mkPassage (uuidFromWord 1) "Lexical note")
            )
              { logosCandidateLexicalScore = Just 0.18
              }
          targetSemantic =
            ( mkCandidate
                [LogosMemoryRetrievedFromDirectTarget, LogosMemoryRetrievedFromSemantic]
                (mkPassage (uuidFromWord 2) "Target report")
            )
              { logosCandidateSemanticScore = Just 0.72
              }
          ranked =
            rankMemoryCandidates
              fixedNow
              Map.empty
              0.30
              defaultLogosMemoryRankWeights
              query
              [lexicalOnly, targetSemantic]

      fmap ((.logosMemorySourceTitle) . (.logosRankedPassage)) ranked
        `shouldBe` ["Target report", "Lexical note"]

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0)

mkCandidate :: [LogosMemoryRetrievalSource] -> LogosMemoryPassage -> LogosMemoryCandidate
mkCandidate sources passage =
  LogosMemoryCandidate
    { logosCandidatePassage = passage
    , logosCandidateLexicalScore = Nothing
    , logosCandidateFuzzyScore = Nothing
    , logosCandidateSemanticScore = Nothing
    , logosCandidateMatchedTerms = ["amd"]
    , logosCandidateMatchedFields = []
    , logosCandidateSources = sources
    , logosCandidateFusionScore = 0
    }

mkPassage :: UUID -> Text -> LogosMemoryPassage
mkPassage passageId' title' =
  LogosMemoryPassage
    { logosMemoryPassageId = passageId'
    , logosMemorySourceKind = "saved_report"
    , logosMemorySourceItemId = Just (uuidFromWord 10)
    , logosMemorySourceCheckpointId = Nothing
    , logosMemorySourceVersionId = uuidFromWord 20
    , logosMemoryChatSessionId = Nothing
    , logosMemoryPassageOrder = 0
    , logosMemorySourceTitle = title'
    , logosMemorySectionHeading = Just "Thesis"
    , logosMemoryPassageText = "AMD downside remains in focus."
    , logosMemoryEntities = ["AMD"]
    , logosMemoryReportType = Just "report"
    , logosMemoryTimeRange = Nothing
    , logosMemoryPassageTokenCount = 8
    , logosMemorySourceCreatedAt = fixedNow
    , logosMemorySourceUpdatedAt = fixedNow
    }

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0
