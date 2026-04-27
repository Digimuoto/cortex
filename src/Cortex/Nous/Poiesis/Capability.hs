module Cortex.Nous.Poiesis.Capability
  ( poiesisCapabilityBundle,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Poiesis),
    NousCapabilityBundle,
    nousCapabilityBundle,
  )

poiesisCapabilityBundle :: NousCapabilityBundle
poiesisCapabilityBundle = nousCapabilityBundle Poiesis
