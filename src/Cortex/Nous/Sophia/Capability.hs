module Cortex.Nous.Sophia.Capability
  ( sophiaCapabilityBundle,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Sophia),
    NousCapabilityBundle,
    nousCapabilityBundle,
  )

sophiaCapabilityBundle :: NousCapabilityBundle
sophiaCapabilityBundle = nousCapabilityBundle Sophia
