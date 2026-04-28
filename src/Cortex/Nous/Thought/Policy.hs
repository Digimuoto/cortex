{- |
Module      : Cortex.Nous.Thought.Policy
Description : Nous reasoning-library support for policy.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Thought.Policy
  ( CortexActionApproval (..)
  , CortexAgentPolicy (..)
  , CortexToolScope (..)
  )
where

import Data.Text (Text)

data CortexToolScope = CortexToolScope
  { cortexReadableTools :: [Text]
  , cortexWritableTools :: [Text]
  }
  deriving stock (Eq, Show)

data CortexActionApproval
  = CortexActionApprovalRequired
  | CortexActionApprovalAutonomous
  deriving stock (Eq, Show)

data CortexAgentPolicy = CortexAgentPolicy
  { cortexToolScope :: CortexToolScope
  , cortexActionApproval :: CortexActionApproval
  , cortexRequireGrounding :: Bool
  }
  deriving stock (Eq, Show)
