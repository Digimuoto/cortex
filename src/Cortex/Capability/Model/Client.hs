module Cortex.Capability.Model.Client
  ( CortexModelClient (..)
  )
where

import Cortex.Capability.Model.Types
  ( CortexChoice
  , CortexChoiceRequest
  )

data CortexModelClient m = CortexModelClient
  { requestCortexChoice :: CortexChoiceRequest -> m CortexChoice
  }
