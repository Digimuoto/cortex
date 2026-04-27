-- | Supported Cortex import surface for downstream consumers.
--
-- Downstream products should prefer @import Cortex@ for the stable substrate
-- API. Area modules remain available for advanced use, but this module is the
-- boundary that accumulates public compatibility promises.
module Cortex
  ( module Cortex.Capability,
    module Cortex.Circuit,
    module Cortex.Document,
    DocumentValidationError,
    module Cortex.Event,
    module Cortex.Graph,
    GraphValidationError,
    module Cortex.Memory,
    module Cortex.Nous,
    module Cortex.Pulse,
    module Cortex.Wire,
  )
where

import Cortex.Capability
import Cortex.Circuit
import Cortex.Document hiding (ValidationError)
import Cortex.Document qualified as Document
import Cortex.Event
import Cortex.Graph hiding (ValidationError)
import Cortex.Graph qualified as Graph
import Cortex.Memory
import Cortex.Nous
import Cortex.Pulse
import Cortex.Wire

-- | Domain-shaped alias for document validation failures.
type DocumentValidationError = Document.ValidationError

-- | Domain-shaped alias for graph validation failures.
type GraphValidationError = Graph.ValidationError
