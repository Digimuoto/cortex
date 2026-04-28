{- |
Module      : Cortex.Nous.Archetypes.Logos
Description : Nous reasoning-library support for logos.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Archetypes.Logos
  ( logosDefinition
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Logos)
  , NousArchetypeDefinition
  , nousArchetypeDefinition
  )

logosDefinition :: NousArchetypeDefinition
logosDefinition = nousArchetypeDefinition Logos
