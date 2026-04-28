{- |
Module      : Cortex.Pulse.Memory.Walk
Description : Walk combinators for graph-native topological memory.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Given a topology, an origin 'NodeId', a 'WalkDirection', a
'WalkScope', and the current node-status map, 'walkCandidates'
produces the set of nodes the origin is allowed to see, each paired
with its BFS hop-count from the origin.  The origin itself is
excluded — a stage reading memory does not observe its own output.

No IO, no scoring.  The scoring layer
('Cortex.Pulse.Memory.Score') consumes this output and attaches
composite scores.  Enumeration is BFS (hop-count order); the
graph-axis signal the score uses is random-walk influence computed
separately in 'Cortex.Pulse.Memory.Query'.  Ordering of candidates
at this stage is irrelevant — the final sort always runs over the
scored matches.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Memory.Walk
  ( walkCandidates
  , directionRelations
  , bfsDistance
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence ((|>))
import Data.Sequence qualified as Seq
import Data.Set qualified as Set

import Cortex.Algebra.Graph
  ( Relation
  , successors
  , transposeRelation
  )
import Cortex.Pulse.Memory.Types
  ( WalkDirection (..)
  , WalkScope (..)
  )
import Cortex.Pulse.Node (NodeId)
import Cortex.Pulse.Runtime (NodeStatus (..))

{- | Collect every node reachable from the origin in the requested
'WalkDirection', paired with its hop-count, then filter by scope.

The origin is never included.  Ordering of the returned list matches
BFS visitation order (ascending hop count, ties broken by the
underlying @Map.toAscList@ of successor sets — deterministic given
the 'Relation').
-}
walkCandidates
  :: Relation NodeId
  -> NodeId
  -> WalkDirection
  -> WalkScope
  -> Map NodeId NodeStatus
  -> [(NodeId, Int)]
walkCandidates topology origin direction scope statuses =
  let rels = directionRelations topology direction
      distances = mergeDistances [bfsDistance r origin | r <- rels]
      withoutOrigin = Map.delete origin distances
      filtered = Map.filterWithKey (\nid _ -> inScope scope (Map.lookup nid statuses)) withoutOrigin
   in Map.toAscList filtered

{- | BFS from the origin in the given relation.  Returns @Map NodeId Int@
where the value is the hop-count from origin.  The origin maps to 0.
Nodes unreachable from the origin are absent from the map.
-}
bfsDistance :: Relation NodeId -> NodeId -> Map NodeId Int
bfsDistance rel origin = go (Seq.singleton (origin, 0)) (Map.singleton origin 0)
  where
    go queue visited = case Seq.viewl queue of
      Seq.EmptyL -> visited
      (node, depth) Seq.:< rest ->
        let nextDepth = depth + 1
            children = Set.toAscList (successors rel node)
            (queue', visited') =
              foldr
                ( \child (q, v) ->
                    if Map.member child v
                      then (q, v)
                      else (q |> (child, nextDepth), Map.insert child nextDepth v)
                )
                (rest, visited)
                children
         in go queue' visited'

-- ============================================================================
-- Direction handling
-- ============================================================================

{- | Pick the relations we traverse for a given 'WalkDirection'.

'Ancestors' walks the transposed graph; 'Descendants' walks the
original; 'Bidirectional' returns both.  Consumers that walk
multiple relations must merge results per their own semantics —
'walkCandidates' merges hop maps with 'min'; the influence
computation in 'Cortex.Pulse.Memory.Query' merges influence maps
with 'max'.
-}
directionRelations :: Relation NodeId -> WalkDirection -> [Relation NodeId]
directionRelations topology = \case
  Ancestors -> [transposeRelation topology]
  Descendants -> [topology]
  Bidirectional -> [topology, transposeRelation topology]

{- | Merge hop-count maps by taking the minimum distance for nodes that
appear in more than one.  Preserves the shortest path when
'Bidirectional' walks find a node via both ancestor and descendant
routes.
-}
mergeDistances :: [Map NodeId Int] -> Map NodeId Int
mergeDistances = foldr (Map.unionWith min) Map.empty

-- ============================================================================
-- Scope filter
-- ============================================================================

{- | Decide whether a node's status falls inside the requested scope.
Absent statuses (node in the topology but not in the status map)
are treated as 'NodePending' — matching the default from
'initialGraphState'.
-}
inScope :: WalkScope -> Maybe NodeStatus -> Bool
inScope scope mStatus =
  let status = fromMaybe NodePending mStatus
   in case scope of
        SettledOnly -> isSettled status
        DebugAllStatuses -> True

{- | A node is /settled/ iff it has a terminal, reproducible outcome
the reviewer can read: completed, skipped (with reason), rewritten
(the anchor output was preserved on rewrite admission).  Running,
waiting, failed, and interrupted nodes are excluded — they are
live orchestration state, not memory.

The pattern match is deliberately exhaustive so a new
'NodeStatus' variant forces a compile-time decision here rather
than silently inheriting the default 'False'.
-}
isSettled :: NodeStatus -> Bool
isSettled = \case
  NodeCompleted -> True
  NodeSkipped -> True
  NodeRewritten -> True
  NodePending -> False
  NodeRunning -> False
  NodeWaiting _ -> False
  NodeFailed -> False
  NodeInterrupted _ -> False
