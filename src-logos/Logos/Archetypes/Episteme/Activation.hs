{- |
Module      : Logos.Archetypes.Episteme.Activation
Description : Logos reasoning-library support for activation.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Archetypes.Episteme.Activation
  ( epistemeCapabilityBundle
  )
where

import Logos.Types
  ( LogosArchetype (Episteme)
  , LogosCapabilityBundle
  , logosCapabilityBundleFor
  )

epistemeCapabilityBundle :: LogosCapabilityBundle
epistemeCapabilityBundle = logosCapabilityBundleFor Episteme
