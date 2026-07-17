{- |
Module      : Cortex.Wire.StaticProgram
Description : Normalized fixed-topology deployment input for the Wire C backend.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

This module lowers the authoritative 'CompiledCircuit' plus its admission
artifact into the deliberately smaller @static-program/v1@ deployment input.
The artifact is data for Lean validation and C emission; it is not a replacement
for either the compiled circuit or the proof-witness admission artifact.
-}
module Cortex.Wire.StaticProgram
  ( StaticProgram (..)
  , StaticProgramNode (..)
  , StaticProgramEdge (..)
  , StaticProgramError (..)
  , staticProgramSchema
  , lowerCompiledCircuitToStaticProgram
  , renderStaticProgramError
  )
where

import Control.Monad (void)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Numeric.Natural (Natural)

import Cortex.Algebra.Graph (Relation (..), ValidationError (..), analyzeDAG)
import Cortex.Wire.AdmissionArtifact
  ( WireAdmissionArtifact (..)
  , WireAdmissionClosureMode (..)
  , wireAdmissionMetadataKey
  )
import Cortex.Wire.AdmissionBundle
  ( WireAdmissionBundle (..)
  , admitWireAdmissionBundle
  )
import Cortex.Wire.Circuit.Compiled
  ( CircuitCompatibilityWitness (..)
  , CompiledCircuit (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))

-- | Stable schema identifier consumed by the Lean host executable.
staticProgramSchema :: Text
staticProgramSchema = "cortex.wire.static-program/v1"

-- | One canonical dense node in the static deployment graph.
data StaticProgramNode = StaticProgramNode
  { staticProgramNodeId :: !Word32
  , staticProgramNodeRef :: !CircuitNodeRef
  , staticProgramNodeExecutor :: !Text
  }
  deriving stock (Eq, Show)

-- | One direct edge between dense node identifiers.
data StaticProgramEdge = StaticProgramEdge
  { staticProgramEdgeFrom :: !Word32
  , staticProgramEdgeTo :: !Word32
  }
  deriving stock (Eq, Ord, Show)

-- | Restricted deployment artifact accepted by @cortex-wire-c@.
data StaticProgram = StaticProgram
  { staticProgramAdmissionSchemaVersion :: !Word32
  , staticProgramId :: !Text
  , staticProgramIdentity :: !Text
  , staticProgramNodes :: ![StaticProgramNode]
  , staticProgramEdges :: ![StaticProgramEdge]
  }
  deriving stock (Eq, Show)

-- | Typed rejection reasons for the fixed-topology deployment profile.
data StaticProgramError
  = StaticProgramMissingAdmissionArtifact
  | StaticProgramMalformedAdmissionArtifact
  | StaticProgramAdmissionRejected !Text
  | StaticProgramOpenFragment
  | StaticProgramAdmissionVersionOverflow !Natural
  | StaticProgramNodeCountOverflow !Integer
  | StaticProgramEdgeCountOverflow !Integer
  | StaticProgramUnsupportedNode !CircuitNodeRef !Text
  | StaticProgramUnsupportedAdmissionFeature !Text
  | StaticProgramPureNode !CircuitNodeRef
  | StaticProgramInvalidExecutor !CircuitNodeRef
  | StaticProgramInvalidEndpoint !CircuitNodeRef
  | StaticProgramCycle ![CircuitNodeRef]
  deriving stock (Eq, Show)

instance ToJSON StaticProgramNode where
  toJSON node =
    Aeson.object
      [ "id" .= node.staticProgramNodeId
      , "ref" .= node.staticProgramNodeRef.unCircuitNodeRef
      , "executor" .= node.staticProgramNodeExecutor
      ]

instance FromJSON StaticProgramNode where
  parseJSON = Aeson.withObject "StaticProgramNode" $ \objectValue ->
    StaticProgramNode
      <$> objectValue .: "id"
      <*> (CircuitNodeRef <$> objectValue .: "ref")
      <*> objectValue .: "executor"

instance ToJSON StaticProgramEdge where
  toJSON edge =
    Aeson.object
      [ "from" .= edge.staticProgramEdgeFrom
      , "to" .= edge.staticProgramEdgeTo
      ]

instance FromJSON StaticProgramEdge where
  parseJSON = Aeson.withObject "StaticProgramEdge" $ \objectValue ->
    StaticProgramEdge
      <$> objectValue .: "from"
      <*> objectValue .: "to"

instance ToJSON StaticProgram where
  toJSON program =
    Aeson.object
      [ "schema" .= staticProgramSchema
      , "admission_schema_version" .= program.staticProgramAdmissionSchemaVersion
      , "program_id" .= program.staticProgramId
      , "program_identity" .= program.staticProgramIdentity
      , "nodes" .= program.staticProgramNodes
      , "edges" .= program.staticProgramEdges
      ]

