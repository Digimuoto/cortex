module Cortex.Nous.Memory.RankSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Test.Hspec

import Cortex.Nous.Memory.Query (parseMemoryQuery)
import Cortex.Nous.Memory.Rank
  ( defaultCortexMemoryRankWeights
  , rankMemoryCandidates
  )
import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate (..)
  , CortexMemoryPassage (..)
  , CortexMemoryRankedPassage (..)
  , CortexMemoryRetrievalSource (..)
  , defaultCortexMemoryEntityConfig
  )

spec :: Spec
spec = do
  describe "rankMemoryCandidates" $ do
    it "ranks direct-target semantic hits above weaker lexical-only matches" $ do
      let query = parseMemoryQuery defaultCortexMemoryEntityConfig "AMD downside" [] (Just (uuidFromWord 10))
          lexicalOnly =
            ( mkCandidate
                [CortexMemoryRetrievedFromLexical]
                (mkPassage (uuidFromWord 1) "Lexical note")
            )
              { cortexCandidateLexicalScore = Just 0.18
              }
          targetSemantic =
            ( mkCandidate
                [CortexMemoryRetrievedFromDirectTarget, CortexMemoryRetrievedFromSemantic]
                (mkPassage (uuidFromWord 2) "Target report")
            )
              { cortexCandidateSemanticScore = Just 0.72
              }
          ranked =
            rankMemoryCandidates
              fixedNow
              Map.empty
              0.30
              defaultCortexMemoryRankWeights
              query
              [lexicalOnly, targetSemantic]

      fmap ((.cortexMemorySourceTitle) . (.cortexRankedPassage)) ranked
        `shouldBe` ["Target report", "Lexical note"]

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 4 1) (secondsToDiffTime 0)

mkCandidate :: [CortexMemoryRetrievalSource] -> CortexMemoryPassage -> CortexMemoryCandidate
mkCandidate sources passage =
  CortexMemoryCandidate
    { cortexCandidatePassage = passage
    , cortexCandidateLexicalScore = Nothing
    , cortexCandidateFuzzyScore = Nothing
    , cortexCandidateSemanticScore = Nothing
    , cortexCandidateMatchedTerms = ["amd"]
    , cortexCandidateMatchedFields = []
    , cortexCandidateSources = sources
    , cortexCandidateFusionScore = 0
    }

mkPassage :: UUID -> Text -> CortexMemoryPassage
mkPassage passageId' title' =
  CortexMemoryPassage
    { cortexMemoryPassageId = passageId'
    , cortexMemorySourceKind = "saved_report"
    , cortexMemorySourceItemId = Just (uuidFromWord 10)
    , cortexMemorySourceCheckpointId = Nothing
    , cortexMemorySourceVersionId = uuidFromWord 20
    , cortexMemoryChatSessionId = Nothing
    , cortexMemoryPassageOrder = 0
    , cortexMemorySourceTitle = title'
    , cortexMemorySectionHeading = Just "Thesis"
    , cortexMemoryPassageText = "AMD downside remains in focus."
    , cortexMemoryEntities = ["AMD"]
    , cortexMemoryReportType = Just "report"
    , cortexMemoryTimeRange = Nothing
    , cortexMemoryPassageTokenCount = 8
    , cortexMemorySourceCreatedAt = fixedNow
    , cortexMemorySourceUpdatedAt = fixedNow
    }

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0
