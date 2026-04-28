{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Cortex.Wire.Circuit.Compiled
  ( CircuitCompatibilityWitness (..),
    CompiledCircuitFragment (..),
    CircuitConditionNode (..),
    CompiledCircuitNode (..),
    compiledCircuitNodeRef,
    CompiledCircuit (..),
  )
where

import Control.Lens ((&), (?~))
import Cortex.Algebra.Graph (Relation)
import Cortex.Wire.Circuit.IR
  ( CircuitArtifactBoundary (..),
    CircuitCondition,
    CircuitNodeRef,
    CircuitRewriteBoundary (..),
    CircuitSignalBoundary (..),
    CircuitTaskNode (..),
  )
import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Map.Strict (Map)
import Data.OpenApi
  ( NamedSchema (..),
    OpenApiType (..),
    ToSchema (..),
    description,
    type_,
  )
import Data.Text (Text)
import GHC.Generics (Generic)

data CircuitCompatibilityWitness = CircuitCompatibilityWitness
  { circuitCompatibilityFamily :: Text,
    circuitCompatibilityDigest :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CompiledCircuitFragment = CompiledCircuitFragment
  { compiledCircuitFragmentEntryNodes :: [CircuitNodeRef],
    compiledCircuitFragmentExitNodes :: [CircuitNodeRef],
    compiledCircuitFragmentTopology :: Relation CircuitNodeRef,
    compiledCircuitFragmentNodes :: Map CircuitNodeRef CompiledCircuitNode
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CircuitConditionNode = CircuitConditionNode
  { circuitConditionNodeRef :: CircuitNodeRef,
    circuitConditionNodeCondition :: CircuitCondition,
    circuitConditionNodeThenFragment :: CompiledCircuitFragment,
    circuitConditionNodeElseFragment :: Maybe CompiledCircuitFragment,
    circuitConditionNodeMetadata :: Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CompiledCircuitNode
  = CompiledCircuitTask CircuitTaskNode
  | CompiledCircuitSignal CircuitSignalBoundary
  | CompiledCircuitArtifact CircuitArtifactBoundary
  | CompiledCircuitRewriteBoundary CircuitRewriteBoundary
  | CompiledCircuitCondition CircuitConditionNode
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

compiledCircuitNodeRef :: CompiledCircuitNode -> CircuitNodeRef
compiledCircuitNodeRef = \case
  CompiledCircuitTask taskNode -> taskNode.circuitTaskNodeRef
  CompiledCircuitSignal signalBoundary -> signalBoundary.circuitSignalBoundaryRef
  CompiledCircuitArtifact artifactBoundary -> artifactBoundary.circuitArtifactBoundaryRef
  CompiledCircuitRewriteBoundary rewriteBoundary -> rewriteBoundary.circuitRewriteBoundaryRef
  CompiledCircuitCondition conditionNode -> conditionNode.circuitConditionNodeRef

data CompiledCircuit = CompiledCircuit
  { compiledCircuitId :: Text,
    compiledCircuitLabel :: Text,
    compiledCircuitCompatibility :: CircuitCompatibilityWitness,
    compiledCircuitEntryNodes :: [CircuitNodeRef],
    compiledCircuitExitNodes :: [CircuitNodeRef],
    compiledCircuitTopology :: Relation CircuitNodeRef,
    compiledCircuitNodes :: Map CircuitNodeRef CompiledCircuitNode,
    compiledCircuitMetadata :: Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance ToSchema CompiledCircuit where
  declareNamedSchema _ =
    pure . NamedSchema (Just "CompiledCircuit") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "Compiled Cortex circuit artifact with topology, durable node refs, compatibility witness, and node definitions. Exposed as an opaque object because it contains recursive graph metadata."
