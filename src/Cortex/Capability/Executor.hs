{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}

{- | Authority-bearing executor registration boundary.

Capability executor specs describe the host authority that may be projected
into Wire. They intentionally do not carry runnable Pulse actions; hosts bind
those after checking tools, provider policy, config, and codecs.
-}
module Cortex.Capability.Executor
  ( ExecutorSpec (..)
  , ExecutorConfigDecoder (..)
  , ExecutorRequirement (..)
  , ExecutorCodecBoundary (..)
  , ExecutorBindingAuthority (..)
  , executorProjection
  , executorProjectionRegistry
  )
where

import Data.Aeson qualified as Aeson
import Data.Set (Set)
import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..)
  , WireExecutorEffect
  , WireExecutorId
  , WireExecutorProjection (..)
  , WireExecutorRegistry
  , wireExecutorRegistryFromList
  )

data ExecutorConfigDecoder
  = ExecutorConfigUnchecked
  | ExecutorConfigJsonSchema Aeson.Value
  | ExecutorConfigDecoderName Text
  deriving stock (Eq, Show, Generic)

data ExecutorRequirement
  = ExecutorRequiresTool Text
  | ExecutorRequiresModelPolicy Text
  | ExecutorRequiresProvider Text
  | ExecutorRequiresHostPermission Text
  deriving stock (Eq, Ord, Show, Generic)

data ExecutorCodecBoundary = ExecutorCodecBoundary
  { executorCodecInputContracts :: !(Set Text)
  , executorCodecOutputContracts :: !(Set Text)
  }
  deriving stock (Eq, Show, Generic)

data ExecutorBindingAuthority
  = ExecutorProfileOnly
  | ExecutorHostBound
  deriving stock (Eq, Show, Generic)

data ExecutorSpec = ExecutorSpec
  { executorSpecId :: !WireExecutorId
  , executorSpecPorts :: !WireExecutorProjection
  , executorSpecEffect :: !WireExecutorEffect
  , executorSpecConfigDecoder :: !ExecutorConfigDecoder
  , executorSpecRequirements :: !(Set ExecutorRequirement)
  , executorSpecCodecBoundary :: !ExecutorCodecBoundary
  , executorSpecBindingAuthority :: !ExecutorBindingAuthority
  }
  deriving stock (Eq, Show, Generic)

executorProjection :: ExecutorSpec -> WireExecutorProjection
executorProjection spec =
  (executorSpecPorts spec)
    { wireExecutorProjectionId = executorSpecId spec
    , wireExecutorProjectionEffect = executorSpecEffect spec
    , wireExecutorProjectionConfigShape = configShape (executorSpecConfigDecoder spec)
    }
  where
    configShape = \case
      ExecutorConfigUnchecked -> WireExecutorConfigUnchecked
      ExecutorConfigJsonSchema schema -> WireExecutorConfigSchema schema
      ExecutorConfigDecoderName _ -> WireExecutorConfigUnchecked

executorProjectionRegistry :: [ExecutorSpec] -> WireExecutorRegistry
executorProjectionRegistry specs =
  wireExecutorRegistryFromList (fmap executorProjection specs)
