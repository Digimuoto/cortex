{- |
Module      : Logos.Memory.PackSpec
Description : Tests for Logos.Memory.Pack.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Memory.PackSpec (spec) where

import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Logos.Memory.Pack
  ( jaccardSimilarity
  , packReferencePassages
  , packSessionPassages
  , passageFeatures
  )
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryPassage (..)
  , LogosMemoryRankedPassage (..)
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "packSessionPassages" $ do
    it "packs session passages newest-first" $ do
      let packed = packSessionPassages tokenBudget 5 [newerPassage, olderPassage]

      fmap (.logosMemoryPassageId) packed
        `shouldBe` [newerPassage.logosMemoryPassageId, olderPassage.logosMemoryPassageId]

  describe "packReferencePassages" $ do
    it "packs reference passages by score desc then updatedAt desc" $ do
      let packed = packReferencePassages tokenBudget 5 [lowerRanked, higherRanked]

      fmap ((.logosMemoryPassageId) . (.logosRankedPassage)) packed
        `shouldBe` [ higherRanked.logosRankedPassage.logosMemoryPassageId
                   , lowerRanked.logosRankedPassage.logosMemoryPassageId
                   ]

  describe "jaccardSimilarity" $ do
    it "returns 1.0 for identical sets" $
      jaccardSimilarity (Set.fromList ["a", "b"]) (Set.fromList ["a", "b"]) `shouldBe` 1.0

    it "returns 0.0 for disjoint sets" $
      jaccardSimilarity (Set.fromList ["a", "b"]) (Set.fromList ["c", "d"]) `shouldBe` 0.0

    it "returns 1.0 for two empty sets" $
      jaccardSimilarity Set.empty Set.empty `shouldBe` 1.0

    it "returns correct value for partial overlap" $
      jaccardSimilarity (Set.fromList ["a", "b", "c"]) (Set.fromList ["b", "c", "d"])
        `shouldBe` (2.0 / 4.0)

  describe "MMR packing" $ do
    it "prefers diversity over pure score ordering" $ do
      let appleReport1 = mkRankedWithMeta 0.9 "AAPL Analysis" (Just "Revenue") ["AAPL"]
          appleReport2 = mkRankedWithMeta 0.85 "AAPL Analysis" (Just "Outlook") ["AAPL"]
          teslaReport = mkRankedWithMeta 0.8 "TSLA Deep Dive" (Just "Valuation") ["TSLA"]
          packed = packReferencePassages 1000 3 [appleReport1, appleReport2, teslaReport]
          packedTitles = fmap ((.logosMemorySourceTitle) . (.logosRankedPassage)) packed
      -- MMR should pick the TSLA report over the second AAPL report
      -- because TSLA is more diverse from the first AAPL selection
      packedTitles `shouldSatisfy` elem "TSLA Deep Dive"

    it "respects token budget even with MMR" $ do
      let rows = [mkRankedWithTokens 0.9 50, mkRankedWithTokens 0.8 50, mkRankedWithTokens 0.7 50]
          packed = packReferencePassages 90 10 rows
      length packed `shouldBe` 1

    it "skips oversized candidates and continues packing smaller ones" $ do
      let small1 = mkRankedWithTokens 0.9 30
          oversized = mkRankedWithTokens 0.85 200
          small2 = mkRankedWithTokens 0.7 30
          packed = packReferencePassages 100 10 [small1, oversized, small2]
      -- Should select small1, skip oversized, then select small2
      length packed `shouldBe` 2

  describe "passageFeatures" $ do
    it "extracts entities, heading, and title terms" $ do
      let ranked = mkRankedWithMeta 0.9 "Apple Revenue Analysis" (Just "Q4 Summary") ["AAPL", "GOOG"]
          features = passageFeatures ranked
      features `shouldSatisfy` Set.member "aapl"
      features `shouldSatisfy` Set.member "goog"
      features `shouldSatisfy` Set.member "q4 summary"
      features `shouldSatisfy` Set.member "apple"

tokenBudget :: Int64
tokenBudget = 100

olderPassage :: LogosMemoryPassage
olderPassage = mkPassage (uuidFromWord 1) (UTCTime (fromGregorian 2026 3 1) (secondsToDiffTime 0))

newerPassage :: LogosMemoryPassage
newerPassage = mkPassage (uuidFromWord 2) (UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0))

higherRanked :: LogosMemoryRankedPassage
higherRanked = mkRanked 0.9 newerPassage

lowerRanked :: LogosMemoryRankedPassage
lowerRanked = mkRanked 0.4 olderPassage

mkPassage :: UUID -> UTCTime -> LogosMemoryPassage
mkPassage passageId' updatedAt' =
  LogosMemoryPassage
    { logosMemoryPassageId = passageId'
    , logosMemorySourceKind = "checkpoint"
    , logosMemorySourceItemId = Nothing
    , logosMemorySourceCheckpointId = Just (uuidFromWord 99)
    , logosMemorySourceVersionId = uuidFromWord 100
    , logosMemoryChatSessionId = Just (uuidFromWord 200)
    , logosMemoryPassageOrder = 0
    , logosMemorySourceTitle = "Checkpoint"
    , logosMemorySectionHeading = Nothing
    , logosMemoryPassageText = "Prior continuation context."
    , logosMemoryEntities = []
    , logosMemoryReportType = Nothing
    , logosMemoryTimeRange = Nothing
    , logosMemoryPassageTokenCount = 4
    , logosMemorySourceCreatedAt = updatedAt'
    , logosMemorySourceUpdatedAt = updatedAt'
    }

mkRanked :: Double -> LogosMemoryPassage -> LogosMemoryRankedPassage
mkRanked score passage =
  LogosMemoryRankedPassage
    { logosRankedPassage = passage
    , logosRankedCandidate =
        LogosMemoryCandidate
          { logosCandidatePassage = passage
          , logosCandidateLexicalScore = Nothing
          , logosCandidateFuzzyScore = Nothing
          , logosCandidateSemanticScore = Just score
          , logosCandidateMatchedTerms = []
          , logosCandidateMatchedFields = []
          , logosCandidateSources = []
          , logosCandidateFusionScore = 0
          }
    , logosRankedFinalScore = score
    , logosRankedConflictNote = Nothing
    }

mkRankedWithMeta :: Double -> Text -> Maybe Text -> [Text] -> LogosMemoryRankedPassage
mkRankedWithMeta score title heading entities =
  let passage =
        (mkPassage (uuidFromWord (round (score * 1000))) baseTime)
          { logosMemorySourceTitle = title
          , logosMemorySectionHeading = heading
          , logosMemoryEntities = entities
          }
   in mkRanked score passage

mkRankedWithTokens :: Double -> Int -> LogosMemoryRankedPassage
mkRankedWithTokens score tokens =
  let passage =
        (mkPassage (uuidFromWord (round (score * 1000))) baseTime)
          { logosMemoryPassageTokenCount = tokens
          }
   in mkRanked score passage

baseTime :: UTCTime
baseTime = UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0)

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0
