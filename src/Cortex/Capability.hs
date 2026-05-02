{- |
Module      : Cortex.Capability
Description : Cortex substrate support for capability.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability
  ( module Cortex.Capability.Executor
  , module Cortex.Capability.Executor.Pure
  )
where

import Cortex.Capability.Executor
import Cortex.Capability.Executor.Pure
