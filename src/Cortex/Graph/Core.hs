{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Algebraic graph DSL based on Mokhov 2017, "Algebraic Graphs with Class."
--
-- The graph is built using four constructors ('Empty', 'Vertex', 'Overlay',
-- 'Connect') and derived combinators ('path', 'edge', 'star', etc.), then
-- lowered to a concrete 'Relation' for runtime use.
--
-- Layer placement:
--
--   * 'Cortex.Graph' owns pure graph semantics and algorithms.
--   * 'Cortex.Pulse.*' owns durable execution, scheduling, and persistence.
--   * Portman domain workflows compile into these generic graph semantics,
--     but finance-specific meaning does not live here.
--
-- Key semantics from the paper:
--
--   * 'connect' creates ALL cross-edges (left × right), not one edge.
--   * @connect a (connect b c)@ is a clique (triangle), NOT a path.
--   * Paths are built with 'path' or 'edge': @edge a b <> edge b c@.
--   * Malformed graphs (dangling edges) are unrepresentable by construction.
--
-- The algebra operates on arbitrary @Ord a@ vertex types (typically typed
-- stage IDs). Impure payloads (IO stage actions) live in a separate map,
-- indexed by the same vertex type.
module Cortex.Graph.Core
  ( -- * Algebraic graph expression
    Graph (..),
    edge,
    path,
    vertices,
    star,
    clique,
    edges,

    -- * Graph catamorphism
    foldg,

    -- * Lowered relation
    Relation (..),
    toRelation,
    buildCachedRelation,
    transposeRelation,

    -- * Relation queries
    predecessors,
    successors,
    sources,
    sinks,
    adjacencyMap,
    reverseAdjacencyMap,
    checkCacheInvariant,

    -- * Relation transformations
    inducedSubgraph,
    relationDiff,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.Generics (Generic)

-- ============================================================================
-- Algebraic graph expression (Mokhov 2017)
-- ============================================================================

-- | Deep-embedded algebraic graph expression.
--
-- Used at plan-definition time to specify dependency topology. Lowered to
-- 'Relation' via 'toRelation' before runtime use.
--
-- Laws (from the paper):
--
--   * @overlay@ is commutative and associative with 'Empty' as identity
--   * @connect@ is associative with 'Empty' as identity
--   * @connect@ distributes over @overlay@
--   * Decomposition: @connect x (connect y z) = overlay (connect x y) (overlay (connect x z) (connect y z))@
--
-- Note: structural 'Eq' is intentionally NOT derived — different expressions
-- can denote the same graph. Compare via 'Relation' for semantic equality.
data Graph a
  = Empty
  | Vertex a
  | Overlay (Graph a) (Graph a)
  | Connect (Graph a) (Graph a)
  deriving stock (Show, Functor)

-- | @('<>') = 'Overlay'@ — union of two graphs.
instance Semigroup (Graph a) where
  (<>) = Overlay

-- | @'mempty' = 'Empty'@.
instance Monoid (Graph a) where
  mempty = Empty

-- ============================================================================
-- Derived combinators
-- ============================================================================

-- | Single directed edge: @a → b@.
edge :: a -> a -> Graph a
edge x y = Connect (Vertex x) (Vertex y)

-- | Directed path: @a → b → c@ (NOT a clique).
--
-- @path [a, b, c]@ = @edge a b <> edge b c@
--
-- This produces edges @{(a,b), (b,c)}@ — no transitive edge @(a,c)@.
path :: [a] -> Graph a
path [] = Empty
path [x] = Vertex x
path xs = mconcat [edge a b | (a, b) <- zip xs (drop 1 xs)]

-- | Set of isolated vertices (no edges).
vertices :: [a] -> Graph a
vertices = mconcat . fmap Vertex

-- | Star graph: one hub connected to all spokes (fan-out).
--
-- @star hub [a, b, c]@ produces edges @{(hub,a), (hub,b), (hub,c)}@.
star :: a -> [a] -> Graph a
star x ys = Connect (Vertex x) (vertices ys)

-- | Forward clique: all forward edges among an ordered sequence.
--
-- @clique [a, b, c]@ produces edges @{(a,b), (a,c), (b,c)}@.
--
-- This is the natural result of chained 'Connect' (the paper's decomposition law).
clique :: [a] -> Graph a
clique = foldr (Connect . Vertex) Empty

-- | Graph from an explicit edge list.
edges :: [(a, a)] -> Graph a
edges = mconcat . fmap (uncurry edge)

-- ============================================================================
-- Graph catamorphism
-- ============================================================================

-- | Catamorphism (structural fold) over a 'Graph' expression.
--
-- Eliminates a graph by replacing each constructor with a function:
--
-- @
-- foldg e v o c (Overlay (Vertex 1) (Connect (Vertex 2) (Vertex 3)))
--   = o (v 1) (c (v 2) (v 3))
-- @
--
-- This is the universal eliminator — 'toRelation', vertex extraction,
-- pretty-printing, and normalization are all instances of 'foldg'.
foldg :: r -> (a -> r) -> (r -> r -> r) -> (r -> r -> r) -> Graph a -> r
foldg e v o c = go
  where
    go Empty = e
    go (Vertex x) = v x
    go (Overlay x y) = o (go x) (go y)
    go (Connect x y) = c (go x) (go y)

-- ============================================================================
-- Lowered relation (concrete vertex set + edge set)
-- ============================================================================

-- | Concrete graph representation with cached adjacency maps.
--
-- This is the denotational semantics of 'Graph' — the runtime representation
-- consumed by the executor for frontier computation and dependency resolution.
-- Adjacency maps are computed once at lowering time; 'predecessors' and
-- 'successors' are O(log n) lookups, not rebuilds.
data Relation a = Relation
  { relVertices :: !(Set a),
    relEdges :: !(Set (a, a)),
    -- | Cached forward adjacency: vertex → successors.
    relSucc :: !(Map a (Set a)),
    -- | Cached reverse adjacency: vertex → predecessors.
    relPred :: !(Map a (Set a))
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @('<>') = overlayRelations@ — union of two relations (disjoint or overlapping).
instance (Ord a) => Semigroup (Relation a) where
  (<>) = overlayRelations

-- | @'mempty'@ — empty relation (no vertices, no edges).
instance (Ord a) => Monoid (Relation a) where
  mempty =
    Relation
      { relVertices = Set.empty,
        relEdges = Set.empty,
        relSucc = Map.empty,
        relPred = Map.empty
      }

-- | Lower a graph expression to a concrete relation with cached adjacency.
--
-- Implemented as a 'foldg' that maintains adjacency caches incrementally.
toRelation :: (Ord a) => Graph a -> Relation a
toRelation = foldg mempty (\v -> mempty {relVertices = Set.singleton v}) overlayRelations connectRelations

-- | @overlay@: union of vertices and edges.
overlayRelations :: (Ord a) => Relation a -> Relation a -> Relation a
overlayRelations r1 r2 =
  Relation
    { relVertices = relVertices r1 <> relVertices r2,
      relEdges = relEdges r1 <> relEdges r2,
      relSucc = Map.unionWith Set.union (relSucc r1) (relSucc r2),
      relPred = Map.unionWith Set.union (relPred r1) (relPred r2)
    }

-- | @connect@: union of vertices and edges, plus ALL cross-edges.
--
-- Adjacency caches are updated by batch-inserting entire vertex sets per
-- source/target vertex, avoiding per-edge singleton union overhead.
connectRelations :: (Ord a) => Relation a -> Relation a -> Relation a
connectRelations r1 r2 =
  let vs1 = relVertices r1
      vs2 = relVertices r2
      crossEdges = Set.fromList [(v1, v2) | v1 <- Set.toList vs1, v2 <- Set.toList vs2]
      rel' = overlayRelations r1 r2
      -- Batch: each v1 gains all of vs2 as successors (one Set.union per source vertex).
      -- Guard: skip when the opposite side is empty to avoid inserting empty-set tombstones.
      succMap
        | Set.null vs2 = relSucc rel'
        | otherwise = foldl' (\m v1 -> Map.insertWith Set.union v1 vs2 m) (relSucc rel') (Set.toList vs1)
      predMap
        | Set.null vs1 = relPred rel'
        | otherwise = foldl' (\m v2 -> Map.insertWith Set.union v2 vs1 m) (relPred rel') (Set.toList vs2)
   in rel' {relEdges = relEdges rel' <> crossEdges, relSucc = succMap, relPred = predMap}

-- | Build a relation with cached adjacency from raw vertex/edge sets.
--
-- Builds both adjacency maps in a single pass over the edge set.
buildCachedRelation :: (Ord a) => Set a -> Set (a, a) -> Relation a
buildCachedRelation vs es =
  let (succMap, predMap) =
        foldl'
          ( \(s, p) (from, to) ->
              ( Map.insertWith Set.union from (Set.singleton to) s,
                Map.insertWith Set.union to (Set.singleton from) p
              )
          )
          (Map.empty, Map.empty)
          (Set.toList es)
   in Relation vs es succMap predMap

-- | Transpose (reverse) a relation: swap forward and reverse adjacency.
--
-- All edges @(u, v)@ become @(v, u)@. Vertex set is preserved.
transposeRelation :: (Ord a) => Relation a -> Relation a
transposeRelation rel =
  Relation
    { relVertices = rel.relVertices,
      relEdges = Set.map (\(a, b) -> (b, a)) rel.relEdges,
      relSucc = rel.relPred,
      relPred = rel.relSucc
    }

-- ============================================================================
-- Relation queries
-- ============================================================================

-- | Direct predecessors of a vertex (nodes with edges TO this vertex).
-- O(log n) — uses cached reverse adjacency.
predecessors :: (Ord a) => Relation a -> a -> Set a
predecessors rel x = Map.findWithDefault Set.empty x (relPred rel)

-- | Direct successors of a vertex (nodes with edges FROM this vertex).
-- O(log n) — uses cached forward adjacency.
successors :: (Ord a) => Relation a -> a -> Set a
successors rel x = Map.findWithDefault Set.empty x (relSucc rel)

-- | Verify that the cached adjacency maps are consistent with the edge set.
-- Used for validation of incremental graph mutations.
checkCacheInvariant :: (Ord a) => Relation a -> Bool
checkCacheInvariant rel =
  let (expectedSucc, expectedPred) =
        foldl'
          (\(s, p) (u, v) -> (Map.insertWith Set.union u (Set.singleton v) s, Map.insertWith Set.union v (Set.singleton u) p))
          (Map.empty, Map.empty)
          (Set.toList (relEdges rel))
   in relSucc rel == expectedSucc && relPred rel == expectedPred

-- | Forward adjacency map: vertex → set of successors.
-- Cheap projection of the cached field.
adjacencyMap :: Relation a -> Map a (Set a)
adjacencyMap = relSucc

-- | Reverse adjacency map: vertex → set of predecessors.
-- Cheap projection of the cached field.
reverseAdjacencyMap :: Relation a -> Map a (Set a)
reverseAdjacencyMap = relPred

-- | Source vertices: in-degree 0 (no predecessors).
sources :: (Ord a) => Relation a -> Set a
sources rel = Set.filter (Set.null . predecessors rel) (relVertices rel)

-- | Sink vertices: out-degree 0 (no successors).
sinks :: (Ord a) => Relation a -> Set a
sinks rel = Set.filter (Set.null . successors rel) (relVertices rel)

-- ============================================================================
-- Relation transformations
-- ============================================================================

-- | Induced subgraph: keep only the given vertices and edges between them.
inducedSubgraph :: (Ord a) => Set a -> Relation a -> Relation a
inducedSubgraph keep rel =
  let vs' = Set.intersection keep (relVertices rel)
      es' = Set.filter (\(u, v) -> Set.member u vs' && Set.member v vs') (relEdges rel)
   in buildCachedRelation vs' es'

-- | Compute the difference between two relations.
--
-- Returns @(addedVertices, removedVertices, addedEdges, removedEdges)@.
relationDiff ::
  (Ord a) =>
  Relation a ->
  -- | old
  Relation a ->
  -- | new
  (Set a, Set a, Set (a, a), Set (a, a))
relationDiff old new =
  ( Set.difference (relVertices new) (relVertices old),
    Set.difference (relVertices old) (relVertices new),
    Set.difference (relEdges new) (relEdges old),
    Set.difference (relEdges old) (relEdges new)
  )
