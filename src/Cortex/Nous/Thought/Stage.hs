{- |
Module      : Cortex.Nous.Thought.Stage
Description : Nous reasoning-library support for stage.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Thought.Stage
  ( CortexDeploymentId (..)
  , CortexRunHandle (..)
  , CortexRunId (..)
  , CortexStageDescriptor (..)
  )
where

import Data.Text (Text)
import Data.UUID (UUID)

newtype CortexRunId = CortexRunId UUID
  deriving stock (Eq, Show)

newtype CortexDeploymentId = CortexDeploymentId Text
  deriving stock (Eq, Show)

data CortexRunHandle = CortexRunHandle
  { cortexRunHandleRunId :: CortexRunId
  , cortexRunHandleDeploymentId :: Maybe CortexDeploymentId
  }
  deriving stock (Eq, Show)

data CortexStageDescriptor = CortexStageDescriptor
  { cortexStageAgentName :: Maybe Text
  , cortexStageStageName :: Maybe Text
  , cortexStageStep :: Maybe Int
  , cortexStageToolName :: Maybe Text
  }
  deriving stock (Eq, Show)