instance FromJSON StaticProgram where
  parseJSON = Aeson.withObject "StaticProgram" $ \objectValue -> do
    schema <- objectValue .: "schema"
    if schema == staticProgramSchema
      then
        StaticProgram
          <$> objectValue .: "admission_schema_version"
          <*> objectValue .: "program_id"
          <*> objectValue .: "program_identity"
          <*> objectValue .: "nodes"
          <*> objectValue .: "edges"
      else fail ("unsupported static program schema: " <> T.unpack schema)

-- | Lower an admitted circuit to the normalized deployment profile.
lowerCompiledCircuitToStaticProgram
  :: CompiledCircuit -> Either StaticProgramError StaticProgram
lowerCompiledCircuitToStaticProgram compiled = do
  candidateAdmission <- extractAdmissionArtifact compiled
  admission <-
    case admitWireAdmissionBundle candidateAdmission compiled of
      Left rejection -> Left (StaticProgramAdmissionRejected (T.pack (show rejection)))
      Right bundle -> Right bundle.wireAdmissionBundleArtifact
  validateStaticProfile admission
  admissionVersion <- naturalToWord32 admission.wireAdmissionSchemaVersion
  checkBound StaticProgramNodeCountOverflow (Map.size compiled.compiledCircuitNodes)
  checkBound StaticProgramEdgeCountOverflow (Set.size compiled.compiledCircuitTopology.relEdges)
  validateEndpoints compiled
  case analyzeDAG compiled.compiledCircuitTopology of
    Left (GraphHasCycle cyclePath) -> Left (StaticProgramCycle cyclePath)
    Right _topologicalOrder -> pure ()
  nodes <- traverse (uncurry lowerNode) (zip [0 ..] (Map.toAscList compiled.compiledCircuitNodes))
  let denseIds =
        Map.fromAscList
          [ (nodeRef, node.staticProgramNodeId)
          | (nodeRef, node) <- zip (Map.keys compiled.compiledCircuitNodes) nodes
          ]
  edges <- traverse (lowerEdge denseIds) (Set.toAscList compiled.compiledCircuitTopology.relEdges)
  pure
    StaticProgram
      { staticProgramAdmissionSchemaVersion = admissionVersion
      , staticProgramId = compiled.compiledCircuitId
      , staticProgramIdentity = compiled.compiledCircuitCompatibility.circuitCompatibilityDigest
      , staticProgramNodes = nodes
      , staticProgramEdges = edges
      }
  where
    lowerNode
      :: Integer -> (CircuitNodeRef, CompiledCircuitNode) -> Either StaticProgramError StaticProgramNode
    lowerNode denseId (nodeRef, compiledNode) = do
      nodeId <- integerToWord32 StaticProgramNodeCountOverflow denseId
      executor <- case compiledNode of
        CompiledCircuitTask taskNode -> taskExecutor nodeRef taskNode
        CompiledCircuitSignal {} -> Left (StaticProgramUnsupportedNode nodeRef "signal")
        CompiledCircuitArtifact {} -> Left (StaticProgramUnsupportedNode nodeRef "artifact")
        CompiledCircuitRewriteBoundary {} ->
          Left (StaticProgramUnsupportedNode nodeRef "rewrite-boundary")
        CompiledCircuitCondition {} -> Left (StaticProgramUnsupportedNode nodeRef "condition")
      if executor == "pure"
        then Left (StaticProgramPureNode nodeRef)
        else
          Right
            StaticProgramNode
              { staticProgramNodeId = nodeId
              , staticProgramNodeRef = nodeRef
              , staticProgramNodeExecutor = executor
              }

-- | Render a stable, CLI-facing diagnostic for a lowering failure.
renderStaticProgramError :: StaticProgramError -> Text
renderStaticProgramError = \case
  StaticProgramMissingAdmissionArtifact ->
    "compiled circuit has no validator-ready Wire admission artifact"
  StaticProgramMalformedAdmissionArtifact ->
    "compiled circuit carries malformed Wire admission metadata"
  StaticProgramAdmissionRejected rejection ->
    "compiled circuit failed unified Wire admission: " <> rejection
  StaticProgramOpenFragment ->
    "static-program/v1 requires a closed executable admission artifact"
  StaticProgramAdmissionVersionOverflow version ->
    "Wire admission schema version exceeds uint32_t: " <> T.pack (show version)
  StaticProgramNodeCountOverflow count ->
    "static program node count or dense identifier exceeds uint32_t: " <> T.pack (show count)
  StaticProgramEdgeCountOverflow count ->
    "static program edge count exceeds uint32_t: " <> T.pack (show count)
  StaticProgramUnsupportedNode nodeRef kind ->
    "static-program/v1 rejects " <> kind <> " node " <> nodeRef.unCircuitNodeRef
  StaticProgramUnsupportedAdmissionFeature feature ->
    "static-program/v1 rejects admission feature " <> feature
  StaticProgramPureNode nodeRef ->
    "static-program/v1 rejects delayed CorePure node " <> nodeRef.unCircuitNodeRef
  StaticProgramInvalidExecutor nodeRef ->
    "task node has no native executor identity: " <> nodeRef.unCircuitNodeRef
  StaticProgramInvalidEndpoint nodeRef ->
    "topology edge references unknown node " <> nodeRef.unCircuitNodeRef
  StaticProgramCycle cyclePath ->
    "static-program/v1 requires a DAG; cycle: "
      <> T.intercalate " -> " (fmap (.unCircuitNodeRef) cyclePath)

