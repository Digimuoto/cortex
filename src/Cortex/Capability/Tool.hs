{- |
Module      : Cortex.Capability.Tool
Description : Cortex substrate support for tool.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Tool
  ( module Cortex.Capability.Tool.Definition
  , module Cortex.Capability.Tool.Record
  )
where

import Cortex.Capability.Tool.Definition
import Cortex.Capability.Tool.Record
