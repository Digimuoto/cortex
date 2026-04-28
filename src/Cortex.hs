-- | Supported Cortex import surface for downstream consumers.
--
-- Downstream products should prefer @import Cortex@ for the stable substrate
-- API. Area modules remain available for advanced use, but this module is the
-- boundary that accumulates public compatibility promises.
module Cortex
  ( module Cortex.Algebra.Graph,
    module Cortex.Artifact,
    module Cortex.Capability,
    DocumentValidationError,
    GraphValidationError,
    module Cortex.Nous.Memory,
    module Cortex.Nous,
    module Cortex.Pulse,
    module Cortex.Wire,
    module Cortex.Wire.Circuit,
  )
where

import Cortex.Algebra.Graph hiding (ValidationError)
import Cortex.Algebra.Graph qualified as Graph
import Cortex.Artifact hiding (ValidationError)
import Cortex.Artifact qualified as Artifact
import Cortex.Capability
import Cortex.Nous
import Cortex.Nous.Memory
import Cortex.Pulse
import Cortex.Wire
import Cortex.Wire.Circuit

-- | Domain-shaped alias for document validation failures.
type DocumentValidationError = Artifact.ValidationError

-- | Domain-shaped alias for graph validation failures.
type GraphValidationError = Graph.ValidationError
