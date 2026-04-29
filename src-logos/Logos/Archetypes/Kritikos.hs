{- |
Module      : Logos.Archetypes.Kritikos
Description : Logos reasoning-library support for kritikos.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Archetypes.Kritikos
  ( kritikosDefinition
  )
where

import Logos.Types
  ( LogosArchetype (Kritikos)
  , LogosArchetypeDefinition
  , logosArchetypeDefinition
  )

kritikosDefinition :: LogosArchetypeDefinition
kritikosDefinition = logosArchetypeDefinition Kritikos
