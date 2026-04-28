{- |
Module      : Cortex.Pulse.Persistence
Description : Pulse runtime support for persistence.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Persistence
  ( module Cortex.Pulse.Executor.Persistence
  )
where

import Cortex.Pulse.Executor.Persistence
