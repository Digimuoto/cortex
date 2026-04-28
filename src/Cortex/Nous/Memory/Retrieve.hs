{-# LANGUAGE OverloadedRecordDot #-}

module Cortex.Nous.Memory.Retrieve
  ( CortexMemoryRetrievalContext (..),
    CortexMemoryRetrievalRequest (..),
    CortexMemorySelectionProfile (..),
    resolveMemoryContext,
  )
where

import Cortex.Nous.Memory.Candidates
  ( buildMemorySearchPlan,
    generateMemoryCandidates,
  )
import Cortex.Nous.Memory.Conflict
  ( resolveMemoryConflicts,
  )
import Cortex.Nous.Memory.Host
  ( CortexMemoryHost (..),
  )
import Cortex.Nous.Memory.Pack
  ( packReferencePassages,
    packSessionPassages,
  )
import Cortex.Nous.Memory.Query
  ( CortexMemoryQuery (..),
    cortexMemoryQueryIsBlank,
    parseMemoryQuery,
  )
import Cortex.Nous.Memory.Rank
  ( CortexMemoryRankWeights,
    rankMemoryCandidates,
  )
import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate (..),
    CortexMemoryEntityConfig,
    CortexMemoryPassage (..),
    CortexMemoryRankedPassage (..),
    CortexMemoryRetrievalSource (..),
  )
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe, maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.UUID (UUID)

data CortexMemorySelectionProfile = CortexMemorySelectionProfile
  { cortexMemoryRawQuery :: Text,
    cortexMemoryAnchoredItemIds :: [UUID],
    cortexMemoryTargetItemId :: Maybe UUID,
    cortexMemorySessionTokenBudget :: Int64,
    cortexMemorySessionMaxCount :: Int,
    cortexMemoryReferenceTokenBudget :: Int64,
    cortexMemoryReferenceMaxCount :: Int,
    cortexMemoryRankWeights :: CortexMemoryRankWeights,
    -- | Source-kind-keyed prior weights for ranking. App-defined labels
    -- (e.g. "checkpoint", "saved_report") map to prior scores in [0,1].
    -- Source kinds not in the map get 'cortexMemorySourcePriorDefault'.
    cortexMemorySourcePriorWeights :: Map Text Double,
    -- | Default source prior for source kinds not in the weight map.
    cortexMemorySourcePriorDefault :: Double,
    -- | Minimum retrieval score by source kind. Source kinds not in the
    -- map get 'cortexMemoryMinScoreDefault'.
    cortexMemoryMinScoreBySourceKind :: Map Text Double,
    cortexMemoryMinScoreDefault :: Double
  }
  deriving stock (Eq, Show)

data CortexMemoryRetrievalRequest = CortexMemoryRetrievalRequest
  { cortexMemorySelectionProfile :: CortexMemorySelectionProfile,
    cortexMemorySessionId :: Maybe UUID,
    cortexMemorySearchQuery :: Text,
    cortexMemoryExplicitTargetItemId :: Maybe UUID,
    cortexMemoryLinkedItemIds :: [UUID],
    cortexMemorySessionPassageLimit :: Int,
    cortexMemorySearchResultLimit :: Int
  }
  deriving stock (Eq, Show)

data CortexMemoryRetrievalContext = CortexMemoryRetrievalContext
  { cortexMemorySessionPassages :: [CortexMemoryPassage],
    cortexMemoryReferencePassages :: [CortexMemoryRankedPassage]
  }
  deriving stock (Eq, Show)

resolveMemoryContext ::
  (Monad m) =>
  CortexMemoryHost m ->
  CortexMemoryEntityConfig ->
  UTCTime ->
  CortexMemoryRetrievalRequest ->
  m CortexMemoryRetrievalContext
