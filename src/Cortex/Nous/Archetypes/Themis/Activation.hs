module Cortex.Nous.Archetypes.Themis.Activation
  ( themisCapabilityBundle,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Themis),
    NousCapabilityBundle,
    nousCapabilityBundle,
  )

themisCapabilityBundle :: NousCapabilityBundle
themisCapabilityBundle = nousCapabilityBundle Themis
