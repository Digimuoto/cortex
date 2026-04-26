{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Core types for the Cortex Pulse durable execution runtime.
module Cortex.Pulse.Types
  ( -- * Task Kind
    TaskKind (..),

    -- * Envelope
    CortexTaskEnvelope (..),
    taskEnvelopeVersionOrDefault,

    -- * Config
    PulseConfig (..),
    defaultRewriteBudget,
  )
where

import Cortex.Pulse.Rewrite (RewriteBudget (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)

-- | Opaque task kind identifier. The embedding application defines the
-- set of valid task kinds and registers handlers for them via the task
-- registry. Cortex treats this as an app-defined label.
newtype TaskKind = TaskKind {unTaskKind :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | The scheduling/launch envelope. The 'cortexTaskType' field name is
-- preserved for JSON wire compatibility with existing stored configs.
data CortexTaskEnvelope = CortexTaskEnvelope
  { cortexTaskType :: TaskKind,
    cortexTaskVersion :: Int,
    cortexTaskConfig :: Aeson.Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

taskEnvelopeVersionOrDefault :: Aeson.Value -> Int
taskEnvelopeVersionOrDefault rawConfig =
  case (Aeson.fromJSON rawConfig :: Aeson.Result CortexTaskEnvelope) of
    Aeson.Success envelope -> envelope.cortexTaskVersion
    Aeson.Error _ -> 1

-- | Pulse runtime configuration.
data PulseConfig = PulseConfig
  { pulseDbHost :: Text,
    pulseDbPort :: Word16,
    pulseDbUser :: Text,
    pulseDbPassword :: Text,
    pulseDbName :: Text,
    pulseDbPoolSize :: Int,
    pulseApiUrl :: Text,
    pulseJwtSecret :: Text,
    pulseJwtExpirationSeconds :: Int64,
    pulseJwtIssuer :: Text,
    pulseJwtAudience :: Text,
    pulseAdminApiKey :: Maybe Text,
    pulseServiceCredential :: Maybe Text,
    pulseHealthPort :: Int,
    pulseLeaseOwner :: Text,
    pulseLeaseDurationSeconds :: Int,
    pulsePollIntervalSeconds :: Int,
    pulseMaxConcurrentTasks :: Int,
    pulseMaxFrontierConcurrency :: Int,
    pulseTaskTypeLimits :: Map Text Int
  }

-- | Custom Show that redacts the password.
instance Show PulseConfig where
  show cfg =
    "PulseConfig {pulseDbHost = "
      <> show (pulseDbHost cfg)
      <> ", pulseDbPort = "
      <> show (pulseDbPort cfg)
      <> ", pulseDbPassword = <redacted>"
      <> ", pulseApiUrl = "
      <> show (pulseApiUrl cfg)
      <> ", pulseJwtSecret = <redacted>"
      <> ", pulseAdminApiKey = "
      <> case pulseAdminApiKey cfg of
        Nothing -> "Nothing"
        Just _ -> "Just <redacted>"
      <> ", ...}"

-- | Default rewrite budget for tasks that support graph rewrites.
--
-- Policy: **fail-fast**. Any rewrite whose structural cost exceeds the
-- remaining budget in any single dimension is rejected immediately, the
-- stage fails, and the run terminates. There is no soft-cap or deferred
-- rejection mode.
--
-- A zero-budget (@RewriteBudget 0 0 0 0 0@) disables rewrites entirely
-- while preserving graph-state execution for static plans. Tasks that
-- never produce rewrites can safely use the default budget — budget is
-- only consumed when a stage returns 'StageRewrite'.
defaultRewriteBudget :: RewriteBudget
defaultRewriteBudget =
  RewriteBudget
    { rbAddedNodesMax = 16,
      rbAddedEdgesMax = 32,
      rbAddedDepthMax = 6,
      rbFrontierDeltaMax = 4,
      rbRewriteOpsMax = 4
    }
