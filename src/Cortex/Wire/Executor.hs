{- |
Module      : Cortex.Wire.Executor
Description : Source-level executor references and compile-time executor projections.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Wire only needs the structural projection of registered executor authority:
identity, ports, vocabulary, config shape, and effect metadata. Runnable host
authority lives in 'Cortex.Capability.Executor'.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Executor
  ( WireExecutor (..)
  , WireExecutorId (..)
  , wireExecutorIdToText
  , wireExecutorIdFromWireExecutor
  , WireExecutorEffect (..)
  , WireExecutorConfigShape (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , wireExecutorProjectionFromPorts
  , wireContractsFromPorts
  , WireExecutorRegistry (..)
  , emptyWireExecutorRegistry
  , wireExecutorRegistryFromList
  , lookupWireExecutorProjection
  , wireExecutorRegistryVocabulary
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Wire.AST
  ( WireExecutor (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePorts (..)
  )

newtype WireExecutorId = WireExecutorId {unWireExecutorId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (Aeson.ToJSON, Aeson.FromJSON)

wireExecutorIdToText :: WireExecutorId -> Text
wireExecutorIdToText = unWireExecutorId

wireExecutorIdFromWireExecutor :: WireExecutor -> WireExecutorId
wireExecutorIdFromWireExecutor = \case
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

data WireExecutorPortPolicy
  = WireExecutorFixedPorts
  | WireExecutorAuthorDeclaredPorts
  deriving stock (Eq, Show, Generic)

data WireExecutorProjection = WireExecutorProjection
  { wireExecutorProjectionId :: !WireExecutorId
  , wireExecutorProjectionPorts :: !WirePorts
  , wireExecutorProjectionVocabulary :: !(Set Text)
  , wireExecutorProjectionEffect :: !WireExecutorEffect
  , wireExecutorProjectionConfigShape :: !WireExecutorConfigShape
  , wireExecutorProjectionPortPolicy :: !WireExecutorPortPolicy
  }
  deriving stock (Eq, Show, Generic)

wireExecutorProjectionFromPorts
  :: WireExecutorId
  -> WirePorts
  -> WireExecutorEffect
  -> WireExecutorProjection
wireExecutorProjectionFromPorts executorId ports effect =
  WireExecutorProjection
    { wireExecutorProjectionId = executorId
    , wireExecutorProjectionPorts = ports
    , wireExecutorProjectionVocabulary = wireContractsFromPorts ports
    , wireExecutorProjectionEffect = effect
    , wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorFixedPorts
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

lookupWireExecutorProjection
  :: WireExecutorId -> WireExecutorRegistry -> Maybe WireExecutorProjection
lookupWireExecutorProjection executorId registry =
  Map.lookup executorId registry.wireExecutorRegistryProjections

wireExecutorRegistryVocabulary :: WireExecutorRegistry -> Set Text
wireExecutorRegistryVocabulary registry =
  foldMap wireExecutorProjectionVocabulary registry.wireExecutorRegistryProjections
