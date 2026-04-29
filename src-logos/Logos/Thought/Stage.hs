{- |
Module      : Logos.Thought.Stage
Description : Logos reasoning-library support for stage.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.Stage
  ( LogosStageDescriptor (..)
  )
where

import Data.Text (Text)

data LogosStageDescriptor = LogosStageDescriptor
  { logosStageAgentName :: Maybe Text
  , logosStageStageName :: Maybe Text
  , logosStageStep :: Maybe Int
  , logosStageToolName :: Maybe Text
  }
  deriving stock (Eq, Show)
