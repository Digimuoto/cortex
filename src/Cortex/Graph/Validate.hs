-- | DAG validation and cycle detection for graph plans.
module Cortex.Graph.Validate
  ( ValidationError (..),
    analyzeDAG,
    validateDAG,
  )
where

import Cortex.Graph.Core
import Cortex.Graph.Decompose (topSort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

-- | Errors from graph plan validation.
data ValidationError a
  = -- | The graph contains a cycle. The list is the cycle path
    -- (last element connects back to first).
    GraphHasCycle [a]
  deriving stock (Eq, Show)

-- | Validate that a lowered relation is a DAG and return its topological
-- order.
--
-- Returns @Right topoOrder@ for acyclic graphs, @Left (GraphHasCycle path)@
-- for cyclic ones. On cyclic graphs, two traversals occur: 'topSort' detects
-- the cycle, then 'findCycle' extracts the witness path.
analyzeDAG :: (Ord a) => Relation a -> Either (ValidationError a) [a]
analyzeDAG rel =
  case topSort rel of
    Just order -> Right order
    Nothing -> Left (GraphHasCycle (findCycle rel))

-- | Validate that a lowered relation is a DAG (no cycles).
-- Convenience wrapper around 'analyzeDAG' that discards the topological order.
validateDAG :: (Ord a) => Relation a -> Either (ValidationError a) ()
validateDAG rel = case analyzeDAG rel of
  Right _ -> Right ()
  Left err -> Left err

-- | Find a cycle in the graph via DFS with explicit path tracking.
-- Returns the cycle as a clean forward path @[a, b, ..., a]@ where the
-- last element connects back to the first.
--
-- Threads a global visited set to avoid revisiting explored subtrees.
-- Maintains the recursion stack in root-to-current order for clean extraction.
--
-- Precondition: the graph contains at least one cycle.
findCycle :: (Ord a) => Relation a -> [a]
findCycle rel = go Set.empty (Set.toList (relVertices rel))
  where
    adj = relSucc rel

    go _ [] = [] -- should not happen if precondition holds
    go globalVisited (v : rest)
      | Set.member v globalVisited = go globalVisited rest
      | otherwise =
          case dfsWithPath v Set.empty [] globalVisited of
            (_, Just cycle') -> cycle'
            (globalVisited', Nothing) -> go globalVisited' rest

    -- Returns (updatedGlobalVisited, maybeCycle).
    -- @stack@: recursion stack Set (O(log n) membership).
    -- @revPath@: recursion path in reverse (current-to-root, cons accumulation).
    dfsWithPath v stack revPath globalVisited
      | Set.member v stack =
          -- Cycle found: reverse the path, slice from v, close with v.
          let fwdPath = reverse revPath
              cyclePath = dropWhile (/= v) fwdPath <> [v]
           in (globalVisited, Just cyclePath)
      | Set.member v globalVisited =
          (globalVisited, Nothing)
      | otherwise =
          let stack' = Set.insert v stack
              revPath' = v : revPath -- O(1) cons, not O(n) append
              children = foldMap Set.toList (Map.lookup v adj)
              (globalVisited', result) = tryChildren children stack' revPath' globalVisited
           in (Set.insert v globalVisited', result)

    tryChildren [] _ _ globalVisited = (globalVisited, Nothing)
    tryChildren (c : rest) stack stackPath globalVisited =
      case dfsWithPath c stack stackPath globalVisited of
        (gv, Just cycle') -> (gv, Just cycle')
        (gv, Nothing) -> tryChildren rest stack stackPath gv
