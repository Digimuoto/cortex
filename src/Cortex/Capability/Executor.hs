{- |
Module      : Cortex.Capability.Executor
Description : Authority-bearing executor registration boundary.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Capability executor specs describe the host authority that may be projected
into Wire. They intentionally do not carry runnable Pulse actions; hosts bind
those after checking tools, provider policy, config, and codecs.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Executor
  ( ExecutorSpec (..)
  , ExecutorConfigDecoder (..)
  , ExecutorArgumentDecoder (..)
  , executorSpecArgumentDecoder
  , executorSpecWithArgumentDecoder
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

data ExecutorArgumentDecoder
  = ExecutorArgumentUnchecked
  | ExecutorArgumentJsonSchema Aeson.Value
  | ExecutorArgumentDecoderName Text
  deriving stock (Eq, Show, Generic)

executorSpecArgumentDecoder :: ExecutorSpec -> ExecutorArgumentDecoder
executorSpecArgumentDecoder spec =
  case spec.executorSpecConfigDecoder of
    ExecutorConfigUnchecked -> ExecutorArgumentUnchecked
    ExecutorConfigJsonSchema schema -> ExecutorArgumentJsonSchema schema
    ExecutorConfigDecoderName name -> ExecutorArgumentDecoderName name

executorSpecWithArgumentDecoder :: ExecutorArgumentDecoder -> ExecutorSpec -> ExecutorSpec
executorSpecWithArgumentDecoder decoder spec =
  spec
    { executorSpecConfigDecoder =
        case decoder of
          ExecutorArgumentUnchecked -> ExecutorConfigUnchecked
          ExecutorArgumentJsonSchema schema -> ExecutorConfigJsonSchema schema
          ExecutorArgumentDecoderName name -> ExecutorConfigDecoderName name
    }

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
    , wireExecutorProjectionConfigShape = configShape (executorSpecArgumentDecoder spec)
    }
  where
    configShape = \case
      ExecutorArgumentUnchecked -> WireExecutorConfigUnchecked
      ExecutorArgumentJsonSchema schema -> WireExecutorConfigSchema schema
      ExecutorArgumentDecoderName _ -> WireExecutorConfigUnchecked

executorProjectionRegistry :: [ExecutorSpec] -> WireExecutorRegistry
executorProjectionRegistry specs =
  wireExecutorRegistryFromList (fmap executorProjection specs)
