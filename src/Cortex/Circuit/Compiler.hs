{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Circuit.Compiler
  ( CircuitCompileError (..),
    compileCircuitIR,
  )
where

import Control.Monad ((>=>))
import Cortex.Circuit.Artifact
  ( CircuitCompatibilityWitness (..),
    CircuitConditionNode (..),
    CompiledCircuit (..),
    CompiledCircuitFragment (..),
    CompiledCircuitNode (..),
    compiledCircuitNodeRef,
  )
import Cortex.Circuit.IR
  ( CircuitExpr (..),
    CircuitIR (..),
    CircuitNodeRef (..),
  )
import Cortex.Graph
  ( Relation,
    ValidationError,
    edges,
    toRelation,
    validateDAG,
    vertices,
  )
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as BSL
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

data CircuitCompileError
  = CircuitDuplicateNodeRef CircuitNodeRef
  | CircuitInvalidTopology (ValidationError CircuitNodeRef)
  deriving stock (Eq, Show)

data CircuitFragment = CircuitFragment
  { circuitFragmentRoots :: [CircuitNodeRef],
    circuitFragmentExits :: [CircuitNodeRef],
    circuitFragmentNodes :: Map CircuitNodeRef CompiledCircuitNode,
    circuitFragmentEdges :: Set.Set (CircuitNodeRef, CircuitNodeRef)
  }

compileCircuitIR :: CircuitIR -> Either CircuitCompileError CompiledCircuit
compileCircuitIR circuitIr = do
  fragment <- compileExpr [] circuitIr.circuitIrRoot
  let topology = fragmentTopology fragment
  first CircuitInvalidTopology (validateDAG topology)
  pure
    CompiledCircuit
      { compiledCircuitId = circuitIr.circuitIrId,
        compiledCircuitLabel = circuitIr.circuitIrLabel,
        compiledCircuitCompatibility = compatibilityWitness circuitIr,
        compiledCircuitEntryNodes = ordNub fragment.circuitFragmentRoots,
        compiledCircuitExitNodes = ordNub fragment.circuitFragmentExits,
        compiledCircuitTopology = topology,
        compiledCircuitNodes = fragment.circuitFragmentNodes,
        compiledCircuitMetadata = circuitIr.circuitIrMetadata
      }

compileExpr :: [Int] -> CircuitExpr -> Either CircuitCompileError CircuitFragment
compileExpr pathKey = \case
  CircuitSequence (expr NE.:| exprs) -> do
    firstFragment <- compileExpr (pathKey <> [0]) expr
    foldl' step (Right firstFragment) (zip [1 ..] exprs)
    where
      step acc (ix, nextExpr) = do
        prev <- acc
        next <- compileExpr (pathKey <> [ix]) nextExpr
        connectSequential prev next
  CircuitParallel exprs ->
    foldl' step (Right emptyFragment) (zip [0 ..] (NE.toList exprs))
    where
      step acc (ix, branchExpr) = do
        built <- acc
        branch <- compileExpr (pathKey <> [ix]) branchExpr
        mergeParallel built branch
  CircuitConditional condition thenExpr maybeElseExpr -> do
    thenFragment <- compileExpr (pathKey <> [0]) thenExpr
    thenCompiledFragment <- compileFragment thenFragment
    elseCompiledFragment <- traverse (compileExpr (pathKey <> [1]) >=> compileFragment) maybeElseExpr
    let conditionNode =
          CircuitConditionNode
            { circuitConditionNodeRef = syntheticNodeRef "condition" pathKey,
              circuitConditionNodeCondition = condition,
              circuitConditionNodeThenFragment = thenCompiledFragment,
              circuitConditionNodeElseFragment = elseCompiledFragment,
              circuitConditionNodeMetadata = Aeson.object []
            }
    singletonFragment (CompiledCircuitCondition conditionNode)
  CircuitTask taskNode ->
    singletonFragment (CompiledCircuitTask taskNode)
  CircuitAwaitSignal signalBoundary ->
    singletonFragment (CompiledCircuitSignal signalBoundary)
  CircuitArtifact artifactBoundary ->
    singletonFragment (CompiledCircuitArtifact artifactBoundary)
  CircuitRewriteScope rewriteBoundary innerExpr -> do
    boundaryFragment <- singletonFragment (CompiledCircuitRewriteBoundary rewriteBoundary)
    innerFragment <- compileExpr (pathKey <> [0]) innerExpr
    stitched <- connectSequential boundaryFragment innerFragment
    pure
      stitched
        { circuitFragmentRoots = boundaryFragment.circuitFragmentRoots,
          circuitFragmentExits = innerFragment.circuitFragmentExits
        }

emptyFragment :: CircuitFragment
emptyFragment =
  CircuitFragment
    { circuitFragmentRoots = [],
      circuitFragmentExits = [],
      circuitFragmentNodes = Map.empty,
      circuitFragmentEdges = Set.empty
    }

singletonFragment :: CompiledCircuitNode -> Either CircuitCompileError CircuitFragment
singletonFragment compiledNode =
  let nodeRef = compiledCircuitNodeRef compiledNode
   in pure
        CircuitFragment
          { circuitFragmentRoots = [nodeRef],
            circuitFragmentExits = [nodeRef],
            circuitFragmentNodes = Map.singleton nodeRef compiledNode,
            circuitFragmentEdges = Set.empty
          }

connectSequential :: CircuitFragment -> CircuitFragment -> Either CircuitCompileError CircuitFragment
connectSequential left right = do
  nodes' <- mergeNodeMaps left.circuitFragmentNodes right.circuitFragmentNodes
  pure
    CircuitFragment
      { circuitFragmentRoots = left.circuitFragmentRoots,
        circuitFragmentExits = right.circuitFragmentExits,
        circuitFragmentNodes = nodes',
        circuitFragmentEdges =
          left.circuitFragmentEdges
            <> right.circuitFragmentEdges
            <> Set.fromList
              [ (fromRef, toRef)
              | fromRef <- left.circuitFragmentExits,
                toRef <- right.circuitFragmentRoots
              ]
      }

mergeParallel :: CircuitFragment -> CircuitFragment -> Either CircuitCompileError CircuitFragment
mergeParallel left right = do
  nodes' <- mergeNodeMaps left.circuitFragmentNodes right.circuitFragmentNodes
  pure
    CircuitFragment
      { circuitFragmentRoots = ordNub (left.circuitFragmentRoots <> right.circuitFragmentRoots),
        circuitFragmentExits = ordNub (left.circuitFragmentExits <> right.circuitFragmentExits),
        circuitFragmentNodes = nodes',
        circuitFragmentEdges = left.circuitFragmentEdges <> right.circuitFragmentEdges
      }

mergeNodeMaps ::
  Map CircuitNodeRef CompiledCircuitNode ->
  Map CircuitNodeRef CompiledCircuitNode ->
  Either CircuitCompileError (Map CircuitNodeRef CompiledCircuitNode)
mergeNodeMaps left right =
  case filter (`Map.member` left) (Map.keys right) of
    duplicateRef : _ -> Left (CircuitDuplicateNodeRef duplicateRef)
    [] -> Right (Map.union left right)

compatibilityWitness :: CircuitIR -> CircuitCompatibilityWitness
compatibilityWitness circuitIr =
  CircuitCompatibilityWitness
    { circuitCompatibilityFamily = "cortex.workflow/v1",
      circuitCompatibilityDigest = digestText (Aeson.encode circuitIr)
    }

digestText :: BSL.ByteString -> Text
digestText bytes = T.pack (show (hashlazy bytes :: Digest SHA256))

syntheticNodeRef :: Text -> [Int] -> CircuitNodeRef
syntheticNodeRef nodeKind pathKey =
  CircuitNodeRef $
    "__cortex_workflow__/"
      <> nodeKind
      <> "/"
      <> ( if null pathKey
             then "root"
             else T.intercalate "/" (fmap (T.pack . show) pathKey)
         )

fragmentTopology :: CircuitFragment -> Relation CircuitNodeRef
fragmentTopology fragment =
  toRelation $
    vertices (Map.keys fragment.circuitFragmentNodes)
      <> edges (Set.toList fragment.circuitFragmentEdges)

compileFragment :: CircuitFragment -> Either CircuitCompileError CompiledCircuitFragment
compileFragment fragment = do
  let topology = fragmentTopology fragment
  first CircuitInvalidTopology (validateDAG topology)
  pure
    CompiledCircuitFragment
      { compiledCircuitFragmentEntryNodes = ordNub fragment.circuitFragmentRoots,
        compiledCircuitFragmentExitNodes = ordNub fragment.circuitFragmentExits,
        compiledCircuitFragmentTopology = topology,
        compiledCircuitFragmentNodes = fragment.circuitFragmentNodes
      }

ordNub :: (Ord a) => [a] -> [a]
ordNub =
  reverse . fst . foldl' step ([], Set.empty)
  where
    step (acc, seen) value
      | value `Set.member` seen = (acc, seen)
      | otherwise = (value : acc, Set.insert value seen)
