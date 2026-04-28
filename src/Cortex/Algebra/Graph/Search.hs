{-# LANGUAGE TypeFamilies #-}

{- | Generic graph search parameterised by frontier discipline.

DFS, BFS, min-priority, and max-priority search are all the same
algorithm — only the frontier determines which node is expanded next.
The 'Frontier' class captures this: any type that can accept nodes
and yield "the next one" is a valid frontier.

@fempty@ is deliberately absent: priority frontiers need a heuristic
at construction time, so emptiness is a construction concern, not a
class law.  'fextract' returning 'Nothing' already represents an
empty frontier.
-}
module Cortex.Algebra.Graph.Search
  ( -- * Frontier abstraction
    Frontier (..)

    -- * Concrete frontiers
  , Stack (..)
  , Queue (..)
  , MinFrontier (..)
  , MaxFrontier (..)

    -- * Smart constructors
  , minFrontier
  , maxFrontier

    -- * Generic search
  , search
  , searchWithDepth

    -- * Standard instantiations
  , dfs
  , bfs
  , pfs
  , pfsWithDepth

    -- * Reachability
  , reachable
  , reachableFrom
  )
where

import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set

import Cortex.Algebra.Graph.Core

-- ============================================================================
-- Frontier abstraction
-- ============================================================================

{- | A frontier is a configured container that defines which node to
expand next during graph search.

The associated type 'Elem' connects the frontier to the vertex type
of the graph being searched.

There is no @fempty@ method — priority frontiers require a heuristic
at construction time, so an empty frontier is built by the smart
constructor, not the class.  Emptiness is signalled by 'fextract'
returning 'Nothing'.
-}
class Frontier f where
  type Elem f
  finsert :: Elem f -> f -> f
  fextract :: f -> Maybe (Elem f, f)

-- ============================================================================
-- Concrete frontiers
-- ============================================================================

-- | LIFO frontier: depth-first search order.
newtype Stack a = Stack [a]

instance Frontier (Stack a) where
  type Elem (Stack a) = a
  finsert x (Stack xs) = Stack (x : xs)
  fextract (Stack []) = Nothing
  fextract (Stack (x : xs)) = Just (x, Stack xs)

-- | FIFO frontier: breadth-first search order.
newtype Queue a = Queue (Seq a)

instance Frontier (Queue a) where
  type Elem (Queue a) = a
  finsert x (Queue q) = Queue (q Seq.|> x)
  fextract (Queue q) = case Seq.viewl q of
    Seq.EmptyL -> Nothing
    x Seq.:< rest -> Just (x, Queue rest)

{- | Min-priority frontier: extract the vertex with the lowest priority.

The heuristic is stored inside the frontier value — this is why
@fempty@ cannot be a class method.
-}
data MinFrontier p a = MinFrontier (a -> p) (Set (p, a))

instance (Ord p, Ord a) => Frontier (MinFrontier p a) where
  type Elem (MinFrontier p a) = a
  finsert a (MinFrontier h s) = MinFrontier h (Set.insert (h a, a) s)
  fextract (MinFrontier h s) = case Set.minView s of
    Nothing -> Nothing
    Just ((_, a), s') -> Just (a, MinFrontier h s')

-- | Max-priority frontier: extract the vertex with the highest priority.
data MaxFrontier p a = MaxFrontier (a -> p) (Set (Down p, a))

instance (Ord p, Ord a) => Frontier (MaxFrontier p a) where
  type Elem (MaxFrontier p a) = a
  finsert a (MaxFrontier h s) = MaxFrontier h (Set.insert (Down (h a), a) s)
  fextract (MaxFrontier h s) = case Set.minView s of
    Nothing -> Nothing
    Just ((_, a), s') -> Just (a, MaxFrontier h s')

-- ============================================================================
-- Smart constructors
-- ============================================================================

-- | Empty min-priority frontier with the given heuristic.
minFrontier :: (a -> p) -> MinFrontier p a
minFrontier h = MinFrontier h Set.empty

-- | Empty max-priority frontier with the given heuristic.
maxFrontier :: (a -> p) -> MaxFrontier p a
maxFrontier h = MaxFrontier h Set.empty

-- ============================================================================
-- Generic search
-- ============================================================================

{- | Generic graph search parameterised by frontier discipline.

The frontier determines traversal order:

 * @'Stack' []@              → depth-first
 * @'Queue' Seq.empty@       → breadth-first
 * @'minFrontier' heuristic@ → min-priority-first
 * @'maxFrontier' heuristic@ → max-priority-first

Roots not in the graph are silently ignored.
-}
search :: (Ord a, Frontier f, Elem f ~ a) => f -> Relation a -> [a] -> [a]
search frontier0 rel roots' =
  let validRoots = filter (`Set.member` relVertices rel) roots'
      initial = foldl' (flip finsert) frontier0 validRoots
   in go Set.empty initial []
  where
    adj = relSucc rel
    go visited frontier acc =
      case fextract frontier of
        Nothing -> reverse acc
        Just (v, frontier')
          | Set.member v visited -> go visited frontier' acc
          | otherwise ->
              let visited' = Set.insert v visited
                  children = foldMap Set.toList (Map.lookup v adj)
                  frontier'' = foldl' (flip finsert) frontier' children
               in go visited' frontier'' (v : acc)

-- ============================================================================
-- Standard instantiations
-- ============================================================================

{- | Depth-first search.  LIFO frontier (stack).

Roots and children are explored in reverse insertion order due to the
LIFO discipline.  Roots not in the graph are silently ignored.
-}
dfs :: Ord a => Relation a -> [a] -> [a]
dfs = search (Stack [])

{- | Breadth-first search.  FIFO frontier (queue).
Roots not in the graph are silently ignored.
-}
bfs :: Ord a => Relation a -> [a] -> [a]
bfs = search (Queue Seq.empty)

{- | Priority-first search with a heuristic function.

Vertices are extracted in ascending order of @heuristic v@.  Lower
values are extracted first.

This is an unweighted priority traversal, not Dijkstra (which
requires re-prioritisation as distances improve).

Roots not in the graph are silently ignored.
-}
pfs :: (Ord a, Ord p) => (a -> p) -> Relation a -> [a] -> [a]
pfs h = search (minFrontier h)

-- ============================================================================
-- Hop-aware search
-- ============================================================================

{- | Generic hop-aware graph search, /lazy/.

Frontier elements are @(vertex, depth)@ pairs, where depth is the hop
distance from the nearest root (root itself is depth 0).  The visited
set tracks vertices alone, so a vertex is expanded at most once — at
the depth at which the chosen frontier discipline first yields it.

For BFS the first yield is the minimum hop distance.  For priority
frontiers it is whichever path the priority function selects first.

The result list is produced lazily.  'take k' on the output drives
only enough expansion to yield @k@ vertices — this is what gives
priority-first search its stop-at-k behaviour without an explicit
budget argument.

Roots not in the graph are silently ignored.
-}
searchWithDepth
  :: (Ord a, Frontier f, Elem f ~ (a, Int))
  => f
  -> Relation a
  -> [a]
  -> [(a, Int)]
searchWithDepth frontier0 rel roots' =
  let validRoots = filter (`Set.member` relVertices rel) roots'
      initial = foldl' (flip finsert) frontier0 (fmap (,0) validRoots)
   in go Set.empty initial
  where
    adj = relSucc rel
    go visited frontier =
      case fextract frontier of
        Nothing -> []
        Just ((v, d), frontier')
          | Set.member v visited -> go visited frontier'
          | otherwise ->
              let visited' = Set.insert v visited
                  children = fmap (,d + 1) (foldMap Set.toList (Map.lookup v adj))
                  frontier'' = foldl' (flip finsert) frontier' children
               in (v, d) : go visited' frontier''

{- | Priority-first search that reveals hop depth to the heuristic.

Vertices are expanded in ascending order of @h (vertex, depth)@.  Use
'Data.Ord.Down' on the priority to get descending order (highest
score first).

Roots not in the graph are silently ignored.  The result list is
lazy: combine with 'take' for stop-at-k behaviour.
-}
pfsWithDepth
  :: (Ord a, Ord p)
  => ((a, Int) -> p)
  -> Relation a
  -> [a]
  -> [(a, Int)]
pfsWithDepth h = searchWithDepth (minFrontier h)

-- ============================================================================
-- Reachability
-- ============================================================================

-- | All vertices reachable from a given root (inclusive).
reachable :: Ord a => Relation a -> a -> Set a
reachable rel root = reachableFrom rel [root]

{- | All vertices reachable from any of the given roots (inclusive).

Single multi-root traversal: each vertex is visited at most once
regardless of how many roots are provided.  O(|V| + |E|).
-}
reachableFrom :: Ord a => Relation a -> [a] -> Set a
reachableFrom rel roots = Set.fromList (dfs rel roots)
