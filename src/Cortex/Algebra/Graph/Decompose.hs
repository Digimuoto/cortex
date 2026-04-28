{-# LANGUAGE TypeFamilies #-}

-- | Structural decomposition of graphs: topological sorting, DAG folds,
-- and strongly connected components.
module Cortex.Algebra.Graph.Decompose
  ( -- * Topological sort
    topSortWith,
    topSort,
    topSortBy,

    -- * DAG folds
    foldTopSortWith,
    foldTopSort,
    dagDepth,

    -- * Strongly connected components
    scc,
  )
where

import Cortex.Algebra.Graph.Core
import Cortex.Algebra.Graph.Search (Frontier (..), Queue (..), minFrontier)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

-- ============================================================================
-- Topological sort
-- ============================================================================

-- | Topological sort parameterised by frontier discipline.
--
-- The frontier determines which ready node (in-degree 0) is emitted
-- next when multiple are available.  This is the tie-breaking policy:
--
--   * @'Queue' Seq.empty@       → BFS topological order (default)
--   * @'minFrontier' heuristic@ → priority topological sort (a scheduler)
--   * @'maxFrontier' heuristic@ → reverse-priority topological sort
--
-- Returns 'Nothing' if the graph contains a cycle.
topSortWith :: (Ord a, Frontier f, Elem f ~ a) => f -> Relation a -> Maybe [a]
topSortWith frontier0 rel = fst <$> foldTopSortWith frontier0 (const (const ())) rel

-- | Topological sort of a DAG.  Returns 'Nothing' if the graph contains
-- a cycle.
--
-- Uses Kahn's algorithm with a FIFO frontier (BFS topological order).
topSort :: (Ord a) => Relation a -> Maybe [a]
topSort = topSortWith (Queue mempty)

-- | Priority topological sort: emit the lowest-priority ready node first.
--
-- When multiple nodes have in-degree 0, the one with the smallest
-- @heuristic@ value is emitted.  This is a DAG scheduler.
topSortBy :: (Ord a, Ord p) => (a -> p) -> Relation a -> Maybe [a]
topSortBy h = topSortWith (minFrontier h)

-- ============================================================================
-- DAG folds
-- ============================================================================

-- | Fold over a DAG in topological order, parameterised by frontier.
--
-- At each vertex, the step function receives:
--
--   1. The vertex
--   2. A map from its predecessors to their already-computed values
--
-- The frontier determines tie-breaking when multiple vertices are
-- ready simultaneously (same as 'topSortWith').
--
-- Returns the topological order paired with the per-vertex result map,
-- or 'Nothing' if the graph contains a cycle.
--
-- To fold in reverse (sinks first, seeing successor values), pass
-- @'transposeRelation' rel@ — predecessors in the transposed graph
-- are successors in the original.
--
-- @
-- -- Longest path from sources (sinks first, seeing successor values):
-- foldTopSort (\\_ succVals -> 1 + maximum (0 : Map.elems succVals))
--             (transposeRelation rel)
-- @
foldTopSortWith ::
  (Ord a, Frontier f, Elem f ~ a) =>
  f ->
  (a -> Map a b -> b) ->
  Relation a ->
  Maybe ([a], Map a b)
foldTopSortWith frontier0 step rel = go initial inDegMap 0 [] Map.empty
  where
    vs = relVertices rel
    adj = relSucc rel
    predAdj = relPred rel
    totalVertices = Set.size vs
    -- Compute in-degree for each vertex
    inDegMap0 = Map.fromSet (const (0 :: Int)) vs
    inDegMap = foldl' (\m (_, to) -> Map.adjust (+ 1) to m) inDegMap0 (Set.toList (relEdges rel))
    inDeg0 = [v | (v, d) <- Map.toList inDegMap, d == 0]
    initial = foldl' (flip finsert) frontier0 inDeg0

    go frontier remaining !emitted acc results =
      case fextract frontier of
        Nothing ->
          if emitted == totalVertices
            then Just (reverse acc, results)
            else Nothing -- cycle
        Just (v, frontier') ->
          let -- Gather predecessor values for the step function.
              preds = Map.findWithDefault Set.empty v predAdj
              predValues = Map.fromSet (results Map.!) preds
              val = step v predValues
              results' = Map.insert v val results
              children = foldMap Set.toList (Map.lookup v adj)
              (remaining', newReady) = foldl' decrement (remaining, []) children
              decrement (m, zs) c =
                let old = Map.findWithDefault 0 c m
                    m' = Map.insert c (old - 1) m
                 in (m', if old == 1 then c : zs else zs)
              frontier'' = foldl' (flip finsert) frontier' newReady
           in go frontier'' remaining' (emitted + 1) (v : acc) results'

-- | Fold over a DAG in topological order (FIFO frontier).
--
-- At each vertex, the step function receives the vertex and a map from
-- its predecessors to their already-computed values.
--
-- @
-- -- Compute depth of each vertex (distance from sources):
-- foldTopSort (\\_ predVals -> 1 + maximum (0 : Map.elems predVals)) rel
-- @
foldTopSort ::
  (Ord a) =>
  (a -> Map a b -> b) ->
  Relation a ->
  Maybe ([a], Map a b)
foldTopSort = foldTopSortWith (Queue mempty)

-- | Depth of each vertex: longest path from any source.
--
-- Source vertices (in-degree 0) have depth 1.  Returns 'Nothing' if the
-- graph contains a cycle.
dagDepth :: (Ord a) => Relation a -> Maybe (Map a Int)
dagDepth rel = snd <$> foldTopSort step rel
  where
    step _ predVals
      | Map.null predVals = 1
      | otherwise = 1 + maximum (Map.elems predVals)

-- ============================================================================
-- Strongly connected components
-- ============================================================================

-- | Strongly connected components via Kosaraju's algorithm.
-- Returns SCCs in reverse topological order (sinks first).
scc :: (Ord a) => Relation a -> [[a]]
scc rel =
  let -- Phase 1: DFS on forward graph, producing vertices in decreasing
      -- finish-time order (postorderAll prepends: parent before children).
      finishOrder = postorderAll (relSucc rel) (Set.toList (relVertices rel))
      -- Phase 2: DFS on reverse graph in decreasing finish-time order.
      -- Do NOT reverse — postorderAll already returns the correct order.
      revAdj = relPred rel
   in collectSCCs revAdj finishOrder

-- | DFS-derived ordering in decreasing finish-time order.
-- Vertices are prepended after their descendants (@v : acc@), so the root
-- of each DFS tree appears before its children. Used directly as the
-- phase-2 iteration order in Kosaraju's SCC algorithm.
postorderAll :: (Ord a) => Map a (Set a) -> [a] -> [a]
postorderAll adj vs = snd (foldl' visit (Set.empty, []) vs)
  where
    visit (visited, acc) v
      | Set.member v visited = (visited, acc)
      | otherwise = postorderDFS visited v acc

    postorderDFS visited v acc
      | Set.member v visited = (visited, acc)
      | otherwise =
          let visited' = Set.insert v visited
              children = foldMap Set.toList (Map.lookup v adj)
              (visited'', acc') = foldl' (\(vis, a) c -> postorderDFS vis c a) (visited', acc) children
           in (visited'', v : acc')

-- | Collect SCCs by DFS on reverse graph (Kosaraju phase 2).
collectSCCs :: (Ord a) => Map a (Set a) -> [a] -> [[a]]
collectSCCs revAdj order = snd (foldl' collect (Set.empty, []) order)
  where
    collect (visited, sccs) v
      | Set.member v visited = (visited, sccs)
      | otherwise =
          let (visited', component) = collectComponent revAdj visited v []
           in (visited', component : sccs)

    -- Accumulate via cons (O(1) per step), no quadratic append.
    collectComponent adjMap visited v acc
      | Set.member v visited = (visited, acc)
      | otherwise =
          let visited' = Set.insert v visited
              children = foldMap Set.toList (Map.lookup v adjMap)
           in foldl' (\(vis, a) c -> collectComponent adjMap vis c a) (visited', v : acc) children
