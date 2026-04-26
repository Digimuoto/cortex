-- | Canonical Wire compiler facade.
--
-- The concrete grammar implementation currently lives under
-- 'Cortex.Wire.V1'. Future grammar generations should switch this facade
-- rather than making downstream code import a versioned implementation.
module Cortex.Wire.Compile
  ( module Cortex.Wire.V1.Compiler,
  )
where

import Cortex.Wire.V1.Compiler
