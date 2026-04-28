{- |
Module      : Cortex.Capability.Model.Client
Description : Cortex substrate support for client.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Model.Client
  ( CortexModelClient (..)
  )
where

import Cortex.Capability.Model.Types
  ( CortexChoice
  , CortexChoiceRequest
  )

data CortexModelClient m = CortexModelClient
  { requestCortexChoice :: CortexChoiceRequest -> m CortexChoice
  }
