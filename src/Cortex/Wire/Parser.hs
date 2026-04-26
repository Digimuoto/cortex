-- | Canonical Wire parser facade.
--
-- Versioned grammar implementations live below this module. Downstream code
-- should import this facade unless it deliberately tests a specific grammar
-- generation.
module Cortex.Wire.Parser
  ( module Cortex.Wire.V1.Parser,
  )
where

import Cortex.Wire.V1.Parser
