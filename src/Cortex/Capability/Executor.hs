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
  , ExecutorArgumentDecoder (..)
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
  ( WireExecutorArgumentShape (..)
  , WireExecutorEffect
  , WireExecutorId
  , WireExecutorProjection (..)
  , WireExecutorRegistry
  , wireExecutorRegistryFromList
  )

data ExecutorArgumentDecoder
  = ExecutorArgumentUnchecked
  | ExecutorArgumentJsonSchema Aeson.Value
  | ExecutorArgumentDecoderName Text
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
  , executorSpecArgumentDecoder :: !ExecutorArgumentDecoder
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
    , wireExecutorProjectionArgumentShape = argumentShape (executorSpecArgumentDecoder spec)
    }
  where
    argumentShape = \case
      ExecutorArgumentUnchecked -> WireExecutorArgumentUnchecked
      ExecutorArgumentJsonSchema schema -> WireExecutorArgumentSchema schema
      ExecutorArgumentDecoderName _ -> WireExecutorArgumentUnchecked

executorProjectionRegistry :: [ExecutorSpec] -> WireExecutorRegistry
executorProjectionRegistry specs =
  wireExecutorRegistryFromList (fmap executorProjection specs)
