{- |
Module      : Logos.Memory.Candidates
Description : Logos reasoning-library support for candidates.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Candidates
  ( LogosMemorySearchPlan (..)
  , QueryComplexity (..)
  , buildMemorySearchPlan
  , classifyQueryComplexity
  , generateMemoryCandidates
  , mergeMemoryCandidates
  )
where

import Data.List (sortBy)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.Ord (Down (..), comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Logos.Memory.Host
  ( LogosMemoryHost (..)
  )
import Logos.Memory.Query
  ( LogosMemoryQuery (..)
  , logosMemoryQueryIsBlank
  , logosMemoryQueryPositiveTerms
  )
import Logos.Memory.Types
  ( LogosMemoryCandidate (..)
  , LogosMemoryEntityConfig (..)
  , LogosMemoryMatchedField (..)
  , LogosMemoryPassage (..)
  , LogosMemoryRetrievalSource (..)
  )

{- | Classified query complexity determines which search strategies to use.
Simpler queries skip expensive strategies (semantic) to reduce latency
and prevent noise injection.
-}
data QueryComplexity
  = -- | Blank query — no search at all, only anchored/direct items
    QueryBlank
  | -- | Entity-only query (e.g., "AAPL") — lexical exact match is sufficient
    QueryEntityLookup
  | -- | Short factual (1-2 terms, no entities) — lexical + fuzzy, skip semantic
    QuerySimpleLexical
  | -- | Complex analytical — full pipeline
    QueryFull
  deriving stock (Eq, Show)

classifyQueryComplexity :: LogosMemoryEntityConfig -> LogosMemoryQuery -> QueryComplexity
classifyQueryComplexity entityConfig query
  | logosMemoryQueryIsBlank query = QueryBlank
  | null query.logosMemoryQueryTerms = QueryBlank
  | logosMemoryIsEntityOnlyQuery entityConfig query.logosMemoryQueryRawText = QueryEntityLookup
  | length query.logosMemoryQueryTerms <= 2
      && not (logosMemoryQueryHasEntityIntent entityConfig query.logosMemoryQueryRawText) =
      QuerySimpleLexical
  | otherwise = QueryFull

data LogosMemorySearchPlan = LogosMemorySearchPlan
  { logosMemorySearchPlanQuery :: LogosMemoryQuery
  , logosMemorySearchPlanUseLexical :: Bool
  , logosMemorySearchPlanUseFuzzy :: Bool
  , logosMemorySearchPlanUseSemantic :: Bool
  , logosMemorySearchPlanAnchoredItemIds :: [UUID]
  , logosMemorySearchPlanSessionId :: Maybe UUID
  , logosMemorySearchPlanCandidateLimit :: Int
  }
  deriving stock (Eq, Show)

buildMemorySearchPlan
  :: LogosMemoryEntityConfig
  -> LogosMemoryQuery
  -> Maybe UUID
  -> [UUID]
  -> Int
  -> LogosMemorySearchPlan
buildMemorySearchPlan entityConfig query maybeSessionId anchoredItemIds candidateLimit =
  let complexity = classifyQueryComplexity entityConfig query
      (useLex, useFuz, useSem) = case complexity of
        QueryBlank -> (False, False, False)
        QueryEntityLookup -> (True, False, False)
        QuerySimpleLexical -> (True, True, False)
        QueryFull -> (True, True, True)
   in LogosMemorySearchPlan
        { logosMemorySearchPlanQuery = query
        , logosMemorySearchPlanUseLexical = useLex
        , logosMemorySearchPlanUseFuzzy = useFuz
        , logosMemorySearchPlanUseSemantic = useSem
        , logosMemorySearchPlanAnchoredItemIds = trimmedAnchoredItemIds
        , logosMemorySearchPlanSessionId = maybeSessionId
        , logosMemorySearchPlanCandidateLimit = min 80 candidateLimit
        }
  where
    dedupedAnchoredItemIds = List.nub anchoredItemIds
    trimmedAnchoredItemIds =
      case query.logosMemoryQueryExplicitTargetItemId of
        Nothing -> take 8 dedupedAnchoredItemIds
        Just explicitTargetItemId ->
          explicitTargetItemId : take 8 (filter (/= explicitTargetItemId) dedupedAnchoredItemIds)

generateMemoryCandidates
  :: Monad m
  => LogosMemoryHost m
  -> LogosMemorySearchPlan
  -> [LogosMemoryPassage]
  -> m [LogosMemoryCandidate]
generateMemoryCandidates host plan sessionPassages = do
  directAndAnchoredPassages <-
    if null plan.logosMemorySearchPlanAnchoredItemIds
      then pure []
      else logosMemoryLoadItemPassages host plan.logosMemorySearchPlanAnchoredItemIds
  lexicalCandidates <-
    if plan.logosMemorySearchPlanUseLexical
      then logosMemorySearchLexical host plan.logosMemorySearchPlanQuery lexicalLimit
      else pure []
  fuzzyCandidates <-
    if plan.logosMemorySearchPlanUseFuzzy
      then logosMemorySearchFuzzy host plan.logosMemorySearchPlanQuery fuzzyLimit
      else pure []
  semanticCandidates <-
    if plan.logosMemorySearchPlanUseSemantic
      then logosMemorySearchSemantic host plan.logosMemorySearchPlanQuery semanticLimit
      else pure []
  pure $
    mergeMemoryCandidates
      plan.logosMemorySearchPlanQuery
      ( sessionCandidates
          <> directAndAnchoredCandidates plan.logosMemorySearchPlanQuery directAndAnchoredPassages
          <> lexicalCandidates
          <> fuzzyCandidates
          <> semanticCandidates
      )
  where
    lexicalLimit = min 40 plan.logosMemorySearchPlanCandidateLimit
    fuzzyLimit = min 30 plan.logosMemorySearchPlanCandidateLimit
    semanticLimit = min 30 plan.logosMemorySearchPlanCandidateLimit
    sessionCandidates
      | logosMemoryQueryIsBlank plan.logosMemorySearchPlanQuery = []
      | otherwise =
          fmap
            ( annotateCandidate plan.logosMemorySearchPlanQuery
                . baseCandidate LogosMemoryRetrievedFromSessionLocal
            )
            (take 12 sessionPassages)

mergeMemoryCandidates :: LogosMemoryQuery -> [LogosMemoryCandidate] -> [LogosMemoryCandidate]
mergeMemoryCandidates query candidates =
  sortBy
    ( comparing (Down . logosCandidateFusionScore)
        <> comparing (Down . (.logosMemorySourceUpdatedAt) . logosCandidatePassage)
    )
    (Map.elems merged)
  where
    rankedEntries =
      concatMap rankCandidatesForSource [minBound .. maxBound]
    merged =
      foldl' mergeCandidate Map.empty rankedEntries
    mergeCandidate acc (source, rankIndex, candidate) =
      Map.insertWith
        combineCandidates
        candidate.logosCandidatePassage.logosMemoryPassageId
        (sourceContribution query source rankIndex candidate)
        acc
    rankCandidatesForSource source =
      (\(rankIndex, candidate) -> (source, rankIndex, candidate))
        <$> zip
          [1 :: Int ..]
          ( sortBy
              (candidateOrderingForSource source)
              (filter (elem source . logosCandidateSources) candidates)
          )
    reciprocalRank rankIndex = 1 / fromIntegral (60 + rankIndex)
    sourceContribution query' source rankIndex candidate =
      annotateCandidate
        query'
        candidate
          { logosCandidateSources = [source]
          , logosCandidateFusionScore = sourceBias source + reciprocalRank rankIndex
          }

combineCandidates :: LogosMemoryCandidate -> LogosMemoryCandidate -> LogosMemoryCandidate
combineCandidates newer older =
  older
    { logosCandidateLexicalScore =
        pickMax older.logosCandidateLexicalScore newer.logosCandidateLexicalScore
    , logosCandidateFuzzyScore = pickMax older.logosCandidateFuzzyScore newer.logosCandidateFuzzyScore
    , logosCandidateSemanticScore =
        pickMax older.logosCandidateSemanticScore newer.logosCandidateSemanticScore
    , logosCandidateMatchedTerms =
        ordNub (older.logosCandidateMatchedTerms <> newer.logosCandidateMatchedTerms)
    , logosCandidateMatchedFields =
        ordNub (older.logosCandidateMatchedFields <> newer.logosCandidateMatchedFields)
    , logosCandidateSources = ordNub (older.logosCandidateSources <> newer.logosCandidateSources)
    , logosCandidateFusionScore = older.logosCandidateFusionScore + newer.logosCandidateFusionScore
    }
  where
    pickMax left right =
      case (left, right) of
        (Nothing, other) -> other
        (other, Nothing) -> other
        (Just x, Just y) -> Just (max x y)

candidateOrderingForSource
  :: LogosMemoryRetrievalSource
  -> LogosMemoryCandidate
  -> LogosMemoryCandidate
  -> Ordering
candidateOrderingForSource source =
  comparing (Down . candidateScoreForSource source)
    <> comparing (Down . (.logosMemorySourceUpdatedAt) . logosCandidatePassage)
    <> comparing (Down . (.logosMemoryPassageOrder) . logosCandidatePassage)

candidateScoreForSource :: LogosMemoryRetrievalSource -> LogosMemoryCandidate -> Double
candidateScoreForSource source candidate =
  case source of
    LogosMemoryRetrievedFromLexical -> fromMaybe 0 candidate.logosCandidateLexicalScore
    LogosMemoryRetrievedFromFuzzy -> fromMaybe 0 candidate.logosCandidateFuzzyScore
    LogosMemoryRetrievedFromSemantic -> fromMaybe 0 candidate.logosCandidateSemanticScore
    LogosMemoryRetrievedFromSessionLocal -> sourceBias source
    LogosMemoryRetrievedFromDirectTarget -> sourceBias source
    LogosMemoryRetrievedFromAnchored -> sourceBias source

directAndAnchoredCandidates
  :: LogosMemoryQuery
  -> [LogosMemoryPassage]
  -> [LogosMemoryCandidate]
directAndAnchoredCandidates query passages =
  concatMap buildForItem grouped
  where
    explicitTargetItemId = query.logosMemoryQueryExplicitTargetItemId
    grouped =
      Map.toList $
        Map.fromListWith
          (<>)
          [ (itemId, [passage])
          | passage <- passages
          , itemId <- maybeToList passage.logosMemorySourceItemId
          ]
    buildForItem (itemId, itemPassages) =
      let sortedPassages = sortBy (comparing (.logosMemoryPassageOrder)) itemPassages
          limitN
            | Just itemId == explicitTargetItemId = 12
            | otherwise = 4
          source
            | Just itemId == explicitTargetItemId = LogosMemoryRetrievedFromDirectTarget
            | otherwise = LogosMemoryRetrievedFromAnchored
       in fmap (annotateCandidate query . baseCandidate source) (take limitN sortedPassages)

baseCandidate :: LogosMemoryRetrievalSource -> LogosMemoryPassage -> LogosMemoryCandidate
baseCandidate source passage =
  LogosMemoryCandidate
    { logosCandidatePassage = passage
    , logosCandidateLexicalScore = Nothing
    , logosCandidateFuzzyScore = Nothing
    , logosCandidateSemanticScore = Nothing
    , logosCandidateMatchedTerms = []
    , logosCandidateMatchedFields = []
    , logosCandidateSources = [source]
    , logosCandidateFusionScore = sourceBias source
    }

sourceBias :: LogosMemoryRetrievalSource -> Double
sourceBias = \case
  LogosMemoryRetrievedFromDirectTarget -> 1.0
  LogosMemoryRetrievedFromAnchored -> 0.45
  LogosMemoryRetrievedFromSessionLocal -> 0.3
  LogosMemoryRetrievedFromLexical -> 0.0
  LogosMemoryRetrievedFromFuzzy -> 0.0
  LogosMemoryRetrievedFromSemantic -> 0.0

annotateCandidate :: LogosMemoryQuery -> LogosMemoryCandidate -> LogosMemoryCandidate
annotateCandidate query candidate =
  candidate
    { logosCandidateMatchedTerms = ordNub matchedTerms
    , logosCandidateMatchedFields = ordNub matchedFields
    }
  where
    positiveTerms = logosMemoryQueryPositiveTerms query
    titleHaystack = T.toLower candidate.logosCandidatePassage.logosMemorySourceTitle
    headingHaystack = T.toLower (fromMaybe "" candidate.logosCandidatePassage.logosMemorySectionHeading)
    bodyHaystack = T.toLower candidate.logosCandidatePassage.logosMemoryPassageText
    entitiesUpper = Set.fromList (fmap T.toUpper candidate.logosCandidatePassage.logosMemoryEntities)
    matchedTerms =
      [ term
      | term <- positiveTerms
      , termMatches term titleHaystack headingHaystack bodyHaystack entitiesUpper
      ]
    matchedFields =
      concatMap (fieldsForTerm titleHaystack headingHaystack bodyHaystack entitiesUpper) matchedTerms

fieldsForTerm
  :: Text
  -> Text
  -> Text
  -> Set.Set Text
  -> Text
  -> [LogosMemoryMatchedField]
fieldsForTerm titleHaystack headingHaystack bodyHaystack entitiesUpper term =
  ordNub $
    [ LogosMemoryMatchedTitle
    | term `T.isInfixOf` titleHaystack
    ]
      <> [ LogosMemoryMatchedHeading
         | term `T.isInfixOf` headingHaystack
         ]
      <> [ LogosMemoryMatchedBody
         | term `T.isInfixOf` bodyHaystack
         ]
      <> [ LogosMemoryMatchedEntity
         | Set.member (T.toUpper term) entitiesUpper
         ]

termMatches :: Text -> Text -> Text -> Text -> Set.Set Text -> Bool
termMatches term titleHaystack headingHaystack bodyHaystack entitiesUpper =
  term `T.isInfixOf` titleHaystack
    || term `T.isInfixOf` headingHaystack
    || term `T.isInfixOf` bodyHaystack
    || Set.member (T.toUpper term) entitiesUpper

ordNub :: Ord a => [a] -> [a]
ordNub = Set.toList . Set.fromList
