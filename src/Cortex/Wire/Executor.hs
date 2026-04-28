-- | Source-level executor references and compile-time executor projections.
--
-- The concrete registration and host binding API is intentionally deferred to a
-- later executor-design ADR. This module exposes the current Wire executor
-- reference type at the canonical namespace.
module Cortex.Wire.Executor
  ( WireExecutor (..),
  )
where

import Cortex.Wire.AST (WireExecutor (..))
