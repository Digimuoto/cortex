{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Nous.Memory.Candidates
  ( CortexMemorySearchPlan (..),
    QueryComplexity (..),
    buildMemorySearchPlan,
    classifyQueryComplexity,
    generateMemoryCandidates,
    mergeMemoryCandidates,
  )
where

import Cortex.Nous.Memory.Host
  ( CortexMemoryHost (..),
  )
import Cortex.Nous.Memory.Query
  ( CortexMemoryQuery (..),
    cortexMemoryQueryIsBlank,
    cortexMemoryQueryPositiveTerms,
  )
import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate (..),
    CortexMemoryEntityConfig (..),
    CortexMemoryMatchedField (..),
    CortexMemoryPassage (..),
    CortexMemoryRetrievalSource (..),
  )
import Data.List (sortBy)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.Ord (Down (..), comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)

-- | Classified query complexity determines which search strategies to use.
-- Simpler queries skip expensive strategies (semantic) to reduce latency
-- and prevent noise injection.
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

classifyQueryComplexity :: CortexMemoryEntityConfig -> CortexMemoryQuery -> QueryComplexity
classifyQueryComplexity entityConfig query
  | cortexMemoryQueryIsBlank query = QueryBlank
  | null query.cortexMemoryQueryTerms = QueryBlank
  | cortexMemoryIsEntityOnlyQuery entityConfig query.cortexMemoryQueryRawText = QueryEntityLookup
  | length query.cortexMemoryQueryTerms <= 2 && not (cortexMemoryQueryHasEntityIntent entityConfig query.cortexMemoryQueryRawText) = QuerySimpleLexical
  | otherwise = QueryFull

data CortexMemorySearchPlan = CortexMemorySearchPlan
  { cmspQuery :: CortexMemoryQuery,
    cmspUseLexical :: Bool,
    cmspUseFuzzy :: Bool,
    cmspUseSemantic :: Bool,
    cmspAnchoredItemIds :: [UUID],
    cmspSessionId :: Maybe UUID,
    cmspCandidateLimit :: Int
  }
  deriving stock (Eq, Show)

buildMemorySearchPlan ::
  CortexMemoryEntityConfig ->
  CortexMemoryQuery ->
  Maybe UUID ->
  [UUID] ->
  Int ->
  CortexMemorySearchPlan
buildMemorySearchPlan entityConfig query maybeSessionId anchoredItemIds candidateLimit =
  let complexity = classifyQueryComplexity entityConfig query
      (useLex, useFuz, useSem) = case complexity of
        QueryBlank -> (False, False, False)
        QueryEntityLookup -> (True, False, False)
        QuerySimpleLexical -> (True, True, False)
        QueryFull -> (True, True, True)
   in CortexMemorySearchPlan
        { cmspQuery = query,
          cmspUseLexical = useLex,
          cmspUseFuzzy = useFuz,
          cmspUseSemantic = useSem,
          cmspAnchoredItemIds = trimmedAnchoredItemIds,
          cmspSessionId = maybeSessionId,
          cmspCandidateLimit = min 80 candidateLimit
        }
  where
    dedupedAnchoredItemIds = List.nub anchoredItemIds
    trimmedAnchoredItemIds =
      case query.cortexMemoryQueryExplicitTargetItemId of
        Nothing -> take 8 dedupedAnchoredItemIds
        Just explicitTargetItemId ->
          explicitTargetItemId : take 8 (filter (/= explicitTargetItemId) dedupedAnchoredItemIds)

generateMemoryCandidates ::
  (Monad m) =>
  CortexMemoryHost m ->
  CortexMemorySearchPlan ->
  [CortexMemoryPassage] ->
  m [CortexMemoryCandidate]
