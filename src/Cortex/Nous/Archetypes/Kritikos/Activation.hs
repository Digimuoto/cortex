{- |
Module      : Cortex.Nous.Archetypes.Kritikos.Activation
Description : Nous reasoning-library support for activation.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Archetypes.Kritikos.Activation
  ( kritikosCapabilityBundle
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Kritikos)
  , NousCapabilityBundle
  , nousCapabilityBundle
  )

kritikosCapabilityBundle :: NousCapabilityBundle
kritikosCapabilityBundle = nousCapabilityBundle Kritikos
