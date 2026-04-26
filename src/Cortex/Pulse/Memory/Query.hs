{-# LANGUAGE OverloadedRecordDot #-}

-- | Pure query engine for the graph-native topological memory
-- (DIG-529).
--
-- Given an origin 'NodeId' (the caller's @scNodeId@), a
-- 'MemorySnapshot' frozen at stage entry, a 'WalkSpec', and a 'Query',
-- 'pureQueryMemory' produces an ordered list of 'MatchedObservation'
-- values.  Deterministic — same inputs always yield the same output.
-- No IO.
--
-- The IO wrapper lives in 'Cortex.Pulse.Memory' where
-- 'newMemoryHandle' binds this function to a TVar-backed snapshot.
module Cortex.Pulse.Memory.Query
  ( pureQueryMemory,
  )
where

import Cortex.Graph (Relation, dagRandomWalkInfluence)
import Cortex.Pulse.GraphRuntime (NodeStatus (..))
import Cortex.Pulse.Memory.Score (composeScore)
import Cortex.Pulse.Memory.Types
  ( ExtractedFields (..),
    MatchedObservation (..),
    MemorySnapshot (..),
    Query (..),
    ScoreWeights (..),
    WalkDirection,
    WalkSpec (..),
  )
import Cortex.Pulse.Memory.Walk (directionRelations, walkCandidates)
import Cortex.Pulse.Node (NodeId)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Time (diffUTCTime)

-- | Standard PageRank-style damping factor used for the DAG
-- random-walk influence computation.  Hardcoded for now; expose on
-- 'ScoreWeights' if a future caller needs to tune it per stage.
influenceDamping :: Double
influenceDamping = 0.85

-- | Run a query from the given origin against a snapshot.  Pure and
-- deterministic.
--
-- Pipeline:
--
--   1. BFS-enumerate in-scope reachable candidates (hop-count carried
--      for the 'swMaxGraphDistance' pre-filter and the display field).
--   2. Compute DAG random-walk influence of @origin@ on every reachable
--      node via 'dagRandomWalkInfluence'.  For 'Bidirectional' the
--      ancestor and descendant influence maps are merged with 'max'.
--   3. Apply the hard 'swMaxGraphDistance' cutoff on hop count.
--   4. Score each survivor via 'composeScore' using the influence
--      value as the graph axis.
--   5. Sort by @(score DESC, graphDistance ASC, NodeId ASC)@.
--   6. Apply 'wsLimit' after the sort.
pureQueryMemory :: NodeId -> MemorySnapshot -> WalkSpec -> Query -> [MatchedObservation]
pureQueryMemory origin snap walkSpec query =
  let candidates =
        walkCandidates
          snap.msTopology
          origin
          walkSpec.wsDirection
          walkSpec.wsScope
          snap.msNodeStatuses
      influence = computeInfluenceMap snap.msTopology origin walkSpec.wsDirection
      withinBudget = applyMaxDistance walkSpec.wsWeights.swMaxGraphDistance candidates
      matched = concatMap (toMatch snap walkSpec query influence) withinBudget
      sorted = sortMatches matched
   in applyLimit walkSpec.wsLimit sorted

-- | Compute the DAG random-walk influence map for the requested
-- direction.  'Ancestors' uses the transposed topology so mass flows
-- from the origin back through predecessors; 'Descendants' uses the
-- topology as-is; 'Bidirectional' merges per-direction maps with
-- 'max' — mirroring the "best signal via either direction" shape
-- that 'walkCandidates' takes for hop distance with 'min'.
computeInfluenceMap ::
  Relation NodeId ->
  NodeId ->
  WalkDirection ->
  Map NodeId Double
computeInfluenceMap topology origin direction =
  let rels = directionRelations topology direction
      perRel = dagRandomWalkInfluence influenceDamping origin
   in foldr (Map.unionWith max . perRel) Map.empty rels

-- | Project a walked candidate into a 'MatchedObservation'.  Drops
-- candidates whose output is missing or whose routing key doesn't
-- match the query filter.
toMatch ::
  MemorySnapshot ->
  WalkSpec ->
  Query ->
  Map NodeId Double ->
  (NodeId, Int) ->
  [MatchedObservation]
toMatch snap walkSpec query influence (nid, hops) = case Map.lookup nid snap.msNodeOutputs of
  Nothing -> []
  Just output ->
    let extracted = query.qExtractor output
     in if routingKeyOk query.qRoutingKey extracted
          then
            let status = fromMaybe NodePending (Map.lookup nid snap.msNodeStatuses)
                completedAt = Map.lookup nid snap.msNodeCompletedAt
                temporalDelta = fmap (diffUTCTime snap.msCapturedAt) completedAt
                bodyText = maybe "" efBodyText extracted
                influenceScore = fromMaybe 0 (Map.lookup nid influence)
                score =
                  composeScore
                    walkSpec.wsWeights
                    influenceScore
                    snap.msCapturedAt
                    completedAt
                    query.qSemanticScorer
                    query.qSemanticText
                    bodyText
             in [ MatchedObservation
                    { moNodeId = nid,
                      moStatus = status,
                      moOutput = output,
                      moExtracted = extracted,
                      moScore = score,
                      moGraphDistance = hops,
                      moTemporalDelta = temporalDelta,
                      moObservedAt = completedAt
                    }
                ]
          else []

-- ============================================================================
-- Pipeline stages
-- ============================================================================

applyMaxDistance :: Maybe Int -> [(NodeId, Int)] -> [(NodeId, Int)]
applyMaxDistance Nothing = id
applyMaxDistance (Just maxHops) = filter (\(_, hops) -> hops <= maxHops)

routingKeyOk :: Maybe Text -> Maybe ExtractedFields -> Bool
routingKeyOk Nothing _ = True
routingKeyOk (Just wantedKey) mExtracted = case mExtracted of
  Nothing -> False
  Just ef -> efRoutingKey ef == Just wantedKey

sortMatches :: [MatchedObservation] -> [MatchedObservation]
sortMatches =
  sortOn
    ( \m ->
        ( Down m.moScore,
          m.moGraphDistance,
          m.moNodeId
        )
    )

applyLimit :: Maybe Int -> [a] -> [a]
applyLimit Nothing = id
applyLimit (Just n) = take n
