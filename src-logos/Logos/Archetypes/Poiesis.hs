{- |
Module      : Logos.Archetypes.Poiesis
Description : Logos reasoning-library support for poiesis.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Archetypes.Poiesis
  ( poiesisDefinition
  )
where

import Logos.Types
  ( LogosArchetype (Poiesis)
  , LogosArchetypeDefinition
  , logosArchetypeDefinition
  )

poiesisDefinition :: LogosArchetypeDefinition
poiesisDefinition = logosArchetypeDefinition Poiesis
