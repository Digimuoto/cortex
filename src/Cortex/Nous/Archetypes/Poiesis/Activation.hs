module Cortex.Nous.Archetypes.Poiesis.Activation
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
