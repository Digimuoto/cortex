module Cortex.Nous.Archetypes.Kritikos.Activation
  ( kritikosCapabilityBundle
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Kritikos)
  , NousCapabilityBundle
  , nousCapabilityBundle
  )

kritikosCapabilityBundle :: NousCapabilityBundle
kritikosCapabilityBundle = nousCapabilityBundle Kritikos
