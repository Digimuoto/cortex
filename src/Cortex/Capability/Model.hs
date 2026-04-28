{- |
Module      : Cortex.Capability.Model
Description : Cortex substrate support for model.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Model
  ( module Cortex.Capability.Model.Client
  , module Cortex.Capability.Model.Message
  , module Cortex.Capability.Model.Output
  , module Cortex.Capability.Model.Types
  )
where

import Cortex.Capability.Model.Client
import Cortex.Capability.Model.Message
import Cortex.Capability.Model.Output
import Cortex.Capability.Model.Types
