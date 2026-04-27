module Cortex.Nous.Kritikos
  ( kritikosDefinition,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Kritikos),
    NousArchetypeDefinition,
    nousArchetypeDefinition,
  )

kritikosDefinition :: NousArchetypeDefinition
kritikosDefinition = nousArchetypeDefinition Kritikos
