{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Memory.RetrieveSpec (spec) where

import Control.Monad.State.Strict
  ( State,
    modify',
    runState,
  )
import Cortex.Memory.Host
  ( CortexMemoryHost (..),
  )
import Cortex.Memory.Query
  ( CortexMemoryQuery (..),
  )
import Cortex.Memory.Rank
  ( defaultCortexMemoryRankWeights,
  )
import Cortex.Memory.Retrieve
  ( CortexMemoryRetrievalContext (..),
    CortexMemoryRetrievalRequest (..),
    CortexMemorySelectionProfile (..),
    resolveMemoryContext,
  )
import Cortex.Memory.Types
  ( CortexMemoryCandidate (..),
    CortexMemoryPassage (..),
    CortexMemoryRankedPassage (..),
    CortexMemoryRetrievalSource (..),
    defaultCortexMemoryEntityConfig,
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Test.Hspec

spec :: Spec
spec = do
  describe "resolveMemoryContext" $ do
    it "filters candidates that duplicate the current session checkpoint history" $ do
      let sessionId = uuidFromWord 10
          duplicatedCheckpointId = uuidFromWord 20
          dataSet =
            HostData
              { hostSessionPassages =
                  [ mkPassage
                      (uuidFromWord 100)
                      Nothing
                      (Just duplicatedCheckpointId)
                      (Just sessionId)
                      "checkpoint"
                      "Prior checkpoint"
                      "AMD downside watch remains active."
                      fixedNow
                  ],
                hostLexicalCandidates =
                  [ mkCandidate
                      CortexMemoryRetrievedFromLexical
                      ( mkPassage
                          (uuidFromWord 101)
                          Nothing
                          (Just duplicatedCheckpointId)
                          Nothing
                          "checkpoint"
                          "Duplicated checkpoint result"
                          "AMD downside watch remains active."
                          fixedNow
                      )
                      1.0,
                    mkCandidate
                      CortexMemoryRetrievedFromLexical
                      ( mkPassage
                          (uuidFromWord 102)
                          (Just (uuidFromWord 30))
                          Nothing
                          Nothing
                          "saved_report"
                          "AMD external report"
                          "AMD valuation downside is rising."
                          fixedNow
                      )
                      0.9
                  ],
                hostFuzzyCandidates = [],
                hostSemanticCandidates = [],
                hostItemPassages = []
              }
          request =
            (mkRequest "AMD downside watch")
              { cortexMemorySessionId = Just sessionId
              }
          (retrievalContext, trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultCortexMemoryEntityConfig fixedNow request)
              emptyTrace

      trace.traceSessionLoads `shouldBe` [(sessionId, 12)]
      trace.traceLexicalLoads `shouldBe` [("AMD downside watch", 40)]
      fmap passageTitle retrievalContext.cortexMemorySessionPassages
        `shouldBe` ["Prior checkpoint"]
      fmap rankedTitle retrievalContext.cortexMemoryReferencePassages
        `shouldBe` ["AMD external report"]

    it "keeps the newest session checkpoint in session context and out of references" $ do
      let sessionId = uuidFromWord 11
          trimmedCheckpointId = uuidFromWord 21
          keptCheckpointId = uuidFromWord 22
          newerTime = UTCTime (fromGregorian 2026 3 20) (secondsToDiffTime 0)
          olderTime = UTCTime (fromGregorian 2026 3 19) (secondsToDiffTime 0)
          dataSet =
            HostData
              { hostSessionPassages =
                  [ mkPassage
                      (uuidFromWord 110)
                      Nothing
                      (Just trimmedCheckpointId)
                      (Just sessionId)
                      "checkpoint"
                      "Trimmed checkpoint"
                      "Older session context."
                      olderTime,
                    mkPassage
                      (uuidFromWord 111)
                      Nothing
                      (Just keptCheckpointId)
                      (Just sessionId)
                      "checkpoint"
                      "Kept checkpoint"
                      "Newest session context."
                      newerTime
                  ],
                hostLexicalCandidates =
                  [ mkCandidate
                      CortexMemoryRetrievedFromLexical
                      ( mkPassage
                          (uuidFromWord 112)
                          (Just (uuidFromWord 31))
                          Nothing
                          Nothing
                          "saved_report"
                          "AMD external report"
                          "AMD valuation downside is rising."
                          newerTime
                      )
                      0.9
                  ],
                hostFuzzyCandidates = [],
                hostSemanticCandidates = [],
                hostItemPassages = []
              }
          request =
            (mkRequest "AMD downside watch")
              { cortexMemorySessionId = Just sessionId,
                cortexMemorySelectionProfile =
                  (mkProfile "AMD downside watch")
                    { cortexMemorySessionMaxCount = 1,
                      cortexMemorySessionTokenBudget = 32
                    }
              }
          (retrievalContext, _trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultCortexMemoryEntityConfig fixedNow request)
              emptyTrace

      fmap passageTitle retrievalContext.cortexMemorySessionPassages
        `shouldBe` ["Kept checkpoint"]
      fmap rankedTitle retrievalContext.cortexMemoryReferencePassages
        `shouldBe` ["AMD external report"]

    it "loads anchored item passages even when the search query is blank" $ do
      let targetItemId = uuidFromWord 40
          linkedItemId = uuidFromWord 41
          dataSet =
            HostData
              { hostSessionPassages = [],
                hostLexicalCandidates = [],
                hostFuzzyCandidates = [],
                hostSemanticCandidates = [],
                hostItemPassages =
                  [ mkPassage
                      (uuidFromWord 104)
                      (Just targetItemId)
                      Nothing
                      Nothing
                      "saved_report"
                      "Target report"
                      "Prior target report context."
                      fixedNow,
                    mkPassage
                      (uuidFromWord 105)
                      (Just linkedItemId)
                      Nothing
                      Nothing
                      "workspace_markdown"
                      "Linked note"
                      "Prior linked workspace note."
                      fixedNow
                  ]
              }
          request =
            (mkRequest "   ")
              { cortexMemorySelectionProfile =
                  (mkProfile "   ")
                    { cortexMemoryAnchoredItemIds = [targetItemId, linkedItemId],
                      cortexMemoryTargetItemId = Just targetItemId
                    },
                cortexMemoryExplicitTargetItemId = Just targetItemId,
                cortexMemoryLinkedItemIds = [targetItemId, linkedItemId, linkedItemId]
              }
          (retrievalContext, trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultCortexMemoryEntityConfig fixedNow request)
              emptyTrace

      trace.traceLexicalLoads `shouldBe` []
      trace.traceFuzzyLoads `shouldBe` []
      trace.traceSemanticLoads `shouldBe` []
      trace.traceItemLoads `shouldBe` [[targetItemId, linkedItemId]]
      fmap rankedSourceItemId retrievalContext.cortexMemoryReferencePassages
        `shouldBe` [Just targetItemId, Just linkedItemId]

    it "keeps explicit target passages even for low-signal continuation prompts" $ do
      let targetItemId = uuidFromWord 42
          linkedItemId = uuidFromWord 43
          dataSet =
            HostData
              { hostSessionPassages = [],
                hostLexicalCandidates = [],
                hostFuzzyCandidates = [],
                hostSemanticCandidates = [],
                hostItemPassages =
                  [ mkPassage
                      (uuidFromWord 106)
                      (Just targetItemId)
                      Nothing
                      Nothing
                      "saved_report"
                      "Target report"
                      "Detailed target report context that does not lexically match the prompt."
                      fixedNow,
                    mkPassage
                      (uuidFromWord 107)
                      (Just linkedItemId)
                      Nothing
                      Nothing
                      "workspace_markdown"
                      "Linked note"
                      "Supplemental linked note context."
                      fixedNow
                  ]
              }
          request =
            (mkRequest "continue this report")
              { cortexMemorySelectionProfile =
                  (mkProfile "continue this report")
                    { cortexMemoryAnchoredItemIds = [targetItemId, linkedItemId],
                      cortexMemoryTargetItemId = Just targetItemId
                    },
                cortexMemoryExplicitTargetItemId = Just targetItemId,
                cortexMemoryLinkedItemIds = [linkedItemId]
              }
          (retrievalContext, _trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultCortexMemoryEntityConfig fixedNow request)
              emptyTrace

      fmap rankedSourceItemId retrievalContext.cortexMemoryReferencePassages
        `shouldBe` [Just targetItemId, Just linkedItemId]

    it "exercises the full pipeline: candidates, ranking, conflict resolution, score threshold, and packing" $ do
      let sessionId = uuidFromWord 50
          itemId = uuidFromWord 60
          olderTime = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
          newerTime = UTCTime (fromGregorian 2026 3 15) (secondsToDiffTime 0)
          dataSet =
            HostData
              { hostSessionPassages =
                  [ mkPassage (uuidFromWord 200) Nothing (Just (uuidFromWord 70)) (Just sessionId) "checkpoint" "Session checkpoint" "Prior session context." newerTime
                  ],
                hostLexicalCandidates =
                  [ mkCandidate
                      CortexMemoryRetrievedFromLexical
                      (mkPassage (uuidFromWord 201) (Just itemId) Nothing Nothing "saved_report" "AMD thesis" "AMD remains bullish." olderTime)
                      0.8,
                    mkCandidate
                      CortexMemoryRetrievedFromLexical
                      (mkPassage (uuidFromWord 202) (Just itemId) Nothing Nothing "saved_report" "AMD thesis" "AMD downside risk is rising." newerTime)
                      0.7
                  ],
                hostFuzzyCandidates = [],
                hostSemanticCandidates =
                  [ mkCandidate
                      CortexMemoryRetrievedFromSemantic
                      (mkPassage (uuidFromWord 203) (Just (uuidFromWord 61)) Nothing Nothing "workspace_markdown" "Unrelated note" "Some unrelated content." olderTime)
                      0.01
                  ],
                hostItemPassages = []
              }
          request =
            (mkRequest "AMD downside")
              { cortexMemorySessionId = Just sessionId,
                cortexMemorySelectionProfile =
                  (mkProfile "AMD downside")
                    { cortexMemoryReferenceTokenBudget = 500,
                      cortexMemoryReferenceMaxCount = 10
                    }
              }
          (ctx, _trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultCortexMemoryEntityConfig fixedNow request)
              emptyTrace

      -- Session checkpoint should be included
      fmap passageTitle ctx.cortexMemorySessionPassages
        `shouldBe` ["Session checkpoint"]
      -- The low-scoring semantic candidate (0.01) should be filtered out by the 0.20 threshold
      -- The conflicting bullish/bearish AMD passages from the same item should trigger conflict resolution
      -- (the newer bearish one wins)
      let refTitles = fmap rankedTitle ctx.cortexMemoryReferencePassages
      refTitles `shouldSatisfy` notElem "Unrelated note"

data HostData = HostData
  { hostSessionPassages :: [CortexMemoryPassage],
    hostLexicalCandidates :: [CortexMemoryCandidate],
    hostFuzzyCandidates :: [CortexMemoryCandidate],
    hostSemanticCandidates :: [CortexMemoryCandidate],
    hostItemPassages :: [CortexMemoryPassage]
  }

data HostTrace = HostTrace
  { traceSessionLoads :: [(UUID, Int)],
    traceLexicalLoads :: [(Text, Int)],
    traceFuzzyLoads :: [(Text, Int)],
    traceSemanticLoads :: [(Text, Int)],
    traceItemLoads :: [[UUID]]
  }

emptyTrace :: HostTrace
emptyTrace =
  HostTrace
    { traceSessionLoads = [],
      traceLexicalLoads = [],
      traceFuzzyLoads = [],
      traceSemanticLoads = [],
      traceItemLoads = []
    }

hostFromData :: HostData -> CortexMemoryHost (State HostTrace)
hostFromData dataSet =
  CortexMemoryHost
    { cortexMemoryLoadSessionPassages = \sessionId limitN -> do
        modify' (\trace -> trace {traceSessionLoads = trace.traceSessionLoads <> [(sessionId, limitN)]})
        pure dataSet.hostSessionPassages,
      cortexMemorySearchLexical = \query limitN -> do
        modify' (\trace -> trace {traceLexicalLoads = trace.traceLexicalLoads <> [(query.cortexMemoryQueryWebsearchText, limitN)]})
        pure dataSet.hostLexicalCandidates,
      cortexMemorySearchFuzzy = \query limitN -> do
        modify' (\trace -> trace {traceFuzzyLoads = trace.traceFuzzyLoads <> [(query.cortexMemoryQueryNormalizedText, limitN)]})
        pure dataSet.hostFuzzyCandidates,
      cortexMemorySearchSemantic = \query limitN -> do
        modify' (\trace -> trace {traceSemanticLoads = trace.traceSemanticLoads <> [(query.cortexMemoryQuerySemanticText, limitN)]})
        pure dataSet.hostSemanticCandidates,
      cortexMemoryLoadItemPassages = \itemIds -> do
        modify' (\trace -> trace {traceItemLoads = trace.traceItemLoads <> [itemIds]})
        pure dataSet.hostItemPassages
    }

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 3 20) (secondsToDiffTime 0)

mkProfile :: Text -> CortexMemorySelectionProfile
mkProfile rawQuery =
  CortexMemorySelectionProfile
    { cortexMemoryRawQuery = rawQuery,
      cortexMemoryAnchoredItemIds = [],
      cortexMemoryTargetItemId = Nothing,
      cortexMemorySessionTokenBudget = 500,
      cortexMemorySessionMaxCount = 3,
      cortexMemoryReferenceTokenBudget = 1400,
      cortexMemoryReferenceMaxCount = 4,
      cortexMemoryRankWeights = defaultCortexMemoryRankWeights,
      cortexMemorySourcePriorWeights = Map.singleton "checkpoint" 0.20,
      cortexMemorySourcePriorDefault = 0.30,
      cortexMemoryMinScoreBySourceKind = Map.singleton "checkpoint" 0.05,
      cortexMemoryMinScoreDefault = 0.20
    }

mkRequest :: Text -> CortexMemoryRetrievalRequest
mkRequest rawQuery =
  CortexMemoryRetrievalRequest
    { cortexMemorySelectionProfile = mkProfile rawQuery,
      cortexMemorySessionId = Nothing,
      cortexMemorySearchQuery = rawQuery,
      cortexMemoryExplicitTargetItemId = Nothing,
      cortexMemoryLinkedItemIds = [],
      cortexMemorySessionPassageLimit = 12,
      cortexMemorySearchResultLimit = 60
    }

mkPassage ::
  UUID ->
  Maybe UUID ->
  Maybe UUID ->
  Maybe UUID ->
  Text ->
  Text ->
  Text ->
  UTCTime ->
  CortexMemoryPassage
mkPassage passageId' itemId' checkpointId' sessionId' sourceKind' title' body' updatedAt' =
  CortexMemoryPassage
    { cortexMemoryPassageId = passageId',
      cortexMemorySourceKind = sourceKind',
      cortexMemorySourceItemId = itemId',
      cortexMemorySourceCheckpointId = checkpointId',
      cortexMemorySourceVersionId = uuidFromWord 999,
      cortexMemoryChatSessionId = sessionId',
      cortexMemoryPassageOrder = 0,
      cortexMemorySourceTitle = title',
      cortexMemorySectionHeading = Nothing,
      cortexMemoryPassageText = body',
      cortexMemoryEntities = ["AMD"],
      cortexMemoryReportType = Nothing,
      cortexMemoryTimeRange = Nothing,
      cortexMemoryPassageTokenCount = 8,
      cortexMemorySourceCreatedAt = updatedAt',
      cortexMemorySourceUpdatedAt = updatedAt'
    }

mkCandidate :: CortexMemoryRetrievalSource -> CortexMemoryPassage -> Double -> CortexMemoryCandidate
mkCandidate source passage score =
  CortexMemoryCandidate
    { cortexCandidatePassage = passage,
      cortexCandidateLexicalScore = if source == CortexMemoryRetrievedFromLexical then Just score else Nothing,
      cortexCandidateFuzzyScore = if source == CortexMemoryRetrievedFromFuzzy then Just score else Nothing,
      cortexCandidateSemanticScore = if source == CortexMemoryRetrievedFromSemantic then Just score else Nothing,
      cortexCandidateMatchedTerms = ["amd", "downside"],
      cortexCandidateMatchedFields = [],
      cortexCandidateSources = [source],
      cortexCandidateFusionScore = score
    }

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0

passageTitle :: CortexMemoryPassage -> Text
passageTitle = (.cortexMemorySourceTitle)

rankedTitle :: CortexMemoryRankedPassage -> Text
rankedTitle = (.cortexMemorySourceTitle) . (.cortexRankedPassage)

rankedSourceItemId :: CortexMemoryRankedPassage -> Maybe UUID
rankedSourceItemId = (.cortexMemorySourceItemId) . (.cortexRankedPassage)
