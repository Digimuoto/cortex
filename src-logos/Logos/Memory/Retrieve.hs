{- |
Module      : Logos.Memory.Retrieve
Description : Logos reasoning-library support for retrieve.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Retrieve
  ( LogosMemoryRetrievalContext (..)
  , LogosMemoryRetrievalRequest (..)
  , LogosMemorySelectionProfile (..)
  , resolveMemoryContext
  )
where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe, maybeToList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Logos.Memory.Candidates
  ( buildMemorySearchPlan
  , generateMemoryCandidates
  )
import Logos.Memory.Conflict
  ( resolveMemoryConflicts
  )
import Logos.Memory.Host
  ( LogosMemoryHost (..)
  )
import Logos.Memory.Pack
  ( packReferencePassages
  , packSessionPassages
  )
import Logos.Memory.Query
  ( LogosMemoryQuery (..)
  , logosMemoryQueryIsBlank
  , parseMemoryQuery
  )
import Logos.Memory.Rank
  ( LogosMemoryRankWeights
  , rankMemoryCandidates
  )
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryEntityConfig
  , LogosMemoryPassage (..)
  , LogosMemoryRankedPassage (..)
  , LogosMemoryRetrievalSource (..)
  )

data LogosMemorySelectionProfile = LogosMemorySelectionProfile
  { logosMemoryRawQuery :: Text
  , logosMemoryAnchoredItemIds :: [UUID]
  , logosMemoryTargetItemId :: Maybe UUID
  , logosMemorySessionTokenBudget :: Int64
  , logosMemorySessionMaxCount :: Int
  , logosMemoryReferenceTokenBudget :: Int64
  , logosMemoryReferenceMaxCount :: Int
  , logosMemoryRankWeights :: LogosMemoryRankWeights
  , logosMemorySourcePriorWeights :: Map Text Double
  {- ^ Source-kind-keyed prior weights for ranking. App-defined labels
   (e.g. "checkpoint", "saved_report") map to prior scores in [0,1].
   Source kinds not in the map get 'logosMemorySourcePriorDefault'.
  -}
  , logosMemorySourcePriorDefault :: Double
  -- ^ Default source prior for source kinds not in the weight map.
  , logosMemoryMinScoreBySourceKind :: Map Text Double
  {- ^ Minimum retrieval score by source kind. Source kinds not in the
   map get 'logosMemoryMinScoreDefault'.
  -}
  , logosMemoryMinScoreDefault :: Double
  }
  deriving stock (Eq, Show)

data LogosMemoryRetrievalRequest = LogosMemoryRetrievalRequest
  { logosMemorySelectionProfile :: LogosMemorySelectionProfile
  , logosMemorySessionId :: Maybe UUID
  , logosMemorySearchQuery :: Text
  , logosMemoryExplicitTargetItemId :: Maybe UUID
  , logosMemoryLinkedItemIds :: [UUID]
  , logosMemorySessionPassageLimit :: Int
  , logosMemorySearchResultLimit :: Int
  }
  deriving stock (Eq, Show)

data LogosMemoryRetrievalContext = LogosMemoryRetrievalContext
  { logosMemorySessionPassages :: [LogosMemoryPassage]
  , logosMemoryReferencePassages :: [LogosMemoryRankedPassage]
  }
  deriving stock (Eq, Show)

resolveMemoryContext
  :: Monad m
  => LogosMemoryHost m
  -> LogosMemoryEntityConfig
  -> UTCTime
  -> LogosMemoryRetrievalRequest
  -> m LogosMemoryRetrievalContext