generateMemoryCandidates host plan sessionPassages = do
  directAndAnchoredPassages <-
    if null plan.cmspAnchoredItemIds
      then pure []
      else cortexMemoryLoadItemPassages host plan.cmspAnchoredItemIds
  lexicalCandidates <-
    if plan.cmspUseLexical
      then cortexMemorySearchLexical host plan.cmspQuery lexicalLimit
      else pure []
  fuzzyCandidates <-
    if plan.cmspUseFuzzy
      then cortexMemorySearchFuzzy host plan.cmspQuery fuzzyLimit
      else pure []
  semanticCandidates <-
    if plan.cmspUseSemantic
      then cortexMemorySearchSemantic host plan.cmspQuery semanticLimit
      else pure []
  pure $
    mergeMemoryCandidates
      plan.cmspQuery
      ( sessionCandidates
          <> directAndAnchoredCandidates plan.cmspQuery directAndAnchoredPassages
          <> lexicalCandidates
          <> fuzzyCandidates
          <> semanticCandidates
      )
  where
    lexicalLimit = min 40 plan.cmspCandidateLimit
    fuzzyLimit = min 30 plan.cmspCandidateLimit
    semanticLimit = min 30 plan.cmspCandidateLimit
    sessionCandidates
      | cortexMemoryQueryIsBlank plan.cmspQuery = []
      | otherwise =
          fmap
            (annotateCandidate plan.cmspQuery . baseCandidate CortexMemoryRetrievedFromSessionLocal)
            (take 12 sessionPassages)