taskExecutor :: CircuitNodeRef -> CircuitTaskNode -> Either StaticProgramError Text
taskExecutor nodeRef taskNode =
  case taskNode.circuitTaskNodeMetadata of
    Aeson.Object metadata ->
      case KeyMap.lookup "executor" metadata of
        Just (Aeson.Object executor) ->
          case (KeyMap.lookup "kind" executor, KeyMap.lookup "target" executor) of
            (Just (Aeson.String "native"), Just (Aeson.String target))
              | not (T.null target) -> Right target
            _ -> Left (StaticProgramInvalidExecutor nodeRef)
        _ -> Left (StaticProgramInvalidExecutor nodeRef)
    _ -> Left (StaticProgramInvalidExecutor nodeRef)

validateEndpoints :: CompiledCircuit -> Either StaticProgramError ()
validateEndpoints compiled =
  case Set.toAscList
    ((topologyNodes `Set.difference` compiledNodes) <> (compiledNodes `Set.difference` topologyNodes)) of
    invalid : _ -> Left (StaticProgramInvalidEndpoint invalid)
    [] -> Right ()
  where
    topologyNodes = compiled.compiledCircuitTopology.relVertices
    compiledNodes = Map.keysSet compiled.compiledCircuitNodes

lowerEdge
  :: Map.Map CircuitNodeRef Word32
  -> (CircuitNodeRef, CircuitNodeRef)
  -> Either StaticProgramError StaticProgramEdge
lowerEdge denseIds (source, target) = do
  sourceId <- maybe (Left (StaticProgramInvalidEndpoint source)) Right (Map.lookup source denseIds)
  targetId <- maybe (Left (StaticProgramInvalidEndpoint target)) Right (Map.lookup target denseIds)
  pure (StaticProgramEdge sourceId targetId)

naturalToWord32 :: Natural -> Either StaticProgramError Word32
naturalToWord32 value
  | toInteger value <= toInteger (maxBound :: Word32) = Right (fromIntegral value)
  | otherwise = Left (StaticProgramAdmissionVersionOverflow value)

integerToWord32
  :: (Integer -> StaticProgramError) -> Integer -> Either StaticProgramError Word32
integerToWord32 mkError value
  | value >= 0 && value <= toInteger (maxBound :: Word32) = Right (fromInteger value)
  | otherwise = Left (mkError value)

checkBound :: (Integer -> StaticProgramError) -> Int -> Either StaticProgramError ()
checkBound mkError count =
  void (integerToWord32 mkError (toInteger count))

extractAdmissionArtifact :: CompiledCircuit -> Either StaticProgramError WireAdmissionArtifact
extractAdmissionArtifact compiled =
  case compiled.compiledCircuitMetadata of
    Aeson.Object metadata ->
      case KeyMap.lookup (Key.fromText wireAdmissionMetadataKey) metadata of
        Nothing -> Left StaticProgramMissingAdmissionArtifact
        Just encoded ->
          case Aeson.fromJSON encoded of
            Aeson.Error _message -> Left StaticProgramMalformedAdmissionArtifact
            Aeson.Success artifact -> Right artifact
    _nonObjectMetadata -> Left StaticProgramMissingAdmissionArtifact

validateStaticProfile :: WireAdmissionArtifact -> Either StaticProgramError ()
validateStaticProfile admission = do
  case admission.wireAdmissionClosureMode of
    AdmissionClosedExecutable -> Right ()
    AdmissionOpenFragment -> Left StaticProgramOpenFragment
  rejectNonEmpty "nested-fragment" admission.wireAdmissionBindingRefs
  rejectNonEmpty "generated-form" admission.wireAdmissionGeneratedForms
  rejectNonEmpty "phantom-adapter" admission.wireAdmissionPhantomAdapters
  rejectNonEmpty "select" admission.wireAdmissionSelects
  where
    rejectNonEmpty :: Text -> [value] -> Either StaticProgramError ()
    rejectNonEmpty _feature [] = Right ()
    rejectNonEmpty feature (_value : _rest) = Left (StaticProgramUnsupportedAdmissionFeature feature)