resolveMemoryContext host entityConfig now request = do
  sessionPassages0 <-
    case request.logosMemorySessionId of
      Nothing -> pure []
      Just sessionId ->
        logosMemoryLoadSessionPassages host sessionId request.logosMemorySessionPassageLimit
  let parsedQuery =
        parseMemoryQuery
          entityConfig
          request.logosMemorySearchQuery
          request.logosMemoryLinkedItemIds
          request.logosMemoryExplicitTargetItemId
      selectedSession =
        packSessionPassages
          request.logosMemorySelectionProfile.logosMemorySessionTokenBudget
          request.logosMemorySelectionProfile.logosMemorySessionMaxCount
          sessionPassages0
      anchoredItemIds =
        request.logosMemoryExplicitTargetItemId `maybeCons` request.logosMemoryLinkedItemIds
      searchPlan =
        buildMemorySearchPlan
          entityConfig
          parsedQuery
          request.logosMemorySessionId
          anchoredItemIds
          request.logosMemorySearchResultLimit
  candidateRows0 <-
    if logosMemoryQueryIsBlank parsedQuery && null anchoredItemIds
      then pure []
      else generateMemoryCandidates host searchPlan sessionPassages0
  let afterNegativeFilter = filterNegativeTerms anchoredItemIds parsedQuery candidateRows0
      loadedSessionCheckpointIds =
        Set.fromList (mapMaybe (.logosMemorySourceCheckpointId) sessionPassages0)
      candidateRows =
        filter
          ( \candidate ->
              maybe
                True
                (`Set.notMember` loadedSessionCheckpointIds)
                candidate.logosCandidatePassage.logosMemorySourceCheckpointId
          )
          afterNegativeFilter
      rankedRows =
        rankMemoryCandidates
          now
          request.logosMemorySelectionProfile.logosMemorySourcePriorWeights
          request.logosMemorySelectionProfile.logosMemorySourcePriorDefault
          request.logosMemorySelectionProfile.logosMemoryRankWeights
          parsedQuery
          candidateRows
      filteredRows =
        filter qualifiesForRetrieval
          . resolveMemoryConflicts entityConfig
          $ rankedRows

  pure $
    LogosMemoryRetrievalContext
      { logosMemorySessionPassages = selectedSession
      , logosMemoryReferencePassages =
          packReferencePassages
            request.logosMemorySelectionProfile.logosMemoryReferenceTokenBudget
            request.logosMemorySelectionProfile.logosMemoryReferenceMaxCount
            filteredRows
      }
  where
    maybeCons Nothing values = Set.toList (Set.fromList values)
    maybeCons (Just x) values = Set.toList (Set.fromList (x : values))
    qualifiesForRetrieval row =
      hasExplicitlyAnchoredSource row
        || logosRankedFinalScore row
          >= Map.findWithDefault
            request.logosMemorySelectionProfile.logosMemoryMinScoreDefault
            (T.toLower row.logosRankedPassage.logosMemorySourceKind)
            request.logosMemorySelectionProfile.logosMemoryMinScoreBySourceKind

    hasExplicitlyAnchoredSource row =
      any
        (`elem` row.logosRankedCandidate.logosCandidateSources)
        [LogosMemoryRetrievedFromDirectTarget, LogosMemoryRetrievedFromAnchored]

{- | Filter out candidates whose text, title, heading, or entities contain
any of the query's negative terms (terms prefixed with "-" in the
original query). Preserves explicitly anchored passages (direct target
or linked items) since the user explicitly requested them in context.
Uses word-boundary tokenization that preserves dots for dotted symbols.
-}
filterNegativeTerms
  :: [UUID] -> LogosMemoryQuery -> [LogosMemoryCandidate] -> [LogosMemoryCandidate]
filterNegativeTerms anchoredItemIds query
  | null query.logosMemoryQueryNegativeTerms = id
  | otherwise = filter (\c -> isAnchored c || not (matchesNegativeTerm c))
  where
    anchoredSet = Set.fromList anchoredItemIds
    negTerms = Set.fromList (fmap T.toLower query.logosMemoryQueryNegativeTerms)
    isAnchored candidate =
      case candidate.logosCandidatePassage.logosMemorySourceItemId of
        Just itemId -> Set.member itemId anchoredSet
        Nothing -> False
    matchesNegativeTerm candidate =
      let p = candidate.logosCandidatePassage
          tokens =
            Set.fromList $
              tokenize p.logosMemoryPassageText
                <> tokenize p.logosMemorySourceTitle
                <> foldMap tokenize (maybeToList p.logosMemorySectionHeading)
                <> fmap T.toLower p.logosMemoryEntities
       in not (Set.null (Set.intersection negTerms tokens))
    -- Split on whitespace and delimiters, then strip leading/trailing dots
    -- so "bearish." matches "bearish" while "BRK.B" keeps its internal dot.
    tokenize =
      fmap (T.toLower . T.dropAround (== '.'))
        . T.words
        . T.map (\c -> if c `elem` (",;:!?()[]{}\"'" :: [Char]) then ' ' else c)
