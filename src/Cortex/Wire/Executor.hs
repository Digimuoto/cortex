{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Source-level executor references and compile-time executor projections.
--
-- Wire only needs the structural projection of registered executor authority:
-- identity, ports, vocabulary, config shape, and effect metadata. Runnable host
-- authority lives in 'Cortex.Capability.Executor'.
module Cortex.Wire.Executor
  ( WireExecutor (..),
    WireExecutorId (..),
    wireExecutorIdToText,
    wireExecutorIdFromWireExecutor,
    WireExecutorEffect (..),
    WireExecutorConfigShape (..),
    WireExecutorProjection (..),
    wireExecutorProjectionFromPorts,
    wireContractsFromPorts,
    WireExecutorRegistry (..),
    emptyWireExecutorRegistry,
    wireExecutorRegistryFromList,
    lookupWireExecutorProjection,
    wireExecutorRegistryVocabulary,
  )
where

import Cortex.Wire.AST
  ( WireExecutor (..),
    WireInputPort (..),
    WireOutputPort (..),
    WirePorts (..),
  )
import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)

newtype WireExecutorId = WireExecutorId {unWireExecutorId :: Text}
  deriving stock (Eq, Ord, Show, Generic)

wireExecutorIdToText :: WireExecutorId -> Text
wireExecutorIdToText = unWireExecutorId

wireExecutorIdFromWireExecutor :: WireExecutor -> WireExecutorId
wireExecutorIdFromWireExecutor = \case
  WireExecutorLLM modelId -> WireExecutorId modelId
  WireExecutorNative targetId -> WireExecutorId targetId

data WireExecutorEffect
  = WireExecutorPure
  | WireExecutorModel
  | WireExecutorHostEffect
  | WireExecutorImpure
  deriving stock (Eq, Show, Generic)

data WireExecutorConfigShape
  = WireExecutorConfigUnchecked
  | WireExecutorConfigSchema Aeson.Value
  deriving stock (Eq, Show, Generic)

data WireExecutorProjection = WireExecutorProjection
  { wireExecutorProjectionId :: !WireExecutorId,
    wireExecutorProjectionPorts :: !WirePorts,
    wireExecutorProjectionVocabulary :: !(Set Text),
    wireExecutorProjectionEffect :: !WireExecutorEffect,
    wireExecutorProjectionConfigShape :: !WireExecutorConfigShape
  }
  deriving stock (Eq, Show, Generic)

wireExecutorProjectionFromPorts ::
  WireExecutorId ->
  WirePorts ->
  WireExecutorEffect ->
  WireExecutorProjection
wireExecutorProjectionFromPorts executorId ports effect =
  WireExecutorProjection
    { wireExecutorProjectionId = executorId,
      wireExecutorProjectionPorts = ports,
      wireExecutorProjectionVocabulary = wireContractsFromPorts ports,
      wireExecutorProjectionEffect = effect,
      wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    }

wireContractsFromPorts :: WirePorts -> Set Text
wireContractsFromPorts ports =
  Set.fromList $
    concatMap (.wireInputPortAccepts) (Map.elems ports.wirePortsInputs)
      <> fmap (.wireOutputPortContract) (Map.elems ports.wirePortsOutputs)

newtype WireExecutorRegistry = WireExecutorRegistry
  { wireExecutorRegistryProjections :: Map WireExecutorId WireExecutorProjection
  }
  deriving stock (Eq, Show, Generic)

emptyWireExecutorRegistry :: WireExecutorRegistry
emptyWireExecutorRegistry =
  WireExecutorRegistry Map.empty

wireExecutorRegistryFromList :: [WireExecutorProjection] -> WireExecutorRegistry
wireExecutorRegistryFromList projections =
  WireExecutorRegistry
    (Map.fromList [(projection.wireExecutorProjectionId, projection) | projection <- projections])

lookupWireExecutorProjection :: WireExecutorId -> WireExecutorRegistry -> Maybe WireExecutorProjection
lookupWireExecutorProjection executorId registry =
  Map.lookup executorId registry.wireExecutorRegistryProjections

wireExecutorRegistryVocabulary :: WireExecutorRegistry -> Set Text
wireExecutorRegistryVocabulary registry =
  foldMap wireExecutorProjectionVocabulary registry.wireExecutorRegistryProjections
