module Cortex.Nous.Logos.Capability
  ( logosCapabilityBundle,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Logos),
    NousCapabilityBundle,
    nousCapabilityBundle,
  )

logosCapabilityBundle :: NousCapabilityBundle
logosCapabilityBundle = nousCapabilityBundle Logos
