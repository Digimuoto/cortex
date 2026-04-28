{- |
Module      : Cortex.Pulse.Materialize
Description : Pulse runtime support for materialize.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Materialize
  ( module Cortex.Pulse.Materialization
  )
where

import Cortex.Pulse.Materialization
