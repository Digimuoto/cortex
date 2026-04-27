module Cortex.Nous.Themis.Capability
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
