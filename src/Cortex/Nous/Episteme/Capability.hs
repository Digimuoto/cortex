module Cortex.Nous.Episteme.Capability
  ( epistemeCapabilityBundle,
  )
where

import Cortex.Nous.Types
  ( NousArchetype (Episteme),
    NousCapabilityBundle,
    nousCapabilityBundle,
  )

epistemeCapabilityBundle :: NousCapabilityBundle
epistemeCapabilityBundle = nousCapabilityBundle Episteme
