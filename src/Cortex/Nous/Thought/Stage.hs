{-# LANGUAGE DerivingStrategies #-}

module Cortex.Nous.Thought.Stage
  ( CortexDeploymentId (..),
    CortexRunHandle (..),
    CortexRunId (..),
    CortexStageDescriptor (..),
  )
where

import Data.Text (Text)
import Data.UUID (UUID)

newtype CortexRunId = CortexRunId UUID
  deriving stock (Eq, Show)

newtype CortexDeploymentId = CortexDeploymentId Text
  deriving stock (Eq, Show)

data CortexRunHandle = CortexRunHandle
  { cortexRunHandleRunId :: CortexRunId,
    cortexRunHandleDeploymentId :: Maybe CortexDeploymentId
  }
  deriving stock (Eq, Show)

data CortexStageDescriptor = CortexStageDescriptor
  { cortexStageAgentName :: Maybe Text,
    cortexStageStageName :: Maybe Text,
    cortexStageStep :: Maybe Int,
    cortexStageToolName :: Maybe Text
  }
  deriving stock (Eq, Show)
