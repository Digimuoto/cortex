module Cortex.Nous.Episteme
  ( epistemeDefinition,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Episteme),
    NousArchetypeDefinition,
    nousArchetypeDefinition,
  )

epistemeDefinition :: NousArchetypeDefinition
epistemeDefinition = nousArchetypeDefinition Episteme
