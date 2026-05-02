{- |
Module      : Cortex
Description : Supported Cortex import surface for downstream consumers.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Downstream products should prefer @import Cortex@ for the stable substrate
API. Area modules remain available for advanced use, but this module is the
boundary that accumulates public compatibility promises.
-}
module Cortex
  ( module Cortex.Algebra.Graph
  , module Cortex.Capability
  , GraphValidationError
  , module Cortex.Pulse
  , module Cortex.Wire
  , module Cortex.Wire.Circuit
  )
where

import Cortex.Algebra.Graph hiding (ValidationError)
import Cortex.Algebra.Graph qualified as Graph
import Cortex.Capability
import Cortex.Pulse
import Cortex.Wire
import Cortex.Wire.Circuit

-- | Domain-shaped alias for graph validation failures.
type GraphValidationError = Graph.ValidationError
