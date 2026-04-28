{-# LANGUAGE DerivingStrategies #-}

module Cortex.Nous.Thought.Policy
  ( CortexActionApproval (..),
    CortexAgentPolicy (..),
    CortexToolScope (..),
  )
where

import Data.Text (Text)

data CortexToolScope = CortexToolScope
  { cortexReadableTools :: [Text],
    cortexWritableTools :: [Text]
  }
  deriving stock (Eq, Show)

data CortexActionApproval
  = CortexActionApprovalRequired
  | CortexActionApprovalAutonomous
  deriving stock (Eq, Show)

data CortexAgentPolicy = CortexAgentPolicy
  { cortexToolScope :: CortexToolScope,
    cortexActionApproval :: CortexActionApproval,
    cortexRequireGrounding :: Bool
  }
  deriving stock (Eq, Show)
