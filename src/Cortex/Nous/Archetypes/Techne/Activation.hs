module Cortex.Nous.Archetypes.Techne.Activation
  ( techneCapabilityBundle
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Techne)
  , NousCapabilityBundle
  , nousCapabilityBundle
  )

techneCapabilityBundle :: NousCapabilityBundle
techneCapabilityBundle = nousCapabilityBundle Techne
