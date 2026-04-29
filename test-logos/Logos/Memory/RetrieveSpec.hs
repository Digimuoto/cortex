{- |
Module      : Logos.Memory.RetrieveSpec
Description : Tests for Logos.Memory.Retrieve.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Memory.RetrieveSpec (spec) where

import Control.Monad.State.Strict
  ( State
  , modify'
  , runState
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.Word (Word32)
import Logos.Memory.Host
  ( LogosMemoryHost (..)
  )
import Logos.Memory.Query
  ( LogosMemoryQuery (..)
  )
import Logos.Memory.Rank
  ( defaultLogosMemoryRankWeights
  )
import Logos.Memory.Retrieve
  ( LogosMemoryRetrievalContext (..)
  , LogosMemoryRetrievalRequest (..)
  , LogosMemorySelectionProfile (..)
  , resolveMemoryContext
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
                  ]
              , hostLexicalCandidates =
                  [ mkCandidate
                      LogosMemoryRetrievedFromLexical
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
                      1.0
                  , mkCandidate
                      LogosMemoryRetrievedFromLexical
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
                  ]
              , hostFuzzyCandidates = []
              , hostSemanticCandidates = []
              , hostItemPassages = []
              }
          request =
            (mkRequest "AMD downside watch")
              { logosMemorySessionId = Just sessionId
              }
          (retrievalContext, trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultLogosMemoryEntityConfig fixedNow request)
              emptyTrace

      trace.traceSessionLoads `shouldBe` [(sessionId, 12)]
      trace.traceLexicalLoads `shouldBe` [("AMD downside watch", 40)]
      fmap passageTitle retrievalContext.logosMemorySessionPassages
        `shouldBe` ["Prior checkpoint"]
      fmap rankedTitle retrievalContext.logosMemoryReferencePassages
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
                      olderTime
                  , mkPassage
                      (uuidFromWord 111)
                      Nothing
                      (Just keptCheckpointId)
                      (Just sessionId)
                      "checkpoint"
                      "Kept checkpoint"
                      "Newest session context."
                      newerTime
                  ]
              , hostLexicalCandidates =
                  [ mkCandidate
                      LogosMemoryRetrievedFromLexical
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
                  ]
              , hostFuzzyCandidates = []
              , hostSemanticCandidates = []
              , hostItemPassages = []
              }
          request =
            (mkRequest "AMD downside watch")
              { logosMemorySessionId = Just sessionId
              , logosMemorySelectionProfile =
                  (mkProfile "AMD downside watch")
                    { logosMemorySessionMaxCount = 1
                    , logosMemorySessionTokenBudget = 32
                    }
              }
          (retrievalContext, _trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultLogosMemoryEntityConfig fixedNow request)
              emptyTrace

      fmap passageTitle retrievalContext.logosMemorySessionPassages
        `shouldBe` ["Kept checkpoint"]
      fmap rankedTitle retrievalContext.logosMemoryReferencePassages
        `shouldBe` ["AMD external report"]

    it "loads anchored item passages even when the search query is blank" $ do
      let targetItemId = uuidFromWord 40
          linkedItemId = uuidFromWord 41
          dataSet =
            HostData
              { hostSessionPassages = []
              , hostLexicalCandidates = []
              , hostFuzzyCandidates = []
              , hostSemanticCandidates = []
              , hostItemPassages =
                  [ mkPassage
                      (uuidFromWord 104)
                      (Just targetItemId)
                      Nothing
                      Nothing
                      "saved_report"
                      "Target report"
                      "Prior target report context."
                      fixedNow
                  , mkPassage
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
              { logosMemorySelectionProfile =
                  (mkProfile "   ")
                    { logosMemoryAnchoredItemIds = [targetItemId, linkedItemId]
                    , logosMemoryTargetItemId = Just targetItemId
                    }
              , logosMemoryExplicitTargetItemId = Just targetItemId
              , logosMemoryLinkedItemIds = [targetItemId, linkedItemId, linkedItemId]
              }
          (retrievalContext, trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultLogosMemoryEntityConfig fixedNow request)
              emptyTrace

      trace.traceLexicalLoads `shouldBe` []
      trace.traceFuzzyLoads `shouldBe` []
      trace.traceSemanticLoads `shouldBe` []
      trace.traceItemLoads `shouldBe` [[targetItemId, linkedItemId]]
      fmap rankedSourceItemId retrievalContext.logosMemoryReferencePassages
        `shouldBe` [Just targetItemId, Just linkedItemId]

    it "keeps explicit target passages even for low-signal continuation prompts" $ do
      let targetItemId = uuidFromWord 42
          linkedItemId = uuidFromWord 43
          dataSet =
            HostData
              { hostSessionPassages = []
              , hostLexicalCandidates = []
              , hostFuzzyCandidates = []
              , hostSemanticCandidates = []
              , hostItemPassages =
                  [ mkPassage
                      (uuidFromWord 106)
                      (Just targetItemId)
                      Nothing
                      Nothing
                      "saved_report"
                      "Target report"
                      "Detailed target report context that does not lexically match the prompt."
                      fixedNow
                  , mkPassage
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
              { logosMemorySelectionProfile =
                  (mkProfile "continue this report")
                    { logosMemoryAnchoredItemIds = [targetItemId, linkedItemId]
                    , logosMemoryTargetItemId = Just targetItemId
                    }
              , logosMemoryExplicitTargetItemId = Just targetItemId
              , logosMemoryLinkedItemIds = [linkedItemId]
              }
          (retrievalContext, _trace) =
            runState
              (resolveMemoryContext (hostFromData dataSet) defaultLogosMemoryEntityConfig fixedNow request)
              emptyTrace

      fmap rankedSourceItemId retrievalContext.logosMemoryReferencePassages
        `shouldBe` [Just targetItemId, Just linkedItemId]

    it
      "exercises the full pipeline: candidates, ranking, conflict resolution, score threshold, and packing"
      $ do
        let sessionId = uuidFromWord 50
            itemId = uuidFromWord 60
            olderTime = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
            newerTime = UTCTime (fromGregorian 2026 3 15) (secondsToDiffTime 0)
            dataSet =
              HostData
                { hostSessionPassages =
                    [ mkPassage
                        (uuidFromWord 200)
                        Nothing
                        (Just (uuidFromWord 70))
                        (Just sessionId)
                        "checkpoint"
                        "Session checkpoint"
                        "Prior session context."
                        newerTime
                    ]
                , hostLexicalCandidates =
                    [ mkCandidate
                        LogosMemoryRetrievedFromLexical
                        ( mkPassage
                            (uuidFromWord 201)
                            (Just itemId)
                            Nothing
                            Nothing
                            "saved_report"
                            "AMD thesis"
                            "AMD remains bullish."
                            olderTime
                        )
                        0.8
                    , mkCandidate
                        LogosMemoryRetrievedFromLexical
                        ( mkPassage
                            (uuidFromWord 202)
                            (Just itemId)
                            Nothing
                            Nothing
                            "saved_report"
                            "AMD thesis"
                            "AMD downside risk is rising."
                            newerTime
                        )
                        0.7
                    ]
                , hostFuzzyCandidates = []
                , hostSemanticCandidates =
                    [ mkCandidate
                        LogosMemoryRetrievedFromSemantic
                        ( mkPassage
                            (uuidFromWord 203)
                            (Just (uuidFromWord 61))
                            Nothing
                            Nothing
                            "workspace_markdown"
                            "Unrelated note"
                            "Some unrelated content."
                            olderTime
                        )
                        0.01
                    ]
                , hostItemPassages = []
                }
            request =
              (mkRequest "AMD downside")
                { logosMemorySessionId = Just sessionId
                , logosMemorySelectionProfile =
                    (mkProfile "AMD downside")
                      { logosMemoryReferenceTokenBudget = 500
                      , logosMemoryReferenceMaxCount = 10
                      }
                }
            (ctx, _trace) =
              runState
                (resolveMemoryContext (hostFromData dataSet) defaultLogosMemoryEntityConfig fixedNow request)
                emptyTrace

        -- Session checkpoint should be included
        fmap passageTitle ctx.logosMemorySessionPassages
          `shouldBe` ["Session checkpoint"]
        -- The low-scoring semantic candidate (0.01) should be filtered out by the 0.20 threshold
        -- The conflicting bullish/bearish AMD passages from the same item should trigger conflict resolution
        -- (the newer bearish one wins)
        let refTitles = fmap rankedTitle ctx.logosMemoryReferencePassages
        refTitles `shouldSatisfy` notElem "Unrelated note"

data HostData = HostData
  { hostSessionPassages :: [LogosMemoryPassage]
  , hostLexicalCandidates :: [LogosMemoryCandidate]
  , hostFuzzyCandidates :: [LogosMemoryCandidate]
  , hostSemanticCandidates :: [LogosMemoryCandidate]
  , hostItemPassages :: [LogosMemoryPassage]
  }

data HostTrace = HostTrace
  { traceSessionLoads :: [(UUID, Int)]
  , traceLexicalLoads :: [(Text, Int)]
  , traceFuzzyLoads :: [(Text, Int)]
  , traceSemanticLoads :: [(Text, Int)]
  , traceItemLoads :: [[UUID]]
  }

emptyTrace :: HostTrace
emptyTrace =
  HostTrace
    { traceSessionLoads = []
    , traceLexicalLoads = []
    , traceFuzzyLoads = []
    , traceSemanticLoads = []
    , traceItemLoads = []
    }

hostFromData :: HostData -> LogosMemoryHost (State HostTrace)
hostFromData dataSet =
  LogosMemoryHost
    { logosMemoryLoadSessionPassages = \sessionId limitN -> do
        modify' (\trace -> trace {traceSessionLoads = trace.traceSessionLoads <> [(sessionId, limitN)]})
        pure dataSet.hostSessionPassages
    , logosMemorySearchLexical = \query limitN -> do
        modify'
          ( \trace ->
              trace
                { traceLexicalLoads = trace.traceLexicalLoads <> [(query.logosMemoryQueryWebsearchText, limitN)]
                }
          )
        pure dataSet.hostLexicalCandidates
    , logosMemorySearchFuzzy = \query limitN -> do
        modify'
          ( \trace ->
              trace {traceFuzzyLoads = trace.traceFuzzyLoads <> [(query.logosMemoryQueryNormalizedText, limitN)]}
          )
        pure dataSet.hostFuzzyCandidates
    , logosMemorySearchSemantic = \query limitN -> do
        modify'
          ( \trace ->
              trace
                { traceSemanticLoads = trace.traceSemanticLoads <> [(query.logosMemoryQuerySemanticText, limitN)]
                }
          )
        pure dataSet.hostSemanticCandidates
    , logosMemoryLoadItemPassages = \itemIds -> do
        modify' (\trace -> trace {traceItemLoads = trace.traceItemLoads <> [itemIds]})
        pure dataSet.hostItemPassages
    }

fixedNow :: UTCTime
fixedNow = UTCTime (fromGregorian 2026 3 20) (secondsToDiffTime 0)

mkProfile :: Text -> LogosMemorySelectionProfile
mkProfile rawQuery =
  LogosMemorySelectionProfile
    { logosMemoryRawQuery = rawQuery
    , logosMemoryAnchoredItemIds = []
    , logosMemoryTargetItemId = Nothing
    , logosMemorySessionTokenBudget = 500
    , logosMemorySessionMaxCount = 3
    , logosMemoryReferenceTokenBudget = 1400
    , logosMemoryReferenceMaxCount = 4
    , logosMemoryRankWeights = defaultLogosMemoryRankWeights
    , logosMemorySourcePriorWeights = Map.singleton "checkpoint" 0.20
    , logosMemorySourcePriorDefault = 0.30
    , logosMemoryMinScoreBySourceKind = Map.singleton "checkpoint" 0.05
    , logosMemoryMinScoreDefault = 0.20
    }

mkRequest :: Text -> LogosMemoryRetrievalRequest
mkRequest rawQuery =
  LogosMemoryRetrievalRequest
    { logosMemorySelectionProfile = mkProfile rawQuery
    , logosMemorySessionId = Nothing
    , logosMemorySearchQuery = rawQuery
    , logosMemoryExplicitTargetItemId = Nothing
    , logosMemoryLinkedItemIds = []
    , logosMemorySessionPassageLimit = 12
    , logosMemorySearchResultLimit = 60
    }

mkPassage
  :: UUID
  -> Maybe UUID
  -> Maybe UUID
  -> Maybe UUID
  -> Text
  -> Text
  -> Text
  -> UTCTime
  -> LogosMemoryPassage
mkPassage passageId' itemId' checkpointId' sessionId' sourceKind' title' body' updatedAt' =
  LogosMemoryPassage
    { logosMemoryPassageId = passageId'
    , logosMemorySourceKind = sourceKind'
    , logosMemorySourceItemId = itemId'
    , logosMemorySourceCheckpointId = checkpointId'
    , logosMemorySourceVersionId = uuidFromWord 999
    , logosMemoryChatSessionId = sessionId'
    , logosMemoryPassageOrder = 0
    , logosMemorySourceTitle = title'
    , logosMemorySectionHeading = Nothing
    , logosMemoryPassageText = body'
    , logosMemoryEntities = ["AMD"]
    , logosMemoryReportType = Nothing
    , logosMemoryTimeRange = Nothing
    , logosMemoryPassageTokenCount = 8
    , logosMemorySourceCreatedAt = updatedAt'
    , logosMemorySourceUpdatedAt = updatedAt'
    }

mkCandidate :: LogosMemoryRetrievalSource -> LogosMemoryPassage -> Double -> LogosMemoryCandidate
mkCandidate source passage score =
  LogosMemoryCandidate
    { logosCandidatePassage = passage
    , logosCandidateLexicalScore =
        if source == LogosMemoryRetrievedFromLexical then Just score else Nothing
    , logosCandidateFuzzyScore = if source == LogosMemoryRetrievedFromFuzzy then Just score else Nothing
    , logosCandidateSemanticScore =
        if source == LogosMemoryRetrievedFromSemantic then Just score else Nothing
    , logosCandidateMatchedTerms = ["amd", "downside"]
    , logosCandidateMatchedFields = []
    , logosCandidateSources = [source]
    , logosCandidateFusionScore = score
    }

uuidFromWord :: Word32 -> UUID
uuidFromWord = UUID.fromWords 0 0 0

passageTitle :: LogosMemoryPassage -> Text
passageTitle = (.logosMemorySourceTitle)

rankedTitle :: LogosMemoryRankedPassage -> Text
rankedTitle = (.logosMemorySourceTitle) . (.logosRankedPassage)

rankedSourceItemId :: LogosMemoryRankedPassage -> Maybe UUID
rankedSourceItemId = (.logosMemorySourceItemId) . (.logosRankedPassage)
