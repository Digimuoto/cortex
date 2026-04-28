module Cortex.Nous.Archetypes.Logos.Activation
  ( logosCapabilityBundle
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Logos)
  , NousCapabilityBundle
  , nousCapabilityBundle
  )

logosCapabilityBundle :: NousCapabilityBundle
logosCapabilityBundle = nousCapabilityBundle Logos
