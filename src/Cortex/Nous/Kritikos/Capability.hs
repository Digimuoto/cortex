module Cortex.Nous.Kritikos.Capability
  ( kritikosCapabilityBundle,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Kritikos),
    NousCapabilityBundle,
    nousCapabilityBundle,
  )

kritikosCapabilityBundle :: NousCapabilityBundle
kritikosCapabilityBundle = nousCapabilityBundle Kritikos
