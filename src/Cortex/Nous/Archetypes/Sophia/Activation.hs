module Cortex.Nous.Archetypes.Sophia.Activation
  ( sophiaCapabilityBundle
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Sophia)
  , NousCapabilityBundle
  , nousCapabilityBundle
  )

sophiaCapabilityBundle :: NousCapabilityBundle
sophiaCapabilityBundle = nousCapabilityBundle Sophia
