{- |
Module      : Cortex.Pulse.Frontier
Description : Pulse runtime support for frontier.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Frontier
  ( module Cortex.Pulse.Executor.Frontier
  )
where

import Cortex.Pulse.Executor.Frontier