mergeMemoryCandidates :: CortexMemoryQuery -> [CortexMemoryCandidate] -> [CortexMemoryCandidate]
mergeMemoryCandidates query candidates =
  sortBy
    ( comparing (Down . cortexCandidateFusionScore)
        <> comparing (Down . (.cortexMemorySourceUpdatedAt) . cortexCandidatePassage)
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
        candidate.cortexCandidatePassage.cortexMemoryPassageId
        (sourceContribution query source rankIndex candidate)
        acc
    rankCandidatesForSource source =
      (\(rankIndex, candidate) -> (source, rankIndex, candidate))
        <$> zip
          [1 :: Int ..]
          ( sortBy
              (candidateOrderingForSource source)
              (filter (elem source . cortexCandidateSources) candidates)
          )
    reciprocalRank rankIndex = 1 / fromIntegral (60 + rankIndex)
    sourceContribution query' source rankIndex candidate =
      annotateCandidate
        query'
        candidate
          { cortexCandidateSources = [source],
            cortexCandidateFusionScore = sourceBias source + reciprocalRank rankIndex
          }

combineCandidates :: CortexMemoryCandidate -> CortexMemoryCandidate -> CortexMemoryCandidate
combineCandidates newer older =
  older
    { cortexCandidateLexicalScore = pickMax older.cortexCandidateLexicalScore newer.cortexCandidateLexicalScore,
      cortexCandidateFuzzyScore = pickMax older.cortexCandidateFuzzyScore newer.cortexCandidateFuzzyScore,
      cortexCandidateSemanticScore = pickMax older.cortexCandidateSemanticScore newer.cortexCandidateSemanticScore,
      cortexCandidateMatchedTerms = ordNub (older.cortexCandidateMatchedTerms <> newer.cortexCandidateMatchedTerms),
      cortexCandidateMatchedFields = ordNub (older.cortexCandidateMatchedFields <> newer.cortexCandidateMatchedFields),
      cortexCandidateSources = ordNub (older.cortexCandidateSources <> newer.cortexCandidateSources),
      cortexCandidateFusionScore = older.cortexCandidateFusionScore + newer.cortexCandidateFusionScore
    }
  where
    pickMax left right =
      case (left, right) of
        (Nothing, other) -> other
        (other, Nothing) -> other
        (Just x, Just y) -> Just (max x y)

candidateOrderingForSource ::
  CortexMemoryRetrievalSource ->
  CortexMemoryCandidate ->
  CortexMemoryCandidate ->
  Ordering
candidateOrderingForSource source =
  comparing (Down . candidateScoreForSource source)
    <> comparing (Down . (.cortexMemorySourceUpdatedAt) . cortexCandidatePassage)
    <> comparing (Down . (.cortexMemoryPassageOrder) . cortexCandidatePassage)

candidateScoreForSource :: CortexMemoryRetrievalSource -> CortexMemoryCandidate -> Double
candidateScoreForSource source candidate =
  case source of
    CortexMemoryRetrievedFromLexical -> fromMaybe 0 candidate.cortexCandidateLexicalScore
    CortexMemoryRetrievedFromFuzzy -> fromMaybe 0 candidate.cortexCandidateFuzzyScore
    CortexMemoryRetrievedFromSemantic -> fromMaybe 0 candidate.cortexCandidateSemanticScore
    CortexMemoryRetrievedFromSessionLocal -> sourceBias source
    CortexMemoryRetrievedFromDirectTarget -> sourceBias source
    CortexMemoryRetrievedFromAnchored -> sourceBias source

directAndAnchoredCandidates ::
  CortexMemoryQuery ->
  [CortexMemoryPassage] ->
  [CortexMemoryCandidate]
directAndAnchoredCandidates query passages =
  concatMap buildForItem grouped
  where
    explicitTargetItemId = query.cortexMemoryQueryExplicitTargetItemId
    grouped =
      Map.toList $
        Map.fromListWith
          (<>)
          [ (itemId, [passage])
          | passage <- passages,
            itemId <- maybeToList passage.cortexMemorySourceItemId
          ]
    buildForItem (itemId, itemPassages) =
      let sortedPassages = sortBy (comparing (.cortexMemoryPassageOrder)) itemPassages
          limitN
            | Just itemId == explicitTargetItemId = 12
            | otherwise = 4
          source
            | Just itemId == explicitTargetItemId = CortexMemoryRetrievedFromDirectTarget
            | otherwise = CortexMemoryRetrievedFromAnchored
       in fmap (annotateCandidate query . baseCandidate source) (take limitN sortedPassages)

baseCandidate :: CortexMemoryRetrievalSource -> CortexMemoryPassage -> CortexMemoryCandidate
baseCandidate source passage =
  CortexMemoryCandidate
    { cortexCandidatePassage = passage,
      cortexCandidateLexicalScore = Nothing,
      cortexCandidateFuzzyScore = Nothing,
      cortexCandidateSemanticScore = Nothing,
      cortexCandidateMatchedTerms = [],
      cortexCandidateMatchedFields = [],
      cortexCandidateSources = [source],
      cortexCandidateFusionScore = sourceBias source
    }

sourceBias :: CortexMemoryRetrievalSource -> Double
sourceBias = \case
  CortexMemoryRetrievedFromDirectTarget -> 1.0
  CortexMemoryRetrievedFromAnchored -> 0.45
  CortexMemoryRetrievedFromSessionLocal -> 0.3
  CortexMemoryRetrievedFromLexical -> 0.0
  CortexMemoryRetrievedFromFuzzy -> 0.0
  CortexMemoryRetrievedFromSemantic -> 0.0

annotateCandidate :: CortexMemoryQuery -> CortexMemoryCandidate -> CortexMemoryCandidate
annotateCandidate query candidate =
  candidate
    { cortexCandidateMatchedTerms = ordNub matchedTerms,
      cortexCandidateMatchedFields = ordNub matchedFields
    }
  where
    positiveTerms = cortexMemoryQueryPositiveTerms query
    titleHaystack = T.toLower candidate.cortexCandidatePassage.cortexMemorySourceTitle
    headingHaystack = T.toLower (fromMaybe "" candidate.cortexCandidatePassage.cortexMemorySectionHeading)
    bodyHaystack = T.toLower candidate.cortexCandidatePassage.cortexMemoryPassageText
    entitiesUpper = Set.fromList (fmap T.toUpper candidate.cortexCandidatePassage.cortexMemoryEntities)
    matchedTerms =
      [ term
      | term <- positiveTerms,
        termMatches term titleHaystack headingHaystack bodyHaystack entitiesUpper
      ]
    matchedFields =
      concatMap (fieldsForTerm titleHaystack headingHaystack bodyHaystack entitiesUpper) matchedTerms

fieldsForTerm ::
  Text ->
  Text ->
  Text ->
  Set.Set Text ->
  Text ->
  [CortexMemoryMatchedField]
fieldsForTerm titleHaystack headingHaystack bodyHaystack entitiesUpper term =
  ordNub $
    [ CortexMemoryMatchedTitle
    | term `T.isInfixOf` titleHaystack
    ]
      <> [ CortexMemoryMatchedHeading
         | term `T.isInfixOf` headingHaystack
         ]
      <> [ CortexMemoryMatchedBody
         | term `T.isInfixOf` bodyHaystack
         ]
      <> [ CortexMemoryMatchedEntity
         | Set.member (T.toUpper term) entitiesUpper
         ]

termMatches :: Text -> Text -> Text -> Text -> Set.Set Text -> Bool
termMatches term titleHaystack headingHaystack bodyHaystack entitiesUpper =
  term `T.isInfixOf` titleHaystack
    || term `T.isInfixOf` headingHaystack
    || term `T.isInfixOf` bodyHaystack
    || Set.member (T.toUpper term) entitiesUpper

ordNub :: (Ord a) => [a] -> [a]
ordNub = Set.toList . Set.fromList
