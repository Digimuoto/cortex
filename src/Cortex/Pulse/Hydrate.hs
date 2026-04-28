{- |
Module      : Cortex.Pulse.Hydrate
Description : Pulse runtime support for hydrate.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Hydrate
  ( module Cortex.Pulse.PlanHydration
  )
where

import Cortex.Pulse.PlanHydration
