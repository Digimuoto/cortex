module Cortex.Nous.Themis
  ( themisDefinition,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Themis),
    NousArchetypeDefinition,
    nousArchetypeDefinition,
  )

themisDefinition :: NousArchetypeDefinition
themisDefinition = nousArchetypeDefinition Themis
