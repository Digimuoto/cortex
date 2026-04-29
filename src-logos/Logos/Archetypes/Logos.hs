{- |
Module      : Logos.Archetypes.Logos
Description : Logos reasoning-library support for logos.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Archetypes.Logos
  ( logosDefinition
  )
where

import Logos.Types
  ( LogosArchetype (Logos)
  , LogosArchetypeDefinition
  , logosArchetypeDefinition
  )

logosDefinition :: LogosArchetypeDefinition
logosDefinition = logosArchetypeDefinition Logos
