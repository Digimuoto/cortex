module Cortex.Nous.Memory.PackSpec (spec) where

import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Test.Hspec

import Cortex.Nous.Memory.Pack
  ( jaccardSimilarity
  , packReferencePassages
  , packSessionPassages
  , passageFeatures
  )
import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate (..)
  , CortexMemoryPassage (..)
  , CortexMemoryRankedPassage (..)
  )

spec :: Spec
spec = do
  describe "packSessionPassages" $ do
    it "packs session passages newest-first" $ do
      let packed = packSessionPassages tokenBudget 5 [newerPassage, olderPassage]

      fmap (.cortexMemoryPassageId) packed
        `shouldBe` [newerPassage.cortexMemoryPassageId, olderPassage.cortexMemoryPassageId]

  describe "packReferencePassages" $ do
    it "packs reference passages by score desc then updatedAt desc" $ do
      let packed = packReferencePassages tokenBudget 5 [lowerRanked, higherRanked]

      fmap ((.cortexMemoryPassageId) . (.cortexRankedPassage)) packed
        `shouldBe` [ higherRanked.cortexRankedPassage.cortexMemoryPassageId
                   , lowerRanked.cortexRankedPassage.cortexMemoryPassageId
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
          packedTitles = fmap ((.cortexMemorySourceTitle) . (.cortexRankedPassage)) packed
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

olderPassage :: CortexMemoryPassage
olderPassage = mkPassage (uuidFromWord 1) (UTCTime (fromGregorian 2026 3 1) (secondsToDiffTime 0))

newerPassage :: CortexMemoryPassage
newerPassage = mkPassage (uuidFromWord 2) (UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0))

higherRanked :: CortexMemoryRankedPassage
higherRanked = mkRanked 0.9 newerPassage

lowerRanked :: CortexMemoryRankedPassage
lowerRanked = mkRanked 0.4 olderPassage

mkPassage :: UUID -> UTCTime -> CortexMemoryPassage
mkPassage passageId' updatedAt' =
  CortexMemoryPassage
    { cortexMemoryPassageId = passageId'
    , cortexMemorySourceKind = "checkpoint"
    , cortexMemorySourceItemId = Nothing
    , cortexMemorySourceCheckpointId = Just (uuidFromWord 99)
    , cortexMemorySourceVersionId = uuidFromWord 100
    , cortexMemoryChatSessionId = Just (uuidFromWord 200)
    , cortexMemoryPassageOrder = 0
    , cortexMemorySourceTitle = "Checkpoint"
    , cortexMemorySectionHeading = Nothing
    , cortexMemoryPassageText = "Prior continuation context."
    , cortexMemoryEntities = []
    , cortexMemoryReportType = Nothing
    , cortexMemoryTimeRange = Nothing
    , cortexMemoryPassageTokenCount = 4
    , cortexMemorySourceCreatedAt = updatedAt'
    , cortexMemorySourceUpdatedAt = updatedAt'
    }

mkRanked :: Double -> CortexMemoryPassage -> CortexMemoryRankedPassage
mkRanked score passage =
  CortexMemoryRankedPassage
    { cortexRankedPassage = passage
    , cortexRankedCandidate =
        CortexMemoryCandidate
          { cortexCandidatePassage = passage
          , cortexCandidateLexicalScore = Nothing
          , cortexCandidateFuzzyScore = Nothing
          , cortexCandidateSemanticScore = Just score
          , cortexCandidateMatchedTerms = []
          , cortexCandidateMatchedFields = []
          , cortexCandidateSources = []
          , cortexCandidateFusionScore = 0
          }
    , cortexRankedFinalScore = score
    , cortexRankedConflictNote = Nothing
    }

mkRankedWithMeta :: Double -> Text -> Maybe Text -> [Text] -> CortexMemoryRankedPassage
mkRankedWithMeta score title heading entities =
  let passage =
        (mkPassage (uuidFromWord (round (score * 1000))) baseTime)
          { cortexMemorySourceTitle = title
          , cortexMemorySectionHeading = heading
          , cortexMemoryEntities = entities
          }
   in mkRanked score passage

mkRankedWithTokens :: Double -> Int -> CortexMemoryRankedPassage
mkRankedWithTokens score tokens =
  let passage =
        (mkPassage (uuidFromWord (round (score * 1000))) baseTime)
          { cortexMemoryPassageTokenCount = tokens
          }
   in mkRanked score passage

baseTime :: UTCTime
baseTime = UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0)

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0
