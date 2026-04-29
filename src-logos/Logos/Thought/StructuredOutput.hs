{- |
Module      : Logos.Thought.StructuredOutput
Description : Compatibility facade for thought structured-output policy.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.StructuredOutput
  ( module Cortex.Capability.StructuredOutput
  )
where

import Cortex.Capability.StructuredOutput
