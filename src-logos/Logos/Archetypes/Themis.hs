{- |
Module      : Logos.Archetypes.Themis
Description : Logos reasoning-library support for themis.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Archetypes.Themis
  ( themisDefinition
  )
where

import Logos.Types
  ( LogosArchetype (Themis)
  , LogosArchetypeDefinition
  , logosArchetypeDefinition
  )

themisDefinition :: LogosArchetypeDefinition
themisDefinition = logosArchetypeDefinition Themis
