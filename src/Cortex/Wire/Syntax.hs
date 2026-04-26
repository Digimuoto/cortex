-- | Canonical Wire syntax facade.
--
-- The current grammar implementation is backed by 'Cortex.Wire.V1.AST'. This
-- module is the stable import surface for source-level syntax and shared Wire
-- structural types.
module Cortex.Wire.Syntax
  ( module Cortex.Wire.AST,
    module Cortex.Wire.V1.AST,
  )
where

import Cortex.Wire.AST
import Cortex.Wire.V1.AST
