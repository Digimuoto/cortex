module Cortex.Nous.Techne.Capability
  ( techneCapabilityBundle,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Techne),
    NousCapabilityBundle,
    nousCapabilityBundle,
  )

techneCapabilityBundle :: NousCapabilityBundle
techneCapabilityBundle = nousCapabilityBundle Techne