resolveMemoryContext host entityConfig now request = do
  sessionPassages0 <-
    case request.cortexMemorySessionId of
      Nothing -> pure []
      Just sessionId ->
        cortexMemoryLoadSessionPassages host sessionId request.cortexMemorySessionPassageLimit
  let parsedQuery =
        parseMemoryQuery
          entityConfig
          request.cortexMemorySearchQuery
          request.cortexMemoryLinkedItemIds
          request.cortexMemoryExplicitTargetItemId
      selectedSession =
        packSessionPassages
          request.cortexMemorySelectionProfile.cortexMemorySessionTokenBudget
          request.cortexMemorySelectionProfile.cortexMemorySessionMaxCount
          sessionPassages0
      anchoredItemIds =
        request.cortexMemoryExplicitTargetItemId `maybeCons` request.cortexMemoryLinkedItemIds
      searchPlan =
        buildMemorySearchPlan
          entityConfig
          parsedQuery
          request.cortexMemorySessionId
          anchoredItemIds
          request.cortexMemorySearchResultLimit
  candidateRows0 <-
    if cortexMemoryQueryIsBlank parsedQuery && null anchoredItemIds
      then pure []
      else generateMemoryCandidates host searchPlan sessionPassages0
  let afterNegativeFilter = filterNegativeTerms anchoredItemIds parsedQuery candidateRows0
      loadedSessionCheckpointIds =
        Set.fromList (mapMaybe (.cortexMemorySourceCheckpointId) sessionPassages0)
      candidateRows =
        filter
          ( \candidate ->
              maybe True (`Set.notMember` loadedSessionCheckpointIds) candidate.cortexCandidatePassage.cortexMemorySourceCheckpointId
          )
          afterNegativeFilter
      rankedRows =
        rankMemoryCandidates
          now
          request.cortexMemorySelectionProfile.cortexMemorySourcePriorWeights
          request.cortexMemorySelectionProfile.cortexMemorySourcePriorDefault
          request.cortexMemorySelectionProfile.cortexMemoryRankWeights
          parsedQuery
          candidateRows
      filteredRows =
        filter qualifiesForRetrieval
          . resolveMemoryConflicts entityConfig
          $ rankedRows

  pure $
    CortexMemoryRetrievalContext
      { cortexMemorySessionPassages = selectedSession,
        cortexMemoryReferencePassages =
          packReferencePassages
            request.cortexMemorySelectionProfile.cortexMemoryReferenceTokenBudget
            request.cortexMemorySelectionProfile.cortexMemoryReferenceMaxCount
            filteredRows
      }
  where
    maybeCons Nothing values = Set.toList (Set.fromList values)
    maybeCons (Just x) values = Set.toList (Set.fromList (x : values))
    qualifiesForRetrieval row =
      hasExplicitlyAnchoredSource row
        || cortexRankedFinalScore row
          >= Map.findWithDefault
            request.cortexMemorySelectionProfile.cortexMemoryMinScoreDefault
            (T.toLower row.cortexRankedPassage.cortexMemorySourceKind)
            request.cortexMemorySelectionProfile.cortexMemoryMinScoreBySourceKind

    hasExplicitlyAnchoredSource row =
      any
        (`elem` row.cortexRankedCandidate.cortexCandidateSources)
        [CortexMemoryRetrievedFromDirectTarget, CortexMemoryRetrievedFromAnchored]

-- | Filter out candidates whose text, title, heading, or entities contain
-- any of the query's negative terms (terms prefixed with "-" in the
-- original query). Preserves explicitly anchored passages (direct target
-- or linked items) since the user explicitly requested them in context.
-- Uses word-boundary tokenization that preserves dots for dotted symbols.
filterNegativeTerms :: [UUID] -> CortexMemoryQuery -> [CortexMemoryCandidate] -> [CortexMemoryCandidate]
filterNegativeTerms anchoredItemIds query
  | null query.cortexMemoryQueryNegativeTerms = id
  | otherwise = filter (\c -> isAnchored c || not (matchesNegativeTerm c))
  where
    anchoredSet = Set.fromList anchoredItemIds
    negTerms = Set.fromList (fmap T.toLower query.cortexMemoryQueryNegativeTerms)
    isAnchored candidate =
      case candidate.cortexCandidatePassage.cortexMemorySourceItemId of
        Just itemId -> Set.member itemId anchoredSet
        Nothing -> False
    matchesNegativeTerm candidate =
      let p = candidate.cortexCandidatePassage
          tokens =
            Set.fromList $
              tokenize p.cortexMemoryPassageText
                <> tokenize p.cortexMemorySourceTitle
                <> foldMap tokenize (maybeToList p.cortexMemorySectionHeading)
                <> fmap T.toLower p.cortexMemoryEntities
       in not (Set.null (Set.intersection negTerms tokens))
    -- Split on whitespace and delimiters, then strip leading/trailing dots
    -- so "bearish." matches "bearish" while "BRK.B" keeps its internal dot.
    tokenize =
      fmap (T.toLower . T.dropAround (== '.'))
        . T.words
        . T.map (\c -> if c `elem` (",;:!?()[]{}\"'" :: [Char]) then ' ' else c)
