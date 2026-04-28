{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

{- | Rel8 row types and table schemas for Pulse-owned tables.
All tables are in the 'pulse' PostgreSQL schema.
-}
module Cortex.Pulse.Schema
  ( -- * Row Types
    PulseTaskDefinitionRow (..)
  , PulseRunRow (..)
  , PulseCheckpointRow (..)
  , PulseStageLogRow (..)

    -- * Table Schemas
  , pulseTaskDefinitionSchema
  , pulseRunSchema
  , pulseCheckpointSchema
  , pulseStageLogSchema
  )
where

import Data.Aeson (Value)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time (CalendarDiffTime, UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Rel8

-- ============================================================================
-- Row Types
-- ============================================================================

data PulseTaskDefinitionRow f = PulseTaskDefinitionRow
  { taskId :: Column f UUID
  , taskType :: Column f Text
  , taskName :: Column f Text
  , config :: Column f Value
  , cronExpression :: Column f Text
  , enabled :: Column f Bool
  , schedulerClaimed :: Column f Bool
  , nextRunAt :: Column f (Maybe UTCTime)
  , lastRunAt :: Column f (Maybe UTCTime)
  , lastRunStatus :: Column f (Maybe Text)
  , timeoutSeconds :: Column f Int32
  , priority :: Column f Int32
  , minIntervalSeconds :: Column f (Maybe Int32)
  , createdAt :: Column f UTCTime
  , updatedAt :: Column f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Rel8able)

data PulseRunRow f = PulseRunRow
  { runId :: Column f UUID
  , taskId :: Column f UUID
  , status :: Column f Text
  , triggerSource :: Column f Text
  , startedAt :: Column f (Maybe UTCTime)
  , completedAt :: Column f (Maybe UTCTime)
  , duration :: Column f (Maybe CalendarDiffTime)
  , leaseOwner :: Column f (Maybe Text)
  , leaseExpiresAt :: Column f (Maybe UTCTime)
  , cancelRequestedAt :: Column f (Maybe UTCTime)
  , cancelReason :: Column f (Maybe Text)
  , errorType :: Column f (Maybe Text)
  , errorMessage :: Column f (Maybe Text)
  , errorRetryable :: Column f (Maybe Bool)
  , skipReason :: Column f (Maybe Text)
  , parentRunId :: Column f (Maybe UUID)
  , userId :: Column f (Maybe UUID)
  , createdAt :: Column f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Rel8able)

data PulseCheckpointRow f = PulseCheckpointRow
  { runId :: Column f UUID
  , taskType :: Column f Text
  , checkpointName :: Column f Text
  , state :: Column f Value
  , summary :: Column f (Maybe Value)
  , updatedAt :: Column f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Rel8able)

data PulseStageLogRow f = PulseStageLogRow
  { id :: Column f Int64
  , runId :: Column f UUID
  , stageName :: Column f Text
  , status :: Column f Text
  , stateSummary :: Column f (Maybe Value)
  , startedAt :: Column f UTCTime
  , completedAt :: Column f (Maybe UTCTime)
  }
  deriving stock (Generic)
  deriving anyclass (Rel8able)

-- ============================================================================
-- Table Schemas (manual — pulse schema via QualifiedName)
-- ============================================================================

pulseTaskDefinitionSchema :: TableSchema (PulseTaskDefinitionRow Name)
pulseTaskDefinitionSchema =
  TableSchema
    { name = QualifiedName {name = "task_definitions", schema = Just "pulse"}
    , columns =
        PulseTaskDefinitionRow
          { taskId = "task_id"
          , taskType = "task_type"
          , taskName = "task_name"
          , config = "config"
          , cronExpression = "cron_expression"
          , enabled = "enabled"
          , schedulerClaimed = "scheduler_claimed"
          , nextRunAt = "next_run_at"
          , lastRunAt = "last_run_at"
          , lastRunStatus = "last_run_status"
          , timeoutSeconds = "timeout_seconds"
          , priority = "priority"
          , minIntervalSeconds = "min_interval_seconds"
          , createdAt = "created_at"
          , updatedAt = "updated_at"
          }
    }

pulseRunSchema :: TableSchema (PulseRunRow Name)
pulseRunSchema =
  TableSchema
    { name = QualifiedName {name = "runs", schema = Just "pulse"}
    , columns =
        PulseRunRow
          { runId = "run_id"
          , taskId = "task_id"
          , status = "status"
          , triggerSource = "trigger_source"
          , startedAt = "started_at"
          , completedAt = "completed_at"
          , duration = "duration"
          , leaseOwner = "lease_owner"
          , leaseExpiresAt = "lease_expires_at"
          , cancelRequestedAt = "cancel_requested_at"
          , cancelReason = "cancel_reason"
          , errorType = "error_type"
          , errorMessage = "error_message"
          , errorRetryable = "error_retryable"
          , skipReason = "skip_reason"
          , parentRunId = "parent_run_id"
          , userId = "user_id"
          , createdAt = "created_at"
          }
    }

pulseCheckpointSchema :: TableSchema (PulseCheckpointRow Name)
pulseCheckpointSchema =
  TableSchema
    { name = QualifiedName {name = "checkpoints", schema = Just "pulse"}
    , columns =
        PulseCheckpointRow
          { runId = "run_id"
          , taskType = "task_type"
          , checkpointName = "checkpoint_name"
          , state = "state"
          , summary = "summary"
          , updatedAt = "updated_at"
          }
    }

pulseStageLogSchema :: TableSchema (PulseStageLogRow Name)
pulseStageLogSchema =
  TableSchema
    { name = QualifiedName {name = "stage_log", schema = Just "pulse"}
    , columns =
        PulseStageLogRow
          { id = "id"
          , runId = "run_id"
          , stageName = "stage_name"
          , status = "status"
          , stateSummary = "state_summary"
          , startedAt = "started_at"
          , completedAt = "completed_at"
          }
    }
