{- |
Module      : Cortex.Nous.Archetypes.Poiesis
Description : Nous reasoning-library support for poiesis.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Archetypes.Poiesis
  ( poiesisDefinition
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Poiesis)
  , NousArchetypeDefinition
  , nousArchetypeDefinition
  )

poiesisDefinition :: NousArchetypeDefinition
poiesisDefinition = nousArchetypeDefinition Poiesis
