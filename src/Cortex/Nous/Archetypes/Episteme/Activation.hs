module Cortex.Nous.Archetypes.Episteme.Activation
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
