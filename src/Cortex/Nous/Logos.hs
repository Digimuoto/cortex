module Cortex.Nous.Logos
  ( logosDefinition,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Logos),
    NousArchetypeDefinition,
    nousArchetypeDefinition,
  )

logosDefinition :: NousArchetypeDefinition
logosDefinition = nousArchetypeDefinition Logos
