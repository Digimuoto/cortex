module Cortex.Nous.Sophia
  ( sophiaDefinition,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Sophia),
    NousArchetypeDefinition,
    nousArchetypeDefinition,
  )

sophiaDefinition :: NousArchetypeDefinition
sophiaDefinition = nousArchetypeDefinition Sophia
