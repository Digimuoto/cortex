-- | DAG influence scoring via single-pass random-walk mass propagation.
--
-- Given a DAG, an origin vertex, and a damping factor @α ∈ (0, 1)@,
-- 'dagRandomWalkInfluence' assigns every reachable vertex a scalar
-- "share of a random walk starting at the origin" — the DAG analogue
-- of personalized PageRank without the iterative fixed point.
--
-- The walker starts at @origin@ with mass @1@.  At each step it
-- distributes a fraction @α@ of its current mass uniformly across
-- outgoing edges; the remaining @1 - α@ "stops" at the current
-- vertex.  Because the graph is a DAG, one topological pass computes
-- the exact stationary distribution — no convergence loop, no @ε@.
--
-- __Interpretation by direction.__  To query upstream ancestors from
-- a reviewer node, call the function with the /transposed/ topology:
-- successors-in-transpose are actual predecessors in the original, so
-- mass flows from the reviewer back through its causal cone.  For
-- downstream (descendant) queries use the topology as-is.  For
-- bidirectional queries run the function twice and merge the maps
-- with 'Data.Map.Strict.unionWith' 'max' — matches the BFS
-- implementation's per-direction union.
--
-- __Why this beats @1 \/ (1 + hops)@.__  Hop count treats a node
-- reached via many short paths identically to one reached via a
-- single chain.  Influence propagation naturally rewards merges:
-- if two predecessors of @v@ both carry mass, @v@ accumulates from
-- both, so its score grows with its aggregate causal support.  See
-- the @merge vs chain@ test for the concrete invariant.
module Cortex.Algebra.Graph.Influence
  ( dagRandomWalkInfluence,
  )
where

import Cortex.Algebra.Graph.Core (Relation, relSucc, relVertices)
import Cortex.Algebra.Graph.Decompose (foldTopSort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

-- | Compute the random-walk influence of @origin@ on every vertex in
-- the DAG under damping factor @α@.
--
-- * @origin@ receives mass @1@.
-- * Every other reachable vertex @v@ receives
--   @sum over predecessors u of (α * mass[u] / outDeg(u))@.
-- * Vertices unreachable from @origin@ receive mass @0@.
-- * Dangling vertices (out-degree 0) absorb their incoming mass —
--   it does not propagate further.
--
-- Returns an empty map if the graph contains a cycle.  Origin is
-- included in the result with its own mass; callers that want
-- "influence on /other/ vertices" should 'Map.delete' origin.
--
-- __Complexity.__  One topological sort plus one linear pass over
-- edges: O(|V| + |E|).  No convergence loop, no @ε@.
dagRandomWalkInfluence ::
  (Ord a) =>
  -- | damping factor @α ∈ (0, 1)@.  Standard PageRank uses @0.85@.
  Double ->
  -- | origin vertex (receives mass @1@).
  a ->
  -- | DAG.  Behaviour on cyclic input: returns 'Map.empty'.
  Relation a ->
  Map a Double
dagRandomWalkInfluence alpha origin rel =
  let outDeg v = Set.size (Map.findWithDefault Set.empty v (relSucc rel))
      step v predVals
        | v == origin = 1
        | otherwise =
            sum
              [ let deg = outDeg u
                 in if deg == 0 then 0 else alpha * uMass / fromIntegral deg
              | (u, uMass) <- Map.toList predVals
              ]
   in -- 'foldTopSort' walks every vertex; non-reachable ones get 0
      -- because their predecessor chain never touches the origin.
      case foldTopSort step rel of
        Nothing -> Map.empty
        Just (_, results) ->
          if Set.member origin (relVertices rel)
            then results
            else Map.empty
