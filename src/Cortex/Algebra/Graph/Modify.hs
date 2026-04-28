{- | Mutation operations on lowered 'Relation' values.

All operations are pure functional updates that preserve the cached
adjacency invariant.
-}
module Cortex.Algebra.Graph.Modify
  ( addEdge
  , removeEdge
  , removeVertex
  , mapRelation
  )
where

import Data.Bifunctor (bimap)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

import Cortex.Algebra.Graph.Core

-- | Add a directed edge: @u → v@.
addEdge :: Ord a => a -> a -> Relation a -> Relation a
addEdge u v rel =
  rel
    { relVertices = Set.insert u (Set.insert v (relVertices rel))
    , relEdges = Set.insert (u, v) (relEdges rel)
    , relSucc = Map.insertWith Set.union u (Set.singleton v) (relSucc rel)
    , relPred = Map.insertWith Set.union v (Set.singleton u) (relPred rel)
    }

-- | Remove a directed edge: @u → v@.
removeEdge :: Ord a => a -> a -> Relation a -> Relation a
removeEdge u v rel =
  rel
    { relEdges = Set.delete (u, v) (relEdges rel)
    , relSucc = pruneAdj u v (relSucc rel)
    , relPred = pruneAdj v u (relPred rel)
    }

{- | Remove a vertex and all its incident edges.

Uses 'Set.difference' against the known incident edges rather than
scanning the entire edge set.
-}
removeVertex :: Ord a => a -> Relation a -> Relation a
removeVertex v rel =
  let preds = predecessors rel v
      succs = successors rel v
      incident = Set.map (,v) preds <> Set.map (v,) succs
      edges' = Set.difference (relEdges rel) incident
      rel' =
        rel
          { relVertices = Set.delete v (relVertices rel)
          , relEdges = edges'
          , relSucc = Map.delete v (relSucc rel)
          , relPred = Map.delete v (relPred rel)
          }
      -- Clean up references in successor/predecessor sets of neighbors.
      rel'' = Set.foldl' (\r p -> r {relSucc = pruneAdj p v (relSucc r)}) rel' preds
      rel''' = Set.foldl' (\r s -> r {relPred = pruneAdj s v (relPred r)}) rel'' succs
   in rel'''

{- | Map a function over all vertices in a relation.

__Warning:__ if @f@ is not injective, distinct vertices collapse (quotient).
This is mathematically correct but may silently merge nodes at runtime.
Ensure @f@ is injective for execution-plan use.
-}
mapRelation :: Ord b => (a -> b) -> Relation a -> Relation b
mapRelation f rel =
  let vs' = Set.map f (relVertices rel)
      es' = Set.map (bimap f f) (relEdges rel)
   in buildCachedRelation vs' es'

{- | Remove @val@ from the set at @key@; delete the key entirely if the set
becomes empty. Keeps adjacency maps free of empty-set tombstones.
-}
pruneAdj :: (Ord k, Ord a) => k -> a -> Map k (Set a) -> Map k (Set a)
pruneAdj key val = Map.update (\s -> let s' = Set.delete val s in if Set.null s' then Nothing else Just s') key
