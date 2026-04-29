{- |
Module      : Logos.Thought.Policy
Description : Logos reasoning-library support for policy.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.Policy
  ( LogosActionApproval (..)
  , LogosAgentPolicy (..)
  , LogosToolScope (..)
  )
where

import Data.Text (Text)

data LogosToolScope = LogosToolScope
  { logosReadableTools :: [Text]
  , logosWritableTools :: [Text]
  }
  deriving stock (Eq, Show)

data LogosActionApproval
  = LogosActionApprovalRequired
  | LogosActionApprovalAutonomous
  deriving stock (Eq, Show)

data LogosAgentPolicy = LogosAgentPolicy
  { logosToolScope :: LogosToolScope
  , logosActionApproval :: LogosActionApproval
  , logosRequireGrounding :: Bool
  }
  deriving stock (Eq, Show)
